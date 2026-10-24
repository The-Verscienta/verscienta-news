# Alerting on Error Rate, Latency, Queue Depth, Ollama Health — Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


Date: 2026-06-11
Phase 4 → Observability & Ops: "Alerting on error rate, latency, queue depth, Ollama health."
Builds on the PromEx/Prometheus/Grafana stack (spec: 2026-06-11-prometheus-grafana-design.md).

## Goal

Versioned Prometheus alert rules covering the four todo signals, evaluated by
the local Compose monitoring stack (and reusable verbatim by a production
Prometheus), with Alertmanager for routing. Ollama currently exports no health
signal, so the app additionally gains a `verscienta_ollama_up` gauge.

## Approaches considered

1. **Prometheus alert rules + Alertmanager** (chosen) — rules are repo-versioned
   YAML, evaluated wherever Prometheus runs (local profile and prod), and
   Alertmanager provides grouping/dedup/silences and pluggable receivers.
2. Grafana unified alerting — couples alert definitions to the dashboard tool;
   provisioning alert rules as code is clumsier than Prometheus rule files.
3. In-app alerting (Oban job checking thresholds, emailing) — reimplements
   Alertmanager poorly. Rejected.

## Signals → rules (`monitoring/alerts.yml`)

Metric names verified against PromEx 1.11 plugin sources; prefix is
`verscienta_prom_ex_`.

| Alert | Expression sketch | For | Severity |
| --- | --- | --- | --- |
| `VerscientaAppDown` | `up{job="verscienta"} == 0` | 2m | critical |
| `VerscientaHighErrorRate` | 5xx ÷ total of `rate(verscienta_prom_ex_phoenix_http_requests_total[5m])` > 5%, guarded by total rate > 0.1 req/s so a single error at idle traffic can't page | 5m | critical |
| `VerscientaHighLatencyP95` | `histogram_quantile(0.95, … _http_request_duration_milliseconds_bucket[5m])` > 1000 ms | 10m | warning |
| `VerscientaObanQueueBacklog` | `verscienta_prom_ex_oban_queue_length_count{state="available"}` > 500 per queue | 10m | warning |
| `VerscientaObanRetryablePileup` | same metric, `state="retryable"` > 50 per queue | 15m | warning |
| `VerscientaOllamaDown` | `verscienta_ollama_up == 0` | 10m | warning (AI enrichment degrades gracefully; never critical) |

Thresholds are starting points, tunable in one file. Each rule carries
`summary`/`description` annotations.

## Ollama health gauge

- `Verscienta.AI.Health.up?/0` — `GET {ollama_url}/api/version` via Req,
  `receive_timeout: 2_000`, `retry: false`; any non-2xx/error/raise → `false`.
  Accepts override opts (`up?/1`) so tests inject `plug: {Req.Test, …}`.
- `Verscienta.PromEx.Plugins.Ollama` — PromEx polling plugin (30s default
  `poll_rate`), emits `last_value` gauge **`verscienta_ollama_up`** (1/0).
  Added to `Verscienta.PromEx.plugins/0`. No Grafana dashboard (the alert and
  Explore suffice).

In test the plugin never polls (PromEx disabled in test env); the existing
`/metrics` integration test tolerates a refused localhost probe (instant
`false`, no crash).

## Alertmanager (Compose `monitoring` profile)

- `alertmanager` service (`prom/alertmanager`), port `${ALERTMANAGER_PORT:-9093}`,
  config `monitoring/alertmanager.yml`: group by alertname, route everything to
  a `default` receiver with **no integrations** (alerts visible/silenceable in
  the AM UI; nothing leaves the machine). Slack/email/webhook wiring is
  documented, not enabled — receivers are deployment config.
- `monitoring/prometheus.yml` gains `rule_files: [alerts.yml]` and an
  `alerting:` block targeting `alertmanager:9093`; Compose mounts
  `monitoring/alerts.yml` into the Prometheus container.

## Production

Reuse `monitoring/alerts.yml` in the prod Prometheus (rule_files), point its
`alerting:` at the prod Alertmanager, configure real receivers there. The
`verscienta_ollama_up` gauge ships with the app, so OllamaDown works anywhere
the app is scraped. Documented in docs/observability.md.

## Error handling

- Health probe failures (timeout, refused, DNS, non-2xx, raise) → gauge `0`;
  the probe can never crash the poller.
- Missing Alertmanager (e.g. prod Prometheus without one) → rules still
  evaluate; firing alerts are visible in the Prometheus UI.

## Testing

- `Verscienta.AI.Health`: Req.Test-stubbed 200 → true; 500 → false;
  transport error → false (no real network).
- `Verscienta.PromEx.Plugins.Ollama`: polling group structure (event name,
  poll rate honored, gauge definition present).
- Rule/config syntax: `promtool check rules monitoring/alerts.yml` and
  `amtool check-config monitoring/alertmanager.yml` run via Docker as part of
  verification (not CI — matches how the dashboards were validated).

## Out of scope

Real notification receivers (Slack/email/PagerDuty credentials), recording
rules, SLO/burn-rate alerting, alerting on Meilisearch/Redis health (no
exporters for them yet), structured logging and runbooks (separate todo lines).
