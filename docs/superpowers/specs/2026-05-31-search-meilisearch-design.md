# Search (Meilisearch) Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-05-31
**Status:** Approved
**Phase:** 1 (MVP) — Subsystem 4 of 6
**Depends on:** Phase 0 (Meilisearch in Compose; `meilisearch_url`/`meilisearch_key` config); Subsystem 2 (Content — `Article`, `blocks`, `Tag`, `Category`); Subsystem 3 (Oban already configured + supervised; the `FeedClient` stubbable-behaviour pattern)

## Goal

Make published articles searchable: index them into Meilisearch (typo-tolerant, faceted),
keep the index in sync via Oban jobs on article changes, expose a live `/search` LiveView
with category/tag facets, and fall back to a Postgres query when Meilisearch is unavailable.

## Decisions

| Decision | Choice |
|----------|--------|
| Meili client | Small **`req`-based `Verscienta.Search.Client`** (we use few endpoints); no third-party Meili lib |
| Index sync | **Oban jobs** enqueued from Ash after-action hooks (upsert on publish/update; delete on archive/unpublish/delete) |
| Indexed doc | `title`, `excerpt`, **`body_text`** (plain text from blocks), `tags` + `tag_slugs`, `category`, `aggregated?`, `published_at`, `slug` — **published articles only** |
| Searchable | `[title, excerpt, body_text, tags]`; filterable `[category, aggregated?, tag_slugs]`; sortable `[published_at]` |
| Search UI | `/search` LiveView: live (debounced) query, category + tag facets with counts, Codex cards |
| Fallback | **Postgres ILIKE** on title/excerpt when Meili errors (body_text only lives in Meili) |
| Bootstrap | Boot-time `Index.setup/0` that **no-ops if Meili unreachable** (never blocks boot) + `mix verscienta.reindex` |
| Admin reindex button | **Deferred** (mix task only this subsystem) |

## Section 1: Meili client & index management

`Verscienta.Search.Client` — a thin `req` wrapper over the Meili HTTP API, reading
`Application.get_env(:verscienta, :meilisearch_url)` and `:meilisearch_key` (Bearer auth).
A behaviour so it can be stubbed in tests:
- `@callback search(index, params :: map) :: {:ok, map} | {:error, term}`
- `@callback add_documents(index, [map]) :: {:ok, map} | {:error, term}`
- `@callback delete_document(index, id) :: {:ok, map} | {:error, term}`
- `@callback update_settings(index, map) :: {:ok, map} | {:error, term}`
- `@callback create_index(index, primary_key) :: {:ok, map} | {:error, term}`
The default impl is `Verscienta.Search.Client.Req`; tests configure
`config :verscienta, :search_client, <stub>` (mirrors the aggregation `FeedClient` pattern).

`Verscienta.Search.Index`:
- `@index "articles"`.
- `settings/0` returns the settings map: `searchableAttributes`, `filterableAttributes`,
  `sortableAttributes` (see decisions).
- `setup/0` — create the index (ignore "already exists") then apply settings. Returns
  `:ok | {:error, reason}`; **never raises**. Called at boot (guarded) and by the reindex task.

## Section 2: Document builder + sync

`Verscienta.Search.Document.build(article)` → flat map with string/!-friendly keys:
```
%{
  "id" => article.id,
  "title" => article.title,
  "excerpt" => article.excerpt || "",
  "body_text" => blocks_to_text(article.blocks),
  "tags" => Enum.map(article.tags, & to_string(&1.name)),
  "tag_slugs" => Enum.map(article.tags, & &1.slug),
  "category" => to_string(article.category),
  "aggregated" => article.aggregated?,
  "published_at" => DateTime.to_unix(article.published_at || now),
  "slug" => article.slug
}
```
`blocks_to_text/1` extracts plain text from the block tree (paragraph/heading/blockquote/
list items/markdown source/callout text/code; skip divider/image/embed). It is a **new,
small, pure function** in the Search namespace (not the renderer — renderer produces HTML;
this produces plain text). Markdown block source is included as-is (plain enough for search).

**Sync.** Add a `Verscienta.Content.Article.Changes.EnqueueIndex` after-action change attached
to `:create`, `:update`, `:publish`, `:archive`, `:create_aggregated`. It enqueues
`Verscienta.Search.Workers.IndexArticleWorker` with `%{"article_id" => id, "op" => "upsert" | "delete"}`:
- `op` is `"upsert"` when the resulting article `status == :published`, else `"delete"`.
The worker:
- `"upsert"` → load the article (+ tags), `Document.build`, `Client.add_documents("articles", [doc])`.
- `"delete"` → `Client.delete_document("articles", id)`.
- Unique on `[:article_id]` (collapse rapid edits); idempotent; on Meili error the job
  retries (max_attempts) — search lag on outage is acceptable.
- If the article was deleted from the DB before the job runs, treat as delete.

(Article hard-delete is not currently an action; unpublish via `:archive` covers removal.
A future `:destroy` would attach the same change.)

## Section 3: Search service + Postgres fallback

`Verscienta.Search.search(query, opts \\ [])` — `opts`: `:category` (atom|nil),
`:tags` (list of tag slugs), `:page` (1-based), `:per_page` (default 20).
- Builds Meili filter from category + tag_slugs; requests `facets: ["category", "tag_slugs"]`,
  pagination (`offset`/`limit`), and the query.
- On `{:ok, resp}`: returns
  `%{hits: [...docs...], facets: %{"category" => %{...counts}, "tag_slugs" => %{...}}, total: n, page: p, source: :meili}`.
- On `{:error, _}`: **fallback** to `search_postgres/2` — an Ash/Ecto query over published
  articles filtering `ILIKE '%query%'` on title/excerpt (+ category filter if given; tag
  filter via the join when feasible, else skipped), newest first, paginated. Returns the
  same shape with `facets: %{}` and `source: :postgres`.
- Empty/blank query in fallback returns latest published (so the page isn't empty).

Hits are plain maps from Meili (already-flat docs); the LiveView renders from these (it does
NOT reload each Article — title/slug/excerpt/category are in the doc). The PG fallback maps
Article structs into the same hit shape.

## Section 4: Search LiveView

`/search` → `VerscientaWeb.SearchLive` (`on_mount :live_user_optional`). Codex dark canvas.
- **Query input**: debounced `phx-change="search"` (≈250ms via `phx-debounce`); the current
  query/filters live in assigns and (optionally) the URL query string via `push_patch` so
  searches are shareable. URL params hydrate on mount/handle_params.
- **Facets**: a row/sidebar of the 8 categories (each with a count when `source: :meili`) and
  the top N tags from the facet response; clicking toggles that filter and re-queries. Active
  filters are shown with a clear-all. When `source: :postgres`, facet counts are hidden and a
  subtle "limited results (search service unavailable)" note shows.
- **Results**: Codex `news_card`s (category accent) linking to `/articles/:slug`; total count;
  empty-state copy when no query / no results.
- **Nav**: add a `search` link to the top strip (visible to everyone).

## Section 5: Bootstrapping & backfill

- **Boot:** a tiny guarded call (in `application.ex` via a `Task` or a `Verscienta.Search.Setup`
  child) runs `Index.setup/0`; failures log a warning and are swallowed (Meili may be down or
  starting). Skipped entirely in `:test`.
- **Reindex task:** `mix verscienta.reindex` — streams all published articles (+ tags),
  builds docs, batches `add_documents`, after ensuring `Index.setup/0`. Prints a count.
- **Seeds:** optionally call the reindex logic in dev seeds after creating demo content
  (guarded; no-op if Meili down).

## Section 6: Testing

All tests **stub the Meili client** (`config :verscienta, :search_client, StubModule`); no live
Meili. Oban `testing: :manual`.

- **Document (DataCase):** `build/1` flattens blocks→`body_text` (paragraph/heading/markdown/
  list/callout included; divider/image/embed excluded), includes tag names + slugs, category
  string, unix `published_at`. `blocks_to_text/1` unit cases.
- **Index:** `settings/0` payload has the right searchable/filterable/sortable keys; `setup/0`
  returns `:ok` with a stub and `{:error, _}`/no-raise when the stub errors.
- **Sync change + worker:** publishing an article enqueues an `IndexArticleWorker` upsert;
  archiving enqueues a delete; `perform/1` upsert calls `add_documents` with the built doc;
  delete calls `delete_document`; unique opts present. (Use `Oban.Testing` + a recording stub.)
- **Search service:** with a stub returning hits+facets, `search/2` maps hits, facet counts,
  total, `source: :meili`, and applies category/tag filters to the Meili params. With a stub
  that errors, `search/2` falls back: `source: :postgres`, ILIKE matches a seeded published
  article, drafts excluded, blank query returns latest published.
- **LiveView (ConnCase):** `/search` renders; typing updates results (stub); toggling a
  category facet adds the filter (assert the stub received the filter / results change);
  fallback note renders when the stub errors.

Existing CI gates: `compile --warnings-as-errors`, `format --check-formatted`,
`credo --strict`, `test`. New dep: none required if `req`-based (already have `req`); if a
Meili lib is chosen instead, add it. Migrations: none (no new DB schema; fallback uses
existing `articles`/`tags`).

## Out of Scope (deferred)

- Admin "reindex" button (mix task only for now).
- Searching users, comments, or other resources (articles only).
- Synonyms, typo-tolerance tuning, ranking-rule customization, stop words.
- Highlighting/snippets in results (use excerpt).
- Postgres `tsvector` GIN index / full FTS (fallback is ILIKE title/excerpt only).
- Search analytics / popular queries / suggestions.
- Per-tag facet pagination beyond a top-N list.

## Definition of Done

- Publishing an article makes it findable at `/search` by words in its title, excerpt, body,
  or tags; archiving/unpublishing removes it from results.
- `/search` supports a live query with category + tag facets (with counts) and links results
  to the reading view.
- When Meilisearch is unavailable, `/search` still returns title/excerpt matches via Postgres
  and shows a "limited results" note; the app boots fine with Meili down.
- `mix verscienta.reindex` repopulates the index from all published articles.
- Index sync runs through Oban (retried, non-blocking); only published articles are indexed.
- All tests pass (Meili stubbed); CI green; work committed on `phase-1-search`.
