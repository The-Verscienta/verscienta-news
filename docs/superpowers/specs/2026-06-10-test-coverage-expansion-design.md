# Test Coverage Expansion — Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-10
**Todo item:** Phase 2 cross-cutting — "Expand test coverage (social flows, gamification math, uploads)"
**Status:** approved

## Goal

Close the meaningful coverage gaps surfaced by `mix test --cover` and make the coverage
number itself trustworthy and CI-enforceable. Baseline at design time: **78.11% total,
920 tests, 0 failures, 24.8s**.

The todo item's named areas (social flows, gamification math, uploads) have gained
substantial coverage since it was written; a fresh coverage run shows the *actual* gaps
are elsewhere. Scope decision (user-approved): coverage-driven across the whole app,
hybrid approach — new tests for real gaps + coverage-config hygiene + CI enforcement.

## Context

- 246 test files; suite green. Coverage run performed in this worktree via the root dev
  container (`docker exec news-verscienta-app-1 ... mix test --cover`).
- The raw total is diluted by ~35 Ash-generated `Inspect.*` protocol impls at 0%,
  load-test/seed/backfill mix tasks, real HTTP `*.Req` clients (replaced by stubs in
  test by design), and styleguide scaffolding.
- Some low numbers are boilerplate, not risk: `Social.ActivityEvent` (33%) and
  `Gamification.GamificationAudit` (33%) are thin Ash resources; `Cache.Redis` (35%)
  runs disabled in test env by design. These are explicitly *not* targets.

## New tests — core targets

### 1. Referral capture flow, end-to-end (web layer)

Currently: `ReferralRedirectController` 0%, `SettingsReferralsLive` 0%,
`AuthController` 6.9%, `CaptureReferral` plug 57%. Domain logic
(`Gamification.Referrals`) is already tested; the web wiring is not.

- `CaptureReferral` plug (conn tests): `?ref=code` sets the `verscienta_ref` cookie
  (30-day max-age, HttpOnly, SameSite=Lax); missing/empty `ref` leaves the conn alone.
- `ReferralRedirectController`: `GET /r/:code` sets the cookie and redirects to `/`.
- `AuthController` register success with the cookie present and `:referrals` flag
  enabled → `Referrals.capture/3` records the referral and the response deletes the
  cookie; flag disabled → no capture. (Exercise via the real registration POST so the
  AshAuthentication pipeline stays honest.)
- `SettingsReferralsLive`: mount generates a referral code when missing; `rotate`
  event rotates the code; rotate again inside the 24h cooldown shows the error
  message; `share_link/1` returns `<endpoint>/r/<code>`.

### 2. AuthController

- `success/4`: flash message per activity (`{:confirm_new_user, :confirm}`,
  `{:password, :reset}`, default); honors `:return_to` session value; register
  activity redirects to `/welcome`.
- `failure/3`: generic "Incorrect email or password" flash; the
  unconfirmed-user special case message; redirects to `/sign-in`.
- `sign_out/2`: clears the session, renews it, flashes, redirects to `return_to`/`/`.

### 3. Small zero-coverage pages

- `StoreHistoryLive` (`/store/history`): requires auth; lists only the current user's
  redemptions, newest first; renders reward-item names via the items map.
- `GoodbyeLive` (`/goodbye`): renders the deletion message; SEO assign is noindex.

### 4. `Communities.Counts` (0%)

- `group_member_count/1` counts only `:active` memberships.
- Value is cached; a membership write through the resource action invalidates the
  `group:<id>:counts` tag (pairs with `GroupMembership.Changes.InvalidateCounts`).

### 5. Gamification math (the todo's named area)

- `Gamification.Leaderboards` (67%): uncovered ranking/window/period branches.
- `LeaderboardSnapshotWorker` (51%): snapshot computation paths not exercised
  (weekly/monthly/global/category variants as applicable).
- `LeaderboardLive` (64%): uncovered board-switching/render branches.

### 6. `Content.BlockRenderer` (66%)

- Cover the uncovered block-type and sanitization branches (identify via the HTML
  coverage report in `cover/`). Security-relevant: these are the "never trust client
  HTML" paths.

## Stretch targets (only if cheap while in the area)

- `NotificationBellLive` (57%): uncovered handle_info/event branches.
- `AdminFlagShowLive` (58%) / `AdminFlagsLive` (61%) / `FlagComponents` (0%):
  moderation-UI branches.

## Coverage hygiene

In `mix.exs` `project/0`, add:

```elixir
test_coverage: [
  ignore_modules: [
    ~r/^Inspect\./,                        # Ash-generated Inspect impls
    # seed/backfill/load-test/reindex mix tasks (NOT AiBackfill — it has tests)
    Mix.Tasks.Verscienta.Embeddings.Backfill,
    Mix.Tasks.Verscienta.Flags.Seed,
    Mix.Tasks.Verscienta.Gamification.Backfill,
    Mix.Tasks.Verscienta.Gamification.Seed,
    Mix.Tasks.Verscienta.Reindex,
    ~r/^Mix\.Tasks\.Verscienta\.LoadTest\./,
    ~r/^Verscienta\.LoadTest\./,
    # real HTTP clients stubbed in test by design (NOT Analytics.Client.Req — tested)
    Verscienta.AI.Client.Req,
    Verscienta.Aggregation.FeedClient.Req,
    Verscienta.Search.Client.Req,
    VerscientaWeb.StyleguideHTML,
    VerscientaWeb.PageHTML,
    VerscientaWeb.AuthOverrides
  ],
  summary: [threshold: N]
]
```

- `N` is chosen *after* the new tests land: the measured total, rounded down to the
  nearest whole percent (expected ~85). The threshold enforces regression, not
  aspiration — the suite must pass it on the day it merges.
- The ignore list is deliberately precise (explicit modules over broad regexes) so
  tested modules like `Mix.Tasks.Verscienta.AiBackfill` (92%) and
  `Verscienta.Analytics.Client.Req` (38%, has `client_req_test.exs`) keep counting.

## CI enforcement

`.github/workflows/ci.yml` test step changes from `mix test` to `mix test --cover`
so the threshold gates merges. No new job; same step.

## Non-goals

- No StreamData/property-based tests (separate Phase 4 todo item).
- No Redis integration tests (`Cache.Redis` is disabled in test env by design).
- No tests for Ash resource boilerplate or generated code purely to move the number.
- No new test deps (no excoveralls, no Mox) — built-in `mix test --cover`,
  existing stubs and `Verscienta.Support.Factory`.

## Testing approach / conventions

- Follow existing patterns: `Verscienta.DataCase` for domain tests,
  `VerscientaWeb.ConnCase` + `Phoenix.LiveViewTest` for web tests,
  `Verscienta.Support.Factory` for data, `AuthHelpers` for signed-in conns.
- Beware the known seed-contamination failure mode: never assert global counts;
  scope assertions to test-created data.
- Run everything in the dev container against this worktree:
  `docker exec news-verscienta-app-1 bash -lc "cd /workspace/.claude/worktrees/ecstatic-stonebraker-d1cb0b && MIX_ENV=test mix test"`.
- One session runs tests at a time against the shared `verscienta_test` DB (another
  session is active on this repo; coordinate by keeping runs short).

## Verification / definition of done

1. Full suite green in the container.
2. `mix test --cover` passes the new threshold; total meaningfully above the 78.11%
   baseline (expected ~85% after hygiene + new tests).
3. CI workflow runs `mix test --cover` successfully.
4. `docs/todo.md` Phase 2 item "Expand test coverage" checked off with a parenthetical
   describing what landed.
