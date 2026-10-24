# Phase 0 — Foundation (Bootable Slice) Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-05-30
**Status:** Approved
**Scope:** Bootable slice of Phase 0 from [docs/todo.md](../../todo.md)

## Goal

A reproducible, containerized development environment in which a Phoenix 1.7 + Ash
application boots, connects to PostgreSQL, ships the "Codex" design tokens plus a starter
component set, and is guarded by basic CI. This is the foundation every Phase 1 feature
builds on — not feature work itself.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Dev environment | Docker dev container | Reproducible; insulates from host's RC toolchain |
| Elixir / OTP | Pin **1.18.x / OTP 27.x** in the image | Current well-supported combo for Phoenix 1.7 + Ash (host runs RC 1.20/OTP 29, unsupported) |
| Auth library | **AshAuthentication** | Consistent with the Ash-centric stack; avoids duplicate user modeling |
| App generation | **Igniter** (`igniter.new --with phx.new`) | Canonical Ash setup; cleaner than `phx.new` + manual Ash bolt-on |
| Phase 0 scope | **Bootable slice** | Get a running foundation; defer polish to follow-ups |

## Architecture & Components

### 1. Dev Container + Compose Stack

- **`.devcontainer/devcontainer.json`** — attaches the editor to the `app` service; runs
  `mix setup` on create; forwards port 4000.
- **`Dockerfile.dev`** — app image based on `hexpm/elixir:1.18.x-erlang-27.x-debian-*`,
  plus Node 22, `inotify-tools`, and hex/rebar pre-installed.
- **`docker-compose.yml`** services:
  - `app` — Phoenix server on `:4000`, mounts source, depends on `db`.
  - `db` — `postgres:16`.
  - `redis` — `redis:7`.
  - `meilisearch` — `getmeili/meilisearch:v1.x`.
  - `ollama` — `ollama/ollama`, gated behind an opt-in compose **profile** (`ai`) because
    the model pull is heavy; not started by default.
- **Named volumes** for Postgres data, Meilisearch data, Ollama models, and `deps`/`_build`
  caches so rebuilds stay fast.

### 2. Phoenix + Ash Application

- Generated via Igniter:
  `mix igniter.new verscienta --with phx.new --install ash,ash_postgres,ash_phoenix,ash_authentication,ash_authentication_phoenix`
- OTP app `verscienta`; modules `Verscienta` / `VerscientaWeb`.
- **AshPostgres** repo (`Verscienta.Repo`) + migrations.
- **`Verscienta.Accounts`** Ash domain with a **`User` resource skeleton** (identity fields
  + AshAuthentication password strategy wired enough to compile and migrate).
  - Login / registration / reset UI is **Phase 1**. Phase 0 only ensures the deps,
    domain, resource, and migrations exist and the app compiles.

### 3. Codex Design System

- **`tailwind.config.js`** extended with Codex tokens:
  - Colors: `bg #0c0c0c`, `bg-2 #161616`, `bg-3 #1f1f1f`, ink scale (`#ffffff` / `#b6b6b6`
    / `#6d6d6d`), `line #2a2a2a`, `zune #F2660A`, and the 7 Metro accents
    (world `#1BA1E2`, politics `#E51400`, tech `#00ABA9`, culture `#D80073`,
    sport `#8CBF26`, business `#F09609`, opinion `#A200FF`).
  - `borderRadius` default `0` (sharp corners).
  - `fontFamily` → Hanken Grotesk as the single family.
  - Custom easing `cubic-bezier(.2,.8,.2,1)` + `slide` / `stagger` / `turnstile` keyframes.
- **Hanken Grotesk** self-hosted via `@fontsource-variable/hanken-grotesk` (npm) — no
  runtime CDN dependency.
- **Root layout** — dark canvas with the thin top "strip" chrome.
- **`VerscientaWeb.CodexComponents`** — starter function components: `kicker`, `headline`,
  `breaking_bar`, `news_card`, `tile`, `feed_post`, `notif`, `button`.
- **`/styleguide`** — a dev-only page rendering the component set. Full `phoenix_storybook`
  is deferred.

### 4. Config, CI & Hygiene

- **`config/runtime.exs`** — env-driven: database URL, `secret_key_base`, Meilisearch
  host/key, Redis URL, Ollama URL.
- **`.env.example`** + `dotenvy` for local env loading (real `.env` gitignored).
- **GitHub Actions** workflow:
  `setup-beam` (1.18 / 27) → cache `deps` + `_build` → `mix deps.get` →
  `mix compile --warnings-as-errors` → `mix format --check-formatted` →
  `mix credo --strict` → `mix test` (with a Postgres service container).
- Repo hygiene: `git init`, `.gitignore`, `.tool-versions` (documents 1.18/27),
  `.formatter.exs`, README onboarding update (devcontainer / `docker compose up`).

## Data Flow

Editor attaches to the devcontainer `app` service → Phoenix runs on `:4000` → connects to
`db` / `redis` / `meilisearch` / `ollama` over the compose network → browser hits
`localhost:4000`.

## Testing

ExUnit smoke tests verifying:
1. The application boots and the supervision tree starts.
2. `Verscienta.Repo` connects to Postgres.
3. The home page and `/styleguide` render (200).
4. One `User` Ash action runs successfully (e.g. create/read).

CI must pass on every push/PR.

## Explicitly Deferred (YAGNI for this slice)

These are real Phase 0 todo items intentionally held for follow-ups so the slice stays
focused:

- Dialyzer / PLT setup.
- `phoenix_storybook` (the lightweight `/styleguide` covers the immediate need).
- Dependabot.
- Coolify deploy hookup.
- Full authentication UI (registration / login / reset flows).
- Oban / Broadway / Meilisearch **integration logic** — the services run in compose but are
  not yet wired into application code.

## Definition of Done

- `docker compose up` (or opening the devcontainer) yields a running app at
  `localhost:4000`.
- `mix setup` succeeds from a clean checkout inside the container.
- Home and `/styleguide` pages render with Codex styling and the starter components.
- `mix compile --warnings-as-errors`, `mix format --check-formatted`,
  `mix credo --strict`, and `mix test` all pass locally and in CI.
- Spec, README onboarding, and repo hygiene files are committed.
