# Query Profiling & N+1 Audit — Hot Paths (Historical — Verscienta standalone)

> **Scope note (added 2026-10-03, Slice 1 alignment):** This audit profiled the
> **Verscienta standalone** hot paths (`Verscienta.*` LiveViews,
> `Social.following_feed`, `ActivityLive`, `LeaderboardLive`, etc., with
> `Verscienta.Cache.*` + `Verscienta.Support.QueryCounter`). Slice 1 hot paths
> are **Kiln fired delivery** (`KilnCMS.Cache`/`Firing.Cache`, Cachex ETS,
> PubSub bust, headless `GET /api/content/:type/:slug`), not Verscienta
> LiveView feeds. Retained as historical evidence for the standalone query
> fixes.

**Date:** 2026-06-11
**Phase:** 4 — Performance & Scale ("Query profiling + N+1 elimination across hot paths")
**Method:** static sweep of every hot request path (LiveView mounts + the context
functions they call) for per-item queries, post-loop loads, and unbounded reads;
findings confirmed by query-count measurement via the new
`Verscienta.Support.QueryCounter` telemetry helper (`test/support/query_counter.ex`)
and locked in by `test/verscienta/query_budget_test.exs`.

## Findings — fixed

### 1. Activity feeds: per-event shadowban lookups (N+1)

`Social.reject_shadowed/2` called `Moderation.Subject.shadowed?/2` — an
`Ash.get` — once per activity event. Every activity surface paid it:
`ActivityLive` (global + personal, 50 events), `ProfileLive` activity tab
(50 events). Measured: **10 queries for 8 events** on `global_activity/1`.

**Fix:** new batched `Moderation.Subject.shadowed_ids/2` (one `id in ^ids and
moderation_status == :shadowed` query per subject type, non-uuid ids skipped for
parity with the single-id lookup) consumed by `reject_shadowed/2`. Now **3
queries for any number of events** (events read + actor load + shadow batch).

### 2. `Social.following_feed/2`: unbounded reads trimmed in memory

Three problems in one function:
- the articles branch loaded **every** matching published article (full rows +
  tags), sorted in memory, then took `limit`;
- followed tags ran a **separate unbounded query** materializing every tagged
  article id into an `id in ^ids` list;
- the reposts branch loaded **every** repost by followed users (with article +
  user hydration), then rejected ineligible ones in memory.

Measured: 6 candidate articles + 6 reposts with `limit: 3` fetched **6 rows per
branch**; production worst case is a follower of prolific authors/categories
fetching thousands of rows per feed render.

**Fix:** each branch now sorts and limits in SQL (`published_at desc_nils_last`
/ `inserted_at desc`), the tags condition is folded into the main filter as
`exists(tags, id in ^tag_ids)`, and repost eligibility (article published /
visible / public / exists) moved into the join filter. Fetching the newest
`limit` of each kind is sufficient for the merged top-`limit`. Behavioral nuance:
articles are DB-sorted by `published_at` (nils last) rather than the in-memory
`published_at || inserted_at` — identical for real data, since publishing always
stamps `published_at`.

## Findings — verified clean (no change)

| Path | Why it's fine |
|------|---------------|
| `ArticleReaderLive` | comments preload `[:user, replies: [:user]]` in-query; mention handles, reported-comment ids, reaction counts are each one batched query; bookmark/repost/reaction state are single bounded lookups |
| `NotificationsLive` / bell | notifications read loads `:actor` in-query; unread count is one `count` |
| `LeaderboardLive` | entries hydrate users with a single `id in ^ids` read (and boards come from the cache/materialized view) |
| `LibraryLive` | `:list_for_user` action preloads `:article` |
| `GroupsLive` / `GroupLive` | `Ash.load!` on a **list** batches: `:member_count` aggregate and member `:user` loads are one query each, not per-item |
| `RoomLive` | `recent_messages` loads `:user` in-query, bounded at 50 |
| `SearchLive` | hits come from Meilisearch documents (no per-hit DB access); personalized re-rank batch-loads embeddings for the window |
| `ProfileLive` | three bounded count queries + one batched user load for follower lists |
| `Recommendations` (for_you/related) | candidate pool is one bounded query; per-user engagement exclusions are 5 bounded queries behind a 1h cache; related is cached per-article |

## Regression protection

`test/verscienta/query_budget_test.exs` (async: false — telemetry is
node-global) asserts:
- `global_activity/1` ≤ 4 queries with 8 events;
- `personal_activity/2` ≤ 5 queries with 7 events;
- `following_feed/2` ≤ 7 queries **and no single query fetching more rows than
  the requested page** (12 candidates, page of 3).

When adding a new hot-path list render, add a budget test next to these.
