# Verscienta News — project overview

The cut line is `docs/slice-1.md`. This page is the product outline. Exit tests live only in that file.

## 1. What ships first

Verscienta News is a curated holistic health reader. Slice 1 is one category of articles on the fired Kiln page, reviewed by a person before they are public.

- Public URL: `/[field:category]/[slug]`, fired by Kiln. No second reader in Slice 1.
- Ingested drafts use Kiln state `in_review`. There is no `pending_review` state and no score that publishes.
- Review queue: `/editor?status=in_review`, with the checklist in `docs/moderation.md`.
- Sources come from `VerscientaNews.Ingestion.Allowlist`. The poller truncates `excerpt_link` bodies to 280 characters of plain text before storage, and stores no body for `link_only`.
- Ollama is advisory. Compose profile `ml`. If it is down, the draft still waits in `in_review`.
- Claim status is `unreviewed`, `flagged`, or `cleared`. `verified` waits for Verified Expert.
- The fired page always renders attribution and: "Not medical advice — for information only. Consult a qualified professional."

## 2. What waits

Follows, comments, communities, activity, vitality, leaderboards, recommendations, Meilisearch, pgvector search, LiveKit, a Svelte reader, Broadway, and Redis. Newsletter and billing already exist in Kiln. Turning them on is not a Slice 1 exit.

Order after exit is in `docs/slice-1.md`.

## 3. Stack

| Layer | Choice |
|---|---|
| Backend | KilnCMS v1.0.0 submodule plus overlay `projects/verscienta_news/` |
| Reader | Fired Kiln page |
| Database | PostgreSQL 16. The `vector` extension is required because Kiln registers that type. Semantic search stays off |
| Search | Kiln Postgres full text |
| AI | Ollama, advisory, `OLLAMA_URL` default `http://localhost:11434`, Compose profile `ml` |
| Cache and realtime | Cachex, Hammer, `Phoenix.PubSub`. No Redis |
| Jobs | Oban. The poll is Req, not Broadway |
| Auth | AshAuthentication |

Hosting notes for Coolify are in `docs/deploy-coolify.md`.

## 4. Models in Slice 1

- `VerscientaNews.Catalog.Article` — Kiln content type, alias `/[field:category]/[slug]`, Portable Text.
- `VerscientaNews.Ingestion.Allowlist` — the source registry.
- `ModerationFlag` — toxicity, claim, takedown, report. Opened by the advisory model or a person. Does not publish.

Users, follows, and gamification records are not Slice 1.

## 5. Design

`docs/design/the-codex-v6.html` is the Codex (dark theme, `#0c0c0c`). `frontend/src/lib/tokens/codex.css` is a separate earth palette. See `docs/design/codex-notes.md`. Slice 1's reader is the Kiln fired page, so the Svelte palette is not on the Slice 1 exit path.
