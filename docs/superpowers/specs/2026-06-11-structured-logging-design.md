# Structured Logging + Log Retention — Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


Date: 2026-06-11
Phase 4 → Observability & Ops: "Structured logging + log retention."
Stacked on the metrics (PR #30) and alerting (PR #32) work.

## Goal

Production logs become machine-parseable JSON (one object per line on stdout,
secrets redacted), and log storage is bounded with a defined retention policy
both locally and on the Coolify host. Dev/test keep human-readable text logs.

## Approaches considered

1. **logger_json** (chosen) — ecosystem-standard `:logger` formatters
   (Basic/Datadog/GCP/Elastic schemas), built-in redactors, maintained
   (7.0.4). We use the Basic schema: no vendor lock-in, trivially ingested by
   Loki/Elastic/Datadog later.
2. Hand-rolled `:logger` formatter emitting Jason-encoded maps — reimplements
   crash-report formatting, unicode edge cases, and redaction for no benefit.
3. Keep text logs and parse downstream (regex in the collector) — fragile,
   not actually structured. Rejected.

## Components

### 1. `Verscienta.Logging` (`lib/verscienta/logging.ex`)

Owns the formatter construction so it is unit-testable (runtime.exs is not):

- `formatter/0` → `LoggerJSON.Formatters.Basic.new/1` with
  `metadata: {:all_except, [:conn, :socket]}` and a
  `LoggerJSON.Redactors.RedactKeys` redactor covering password/secret/token/
  api_key/authorization/cookie-style keys. Output: one JSON object per line —
  `time`, `severity`, `message`, `metadata` (incl. `request_id`), plus
  `request` when Plug metadata is present.
- `parse_level/1` → maps a `LOG_LEVEL` env string to a `Logger` level,
  falling back to `:info` on nil/unknown values (a typo in an env var must
  not take prod down at boot).

### 2. Runtime wiring (`config/runtime.exs`, prod block only)

```elixir
config :logger, :default_handler, formatter: Verscienta.Logging.formatter()
config :logger, level: Verscienta.Logging.parse_level(System.get_env("LOG_LEVEL"))
```

Dev/test untouched: they keep the existing
`$time $metadata[$level] $message` text format.

### 3. Retention

Logs go to stdout (12-factor); retention is the container runtime's job:

- **Local Compose**: a shared `x-logging` anchor sets the `json-file` driver
  with `max-size: 10m`, `max-file: 3` on every long-running service
  (app, db, redis, meilisearch, ollama, prometheus, grafana, alertmanager) —
  a hard ~30 MB cap per service.
- **Production (Coolify host)**: documented `daemon.json`
  (`log-driver: json-file`, same rotation opts) — Docker's default is
  *unbounded*, so this is the actual retention fix. Documented in
  docs/observability.md, applied on the host (not in-repo, same rule as other
  Coolify config).

No Loki/log-shipping stack: out of scope for this line item; the JSON format
is what makes adding one later trivial.

## Error handling

- Unknown/missing `LOG_LEVEL` → `:info` (never raises at boot).
- Redaction is by exact key match after binary conversion (logger_json
  semantics); nested maps are walked by the encoder.
- Crash reports flow through logger_json's crash formatting into the same
  JSON schema.

## Testing

`Verscienta.Logging` unit tests (no global logger reconfiguration — tests
call the formatter directly on synthetic `:logger` events):

- formatted event is valid JSON with `message`, `severity`, `time`, and
  `metadata.request_id`;
- a `password` metadata key renders as `"[REDACTED]"`;
- `parse_level/1`: valid level strings (case-insensitive) map correctly;
  nil/garbage → `:info`.

Plus `docker compose config` validation for the logging anchor.

## Out of scope

Log shipping/aggregation (Loki, Elastic), vendor-specific log schemas,
Phoenix request-log replacement (`LoggerJSON.Plug`), audit logging, and
runbooks (separate todo line).
