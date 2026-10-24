# Observability: Prometheus Metrics + Grafana Dashboards

The app (KilnCMS + `verscienta_news` overlay) exports Prometheus metrics via
[PromEx](https://hexdocs.pm/prom_ex) at **`GET /metrics`** on the regular
HTTP endpoint, guarded by `KilnCMSWeb.Plugs.MetricsAuth` (or the overlay's
equivalent if present).

## What's exported

| Plugin | Covers |
| --- | --- |
| Application | dependency/app versions, uptime |
| Beam | memory, run queues, schedulers, GC |
| Phoenix | request rate/duration per route, channel joins |
| Ecto | query time split (queue/query/decode), pool usage |
| Oban | job lifecycle events, queue lengths |
| `KilnCMS.PromEx.Plugins.Cache` (if present) | `kiln_cms_cache_*` counters/histograms tagged by cache and hit/miss |
| `KilnCMS.PromEx.Plugins.Ollama` (if present) | `kiln_cms_ollama_up` gauge (1/0), probe of the Ollama version endpoint |

> **Stack note:** Cache metrics are Cachex (ETS) + `KilnCMS.Cache.ClusterBust`
> PubSub broadcasts — there is no `Verscienta.Cache.Redis` or `REDIS_URL`.
> Rate limiting is `Hammer` (ETS). Realtime is `Phoenix.PubSub` (pg adapter).
> Dragonfly/Redis are deferred per Kiln D1/D2 and must not appear in dashboards
> or alerts as required signals.

## Endpoint auth

- `METRICS_AUTH_TOKEN` set → `/metrics` requires `Authorization: Bearer <token>`
  (constant-time compare); wrong/missing token → 401.
- Unset → served openly only where `:metrics_public` is configured (dev/test).
  In prod without a token the endpoint returns **404** (invisible).

## Local monitoring stack

```sh
docker compose --profile monitoring up -d prometheus grafana
```

- Prometheus on `http://localhost:${PROMETHEUS_PORT:-9090}`, scraping
  `app:4000/metrics` every 15s ([monitoring/prometheus.yml](../monitoring/prometheus.yml)).
- Grafana on `http://localhost:${GRAFANA_PORT:-3001}` (anonymous admin, dev
  only), with the Prometheus datasource and the PromEx dashboards provisioned
  from [monitoring/grafana/dashboards](../monitoring/grafana/dashboards/).

### Regenerating the dashboards

The checked-in dashboard JSONs are rendered by PromEx. After changing
the PromEx module's plugins/assigns, re-export them:

```sh
for d in application beam phoenix ecto oban; do
  docker exec kiln-cms-app-1 \
    mix prom_ex.dashboard.export -m KilnCMS.PromEx -d $d.json \
    -s > monitoring/grafana/dashboards/$d.json
done
```

> The exact `mix prom_ex.dashboard.export` module name depends on where
> `PromEx` is started in the overlay vs core — check
> `kiln_cms/lib/kiln_cms/application.ex` or `config/config.exs` for the
> canonical module.

## Alerting

Alert rules live in [monitoring/alerts.yml](../monitoring/alerts.yml) — one
versioned file, evaluated by Prometheus locally and in prod alike:

| Alert | Fires when | Severity |
| --- | --- | --- |
| `KilnAppDown` (or `VerscientaAppDown` — legacy name) | scrape target down 2m | critical |
| `KilnHighErrorRate` | 5xx ratio > 5% over 5m (min-traffic guarded) | critical |
| `KilnHighLatencyP95` | p95 request duration > 1s for 10m | warning |
| `KilnObanQueueBacklog` | > 500 available jobs in a queue for 10m | warning |
| `KilnObanRetryablePileup` | > 50 retryable jobs in a queue for 15m | warning |
| `KilnOllamaDown` | `kiln_cms_ollama_up == 0` for 10m | warning (AI degrades gracefully) |

Every alert carries a `runbook` annotation linking to its incident procedure
in [docs/runbooks](runbooks/README.md).

The `monitoring` Compose profile includes Alertmanager on
`http://localhost:${ALERTMANAGER_PORT:-9093}` with a no-op default receiver
([monitoring/alertmanager.yml](../monitoring/alertmanager.yml)) — firing
alerts show up in its UI but are not delivered anywhere. To deliver, add
`slack_configs`/`email_configs`/`webhook_configs` to the `default` receiver.

In production: load `monitoring/alerts.yml` into your Prometheus
(`rule_files`) and point its `alerting:` block at your Alertmanager.

## Logs

**Structured logging (prod only):** in production, `kiln_cms/config/runtime.exs`
switches the default `:logger` handler to a JSON formatter (often `logger_json`,
Basic schema) — one JSON object per line on stdout with `time` / `severity` /
`message` / `metadata` (incl. `request_id`), ready for Loki/Elastic/Datadog
ingestion. Secret-bearing metadata keys (`password`, `token`, `authorization`,
`cookie`, …) are redacted by exact key match. `LOG_LEVEL`
(emergency…debug) overrides the default `info`; unknown values fall back to
`info` rather than failing boot. Dev/test keep the human-readable text format.

**Retention:** logs go to stdout; the container runtime bounds them.

- *Local Compose*: the `x-logging` anchor in `docker-compose.yml` caps every
  service at 3 × 10 MB rotated json-files (~30 MB/service).
- *Production (Coolify host)*: Docker's default json-file driver is
  **unbounded** — set rotation in `/etc/docker/daemon.json` on the host and
  restart dockerd:

  ```json
  {
    "log-driver": "json-file",
    "log-opts": { "max-size": "10m", "max-file": "5" }
  }
  ```

  That bounds retention to the last ~50 MB of logs per container (sizeable
  history at JSON line volume). Ship to a log store before rotation if
  longer retention is ever needed — the JSON format makes that a
  config-only change.

## Production (Coolify)

1. Set `METRICS_AUTH_TOKEN` (e.g. `openssl rand -hex 32`) in Coolify secrets.
2. Point your Prometheus at the app:

   ```yaml
   scrape_configs:
     - job_name: verscienta-news
       metrics_path: /metrics
       scheme: https
       authorization:
         type: Bearer
         credentials: <METRICS_AUTH_TOKEN>
       static_configs:
         - targets: ["<PHX_HOST>"]
   ```

3. Dashboards: either import the JSONs from
   `monitoring/grafana/dashboards/` into your Grafana, or set `GRAFANA_HOST`
   + `GRAFANA_AUTH_TOKEN` (service-account token with dashboard edit rights)
   and PromEx uploads/refreshes them into a "Verscienta" folder on every boot.
   The dashboards expect a Prometheus datasource with uid `prometheus`.

## Latency targets (Slice 1)

Slice 1 does **not** claim sub-100 ms LiveView interactions. The targets that
gate Slice 1 are the Kiln delivery SLOs (see `kiln_cms/docs/performance.md`):

| Surface | p95 target | What it measures |
|---|---|---|
| Public HTML — cache **hit** | < 50 ms | Fired artifact via `KilnCMS.Cache` (Cachex ETS) |
| Public HTML — cache **miss** | < 250 ms | Live render fallback |
| Headless API (`GET /api/content/:type/:slug`) | < 50 ms | Fired artifact, origin-side |
| Editor publish response | < 2 s | Enqueues `Firing.FireWorker`, not blocking on render |
| Fired cache safety-net TTL | 60 min | Precise invalidation on writes; TTL is backstop |

See [load-testing](load-testing.md) and `kiln_cms/docs/benchmarks.md` for the
measured baselines and the `scripts/benchmarks/api_latency.sh` harness that
replaces the old Verscienta standalone Benchee LiveView hammer for Slice 1.
