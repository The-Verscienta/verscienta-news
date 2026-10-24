# Auth & Profiles Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-05-30
**Status:** Approved
**Phase:** 1 (MVP) — Subsystem 1 of 6
**Depends on:** Phase 0 foundation (Phoenix 1.8 + Ash 3 + AshAuthentication scaffold)

## Goal

Make authentication actually functional and add user profiles. The Phase 0 generator wired
the auth *routes* (`/sign-in`, `/register`, `/reset`, `/auth/*`, confirm, magic-link) but the
`Verscienta.Accounts.User` resource is a bare skeleton — only `id`, the token add-on, and a
`get_by_subject` read. No email, no password strategy, no confirmation. This subsystem
implements the strategies the routes expect, adds a lean profile + role model, and ships
public profile pages plus a settings editor.

## Decisions

| Decision | Choice |
|----------|--------|
| Strategies | Email + password, **email confirmation**, **password reset**. No magic link (remove/disable the routed magic-link route). |
| Auth UI | Built-in `AshAuthentication.Phoenix` LiveViews, themed toward Codex via `AuthOverrides` + daisyUI dark theme. |
| Profile model | Lean: `username`, `display_name`, `bio`, `avatar_url`, `role` enum. |
| Avatars | `avatar_url` string + initials fallback. **No file upload** (Cloudflare Images is Phase 2). |
| Profile URL | `/@:username`. |
| Email delivery | Swoosh **local** adapter (dev `/dev/mailbox`). Real SMTP/Postmark deferred to deployment. |

## Section 1: User Resource & Authentication Strategies

Extend `Verscienta.Accounts.User`:

**Attributes**
- `email` — `:ci_string`, `allow_nil? false`, sensitive in errors; unique identity `unique_email`.
- `hashed_password` — `:string`, `allow_nil? true`, `sensitive? true`.
- `username` — `:ci_string`, `allow_nil? false`, unique identity `unique_username`; constrained to a URL-safe pattern (lowercase letters, digits, underscore, 3–30 chars).
- `display_name` — `:string`, `allow_nil? true`.
- `bio` — `:string`, `allow_nil? true` (longer text; no hard DB limit beyond a sane `max_length` constraint, e.g. 500).
- `avatar_url` — `:string`, `allow_nil? true`.
- `role` — `Ash.Type.Atom` constrained to `[:user, :expert, :moderator, :admin]`, default `:user`, `public? true`, **not writable by the public update action**.
- `confirmed_at` — `:utc_datetime_usec`, `allow_nil? true` (set by confirmation add-on).
- `create_timestamp :inserted_at`, `update_timestamp :updated_at`.

**Strategies / add-ons (AshAuthentication)**
- `password` strategy with `identity_field :email`, `hashed_password_field :hashed_password`, and `resettable` enabled (password reset).
- `confirmation` add-on: confirm on register, token sent by email, writes `confirmed_at`. (The router's `confirm_route` targets `:confirm_new_user` — name the confirmation strategy/action accordingly.)
- Keep the existing `tokens` block + `log_out_everywhere` add-on.

**Actions** (the router already references these)
- `register_with_password` (accepts `email`, `password`, `password_confirmation`, `username`).
- `sign_in_with_password`.
- Password reset request + reset actions (from `resettable`).
- `:confirm_new_user` confirmation action.
- `update_profile` — accepts `username`, `display_name`, `bio`, `avatar_url` only. Does **not** accept `email` or `role`.
- Keep `get_by_subject` read.

**Senders**
- `Verscienta.Accounts.User.Senders.SendConfirmationEmail` and `...SendPasswordResetEmail` (Swoosh via `Verscienta.Mailer`, local adapter in dev).

**Username on registration:** registration requires a `username`. The register action validates uniqueness + format.

## Section 2: Authorization Policies

- Keep the `AshAuthentication.Checks.AshAuthenticationInteraction` bypass (auth flows self-authorize).
- `read`: publicly allowed (profile pages are public). `email`/`hashed_password` remain sensitive so they are not exposed in profile rendering; templates only read public fields.
- `update_profile`: `authorize_if expr(id == ^actor(:id))` — a user may edit only their own profile.
- `role`: never settable via `update_profile`. Changing role requires an admin path (seeds/console for MVP; an admin UI is out of scope here).

## Section 3: Auth UI (built-in, themed)

- Retain the routed `AshAuthentication.Phoenix` sign-in/register/reset/confirm LiveViews.
- Remove the **magic-link** route (not in scope) — delete `magic_sign_in_route(...)` from the router.
- Set daisyUI **dark** theme as default so auth pages sit on the Codex canvas; tune via `VerscientaWeb.AuthOverrides` (banner/text/button classes toward Zune accent where reasonable).
- Add a "confirmation pending / check your email" experience after registration.
- **Top strip nav** (`root.html.heex`) becomes auth-aware:
  - signed-out: `sign in` · `register`.
  - signed-in: `@username` (links to profile) · `settings` · `sign out`.
  - Requires the current user in the layout assigns (via the browser pipeline / `on_mount`).

## Section 4: Profiles

- **Public profile** — route `/@:username` → `ProfileLive` (`live_user_optional`). Codex profile header (large lowercase name, `@username`, role badge using an accent, bio, avatar image or initials block). Read-only. 404 for unknown username.
- **Settings** — route `/settings` → `SettingsLive` (`live_user_required`). Form bound to `update_profile` via `AshPhoenix.Form`, editing `username`/`display_name`/`bio`/`avatar_url`, with live validation and a success flash. Email/password changes use the existing AshAuthentication flows (link out to reset for password); changing email is out of scope for MVP.

## Section 5: Testing

**Resource/domain (DataCase)**
- Register with password creates an unconfirmed user; confirmation action sets `confirmed_at`.
- Sign-in with correct/incorrect password.
- Password reset request + reset updates the hash.
- `username` and `email` uniqueness violations return changeset errors.
- `username` format validation rejects bad values.
- `update_profile` by the owner succeeds; by a different actor is forbidden; `role`/`email` cannot be set through it.

**Web (ConnCase / LiveView)**
- `/settings` requires auth (redirects when signed out); renders and saves for a signed-in user; shows validation errors.
- `/@:username` renders a known profile; 404s for unknown.
- Top-strip nav reflects signed-in vs signed-out state.

**Quality gates:** existing CI — `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test`. New migrations generated via `mix ash.codegen`.

## Out of Scope (deferred)

- Magic-link sign-in (route removed).
- Avatar file uploads / Cloudflare Images (Phase 2).
- Email change flow; social/OAuth logins (Ueberauth) — later.
- Points / badges / stats on profiles (Gamification subsystem).
- Admin UI for role management (console/seeds only for now).
- Real production email transport (deployment phase).

## Definition of Done

- A new user can register, receives a confirmation email (viewable at `/dev/mailbox`), confirms, signs in, and signs out.
- Forgotten-password reset works end to end via emailed link.
- `/@:username` shows a Codex-styled public profile; `/settings` lets the owner edit their profile with validation.
- Role exists and defaults to `:user`; it cannot be set via the public update action.
- Top-strip nav is auth-aware.
- All tests pass; CI green; migrations committed.
