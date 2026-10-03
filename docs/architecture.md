# Architecture

## Overview

Verscienta News layers on KilnCMS v1.0.0 (submodule `kiln_cms/`, overlay `projects/verscienta_news/`). Kiln owns publishing (blocks, workflow, versioning, firing, headless APIs, search). Overlay adds wellness catalog + middleware services (ingestion, AI, social, gamification).

```
Browser (SvelteKit :5173) ── fetch/Channels ──► KilnCMS :4000 ── fired artifacts /api/* ──┐
                                    └─ Meilisearch :7700 ◄── Oban indexing ───────────────┤
Frontend proxy /api + /socket ──► Phoenix ──► Ash domains (Catalog, Social, Gamification) ─► Postgres :5432
Broadway (RSS/APIs/HTML) ──► NormalizedArticle ──► Ollama Llama :11434 (summarize/tag/quality) ─► Kiln Post draft
Phoenix Channels + LiveKit SFU ──► Rooms/Presence
```

## Backend (Kiln)

- **Content**: `VerscientaNews.Catalog.Article` (`type: :article`, alias `/[field:category]/[slug]`, excerpt, SEO patterns). Embedded blocks (Portable Text canonical via D12) — see `blocks/wellness_callout.ex`.
- **Activation**: `config/project.exs` restates core `ash_domains`/`content_domains` + adds `VerscientaNews.Catalog`; `Kiln.Plugin` declares domains/blocks (verified by `mix kiln.plugins.doctor`).
- **Delivery**: fired artifacts (`web`/`json`/`json_ld`) via `PublishedArtifact` + Cachex; headless at `/api/content/article/:slug`, `/api/search`, `/api/json`, `/gql`.

## Middleware (same OTP release)

| Concern | Module | Impl |
|---|---|---|
| Ingestion | `VerscientaNews.Ingestion.Pipeline` | Broadway pipeline per source (RSS `ElixirFeedParser`, HTML `Floki`, API `Req`), batchers dedupe by URL hash, Oban cron 15m |
| Normalization | `VerscientaNews.Ingestion.Normalize` | HTML → TipTap JSON → Portable Text; extract cover, tags, category guess |
| AI | `VerscientaNews.AI.Llama` | Req client to Ollama `http://ollama:11434/api/generate`; prompts for summary (2–3 sentences), tags (fixed taxonomy), quality_score 0–100, toxicity/claim flag |
| Recommendations | `VerscientaNews.Recommendation` | RRF fusion: Meilisearch keyword + pgvector block embeddings (Kiln D16) + collaborative signals; `Recommendation` Ash resource |
| Gamification | `VerscientaNews.Gamification` | Vitality ledger, badges, quests, leaderboard matviews |
| Social | `VerscientaNews.Social` | Follows, comments (closure), reactions, reposts, communities, activity feed fanout via PubSub |

## Frontend (SvelteKit)

- Routes: `/` (For You / Following tabs), `/article/[slug]`, `/category/[cat]`, `/search`, `/write` (TipTap), `/c/[handle]`, `/room/[id]`.
- State: Svelte stores + Phoenix Channels (`src/lib/api/realtime.ts`); Meilisearch `instant-meilisearch`.
- Tokens: `src/lib/tokens/codex.css` (`--color-primary` ember #c45a1a, secondary herbal #2f6b4a, accent gold #8b6b3a). Codex-gated — replace with `the-codex-v6.html` values when readable.

## Decisions carried from plan

- BFF stays Elixir (one BEAM) — Node/Go rejected for auth/policy duplication.
- SvelteKit over Next.js — smaller bundle for long-form reading; Next.js remains fallback if hiring favors React.
- Dragonfly deferred (D2) — Cachex/Hammer + Postgres (Oban) until multi-node measured.
- LiveKit additive behind `livekit_enabled`.
