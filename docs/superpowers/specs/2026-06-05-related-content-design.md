# Related Content Module Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-05
**Status:** Approved
**Phase:** 3 — Intelligence & Growth · Recommendation & Personalization (slice 3 of 4)
**Depends on:** slice 2 (`Recommendations.similar/2` + article embeddings), Content (Article/Category), `Verscienta.Cache`, `ArticleReaderLive`.

## Goal

Surface semantically-related articles on the article reading page. A new cached `Recommendations.related/2` returns up to N articles for an anchor article — semantic neighbors via `similar/2` first, backfilled with same-category recents when the anchor has no embedding yet or has too few neighbors — and `ArticleReaderLive` renders them as a "related reading" grid after the article body. Per-article (not per-user). No new dependency.

## Decomposition context

Slices 1 (For You signal-based) and 2 (embeddings + pgvector) shipped. This is slice 3. Remaining: slice 4 (personalized search + For You v2 hybrid).

## Decisions

| Decision | Choice |
|----------|--------|
| Behavior | **Semantic-first** (`similar/2`) **+ same-category recent fallback** to fill N |
| Placement | Article reader page, **after the body + medical disclaimer, before the reactions/comments section** |
| Count | **4** cards (`:limit` default 4) |
| Granularity | **Per-article** (cacheable globally per article, high hit rate) |
| Caching | `related:article:<id>:limit=<n>`, TTL ~10 min, tag `"related"`; TTL-only (no fan-out invalidation) |
| Fallback query | Its **own eligibility-filtered query** (not the cached `list_by_category`) so it can't leak deactivated/anonymized authors |
| Rendering | Reuse the shared `article_grid/1` component (the one `CategoryLive` imports from `ArticleFeedLive`) |

## Section 1: `Recommendations.related/2`

New module `Verscienta.Recommendations.Related`, delegated from the context as `Recommendations.related(article, opts \\ [])` (`:limit` default 4):

1. **Semantic:** `semantic = Recommendations.similar(article, limit: n)`.
2. **Fill if short:** if `length(semantic) < n`, run a fallback query for `n - length(semantic)` more: published, non-group, non-deactivated/anonymized-author articles where `category == article.category`, `id != article.id`, and `id not in` the semantic ids, ordered `published_at desc`, with `:tags` loaded.
3. **Combine:** `semantic ++ fallback`, deduped by id, take `n`.
4. **Cache:** wrap the whole computation in `Verscienta.Cache.fetch/3` under `related:article:<id>:limit=<n>`, TTL `600_000`, tags `["related"]`. Per-article key → high hit rate, no shared-cache test race.

The eligibility filter mirrors `:list_published` / `similar/2`: `status == :published and is_nil(group_id) and is_nil(author.deactivated_at) and is_nil(author.anonymized_at)`. `similar/2` already returns `[]` for an unembedded anchor, so step 2's fallback fully populates the section in that case.

File: `lib/verscienta/recommendations/related.ex`; one-line `defdelegate related/2` in `lib/verscienta/recommendations.ex`.

## Section 2: Article-page integration

In `lib/verscienta_web/live/article_reader_live.ex`:
- `mount` assigns `related: Verscienta.Recommendations.related(article, limit: 4)` (the article is already loaded with `:tags`/`:author`; `:embedding` is a default attribute, so `similar/2` works).
- A new section in `render/1`, placed **after** the medical-disclaimer `<p>` and **before** the `<section>` that holds reactions + comments: a heading ("related reading", lowercase to match the page's style) and `<.article_grid articles={@related} />`, wrapped in `:if={@related != []}`.
- Reuse `article_grid/1` via the same import `CategoryLive` uses (`import VerscientaWeb.ArticleFeedLive, only: [article_grid: 1]` or the existing equivalent) — confirm the exact import form against `CategoryLive`.

## Section 3: Testing

- **`Recommendations.related/2`** (DataCase, `async: true`, deterministic with known embeddings — same `vec/1` helper as `similar_test`):
  - anchor with an embedding → semantic neighbors returned first;
  - anchor with **no** embedding → falls back to same-category recents (non-empty);
  - fills exactly to `:limit` when enough candidates exist;
  - excludes the anchor itself; dedupes between semantic + fallback;
  - excludes deactivated/anonymized-author articles (set `deactivated_at` via raw SQL);
  - second call hits the cache.
- **`ArticleReaderLive`**: visiting an article whose category has a published sibling (no embeddings → exercises the category fallback) renders a "related reading" section containing the sibling's title.
- Full suite + `credo --strict` + `dialyzer` green; format clean.

## Out of scope (deferred)

Personalized/search ranking (slice 4); per-user related; MMR/diversity re-ranking over neighbors; related on non-article pages; per-publish/per-embedding fan-out cache invalidation (TTL suffices).

## Definition of Done

- `Verscienta.Recommendations.Related.related/2` (semantic-first + category fallback, eligibility-filtered, deduped, capped) cached per-article; `defdelegate related/2`.
- `ArticleReaderLive` renders the 4-card "related reading" grid after the body/disclaimer, before reactions/comments, via the shared `article_grid/1`, hidden when empty.
- Tests across `related/2` (semantic + fallback + exclusions + cache) and the reader section; full suite + credo + dialyzer green.
- `docs/todo.md` related-content item checked off. No new dependency.
