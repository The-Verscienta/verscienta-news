# Load Testing (Slice 1)

## Current targets (Slice 1)

Slice 1's performance targets are the **Kiln delivery SLOs** — not the old
Verscienta standalone "sub-100 ms LiveView interactions" claim, which is
**removed** for this overlay. Kiln's measured baselines are in
[`kiln_cms/docs/benchmarks.md`](../kiln_cms/docs/benchmarks.md) and the SLO
table in [`kiln_cms/docs/performance.md`](../kiln_cms/docs/performance.md).

| Surface | p95 target (origin-side) | Baseline (Kiln v1.0, `scripts/benchmarks/api_latency.sh`) |
|---|---|---|
| Public HTML — cache **hit** | < 50 ms | 0.1–0.3 ms warm (hit does zero DB work) |
| Public HTML — cache **miss** | < 250 ms | not yet measured (live render) |
| Headless API — fired artifact (`GET /api/content/:type/:slug`) | < 50 ms | 2–7 ms p95 @ 50 clients (by-slug); 40–43 ms p95 @ 50 clients (JSON:API list — slowest) |
| Editor publish response | < 2 s | not yet measured (enqueues `Firing.FireWorker`) |

**Harness:** `scripts/benchmarks/api_latency.sh` (`MIX_ENV=prod`, closed-loop,
1/10/50 clients, cold vs warm, server-side `[:phoenix, :endpoint, :stop]`).
See `kiln_cms/docs/benchmarks.md` for the full result table and run
instructions. Search and sync targets are separate (search misses from 10
clients; sync initial page misses from 10 — tracked in Kiln #1712/#1713).

> **No sub-100 ms LiveView claim:** the old Verscienta standalone
> `docs/todo.md` / `docs/audits/2026-06-11-perf-target-verification.md`
> gating on `<100 ms LiveView dead-render p95` described a different
> application (standalone `Verscienta.*` with Redis/ETS two-tier cache and
> Leaderboard LiveViews). That stack — `Verscienta.Cache.Redis`, `REDIS_URL`,
> `Leaderboards`, `Social.trending` — does not exist in this overlay
> (`Cachex`/`Hammer`/`Phoenix.PubSub`, no Redis, no Leaderboards in Slice 1).
> Keep that audit as historical context for the standalone prototype; do not
> gate Slice 1 exit on it.

## What Slice 1 actually validates

- **Fired delivery cache hits are < 50 ms p95** — the hot path (`KilnCMS.Cache`
  → `KilnCMS.Firing.Cache`, both Cachex ETS) serves the record + enriched
  blocks + translations with zero queries. Telemetry is
  `[:kiln_cms, :cache, :content]` tagged `hit`/`miss`/`coalesced`/`error`.
- **Headless API stays < 50 ms p95** for by-slug reads at 50 concurrent
  clients — the Svelte thin reader's contract (`?format=json`).
- **Cache invalidation is precise** — `BustContentCache` on content writes;
  multi-node via `KilnCMS.Cache.ClusterBust` PubSub broadcasts
  (`:bust_keys`/`:put_keys`/`:bust_prefix`/`:bust_all`). Purge is
  best-effort at-most-once; TTL (60 min) remains the guarantee.
- Search/personalization/leaderboard load is **out of scope** for Slice 1
  (Kiln Postgres FTS only; no Meilisearch/pgvector/For You/leaderboards).

## Running the Kiln benchmark harness

```sh
# From kiln_cms checkout (or the overlay's pinned kiln_cms/):
MIX_ENV=prod POOL_SIZE=10 mix phx.server &
# In another shell:
scripts/benchmarks/api_latency.sh              # ~10 min on warm _build/prod
BENCH_PROFILE=search,sync_initial scripts/benchmarks/api_latency.sh
```

Corpus, machine, and load details are in `kiln_cms/docs/benchmarks.md`. The
benchmark raises `POOL_SIZE` limits via
`config :kiln_cms, KilnCMSWeb.RateLimit, limits:` on the running node —
nothing is disabled in code.

## Legacy Verscienta harness (historical — not Slice 1 gate)

A previous in-repo harness validated two different targets for the standalone
prototype:

- **< 50 ms cached reads** — Benchee warm L1 hits of `Social.trending`,
  `Article.list_*`, 7 cached counts, `Leaderboards.cached` (all
  `Verscienta.*` — not in this overlay).
- **< 100 ms LiveView dead-render p95** — concurrent hammer of
  `GET /articles`, `/c/:category`, `/leaderboard` (all standalone routes).

That harness lived under `bench/cached_reads_bench.exs` and
`mix verscienta.load_test.*` (`MIX_ENV=loadtest`, isolated
`verscienta_loadtest` DB, `redis` L2 on, Oban/search off). **Do not use it
to gate Slice 1** — the modules, routes, and Redis L2 it measured no longer
exist. The files are retained only as audit history; the Slice 1 gate is the
Kiln `api_latency.sh` harness above.

### If you still need to run the legacy harness locally

Prerequisites then were `app`, `db`, `redis` via Docker Compose and
`MIX_ENV=loadtest`. They are documented here only for forensic replay of the
`2026-06-11-perf-target-verification.md` audit, not for Slice 1 verification.

## Interpreting results

- A human reads the tables; the harness exit code lets CI consume them later.
- A discovered hotspot is a **separate follow-up**, not part of the harness —
  no application code under test is modified by the harness.
- For quota/pool tuning, see `kiln_cms/docs/performance.md` (Oban queue
  concurrency vs `POOL_SIZE`).

## What's covered by tests

The Kiln delivery-cache and performance tests live in the Kiln core test
suite. Overlay-specific caching/moderation coverage lives under
`test/verscienta_news/` (ingestion, source-rights, moderation).

## Out of scope (deferred past Slice 1)

WebSocket-connected LiveView load of Verscienta standalone routes,
distributed/multi-node generation, sustained soak tests, automated CI
perf-gating of the old LiveView targets, personalized-feed load, and live
Grafana/Prometheus dashboards for the overlay's headless API. See the Kiln
benchmark docs for what's deferred there.
