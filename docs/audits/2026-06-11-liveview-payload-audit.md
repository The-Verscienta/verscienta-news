# LiveView Diffing / Payload Audit (Historical — Verscienta standalone)

> **Scope note (added 2026-10-03, Slice 1 alignment):** This audit covered the
> **Verscienta standalone** LiveViews (`Verscienta.*` LiveViews with
> `ETS/Redis` cache entries, `Verscienta.Cache.*`, `LeaderboardLive`,
> `ActivityLive`, `Social.following_feed`, etc.). Slice 1's delivery path is
> **Kiln fired `/:slug` + `?format=json`** (Cachex ETS via `KilnCMS.Cache` /
> `KilnCMS.Firing.Cache`, PubSub for bust, no Redis) with a Svelte thin reader
> (`/`, `/article/[slug]`, `/search`); there are no Verscienta LiveView feeds
> or Leaderboards in Slice 1. Retained as historical evidence for the
> standalone prototype's payload fixes; the card-fields / stream patterns remain
> useful background but do not describe the Slice 1 overlay.

**Date:** 2026-06-11
**Phase:** 4 — Performance & Scale ("LiveView diffing/payload audit; reduce assign churn")
**Method:** swept all 29 LiveViews (plus the shared card components) for large
list assigns vs streams, full-struct assigns, re-load churn in
`handle_event`/`handle_info`/`handle_params`, and temporary-assign candidates.

## The dominant finding: heavy structs on card surfaces

Every list surface rendered 4–6 light fields per article (title, slug, excerpt,
category, published_at) but assigned **full Article structs — each carrying the
entire `blocks` JSONB body and a 768-dim `embedding` vector** (~6 KB + the whole
article body, per item, per socket). The same full structs were also serialized
into the ETS/Redis cache entries fronting those reads.

**Fix:** `Article.card_fields/0` — every attribute except `:blocks` and
`:embedding` — applied as `Ash.Query.select` on each card-surface read:

| Surface | Read |
|---------|------|
| Latest / category / group feeds | `do_list_published` / `do_list_by_category` / `do_list_by_group` (also shrinks their cache entries) |
| Trending | `Trending.load_articles/1` |
| Following feed | `Social.following_articles/5` |
| For You | items strip blocks/embedding in `to_item/1` (scoring still uses the full candidate structs — embeddings are needed there) |
| Related / semantic-similar | `Similar.similar/2` + `Related.category_fallback/3` |
| Library | `Bookmark :list_for_user` loads the article with card fields |
| Sitemap | `select [:slug, :updated_at]` — previously read the **entire published corpus as full structs** into a 1h cache entry |

A drift guard in `feed_payload_test.exs` fails when a new Article attribute is
added without deciding whether it is card-light or heavy-excluded.

## Churn fixes

- **LeaderboardLive**: `{:snapshot_written, ...}` broadcasts fire for *every*
  board; the handler refetched + re-rendered regardless of which board the
  socket showed. Now guarded to the matching scope/category/window.

## Reviewed and deliberately unchanged

- **Feed tab switches re-run `load_feed`** — correct: the reads are
  context-cached (600s, previous slice), so a tab switch is an ETS hit, and
  fresh-on-navigate is the wanted UX.
- **Streams already used correctly** on activity, comments, notifications, room
  messages (transient assigns memory by design).
- **`mark_all_read` stream reset** — streams discard server-side data, so
  re-fetch + reset is the standard pattern; one indexed 50-row query on an
  explicit click.
- **Reader comment events** re-fetch only the affected top-level comment
  subtree (not the whole tree) — needed for sanitized render + replies.
- **CategoryLive / feeds "unbounded" lists** — actually capped at
  `@feed_limit 60` in the Article module.
- **GroupLive moderation reloads, ProfileLive activity tab reload, editor
  revisions assign** — bounded, low-heat, or author-only; noted as acceptable.
  Library pagination (bookmark count is user-unbounded) is a follow-up if real
  libraries grow past ~hundreds.

## Verification

`feed_payload_test.exs` asserts every card surface returns light articles
(drift-guarded); `leaderboard_live_test.exs` asserts non-matching snapshot
broadcasts no longer refetch. Full suite green.
