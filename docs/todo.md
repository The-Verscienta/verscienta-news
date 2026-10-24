# Verscienta News — Build Todo

A step-by-step, phased checklist to take Verscienta News from an empty repository to a
full-featured production web app. Phases are ordered so each builds on the last; within a
phase, work roughly top to bottom. Check items off as they land and are verified.

Legend: `[ ]` not started · `[~]` in progress · `[x]` done

> **Slice 1 cut line:** `docs/slice-1.md` is the only exit list. `docs/README.md` says which files are historical. The fired page is `/[field:category]/[slug]`. State is `in_review`. Queue is `/editor?status=in_review`.

---

## Phase 0 — Foundation & Project Setup (1–2 weeks) — ✅ DONE

Goal: a running KilnCMS v1.0.0 + overlay app, CI/CD, and local dev environment everyone can reproduce.

These checkboxes were closed against the standalone Verscienta app and an early overlay scaffold. They are not Slice 1 exit evidence. Slice 1 work is Phase 1 below, and the tests are in `docs/slice-1.md`.

### Tooling & Environment
- [x] Install/standardize Elixir + OTP versions (`.tool-versions` via asdf/mise). *(`.tool-versions` pins Erlang 27.3.4.15 / Elixir 1.19.5, matching `kiln_cms`; `Dockerfile` ARGs match)*
- [x] Generate Phoenix 1.7+ app with LiveView and Tailwind. *(Phoenix 1.8.7 — now via KilnCMS v1.0.0 submodule `kiln_cms/`)*
- [x] Initialize git repo, `.gitignore`, branch protection on `main`. *(repo + .gitignore done; branch protection verified — Phase 0 closed)*
- [x] Add `Ash` + `AshPostgres` + `AshPhoenix` and configure the default Ash domain(s). *(via Kiln overlay `projects/verscienta_news/` + `config/project.exs`)*
- [x] Configure PostgreSQL 16+ for local dev (Docker Compose service).
- [x] Add Tailwind CSS + configure the "Codex" design tokens. *(Tailwind v4 CSS-first `@theme` in `assets/css/app.css`)*
- [x] Set up `Credo`, `Dialyzer` (or Dialyxir), and `mix format` with a `.formatter.exs`.
- [x] Add `ExUnit` config, test helpers, and an initial smoke test.

### Local Service Stack (Docker Compose)
- [x] PostgreSQL 16.
- [x] Redis. *(Closed in error as a required service. This compose file has no Redis. Slice 1 cache is Cachex. See `docs/runbooks/redis-down.md`.)*
- [x] Meilisearch. *(compose service exists but deferred — Kiln Postgres FTS is Slice 1 search)*
- [x] Ollama (with a small model pulled for dev, e.g. `llama3.2:3b`). *(Compose profile `ml`, not `ai`. Advisory only. Not required for the fired page.)*
- [x] Document `docker compose up` + `mix setup` onboarding in README.

### Configuration & Secrets
- [x] Set up `config/runtime.exs` for env-driven config.
- [x] Define secrets strategy (env vars locally, Coolify secrets in prod).
- [x] Add `dotenvy` or equivalent for local `.env` loading (gitignored).

### CI/CD
- [x] GitHub Actions: install deps, compile (warnings as errors), format check, Credo, tests.
- [x] Cache deps + `_build` in CI.
- [x] (Optional) Dialyzer job with PLT caching. *(CI Dialyzer job added in `408f043`)*
- [x] Coolify project created; connect repo for auto-deploy on `main`. *(verified/closed for Phase 0 — in-repo Coolify config not required)*
- [x] Dependabot configured. *(`.github/dependabot.yml` for mix + github-actions)*

### Design System Setup
- [x] Port "The Codex" tokens to `tailwind.config.js`. *(actually in `assets/css/app.css` `@theme` — Tailwind v4 CSS-first; colors `#0c0c0c`, `#F2660A`, Metro accents all present)*
- [x] Load Hanken Grotesk and set as the single typeface. *(self-hosted via `@font-face` in `app.css`)*
- [x] Build base layout shell (thin top strip / chrome, dark canvas).
- [x] Create core function components: `kicker`, `giant`/headline, `breaking_bar`, `news_card`, `tile`, `feed_post`, `notif`, `button`. *(`codex_components.ex`)*
- [x] Add motion utilities (slide/stagger/turnstile) and the snappy easing curve. *(`--ease-codex` + slidein/rise + stagger + turnstile utilities)*
- [x] Set up Storybook-style component showcase. *(`/styleguide` page)*

---

## Phase 1 — Slice 1

Goal: one category of articles on the fired Kiln page `/[field:category]/[slug]`, reviewed before they are public. Exit tests are only in `docs/slice-1.md`. Do not add a second list here.

- [ ] `VerscientaNews.Ingestion.Allowlist` is the poll registry, and `docs/source-rights.md` matches it. `mix test test/verscienta_news/allowlist_test.exs` passes.
- [ ] `Poller.apply_license/1` truncates `excerpt_link` to 280 characters of plain text and drops `link_only` bodies before storage. Unknown hosts return `{:error, :not_allowlisted}`.
- [ ] Ingested drafts are Kiln state `in_review` (not a `pending_review` state). Review is `/editor?status=in_review`. Approve uses the checklist in `docs/moderation.md` and does not set `verified`.
- [ ] `claim_status` is `unreviewed`, `flagged`, or `cleared`. The disclaimer is template copy on the fired page.
- [ ] Ollama profile `ml` stopped: new polls stay `in_review` and unpublished.
- [ ] Kiln Postgres search returns seeded articles. No Svelte parity test. Newsletter and billing are not exit items.

Out until `docs/slice-1.md` says otherwise: follow graph, gamification, recommendations, Meilisearch, LiveKit, Svelte reader, Broadway, Redis.

---

## Phase 2 — Social & Gamification (8 weeks) — ⏸ DEFERRED past Slice 1

> **DEFERRED** — Entire phase is out of scope until Slice 1 exit criteria pass.
> Promote in the order in `docs/slice-1.md`: Verified Expert, follow graph, Svelte reader, Meilisearch and recommendations, then gamification.

Goal: a real social graph and activity layer, full gamification loop, and media uploads. **Not started — deferred.**

### Social Graph — DEFERRED
- [ ] **DEFERRED** — `Follow` resource (user→user, user→topic/tag).
- [ ] **DEFERRED** — Follow/unfollow with live counts + optimistic UI.
- [ ] **DEFERRED** — "Following" vs "For You" vs "Trending" pivot on the home feed.
- [ ] **DEFERRED** — Mentions (`@user`) parsing + linking in posts/comments.
- [ ] **DEFERRED** — Reposts / quote-reposts.

### Activity Feeds — DEFERRED
- [ ] **DEFERRED** — Activity event model (fan-out or fan-in strategy decided + documented).
- [ ] **DEFERRED** — Personal activity feed (things you follow).
- [ ] **DEFERRED** — Global activity feed.
- [ ] **DEFERRED** — Real-time feed updates via Phoenix PubSub.

### Communities & Groups — DEFERRED
- [ ] **DEFERRED** — `Group` + `GroupMembership` resources (public communities, private groups).
- [ ] **DEFERRED** — Group creation, join/leave, roles (owner/mod/member).
- [ ] **DEFERRED** — Group-scoped content + discussions.
- [ ] **DEFERRED** — Group discovery / directory.

### Media & Images — DEFERRED
- [ ] **DEFERRED** — Cloudflare Images integration (signed upload URLs, Transformations).
- [ ] **DEFERRED** — Direct-to-Cloudflare upload from LiveView (`live_file_input` / external uploads).
- [ ] **DEFERRED** — Avatar + cover image uploads.
- [ ] **DEFERRED** — Inline images/video embeds in the editor.
- [ ] **DEFERRED** — (Optional) Cloudflare R2 for non-image file storage.

### Notifications — DEFERRED
- [ ] **DEFERRED** — `Notification` resource (type, actor, subject, read state).
- [ ] **DEFERRED** — In-app notification center (colored bar by type per design system).
- [ ] **DEFERRED** — Real-time delivery via PubSub/Presence.
- [ ] **DEFERRED** — Notification preferences.

### Advanced Gamification — DEFERRED
- [ ] **DEFERRED** — `Quest` / challenge engine (daily/weekly, progress tracking, completion rewards).
- [ ] **DEFERRED** — Streaks (daily login/reading streak with grace logic).
- [ ] **DEFERRED** — `LeaderboardSnapshot` resource + Oban jobs to compute weekly/monthly/global/category boards.
- [ ] **DEFERRED** — Leaderboard LiveViews.
- [ ] **DEFERRED** — Reward Store (catalog, redemption, points spend ledger).
- [ ] **DEFERRED** — Referral / invite-a-friend flow with point rewards.

### AI (Basic Ollama Integration) — DEFERRED (advisory only in Slice 1)
- [ ] **DEFERRED** — Ollama HTTP client module beyond advisory tags/summary (no quality-score gate).
- [ ] **DEFERRED** — Summarization job for aggregated/published content (advisory tags already in Slice 1).
- [ ] **DEFERRED** — Auto-tagging + category suggestion (advisory in Slice 1; no auto-publish).
- [ ] **DEFERRED** — Quality / evidence-level scoring on content (never gates publish in Slice 1).
- [ ] **DEFERRED** — Backfill job and any ingest hook beyond leaving the draft in `in_review`.
- [ ] **DEFERRED** — Graceful degradation when Ollama is unavailable (already required in Slice 1).

### Phase 2 Cross-cutting — DEFERRED
- [ ] **DEFERRED** — FunWithFlags feature flags for rolling out social features.
- [ ] **DEFERRED** — Caching layer (Redis + ETS) for feeds, counts, leaderboards — Slice 1 uses Cachex/Hammer only.
- [ ] **DEFERRED** — Expand test coverage (social flows, gamification math, uploads).
- [ ] **DEFERRED** — Load-test feeds + leaderboards for the perf targets.

---

## Phase 3 — Intelligence & Growth (8–10 weeks) — ⏸ DEFERRED past Slice 1

> **DEFERRED** — Entire phase is out of scope until Slice 1 exit criteria pass.
> Promote after Phase 2 items per `docs/slice-1.md` order: (5) Meilisearch + recommendations with cold-start spec, then growth loops.

Goal: personalization, real-time rooms, smart moderation, and growth loops. **Not started — deferred.**

### Recommendation & Personalization — DEFERRED
- [ ] **DEFERRED** — Hybrid recommendation engine (content-based + collaborative signals) — no RRF in Slice 1.
- [ ] **DEFERRED** — "For You" feed ranking using interactions, follows, tags, recency.
- [ ] **DEFERRED** — Embeddings via Ollama for semantic similarity (store in Postgres `pgvector`).
- [ ] **DEFERRED** — Related-content module on article pages.
- [ ] **DEFERRED** — Personalized search ranking.

### Live Rooms & Real-time — DEFERRED
- [ ] **DEFERRED** — Live discussion rooms via LiveView + PubSub + Phoenix.Presence.
- [ ] **DEFERRED** — Room lifecycle (create/join/leave, moderation controls).
- [ ] **DEFERRED** — (Optional) Audio/video via LiveKit/WebRTC — no LiveKit in Slice 1.
- [ ] **DEFERRED** — Live reactions / typing indicators / online presence.

### Notifications & Digests — DEFERRED (Kiln Newsletter reused in Slice 1)
- [ ] **DEFERRED** — Daily/weekly digest email generation beyond Kiln Newsletter baseline.
- [ ] **DEFERRED** — Scheduled digest Oban jobs + unsubscribe management beyond Kiln.
- [ ] **DEFERRED** — Push/web-push notifications (optional).
- [ ] **DEFERRED** — Digest refinements (per-user-timezone, non-article content, admin send now, open/click analytics) — after Kiln Newsletter reuse is proven.

### Moderation & Trust — DEFERRED (human queue in Slice 1; advanced tooling is next)
- [ ] **DEFERRED** — `ModerationFlag` resource + community reporting UI beyond takedown flag.
- [ ] **DEFERRED** — Llama-based toxicity + dubious-claim detection on submit (advisory flag only in Slice 1).
- [ ] **DEFERRED** — Moderation queue beyond `/editor?status=in_review`.
- [ ] **DEFERRED** — Auto-actions (hold, shadow, escalate) with audit log — no auto-hold in Slice 1.
- [ ] **DEFERRED** — AI writing assistant for authors (draft help, tone, claim-checking).
- [ ] **DEFERRED** — Moderation fast-follows (rate-limit reports, reporter notifications).

### Expert Program — DEFERRED (promote as #2 after Slice 1)
- [ ] **DEFERRED** — Verified Expert application + credential review workflow.
- [ ] **DEFERRED** — Expert badge + elevated trust signals on content/profile.
- [ ] **DEFERRED** — Expert-only publishing privileges / featured placement.

### Growth — DEFERRED
- [ ] **DEFERRED** — SEO: meta tags, Open Graph, sitemap, structured data for articles.
- [ ] **DEFERRED** — Shareable links + social card images.
- [ ] **DEFERRED** — PostHog analytics + key funnels/events instrumented.
- [ ] **DEFERRED** — Onboarding flow (interest selection seeds the For You feed).

---

## Phase 4 — Polish, Monetization & Scale (ongoing) — ⏸ DEFERRED past Slice 1

> **DEFERRED** — Entire phase is out of scope until Slice 1 exit criteria pass.
> Per `docs/slice-1.md`: (6) gamification only if non-dwell metrics are agreed — after follow graph, Svelte interactivity, and Meilisearch/recommendations.

Goal: production hardening, revenue, and operational excellence. **Not started — deferred.**

### Performance & Scale — DEFERRED
- [ ] **DEFERRED** — Materialized views for heavy aggregates (feeds, leaderboards, trending).
- [ ] **DEFERRED** — Query profiling + N+1 elimination across hot paths.
- [ ] **DEFERRED** — Aggressive Redis/ETS caching strategy with invalidation rules — Slice 1 uses Cachex only.
- [ ] **DEFERRED** — LiveView diffing/payload audit; reduce assign churn.
- [ ] **DEFERRED** — Verify perf targets: Slice 1 is headless API p95 < 50 ms + public HTML hit < 50 ms (Kiln SLOs via `scripts/benchmarks/api_latency.sh`); sub-100 ms LiveView claim removed — see `docs/load-testing.md` + `kiln_cms/docs/benchmarks.md`.
- [ ] **DEFERRED** — Multi-node readiness (PubSub adapter, distributed Presence, sticky sessions).

### Monetization — DEFERRED (Kiln Billing reused in Slice 1 for subscriptions)
- [ ] **DEFERRED** — Premium subscriptions beyond Kiln Billing baseline (PayPal tiers, etc.).
- [ ] **DEFERRED** — Paywalled / premium content tiers.
- [ ] **DEFERRED** — Sponsored content placements (clearly labeled).
- [ ] **DEFERRED** — Affiliate link integration + disclosure.
- [ ] **DEFERRED** — Featured / promoted challenges.

### Observability & Ops — DEFERRED
- [ ] **DEFERRED** — Prometheus metrics export + Grafana dashboards.
- [ ] **DEFERRED** — Alerting on error rate, latency, queue depth, Ollama health.
- [ ] **DEFERRED** — Structured logging + log retention.
- [ ] **DEFERRED** — Backups verified (Coolify + Postgres WAL + R2) with restore drill.
- [ ] **DEFERRED** — Runbooks for common incidents.

### Compliance & Trust — DEFERRED beyond source-rights gate
- [ ] **DEFERRED** — GDPR/CCPA: data export, account deletion, consent management beyond source-rights takedown.
- [ ] **DEFERRED** — Cookie/consent banner.
- [ ] **DEFERRED** — Content medical-disclaimer system finalized beyond Slice 1 badge.
- [ ] **DEFERRED** — Terms of Service + Privacy Policy.
- [ ] **DEFERRED** — Signed/optimized Cloudflare Image URLs enforced.
- [ ] **DEFERRED** — Legal review of drafted ToS / Privacy Policy / Cookie Policy / Medical Disclaimer texts.
- [ ] **DEFERRED** — Ops: set `CLOUDFLARE_IMAGES_SIGNING_KEY` in prod.

### Quality — DEFERRED
- [ ] **DEFERRED** — Property-based tests for gamification + ranking math.
- [ ] **DEFERRED** — End-to-end smoke tests on critical journeys.
- [ ] **DEFERRED** — Security review (authz on every Ash action, input validation, OWASP pass).
- [ ] **DEFERRED** — Accessibility audit (WCAG AA) across the app.
- [ ] **DEFERRED** — Performance regression checks in CI.

---

## Always-On (every phase)

- [ ] Write tests alongside features; keep CI green.
- [ ] Enforce Ash policies/authorization on new resources and actions.
- [ ] Keep the design system the single source of truth — no one-off styles.
- [ ] Update docs (`README.md`, ADRs) when architecture decisions are made.
- [ ] Run `mix format`, Credo, and Dialyzer before merging.
- [ ] Review accessibility + mobile responsiveness for each new screen.
