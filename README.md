# Verscienta News

Wellness reader on **KilnCMS v1.0.0** (submodule `kiln_cms/`, overlay `projects/verscienta_news/`). Single delivery path is Kiln fired `/:slug`; SvelteKit is a thin reader until the cut line.

> Critique applied: `docs/plan-critique.md` — see `docs/slice-1.md` for the first shippable, `docs/source-rights.md` for legal gate, and `docs/architecture.md` for the deferred-correct ADS.

## Stack

| Layer | Choice |
|---|---|
| Backend | `kiln_cms` v1.0.0 (`kiln_cms/`), overlay `projects/verscienta_news/` |
| Poll/AI | Oban + Req/Floki/ElixirFeedParser + Ollama advisory (no Broadway, no auto-publish threshold) |
| Search | Kiln Postgres FTS Slice 1; Meilisearch/pgvector deferred |
| Reader | SvelteKit + TS + Tailwind 4 + Vite (`phoenix` JS reserved for Slice 3 channels) |
| Trust | Human review queue + `source_license`/`attribution`/`claim_status` + disclaimer (Slice 1) |
| DB/ops | Postgres 16, Cachex/Hammer, PubSub; Dragonfly deferred (Kiln D2) |

## Quick start

```bash
docker compose up -d postgres
cd kiln_cms
mix setup        # deps.get + ash.setup + assets.setup
mix phx.server   # http://localhost:4000  (fired /:slug lives here)

# reader (thin fetch of /api/content/article/:slug?format=json)
cd ../frontend
npm install
npm run dev      # http://localhost:5173
```

Auth: **AshAuthentication** (not Pow/Ueberauth). Log in at Kiln `/sign-in`; Svelte forwards session cookie / `Authorization: Bearer <api_key>` (from `POST /api/auth/sign_in`). No writes from Svelte until Slice 1 exit.

## Structure

```
kiln_cms/                      # submodule v1.0.0
projects/verscienta_news/      # canonical overlay (copied into image)
  catalog.ex / catalog/article.ex  # source_url unique + source_license/attribution/claim fields
  blocks/wellness_callout.ex
  services/ (poller, ai_llama advisory, recommendation deferred)
  plugin.ex
config/project.exs             # overlay activation
frontend/                      # thin reader: /, /article/[slug], /category/*, /search
docs/slice-1.md, source-rights.md, architecture.md, ingestion.md, moderation.md
```

Image:

```dockerfile
COPY kiln_cms /app/kiln_cms
COPY projects/verscienta_news /app/kiln_cms/projects/verscienta_news
COPY config/project.exs /app/kiln_cms/config/project.exs
```

## Delivery (single path)

Fired `web` at `/:slug` + `?format=json` for the reader. No Svelte `/write` TipTap — author at Kiln `/editor`. See `docs/slice-1.md` exit criteria before promoting follow graph / vitality / For You / LiveKit.

## Verify

```bash
cd kiln_cms && mix precommit
mix kiln.plugins.doctor && mix kiln.search.check
cd ../frontend && npm run check && npm run build
```

Design tokens: `frontend/src/lib/tokens/codex.css` (Codex-gated, see `docs/design/codex-notes.md`).
