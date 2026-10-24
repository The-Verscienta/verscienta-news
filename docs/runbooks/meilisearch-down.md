# Meilisearch down

**Alert:** — (surfaces as 5xx/errors on search routes) · **Severity:**
warning-equivalent (search-only outage)

## Symptoms

> **Slice 1 note:** Slice 1 search is **Kiln Postgres FTS** (`KilnCMS.Search`);
> this runbook only applies if you provisioned Meilisearch (`--profile search`
> / `MEILISEARCH_URL` set). With Postgres FTS, Meilisearch being down has no
> effect.

Search requests fail or return errors; non-search pages are unaffected. At
**boot** the app tolerates a missing Meilisearch (`KilnCMS.Search.Setup` logs
`Meilisearch index setup skipped:` and continues) — failures surface
per-request.

## Impact

Search (including personalized search) is down **only when Meilisearch is the
active search backend**. With Slice 1 Postgres FTS there is no impact.
Indexing of new/updated content fails while it lasts; the index goes stale.

## Diagnose

1. Health: `curl -fsS $MEILISEARCH_URL/health` → `{"status":"available"}`?
2. Container logs (it's memory-hungry during indexing; OOM is common).
3. `MEILISEARCH_URL` / `MEILISEARCH_KEY` env after infra changes — both are
   only required if Meilisearch is enabled (Slice 1 defaults to Postgres FTS
   with no Meilisearch; a wrong key 401s at request time).
4. Search route errors in app logs:
   `docker logs <app> --since 15m | jq -r 'select(.severity=="error") | .message' | grep -i -e meili -e search`

## Mitigate

- Restart/start Meilisearch (persistent volume `meili` keeps the index).
- Wrong key/URL → fix in Coolify secrets, redeploy the app.
- If the index was lost or is stale after recovery, rebuild it:

  ```sh
  docker exec -it <app> bin/kiln_cms rpc "KilnCMS.Search.Setup.run()"
  # or, if a mix task exists:
  docker exec <app> mix kiln.search.reindex
  ```

  (Index settings are re-ensured by `KilnCMS.Search.Setup` on next boot.)

## Verify

`/health` available; searches return results; a freshly published article
appears in search after reindex/normal indexing.

## Prevention

Give Meilisearch enough memory for peak indexing (bulk reindex is the spike).
Keep its data on the persistent volume so restarts don't force a reindex.
