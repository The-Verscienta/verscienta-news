# PostHog Analytics (Server-Side) Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-05
**Status:** Approved
**Phase:** 3 — Intelligence & Growth · Growth (slice 3 of 4)
**Depends on:** the `*_client` behaviour+stub pattern (Search/Images/AI), `:req`, the `:browser` pipeline + LiveView `on_mount`, the User/Article/Follow Ash actions.
**New dependency:** none required (uses `:req`). PostHog is reached over its HTTP `/capture` API.

## Goal

Instrument the key product funnels with server-side PostHog events: acquisition (signup), consumption (article view, search), engagement (follow), and creation (publish). Events are captured from Elixir via PostHog's HTTP API through an `Analytics.Client` behaviour (Req impl + test stub), mirroring the existing Search/Images/AI clients. Fire-and-forget and failure-tolerant — analytics never blocks or breaks a request. Both anonymous and signed-in visitors are tracked (so the anonymous→signup funnel is visible), using a session-scoped anonymous id. No client-side JS / cookies in v1 (that waits for the Phase 4 consent banner).

## Decomposition context

Growth slices: 1 (SEO — shipped), 2 (social cards — shipped), **3 (this — analytics)**, 4 (onboarding). Independent of the others.

## Decisions

| Decision | Choice |
|----------|--------|
| Mode | **Server-side** capture via `Analytics.Client` behaviour (Req + Stub), per-env config |
| Delivery | **Fire-and-forget** (`Task.start`, rescued); never blocks or raises; **no-op when unconfigured** |
| Audience | **Anonymous + signed-in**; `distinct_id = current_user.id \|\| analytics_id \|\| "anonymous"` |
| Anonymous id | a `AnalyticsId` plug stores a persistent UUID in the Phoenix **session**; an `on_mount` exposes it to LiveViews |
| Event set (v1) | `signup`, `article_published`, `user_followed` (after-action changes); `article_viewed`, `search_performed` (LiveView) |
| Privacy | no raw search text (`query_length` + `result_count`); minimal non-PII props; `identify` sets username/email on signup |
| Config | `:posthog_host` + `:posthog_api_key` from `runtime.exs`; `analytics_client` = `Client.Req` (default) / `Client.Stub` (test) |

## Section 1: `Verscienta.Analytics` + `Analytics.Client`

New `lib/verscienta/analytics.ex`:
- `capture(event, distinct_id, properties \\ %{}) :: :ok` — delegate to the configured client.
- `identify(distinct_id, properties) :: :ok` — set person properties (a `$identify`/`$set` capture).
- `distinct_id(user, analytics_id)` — `(user && to_string(user.id)) || analytics_id || "anonymous"`.
- Named helpers that centralize event names + safe props:
  - `track_signup(user)` → `capture("signup", user.id, %{})` + `identify(user.id, %{username:, email:})`.
  - `track_article_published(article)` → `capture("article_published", author_id, %{category:, article_id:})`.
  - `track_follow(follower_id, follow_type)` → `capture("user_followed", follower_id, %{type:})`.
  - `track_article_view(article, distinct_id)` → `capture("article_viewed", distinct_id, %{article_id:, category:})`.
  - `track_search(distinct_id, query, result_count)` → `capture("search_performed", distinct_id, %{query_length: String.length(query), result_count: result_count})` (NO raw query).

New `lib/verscienta/analytics/client.ex`:
- `@callback capture(event :: String.t(), distinct_id :: String.t(), properties :: map) :: :ok`
- `@callback identify(distinct_id :: String.t(), properties :: map) :: :ok`
- dispatcher `capture/3`, `identify/2` → `Application.get_env(:verscienta, :analytics_client, __MODULE__.Req)`.
- `Client.Req`: builds the PostHog payload (`%{api_key:, event:, distinct_id:, properties:, timestamp:}`) and POSTs to `#{host}/capture/` via `Req` **inside `Task.start/1`** (fire-and-forget); rescues all errors (log at debug/warning, never raise). If `host`/`api_key` is missing/blank → return `:ok` without sending. `identify` posts a `$identify` event with `"$set" => properties`.
- `Client.Stub` (in `test/support/`): records `{fun, args}` to an app-env list (mirrors `Search.ClientStub`); `calls/0`, `reset/0`; returns `:ok`.

## Section 2: Anonymous id (`AnalyticsId` plug + on_mount)

- `lib/verscienta_web/plugs/analytics_id.ex` — a plug: if `get_session(conn, :analytics_id)` is nil, generate `Ecto.UUID.generate()` (or `Ash.UUID.generate()`), `put_session`, and `assign(conn, :analytics_id, id)`; else assign the existing one. Added to the `:browser` pipeline (after fetch_session).
- `lib/verscienta_web/live/analytics_on_mount.ex` (or a clause in the existing on-mount module) — `on_mount` reads `session["analytics_id"]` and `assign(socket, :analytics_id, id)`; attach to the relevant `live_session`(s) so instrumented LiveViews have it. (LiveViews can't write the session, so the plug owns creation; the on_mount only reads.)
- Controllers (home) get `conn.assigns.analytics_id` directly.

## Section 3: Event instrumentation

**After-action changes (signed-in; actor id as distinct_id):**
- `signup`: a change on `User.:register_with_password` (`Verscienta.Accounts.User.Changes.TrackSignup` or similar) → `Analytics.track_signup(user)` in `after_action`. Rescued so analytics failure never breaks registration.
- `article_published`: a change on `Article.:publish` → `Analytics.track_article_published(record)`.
- `user_followed`: a change on the follow create action (find it under `Verscienta.Social`) → `Analytics.track_follow(actor_id, type)`. If a clean after-action site isn't available, fire from the follow toggle LiveView handler instead.

Each change mirrors the `EnqueueEmbedding`/`EnqueueOgCard` after-action pattern (rescue + `:ok`).

**LiveView (anonymous-capable; `distinct_id = user.id || analytics_id`):**
- `article_viewed`: in `ArticleReaderLive.mount` → `Analytics.track_article_view(article, Analytics.distinct_id(current_user, analytics_id))`. Fire on the dead render (connected? guard if needed to avoid double-count — fire once, e.g. only on the initial mount).
- `search_performed`: in `SearchLive.handle_event("search", ...)` after results → `Analytics.track_search(distinct_id, query, results.total)`. Skip when the query is blank.

## Section 4: Privacy

- `search_performed` sends `query_length` + `result_count` only — never the raw query string.
- Person properties on `identify` limited to `username` + `email` (standard for product analytics).
- No event carries article body, comment text, or other content; only ids + category + counts.

## Section 5: Config

- `config/config.exs`: `config :verscienta, analytics_client: Verscienta.Analytics.Client.Req`.
- `config/test.exs`: `config :verscienta, analytics_client: Verscienta.Analytics.Client.Stub`.
- `config/runtime.exs`: read `POSTHOG_HOST` (default `https://us.i.posthog.com`) and `POSTHOG_API_KEY` (nil if unset) into `:verscienta` env; the Req client treats a blank/nil key as "disabled" (no-op).

## Section 6: Testing

- **`Analytics` helpers** (with `Client.Stub`): each `track_*` helper records a capture with the expected event name, distinct_id, and properties; `track_search` records `query_length`/`result_count` and NOT the raw text; `track_signup` also records an `identify`.
- **`distinct_id/2`**: user present → user id; nil user + analytics_id → analytics_id; both nil → `"anonymous"`.
- **`AnalyticsId` plug**: sets a session id when absent; reuses it when present; assigns it.
- **`Client.Req` no-op**: with host/key unconfigured, `capture/3` returns `:ok` and records no HTTP (assert it doesn't raise; since it's fire-and-forget, assert the unconfigured guard returns `:ok` synchronously before spawning).
- **Instrumentation**: registering a user records a `signup` event (Stub); publishing records `article_published`; visiting an article (dead render) records `article_viewed` with a distinct_id; searching records `search_performed`. (For after-action events, the Stub is synchronous so the assertion is race-free; for the Req path the Task is async — tests use the Stub.)
- Full suite + `credo --strict` + `dialyzer` + format green.

## Out of scope (deferred)

Client-side posthog-js (autocapture, pageview-on-live-navigation, session replay) — pending the Phase 4 cookie/consent banner; reaction/bookmark/comment events (trivial follow-on with the same helper); anonymous→user `alias` on signup; PostHog feature flags / experiments; batching/Oban-backed reliable delivery (fire-and-forget is the v1 tradeoff); a consent gate on capture.

## Definition of Done

- `Verscienta.Analytics` (`capture/3`, `identify/2`, `distinct_id/2`, `track_*` helpers) + `Analytics.Client` behaviour with `Client.Req` (fire-and-forget, no-op-when-unconfigured) + `Client.Stub`.
- `AnalyticsId` plug in `:browser` + an `on_mount` exposing `analytics_id` to LiveViews.
- The 5 v1 events instrumented (signup/published/followed via after-action changes; viewed/searched via LiveView), privacy-safe.
- Per-env config; Req disabled without a key.
- Tests across helpers/distinct_id/plug/no-op/instrumentation; full suite + credo + dialyzer green.
- `docs/todo.md` PostHog item checked off. No new dependency.
