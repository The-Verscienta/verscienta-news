# High error rate

**Alert:** `KilnHighErrorRate` / `VerscientaHighErrorRate` (legacy name) · **Severity:** critical

## Symptoms

More than 5% of HTTP requests returned 5xx over the last 5 minutes (with the
min-traffic guard, so this is real traffic failing).

## Impact

A meaningful fraction of user requests are failing.

## Diagnose

1. **Which routes?** PromQL:

   ```promql
   topk(5, sum by (path, controller, status) (
     rate(verscienta_prom_ex_phoenix_http_requests_total{status=~"5.."}[5m])))
   ```

   One route → recent change to that feature. Everything → shared dependency
   (DB, deploy — no Redis in Slice 1; cache is Cachex ETS per D1/D2).
2. **What exceptions?** Errors in prod logs are JSON with `request_id`:

   ```sh
   docker logs <app> --since 15m | jq -r 'select(.severity=="error") | .message' | sort | uniq -c | sort -rn | head
   ```

   Take one `metadata.request_id` and pull its whole request:
   `docker logs <app> --since 15m | jq -r 'select(.metadata.request_id=="...")'`
3. **Did a deploy just land?** Coolify deploy history vs. alert start time.
4. DB symptoms (`DBConnection` errors, timeouts) →
   [postgres-issues](postgres-issues.md). Search errors on search routes →
   [meilisearch-down](meilisearch-down.md).

## Mitigate

- Caused by a deploy → [roll back](deploy-rollback.md) first, debug after.
- Dependency down → that dependency's runbook.
- One feature broken and gated → disable its FunWithFlags flag from the
  console (`FunWithFlags.disable(:flag_name)`) to stop the bleeding.

## Verify

5xx rate back under threshold:

```promql
sum(rate(verscienta_prom_ex_phoenix_http_requests_total{status=~"5.."}[5m]))
  / sum(rate(verscienta_prom_ex_phoenix_http_requests_total[5m]))
```

## Prevention

Reproduce the exception in a test before (or right after) fixing; ship the
regression test with the fix.
