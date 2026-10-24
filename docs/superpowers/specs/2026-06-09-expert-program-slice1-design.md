# Expert Program — Slice 1: Application → Review → Expert Role

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-09
**Phase:** 3 — Intelligence & Growth › Expert Program
**Todo items (Expert Program):**
- `[ ] Verified Expert application + credential review workflow.` ← Slice 1
- `[ ] Expert badge + elevated trust signals on content/profile.` ← profile badge in Slice 1; content bylines in Slice 2
- `[ ] Expert-only publishing privileges / featured placement.` ← Slice 2
**Slice:** 1 of 2.

## Goal

Let a user apply for verified-expert status, have a moderator/admin review the
application, and on approval promote the user to the existing `:expert` role —
with an in-app notification and a visible "Verified Expert" badge on their
profile. The whole flow is gated by the off-by-default `:expert_program` feature
flag.

## Decisions (from brainstorming)

- **Expert grants elevated treatment, not a restriction.** Publishing stays open
  to everyone; expert status is a trust/quality signal (profile badge now;
  content bylines + featured placement in Slice 2). No publishing is taken away.
- **Permission model = the `:expert` role.** `User.role` already includes
  `:expert` (enum `[:user, :expert, :moderator, :admin]`) — no migration for the
  value. Approval promotes `:user → :expert`.
- **Credentials = links + statement** (no file upload): a free-text statement of
  expertise + one or more credential URLs (LinkedIn, academic profile, license
  registry, publications). Reviewers open the links.
- **Reviewers = moderators + admins**, reusing the existing
  `^actor(:role) in [:moderator, :admin]` gate and the role-gated LiveView
  pattern (`AdminModerationLive`).
- **The application row is the audit record** (reviewer_id / reviewed_at /
  reviewer_note / status) — no separate audit-log resource in Slice 1.
- **`:grant_expert` only promotes a `:user`** — never demotes or changes a
  moderator/admin; no-ops if already `:expert`.
- **One pending application per user**; re-apply allowed after a decision (no
  cooldown). Grant-only (no expert-revocation UI in Slice 1). In-app
  notification only (email deferred).

## Architecture

```
applicant → /experts/apply (gated by :expert_program)
  └─ ExpertApplication :apply  (status :pending; rejects if already :expert or has a pending app)

moderator/admin → /admin/experts (AdminExpertsLive, mod/admin-gated)
  ├─ Experts.pending/0 → queue of pending applications
  ├─ approve → Experts.approve(app, reviewer)
  │     ├─ ExpertApplication :approve (status :approved, reviewer, reviewed_at)
  │     ├─ User :grant_expert  (role :user → :expert)
  │     └─ Notification :create (:expert_application_approved)
  └─ reject → Experts.reject(app, reviewer, note)
        ├─ ExpertApplication :reject (status :rejected, reviewer, reviewed_at, reviewer_note)
        └─ Notification :create (:expert_application_rejected)

profile (/@:username) → renders "✓ Verified Expert" badge when user.role == :expert
```

### 1. `Verscienta.Experts` domain + `ExpertApplication` resource

New domain `Verscienta.Experts` (registered in `config/config.exs` `ash_domains`
and `.formatter.exs` if it lists domains). Resource
`Verscienta.Experts.ExpertApplication` (AshPostgres, table `expert_applications`,
`Ash.Policy.Authorizer`):

Attributes:
- `statement` — `:string`, `allow_nil?: false`, `constraints: [min_length: 20, max_length: 2000]`.
- `credential_urls` — `{:array, :string}`, `allow_nil?: false` (validate ≥1 entry, each an `http(s)://` URL, in `:apply`).
- `status` — `:atom`, `allow_nil?: false`, `default: :pending`,
  `constraints: [one_of: [:pending, :approved, :rejected]]`, `public?: true`.
- `reviewer_note` — `:string`, `allow_nil?: true`, `constraints: [max_length: 1000]`.
- `reviewed_at` — `:utc_datetime_usec`, `allow_nil?: true`.
- `inserted_at` / `updated_at` timestamps.

Relationships:
- `belongs_to :user, Verscienta.Accounts.User` (applicant, `allow_nil?: false`).
- `belongs_to :reviewer, Verscienta.Accounts.User` (`allow_nil?: true`).

Actions:
- `create :apply` — `accept [:statement, :credential_urls]`;
  `change relate_actor(:user)`; a change/validation that (a) every URL is a
  non-empty `http(s)` string and the list is non-empty, (b) the actor's role is
  `:user` (reject `:expert`/mod/admin with a friendly error), (c) no existing
  `:pending` application for the actor. Policy: `authorize_if actor_present()`.
- `read :queue` — `filter expr(status == :pending)`,
  `prepare build(sort: [inserted_at: :asc], load: [:user])`. Policy: mod/admin.
- `read :for_user` — `argument :user_id`; `filter expr(user_id == ^arg(:user_id))`,
  newest first. Used by the applicant to see their own latest application. Policy:
  applicant-self or mod/admin.
- `update :approve` — system action (`authorize?: false`, called by
  `Experts.approve/2` which does the role grant): `accept []`;
  `change set_attribute(:status, :approved)`;
  `change set_attribute(:reviewed_at, &DateTime.utc_now/0)`;
  `change manage reviewer via relate_actor(:reviewer)` OR set reviewer_id from
  the passed reviewer. (Since the context function passes the reviewer, set
  `reviewer_id` explicitly.)
- `update :reject` — `accept [:reviewer_note]`;
  `change set_attribute(:status, :rejected)`;
  `change set_attribute(:reviewed_at, &DateTime.utc_now/0)`; set reviewer_id.

Validation helpers (a `Verscienta.Experts.ExpertApplication.Changes.ValidateApply`
before-action change, or inline): reject when role ≠ `:user`, when
`credential_urls` is empty or any entry isn't `http(s)`, and when a pending
application already exists (`Ash.read` with the `:for_user`/pending filter).

### 2. `Accounts.User` `:grant_expert` action + `Experts` context

Add to `lib/verscienta/accounts/user.ex`:
```elixir
update :grant_expert do
  description "Promote a :user to :expert (no-op if already expert/mod/admin)."
  accept []
  require_atomic? false
  change fn cs, _ctx ->
    case Ash.Changeset.get_attribute(cs, :role) do
      :user -> Ash.Changeset.force_change_attribute(cs, :role, :expert)
      _ -> cs
    end
  end
end
```
Policy: `policy action(:grant_expert) do authorize_if expr(^actor(:role) in [:moderator, :admin]) end`.

`Verscienta.Experts` context functions:
- `apply(user, %{statement:, credential_urls:})` — thin wrapper over the `:apply`
  action (or callers use the action directly from the LiveView).
- `pending/0` — `Ash.read!(ExpertApplication, action: :queue, authorize?: false)`.
- `latest_for_user(user_id)` — the user's most recent application (or nil).
- `approve(application, reviewer)`:
  1. run `ExpertApplication :approve` with `reviewer_id: reviewer.id` (authorize?: false);
  2. promote: `Ash.get!(User, application.user_id) |> Ash.Changeset.for_update(:grant_expert, %{}, actor: reviewer) |> Ash.update!()`;
  3. create `Notification` `:expert_application_approved` (recipient = applicant,
     actor = reviewer, subject_type `:user`, subject_id applicant id);
  best-effort on the notification (never fail the approval); returns `:ok`.
- `reject(application, reviewer, note)`:
  1. run `:reject` with `reviewer_note: note, reviewer_id: reviewer.id`;
  2. create `Notification` `:expert_application_rejected` with the note in metadata;
  returns `:ok`.

Both context functions check `reviewer.role in [:moderator, :admin]` up front
(mirroring `Moderation.resolve/5`), returning `{:error, :unauthorized}` otherwise
— defense in depth beyond the action policy.

### 3. Review queue — `AdminExpertsLive` at `/admin/experts`

Mirror `AdminModerationLive`:
- `on_mount {VerscientaWeb.LiveUserAuth, :live_user_required}`; in `mount`, raise
  a `NotFound` (define `AdminExpertsLive.NotFound`, `plug_status: 404`) when
  `current_user.role not in [:moderator, :admin]`.
- Load `Experts.pending/0` (with `:user` loaded). Render each application: the
  applicant's `@username`, bio, the statement, and `credential_urls` as
  `target="_blank" rel="noopener"` links, plus submitted time.
- Buttons: **approve** (`phx-click="approve"`, `phx-value-id`) and **reject** —
  reject reveals a small note textarea then submits (`phx-value-id` + the note).
  Handlers call `Experts.approve/2` / `Experts.reject/3` with
  `socket.assigns.current_user`, flash, and reload the queue.
- Add a nav entry to the moderator/admin area (next to the moderation queue link).
- Route in `router.ex` under the authenticated live_session.

### 4. Applicant flow — `/experts/apply` (`ExpertApplyLive`)

- `on_mount :live_user_required`; gate the apply form behind
  `Verscienta.Flags.enabled?(:expert_program)` — if the flag is off, render a
  "not currently accepting applications" message (or raise NotFound). The route
  exists regardless; the flag gates the form.
- On mount, load `Experts.latest_for_user(current_user.id)` and branch:
  - `current_user.role == :expert` → "You're a verified expert." (no form)
  - latest status `:pending` → "Your application is under review." (no form)
  - latest status `:rejected` → show the reviewer note + the form to re-apply.
  - no application (and role `:user`) → show the form.
- Form: `statement` textarea + a `credential_urls` input (one URL per line in a
  textarea; split on newlines, trim, drop blanks). Submit → `:apply` action with
  `actor: current_user`. On success, flash + show the pending state. On a
  validation error (bad URL, already pending, etc.), render the error.
- Link to `/experts/apply` from `/settings` (and/or the user's own profile) when
  the flag is on and the user is not already an expert.

### 5. Trust signal + notifications

- **Profile badge** (`profile_live.ex`): where the role label renders today
  (`{@user.role}`), special-case `:expert` to a distinct "✓ Verified Expert"
  badge (accent color, e.g. a Codex accent), keeping the plain label for other
  roles. Small, self-contained change.
- **Notification types**: add `:expert_application_approved` and
  `:expert_application_rejected` to the `Notification.type` `one_of`
  (`lib/verscienta/notifications/notification.ex`). `subject_type :user` already
  exists. Add render branches in the notification center component so the two new
  types display sensible copy + link to `/experts/apply` (status) or the
  profile.

### 6. Gating + feature flag

- `:expert_program` is already in `Flags.@known_flags` and seeded OFF
  (`@phase3_off`). It gates the applicant apply form (Section 4). The review
  queue is reachable by mods regardless (it's simply empty until applications
  exist), but the nav entry to it may also be flag-gated for tidiness.
- No new flag needed.

## Testing

- **Apply:** a `:user` applies → a `:pending` application with the statement +
  URLs and `user_id` = actor. Applying again while pending → error. Applying when
  already `:expert` → error. Empty `credential_urls` or a non-`http(s)` URL →
  validation error.
- **Approve:** `Experts.approve(app, mod)` → application `:approved` with
  reviewer/reviewed_at; the applicant's `role` becomes `:expert`; an
  `:expert_application_approved` Notification exists for the applicant. A
  non-mod calling `approve` → `{:error, :unauthorized}` and no role change.
- **`:grant_expert` guard:** promoting a `:user` → `:expert`; calling it on a
  `:moderator`/`:admin` → unchanged (no demotion); on an `:expert` → unchanged.
- **Reject:** `Experts.reject(app, mod, "note")` → `:rejected` with the note;
  an `:expert_application_rejected` Notification; role unchanged.
- **Queue:** `Experts.pending/0` returns pending applications loaded with `:user`;
  resolved (approved/rejected) ones excluded.
- **LiveView:** a mod sees the queue and can approve a listed application (role
  promoted); a non-mod gets `NotFound` at `/admin/experts`. The apply page shows
  the right state per role/application status and gates on the flag.
- **Profile:** an `:expert` user's profile renders the "Verified Expert" badge; a
  `:user`'s does not.

## Out of scope (Slice 2 / later)

- Expert label on article + comment bylines.
- `featured_until` on Article + a mod `:set_featured` action + feed sorting.
- Experts' articles skipping the AI moderation hold.
- Expert revocation/demotion UI; application cooldowns; email notifications;
  credential document uploads.

## Files touched (summary)

- New: `lib/verscienta/experts.ex` (domain), `lib/verscienta/experts/expert_application.ex`,
  optional `lib/verscienta/experts/expert_application/changes/validate_apply.ex`.
- Modify: `lib/verscienta/accounts/user.ex` (`:grant_expert` action + policy).
- New: `lib/verscienta_web/live/admin_experts_live.ex`, `lib/verscienta_web/live/expert_apply_live.ex`.
- Modify: `lib/verscienta_web/router.ex` (two routes + nav), `lib/verscienta_web/live/profile_live.ex` (badge),
  `lib/verscienta/notifications/notification.ex` (types) + the notification-center component.
- Modify: `config/config.exs` (add `Verscienta.Experts` to `ash_domains`).
- New migration: `expert_applications` table.
- Tests across the above.
