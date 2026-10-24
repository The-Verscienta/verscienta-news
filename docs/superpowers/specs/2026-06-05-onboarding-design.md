# Onboarding Flow Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-05
**Status:** Approved
**Phase:** 3 — Intelligence & Growth · Growth (slice 4 of 4 — final slice)
**Depends on:** `Verscienta.Social` (category follows), `Recommendations` (For You reads `followed_categories`), `Content.Category`, `VerscientaWeb.AuthController`, `Verscienta.Analytics` (slice 3).
**New dependency:** none.

## Goal

Give new users a one-screen interest picker at signup so the For You feed and personalized search have signal from the very first visit — closing the recommender's cold-start loop. Selecting wellness categories creates category follows (the exact signal `AffinityProfile.followed_categories` uses), then drops the user onto their freshly-personalized feed. Skippable; entered once, at registration.

## Decomposition context

Growth slices: 1 (SEO), 2 (social cards), 3 (analytics) — all shipped. **4 (this — onboarding)** is the final Growth slice. It consumes the recommender built in the Recommendation & Personalization subsystem.

## Decisions

| Decision | Choice |
|----------|--------|
| Selection | **Categories only** — the 8 wellness categories, multi-select → category follows |
| Entry | `AuthController.success/4` redirects **new registrations** to `/welcome` (sign-in unchanged) |
| Re-prompt | **None** — onboarding shows once at registration; abandoners aren't nagged (v1) |
| Skippable | Yes — "skip for now" sets `onboarded_at` and goes to the feed |
| `continue` gate | requires **≥1** category; skip is the 0-pick path |
| Post-onboarding | land on **`/articles?feed=for_you`** (the seeded For You feed) |
| Completion flag | `User.onboarded_at` (set on continue OR skip) |
| Analytics | `onboarding_completed` with `category_count` (reuses slice 3) |

## Section 1: `User.onboarded_at` + `:complete_onboarding`

In `lib/verscienta/accounts/user.ex`:
- attribute `onboarded_at, :utc_datetime_usec` (nullable, public read).
- action `:complete_onboarding` (update) — sets `onboarded_at` to `DateTime.utc_now()` via `change set_attribute(:onboarded_at, &DateTime.utc_now/0)` (or a `force_change_attribute` in a tiny change); accepts nothing else; no enqueue/hooks. Authorized for the acting user on their own record (mirror how `:update_profile`/`:update_notification_prefs` are policied — the actor updates self).
- Migration adding the nullable `onboarded_at` column.

## Section 2: `OnboardingLive` at `/welcome`

New `lib/verscienta_web/live/onboarding_live.ex`, route `live "/welcome", OnboardingLive, :index` inside the `ash_authentication_live_session :authenticated_routes` block (logged-in only).

- **mount**:
  - `current_user = socket.assigns.current_user`.
  - If `current_user.onboarded_at` is set → `{:ok, push_navigate(socket, to: ~p"/articles")}` (returning/direct visits skip).
  - Else assign `categories: Category.all()`, `selected: MapSet.new()`, `page_title: "welcome"`, and `:seo` `noindex: true` (it's a private flow).
- **render**: a welcome header + intro line; a responsive grid of the 8 category tiles (each shows the label, uses the category accent, and a selected/unselected visual state via `phx-click="toggle_category" phx-value-key={cat.key}`); a primary **"continue"** button (disabled until `MapSet.size(selected) > 0`, label includes the count) wired to `phx-click="continue"`; and a subtle **"skip for now"** (`phx-click="skip"`).
- **`handle_event("toggle_category", %{"key" => key}, socket)`**: toggle the (validated) category key in `selected`.
- **`handle_event("continue", _, socket)`**:
  1. for each selected key, create a category follow — the existing `Social` follow action (`Ash.ActionInput.for_action(:toggle, %{target_type: :category, target_id: to_string(key)}, actor: current_user) |> Ash.run_action!()`), matching `CategoryLive`'s usage.
  2. run `:complete_onboarding` on `current_user`.
  3. `Analytics.capture("onboarding_completed", to_string(current_user.id), %{"category_count" => MapSet.size(selected)})`.
  4. `push_navigate(socket, to: ~p"/articles?feed=for_you")`.
- **`handle_event("skip", _, socket)`**: run `:complete_onboarding`; `Analytics.capture("onboarding_completed", id, %{"category_count" => 0})`; `push_navigate` to `~p"/articles"`.
- Validate keys against `Category.keys()` (reject unknown via `String.to_existing_atom` rescue) so a tampered `phx-value-key` can't crash or create a bogus follow.

## Section 3: Entry point — register redirect

In `lib/verscienta_web/controllers/auth_controller.ex`, `success/4` currently redirects to `get_session(conn, :return_to) || ~p"/"`. Add a clause/branch: when `activity` indicates a **registration** (confirm the exact activity value for `:register_with_password` — likely `{:password, :register}`), redirect to `~p"/welcome"` instead (after the existing session setup). Sign-in/confirm/reset paths keep the current behavior. Keep the `delete_session(:return_to)` + token/session plumbing intact — only the final `redirect(to: ...)` target changes for the register activity.

## Section 4: Analytics

Reuse `Verscienta.Analytics.capture/3`: `onboarding_completed` with `%{"category_count" => n}` (n = picked count on continue, 0 on skip), `distinct_id = user.id`. Fire-and-forget; never blocks the redirect.

## Section 5: Testing

- **`User.:complete_onboarding`**: sets `onboarded_at` (was nil → a datetime).
- **`OnboardingLive`** (ConnCase + signed-in):
  - a fresh user (nil `onboarded_at`) sees the 8 category labels and the skip link;
  - toggling categories + `continue` creates the selected category follows (`Social.following?(user, :category, key)` true for picked, false for unpicked), sets `onboarded_at`, and redirects to `/articles?feed=for_you`;
  - `skip` sets `onboarded_at`, creates no follows, redirects to `/articles`;
  - an already-onboarded user visiting `/welcome` is redirected away (no picker);
  - `continue` with nothing selected is not possible (button gated) — assert the button is disabled at 0.
- **`AuthController`**: registering a new account redirects to `/welcome`; a normal sign-in redirects to `return_to`/home (not `/welcome`). (Use the project's existing auth test approach.)
- **Analytics**: `onboarding_completed` fires (pid-stub) with the right `category_count` on continue and skip.
- Full suite + `credo --strict` + `dialyzer` + format green.

## Out of scope (deferred)

Tag/source selection; a global re-prompt or "finish your setup" nudge for users who abandoned onboarding (v1 redirects only at registration); a multi-step wizard; capturing avatar/bio/display-name during onboarding; A/B of copy/layout; localized onboarding; minimum-pick enforcement beyond the `continue` gate.

## Definition of Done

- `User.onboarded_at` + `:complete_onboarding` action + migration.
- `OnboardingLive` at `/welcome` (category grid, toggle, ≥1-gated continue creating category follows + completing, skip; already-onboarded redirect; key validation; noindex).
- `AuthController.success/4` sends new registrations to `/welcome`.
- `onboarding_completed` analytics event (continue + skip).
- Tests across the action / LiveView (continue, skip, already-onboarded, gated continue) / auth redirect / analytics; full suite + credo + dialyzer green.
- `docs/todo.md` onboarding item checked off. No new dependency.
