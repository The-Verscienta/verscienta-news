# App down

**Alert:** `KilnAppDown` / `VerscientaAppDown` (legacy) · **Severity:** critical

## Symptoms

Prometheus cannot scrape `/metrics` for 2+ minutes (`up{job="verscienta"} == 0`).
Usually the site is also unreachable; check immediately.

## Impact

Full user-facing outage (if the app is actually down — see false positives).

## Diagnose

1. **Is it real?** `curl -fsS https://<PHX_HOST>/` — if the site responds,
   this is likely a **scrape problem, not an outage**:
   - 401 from `/metrics` → `METRICS_AUTH_TOKEN` rotated without updating the
     Prometheus `authorization.credentials`, or vice versa.
   - 404 from `/metrics` → `METRICS_AUTH_TOKEN` unset in the app environment
     (prod hides the endpoint without it).
   - Network/firewall change between Prometheus and the app.
2. Container state: Coolify UI, or `docker ps` on the host — is the app
   container running/restarting (crash loop)?
3. Crash loop → logs from the last boot:
   `docker logs <app> --since 10m | jq -r 'select(.severity=="error" or .severity=="emergency") | .message'`
   Common boot failures are missing required env vars — `DATABASE_URL`,
   `SECRET_KEY_BASE`, `TOKEN_SIGNING_SECRET`, `CLOUDFLARE_*` all raise at
   boot by design. `MEILISEARCH_URL`/`MEILISEARCH_KEY` are only required if
   you enabled Meilisearch — Slice 1 defaults to Kiln Postgres FTS.
4. Healthy-looking container but no responses → check Postgres
   ([postgres-issues](postgres-issues.md)) and host resources
   (`df -h`, `free -m` — full disk is a classic).

## Mitigate

- Crash loop after a deploy → [roll back](deploy-rollback.md).
- Missing/wrong env var → fix in Coolify secrets, redeploy.
- Host-level (disk/memory) → free space (old images: `docker system prune`),
  restart the container.
- Scrape-only false positive → fix the token/config mismatch; consider a
  silence in Alertmanager while it propagates.

## Verify

`up{job="verscienta"} == 1` in Prometheus; site responds; alert resolves.

## Prevention

Keep `METRICS_AUTH_TOKEN` rotation atomic with the Prometheus config change.
Boot-required env vars are intentionally fail-fast — validate new ones in a
staging deploy first.
