# Verscienta News

Wellness-focused news reader built on **KilnCMS** (Elixir/Ash/Phoenix) + **SvelteKit** frontend. See `docs/project-overview.md` (Codex-gated) and `kiln_cms/KilnCMS_Project_Plan.md` for upstream architecture.

## Stack

| Layer | Choice |
|---|---|
| Backend CMS | `kiln_cms` v1.0.0 pinned as git submodule (`kiln_cms/`), overlay `projects/verscienta_news/` |
| Middleware / BFF | Elixir (Broadway + Oban + Req) in same OTP release; Ollama Llama for AI |
| Search | Postgres FTS + Meilisearch (hybrid) + pgvector semantic |
| Frontend | SvelteKit + TypeScript + Tailwind 4 + Vite, TipTap editor, `phoenix` JS Channels |
| Realtime / Rooms | Phoenix Channels + Presence; LiveKit (WebRTC) optional profile |
| DB | Postgres 16; Dragonfly optional multi-node cache |

## Quick start

```bash
docker compose up -d postgres
# optional: docker compose --profile search up -d
# optional: docker compose --profile ml up -d   # ollama

cd kiln_cms
mix setup        # deps.get + ash.setup + assets.setup
mix phx.server   # http://localhost:4000 (Kiln + delivery)

# frontend (separate terminal)
cd ../frontend
npm install
npm run dev      # http://localhost:5173 proxies /api to :4000
```

Overlay activation: `config/project.exs` (and duplicate at `kiln_cms/config/project.exs` for local dev without Docker) registers `VerscientaNews.Catalog` + `VerscientaNews.Plugin`.

## Project structure

```
kiln_cms/                      # submodule, v1.0.0
projects/verscienta_news/      # canonical overlay (copied into image)
  catalog.ex / catalog/article.ex
  blocks/wellness_callout.ex
  plugin.ex
  project.exs                  # also at config/project.exs + kiln_cms/config/project.exs
config/project.exs             # overlay activation
frontend/                      # SvelteKit app
docker-compose.yml             # postgres + optional profiles
```

Building the overlaid image (production, `PROJECT=verscienta_news`):

```dockerfile
COPY kiln_cms /app/kiln_cms
COPY projects/verscienta_news /app/kiln_cms/projects/verscienta_news
COPY config/project.exs /app/kiln_cms/config/project.exs
RUN --build-arg PROJECT=verscienta_news mix release
```

## Delivery

- Public web: Kiln renders `/<slug>` from fired artifacts (`VerscientaNews.Catalog.Article`); headless: `/api/json`, `/gql`, `/api/content/article/:slug`, `/api/search`, `/sitemap.xml`, `/feed.json`.
- Frontend consumes headless APIs; channels at `/socket` for comments/rooms/presence.

## Verify

```bash
cd kiln_cms && mix precommit              # format, credo --strict, dialyzer, sobelow, tests
mix kiln.plugins.doctor && mix kiln.search.check
cd ../frontend && npm run check && npm run build
```

Design tokens: `frontend/src/lib/tokens/codex.css` (Codex-gated — map Kiln ember `base-*/primary` to `the-codex-v6.html` values when readable). See `docs/design/codex-notes.md`.
