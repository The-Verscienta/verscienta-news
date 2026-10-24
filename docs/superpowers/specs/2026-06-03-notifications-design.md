# Notifications Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-03
**Status:** Approved
**Phase:** 2 (Social & Gamification) — Subsystem 3 of 7: Notifications
**Depends on:** Social Graph + Activity Feeds (merged). Reuses Accounts (`User`), Content
(`Article`), Engagement (`Comment`, `Reaction`), `Social.Follow`, `Social.Mentions`, and the
established emit-from-hooks + per-user PubSub patterns.

## Goal

A recipient-centric, in-app **notifications** system: when someone acts on you (follows you, reacts
to or comments on your article, replies to your comment, or @mentions you), create a private
`Notification` in your inbox with read state. Surface them in a `/notifications` center and a live
nav bell, governed by per-type preferences, delivered in real time via PubSub. In-app only.

This neighbors Activity Feeds (public actor-centric stream) but is a distinct concern: notifications
are private, per-recipient, with read state + preferences. They are emitted from the same action
hooks but written to the affected user.

## Decisions

| Decision | Choice |
|----------|--------|
| Data model | Standalone `Notification` resource in a new `Verscienta.Notifications` domain |
| Preferences | A `notification_prefs` map attribute on `User` (default all-on), toggled in `/settings` |
| Triggers | `:followed`, `:reacted`, `:commented`, `:replied`, `:mentioned` |
| Emission | Best-effort from existing hooks; **skip self**; **honor preferences**; **dedup per comment** |
| Mutability | Append-only inbox + read state (`read_at`). Un-toggling an action does NOT remove a notification. |
| Privacy | Recipient-only policies — a user can only read/mark their own notifications |
| Real-time | `notifications:<user_id>` PubSub topic; `/notifications` center + a nested live nav bell |
| Delivery | In-app only |
| Deferred | Email/push/web-push; digest batching; grouping/aggregation; badge-earned notifications; Presence |

## Data model

### `Verscienta.Notifications.Notification`
- **Attributes:**
  - `recipient_id` (uuid) — `belongs_to :recipient, Verscienta.Accounts.User`, `allow_nil?: false`
  - `actor_id` (uuid) — `belongs_to :actor, Verscienta.Accounts.User`, `allow_nil?: false`
  - `type` (atom, `allow_nil?: false`, one_of `[:followed, :reacted, :commented, :replied, :mentioned]`)
  - `subject_type` (atom, one_of `[:user, :article, :comment]`, `allow_nil?: false`)
  - `subject_id` (string, `allow_nil?: false`)
  - `metadata` (map, default `%{}`, public) — snapshot for rendering + linking, e.g.
    `%{"actor_username" => ..., "article_title" => ..., "article_slug" => ..., "comment_excerpt" => ...}`
  - `read_at` (utc_datetime_usec, nullable)
  - `create_timestamp :inserted_at`
- **Actions:**
  - `create :create` — system action (accepts all fields); invoked only via `Notifications.notify/1`
    with `authorize?: false`.
  - `update :mark_read` — sets `read_at` to now (`accept []`, `require_atomic? false`, change forces
    `read_at`); recipient-only.
  - reads: default `:read`; `:for_recipient` (arg `recipient_id`, filter + sort `inserted_at: :desc`).
  - `mark_all_read` is a **context helper** (`Notifications.mark_all_read(user)`) doing a bulk update of
    the recipient's unread rows (`authorize?: false`, scoped to recipient_id).
- **Policies (authorizer enabled):**
  - `action_type(:read)` → `authorize_if expr(recipient_id == ^actor(:id))` (private inbox).
  - `action(:mark_read)` → `authorize_if expr(recipient_id == ^actor(:id))`.
  - `action(:create)` → `authorize_if always()` (only ever called with `authorize?: false`).
- **Indexes (migration):** `recipient_id`, `[recipient_id, read_at]` (unread counts), `inserted_at`.

### `User.notification_prefs`
Add `attribute :notification_prefs, :map, allow_nil?: false, default: %{}, public?: true` to
`Verscienta.Accounts.User`, plus an `update :update_notification_prefs` action (accepts the map,
owner-policy already covers `update_profile`-style; add a policy `authorize_if expr(id == ^actor(:id))`).
An empty/missing key means **enabled** (opt-out model). Migration adds the column.

## Emission

`Notifications.notify(%{recipient_id, actor_id, type, subject_type, subject_id, metadata})`:
1. If `recipient_id == actor_id` → `:ok` (no self-notify).
2. Load the recipient; if `Notifications.enabled?(recipient, type)` is false → `:ok`.
3. Create the notification (`authorize?: false`).
4. Broadcast `{:notification, id}` on `notifications:<recipient_id>`.
5. Best-effort: wrap in `rescue -> :ok` so it never breaks the calling action.

`Notifications.enabled?(user, type)` → `Map.get(user.notification_prefs, to_string(type), true) != false`.

Hook integration (alongside the existing activity emission; emit on the **create branch** only):

| Source | recipient | type | subject | metadata |
|--------|-----------|------|---------|----------|
| `Social.Follow` `:toggle` (user target, create) | followed user (`id`) | `:followed` | `:user`, actor id | `actor_username` |
| `Engagement.Reaction` `:toggle` (create) | article author | `:reacted` | `:article`, article id | `actor_username`, `article_title/slug`, `kind` |
| `Engagement.Comment` `:create` | article author | `:commented` | `:article`, article id | `actor_username`, `article_title/slug`, `comment_excerpt` |
| `Engagement.Comment` `:create` (when `parent_id`) | parent comment's author | `:replied` | `:comment`, parent id | `actor_username`, `article_title/slug`, `comment_excerpt` |
| `Engagement.Comment` `:create` (each `@mention`) | mentioned existing user | `:mentioned` | `:comment`, comment id | `actor_username`, `article_title/slug`, `comment_excerpt` |

**Comment dedup:** a single comment can match multiple rules (e.g. you reply to the article author
and also @mention them). Compute the set of `(recipient, type)` to send and ensure **one recipient
gets at most one notification per comment** — prefer the most specific type in priority order
`:replied > :mentioned > :commented`, and always skip the actor. (Concretely: build a map keyed by
recipient_id, keep the highest-priority type, then notify.)

**Mentions extraction:** add `Social.Mentions.extract_existing_usernames(body)` (reuse the existing
regex + the existing-username lookup already in `Mentions`) returning the existing `%User{}`s (or
ids) mentioned, for the comment hook to notify.

## Queries & real-time

- `Notifications.list(user, opts)` — `:for_recipient`, newest first, limit (default 50), load `:actor`.
- `Notifications.unread_count(user)` — count where `recipient_id == user.id and is_nil(read_at)`.
- `Notifications.topic(user_id)` = `"notifications:" <> to_string(user_id)`; `subscribe/1`, `broadcast/2`.
- `Notifications.get(id)` — load one with `:actor` (for LiveViews on receipt).

## UI

### Notification center — `/notifications` LiveView (signed-in)
- Route in the authenticated live session. Lists the recipient's notifications via **LiveView streams**.
- Each row: a colored **left bar by type** (Codex accent per type — e.g. zune for mentions, a metro
  accent per other type), the actor `@username`, a type-specific message, relative time, and a link to
  the subject (article/profile/comment-on-article). Unread rows visually distinct (e.g. subtle bg).
- "mark all read" button → `Notifications.mark_all_read(current_user)`.
- Clicking a row marks it read (`:mark_read`) and navigates to the subject.
- Subscribes to `Notifications.topic(current_user.id)`; on `{:notification, id}` loads + prepends
  (`stream_insert at: 0`); dom id `"notification-<id>"`.
- A shared `notification_item/1` component (in `VerscientaWeb.SocialComponents` or a new
  `NotificationComponents`) renders a row from the snapshot; message text via a `type → phrase` helper.

### Nav bell — nested `NotificationBellLive`
- A small LiveView (`VerscientaWeb.NotificationBellLive`) `live_render`-ed in the root layout for
  signed-in users only. Shows a bell glyph + an unread-count badge (hidden when 0), linking to
  `/notifications`.
- Mounts with `unread_count` from `Notifications.unread_count/1`; subscribes to the user's topic; on
  `{:notification, _}` increments; it also handles a `{:notifications_read}` broadcast (sent by
  `mark_read`/`mark_all_read`) to refresh the count to the real unread total.
- `live_render` works in the root layout for both controller-rendered and LiveView pages (mounted from
  the dead render with `@conn`). Render only when there is a current user.

### Settings — preferences
- A "notifications" section in the existing `/settings` LiveView with a checkbox per type, persisted via
  `User.update_notification_prefs` (writes the `notification_prefs` map). Default all-checked.

## Safety

- **Private:** recipient-only read/mark policies; a user cannot read another user's notifications.
- Snapshot strings render escaped (HEEx `{...}`); links from safe slugs/usernames via `~p`.
- Self-notify skipped; preferences honored at emit time; emit best-effort (never breaks the action).
- Append-only inbox: un-toggling a reaction/follow does not delete a notification.

## Testing & gates

- **Emit per trigger:** follow → `:followed` to followed user; reaction → `:reacted` to author;
  comment → `:commented` to author; reply → `:replied` to parent author; mention → `:mentioned` to
  the mentioned user. Each to the correct recipient with correct type/subject/metadata.
- **Self-skip:** acting on your own content notifies nobody.
- **Preferences:** disabling a type in `notification_prefs` suppresses that type; others still fire.
- **Dedup:** a reply that also @mentions the parent author yields exactly ONE notification (highest
  priority type).
- **Read state:** `mark_read` sets `read_at`; `mark_all_read` clears all unread; `unread_count` correct.
- **Authorization:** a user reading `:for_recipient` for another user's id gets nothing / is forbidden;
  `mark_read` on someone else's notification is forbidden.
- **Real-time:** a LiveView on `/notifications` (and the bell) receives a broadcast and updates.
- **Seeds:** add a couple of notifications; existing tests unaffected (new table; emission is additive
  and best-effort — confirm no existing test asserts a count the new rows would break).
- Gates green: `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`,
  `MIX_ENV=test mix test`. Migrations via `mix ash.codegen`.

## Definition of Done

- `Notification` resource in `Verscienta.Notifications` (recipient-only policies); `User.notification_prefs`;
  migrations applied; domain registered.
- All 5 triggers emit best-effort to the right recipient, skipping self, honoring preferences, deduped per comment.
- `/notifications` center: list, colored-by-type, mark-one/mark-all read, real-time prepend.
- Nested live nav bell with unread badge, updating in real time on every page.
- `/settings` per-type preference toggles.
- @mentions in comments now notify the mentioned user.
- All gates green; migrations via `mix ash.codegen`; work committed on `notifications`.
