# Redis down — REMOVED (Slice 1)

> **This runbook is retained as a stub for historical links only.**
> Slice 1 has **no Redis / Dragonfly**. The stack is
> **Cachex (ETS) + Hammer (ETS) + Phoenix.PubSub (pg)** per Kiln D1/D2.

- Cache: `KilnCMS.Cache` (Cachex ETS, `max_entries: 10_000`, 60 min TTL backstop, precise invalidation on writes).
- Multi-node bust: `KilnCMS.Cache.ClusterBust` via `Phoenix.PubSub` topic `kiln:cache_bust` (best-effort, at-most-once; TTL remains the guarantee).
- Rate limiting: `Hammer` (ETS).
- Realtime: `Phoenix.PubSub` (pg adapter).

If you followed an old link expecting Redis remediation, see
[cache-degraded](cache-degraded.md) instead. Do not provision or configure
`REDIS_URL` — it has no effect in this codebase.

Historical note: the Verscienta standalone prototype used a two-tier
`ETS → Redis (Redix)` cache with `Verscienta.Cache.Redis` and `REDIS_URL`.
That tier was removed when the app became a KilnCMS overlay; Dragonfly is
deferred until multi-node measurement (D2).
