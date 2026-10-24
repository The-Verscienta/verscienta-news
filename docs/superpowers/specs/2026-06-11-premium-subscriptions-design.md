# Premium Subscriptions (PayPal billing) — Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-11
**Todo item:** Phase 4 → Monetization → "Premium subscriptions (billing integration)"
**Decision:** PayPal only (user confirmed; "Evalon/Elavon" dropped). Billing machinery only —
content paywalls are the separate "Paywalled / premium content tiers" todo item and are out of
scope here.

## Goal

Users can buy a premium subscription (monthly or annual) through PayPal, manage/cancel it from
settings, and the app exposes a single `Accounts.premium?/1` check that later paywall work will
consume. Subscription state stays correct via PayPal webhooks.

## Scope

In scope:

- One premium tier, two billing cycles: monthly and annual. Prices live in PayPal Plans, not in
  our code.
- Server-driven redirect checkout (no client-side JS, no PayPal JS SDK).
- Webhook-driven lifecycle sync.
- `/premium` pricing page, subscription panel in `/settings`, premium badge on profile.
- `Accounts.premium?/1` + cached lookup.
- One-time provisioning mix task for the PayPal Product + Plans.

Out of scope (explicitly):

- Content gating / paywalls (separate todo item).
- Perks (points multipliers, ad-free, etc.).
- Multiple tiers, trials, coupons, proration, plan switching (cancel + resubscribe is the v1
  upgrade path).
- Refund handling beyond mirroring PayPal's subscription status.
- Elavon/card-gateway integration.

## Approach

Server-driven redirect flow against PayPal's REST Subscriptions API:

1. User picks monthly or annual on `/premium`.
2. Server creates a local `Subscription` row in `:pending`, then calls PayPal
   `POST /v1/billing/subscriptions` with `plan_id`, `custom_id = user.id`, and
   `application_context.return_url` / `cancel_url`.
3. User is redirected to PayPal's `approve` link, approves, and is redirected back to our
   return URL with the `subscription_id`.
4. The return controller re-fetches the subscription from PayPal (never trusts query params)
   and activates the local row if PayPal says `ACTIVE`.
5. Webhooks independently drive the same transitions; both paths are idempotent, whichever
   lands first wins.

Rationale: no maintained Elixir PayPal package exists, so the client is hand-rolled either
way; the redirect flow needs zero client JS, which fits this project's vendored-assets/no-npm,
LiveView-first conventions. PayPal's hosted checkout accepts cards without a PayPal account.

Alternatives considered: PayPal JS SDK Smart Buttons (popup UX, but third-party script + JS
hook + CSP complexity inside LiveView); PayPal-hosted no-code subscribe links (cannot attach
our user id at creation; reconcile-by-email is fragile). Both rejected.

## Architecture

### New Ash domain: `Verscienta.Billing`

One resource, `Verscienta.Billing.Subscription`:

| Field                    | Type                                                         | Notes                                  |
| ------------------------ | ------------------------------------------------------------ | -------------------------------------- |
| `user_id`                | belongs_to User                                              | at most one non-terminal sub per user  |
| `paypal_subscription_id` | string, unique index                                         | set at creation                        |
| `plan`                   | atom enum `:monthly` \| `:annual`                            | which PayPal Plan was used             |
| `status`                 | atom enum `:pending` `:active` `:suspended` `:cancelled` `:expired` | mirrors PayPal status          |
| `current_period_end`     | utc_datetime, nullable                                       | from `billing_info.next_billing_time`  |
| timestamps               |                                                              |                                        |

Status transitions: `pending → active`; `active ↔ suspended` (payment failure / recovery);
`active|suspended → cancelled`; `pending|active|suspended → expired`. `cancelled` and
`expired` are terminal. A cancelled subscription keeps premium until
`current_period_end` passes (PayPal keeps it ACTIVE until period end when cancelled by the
user; if PayPal reports CANCELLED we honor `current_period_end` locally).

Actions:

- `start` — create `:pending` row for a user + plan. Guard: error if the user already has a
  `pending|active|suspended` subscription.
- `attach_paypal_id` — set `paypal_subscription_id` after the PayPal create call.
- `sync` — idempotent: given fresh PayPal subscription data (status +
  next_billing_time), apply the matching local transition. Used by both the return
  controller and the webhook worker. Unknown/unchanged statuses are no-ops.
- `cancel_request` — user-initiated: call PayPal cancel, then `sync`.

Policies: owner can read own subscription; create/update only via system (actor `:system` or
authorize?: false from controllers/workers — match the pattern used by existing system-driven
domains); no user-facing destroy.

Stale-`:pending` rows (user abandoned checkout) are handled safely during reuse. When
`start_checkout` finds an existing pending row that already has a `paypal_subscription_id`
attached, it first calls `sync/1` on that id to pick up any just-approved subscription (returning
`{:error, :already_subscribed}` if sync reveals the status is now `:active` or `:suspended`).
Otherwise it best-effort cancels the superseded PayPal subscription (an unapproved
APPROVAL_PENDING subscription is inert, so cancel failure is logged and swallowed), then clears
the stale id and updates the plan before proceeding. If `paypal_subscription_id` is nil (PayPal
call never reached or failed), the row is updated in place as before.

A partial unique index `billing_subscriptions_one_nonterminal_per_user` on `(user_id)` where
`status IN ('pending', 'active', 'suspended')` enforces at most one non-terminal subscription per
user at the database level. A concurrent `start_checkout` that races past the application-level
check and hits this constraint receives `{:error, :already_subscribed}`.

### PayPal client: `Verscienta.Billing.PayPal.Client`

Same shape as `Analytics.Client`: a behaviour with a default Req-based impl, swappable via
`Application.get_env(:verscienta, :paypal_client, __MODULE__.Req)`.

Callbacks:

- `create_subscription(plan_id, custom_id, return_url, cancel_url)` → `{:ok, %{id, approve_url}}`
- `get_subscription(id)` → `{:ok, %{status, plan_id, custom_id, next_billing_time}}`
- `cancel_subscription(id, reason)` → `:ok`
- `verify_webhook_signature(headers, raw_body)` → `{:ok, :verified | :failed}` — calls PayPal's
  `POST /v1/notifications/verify-webhook-signature` with the configured webhook ID.

OAuth: client-credentials token fetched from `/v1/oauth2/token`, cached in ETS (or the
existing cache layer) with expiry minus a safety margin; refetched on 401.

Config (`runtime.exs`, env-driven): `PAYPAL_BASE_URL` (sandbox vs live), `PAYPAL_CLIENT_ID`,
`PAYPAL_CLIENT_SECRET`, `PAYPAL_WEBHOOK_ID`, `PAYPAL_PLAN_ID_MONTHLY`, `PAYPAL_PLAN_ID_ANNUAL`.
Billing features degrade gracefully (pricing page shows "unavailable") when unconfigured —
dev environments won't have PayPal creds by default.

### Provisioning: `mix verscienta.billing.setup`

One-time task: creates the Product (`/v1/catalogs/products`) and two Plans
(`/v1/billing/plans`) in PayPal from CLI-provided prices, prints the Plan IDs to set as env
vars. Idempotence is manual (operator runs it once per environment); the task lists existing
plans first and warns instead of blindly duplicating.

### Web layer

- `PremiumLive` at `/premium` — Codex-styled pricing page, monthly + annual cards, current
  status if already subscribed. Subscribe button → LiveView `subscribe` event which calls
  `start_checkout` and ends in `redirect(socket, external: approve_url)` (no separate
  subscribe controller; LiveView handles the external redirect directly, avoiding CSRF
  plumbing for a plain form POST).
- `GET /premium/return` + `GET /premium/cancelled` — return/cancel landing controller
  actions. Return verifies via `get_subscription` + `sync`, then redirects to `/premium`
  with a flash. Cancelled just flashes "checkout cancelled".
- `POST /webhooks/paypal` — controller outside the browser pipeline (no CSRF). Reads the
  raw body (custom body reader on the route or cached raw body — required for signature
  verification), verifies the signature, then enqueues an Oban job
  (`Billing.SyncSubscriptionWorker`, `:default` queue) with the event; responds 200
  immediately after enqueue, 400 on signature failure. The worker re-fetches the
  subscription from PayPal and calls `sync` — payloads are treated as triggers, not truth,
  which makes event ordering irrelevant.
  Handled events: `BILLING.SUBSCRIPTION.ACTIVATED`, `.CANCELLED`, `.SUSPENDED`, `.EXPIRED`,
  `.PAYMENT.FAILED`, `PAYMENT.SALE.COMPLETED` (refreshes `current_period_end`). Unknown
  events: 200 and ignore. Events for unknown `paypal_subscription_id`: log warn, 200.
- `/settings` panel — shows plan, status, renewal/expiry date; "Cancel subscription" with
  confirm; cancelled state shows "premium until {date}".
- Profile badge — small premium marker next to the existing role/expert badges.

### Premium check

`Verscienta.Accounts.premium?(user)` → true when the user has a subscription with
`status == :active`, or with `status == :cancelled and current_period_end > now`.
`:suspended` (payment failing) is **not** premium — PayPal retries the charge and either
reactivates the subscription or cancels it, and we mirror whichever happens.

Backed by the existing Redis/ETS cache layer with a short TTL (5 min) and explicit
invalidation from `sync`. This function is the single interface the future paywall slice
consumes; nothing else in the app may query Billing directly for gating.

## Error handling

- PayPal API errors during checkout → flash on `/premium`, pending row left for reuse.
- Return URL with a subscription PayPal won't confirm as ACTIVE → flash "still processing,
  you'll be upgraded shortly" (webhook will finish the job).
- Webhook signature failure → 400 (PayPal retries with backoff).
- Worker failures → standard Oban retries; `sync` is idempotent so retries are safe.
- PayPal outage on cancel → flash error, no local state change (user retries).

## Testing

- Mox-style fake of the PayPal client behaviour (config swap, like `:analytics_client`).
- Resource tests: transition matrix for `sync` (idempotency, terminal states, unknown→no-op),
  one-active-per-user guard, pending-row reuse.
- Controller tests: subscribe redirect, return-URL activate, return-URL not-yet-active,
  webhook signature pass/fail, unknown event, unknown subscription id, enqueue + worker run.
- LiveView tests: pricing page render (configured/unconfigured/subscribed states), settings
  cancel flow.
- `premium?/1`: each status × period-end combination; cache invalidation on sync.

## Open questions resolved during brainstorm

- "Evalon" → dropped; PayPal only.
- Scope → billing machinery only; paywalls later.
- Plans → one tier, monthly + annual.
