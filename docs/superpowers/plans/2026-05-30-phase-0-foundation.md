# Phase 0 Foundation (Bootable Slice) Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a reproducible, containerized Phoenix 1.7 + Ash dev environment that boots, connects to Postgres, ships the "Codex" design tokens plus a starter component set, and is guarded by basic CI.

**Architecture:** A Docker dev container (pinned Elixir 1.18 / OTP 27) runs the Phoenix app; Postgres, Redis, Meilisearch, and an opt-in Ollama run as Compose services. The app is generated with Igniter (Ash-first), styled with Codex Tailwind tokens and a `CodexComponents` module, and exercised by ExUnit smoke tests in GitHub Actions.

**Tech Stack:** Elixir 1.18 / OTP 27, Phoenix 1.7, Ash + AshPostgres + AshAuthentication, LiveView, Tailwind CSS, Docker Compose, PostgreSQL 16, Redis 7, Meilisearch v1, Ollama, GitHub Actions.

---

## Conventions for the executor

- **Host shell:** PowerShell on Windows. Host-side commands (`docker`, `git`) are shown for PowerShell.
- **In-container shell:** bash. Commands prefixed `docker compose run --rm app bash -lc "…"` run inside the pinned toolchain.
- **Working dir:** repo root `C:\Github\news-verscienta` (already a git repo on branch `main`; contains `docs/`, `README.md`).
- The mix project lives at the **repo root** (OTP app `verscienta`), not a subfolder.
- Commit after every task. Use the existing git identity (do not set a local override).

---

## File Structure

| File | Responsibility |
|------|----------------|
| `Dockerfile.dev` | Pinned Elixir/OTP toolchain image for dev + CI-parity, with Node, curl, inotify-tools, git |
| `.dockerignore` | Keep build context small |
| `docker-compose.yml` | `app`, `db`, `redis`, `meilisearch`, `ollama` (profile `ai`) services + volumes |
| `.devcontainer/devcontainer.json` | Editor attach to `app` service; `mix setup` post-create |
| `.env.example` | Documented env vars; copied to `.env` (gitignored) locally |
| `mix.exs` / `config/*` | Generated app config; edited for env-driven dev DB + dotenvy + Meili/Redis/Ollama URLs |
| `assets/css/app.css` | Codex `@font-face` + base canvas styles |
| `assets/tailwind.config.js` | Codex design tokens (colors, radius 0, font, easing, keyframes) |
| `priv/static/fonts/` | Self-hosted Hanken Grotesk woff2 files |
| `lib/verscienta_web/components/layouts/root.html.heex` | Dark canvas + thin "strip" chrome |
| `lib/verscienta_web/components/codex_components.ex` | Starter Codex function components |
| `lib/verscienta_web/controllers/styleguide_*` | Dev-only `/styleguide` page |
| `lib/verscienta/accounts.ex` + `lib/verscienta/accounts/user.ex` | Ash domain + `User` resource skeleton |
| `test/verscienta_web/smoke_test.exs` + `test/verscienta/accounts_test.exs` | Smoke tests |
| `.github/workflows/ci.yml` | compile/format/credo/test pipeline |

---

## Task 1: Dev container toolchain image

**Files:**
- Create: `Dockerfile.dev`
- Create: `.dockerignore`

- [ ] **Step 1: Write `Dockerfile.dev`**

```dockerfile
# Pinned to match the spec: Elixir 1.18 / Erlang OTP 27 on Debian.
FROM hexpm/elixir:1.18.4-erlang-27.3.4-debian-bookworm-20250520-slim

ENV LANG=C.UTF-8 \
    MIX_HOME=/root/.mix \
    HEX_HOME=/root/.hex

# System deps: build tools, file watching, git, curl (font fetch), Node 22 (assets/tooling), Postgres client.
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      build-essential git curl ca-certificates inotify-tools postgresql-client && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

WORKDIR /workspace

# Source is bind-mounted at runtime; no COPY of app code here (avoids chicken-and-egg with generation).
CMD ["bash"]
```

- [ ] **Step 2: Write `.dockerignore`**

```
.git
_build
deps
node_modules
assets/node_modules
priv/static/assets
.elixir_ls
```

- [ ] **Step 3: Build the image**

Run:
```powershell
docker build -f Dockerfile.dev -t verscienta-dev .
```
Expected: build succeeds; final line shows the image tagged `verscienta-dev:latest`.

- [ ] **Step 4: Verify the toolchain versions inside the image**

Run:
```powershell
docker run --rm verscienta-dev bash -lc "elixir --version && node --version && git --version"
```
Expected: `Elixir 1.18.4` on `Erlang/OTP 27`, `v22.x`, and a git version.

- [ ] **Step 5: Commit**

```powershell
git add Dockerfile.dev .dockerignore
git commit -m "build: add pinned Elixir 1.18/OTP 27 dev container image"
```

---

## Task 2: Generate the Phoenix + Ash app into the repo root

This uses Igniter inside the pinned image, writes to a scratch dir, then copies generated files into the repo root **without clobbering** the existing `README.md` / `docs/` / `.git`.

**Files:**
- Create (generated): `mix.exs`, `config/`, `lib/`, `test/`, `assets/`, `priv/`, `.formatter.exs`, `.gitignore`, etc.

- [ ] **Step 1: Generate the app in a scratch dir and merge into the workspace**

Run:
```powershell
docker run --rm -v ${PWD}:/workspace -w /tmp verscienta-dev bash -lc "`
  mix archive.install hex igniter_new --force && `
  mix igniter.new verscienta --with phx.new --install ash,ash_postgres,ash_phoenix,ash_authentication,ash_authentication_phoenix --yes && `
  cp -a -n /tmp/verscienta/. /workspace/ && `
  echo GENERATED_OK"
```
Expected: ends with `GENERATED_OK`. `cp -a -n` (no-clobber) leaves the existing `README.md` and `docs/` untouched while bringing in all new generated files.

- [ ] **Step 2: Confirm the project is at root and uses the right module names**

Run:
```powershell
docker compose version > $null; Get-Content mix.exs | Select-String "app: :verscienta"
```
Expected: a line containing `app: :verscienta`. Also confirm `lib/verscienta/` and `lib/verscienta_web/` directories exist.

- [ ] **Step 3: Fetch deps and compile inside a throwaway container**

Run:
```powershell
docker run --rm -v ${PWD}:/workspace -w /workspace verscienta-dev bash -lc "mix deps.get && mix compile"
```
Expected: deps resolve and `Compiling N files (.ex)` finishes with no errors. Warnings acceptable at this stage.

- [ ] **Step 4: Commit the generated app**

```powershell
git add -A
git commit -m "feat: scaffold Phoenix 1.7 + Ash app via Igniter (verscienta)"
```

---

## Task 3: Env-driven config + dotenvy + .env.example

Make dev config read connection details from env so the same code works in Compose and locally. Phoenix's generated `config/dev.exs` hardcodes `localhost`; we point it at env with Compose-friendly defaults.

**Files:**
- Modify: `mix.exs` (add `:dotenvy`)
- Modify: `config/dev.exs` (env-driven Repo)
- Modify: `config/runtime.exs` (Meili/Redis/Ollama URLs)
- Create: `config/dotenv.exs` loader call (or inline in `config/runtime.exs`)
- Create: `.env.example`
- Modify: `.gitignore` (ignore `.env`)

- [ ] **Step 1: Add `dotenvy` dependency**

In `mix.exs`, inside `defp deps do [...]`, add:
```elixir
      {:dotenvy, "~> 0.9"},
```

- [ ] **Step 2: Load `.env` early in `config/runtime.exs`**

At the very top of `config/runtime.exs` (after `import Config`), add:
```elixir
# Load .env in dev/test so local runs and Compose share one source of env vars.
if config_env() in [:dev, :test] do
  Dotenvy.source([".env", System.get_env()])
end
```

- [ ] **Step 3: Make the dev Repo env-driven**

In `config/dev.exs`, replace the `config :verscienta, Verscienta.Repo, …` block's connection keys with:
```elixir
config :verscienta, Verscienta.Repo,
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("DB_PORT", "5432")),
  database: System.get_env("DB_NAME", "verscienta_dev"),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10
```

- [ ] **Step 4: Add service URLs to `config/runtime.exs`**

Append to `config/runtime.exs` (outside any `if config_env() == :prod` block so dev gets them too):
```elixir
config :verscienta,
  meilisearch_url: System.get_env("MEILISEARCH_URL", "http://localhost:7700"),
  meilisearch_key: System.get_env("MEILISEARCH_KEY", "masterKey"),
  redis_url: System.get_env("REDIS_URL", "redis://localhost:6379"),
  ollama_url: System.get_env("OLLAMA_URL", "http://localhost:11434")
```

- [ ] **Step 5: Write `.env.example`**

```dotenv
# Database
DB_HOST=db
DB_PORT=5432
DB_USER=postgres
DB_PASSWORD=postgres
DB_NAME=verscienta_dev

# Services (Compose service names)
MEILISEARCH_URL=http://meilisearch:7700
MEILISEARCH_KEY=masterKey
REDIS_URL=redis://redis:6379
OLLAMA_URL=http://ollama:11434
```

- [ ] **Step 6: Ignore real `.env`**

Append to `.gitignore`:
```
# Local environment overrides
.env
```

- [ ] **Step 7: Verify config compiles**

Run:
```powershell
docker run --rm -v ${PWD}:/workspace -w /workspace verscienta-dev bash -lc "mix deps.get && mix compile"
```
Expected: compiles with no errors.

- [ ] **Step 8: Commit**

```powershell
git add -A
git commit -m "config: env-driven dev DB and service URLs via dotenvy"
```

---

## Task 4: Compose stack + first boot

**Files:**
- Create: `docker-compose.yml`

- [ ] **Step 1: Write `docker-compose.yml`**

```yaml
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile.dev
    command: bash -lc "mix deps.get && mix ash.setup && mix phx.server"
    working_dir: /workspace
    volumes:
      - .:/workspace
      - deps:/workspace/deps
      - build:/workspace/_build
    ports:
      - "4000:4000"
    env_file:
      - .env
    depends_on:
      db:
        condition: service_healthy
    stdin_open: true
    tty: true

  db:
    image: postgres:16
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: verscienta_dev
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 10

  redis:
    image: redis:7
    ports:
      - "6379:6379"

  meilisearch:
    image: getmeili/meilisearch:v1.10
    environment:
      MEILI_MASTER_KEY: masterKey
      MEILI_ENV: development
    ports:
      - "7700:7700"
    volumes:
      - meili:/meili_data

  ollama:
    image: ollama/ollama
    profiles: ["ai"]
    ports:
      - "11434:11434"
    volumes:
      - ollama:/root/.ollama

volumes:
  deps:
  build:
  pgdata:
  meili:
  ollama:
```

- [ ] **Step 2: Create local `.env` from the example**

Run:
```powershell
Copy-Item .env.example .env
```

- [ ] **Step 3: Boot the stack (without Ollama)**

Run:
```powershell
docker compose up -d db redis meilisearch
docker compose up app
```
Expected: app logs show `Running VerscientaWeb.Endpoint … at 0.0.0.0:4000` and `Access VerscientaWeb.Endpoint at http://localhost:4000`. Migrations from `mix ash.setup` run cleanly against `db`.

- [ ] **Step 4: Verify the home page responds**

In a second terminal, run:
```powershell
(Invoke-WebRequest http://localhost:4000 -UseBasicParsing).StatusCode
```
Expected: `200`.

- [ ] **Step 5: Stop the stack**

Run:
```powershell
docker compose down
```

- [ ] **Step 6: Verify Ollama profile is opt-in**

Run:
```powershell
docker compose config --services
docker compose --profile ai config --services
```
Expected: first list omits `ollama`; second list includes `ollama`.

- [ ] **Step 7: Commit**

```powershell
git add docker-compose.yml
git commit -m "build: add Compose stack (db, redis, meilisearch, opt-in ollama, app)"
```

---

## Task 5: Dev container definition

**Files:**
- Create: `.devcontainer/devcontainer.json`

- [ ] **Step 1: Write `.devcontainer/devcontainer.json`**

```json
{
  "name": "verscienta",
  "dockerComposeFile": ["../docker-compose.yml"],
  "service": "app",
  "workspaceFolder": "/workspace",
  "forwardPorts": [4000, 5432, 7700, 6379],
  "postCreateCommand": "mix deps.get && mix ash.setup",
  "customizations": {
    "vscode": {
      "extensions": ["JakeBecker.elixir-ls", "phoenixframework.phoenix"]
    }
  }
}
```

- [ ] **Step 2: Validate the compose reference resolves**

Run:
```powershell
docker compose -f docker-compose.yml config > $null; if ($?) { "compose OK" }
```
Expected: prints `compose OK` (compose file is valid and referenced path is correct).

- [ ] **Step 3: Commit**

```powershell
git add .devcontainer/devcontainer.json
git commit -m "build: add VS Code dev container definition"
```

---

## Task 6: Codex design tokens + self-hosted font

> **REVISION (after Task 2 — supersedes the Tailwind v3 steps below):** Generation produced
> **Phoenix 1.8 with Tailwind v4** (CSS-first `@import "tailwindcss"`, daisyUI `themes: false`,
> **no `tailwind.config.js`**). We embrace v4 instead of pinning v3. Net changes:
> - Do **not** create `tailwind.config.js` and do **not** change the `:tailwind` version in config.
> - Define Codex tokens in a `@theme { … }` block appended to `assets/css/app.css` using
>   `--color-*`, `--font-sans`, `--ease-*`, `--animate-*` variables.
> - Force-generate the dynamic accent classes (from `CodexComponents.accent_bg/1`) with an
>   `@source inline("bg-zune bg-world …")` directive in `app.css` (replaces the Task 8 `safelist`).
> - Keep daisyUI (`themes: false` already neuters its theming); our `@theme` adds the Codex palette.
> - `static_paths` already includes `fonts`, so `/fonts/*.woff2` will be served.
> The concrete v4 file content is delivered to the implementer in its dispatch prompt.

**Files (revised):**
- Modify: `assets/css/app.css` (add `@theme`, `@font-face`, base canvas, `@source inline`)
- Create: `priv/static/fonts/hanken-grotesk-latin-wght-normal.woff2`
- Create: `priv/static/fonts/hanken-grotesk-latin-wght-italic.woff2`

- [ ] **Step 1: Fetch the Hanken Grotesk variable woff2 files**

Run:
```powershell
New-Item -ItemType Directory -Force priv/static/fonts | Out-Null
Invoke-WebRequest "https://cdn.jsdelivr.net/npm/@fontsource-variable/hanken-grotesk/files/hanken-grotesk-latin-wght-normal.woff2" -OutFile "priv/static/fonts/hanken-grotesk-latin-wght-normal.woff2"
Invoke-WebRequest "https://cdn.jsdelivr.net/npm/@fontsource-variable/hanken-grotesk/files/hanken-grotesk-latin-wght-italic.woff2" -OutFile "priv/static/fonts/hanken-grotesk-latin-wght-italic.woff2"
```
Expected: two `.woff2` files exist and are non-empty (`(Get-Item priv/static/fonts/*.woff2).Length` > 0).

- [ ] **Step 2: Pin Tailwind v3 so the config-file token approach is deterministic**

Recent generators may ship Tailwind v4 (CSS-first `@theme`, no `tailwind.config.js`, no `safelist`). To keep this plan deterministic, pin the classic v3 toolchain. In `config/config.exs`, set the `config :tailwind, …` block to:
```elixir
config :tailwind,
  version: "3.4.13",
  verscienta: [
    args:
      ~w(--config=tailwind.config.js --input=css/app.css --output=../priv/static/assets/app.css),
    cd: Path.expand("../assets", __DIR__)
  ]
```
(Replace the generated `:tailwind` block entirely. Keep the app key name `verscienta` matching what `mix assets.build` aliases reference — check `mix.exs` aliases and use that key if it differs.)

- [ ] **Step 3: Set `assets/css/app.css` (v3 directives, then font, then base)**

Replace the Tailwind import/directive lines at the **top** of `assets/css/app.css` with the v3 directives, then add the font faces and dark-canvas baseline **after** them (order matters — `@import`/`@tailwind` rules must come first, so `@font-face` follows). Keep any other existing rules below.
```css
@tailwind base;
@tailwind components;
@tailwind utilities;

@font-face {
  font-family: "Hanken Grotesk Variable";
  font-style: normal;
  font-display: swap;
  font-weight: 100 900;
  src: url("/fonts/hanken-grotesk-latin-wght-normal.woff2") format("woff2-variations");
}
@font-face {
  font-family: "Hanken Grotesk Variable";
  font-style: italic;
  font-display: swap;
  font-weight: 100 900;
  src: url("/fonts/hanken-grotesk-latin-wght-italic.woff2") format("woff2-variations");
}

html { -webkit-font-smoothing: antialiased; }
body { background: #0c0c0c; color: #ffffff; font-weight: 300; }
::selection { background: #f2660a; color: #000; }
```

- [ ] **Step 4: Write `assets/tailwind.config.js` (v3 form with Codex tokens)**

Create/overwrite `assets/tailwind.config.js` (the `safelist` for dynamic accent classes is added later in Task 8):
```js
module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/verscienta_web.ex",
    "../lib/verscienta_web/**/*.*ex",
  ],
  theme: {
    extend: {
      colors: {
        canvas: { DEFAULT: "#0c0c0c", 2: "#161616", 3: "#1f1f1f" },
        ink: { DEFAULT: "#ffffff", 2: "#b6b6b6", 3: "#6d6d6d" },
        line: "#2a2a2a",
        zune: "#f2660a",
        world: "#1ba1e2",
        politics: "#e51400",
        tech: "#00aba9",
        culture: "#d80073",
        sport: "#8cbf26",
        business: "#f09609",
        opinion: "#a200ff",
      },
      fontFamily: {
        sans: ['"Hanken Grotesk Variable"', "ui-sans-serif", "system-ui", "sans-serif"],
      },
      borderRadius: {
        DEFAULT: "0px", none: "0px", sm: "0px", md: "0px", lg: "0px", xl: "0px",
      },
      transitionTimingFunction: {
        codex: "cubic-bezier(.2,.8,.2,1)",
      },
      keyframes: {
        slidein: { from: { opacity: "0", transform: "translateX(40px)" }, to: { opacity: "1", transform: "none" } },
        rise: { from: { opacity: "0", transform: "translateY(24px)" }, to: { opacity: "1", transform: "none" } },
        turnstile: { from: { transform: "rotateY(90deg)" }, to: { transform: "rotateY(0)" } },
      },
      animation: {
        slidein: "slidein .4s cubic-bezier(.2,.8,.2,1)",
        rise: "rise .6s cubic-bezier(.2,.8,.2,1) backwards",
        turnstile: "turnstile .4s cubic-bezier(.2,.8,.2,1)",
      },
    },
  },
  plugins: [],
}
```

Run:
```powershell
docker run --rm -v ${PWD}:/workspace -w /workspace verscienta-dev bash -lc "mix deps.get && mix tailwind.install --if-missing && mix assets.build"
```
Expected: the Tailwind v3.4.13 binary downloads, then `tailwind` and `esbuild` run with no errors; `priv/static/assets/app.css` is produced and contains a `--tw-` variable / utility classes (confirming v3 ran).

- [ ] **Step 6: Commit**

```powershell
git add assets/tailwind.config.js assets/css/app.css priv/static/fonts config/config.exs
git commit -m "style: add Codex design tokens (Tailwind v3) and self-hosted Hanken Grotesk"
```

---

## Task 7: Root layout — dark canvas + thin strip chrome

**Files:**
- Modify: `lib/verscienta_web/components/layouts/root.html.heex`

- [ ] **Step 1: Replace the `<body>` content of `root.html.heex`**

Set the `<body>` so the canvas is dark and a thin top strip is the only persistent chrome:
```heex
  <body class="bg-canvas font-sans text-ink antialiased">
    <header class="fixed inset-x-0 top-0 z-50 flex items-center gap-7 px-6 py-3.5">
      <a href="/" class="text-[13px] font-extrabold lowercase tracking-wide">
        verscienta<span class="text-zune">·</span>news
      </a>
      <nav class="ml-auto hidden gap-5 text-xs font-medium lowercase tracking-wider text-ink-3 sm:flex">
        <a href="/styleguide" class="transition-colors hover:text-ink">styleguide</a>
      </nav>
    </header>
    {@inner_content}
  </body>
```

- [ ] **Step 2: Boot and verify the strip renders**

Run:
```powershell
docker compose up -d db
docker compose run --rm --service-ports app bash -lc "mix ash.setup && mix phx.server" 
```
In another terminal:
```powershell
(Invoke-WebRequest http://localhost:4000 -UseBasicParsing).Content | Select-String "verscienta"
```
Expected: the response HTML contains `verscienta`. Stop with `Ctrl+C`, then `docker compose down`.

- [ ] **Step 3: Commit**

```powershell
git add lib/verscienta_web/components/layouts/root.html.heex
git commit -m "feat: dark canvas root layout with thin strip chrome"
```

---

## Task 8: Codex starter components + /styleguide page

**Files:**
- Create: `lib/verscienta_web/components/codex_components.ex`
- Create: `lib/verscienta_web/controllers/styleguide_html.ex`
- Create: `lib/verscienta_web/controllers/styleguide_html/index.html.heex`
- Create: `lib/verscienta_web/controllers/styleguide_controller.ex`
- Modify: `lib/verscienta_web/router.ex`

- [ ] **Step 1: Write the starter components module**

Create `lib/verscienta_web/components/codex_components.ex`:
```elixir
defmodule VerscientaWeb.CodexComponents do
  @moduledoc "Codex design-system function components (Zune-inspired)."
  use Phoenix.Component

  attr :rest, :global
  slot :inner_block, required: true

  def kicker(assigns) do
    ~H"""
    <p class="text-[11px] font-semibold uppercase tracking-[0.32em] text-ink-3" {@rest}>
      {render_slot(@inner_block)}
    </p>
    """
  end

  attr :class, :string, default: ""
  slot :inner_block, required: true

  def headline(assigns) do
    ~H"""
    <h2 class={["font-sans font-extralight lowercase leading-[0.9] tracking-tight", @class]}>
      {render_slot(@inner_block)}
    </h2>
    """
  end

  attr :flag, :string, default: "breaking"
  slot :inner_block, required: true

  def breaking_bar(assigns) do
    ~H"""
    <div class="flex items-stretch border border-line">
      <div class="flex items-center whitespace-nowrap bg-politics px-4 py-3.5 text-xs font-extrabold uppercase tracking-wider text-white">
        ● {@flag}
      </div>
      <div class="flex items-center px-4 py-3.5 text-base font-light">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :category, :string, required: true
  attr :accent, :string, default: "world"
  attr :author, :string, default: ""
  attr :meta, :string, default: ""
  slot :inner_block, required: true

  def news_card(assigns) do
    ~H"""
    <article class="flex flex-col border border-line bg-canvas transition-transform duration-200 hover:-translate-y-1.5">
      <div class={["relative h-[170px]", accent_bg(@accent)]}>
        <span class={["absolute bottom-0 left-0 px-2.5 py-1 text-[10px] font-extrabold uppercase tracking-wider text-black", accent_bg(@accent)]}>
          {@category}
        </span>
      </div>
      <div class="px-5 pb-6 pt-5">
        <h5 class="mb-3 text-xl font-light leading-tight">{render_slot(@inner_block)}</h5>
        <div class="flex justify-between text-[11px] text-ink-3">
          <span class="text-ink-2">{@author}</span><span>{@meta}</span>
        </div>
      </div>
    </article>
    """
  end

  attr :accent, :string, default: "tech"
  attr :label, :string, required: true
  slot :inner_block, required: true

  def tile(assigns) do
    ~H"""
    <div class={["flex h-[150px] flex-col justify-end p-4 text-white", accent_bg(@accent)]}>
      <div class="text-[11px] font-extrabold uppercase tracking-wider opacity-85">{@label}</div>
      <h6 class="mt-1.5 text-base font-light leading-tight">{render_slot(@inner_block)}</h6>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :handle, :string, required: true
  attr :when, :string, default: ""
  attr :accent, :string, default: "tech"
  slot :inner_block, required: true

  def feed_post(assigns) do
    ~H"""
    <article class="border border-line bg-canvas px-6 py-5 transition-colors hover:border-[#3a3a3a]">
      <div class="mb-4 flex items-center gap-3.5">
        <div class={["flex h-11 w-11 items-center justify-center text-lg font-extrabold text-black", accent_bg(@accent)]}>
          {String.slice(@name, 0, 2)}
        </div>
        <div>
          <div class="text-[15px] font-semibold">{@name}</div>
          <div class="text-xs text-ink-3">{@handle}</div>
        </div>
        <div class="ml-auto text-[11px] uppercase tracking-wider text-ink-3">{@when}</div>
      </div>
      <div class="text-base font-light leading-snug">{render_slot(@inner_block)}</div>
    </article>
    """
  end

  attr :accent, :string, default: "zune"
  attr :icon, :string, default: "+"
  attr :when, :string, default: ""
  slot :inner_block, required: true

  def notif(assigns) do
    ~H"""
    <div class="flex items-center gap-4 border-b border-line px-5 py-4">
      <span class={["w-[3px] self-stretch", accent_bg(@accent)]}></span>
      <span class={["flex h-9 w-9 items-center justify-center text-[13px] font-extrabold text-black", accent_bg(@accent)]}>
        {@icon}
      </span>
      <span class="text-sm font-light text-ink-2">{render_slot(@inner_block)}</span>
      <span class="ml-auto whitespace-nowrap text-[11px] uppercase tracking-wider text-ink-3">{@when}</span>
    </div>
    """
  end

  attr :rest, :global, include: ~w(type href)
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button class="bg-zune px-6 py-3 text-xs font-bold uppercase tracking-wider text-black transition-[filter] hover:brightness-110" {@rest}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  # Maps a Codex accent name to its Tailwind background class.
  defp accent_bg("zune"), do: "bg-zune"
  defp accent_bg("world"), do: "bg-world"
  defp accent_bg("politics"), do: "bg-politics"
  defp accent_bg("tech"), do: "bg-tech"
  defp accent_bg("culture"), do: "bg-culture"
  defp accent_bg("sport"), do: "bg-sport"
  defp accent_bg("business"), do: "bg-business"
  defp accent_bg("opinion"), do: "bg-opinion"
  defp accent_bg(_), do: "bg-canvas-2"
end
```

- [ ] **Step 2: Whitelist the accent classes for Tailwind (safelist)**

Tailwind only emits classes it sees as literal strings. Since `accent_bg/1` returns class names, add a safelist to `assets/tailwind.config.js` at the top level of the exported config object:
```js
  safelist: [
    "bg-zune", "bg-world", "bg-politics", "bg-tech",
    "bg-culture", "bg-sport", "bg-business", "bg-opinion", "bg-canvas-2",
  ],
```

- [ ] **Step 3: Write the styleguide controller**

Create `lib/verscienta_web/controllers/styleguide_controller.ex`:
```elixir
defmodule VerscientaWeb.StyleguideController do
  use VerscientaWeb, :controller

  def index(conn, _params), do: render(conn, :index)
end
```

- [ ] **Step 4: Write the styleguide HTML view module**

Create `lib/verscienta_web/controllers/styleguide_html.ex`:
```elixir
defmodule VerscientaWeb.StyleguideHTML do
  use VerscientaWeb, :html
  import VerscientaWeb.CodexComponents

  embed_templates "styleguide_html/*"
end
```

- [ ] **Step 5: Write the styleguide template**

Create `lib/verscienta_web/controllers/styleguide_html/index.html.heex`:
```heex
<div class="px-6 pb-24 pt-28">
  <.kicker>codex · component showcase</.kicker>
  <.headline class="mb-12 text-6xl">styleguide</.headline>

  <p class="mb-3 text-[11px] uppercase tracking-widest text-ink-3">breaking bar</p>
  <div class="mb-12">
    <.breaking_bar>
      <b class="font-semibold">Council approves river crossing</b>&nbsp;— first new bridge in a generation.
    </.breaking_bar>
  </div>

  <p class="mb-3 text-[11px] uppercase tracking-widest text-ink-3">news cards</p>
  <div class="mb-12 grid gap-7 sm:grid-cols-2 lg:grid-cols-3">
    <.news_card category="world" accent="world" author="R. Adeyemi" meta="4 min · today">
      Coastal nations sign a new accord on shipping lanes
    </.news_card>
    <.news_card category="tech" accent="tech" author="L. Hartman" meta="5 min · today">
      The quiet return of the dedicated music device
    </.news_card>
    <.news_card category="culture" accent="culture" author="S. Velez" meta="3 min · 1h ago">
      An archive of forgotten interface music, restored
    </.news_card>
  </div>

  <p class="mb-3 text-[11px] uppercase tracking-widest text-ink-3">tiles</p>
  <div class="mb-12 grid grid-cols-2 gap-3.5 sm:grid-cols-4">
    <.tile accent="politics" label="politics · live">Vote count enters its final hour</.tile>
    <.tile accent="world" label="world">Accord signed by 14 nations</.tile>
    <.tile accent="business" label="business">Markets up 2%</.tile>
    <.tile accent="sport" label="sport">Underdogs win it</.tile>
  </div>

  <p class="mb-3 text-[11px] uppercase tracking-widest text-ink-3">feed post</p>
  <div class="mb-12 max-w-xl">
    <.feed_post name="Lena Hartman" handle="@lhartman" when="12m" accent="tech">
      spent the afternoon with a 2009 media player and the interface still feels faster than half my apps.
    </.feed_post>
  </div>

  <p class="mb-3 text-[11px] uppercase tracking-widest text-ink-3">notifications</p>
  <div class="mb-12 border border-line">
    <.notif accent="zune" icon="+" when="2m"><b class="text-ink">R. Adeyemi</b> started following you</.notif>
    <.notif accent="culture" icon="♥" when="18m"><b class="text-ink">3 people</b> liked your post</.notif>
    <.notif accent="tech" icon="@" when="1h"><b class="text-ink">S. Velez</b> mentioned you in a reply</.notif>
  </div>

  <p class="mb-3 text-[11px] uppercase tracking-widest text-ink-3">button</p>
  <.button>+ follow</.button>
</div>
```

- [ ] **Step 6: Add the route**

In `lib/verscienta_web/router.ex`, inside the existing `scope "/", VerscientaWeb do … pipe_through :browser` block, add:
```elixir
    get "/styleguide", StyleguideController, :index
```

- [ ] **Step 7: Verify it compiles and the page renders**

Run:
```powershell
docker compose up -d db
docker compose run --rm --service-ports app bash -lc "mix ash.setup && mix phx.server"
```
In another terminal:
```powershell
(Invoke-WebRequest http://localhost:4000/styleguide -UseBasicParsing).Content | Select-String "component showcase"
```
Expected: response contains `component showcase`. Stop with `Ctrl+C`; `docker compose down`.

- [ ] **Step 8: Commit**

```powershell
git add lib/verscienta_web/components/codex_components.ex lib/verscienta_web/controllers/styleguide_controller.ex lib/verscienta_web/controllers/styleguide_html.ex lib/verscienta_web/controllers/styleguide_html assets/tailwind.config.js lib/verscienta_web/router.ex
git commit -m "feat: Codex starter components and dev styleguide page"
```

---

## Task 9: Accounts domain + User resource skeleton

A minimal Ash domain and `User` resource that compiles and migrates. No login UI (Phase 1). The resource carries an email identity + AshAuthentication password strategy stub so the foundation is ready.

**Files:**
- Create: `lib/verscienta/accounts.ex`
- Create: `lib/verscienta/accounts/user.ex`
- Modify: `config/config.exs` (register the domain under `:ash_domains`)
- Create (generated): migration under `priv/repo/migrations/`

- [ ] **Step 1: Write the domain**

Create `lib/verscienta/accounts.ex`:
```elixir
defmodule Verscienta.Accounts do
  @moduledoc "Accounts bounded context — users and authentication."
  use Ash.Domain

  resources do
    resource Verscienta.Accounts.User
  end
end
```

- [ ] **Step 2: Write the `User` resource skeleton**

Create `lib/verscienta/accounts/user.ex`:
```elixir
defmodule Verscienta.Accounts.User do
  @moduledoc "Application user."
  use Ash.Resource,
    domain: Verscienta.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "users"
    repo Verscienta.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :ci_string, allow_nil?: false, public?: true
    attribute :hashed_password, :string, allow_nil?: true, sensitive?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_email, [:email]
  end

  actions do
    defaults [:read]

    create :register do
      accept [:email]
    end
  end
end
```

- [ ] **Step 3: Register the domain**

In `config/config.exs`, ensure (add if missing):
```elixir
config :verscienta, ash_domains: [Verscienta.Accounts]
```
If an `ash_domains` line already exists, add `Verscienta.Accounts` to the list rather than duplicating.

- [ ] **Step 4: Generate the migration**

Run:
```powershell
docker run --rm -v ${PWD}:/workspace -w /workspace verscienta-dev bash -lc "mix ash.codegen create_users"
```
Expected: a new migration file appears under `priv/repo/migrations/` creating the `users` table with `email`, `hashed_password`, timestamps, and a unique index on `email`.

- [ ] **Step 5: Apply the migration and confirm it compiles**

Run (compile needs no DB; migrations run via Compose which is on the `db` network):
```powershell
docker run --rm -v ${PWD}:/workspace -w /workspace verscienta-dev bash -lc "mix compile"
docker compose up -d db
docker compose run --rm app bash -lc "mix ash.setup"
docker compose down
```
Expected: `mix compile` succeeds; `mix ash.setup` creates the DB and runs migrations including `create_users` with no errors.

- [ ] **Step 6: Commit**

```powershell
git add lib/verscienta/accounts.ex lib/verscienta/accounts/user.ex config/config.exs priv/repo/migrations
git commit -m "feat: Accounts domain and User resource skeleton"
```

---

## Task 10: Smoke tests

Now we add real ExUnit tests for the foundation. These are the Phase 0 acceptance gate.

**Files:**
- Create: `test/verscienta_web/smoke_test.exs`
- Create: `test/verscienta/accounts_test.exs`

- [ ] **Step 1: Write the web smoke test**

Create `test/verscienta_web/smoke_test.exs`:
```elixir
defmodule VerscientaWeb.SmokeTest do
  use VerscientaWeb.ConnCase, async: true

  test "home page renders", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "verscienta"
  end

  test "styleguide page renders the component showcase", %{conn: conn} do
    conn = get(conn, ~p"/styleguide")
    assert html_response(conn, 200) =~ "component showcase"
  end
end
```

- [ ] **Step 2: Run the web smoke test to verify it passes**

Run:
```powershell
docker compose up -d db
docker compose run --rm -e MIX_ENV=test app bash -lc "mix ash.setup && mix test test/verscienta_web/smoke_test.exs"
```
Expected: `2 tests, 0 failures`.

- [ ] **Step 3: Write the Accounts test**

Create `test/verscienta/accounts_test.exs`:
```elixir
defmodule Verscienta.AccountsTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Accounts.User

  test "can register and read a user via the Ash domain" do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(:register, %{email: "founder@verscienta.news"})
      |> Ash.create()

    assert to_string(user.email) == "founder@verscienta.news"
    assert [_] = Ash.read!(User)
  end
end
```

- [ ] **Step 4: Run the Accounts test to verify it passes**

Run:
```powershell
docker compose run --rm -e MIX_ENV=test app bash -lc "mix test test/verscienta/accounts_test.exs"
docker compose down
```
Expected: `1 test, 0 failures`.

- [ ] **Step 5: Run the full suite + quality gates**

Run:
```powershell
docker compose up -d db
docker compose run --rm -e MIX_ENV=test app bash -lc "mix ash.setup && mix test"
docker compose run --rm app bash -lc "mix format --check-formatted && mix compile --warnings-as-errors"
docker compose down
```
Expected: all tests pass; `mix format --check-formatted` exits 0 (run `mix format` first if it complains, then re-commit); `mix compile --warnings-as-errors` exits 0.

- [ ] **Step 6: Commit**

```powershell
git add test
git commit -m "test: smoke tests for web pages and Accounts domain"
```

---

## Task 11: CI pipeline

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/ci.yml`:
```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest

    services:
      db:
        image: postgres:16
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: verscienta_test
        ports: ["5432:5432"]
        options: >-
          --health-cmd "pg_isready -U postgres"
          --health-interval 5s --health-timeout 5s --health-retries 10

    env:
      MIX_ENV: test
      DB_HOST: localhost
      DB_USER: postgres
      DB_PASSWORD: postgres
      DB_NAME: verscienta_test

    steps:
      - uses: actions/checkout@v4

      - uses: erlef/setup-beam@v1
        with:
          elixir-version: "1.18.4"
          otp-version: "27.3.4"

      - name: Cache deps and _build
        uses: actions/cache@v4
        with:
          path: |
            deps
            _build
          key: ${{ runner.os }}-mix-${{ hashFiles('**/mix.lock') }}
          restore-keys: ${{ runner.os }}-mix-

      - run: mix deps.get
      - run: mix assets.setup        # installs pinned esbuild + tailwind binaries
      - run: mix assets.build        # produces priv/static/assets so verified static routes resolve
      - run: mix compile --warnings-as-errors
      - run: mix format --check-formatted
      - run: mix credo --strict
      - run: mix ash.setup
      - run: mix test
```

- [ ] **Step 2: Confirm `credo` is available**

Run:
```powershell
docker compose run --rm app bash -lc "mix credo --strict || true"
```
Expected: Credo runs (phx.new includes it as a dev/test dep). If it reports "could not find credo", add `{:credo, "~> 1.7", only: [:dev, :test], runtime: false}` to `mix.exs` deps, run `mix deps.get`, and commit that change too.

- [ ] **Step 3: Validate the workflow YAML locally**

Run:
```powershell
docker run --rm -v ${PWD}:/w -w /w verscienta-dev bash -lc "python3 -c 'import yaml,sys; yaml.safe_load(open(\".github/workflows/ci.yml\")); print(\"yaml ok\")' || node -e 'require(\"fs\").readFileSync(\".github/workflows/ci.yml\"); console.log(\"read ok\")'"
```
Expected: prints `yaml ok` (or `read ok`). This is a sanity check only; full validation happens when GitHub runs it.

- [ ] **Step 4: Commit**

```powershell
git add .github/workflows/ci.yml mix.exs mix.lock
git commit -m "ci: add compile/format/credo/test GitHub Actions pipeline"
```

---

## Task 12: README onboarding + final verification

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a "Getting Started" section to `README.md`**

Insert after the intro/vision section, before "Core Features":
```markdown
## Getting Started (Local Development)

Everything runs in Docker — you do not need Elixir installed on the host.

```bash
# 1. Copy environment defaults
cp .env.example .env            # PowerShell: Copy-Item .env.example .env

# 2. Build the dev image
docker build -f Dockerfile.dev -t verscienta-dev .

# 3. Start backing services + the app
docker compose up
```

The app is served at http://localhost:4000 — the front page and the component
showcase at http://localhost:4000/styleguide.

Optional self-hosted AI (Ollama) is opt-in:

```bash
docker compose --profile ai up ollama
```

### Common tasks

```bash
docker compose run --rm app bash -lc "mix test"     # run the test suite
docker compose run --rm app bash -lc "mix format"   # format code
docker compose run --rm app bash -lc "mix ash.codegen <name>"  # generate migrations
```

Or open the folder in VS Code and "Reopen in Container" (uses `.devcontainer`).
```

- [ ] **Step 1b: Add `.tool-versions` (documents the pinned runtime for native/asdf fallback)**

Create `.tool-versions` at the repo root:
```
erlang 27.3.4
elixir 1.18.4-otp-27
nodejs 22.14.0
```

- [ ] **Step 2: Full clean verification from scratch**

Run:
```powershell
docker compose down -v
docker build -f Dockerfile.dev -t verscienta-dev .
docker compose up -d db redis meilisearch
docker compose run --rm app bash -lc "mix deps.get && mix ash.setup && MIX_ENV=test mix ash.setup && mix test && mix format --check-formatted && mix compile --warnings-as-errors"
```
Expected: deps resolve, DBs set up, all tests pass, format clean, no warnings.

- [ ] **Step 3: Verify the running app one more time**

Run:
```powershell
docker compose up -d
Start-Sleep -Seconds 8
(Invoke-WebRequest http://localhost:4000 -UseBasicParsing).StatusCode
(Invoke-WebRequest http://localhost:4000/styleguide -UseBasicParsing).StatusCode
docker compose down
```
Expected: both return `200`.

- [ ] **Step 4: Commit**

```powershell
git add README.md .tool-versions
git commit -m "docs: add local development onboarding and .tool-versions"
```

---

## Definition of Done (verify all)

- [ ] `docker compose up` serves the app at `localhost:4000`; `/` and `/styleguide` both return `200` with Codex styling.
- [ ] `mix test` passes (web smoke + Accounts).
- [ ] `mix format --check-formatted`, `mix credo --strict`, and `mix compile --warnings-as-errors` all pass.
- [ ] Ollama is excluded from default `docker compose up` and only starts under `--profile ai`.
- [ ] CI workflow committed and structured to run the same gates.
- [ ] README documents the container-based onboarding.
- [ ] All work committed on `main` with the existing git identity.
