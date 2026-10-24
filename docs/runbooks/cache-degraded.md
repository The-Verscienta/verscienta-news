# Cache degraded / desync

**Alert:** — (surfaces as elevated p95 / DB `queue_time` rise) · **Severity:** warning-equivalent

## Symptoms

No outage — Cachex (ETS) is in-BEAM and has no external dependency to go
"down" in the Redis sense. Degradation looks like:

- Hit rate collapses (`[:kiln_cms, :cache, :content]` telemetry: `hit` → `miss`/`error`/`coalesced` spike).
- DB `queue_time` / `query_time` rise (every `GET /:slug` and `GET /api/content/:type/:slug` now hits Postgres).
- On multi-node: one node serves stale content after a write (PubSub bust missed).

## Impact

Performance only. Fired delivery falls back to live render on cache miss
(`ContentController`); headless artifact API returns `503 + Retry-After` only
during the brief artifact-creation window, not on cache misses. Correctness is
preserved — the 60 min safety-net TTL bounds staleness.

## Diagnose

1. **Is it a miss storm or a desync?**
   - Single-node miss storm: telemetry `coalesced` rate high (many callers coalesced onto the same in-flight fetch).
   - Multi-node stale: `KilnCMS.Cache.ClusterBust` PubSub topic `kiln:cache_bust` missed (partitioned/booting node) — see `KilnCMS.Cache.ClusterBust` moduledoc.
2. **Check the cache process:**
   ```sh
   docker exec -it <app> bin/kiln_cms rpc "Cachex.stats(:kiln_cms_content_cache) |> IO.inspect()"
   docker exec -it <app> bin/kiln_cms rpc "KilnCMS.Cache.enabled?() |> IO.inspect()"
   ```
   `enabled: false` (via `config :kiln_cms, KilnCMS.Cache, enabled: false`) means every read intentionally bypasses the cache.
3. **DB pressure:**
   ```promql
   histogram_quantile(0.95, sum by (le) (rate(kiln_cms_cache_content_duration_ms_bucket[5m])))
   ```

## Mitigate

- **Single-node miss storm** — nothing to restart (no Redis). Let `Cachex.fetch` coalescing absorb the spike; check for an unbounded slug flood (the cache is capped at 10 000 entries, evented LRW reclaim 10%).
- **Stale on one node** — the writing node's local `Cachex.del` already applied (read-your-writes); other nodes missed the PubSub broadcast (at-most-once). Either wait for TTL or force a cluster-wide flush:
  ```sh
  docker exec -it <app> bin/kiln_cms rpc "KilnCMS.Cache.flush_delivery()"
  # On multi-node this broadcasts :bust_all to every node (#1138); count shown is from the rpc node only.
  ```
  Local-only alternative (mix task boots a second node — do not use in prod):
  `mix kiln.cache.flush` (dev only).
- **Cache disabled in config** — revert `enabled: false` and redeploy if it was unintentional.

## Verify

Telemetry `hit` rate recovers; p95 back under SLO (`< 50 ms` hit, `< 250 ms` miss per `kiln_cms/docs/performance.md`); DB `queue_time` normalizes.

## Prevention

- Keep the 10 000-entry cap (DoS bound on anonymous slug flood).
- No Redis/Dragonfly to tune for Slice 1 (per D1/D2). Revisit when multi-node measurement shows a shared cache is needed — until then, a CDN (`Cache-Control: public, max-age=60, stale-while-revalidate=300` + ETag) absorbs viral spikes, not a second cache tier.
- Monitor `coalesced` and `error` rates, not just hit rate — they signal the stampede and the per-key dedup failure modes.
