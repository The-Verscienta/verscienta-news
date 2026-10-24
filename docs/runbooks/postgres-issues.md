# Postgres issues

**Alert:** — (surfaces as `KilnAppDown`/`VerscientaAppDown` or
`KilnHighErrorRate`/`VerscientaHighErrorRate`; `DBConnection` errors in logs)
· **Severity:** treat as critical

## Symptoms

- Total DB loss: app crash-loops at boot, or every request 500s with
  `DBConnection.ConnectionError` in logs.
- Pool exhaustion (subtler): latency climbs, Ecto dashboard shows
  `queue_time` rising while `query_time` stays flat; sporadic timeouts.

## Impact

Everything — Postgres backs the app, Oban, and FunWithFlags.

## Diagnose

1. Is Postgres up and accepting connections?
   `docker exec <db> pg_isready -U postgres`
2. Disk full on the DB host (`df -h`) — Postgres goes read-only/down; WAL
   growth is the usual culprit.
3. Connection saturation, from any psql:

   ```sql
   SELECT count(*), state FROM pg_stat_activity GROUP BY state;
   SHOW max_connections;
   ```

   App side: pool is `POOL_SIZE` (default 10) per app instance, plus Oban's
   usage of the same repo.
4. Long-running/stuck queries:

   ```sql
   SELECT pid, now() - query_start AS dur, left(query, 80)
   FROM pg_stat_activity WHERE state <> 'idle' ORDER BY dur DESC LIMIT 10;
   ```

## Mitigate

- DB container down → start it; check its logs for corruption vs. plain OOM.
- Disk → free space (logs, old WAL after a successful backup), then size up.
- Stuck query hogging connections → `SELECT pg_terminate_backend(pid);`
- Sustained pool exhaustion → raise `POOL_SIZE` while
  `app_instances × POOL_SIZE + overhead < max_connections`; otherwise raise
  `max_connections` (needs DB restart) or reduce per-request query fan-out.

## Verify

`pg_isready` OK; error rate and `queue_time` recover; app reconnects
automatically (no restart needed once the DB is back).

## Prevention

This is why "Backups verified (Coolify + Postgres WAL + R2) with restore
drill" is its own Phase 4 todo — without a tested restore, every incident
here is existential. Monitor DB host disk alongside app metrics.
