# Outline and overlay plan critique

> **Historical.** This is the 3 Oct 2026 critique of the first outline. The current scope is `docs/slice-1.md`. See `docs/README.md`. Do not treat the verdict below as the state of the docs now.

Critique of the Verscienta News outline in `news-verscienta/docs/project-overview.md` and the Kiln overlay plan in this repo (`docs/architecture.md`, `docs/ingestion.md`, `docs/social.md`, `docs/gamification.md`, `docs/moderation.md`). Compared with KilnCMS v1.0.0 as pinned in the submodule.

Reviewed 3 Oct 2026. Status below is what the documents commit to, not what a later implementation might add.

## Verdict

Do not build from these documents as they stand.

The outline is a stack wishlist with engagement scheduled before trust. The overlay correctly keeps one Elixir release and defers Dragonfly, then specifies a second product — SvelteKit, a follow graph, vitality, Broadway, LiveKit, and reciprocal rank fusion — at the same altitude. Four gaps block a first release: source rights, a real review gate, a single delivery path, and an explicit cut line.

| | |
|---|---|
| Blockers | 4 |
| Conflicts with Kiln | 5 |
| Outline phases with no exit criteria | 4 |
| Kiln v1.0.0 already covers | newsletter, billing, search |

## What each document is

**Product outline** (`project-overview.md`, 175 lines). Titled a complete development plan. It names a reader outcome in one paragraph, then spends the rest on technologies: LiveView, Redis, Coolify, Ollama, Meilisearch, PostHog, Cloudflare Images. Phases are calendar blocks (8–12, 8, 8–10 weeks) with no acceptance test, owner, dependency, or non-goal. Auth is written as “Pow or Ueberauth.”

**Overlay plan** (`docs/architecture.md` plus the feature docs). A module map plus four decisions carried forward: one BEAM, SvelteKit, Dragonfly deferred, LiveKit behind a flag. The feature docs are stubs that point at modules and tests that are not in the tree. The durable decision is real: `Article` is a Kiln content type, fired, with a category alias. Everything social and algorithmic is still a noun list.

## Coverage against a wellness publisher

| Concern | Outline | Overlay plan |
|---|---|---|
| Article as Kiln content | Missing | Present |
| Fired public delivery | LiveView pages | Claimed, and a second route is also specified |
| Source rights and takedown | Missing | Missing |
| Human review before publish | Phase 3 | Threshold auto-publish |
| Medical disclaimer | One security bullet | Missing |
| Auth | Pow or Ueberauth | Inherited; Svelte session unset |
| Search | Meilisearch required | Kiln search; Meilisearch optional |
| Digests | Phase 3, greenfield | Kiln newsletter already exists |
| Subscriptions | Phase 4, greenfield | Kiln billing already exists |
| Social graph | Phase 2 | New domain; name collides with `KilnCMS.Social` |
| Live rooms | Phase 3 | Flagged, drawn as core |
| Redis / Dragonfly | Required | Deferred; matches Kiln D2 |
| Observability and GDPR | Grafana, Sentry, export | Missing from the overlay |

## Blockers

### Republication rights are unspecified

Outline §2, ingestion doc. RSS, JSON APIs, and HTML scrape become Kiln drafts. Nothing says which sources allow full text, excerpt-plus-link, or nothing. No robots policy, license field, attribution block, or takedown path. That is the product’s legal core.

### A model score is treated as a publish gate

Ingestion doc, `projects/verscienta_news/services/ai_llama.ex`. A score of 75 or higher is auto-publish eligible. The rubric asks the model for freshness and source trust it cannot observe unless the pipeline injects them. The stub `score/1` returns 75, which is the threshold. `claim_risk` (low/med/high) and toxicity (bool) are two different contracts, and neither blocks publish.

### Trust work sits after engagement work

Outline phases 1–3. Phase 1 ships aggregation, comments, reactions, and points. Expert review, claim detection, and the disclaimer are phase 3. For wellness claims, the review queue and an on-article disclaimer belong in the first slice, ahead of follows and vitality.

### There is no first shippable slice

Outline §10, `docs/architecture.md`. Phase 1 is 8–12 weeks of auth, publishing, aggregation, Meilisearch, comments, reactions, a feed, points, and badges. The overlay lists ingestion, AI, recommendations, gamification, social, LiveKit, and a SvelteKit app as peers. A reader cannot tell what is in or out of the first release.

## Conflicts with Kiln

### Three frontends are all still in play

Outline §3, `docs/architecture.md`, `/write`. The outline makes Phoenix LiveView the primary UI. The overlay picks SvelteKit for reading, keeps Next.js as a hiring fallback, and adds a second TipTap at `/write`. Kiln already has the content editor, preview, and fired public pages. The reader can be a thin client of fired artifacts. A second editor splits auth and the block model.

### “One BEAM” still introduces a second app

`docs/architecture.md` decisions. Rejecting a Node or Go BFF is sound. SvelteKit on port 5173 then proxies `/api` and `/socket`, owns reader state, and is the only place channels are specified. Channel tokens, session sharing with AshAuthentication, and who renders the public article are unset. Kiln’s fired `/<slug>` and the Svelte `/article/[slug]` route are two delivery paths.

### The plan rebuilds systems Kiln already ships

Outline §2–4, `config/project.exs`. Kiln v1.0.0 already has newsletter send, notifications, billing and memberships, Postgres search plus optional Meilisearch and embeddings, and outbound social announce. `KilnCMS.Social` is Bluesky and Mastodon on publish, not a follow graph. Digests, subscriptions, and search are specified as greenfield. The overlay domain list registers Kiln’s Social and the docs propose `VerscientaNews.Social` without saying they are different things.

### The outline still requires Redis

Outline §3, Kiln decisions D1 and D2. Cache, rate limit, and realtime are all Redis in the outline. Kiln’s locked decisions use `Phoenix.PubSub`, Cachex, Hammer, and Oban, and add Dragonfly only after a multi-node measurement. The overlay repeats that correctly and leaves the outline unchanged, so the two documents disagree on the ops baseline.

### Auth is a menu, not a decision

Outline §3. “Pow or Phoenix Auth + Ueberauth” is still the written choice. Kiln is AshAuthentication with Ash policies. The Svelte app never says how a reader becomes an actor for comments, follows, or channels.

## Defer

### Broadway is the wrong shape for a 15-minute poll

Ingestion doc. A cron that fetches an allowlist of feeds is an Oban job plus Req. Broadway producers, per-source pipelines, and batcher dedupe add a dependency the stub does not compile against. Dedupe belongs on a unique `source_url`. The docs name `VerscientaNews.Ingestion.Normalize` and `Bridge`; those modules are not in the tree.

### Vitality rewards the wrong behavior

Outline §2, `docs/gamification.md`. Points for dwell time pay people to linger. Leaderboards on health advice select for volume. A reward store that buys featured placement is pay-to-rank on medical-adjacent content. None of this is required to read, trust, or follow a topic.

### Hybrid recommendations have no cold start

`docs/architecture.md`, `projects/verscienta_news/services/recommendation.ex`. Reciprocal rank fusion across Meilisearch, pgvector block embeddings, and collaborative signals needs a corpus and a behavior graph. Kiln already has an embeddings leg (D16) that ships off unless `KILN_ML=1`. The plan does not say what it reuses, what a `Recommendation` row stores, or what “For You” shows for a new reader.

### The latency targets cannot be tested

Outline §6. Sub-100ms LiveView responses and sub-50ms cached reads name no percentile, payload, or concurrency. After the overlay moves reading to SvelteKit, the LiveView number no longer describes the reader. “Significant concurrent users” is not a capacity plan.

## What to keep

One OTP release and the plugin overlay. `Article` via `KilnCMS.CMS.Content`, Portable Text, workflow, and fired artifacts. Cachex and Oban until a measurement says otherwise. LiveKit off the core path. Ollama failing open to a human queue, once that queue exists and failing open means the item waits for review.

Design tokens in `frontend/src/lib/tokens/codex.css` are a guessed earth palette. `the-codex-v6.html` was unavailable when `docs/design/codex-notes.md` was written. Treat the palette as temporary.

## A first slice the documents do not contain

Ship one category of articles that a person can read on the fired Kiln page. Poll a short allowlist of feeds with Oban, store the source URL under a unique constraint, and leave every item in review. Show attribution, a medical disclaimer, and claim status on the article. Use Kiln’s editor and Kiln’s search. Leave Meilisearch, the Svelte reader, follows, vitality, rooms, and recommendations out until that page is the product.
