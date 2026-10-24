# Digest Emails — Core + Unsubscribe Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-05
**Status:** Approved
**Phase:** 3 — Intelligence & Growth · Notifications & Digests (slice 1 of 2 + deferred push)
**Depends on:** `Recommendations.for_you/2` (highlights), `Verscienta.Mailer` (Swoosh) + the AshAuthentication sender pattern, the `User` resource + `:update_notification_prefs` precedent, the `:digest_emails` flag (already declared), `Phoenix.Token`.
**New dependency:** none.

## Goal

Let a user receive a personalized digest email of their top "For You" articles, opt in via settings, and unsubscribe in one click. This slice builds the digest mechanism end-to-end (preference → content → email → per-user send → unsubscribe); the scheduled fan-out that runs it daily/weekly is slice 2. Opt-in by default (no unsolicited mail).

## Decomposition context

Notifications & Digests splits into: **1 (this — digest email + per-user send + unsubscribe)**, 2 (scheduled cron fan-out by frequency), and deferred push/web-push. This slice's `SendDigestWorker` is enqueued manually/in tests; slice 2 schedules it.

## Decisions

| Decision | Choice |
|----------|--------|
| Frequency | `digest_frequency` `:atom` one_of `[:off, :daily, :weekly]`, **default `:off`** (opt-in) |
| Highlights | top ~5 `Recommendations.for_you` articles published within the window (7 d weekly / 1 d daily); **skip send if empty** |
| Email | Swoosh HTML + text via `Verscienta.Mailer`; one-click unsubscribe footer link |
| Unsubscribe | `Phoenix.Token` signed link → `GET /digests/unsubscribe/:token` → set `:off` (no login) |
| Settings | a digest-frequency selector in `SettingsLive` (opt-in is needed to be usable) |
| Send tracking | `last_digest_at` set on each actual send |
| Gating | the `:digest_emails` flag (the worker no-ops when off) |

## Section 1: User fields + actions

In `lib/verscienta/accounts/user.ex`:
- attributes: `digest_frequency, :atom` (`constraints: [one_of: [:off, :daily, :weekly]]`, `default: :off`, `allow_nil?: false`, public); `last_digest_at, :utc_datetime_usec` (nullable, public).
- action `:set_digest_frequency` (update) — `accept [:digest_frequency]`; policy `authorize_if expr(id == ^actor(:id))` (mirror `:update_notification_prefs`). The unsubscribe controller calls it with `authorize?: false` (token-authed).
- action `:record_digest_sent` (update) — `accept []`, `require_atomic? false`, `change set_attribute(:last_digest_at, &DateTime.utc_now/0)` (no hooks; worker-only, called `authorize?: false`).
- migration adds both columns.

## Section 2: `Verscienta.Digests` context

New `lib/verscienta/digests.ex` (a plain module, not an Ash domain):
- `@highlight_limit 5`.
- `highlights(user)` — window from `digest_frequency` (`:weekly` → 7 days, `:daily` → 1 day; `:off` → `[]`); take `Recommendations.for_you(user, limit: 30)`, keep items whose `article.published_at` is within `now - window`, take the first `@highlight_limit` articles. Returns `[%Article{}]` (possibly `[]`). (`for_you` already eligibility-filters + excludes engaged; the date filter narrows to the window.)
- `window_days(frequency)` helper (`:weekly` → 7, `:daily` → 1, else 0).
- `unsubscribe_token(user)` — `Phoenix.Token.sign(VerscientaWeb.Endpoint, "digest unsubscribe", user.id)`.
- `verify_unsubscribe_token(token)` — `Phoenix.Token.verify(..., "digest unsubscribe", token, max_age: <30 days>)` → `{:ok, user_id} | {:error, reason}`.

## Section 3: Digest email

`lib/verscienta/digests/email.ex` — `build(user, articles)` returns a `Swoosh.Email`:
- to: user; from: the app's configured from-address (reuse the senders' from); subject: e.g. "Your Verscienta digest".
- HTML + text body: a greeting + each article as title (linked to the absolute `url(~p"/articles/<slug>")`) + excerpt; a footer with an **unsubscribe** link to `url(~p"/digests/unsubscribe/#{token}")` and a one-line "you're receiving this because…".
- `deliver(user, articles)` → build + `Verscienta.Mailer.deliver/1`.
Mirror the existing senders' structure (`lib/verscienta/accounts/user/senders/*`) for from-address + mailer usage.

## Section 4: `SendDigestWorker`

`lib/verscienta/digests/workers/send_digest_worker.ex` (Oban; queue `:default`; `unique` by user_id over a short window; `max_attempts` 3):
- `perform(%{"user_id" => id})`:
  - if `not Flags.enabled?(:digest_emails)` → `:ok`;
  - `Ash.get(User, id)` → not found → `:ok`;
  - if `user.digest_frequency == :off` → `:ok`;
  - `articles = Digests.highlights(user)`; if `articles == []` → `:ok` (skip — no hollow digest);
  - `Digests.Email.deliver(user, articles)`; on success run `:record_digest_sent`; `:ok`. Deliver errors bubble for retry.

## Section 5: Unsubscribe

`lib/verscienta_web/controllers/digest_controller.ex` + route `get "/digests/unsubscribe/:token", DigestController, :unsubscribe` (in the public browser scope, no auth):
- verify the token; on `{:ok, user_id}` → load the user + run `:set_digest_frequency` `:off` (`authorize?: false`); render a simple "You've been unsubscribed" page (a minimal template or `text/html`).
- on `{:error, _}` → render a "link expired/invalid" page (still 200, friendly).

## Section 6: Settings opt-in

In `SettingsLive` (and its form): add a digest-frequency control (off / daily / weekly) bound to `:set_digest_frequency` (or fold into the existing prefs save). Changing it persists `digest_frequency`. (Read the current `SettingsLive` to integrate with its existing form/sections; keep it consistent.)

## Section 7: Testing

- **`Digests.highlights/1`**: a `:weekly` user with recent published For-You articles gets them (within the window); articles older than the window are excluded; an `:off` user → `[]`; capped at 5.
- **`SendDigestWorker`** (Swoosh test adapter / `assert_email_sent`-style): a `:weekly` user with highlights → an email is delivered to them + `last_digest_at` set; an `:off` user, the flag off, or empty highlights → no email; the email body contains the unsubscribe link + an article title. (Enable `:digest_emails` in these tests.)
- **Unsubscribe**: `GET /digests/unsubscribe/<valid token>` sets the user to `:off` + renders confirmation; an invalid/garbage token renders the friendly error (no crash); the token round-trips (`unsubscribe_token` → `verify`).
- **`SettingsLive`**: changing the digest selector persists `digest_frequency` (e.g. off → weekly).
- Full suite + `credo --strict` + `dialyzer` + format green.

(Testing note: the app already configures a Swoosh test/local adapter in test; assert deliveries via `Swoosh.TestAssertions` — confirm the existing email tests' approach and mirror it.)

## Out of scope (later / deferred)

The scheduled cron fan-out that enqueues `SendDigestWorker` by frequency (slice 2); push / web-push (deferred); non-article digest content (new followers, comment replies, room activity); per-user optimal send-time; rich HTML email theming/branding beyond a clean baseline; digest open/click analytics; a digest preview.

## Definition of Done

- `User.digest_frequency` (default `:off`) + `last_digest_at` + `:set_digest_frequency` + `:record_digest_sent` + migration.
- `Verscienta.Digests` (`highlights/1`, unsubscribe token sign/verify).
- `Digests.Email` (HTML+text, unsubscribe footer) via `Verscienta.Mailer`.
- `SendDigestWorker` (flag/off/empty guards; deliver + record; retryable).
- `GET /digests/unsubscribe/:token` controller (token-authed → set `:off`; friendly invalid case).
- `SettingsLive` digest-frequency opt-in selector.
- Tests across highlights / worker (delivered + guards) / unsubscribe (valid+invalid) / settings; full suite + credo + dialyzer green.
- `docs/todo.md` "Daily/weekly digest email generation" + "unsubscribe management" reflected (generation + unsubscribe done; the scheduled Oban fan-out is slice 2). No new dependency.
