# Auth Hardening — Design Spec

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-05
**Status:** Approved (design) — ready for implementation planning
**Phase:** Phase 1 (MVP) — final auth/account follow-ups

## Summary

The final outstanding Phase 1 feature work is auth/account hardening. This subsystem adds
three loosely-coupled capabilities to the existing AshAuthentication setup:

1. **Rate limiting** on the authentication endpoints (`/auth/*`).
2. **Email change** with confirm-the-new-address-first semantics.
3. **Account deletion** via a 30-day grace period that deactivates immediately and
   anonymizes (soft-deletes) later.

Each unit is independently testable and communicates through narrow interfaces. None of them
touch authored content rows — anonymization scrubs the `User` row in place so every foreign
key (`Article.author_id`, `Comment.author_id`, follows, points, referrals, leaderboards)
stays valid and thread/leaderboard integrity is preserved.

## Context (current state)

- **Auth stack:** AshAuthentication (password strategy) on `Verscienta.Accounts.User`, with:
  - `confirmation :confirm_new_user` add-on monitoring `[:email]`, `confirm_on_create? true`,
    `confirm_on_update? false`.
  - `tokens` enabled with `store_all_tokens?` and `require_token_presence_for_authentication?`.
  - `log_out_everywhere` add-on (`apply_on_password_change? true`).
  - A `change_password` action that already validates the current password via
    `AshAuthentication.Strategy.Password.PasswordValidation`.
- **Routes:** Auth endpoints are the generated `AuthController` routes under `/auth/*`
  (`auth_routes`, `sign_in_route`, `reset_route`, `confirm_route`). No rate limiting today.
- **Settings:** `VerscientaWeb.SettingsLive` (`/settings`) has profile + notification-prefs
  forms only. No password-change, email-change, or delete UI.
- **Infra:** Redis is already run (the L2 cache, `Verscienta.Cache`); Oban is configured with
  a `default`/`aggregation`/`ai` queue set and a cron plugin. Multi-node readiness is a Phase 4
  goal — single-node today.

## Decisions (locked during brainstorming)

| Topic | Decision |
|---|---|
| Deletion data model | **Anonymize / soft-delete.** Scrub PII on the `User` row, keep authored content reattributed to the tombstoned identity. |
| Deletion timing | **30-day grace period.** Deactivate immediately (sign out everywhere, hide profile/content, block sign-in); finalize via Oban after 30 days. Signing back in within the window cancels. |
| Re-auth gate | **Current password required** for both email-change and deletion. Deletion additionally requires **typing the username** to confirm. |
| Email change | **Confirm new address first.** Hold the change until the new address confirms; notify the old address with a "wasn't me" heads-up. |
| Rate-limit backend | **Hammer + ETS now, Redis-ready.** Wrapped behind `Verscienta.RateLimit` so a later swap to the Hammer Redis backend is a one-module change. |
| Rate-limit scope/key | **Per-IP AND per-identity**, covering sign-in, password-reset request, registration, and the new email-change request. Friendly "too many attempts" error on limit. |
| Rate-limit enforcement point | **Ash action layer**, not an HTTP plug. AshAuthentication.Phoenix validates credentials inside LiveView-invoked actions; failed attempts never reach a controller, so a `/auth/*` plug can't see them. Client IP is threaded into the action via an `on_mount` seam (LiveComponents share the LiveView process). |
| Email-change mechanism | **Built-in AshAuthentication confirmation add-on** (hold-until-confirmed), not a hand-rolled `pending_email` column — reuses the existing token resource, sender pattern, and confirm route. |

## Architecture

Three units:

1. **`Verscienta.RateLimit`** — thin wrapper over Hammer (ETS backend). Single public surface
   `check(bucket, key)`; all bucket scales/limits defined here (tunable via app config). Fails
   open if the backend errors. Enforced from **inside the relevant Ash actions** (a preparation
   on the `sign_in_with_password` read action; changes on `register_with_password`,
   `request_password_reset_token`, and the new `request_email_change`). The client IP is captured
   by a `:capture_client_ip` `on_mount` hook on the auth `live_session`s, which stashes the peer
   IP for the action to read (the form LiveComponents run in the same LiveView process). On a
   limit breach the action returns an `Ash.Error` surfaced as a form error ("Too many attempts,
   try again in N seconds").
2. **Email change** — a second confirmation add-on on `User` monitoring `:email` for updates,
   configured to store the pending change in the token and apply it only on confirmation. A
   `request_email_change` action (password-gated) drives it; a sender emails the new address; a
   courtesy notification goes to the old address.
3. **Account deletion** — a deactivate → grace → anonymize lifecycle on `User`, plus an Oban
   `AccountPurgeWorker` (daily cron) that finalizes expired requests. Sign-in and `LiveUserAuth`
   learn the deactivated/anonymized states.

## Data model changes (`User`)

New attributes:

- `deactivated_at :utc_datetime_usec` (nil = active). Presence ⇒ account hidden + sign-in blocked
  (but reactivatable).
- `deletion_finalizes_at :utc_datetime_usec` — when `AccountPurgeWorker` should anonymize
  (request time + 30 days).
- `anonymized_at :utc_datetime_usec` — set when finalized; marks a permanent tombstone.

No new column for email change (the pending value rides in the confirmation token). Authored
content FKs are untouched.

A migration adds the three nullable columns. (Confirm exact Ash codegen approach during planning;
the project uses `AshPostgres` migrations.)

## Actions, flows & policies

### Email change (`/settings`, password-gated)

- **`request_email_change`** (update action):
  - Validates the current password (`PasswordValidation`, same pattern as `change_password`).
  - Accepts the new email (`:ci_string`).
  - Triggers confirmation to the **new** address (sender) and a notification to the **old**
    address ("an email change was requested; if this wasn't you …").
  - The email attribute only swaps when the confirmation link is clicked (handled by the existing
    `/auth/.../confirm` route + the update-confirmation add-on).
- New senders: `SendEmailChangeConfirmationEmail` (to new address),
  `SendEmailChangedNotificationEmail` (to old address).

### Account deletion (`/settings` → danger zone, password + typed-username gated)

- **`request_deletion`** (update action):
  - Validates current password.
  - Validates a submitted `confirm_username` argument equals the user's current username.
  - Sets `deactivated_at = now`, `deletion_finalizes_at = now + 30d`.
  - Revokes all tokens (reuse the `log_out_everywhere` machinery).
  - LiveView redirects to a goodbye page.
- **`cancel_deletion`** (update action): clears `deactivated_at` + `deletion_finalizes_at`.
  Fired automatically on a successful sign-in while deactivated (reactivation).
- **`anonymize`** (system update action, called by the worker):
  - Scrub `email → deleted+<id>@verscienta.invalid`, `username → deleted_<short-id>`,
    null out `display_name`, `bio`, `avatar_url`, `flair`, `equipped_theme`.
  - Set `anonymized_at = now`.
  - Keep `id`, `role`, `points`, and all content/relationship links intact.
- **`AccountPurgeWorker`** (Oban, daily cron): selects users where
  `deletion_finalizes_at <= now and anonymized_at is nil`, calls `anonymize` on each.

### Sign-in / session changes

- **`sign_in_with_password`**: reject users with `anonymized_at` set (treat as no account). For
  merely-deactivated users, allow sign-in and fire `cancel_deletion` (reactivation).
- **`LiveUserAuth`**: guards stale sessions for deactivated/anonymized users; primary
  reactivation path is the sign-in action itself.
- **Public surfaces**: `/@:username` profile and content/feed queries filter out
  deactivated/anonymized users; existing content they authored renders under the tombstone
  identity.

### Policies

- `request_email_change`, `request_deletion`, `cancel_deletion` (self path) →
  `authorize_if expr(id == ^actor(:id))`.
- `anonymize` → system action (worker actor / bypass), not user-invokable.
- Existing `AshAuthenticationInteraction` bypass continues to cover strategy-driven actions.

## Rate limiting

Buckets defined in `Verscienta.RateLimit` (Hammer/ETS), enforced **inside the Ash actions**,
keyed **per-IP and per-identity (email)**. Starting values (tunable via config):

| Action | Per-IP | Per-identity (email) |
|---|---|---|
| `sign_in_with_password` | 10 / 5 min | 5 / 15 min |
| `request_password_reset_token` | 5 / 15 min | 3 / hour |
| `register_with_password` | 5 / hour | — (no account yet) |
| `request_email_change` | 5 / hour | 3 / hour (per actor) |

**Mechanism:**
- A preparation (read action) / change (other actions) calls `Verscienta.RateLimit.check(bucket, key)`
  before the credential work. If `{:error, retry_after_s}`, the action adds an error so the
  LiveView form shows "Too many attempts, try again in N seconds."
- **IP capture:** the endpoint's LiveView socket `connect_info` is extended with `:peer_data` and
  `:x_headers`. A `:capture_client_ip` `on_mount` hook (added to the sign-in/register and reset
  `live_session`s) reads the client IP — preferring the left-most `x-forwarded-for` entry when
  present, else `peer_data` — and stores it with `Process.put(:auth_client_ip, ip)`. The form
  components run in the same LiveView process, so the action preparation/change reads it via
  `Process.get(:auth_client_ip)`. Missing IP ⇒ skip the IP bucket (identity bucket still applies).
- **Fail open:** if the Hammer backend raises, `check/2` logs and returns `:ok` (never lock out all
  auth because ETS hiccupped).
- **Test mode:** `config/test.exs` sets very high limits (effectively disabled) so existing auth
  tests aren't throttled; rate-limit tests set tight limits via `Application.put_env` in setup.

## Configuration

- Add `hammer` (`~> 7.0`) to `mix.exs`; the `Verscienta.RateLimit` module is `use Hammer, backend: :ets`
  and is started in the supervision tree (`Verscienta.Application`).
- Extend the endpoint LiveView socket `connect_info` with `:peer_data` and `:x_headers` for IP capture.
- Bucket scales + limits exposed as app config so they're tunable per environment and loosened in test.
- Add the `AccountPurgeWorker` to the Oban cron crontab (daily).

## Testing

- **Unit:**
  - `RateLimit.check` boundary behavior (Nth allowed, N+1 denied; window reset).
  - `anonymize` scrubs exactly the intended fields and preserves `id`/`role`/links.
  - `request_deletion` sets `deactivated_at` + `deletion_finalizes_at` and rejects a wrong
    password or mismatched username.
  - `AccountPurgeWorker` selects only expired, not-yet-anonymized users.
- **Integration:**
  - Sign-in within the grace window cancels deletion and reactivates.
  - A deactivated user is hidden from `/@:username` and feeds.
  - Email change does not swap the address until the new-address link is confirmed; the
    old-address notification is sent.
  - Anonymized user cannot sign in.
- **Plug:** N+1 auth POST returns 429; fail-open path when the backend is down.
- Use the existing Oban `testing: :manual` mode for the purge worker; rate-limit config
  loosened/bypassed in `config/test.exs` so existing auth tests aren't throttled.

## Out of scope (explicit)

- Multi-node-shared rate limiting (Redis backend) — deferred; the wrapper makes it a later swap.
- 2FA / MFA, passkeys, OAuth social login.
- Data export ("download my data") — that's a Phase 4 GDPR item.
- Admin-initiated account suspension/banning (distinct from self-service deletion).
- Re-confirmation of email on every login or device management UI.

## Open items to confirm during planning

- Exact AshAuthentication option names for the hold-until-confirmed update-confirmation add-on
  (`inhibit_updates?` + `confirm_on_update?`), verified against the installed AshAuthentication 4.x.
- Whether `log_out_everywhere` can be invoked directly from `request_deletion` or whether token
  revocation needs an explicit token-resource call.
- Production `x-forwarded-for` trust: confirm the deployment proxy (Coolify) sets a trustworthy
  `x-forwarded-for` so the `on_mount` IP capture keys on the real client IP, not the proxy.
