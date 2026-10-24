# Perf Target Verification — Phase 4 (Historical — Verscienta standalone)

> **Scope note (added 2026-10-03, Slice 1 alignment):** This audit verified the
> **Verscienta standalone** Phoenix app (`Verscienta.*`, `MIX_ENV=loadtest`,
> `verscienta_loadtest` DB, **Redis L2 via Redix**, Ash, LiveView feeds +
> leaderboards). That application no longer exists as the delivery path —
> Slice 1 is a **KilnCMS overlay** (`KilnCMS.*` + `VerscientaNews.Catalog`,
> **Cachex ETS + Hammer ETS + Phoenix.PubSub**, no Redis per D1/D2, Kiln
> Postgres FTS, no Leaderboards). **Do not gate Slice 1 exit on the
> `<100 ms LiveView` gate below** — Slice 1's gates are Kiln SLOs
> (hit `< 50 ms`, headless API `< 50 ms` p95) measured by
> `scripts/benchmarks/api_latency.sh` (see `kiln_cms/docs/benchmarks.md`,
> `kiln_cms/docs/performance.md`, and `docs/load-testing.md`).
> Retained as historical evidence for the standalone prototype only.

**Date:** 2026-06-11
**Phase:** 4 — Performance & Scale ("Verify perf targets: <100ms LiveView interactions, <50ms cached reads")
**Code under test:** the full Phase 4 perf stack — materialized views, N+1
elimination, aggressive caching (all on main via #35) + the LiveView payload
audit branch (#37).
**Harness:** the in-repo load-test harness (`docs/load-testing.md`), medium
corpus (5,000 users / 10,020 articles / ~50k engagements / 15k points entries),
`MIX_ENV=loadtest`, isolated `verscienta_loadtest` DB, Redis L2 on (standalone — not Slice 1).
**Environment:** single dev Docker container (Windows 11 host), hammer and
server sharing the container's CPUs — capacity numbers are a floor, not a
production statement.

## Verdict

| Target | Result |
|--------|--------|
| **<50ms cached reads** (warm p99, gated) | **PASS 18/18** — worst 0.53ms, ~100× headroom |
| **<100ms LiveView interactions** (dead-render p95, gated) | **PASS at 25 concurrent users (10/10)**; 9/10 at 50; at 100 users the single dev container saturates (4 routes breach on tail latency while medians stay 7–68ms and errors stay 0%) |

## Gate 1 — cached reads (Benchee, warm p99 < 50ms): PASS 18/18

| Scenario | warm p99 |
|----------|----------|
| counts: bookmark / comment / follower / following / group_member / reaction / repost | 0.02–0.07 ms |
| feed: for_you / trending / list_by_group | 0.13–0.22 ms |
| feed: list_published / list_by_category | 0.51 / 0.53 ms |
| leaderboards: {global, category} × {weekly, monthly, all_time} | 0.07–0.12 ms |

Observed-only primitives: L1 hit ≈ 5µs; trivial miss ≈ 0.6ms; `invalidate_tag`
≈ 0.7ms @ 1 key, 0.9ms @ 100 keys, 4.9ms @ 1000 keys.

## Gate 2 — HTTP dead renders (p95 < 100ms, errors < 1%)

30s steady state per run, 2s warm-up discarded, 5 routes:

| Concurrency | Aggregate rps | p50 range | p95 range | Gate |
|-------------|---------------|-----------|-----------|------|
| 25 users | ~8,200 | 6.8–16.4 ms | 28.5–54.9 ms | **PASS 10/10** |
| 50 users | ~9,100 | 10.0–43.6 ms | 32.7–110.9 ms | 9/10 — only `leaderboard all_time` breaches (110.9ms) |
| 100 users | ~7,900 | 24.8–68.4 ms | 76.8–247.8 ms | 4/5 breach |

Reading the curve: rps stops growing between 50 and 100 users while tails
inflate ~3× and medians stay low — the classic signature of CPU saturation
(hammer + server share one container), not per-request slowness. Errors are 0%
at every level. The interaction-latency target is met with headroom at
moderate concurrency; the 100-user tail is this dev box's capacity ceiling,
which production sizing and the multi-node item own.

**Hotspot worth a follow-up:** `GET /leaderboard` (all_time) is consistently
the slowest route at every concurrency (p50 16 → 44 → 68ms) — it dead-renders
100 table rows per request. Candidate: render the top 25 with progressive
disclosure, or fragment-cache the table. Not a target failure; noted for the
next perf pass.

## Harness change made for this run

`LoadTest.Seeder.seed!/1` now refreshes the materialized views after seeding —
trending and live leaderboards read `mv_trending_articles` /
`mv_leaderboard_scores` since Phase 4, so without the refresh those paths would
have benched empty boards.

## Caveats / deferred (unchanged from the harness design)

Dead renders only (no WebSocket-connected interactions — the documented proxy
per `2026-06-05-load-testing-design.md`), single node, dev hardware, hammer
co-located with the server, no soak. Re-run the runbook on production-like
hardware (hammer on a separate machine) and after multi-node work lands.
