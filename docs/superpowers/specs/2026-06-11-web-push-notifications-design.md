# Web-Push Notifications

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-11
**Phase:** 3 — Intelligence & Growth › Notifications & Digests
**Todo item:** `(Optional) Web-push notifications.`

## Goal

Deliver browser **push notifications** as a third channel alongside in-app and email
digests: when a user receives a notification and has opted into push (granted browser
permission + subscribed), fire a native push to their device(s).

## Decisions (from brainstorming)

- **`web_push_encryption` hex dep** for RFC 8291 message encryption + VAPID (ES256) —
  not hand-rolled (crypto is security-critical).
- **Mirror in-app + master toggle:** any notification a user gets in-app also pushes
  (reusing the existing per-type `notification_prefs` opt-outs), gated by one master
  `web_push` channel toggle.
- **Sender seam:** the actual encrypt-and-POST is behind a configurable behaviour
  (real impl + test stub), so the server side is fully tested without real crypto or
  network.
- **Off-by-default `:web_push` flag** + a `configured?/0` (VAPID keys present) check —
  the feature stays dark until keys are set.

## Honest boundary

Server side is fully unit-tested (subscription storage, dispatch gating, the worker +
pruning, the controller, the notify hook). The **service worker, the browser
`PushManager` subscribe, the JS hook, and real `web_push_encryption` crypto + delivery
are browser-only** — they need VAPID keys and a real browser/push service and are
**not** unit-tested (verified manually). Ships dark behind the flag.

## Background (current state)

- `Verscienta.Notifications.notify/1` (`lib/verscienta/notifications.ex:34-55`):
  self-notify-blocked, prefs-gated via `enabled?(recipient, type)`, best-effort
  (`rescue _ -> :ok`). Creates a `Notification`, `invalidate_unread/1`,
  `broadcast(recipient_id, {:notification, id})`. **Web-push hooks in after the
  broadcast.**
- `Notification` resource (`lib/verscienta/notifications/notification.ex`): `type`
  (one of `@types`), `subject_type`, `subject_id`, `metadata`, `read_at`; `belongs_to
  :recipient`, `:actor`.
- Prefs: `User.notification_prefs` (`:map`, default `%{}`); `enabled?/2` is opt-out —
  `Map.get(prefs, to_string(type), true) != false`. Master push toggle reuses this map
  under the `"web_push"` key.
- `:jose`/`:joken` present transitively; **no web-push lib**. `Req` available; Oban
  available.
- No service worker / manifest exists. `static_paths/0`
  (`lib/verscienta_web.ex:20`) = `~w(assets fonts images favicon.ico robots.txt)`.
  `Plug.Static` serves from `priv/static` at `/`. CSRF token meta tag present in
  `root.html.heex`; `:browser` pipeline has `protect_from_forgery` (accepts the
  `X-CSRF-Token` header).
- Flags: `@known_flags` (`flags.ex`), `@phase3_off` + `@labels` (`flags/seeds.ex`).
- A stub-via-config pattern exists for analytics (`:analytics_client`) — the
  web-push Sender mirrors it.

## Architecture

### 1. Dependency, config, flag

- `mix.exs`: add `{:web_push_encryption, "~> 0.3"}` (confirm the current version;
  it wraps `:jose`). Run `mix deps.get`.
- `config/runtime.exs`: VAPID details (optional, like LiveKit):
  ```elixir
  config :web_push_encryption, :vapid_details,
    subject: System.get_env("VAPID_SUBJECT", "mailto:noreply@verscienta.news"),
    public_key: System.get_env("VAPID_PUBLIC_KEY"),
    private_key: System.get_env("VAPID_PRIVATE_KEY")
  ```
  Dev/test: a generated, committed test keypair (so `configured?/0` is true and tests
  run). The Sender stub means the keys are never used for real crypto in tests.
- `config/config.exs` (or test.exs): `config :verscienta, :web_push_sender,
  Verscienta.WebPush.Sender.Live` (prod/dev) and the stub in `config/test.exs`.
- New `:web_push` flag → `@known_flags` + `@phase3_off` + a `@labels` entry
  (`"Web push notifications"`).

### 2. `PushSubscription` resource + migration

`Verscienta.Notifications.PushSubscription` (AshPostgres):
- `endpoint` (`:string`, required) with a **unique identity** on `endpoint`.
- `p256dh` (`:string`, required), `auth` (`:string`, required).
- `belongs_to :user, Verscienta.Accounts.User` (required).
- Actions: `upsert` (create with `upsert?: true`, `upsert_identity: :unique_endpoint`
  — re-subscribing the same endpoint updates keys/user); `destroy`; a read
  `for_user(user_id)`. System actions (`authorize?: false`); subscriptions are managed
  only via `Verscienta.WebPush`.
- Migration: `push_subscriptions` table (id, user_id FK, endpoint unique, p256dh, auth,
  timestamps).

### 3. `Verscienta.WebPush` + Sender seam + worker

**`Verscienta.WebPush`:**
```elixir
def configured?, do: <vapid public + private present>
def save_subscription(user, %{"endpoint" => e, "keys" => %{"p256dh" => p, "auth" => a}})  # upsert
def delete_subscription(user, endpoint)                                                    # destroy
def dispatch(%Notification{} = n, recipient)   # called from notify/1
```
- **`dispatch/2`**: if `Verscienta.Flags.enabled?(:web_push) and configured?() and
  channel_on?(recipient)` → build a payload and `SendWebPushWorker.new(%{"user_id" =>
  recipient.id, "payload" => payload}) |> Oban.insert()`. Else `:ok`. `channel_on?` =
  `Map.get(prefs, "web_push", true) != false`. (The per-type opt-out was already
  honored by `notify/1`; the self-notify block too.)
- **Payload** (`%{"title" => ..., "body" => ..., "url" => ...}`): a per-type
  title/body from the notification + actor username; `url` → `/notifications` for MVP
  (deep-linking per type is out of scope). A small private `payload_for/1`.

**Sender seam** — `Verscienta.WebPush.Sender` behaviour:
```elixir
@callback send(subscription :: map(), message :: String.t()) :: {:ok, status :: integer()} | {:error, status :: integer()}
```
- `Sender.Live`: builds the `web_push_encryption` subscription struct from
  `%{endpoint, p256dh, auth}` and calls `WebPushEncryption.send_web_push(message, sub)`,
  mapping the HTTP result to `{:ok|:error, status}`. (Exact return shape confirmed
  against the lib; this impl is browser/network-verified, not unit-tested.)
- `Sender.Stub` (test): sends `{:web_push, endpoint, message}` to a configured test pid
  and returns a status — `{:error, 410}` for an endpoint flagged "expired" (to drive
  the pruning test), else `{:ok, 201}`.
- Resolved via `Application.get_env(:verscienta, :web_push_sender)`.

**`SendWebPushWorker`** (Oban, `queue: :default`):
- Loads `PushSubscription.for_user(user_id)`; for each, `Sender.send(sub, Jason.encode!(payload))`;
  on a `404`/`410` status (`{:ok, s}` or `{:error, s}`), **delete that subscription**
  (prune dead endpoints). Returns `:ok` (best-effort — a transient send error doesn't
  fail the job hard; rely on Oban retry only for unexpected raises).

### 4. Notify integration

In `Notifications.notify/1`, after `broadcast(recipient_id, {:notification, notification.id})`:
```elixir
Verscienta.WebPush.dispatch(notification, recipient)
```
(Inside the existing best-effort body — the whole `notify/1` already `rescue`s to `:ok`,
so a web-push hiccup never affects the in-app notification.)

### 5. Client — service worker, hook, controller, settings

- **`priv/static/sw.js`** (plain static file; add `"sw.js"` to `static_paths/0`):
  ```js
  self.addEventListener("push", (event) => {
    const data = event.data ? event.data.json() : {}
    event.waitUntil(self.registration.showNotification(data.title || "Verscienta", {
      body: data.body || "", data: { url: data.url || "/" }, icon: "/images/icon-192.png"
    }))
  })
  self.addEventListener("notificationclick", (event) => {
    event.notification.close()
    event.waitUntil(clients.openWindow(event.notification.data.url || "/"))
  })
  ```
  (Served at `/sw.js` → root scope.)
- **`assets/js/push_subscription.js`** hook (registered in `app.js`), on a settings
  button: `navigator.serviceWorker.register("/sw.js")` → `Notification.requestPermission()`
  → `reg.pushManager.subscribe({userVisibleOnly: true, applicationServerKey:
  urlBase64ToUint8Array(this.el.dataset.publicKey)})` → `fetch("/api/push/subscribe",
  {method: "POST", headers: {"X-CSRF-Token": ..., "Content-Type": "application/json"},
  body: JSON.stringify(sub.toJSON())})`. An unsubscribe path calls `sub.unsubscribe()` +
  `DELETE`. Feature-detect `serviceWorker`/`PushManager`; no-op + a message if absent.
- **`PushSubscriptionController`** (authenticated, `:browser`): `create` (save the posted
  subscription JSON via `WebPush.save_subscription`), `delete` (`WebPush.delete_subscription`
  by endpoint). Returns JSON (`201`/`200`/`4xx`). Routes:
  `post "/api/push/subscribe"` + `delete "/api/push/subscribe"`.
- **Settings UI** (the notification-prefs LiveView/section): a flag+`configured?`-gated
  "Browser push" block — the master `web_push` toggle (writes `notification_prefs`) and a
  per-device "Enable on this device" button carrying `phx-hook="PushSubscription"` +
  `data-public-key={vapid_public_key}`.

## Testing

- **`PushSubscription`**: upsert by endpoint (second upsert updates, doesn't duplicate);
  `for_user`; destroy.
- **`WebPush.save_subscription`/`delete_subscription`**: persist + remove.
- **`WebPush.dispatch`** gating (with the Sender stub + a subscribed recipient):
  flag off → no job; not configured → no job; channel toggle off → no job; all-on →
  one `SendWebPushWorker` enqueued with a payload carrying the right title/body/url.
- **`SendWebPushWorker`**: with two subscriptions (one normal, one "expired") →
  `Sender.send` called for both (assert via the stub pid); the expired one is **pruned**
  (deleted), the normal one remains.
- **`PushSubscriptionController`**: `POST` with a subscription JSON saves it (and is
  idempotent on the same endpoint); `DELETE` removes it; both require auth (a signed-out
  request is rejected/redirected).
- **`Notifications.notify` integration**: a `notify/1` to a subscribed recipient with
  `:web_push` enabled enqueues `SendWebPushWorker`; with the flag off, it does not; a
  self-notification never enqueues.
- **Not tested** (documented in code comments): `sw.js`, the JS hook, the browser
  subscribe flow, and `Sender.Live`'s real `web_push_encryption` crypto + HTTP delivery.

## Out of scope (later)

- Per-type push preferences (we mirror in-app); deep-link URLs per notification type
  (MVP opens `/notifications`); notification grouping/collapsing; badge counts.
- A web-app manifest / full PWA install (only the SW needed for push); an app icon set
  beyond a single `icon-192.png` (add one if missing, else reuse the favicon).
- VAPID key rotation tooling; push for non-`Notification` events; digest/marketing push.
- Automated/browser testing of the service worker + subscribe flow.

## Files touched (summary)

- `mix.exs` (+`mix.lock`) — `web_push_encryption`.
- `config/runtime.exs` (VAPID), `config/config.exs` + `config/test.exs` (sender),
  `lib/verscienta/flags.ex` + `flags/seeds.ex` (`:web_push`).
- `lib/verscienta/notifications/push_subscription.ex` + a migration.
- `lib/verscienta/web_push.ex`, `lib/verscienta/web_push/sender.ex` (+ `Live`/`Stub`),
  `lib/verscienta/web_push/send_web_push_worker.ex`.
- `lib/verscienta/notifications.ex` — the `dispatch/2` hook.
- `lib/verscienta_web/controllers/push_subscription_controller.ex` +
  `lib/verscienta_web/router.ex` routes.
- `priv/static/sw.js` + `lib/verscienta_web.ex` (`static_paths`),
  `assets/js/push_subscription.js` + `assets/js/app.js`, the settings LiveView section.
- Tests across the server-side pieces. One new flag, one new resource/migration, one dep.
