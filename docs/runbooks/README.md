# Runbooks

Incident procedures for operating Verscienta News (KilnCMS + overlay). Every
Prometheus alert ([monitoring/alerts.yml](../../monitoring/alerts.yml)) carries
a `runbook` annotation linking to one of these files. Stack is
**Cachex (ETS) + Hammer (ETS) + Phoenix.PubSub (pg)** — no Redis
(Kiln D1/D2; Dragonfly deferred).

| Runbook | Alert(s) | Severity |
| --- | --- | --- |
| [App down](app-down.md) | `KilnAppDown` / `VerscientaAppDown` (legacy name) | critical |
| [High error rate](high-error-rate.md) | `KilnHighErrorRate` | critical |
| [High latency](high-latency.md) | `KilnHighLatencyP95` | warning |
| [Oban queues](oban-queues.md) | `KilnObanQueueBacklog`, `KilnObanRetryablePileup` | warning |
| [Ollama down](ollama-down.md) | `KilnOllamaDown` / `VerscientaOllamaDown` | warning |
| [Postgres issues](postgres-issues.md) | — (common root cause of the two criticals) | — |
| [Cache degraded](cache-degraded.md) | — (Cachex ETS degraded / multi-node desync) | — |
| [Meilisearch down](meilisearch-down.md) | — (search outage, only if Meilisearch enabled) | — |
| [Source rights](source-rights.md) | — (allowlist / robots / takedown) | — |
| [Moderation queue](moderation-queue.md) | — (review queue backlog / stuck drafts) | — |
| [Deploy rollback](deploy-rollback.md) | — (procedure) | — |

Legacy `redis-down.md` is retained as a stub pointing to `cache-degraded.md` —
do not provision Redis for Slice 1.

## Shared preliminaries

**Where things are**

- Grafana dashboards (Phoenix, Ecto, Oban, BEAM, Application): local stack at
  `http://localhost:3001` (`docker compose --profile monitoring up -d`);
  production Grafana per deployment.
- Prometheus (PromQL console + alert state): local `http://localhost:9090`.
- Alertmanager (silences): local `http://localhost:9093`.
- App logs: `docker logs <app-container>` — JSON lines in prod
  (`time`/`severity`/`message`/`metadata.request_id`), so `jq` works:
  `docker logs <app> --since 15m | jq -r 'select(.severity=="error")'`.
- Coolify UI: deploy history, container status, env vars (secrets).

**Opening an app console**

OTP release (this repo's Dockerfile):

```sh
docker exec -it <app-container> bin/kiln_cms remote
# one-off RPC without joining the cluster:
docker exec -it <app-container> bin/kiln_cms rpc "KilnCMS.Cache.flush_delivery()"
```

**Severity conventions**

- `critical` — user-facing outage or data loss risk; act immediately.
- `warning` — degraded but functioning; investigate within hours.

## Template (for new runbooks)

```markdown
# <Incident name>
**Alert:** <name or —> · **Severity:** <critical|warning|—>
## Symptoms
## Impact
## Diagnose
## Mitigate
## Verify
## Prevention
```
