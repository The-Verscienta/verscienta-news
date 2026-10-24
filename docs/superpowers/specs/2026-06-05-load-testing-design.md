# Load Testing (Feeds + Leaderboards) Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-05
**Status:** Approved
**Phase:** 2 — Social & Gamification (cross-cutting)
**Depends on:** Caching layer (PR #10 — `Verscienta.Cache`, the 4 wired feeds, the 4 count categories, `Leaderboards.cached/3`) **merged to main first**; Content/Social/Engagement/Communities/Gamification domains; Redis (dev/loadtest); Req (already a dep).

## Goal

Build an in-repo load-test harness that validates the two perf targets from `docs/todo.md` — **<50ms cached reads** and **<100ms LiveView interactions** — for feeds and leaderboards. Two halves: (1) Benchee in-process micro-benchmarks of the cached context functions (cold-vs-warm) gating warm reads at 50ms; (2) an Elixir-native concurrent HTTP hammer of the LiveView dead-render endpoints gating p95 at 100ms. Both run in a dedicated `loadtest` MIX_ENV against a deterministic ~10k-article corpus, print percentile reports, and exit non-zero on any gated breach.

## Decisions

| Decision | Choice |
|----------|--------|
| What we measure | **Both**: Benchee in-process (cached-read target) + HTTP concurrency (LiveView-interaction target) |
| Cache dependency | **PR #10 merged first**; harness builds on the merged caching layer |
| HTTP tool | **Elixir-native** `mix` task — Req + `Task.async_stream`, percentiles computed in Elixir (no new external tooling) |
| Benchee scope | Cached feed reads, cached counts, leaderboard reads (all cold-vs-warm) + raw Cache primitives |
| Dataset | **Medium**: ~5k users, ~10k articles, ~50k engagements + a `PointsEntry` history |
| Pass/fail | **Report + soft thresholds with explicit exit code** (`System.halt(1)` on breach); no CI gate yet |
| Isolation | **Dedicated `MIX_ENV=loadtest`** + separate `verscienta_loadtest` DB; Redis enabled (L2 on) |
| Determinism | Fixed derivation (`loaduser-#{i}`) so reruns are comparable; seed = clean rebuild (TRUNCATE then insert) |

## Section 1: File structure & the `loadtest` env

**New files:**
- `config/loadtest.exs` — mirrors dev: Postgres at DB `verscienta_loadtest`, Redis enabled (`Verscienta.Cache` L2 on), `start_search_setup: false`, Oban crons disabled (background workers must not perturb latency mid-run), Endpoint on port **4002** (distinct from dev's 4000).
- `lib/verscienta/load_test/seeder.ex` — builds the medium corpus deterministically + writes a fixtures reference of representative ids.
- `lib/verscienta/load_test/scenarios.ex` — single source of truth for benchmark/HTTP targets: the cached functions + representative argument sets, read from the seeded fixtures.
- `lib/verscienta/load_test/report.ex` — percentile math (`p50/p95/p99/max`), threshold comparison, formatted console table, exit-code accumulation.
- `bench/cached_reads_bench.exs` — the Benchee script (feeds, counts, leaderboards, raw cache primitives), cold + warm.
- `lib/mix/tasks/verscienta.load_test.setup.ex` — `mix verscienta.load_test.setup` → create + migrate the loadtest DB.
- `lib/mix/tasks/verscienta.load_test.seed.ex` — `mix verscienta.load_test.seed` → seed the corpus.
- `lib/mix/tasks/verscienta.load_test.bench.ex` — `mix verscienta.load_test.bench` → run the Benchee script + assert the <50ms warm-read thresholds.
- `lib/mix/tasks/verscienta.load_test.http.ex` — `mix verscienta.load_test.http` → the Req + `Task.async_stream` hammer + assert <100ms p95 / <1% error thresholds.
- `docs/load-testing.md` — runbook.

**Modified files:**
- `mix.exs` — add `{:benchee, "~> 1.3", only: [:dev, :loadtest]}`. Add a `loadtest.setup` alias if convenient. Req already present.
- `config/runtime.exs` — recognize `MIX_ENV=loadtest` for DB URL / port where env-driven (minor).
- `docs/todo.md` — check off the load-test item.

**No changes** to application code under test — the harness reads only through existing public functions. A discovered hotspot is a separate follow-up, not part of this subsystem.

## Section 2: The seeder

`Verscienta.LoadTest.Seeder.seed!/1` builds a deterministic medium corpus. Determinism (fixed derivation `loaduser-#{i}`, fixed PRNG seed, no `Math.random`-style nondeterminism) makes reruns apples-to-apples for before/after comparisons.

**Corpus (medium scale):**
- **~5,000 users** — `loaduser-1@loadtest.local` … `loaduser-5000@loadtest.local`, confirmed, a role spread (mostly `:user`; a few `:expert`/`:moderator`/`:admin`), realistic `points` totals so leaderboards have a meaningful distribution.
- **~10,000 articles** — authored across the user pool, distributed over the 8 categories, ~85% `:published` / ~15% draft/archived, `published_at` spread over the last 180 days, ~10% group-tagged.
- **~50,000 engagements** — power-law-ish skew (a minority of articles get most activity) across comments, reactions, bookmarks, reposts, follows.
- **Gamification rows** — `PointsEntry` history so the leaderboard `SUM(amount)`-grouped-windowed aggregate (the most expensive query) scans real data.
- A handful of **groups** with memberships for `list_by_group` and group-member counts.

**Fast inserts:** batched `Ash.bulk_create` (or raw `Repo.insert_all` where Ash bulk is unavailable) with `return_records?: false`, chunked ~1,000 rows/batch. The bulk path **bypasses Ash after-action hooks** (cache invalidation, search indexing, gamification event emission) — we do NOT want 50k cache-invalidation broadcasts during seed. After the bulk load: one `Cache.flush()` + one leaderboard snapshot computation.

**Reset semantics:** `seed!/1` first `TRUNCATE ... CASCADE`s the app tables (the loadtest DB is exclusively ours, so this is safe and fast), then inserts. Every seed is a clean rebuild — no "already seeded?" drift. The `setup` task wraps `ecto.create` + `ash.migrate`; the `seed` task calls `seed!/1`.

**Fixtures reference:** after seeding, the seeder writes `priv/loadtest/fixtures.json` (a plain JSON map, inspectable + git-ignored) with representative ids: a "hot" article (high engagement), a "cold" article, a mid-tier user, a populated category, a group id, leaderboard scopes/windows. `Scenarios` reads this file so benchmarks/HTTP hit realistic targets, not `id=1`. In `:tiny`/test usage the same file path is written under the test's temp area (or returned directly), so the self-tests don't depend on a prior seed run.

**Scale parameter:** `seed!(scale: :tiny | :medium)`. `:medium` is the default for real runs (~5k/10k/50k). `:tiny` (~20 users / 30 articles / 100 engagements) is for the harness's own ExUnit tests.

## Section 3: The Benchee suite (`bench/cached_reads_bench.exs`)

Each scenario runs in two states: **cold** (cache flushed immediately before the call → miss → DB → write-back) and **warm** (cache pre-filled → L1 hit). The cold/warm pair is the headline result.

**Scenario groups** (arguments selected via `Verscienta.LoadTest.Scenarios`):

| Group | Functions | Cold = | Warm = |
|-------|-----------|--------|--------|
| Feeds | `Social.trending/1`, `Article.list_published`, `Article.list_by_category`, `Article.list_by_group` | full DB query | ETS L1 hit |
| Counts | `Social.Counts.{follower_count, following_count, repost_count}`, `Engagement.Counts.{comment_count, reaction_count, bookmark_count}`, `Communities.Counts.group_member_count` | `COUNT(*)` query | ETS L1 hit |
| Leaderboards | `Leaderboards.cached/3` × {weekly, monthly, all_time} × {global, one category} | windowed `SUM` aggregate | ETS L1 hit |
| Cache primitives | `Cache.fetch` (L1 hit), `Cache.fetch` (miss → trivial loader), `Cache.invalidate_tag` with 1 / 100 / 1000 tagged keys | — | — |

**Honest cold measurement.** Benchee's `before_each` runs outside the timed window. For cold scenarios, `before_each` does `Cache.flush()` + `DEL` of the matching Redis keys, so every timed iteration is a genuine miss. Cold scenarios use a dedicated config (`time: 3`, `warmup: 0`); warm scenarios use `time: 5, warmup: 2`.

**Output.** Benchee's console formatter (we read **average + p99**). After the run, `Report` pulls warm-scenario stats from the `Benchee.Suite` struct and checks each warm read against the 50ms threshold, printing a PASS/FAIL line per scenario and accumulating breaches for the exit code.

**Asserted vs observed.** Warm reads → asserted <50ms. Cold reads → observed only (they exceed 50ms by design — the cache's reason to exist). Cache primitives → observed (characterization).

**Run env.** `MIX_ENV=loadtest mix verscienta.load_test.bench` boots the app (cache supervisor + Redis pool up), verifies the corpus is seeded (helpful error if empty), runs the Benchee script.

## Section 4: The HTTP concurrency hammer (`mix verscienta.load_test.http`)

A Req + `Task.async_stream` task hammering the **dead-render GET** of the three LiveView routes — the server-rendered HTML the mount produces before the WS upgrade, which runs the same `mount`/`handle_params` data-loading (including the cached reads) a connected interaction hits.

**Targets** (from `Scenarios`, using seeded fixture ids):
- `GET /articles` (Latest, the default tab) and `GET /articles?feed=trending` (the expensive tab)
- `GET /c/:category` for a populated category
- `GET /leaderboard?window=weekly&scope=global` and `…?window=all_time&scope=global`

**Mechanics:**
- Load profile flags: `--users N` (concurrency, default 100), `--duration S` (seconds, default 30) OR `--requests N` (fixed count). Parsed by the task.
- `Task.async_stream(stream, fn _ -> time_request(url) end, max_concurrency: users, ordered: false, timeout: :infinity)`; each worker loops issuing requests until the wall-clock duration elapses, recording per-request latency via `System.monotonic_time`.
- Req's Finch pool sized to the concurrency so we measure the server, not client connection starvation. Targets `http://localhost:4002` (the loadtest-env server the operator starts separately).
- Non-200s counted as errors, excluded from latency stats, reported as an error rate.

**Warm-up.** The first ~2s of requests per route are discarded so we measure steady-state with caches warm. We separately report the single "cold first hit" latency so a cache-cold page's first-request cost is visible without polluting percentiles.

**Output (per route):** request count, error count/rate, p50 / p95 / p99 / max, requests/sec, then PASS/FAIL vs p95 < 100ms.

**Two-process setup.** Hammer and server are separate OS processes (operator: `MIX_ENV=loadtest mix phx.server` in terminal A; `MIX_ENV=loadtest mix verscienta.load_test.http …` in terminal B) so they don't compete for BEAM schedulers. An optional `--self-managed` flag may start a sibling-OS-process server for CI convenience, but the default assumes a running server. The runbook documents the two-terminal flow.

## Section 5: Thresholds, reporting, testing

**Thresholds** — one tunable block in `Verscienta.LoadTest.Report`:
```elixir
@thresholds %{
  warm_cached_read_ms: 50,    # every warm Benchee read scenario
  http_p95_ms: 100,           # dead-render p95 under load, per route
  http_error_rate: 0.01       # <1% non-200 under load
}
```
Cold reads, cache primitives, and the HTTP "cold first hit" are observed, never gated.

**Reporting & exit code.** Both `bench` and `http` end with a summary table — each gated scenario gets `PASS` or `FAIL (Xms > Yms)`. Any breach → a bold failure summary naming every breach + `System.halt(1)`. Clean run → exit 0. A human reads the table; a script/CI can use the exit code later without us wiring a flaky CI job now.

**Self-correctness testing** (normal `test` env, tiny fixtures, Redis disabled):
- `Report.percentiles/1` computes p50/p95/p99 correctly on a known list.
- `Report.check/2` returns `:ok` / `{:fail, …}` correctly around the threshold boundary.
- `Scenarios` returns well-formed argument tuples.
- `Seeder.seed!(scale: :tiny)` in a DataCase test produces the expected row counts + a non-empty fixtures reference.

The Benchee script and the HTTP hammer themselves are NOT unit-tested (they are measurement tools, validated by running them); only their pure helpers are.

**Runbook (`docs/load-testing.md`):**
1. `MIX_ENV=loadtest mix verscienta.load_test.setup` (create + migrate the loadtest DB).
2. `MIX_ENV=loadtest mix verscienta.load_test.seed` (~1–2 min).
3. `MIX_ENV=loadtest mix verscienta.load_test.bench` (Benchee + warm-read gate).
4. Terminal A: `MIX_ENV=loadtest mix phx.server`; Terminal B: `MIX_ENV=loadtest mix verscienta.load_test.http --users 100 --duration 30`.
5. Reading the tables; tuning `@thresholds`; bumping scale for a heavier local pass.

All harness `mix` invocations run in Docker: `docker compose exec -e MIX_ENV=loadtest app mix …`.

## Out of scope (deferred)

- Full WebSocket-connected LiveView load (k6 phoenix extension / custom WS client).
- Distributed / multi-node load generation.
- Sustained soak / endurance tests.
- Automated perf-regression gating in CI (deferred to a Phase 4 dedicated perf runner — shared-runner numbers are too noisy to gate on now).
- Per-user personalized feed load (following / activity feeds).
- Large / 100k-scale corpus.
- Grafana / Prometheus dashboards during the run.

## Definition of Done

- `config/loadtest.exs` + a `verscienta_loadtest` DB; Benchee added as a dev/loadtest dep.
- Deterministic seeder builds the ~5k user / ~10k article / ~50k engagement corpus + a `PointsEntry` history, writes a fixtures reference; reruns are clean rebuilds; `scale: :tiny` supported for tests.
- `bench` task: cold-vs-warm Benchee across feeds, counts, leaderboards, cache primitives; gates warm reads at <50ms.
- `http` task: concurrent Req hammer across the 3 routes (5 URLs); gates dead-render p95 at <100ms and error rate <1%.
- Both tasks print a percentile report and `System.halt(1)` on any gated breach; clean runs exit 0.
- Harness pure-helpers covered by ExUnit; full suite stays green.
- `docs/load-testing.md` runbook committed; `docs/todo.md` item checked off.
- CI gates (format, compile, credo, dialyzer) green — but no CI job runs the load test itself.
