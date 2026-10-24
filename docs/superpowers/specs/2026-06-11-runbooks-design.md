# Runbooks for Common Incidents — Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


Date: 2026-06-11
Phase 4 → Observability & Ops: "Runbooks for common incidents."
Stacked on metrics (#30), alerting (#32), structured logging (#34).

## Goal

A repo-versioned runbook per plausible incident, written for the operator on
call: symptoms → diagnosis (concrete commands) → mitigation → verification.
Every Prometheus alert links to its runbook via a `runbook` annotation, so a
firing alert carries its own procedure.

## Approaches considered

1. **Per-incident files in `docs/runbooks/` + alert annotations** (chosen) —
   each alert deep-links to one focused procedure; versioned next to the
   alert rules they pair with.
2. One monolithic RUNBOOK.md — not deep-linkable from alerts, grows unwieldy.
3. External wiki — drifts from code, invisible in PRs. Rejected.

## Contents

`docs/runbooks/README.md`: index, severity conventions, shared preliminaries
(where dashboards/logs live, how to open an IEx console in the app container,
note that prod currently runs mix-in-container — no release artifact yet).

One runbook per incident, alert-paired first:

| Runbook | Pairs with |
| --- | --- |
| app-down.md | VerscientaAppDown (incl. the 401-scrape false-positive gotcha) |
| high-error-rate.md | VerscientaHighErrorRate |
| high-latency.md | VerscientaHighLatencyP95 |
| oban-queues.md | VerscientaObanQueueBacklog + VerscientaObanRetryablePileup |
| ollama-down.md | VerscientaOllamaDown |
| postgres-issues.md | (no direct alert; the usual root cause of AppDown/HighErrorRate) |
| redis-down.md | (cache L2 degradation — silent, shows as latency/DB load) |
| meilisearch-down.md | (search outage; prod boot survives, requests fail) |
| deploy-rollback.md | (bad deploy → Coolify rollback procedure) |

Each follows the same template: **Alert / Severity / Symptoms / Impact /
Diagnose / Mitigate / Verify / Prevention** — diagnosis steps use the real
PromQL series, Grafana dashboards, JSON log fields (`request_id`), and IEx
snippets (Oban queries, cache/probe helpers) verified against the codebase.

Behavioral facts encoded (verified in code):
- Meilisearch: boot-time setup is fault-tolerant (`Search.Setup` logs and
  continues); failures surface per-request. Reindex: `mix verscienta.reindex`.
- Redis: `Cache.Redis.command/1` returns errors after 250ms → callers treat
  as L2 miss; Redix pool reconnects itself; single-node PubSub means
  invalidation does not depend on Redis today. Impact is load, not staleness.
- Ollama: enrichment/embedding workers (queue `:ai`, concurrency 3) fail →
  Oban retries with backoff; OllamaDown often co-fires with RetryablePileup;
  recovery is automatic, backfill via `mix verscienta.ai_backfill` /
  `mix verscienta.embeddings.backfill`.
- Oban queues: default 10, aggregation 5, ai 3 (config.exs).
- Ecto `queue_time` is the pool-exhaustion signal; `POOL_SIZE` env tunes.

## alerts.yml change

Add `runbook: https://github.com/The-Verscienta/news-verscienta/blob/main/docs/runbooks/<file>.md`
annotation to all 6 alerts. Re-validate with promtool.

## Testing / verification

- `promtool check rules` after annotation changes.
- Full `mix precommit` (no code changes expected to affect it — regression
  guard only).
- Accuracy review: every command/metric name in the runbooks must exist in
  the repo (spot-checked during writing).

## Out of scope

Backup/restore drill runbook (separate todo line — depends on infra access),
incident-management process (paging rotations, postmortem templates),
automated remediation.
