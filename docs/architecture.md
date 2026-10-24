# Architecture — Verscienta News on KilnCMS v1.0.0

Slice 1 scope is `docs/slice-1.md`. The public page is the fired Kiln alias `/[field:category]/[slug]`.

```
Oban cron (15m, Allowlist) ── Req ──► Poller.apply_license (truncate before store) ──► Article in_review
Ollama :11434 (Compose profile ml, advisory) ──► summary / flag only; outage leaves the draft in_review
/editor?status=in_review ── checklist ──► published ──► fired /[field:category]/[slug]
```

Kiln owns content workflow (`draft`, `in_review`, `published`, `archived`), firing, headless read APIs, Postgres full-text search, newsletter, billing, notifications, and outbound `KilnCMS.Social` (Bluesky and Mastodon on publish). That module is not a follow graph.

The overlay adds the `Article` type, the `WellnessCallout` block, `VerscientaNews.Ingestion.Allowlist`, and the poller. Follow graph and gamification stay out of `ash_domains` until after Slice 1.

## Delivery

One public path. Kiln fires `/[field:category]/[slug]` from `alias_pattern` on `VerscientaNews.Catalog.Article`. Headless JSON for that same article is `/api/content/article/:slug?format=json`. Slice 1 does not require a Svelte route to match the fired body. Routes under `frontend/` are not the Slice 1 reader.

Authoring is Kiln `/editor`. Review is `/editor?status=in_review`.

## Modules

| Concern | Module | Slice 1 |
|---|---|---|
| Allowlist | `VerscientaNews.Ingestion.Allowlist` | Registry the poller reads |
| Poll | `VerscientaNews.Ingestion.Poller` | Oban + Req. `apply_license/1` before storage. State `in_review` |
| AI | `VerscientaNews.AI.Llama` | Advisory. Does not publish |
| Search | `KilnCMS.Search` | Postgres full text |
| Newsletter, billing | `KilnCMS.Newsletter`, `KilnCMS.Billing` | Present in Kiln. Not a Slice 1 exit |
| Follow graph | `VerscientaNews.FollowGraph` | After Slice 1. Not named `Social` |
| Gamification | `VerscientaNews.Gamification` | After Slice 1, and only with non-dwell metrics |
| Live rooms | Phoenix Channel, LiveKit | Off |

Realtime is `Phoenix.PubSub`. Cache and rate limit are Cachex and Hammer. Dragonfly waits on a multi-node measurement. There is no Redis.

## Auth

AshAuthentication. Svelte sessions are unspecified because Slice 1 has no Svelte writes.

## Stack

| Layer | Choice |
|---|---|
| Backend | `kiln_cms` v1.0.0 submodule, overlay `projects/verscienta_news/` |
| Poll | Oban, Req, Floki, ElixirFeedParser. Ollama optional, profile `ml` |
| Search | Kiln Postgres full text |
| Database | Postgres 16 with the `vector` extension, because Kiln's repo registers that type. Semantic search stays off |
| Reader | Fired Kiln page |
