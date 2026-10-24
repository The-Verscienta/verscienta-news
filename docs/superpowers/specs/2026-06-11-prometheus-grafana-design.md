# Prometheus Metrics Export + Grafana Dashboards — Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


Date: 2026-06-11
Phase 4 → Observability & Ops: "Prometheus metrics export + Grafana dashboards."

## Goal

Expose application metrics in Prometheus text format over HTTP and provide
Grafana dashboards for them — locally via a one-command Docker Compose
monitoring stack, and in production via a token-guarded `/metrics` endpoint
that any external Prometheus can scrape.

## Approaches considered

1. **PromEx** (chosen) — Phoenix-ecosystem standard. Built-in plugins for
   Application, BEAM, Phoenix, Ecto, Oban, and LiveView metrics (all
   subsystems this app uses), each with a maintained pre-built Grafana
   dashboard. Serves metrics via `PromEx.Plug` (no Cowboy needed — works with
   Bandit). Dashboards can be exported to JSON (`mix prom_ex.dashboard.export`)
   or auto-uploaded to Grafana at boot.
2. `telemetry_metrics_prometheus_core` + custom plug — smaller dep, reuses
   `VerscientaWeb.Telemetry.metrics/0`, but no dashboards: we would hand-author
   every Grafana panel. More work, worse result.
3. OpenTelemetry + collector — strictly more infrastructure than the todo item
   asks for; Prometheus is named explicitly. Rejected as overkill.

## Components

### 1. `Verscienta.PromEx` (`lib/verscienta/prom_ex.ex`)

`use PromEx, otp_app: :verscienta`. Plugins:

- `PromEx.Plugins.Application`
- `PromEx.Plugins.Beam`
- `{PromEx.Plugins.Phoenix, router: VerscientaWeb.Router, endpoint: VerscientaWeb.Endpoint}`
- `PromEx.Plugins.Ecto`
- `{PromEx.Plugins.Oban, oban_supervisors: [Oban]}`
- `PromEx.Plugins.PhoenixLiveView`
- `Verscienta.PromEx.Plugins.Cache` (custom, below)

Dashboards: the matching `{:prom_ex, "*.json"}` built-ins, with
`dashboard_assigns` pointing at the provisioned datasource id `prometheus`.

Started as the **first child** in `Verscienta.Application` so its telemetry
handlers are attached before instrumented subsystems boot.

### 2. Custom cache plugin (`Verscienta.PromEx.Plugins.Cache`)

Wraps the existing `[:verscienta, :cache, :fetch]` event (emitted by
`Verscienta.Cache`): a `distribution` of fetch duration tagged by `:source`
(`:l1` / `:l2` / `:loader`). The per-source counts double as hit/miss rates.
The `key` metadata is deliberately **not** a tag (unbounded cardinality).
No custom Grafana dashboard for it (YAGNI — visible via Explore).

### 3. Metrics endpoint + auth

In `VerscientaWeb.Endpoint`, mounted **before** `Plug.Telemetry` so scrapes
don't pollute HTTP metrics:

```elixir
plug VerscientaWeb.Plugs.MetricsAuth
plug PromEx.Plug, prom_ex_module: Verscienta.PromEx, path: "/metrics"
```

`MetricsAuth` only acts on `GET /metrics`:

- `:metrics_auth_token` configured (non-empty) → require
  `authorization: Bearer <token>` (constant-time compare); otherwise 401 + halt.
- token absent → allow only when `:metrics_public` is true (dev/test);
  otherwise 404 + halt (prod default: endpoint hidden unless a token is set).

### 4. Configuration

- `config.exs`: base `Verscienta.PromEx` config (grafana/metrics-server
  `:disabled`; dashboards + datasource assign).
- `dev.exs` / `test.exs`: `metrics_public: true`.
- `test.exs`: PromEx `disabled: true` (avoids Oban polling hitting the DB
  outside the sandbox); the integration test starts it explicitly.
- `runtime.exs`: `METRICS_AUTH_TOKEN` → `:metrics_auth_token`; when
  `GRAFANA_HOST` + `GRAFANA_AUTH_TOKEN` are set, enable PromEx's
  upload-dashboards-on-boot against that Grafana.

### 5. Local monitoring stack (Compose profile `monitoring`)

- `prometheus` (`prom/prometheus`): config at `monitoring/prometheus.yml`,
  scraping `app:4000/metrics` every 15s.
- `grafana` (`grafana/grafana`): anonymous admin (dev only), provisioned
  Prometheus datasource (uid `prometheus`) and a dashboard provider loading
  `monitoring/grafana/dashboards/`, which holds the exported PromEx dashboard
  JSONs (checked in; regenerate with `mix prom_ex.dashboard.export`).

Run: `docker compose --profile monitoring up -d` → Grafana on
`${GRAFANA_PORT:-3001}`, Prometheus on `${PROMETHEUS_PORT:-9090}`.

### 6. Production (Coolify)

Set `METRICS_AUTH_TOKEN`; point the external Prometheus at
`https://<host>/metrics` with `bearer_token`. Optionally set `GRAFANA_HOST` +
`GRAFANA_AUTH_TOKEN` so PromEx uploads/refreshes dashboards at boot.

## Error handling

- Missing/wrong bearer token → 401; no token configured in prod → 404
  (endpoint invisible). Both halt before PromEx.
- PromEx disabled (test default) → supervisor child is `:ignore`; app boots
  normally.
- Grafana upload failures at boot are logged by PromEx, never fatal.

## Testing

- `MetricsAuth` unit tests: 401 wrong/missing token, 200 pass-through with
  token, 404 when neither token nor `metrics_public`, non-`/metrics` paths
  untouched.
- Integration: start `Verscienta.PromEx` (config flipped via
  `Application.put_env` + `on_exit`), `GET /metrics` → 200, body contains
  known series (e.g. `verscienta_prom_ex_status_info`).
- Cache plugin: after `:telemetry.execute` of a fetch event, scrape contains
  `verscienta_cache_fetch_duration_milliseconds` with `source` tag.

## Out of scope

Alerting rules, structured logging, runbooks (separate todo lines); custom
Grafana dashboard for cache/business metrics; Prometheus long-term storage.
