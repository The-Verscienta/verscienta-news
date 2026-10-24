# Materialized Views for Heavy Aggregates Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-11
**Status:** Approved
**Phase:** 4 — Polish, Monetization & Scale (Performance & Scale)
**Depends on:** Phase 2 caching layer (`Verscienta.Cache`); Oban cron; hot-path indexes
(`20260610120000_add_hot_path_indexes`); `Social.Trending`; `Gamification.Leaderboards`.

## Goal

Move the two genuinely heavy *global* aggregations — trending engagement scoring and live
leaderboard score aggregation — out of the request path and into Postgres materialized
views refreshed on a 5-minute Oban cron. Read paths become cheap indexed lookups; the
existing cache layer stays in front as the L1/L2 tier.

## Why these aggregates (and not the others)

| Surface | Today | Materialize? |
|---------|-------|--------------|
| Trending feed tab | `Social.Trending.list/1` runs two full-table GROUP BYs (reactions, comments), loads **all** published article ids into Elixir, and sorts in memory — on every 120s cache miss | **Yes** — `mv_trending_articles` |
| Live leaderboards (current week/month/all-time, global + 8 categories) | `Leaderboards.cached/3` re-aggregates `points_entries` (and the jsonb `gamification_events` join for category boards) on every 60s cache miss × 27 boards | **Yes** — `mv_leaderboard_scores` |
| Latest / category feeds | Single indexed query (`articles_public_feed_index`) | No — nothing to aggregate |
| Following / For You feeds | Per-user (fan-in decision from Phase 2); a global MV cannot represent them, and per-user materialization is a fan-out architecture we explicitly rejected | No — stays on cache + indexes |
| Global activity feed | Indexed `ORDER BY inserted_at DESC LIMIT 50`, no aggregation | No |
| Closed-period leaderboard snapshots | Already materialized as `LeaderboardSnapshot` rows by the daily cron worker | No change — keeps using `Leaderboards.compute/4` (exact closed-window bounds) |

## Decisions

| Decision | Choice |
|----------|--------|
| Views | `mv_trending_articles` (7-day engagement score per published-visible article) and `mv_leaderboard_scores` (score + rank per window × board × user, top 100 per board) |
| Refresh | `Verscienta.MaterializedViews.RefreshWorker` (Oban, `:default` queue) on `*/5 * * * *` cron; `REFRESH MATERIALIZED VIEW CONCURRENTLY` (needs the unique indexes); `unique: [period: 60]` to avoid pileup |
| Staleness budget | ≤5 min for *appearing* in trending/leaderboards (previous caches already allowed 60–120s). **Disappearing is immediate** for moderation/privacy: the trending read re-joins `articles`+`users` and re-applies status/moderation_status/group_id/deactivated/anonymized filters at read time (cheap PK join) |
| Cache interplay | Worker invalidates `articles:trending` + `leaderboards` tags after refresh, so caches never outlive a fresher MV |
| Time semantics | All window math in SQL uses `timezone('utc', now())` against the naive-UTC `inserted_at`/`published_at` columns; weekly = `date_trunc('week', …)` (ISO Monday, matching `Date.beginning_of_week/1`), monthly = `date_trunc('month', …)` |
| Score parity | Trending: `reactions×1 + comments×2`, 7-day window, only articles with score > 0, tie-break `published_at DESC` — identical to `Social.Trending` today. Leaderboards: positive `points_entries` only; category boards join `gamification_events` on `(ref, user_id)` and read `metadata->>'category'` — identical to `Leaderboards.compute/4` |
| Board encoding | `mv_leaderboard_scores.board` is `'global'` for the global scope, else the category slug — a plain NOT NULL column so the unique index `(window, board, user_id)` is expression-free (a `CONCURRENTLY` requirement) |
| Custom windows | `Trending.list(window_days: n)` for n ≠ 7 falls back to the legacy live computation (kept as a private path); the MV serves the default window every caller uses |
| Tests | Plain (non-concurrent) `REFRESH` inside the sandbox transaction sees the test's own writes; any test that refreshes must be `async: false` (the refresh holds an ACCESS EXCLUSIVE lock until the sandbox rollback) |
| Ash | The MVs are not Ash resources; reads are schemaless Ecto queries returning ids/rows, then articles are loaded through Ash exactly as today (`load_articles/1` preserves policy-free ordering) |

## Section 1: File structure

**New files (4):**
- `priv/repo/migrations/<ts>_create_materialized_views.exs` — both views WITH DATA + indexes.
- `lib/verscienta/materialized_views.ex` — `names/0`, `refresh/2`, `refresh_all/1` (`concurrently:` option, default `false`; logs duration).
- `lib/verscienta/materialized_views/refresh_worker.ex` — Oban worker described above.
- `test/verscienta/materialized_views_test.exs` — refresh + both views' semantics.

**Modified files (5):**
- `config/config.exs` — add cron entry `{"*/5 * * * *", Verscienta.MaterializedViews.RefreshWorker}`.
- `lib/verscienta/social/trending.ex` — default-window reads hit the MV (with the read-time visibility re-check join); legacy compute kept for custom `window_days`.
- `lib/verscienta/gamification/leaderboards.ex` — new `live/3` reads the MV; `cached/3` loader uses `live/3` instead of `compute/3`. `compute/4` unchanged (snapshot worker).
- `test/verscienta/social/trending_test.exs`, `test/verscienta/social/trending_privacy_test.exs`, `test/verscienta/gamification/leaderboards_math_test.exs` — refresh the MV after seeding engagement/points.

## Section 2: View definitions (shape)

```sql
CREATE MATERIALIZED VIEW mv_trending_articles AS
WITH reaction_counts AS (
  SELECT article_id, count(*) AS n FROM reactions
  WHERE inserted_at >= timezone('utc', now()) - interval '7 days' GROUP BY article_id
), comment_counts AS (
  SELECT article_id, count(*) AS n FROM comments
  WHERE inserted_at >= timezone('utc', now()) - interval '7 days' AND deleted_at IS NULL
  GROUP BY article_id
)
SELECT a.id AS article_id,
       coalesce(r.n, 0)::bigint AS reactions_7d,
       coalesce(c.n, 0)::bigint AS comments_7d,
       (coalesce(r.n, 0) * 1 + coalesce(c.n, 0) * 2)::bigint AS score,
       a.published_at
FROM articles a
JOIN users u ON u.id = a.author_id
LEFT JOIN reaction_counts r ON r.article_id = a.id
LEFT JOIN comment_counts c ON c.article_id = a.id
WHERE a.status = 'published' AND a.moderation_status = 'visible' AND a.group_id IS NULL
  AND u.deactivated_at IS NULL AND u.anonymized_at IS NULL
  AND coalesce(r.n, 0) + coalesce(c.n, 0) > 0;
-- unique index: (article_id); sort index: (score DESC, published_at DESC)
```

```sql
CREATE MATERIALIZED VIEW mv_leaderboard_scores AS
WITH windows AS (
  SELECT 'weekly' AS w, date_trunc('week', timezone('utc', now())) AS start_at
  UNION ALL SELECT 'monthly', date_trunc('month', timezone('utc', now()))
  UNION ALL SELECT 'all_time', NULL
), global_scores AS (
  SELECT w.w, 'global' AS board, p.user_id, sum(p.amount)::bigint AS score
  FROM windows w JOIN points_entries p ON (w.start_at IS NULL OR p.inserted_at >= w.start_at)
  WHERE p.amount > 0 GROUP BY w.w, p.user_id
), category_scores AS (
  SELECT w.w, e.metadata->>'category' AS board, p.user_id, sum(p.amount)::bigint AS score
  FROM windows w
  JOIN points_entries p ON (w.start_at IS NULL OR p.inserted_at >= w.start_at)
  JOIN gamification_events e ON e.ref = p.source_ref AND e.user_id = p.user_id
  WHERE p.amount > 0 AND e.metadata->>'category' IS NOT NULL
  GROUP BY w.w, e.metadata->>'category', p.user_id
), ranked AS (
  SELECT *, row_number() OVER (PARTITION BY w, board ORDER BY score DESC, user_id) AS rank
  FROM (SELECT * FROM global_scores UNION ALL SELECT * FROM category_scores) s
)
SELECT w AS window, board, user_id, score, rank::integer FROM ranked WHERE rank <= 100;
-- unique index: (window, board, user_id); sort index: (window, board, rank)
```

Both views are created `WITH DATA` so `CONCURRENTLY` works from the first cron run and
reads never see an unpopulated view.

## Section 3: Read paths

- `Social.Trending.list/1` (default window): select `article_id` from the MV joined to
  `articles` + `users` re-applying the visibility/privacy predicates, `ORDER BY score
  DESC, published_at DESC NULLS LAST, LIMIT n`, then `load_articles/1` as today. The
  public `Social.trending/1` cache wrapper (120s, tag `articles:trending`) is unchanged.
- `Leaderboards.cached/3`: loader becomes `live/3` — `WHERE window = ? AND board = ?
  ORDER BY rank LIMIT 100`, normalizing uuid/score exactly like `compute`'s rows. The 60s
  cache + `leaderboards` tag are unchanged; the snapshot worker keeps `compute/4`.

## Error handling

- The refresh worker lets Oban retry (max_attempts 3) on transient DB errors; `CONCURRENTLY`
  refreshes never block readers.
- Read paths do not rescue: the migration guarantees the views exist and are populated.
- Rank-up notifications, snapshots, and closed-period math are untouched (still `compute/4`
  over the source tables), so MV staleness can never corrupt awarded history.
