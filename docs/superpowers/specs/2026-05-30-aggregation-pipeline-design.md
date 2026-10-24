# Aggregation Pipeline Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-05-30
**Status:** Approved
**Phase:** 1 (MVP) — Subsystem 3 of 6
**Depends on:** Phase 0 foundation; Subsystem 1 (Auth — `User`, `:admin` role); Subsystem 2 (Content — `Article`, `Category`, `Markdown`, feed/reader/category LiveViews)

## Goal

Automatically pull articles from trusted RSS/Atom feeds into the existing content feed. A
`Source` resource describes each feed; a fetch pipeline (Oban, scheduled hourly + on-demand)
parses feeds and creates de-duplicated, published aggregated `Article`s that flow into the
existing `/articles`, `/c/:category`, and reader pages. Admins manage sources via an
admin-only LiveView. This is the project's **first use of Oban**.

## Decisions

| Decision | Choice |
|----------|--------|
| Aggregated model | **Extend `Article`** (source ref + `canonical_url` + `aggregated?`), not a separate resource |
| Author model | `Article.author` becomes **nullable**; a validation requires **author OR source** |
| Status after fetch | **Published immediately** (trusted sources; moderation is a later subsystem) |
| Feed parser | **fast_rss** (Rust NIF; RSS + Atom), fetched via existing `req` |
| Body strategy | **Link-out** — store summary + "read the original" link; do NOT scrape full text |
| Scheduling | **Oban** + cron (hourly `ScheduleFetchesWorker`); per-source `FetchSourceWorker` (unique) |
| Admin UI | Admin-only LiveView at `/admin/sources` (CRUD + activate/deactivate + fetch-now) |
| Authorization | Source mutations + admin list = `:admin` role only; aggregated Article creation runs system-context (`authorize?: false`) in the worker |
| Reader affordance | Aggregated articles show "via {source}" + "read original" in the reader |

## Section 1: `Source` resource & `Article` extensions

### `Source` (Content domain, `sources` table)
- `name` — `:string`, `allow_nil? false`, public.
- `feed_url` — `:string`, `allow_nil? false`, public; unique identity `unique_feed_url`.
- `category` — `:atom`, `allow_nil? false`, public, `one_of` the 8 `Category.keys()` (default category for the source's items).
- `active?` — `:boolean`, `allow_nil? false`, default `true`, public.
- `last_fetched_at` — `:utc_datetime_usec`, nullable.
- `last_status` — `:atom`, `allow_nil? false`, default `:never`, `one_of [:never, :ok, :error]`.
- `last_error` — `:string`, nullable.
- `create_timestamp :inserted_at`, `update_timestamp :updated_at`.
- `has_many :articles, Article`.

### `Article` extensions
- `belongs_to :source, Verscienta.Content.Source` (`allow_nil? true`).
- `canonical_url` — `:string`, nullable, **unique identity `unique_canonical_url`** (the dedupe key; nullable so authored articles don't collide — see note).
- `aggregated?` — `:boolean`, `allow_nil? false`, default `false`, public.
- `author` relationship changes from `allow_nil? false` to **`allow_nil? true`**.
- **Validation** (on create/update): require `author_id` is present OR `source_id` is present (an article must have a human author or a feed source). Authored-article actions still set the author via `relate_actor`, so they satisfy it.

**Unique-canonical_url note:** Postgres treats `NULL`s as distinct, so multiple authored articles with `canonical_url = NULL` do not collide; only aggregated items (which always set it) are de-duplicated. Confirm the generated unique index permits multiple nulls (default Postgres behavior — yes).

## Section 2: Fetch + ingest pipeline

`Verscienta.Aggregation.Fetcher.fetch_source(source)`:
1. HTTP GET `source.feed_url` via `req` (sane timeout; follow redirects). On transport/HTTP error → record `:error` + message, return `{:error, reason}`.
2. Parse the body with **fast_rss** → a list of entries (title, link, summary/description, published date). On parse error → record `:error`, return `{:error, reason}`.
3. For each entry, upsert an aggregated Article:
   - `canonical_url` = entry link. **Dedupe:** if an Article with that `canonical_url` exists, skip. (Unique index is the hard guard; pre-check avoids needless inserts.)
   - `title` = entry title (trimmed, required; skip entries with no title/link).
   - `excerpt` = summary text, HTML-stripped + truncated to ≤300 chars.
   - `blocks` = a single `markdown` block: the summary text plus `\n\n[Read the original →](<canonical_url>)`.
   - `category` = `source.category`; `aggregated? = true`; `source_id = source.id`; `author_id = nil`; `status = :published`; `published_at` = entry published date or `DateTime.utc_now()`.
   - Created via the Article `:create_aggregated` action with `authorize?: false`.
4. Record success: set `last_fetched_at = now`, `last_status = :ok`, `last_error = nil`. Return `{:ok, %{new: n, skipped: m}}`.

**HTML stripping:** summary HTML is reduced to text before storage (a small `strip_html/1` helper — regex/entity-decode is acceptable since the result is plain text re-wrapped in a markdown block that `BlockRenderer` re-sanitizes on render). No raw HTML is persisted.

A dedicated Article action `:create_aggregated` accepts `title, excerpt, blocks, category, canonical_url, source_id, published_at` and forces `aggregated?: true`, `status: :published`, `author_id: nil`; it runs the same `Block.cast_all` on blocks. It does NOT use `relate_actor` (no actor).

## Section 3: Oban jobs & scheduling

Add **Oban** (`{:oban, "~> 2.x"}`), configured with the repo, queues `default: 10` and `aggregation: 5`, and the cron plugin. Generate the Oban migration via `mix ecto.gen.migration` per Oban docs (or `mix oban.install` if available) and migrate.

- `Verscienta.Aggregation.FetchSourceWorker` (queue `:aggregation`) — args `%{"source_id" => id}`. Loads the source, calls `Fetcher.fetch_source/1`. **Unique** on `source_id` (e.g. `unique: [keys: [:source_id], period: 60, states: [:available, :scheduled, :executing]]`) so a source isn't fetched twice concurrently. Idempotent (dedupe).
- `Verscienta.Aggregation.ScheduleFetchesWorker` (queue `:default`) — reads all `active?` sources and enqueues a `FetchSourceWorker` per source. Wired to Oban cron `@hourly`.
- "Fetch now" (admin UI) inserts a `FetchSourceWorker` for one source.

Config: dev/prod run Oban normally; **test** uses `testing: :manual` (Oban does not execute jobs automatically — tests assert enqueues with `Oban.Testing` and/or run the fetcher directly).

## Section 4: Source actions & authorization

**Actions (`Source`)**
- `create` (accept name/feed_url/category/active?), `update` (same), `read`, `list_active` (filter `active? == true`).
- `activate` / `deactivate` (set `active?`).
- `record_fetch_result` — accepts `last_status, last_error` + sets `last_fetched_at`; used by the fetcher (system context).

**Policies (`Source`)** — authorizer `Ash.Policy.Authorizer`:
- `create`/`update`/`activate`/`deactivate`/`read`/`list_active` → `authorize_if expr(^actor(:role) == :admin)`.
- `record_fetch_result` → only system context; allow via a bypass for `authorize? == false` calls (the fetcher uses `authorize?: false`), so no policy grants it to actors.

**Article** — add the `:create_aggregated` action; it's only invoked with `authorize?: false` from the worker. Existing Article policies are unchanged for human actions. (The new `aggregated?`/`canonical_url`/`source_id` are not in the human `:create`/`:update` accept lists, so users can't set them.)

## Section 5: Admin UI

`/admin/sources` — `AdminSourcesLive` (`on_mount :live_user_required`; mount also checks `current_user.role == :admin`, else raises a 404 `NotFound`). Codex-styled dark canvas.
- **Table:** name, feed_url, category, active?, last_status + last_fetched_at (relative), last_error (if any).
- **Add/edit** via `AshPhoenix.Form` over `Source.create`/`update` (fields: name, feed_url, category select, active? checkbox).
- **Per-row actions:** "fetch now" (inserts `FetchSourceWorker`, flash "Queued"), activate/deactivate toggle.
- Route in the authenticated live session.

**Reader affordance:** `ArticleReaderLive` — when `@article.aggregated?`, show a "via {source.name}" line and a "read the original →" link to `canonical_url` (load the `:source` relationship). Authored articles render unchanged.

**Nav:** add an `admin` link in the top strip's signed-in branch, shown only when `current_user.role == :admin`, pointing to `/admin/sources`.

## Section 6: Testing

**Source resource (DataCase)**
- CRUD; `list_active` excludes inactive.
- Admin-only: a non-admin actor is forbidden from create/update/read; an admin succeeds.
- `record_fetch_result` updates the last_* fields.

**Fetcher (DataCase, NO network)**
- Given a parsed-feed fixture (or a stubbed `req` via a small injectable client / `Req.Test`), creates aggregated Articles with correct fields (`aggregated?`, `source_id`, `canonical_url`, category, status published, markdown block with the read-original link).
- Dedupe: running twice over the same feed creates items once (second run all skipped).
- Summary HTML is stripped (a `<script>`/tags in a summary don't appear as raw HTML in stored excerpt/block).
- Fetch error path: a stubbed error response sets `last_status: :error` + `last_error`, creates no articles.
- Entries missing title or link are skipped.

**Worker**
- `FetchSourceWorker.perform/1` with a source id calls the fetcher (use `Req.Test` stub or a fetcher seam) and records results; uniqueness opts present.
- `ScheduleFetchesWorker` enqueues one `FetchSourceWorker` per active source (assert with `Oban.Testing.assert_enqueued`).

**Admin LiveView (ConnCase)**
- Non-admin (or signed-out) cannot access `/admin/sources` (redirect/404).
- Admin sees the source list; can add a source; "fetch now" enqueues a `FetchSourceWorker` (`assert_enqueued`).

**Reader**
- An aggregated article shows "via {source}" + a read-original link; an authored article does not.

**Config:** Oban `testing: :manual` in `config/test.exs`; HTTP stubbed (no real network in tests). Existing CI gates apply (`compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, `test`). Migrations via `mix ash.codegen` (resources) + the Oban migration.

## Out of Scope (deferred)

- Full-text scraping / readability extraction (link-out only).
- AI summarization / auto-tagging / quality scoring of aggregated items (Phase 2).
- Non-RSS sources (REST APIs, scraping arbitrary sites).
- Per-source category mapping rules / keyword routing (single category per source for now).
- Image/enclosure ingestion to Cloudflare (Phase 2; aggregated items have no cover image for now, or use the feed's image URL as `cover_image_url` only if trivially present).
- Moderation/review queue for aggregated items (Moderation subsystem).
- Oban Web dashboard (can add later).

## Definition of Done

- An admin can add an RSS/Atom source at `/admin/sources`, click "fetch now", and see new aggregated articles appear in `/articles` and the source's category page, each linking to the original.
- Re-fetching the same feed adds no duplicates (dedupe on `canonical_url`).
- Fetches run automatically hourly via Oban cron; per-source jobs don't run concurrently.
- A failed fetch records `last_status: :error` + `last_error` on the source and creates no articles.
- Source management is admin-only; aggregated articles never have a human author but always have a source (validation enforced).
- Aggregated articles show their source + a read-original link in the reader.
- All tests pass; CI green; migrations (Ash + Oban) committed on `phase-1-aggregation`.
