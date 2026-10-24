# High latency

**Alert:** `KilnHighLatencyP95` / `VerscientaHighLatencyP95` (legacy name) · **Severity:** warning

## Symptoms

p95 request duration above 1s for 10+ minutes.

## Impact

Site feels slow; timeouts and error rate may follow if it worsens.

## Diagnose

1. **Which routes are slow?**

   ```promql
   topk(5, histogram_quantile(0.95, sum by (le, path) (
     rate(verscienta_prom_ex_phoenix_http_request_duration_milliseconds_bucket[5m]))))
   ```

2. **Database?** Grafana Ecto dashboard. `queue_time` rising → connection
   pool exhaustion ([postgres-issues](postgres-issues.md)). `query_time`
   rising → slow queries; find them with `pg_stat_statements` / `EXPLAIN`.
3. **Cache?** Telemetry `[:kiln_cms, :cache, :content]` (Explore:
   `kiln_cms_cache_content_duration_ms` / hit/miss/coalesced/error counts) —
   a collapsed `hit` rate or spike in `coalesced`/`error` means the DB is
   absorbing the cache's load ([cache-degraded](cache-degraded.md)); there is
   no Redis L2 (`KilnCMS.Cache` is Cachex ETS, per D1/D2).
4. **BEAM?** Grafana BEAM dashboard — run-queue lengths and memory. Sustained
   high run queues → CPU saturation (undersized host or runaway work).
5. **Background load?** Oban dashboard — a large aggregation/AI batch can
   compete for DB connections and CPU.

## Mitigate

- Pool exhaustion → raise `POOL_SIZE` (env) within Postgres `max_connections`
  headroom; restart.
- One pathological query → fix or add index; as a stopgap, gate the feature
  via its feature flag if it has one.
- Host saturation → scale the container/host up in Coolify.

## Verify

p95 back under 1s for 10+ minutes (alert resolves); the route-level
histogram quantile confirms the offending route recovered.

## Prevention

Load tests are the Kiln benchmark harness (`scripts/benchmarks/api_latency.sh`
— see `docs/load-testing.md` and `kiln_cms/docs/benchmarks.md`) — re-run
after fixes to confirm headroom against the Slice 1 SLOs (hit `< 50 ms`,
headless API `< 50 ms` — no sub-100 ms LiveView claim). Watch the Ecto
dashboard after schema/feature changes that add queries to hot paths.
