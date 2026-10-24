# Ollama down

**Alert:** `KilnOllamaDown` / `VerscientaOllamaDown` · **Severity:** warning

`kiln_cms_ollama_up == 0` (legacy: `verscienta_ollama_up == 0`) for 10+ minutes
— the app's probe (`KilnCMS.AI.Health` or overlay `VerscientaNews.AI.Health`,
`GET /api/version`, 2s timeout) can't reach Ollama at `OLLAMA_URL`.

## Symptoms

AI enrichment and embeddings stop; `ai` queue jobs fail and accumulate as
`retryable` (expect `KilnObanRetryablePileup` to co-fire if it lasts).

## Impact

**Deliberately non-critical**: articles still aggregate and publish without
enrichment; embedding-dependent features (related content, personalized
ranking) serve unenriched/fallback results. Nothing is lost — failed jobs
retry automatically.

## Diagnose

1. Probe it yourself from the app container:
   `docker exec <app> curl -fsS -m 2 $OLLAMA_URL/api/version`
2. Is the Ollama container/host up? (`docker ps`, its logs — OOM kills are
   common: models need RAM; check `dmesg | grep -i oom` on its host.)
3. `OLLAMA_URL` env correct after recent infra changes? (Defaults to
   localhost:11434 when unset — wrong in any multi-container deployment.)
4. Model present? `docker exec <ollama> ollama list` should include
   `OLLAMA_MODEL` (default `llama3.2:3b`) and `OLLAMA_EMBED_MODEL`
   (default `nomic-embed-text`). If the volume was recreated, re-pull.

## Mitigate

- Restart/start the Ollama container; re-pull models if missing
  (`ollama pull llama3.2:3b`, `ollama pull nomic-embed-text`).
- Wrong URL → fix `OLLAMA_URL` in Coolify secrets, redeploy.
- No fix available soon → nothing else to do: enrichment degrades gracefully
  and retries. If retryable jobs piled high, see
  [oban-queues](oban-queues.md) to bulk-retry after recovery.

## Verify

`kiln_cms_ollama_up == 1` in Prometheus; `ai` queue draining. Backfill any
articles that exhausted retries while it was down (check overlay for the
exact backfill task name — e.g. `mix kiln.ai_backfill` or
`mix verscienta.ai_backfill` if the overlay provides it):

```sh
docker exec -it <app> bin/kiln_cms rpc "Oban.insert!(KilnCMS.AI.BackfillWorker.new(%{}))"
# or, if a mix backfill task exists:
docker exec <app> mix kiln.ai_backfill
```

## Prevention

Give the Ollama host enough RAM for the configured models with headroom;
keep models on a persistent volume so restarts don't re-pull.
