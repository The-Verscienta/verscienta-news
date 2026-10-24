# Moderation & Trust — Slice 1 Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-08
**Phase:** 3 — Intelligence & Growth → Moderation & Trust
**Scope:** Slice 1 of 4. Community reporting + human moderation loop.

## Context

The "Moderation & Trust" section of `docs/todo.md` is five semi-independent
subsystems. It is decomposed into slices, each with its own spec → plan → build
cycle:

- **Slice 1 (this doc):** `ModerationFlag` resource + community reporting UI +
  human moderator queue/dashboard. The complete report-and-act loop.
- Slice 2: Auto-actions (hold/shadow/escalate) + full audit log.
- Slice 3: Llama-based toxicity + dubious-claim auto-flagging on submit.
- Slice 4: AI writing assistant for authors (author-facing, not moderation).

### What already exists (reused, not rebuilt)

- **Roles:** `User.role` ∈ `:user | :expert | :moderator | :admin`.
  `Comment.soft_delete` already authorizes `role in [:moderator, :admin]`.
- **Remove/archive actions on every reportable target:**
  - `Comment.soft_delete` (tombstone via `deleted_at`).
  - `Article.archive` (`status: :archived`, has its own policy).
  - `Communities.Message.soft_delete` (room messages are persisted in
    `room_messages`, with `deleted_at`).
  - `User` — has a `deactivated_at` precedent (account-deletion grace);
    suspension mirrors that pattern with a new `suspended_until`.
- **AI client** (`Verscienta.AI.Client.generate/2`) — reserved for slices 3.
- **Feature flags:** `auto_moderation`, `expert_program`, `writing_assistant`
  already declared in `Verscienta.Flags`. Reserved for the AI slices; human
  reporting in slice 1 ships **unflagged** (core safety).
- **Admin gating:** `admin_required` plug in the router is **admin-only** today.
- **Rate limiting:** Hammer/ETS action-layer infra exists (auth endpoints).

## Goals

Authenticated users can report a comment, article, user profile, or room
message. Reports land in a moderator queue. Moderators (and admins) review the
queue and resolve each item by dismissing it, removing the content, warning the
user, or suspending the user — every action recorded durably.

## Non-goals (deferred to later slices / follow-ups)

- AI auto-flagging on submit (slice 3).
- Auto-actions: hold / shadow / escalate (slice 2).
- Full audit log surface/UI (slice 2 — slice 1 lays the `Moderation.Action`
  record that seeds it).
- Notifying reporters when their report is resolved.
- Suspension enforcement on *every* create action (slice 1 enforces on the two
  highest-volume vectors only — see below).
- Appeals flow.
- **Rate-limiting on `report`** — deferred to a fast-follow. The unique key
  `(subject_type, subject_id, reporter_id)` already makes duplicate reports of
  the *same* subject idempotent; the remaining vector is a user spamming reports
  across many *distinct* subjects, which a Hammer per-user limiter (reusing the
  auth rate-limit infra) should cover. Not shipped in slice 1.
- Hiding the report affordance on subjects the actor has *already* reported
  across sessions (the upsert makes a re-report harmless; the component only
  hides post-submit within a session).

## Architecture

### Target modeling — single polymorphic flag

One `Moderation.Flag` table references any of the four target types via
`subject_type` (atom enum) + `subject_id` (uuid). One resource, one queue, one
reporting path.

Rejected alternatives: per-type flag tables (quadruples resources/UI, no unified
queue); Ash polymorphic relationships (more machinery than needed).

Cost: no DB-level foreign key on the polymorphic column. Mitigated by
**snapshotting** `subject_excerpt` and `subject_author_id` onto the flag at
report time, so the queue renders fast and stays meaningful even if the content
is later edited or deleted. The live record is resolved by `{type, id}` only
when a moderator acts on it.

### New domain: `Verscienta.Moderation`

Two resources: `Flag` and `Action`.

#### `Moderation.Flag`

Attributes:

| field | type | notes |
|---|---|---|
| `id` | uuid | pk |
| `subject_type` | atom | `:comment \| :article \| :user \| :room_message` |
| `subject_id` | uuid | the reported record's id |
| `subject_excerpt` | string | snapshot text for the queue (e.g. first ~200 chars / title / bio) |
| `subject_author_id` | uuid | nullable — the offending user, captured at report time |
| `reason` | atom | `:spam \| :harassment \| :misinformation \| :off_topic \| :other` |
| `note` | string | optional reporter free-text |
| `status` | atom | `:pending \| :resolved`, default `:pending` |
| `resolution` | atom | nullable: `:dismissed \| :content_removed \| :user_warned \| :user_suspended` |
| `reporter_id` | uuid | belongs_to User |
| `resolved_by_id` | uuid | nullable belongs_to User |
| `resolved_at` | utc_datetime_usec | nullable |
| timestamps | | `inserted_at` / `updated_at` |

**Unique index** on `(subject_type, subject_id, reporter_id)` — a user cannot
flag the same subject twice.

Actions:

- `report` (create) — actor required. Accepts `subject_type, subject_id,
  reason, note`. A change resolves the live subject and captures
  `subject_excerpt` + `subject_author_id`. Rejects reporting your own content.
  Upsert on the unique key (re-report is a no-op / idempotent). Rate-limiting
  deferred to a fast-follow (see Non-goals).
- `queue` (read) — `status == :pending`, sorted by `inserted_at` (grouping by
  subject is done in the LiveView so we get report counts).
- `resolve` (update) — sets `status: :resolved`, `resolution`, `resolved_by_id`,
  `resolved_at`. Performs the chosen content action and writes a
  `Moderation.Action`. **Resolving acts on all pending flags for the same
  `(subject_type, subject_id)` at once** (the moderator decides per subject, not
  per individual report).

Policies:

- `report` → `actor_present()`.
- `queue` / `resolve` → `expr(^actor(:role) in [:moderator, :admin])`.

#### `Moderation.Action` (audit seed)

A durable record written every time a moderator acts. The only durable home for
"warn user," and the seed for slice 2's full audit log. Mirrors the existing
`Flags.Audit` resource shape.

| field | type | notes |
|---|---|---|
| `id` | uuid | pk |
| `moderator_id` | uuid | belongs_to User |
| `action` | atom | `:dismiss \| :remove_content \| :warn_user \| :suspend_user` |
| `subject_type` | atom | same enum as Flag |
| `subject_id` | uuid | |
| `target_user_id` | uuid | nullable — the affected user (author/offender) |
| `note` | string | nullable — moderator note / context |
| `occurred_at` | utc_datetime_usec | |

Read-only after creation. Indexed on `(target_user_id, occurred_at)` and
`(subject_type, subject_id)`.

### User suspension (minimal)

- New `User.suspended_until` attribute (`utc_datetime_usec`, nullable,
  `writable? false`), mirroring the `deactivated_at` precedent.
- System actions `:suspend` (accepts `suspended_until`) and `:unsuspend` (clears
  it), invokable only by `role in [:moderator, :admin]`.
- **Enforcement (slice 1):** a policy/validation on **`Comment.create` and
  `Communities.Message.post`** denying when `suspended_until` is in the future.
  These are the highest-volume abuse vectors. A suspended user sees a banner /
  flash explaining the block.
- Article-publish and other create actions are trivial follow-ons; explicitly
  **not** wired in slice 1 to keep the change focused.
- **Warn** writes only a `Moderation.Action` (no attribute change on User).

## Reporting UI

A reusable **`ReportDialog` live_component**, parameterized by `{subject_type,
subject_id}`:

- A "Report" affordance (e.g. ⚐ icon/button) rendered on:
  - the comment component,
  - the article reader,
  - the room message,
  - the public profile page.
- Clicking opens a modal: reason radios + optional note → submits the `report`
  action → inline "Reported, thanks" confirmation.
- Hidden on the actor's own content, and on subjects the actor has already
  reported.
- Built from existing Codex components; no one-off styles.

## Moderator queue / dashboard

- New **`AdminModerationLive`** at `/admin/moderation`.
- Behind a **new `mod_required` plug** allowing `role in [:moderator, :admin]`
  (today's `admin_required` is admin-only). A matching `live_session` / on_mount
  for the LiveView path.
- Queue view: pending flags **grouped by `(subject_type, subject_id)`**, each row
  showing the snapshot excerpt, report count, distinct reasons, and first-reported
  time. Sorted by report count then recency. Filters: subject_type and status.
- Detail panel per grouped subject: snapshot text + deep-link to the live
  content + action buttons — **Dismiss / Remove content / Warn user / Suspend
  user**. Each resolves all pending flags for that subject and writes a
  `Moderation.Action`.
- A small nav entry surfaced for moderators/admins.

## Error handling

- Report on already-deleted/missing subject: the snapshot still lets the queue
  render; resolve's content action is a best-effort no-op if the live record is
  already gone (don't crash the resolve).
- Duplicate report by same user: idempotent (unique key); UI hides the affordance
  pre-emptively.
- Rate-limit exceeded: friendly flash, no flag written.
- Resolve race (two mods resolve same subject): second resolve sees no pending
  flags and is a harmless no-op.

## Testing

Ash action tests:

- `report` captures snapshot + author; dedup unique key; self-report rejected;
  rate-limit engaged; `actor_present` enforced.
- `resolve` sets resolution fields, performs the right content action per
  subject_type, writes a `Moderation.Action`, and resolves *all* pending flags
  for the subject; policy denies non-moderators.
- `suspend` blocks `Comment.create` and `Message.post`; `unsuspend` restores.

LiveView tests:

- `ReportDialog` submits and shows confirmation; hidden on own content / already
  reported.
- `AdminModerationLive` renders grouped queue, applies filters, and each resolve
  button drives the correct outcome; `mod_required` blocks plain users.

## Rollout

Human reporting + queue ship **unflagged**. No data migration beyond the two new
tables (`moderation_flags`, `moderation_actions`) and the `users.suspended_until`
column. Seeds: optionally add a couple of demo flags for dev.
