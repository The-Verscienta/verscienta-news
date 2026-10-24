# Live Rooms — Moderation Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-05
**Status:** Approved
**Phase:** 3 — Intelligence & Growth · Live Rooms & Real-time (slice 3 of 3 + deferred A/V)
**Depends on:** slices 1–2 (`Communities.Room`/`Message`, `RoomLive`, PubSub `"room:<id>"`, Presence), `Communities.can_moderate?/2` (owner/mod), the `Comment.:soft_delete` pattern.
**New dependency:** none. Adds one resource (`RoomBan`) + a `Message.deleted_at` column.

## Goal

Give room moderators (group owner/mod) the controls to keep a live room healthy: remove a message, lock/unlock the room (read-only), and ban a disruptive participant from the chat. All actions are gated by `Communities.can_moderate?/2` and re-checked server-side; effects propagate live via PubSub.

## Decomposition context

Live Rooms slices: 1 (core + messaging) and 2 (ephemeral signals) shipped. **3 (this — moderation)** completes the v1 subsystem (A/V remains explicitly deferred).

## Decisions

| Decision | Choice |
|----------|--------|
| Remove message | **soft-delete** (`deleted_at`, mirrors `Comment`) + live `stream_delete` (vanish; "[removed]" placeholder deferred) |
| Lock room | toggle `Room.status` `:open`↔`:closed`; **closed = read-only for everyone**; mods unlock |
| Ban | **room-level** `RoomBan` resource; force-disconnect via PubSub; banned stays a group member |
| Ban targets | a mod may ban a plain **member** only — **not the owner, not other mods, not self** |
| Authorization | every mod action guarded by `can_moderate?/2` at the context layer + re-checked; mod-only UI |

## Section 1: Remove message (soft-delete)

In `lib/verscienta/communities/message.ex`:
- attribute `deleted_at, :utc_datetime_usec` (nullable, public).
- action `:soft_delete` (update) — `change set_attribute(:deleted_at, &DateTime.utc_now/0)`, accepts nothing else (mirror `Comment.:soft_delete`).
- migration adds `deleted_at`.

In `lib/verscienta/communities.ex`:
- `recent_messages/2` adds `is_nil(deleted_at)` to the filter (removed messages don't load).
- `remove_message(message, mod)` — load the message's room+group if needed; if `can_moderate?(mod, group)`: run `:soft_delete`, return `{:ok, message}`; else `{:error, :unauthorized}`. (The message struct may need its room→group; load it, or pass the group.)

`RoomLive` broadcasts `{:message_removed, message_id}` after a successful remove; `handle_info` does `stream_delete` so the message vanishes for everyone.

## Section 2: Lock / unlock room

In `lib/verscienta/communities/room.ex`:
- action `:set_status` (update) — `accept [:status]`.

In `lib/verscienta/communities.ex`:
- `lock_room(room, mod, status)` (`status` in `[:open, :closed]`) — guard `can_moderate?(mod, group_of(room))`; run `:set_status`; `{:ok, room}` | `{:error, :unauthorized}`.
- `post_message/3` additionally rejects when the room is closed: `{:error, :room_closed}` (check `room.status`). (The `RoomLive` keeps `room.status` fresh via the `{:room_status, …}` broadcast.)

`RoomLive` broadcasts `{:room_status, status}` on toggle; `handle_info` updates `socket.assigns.room` and the render hides the composer + shows a "room is locked" notice when `:closed`. The mod sees a lock/unlock toggle either way.

## Section 3: Room-level ban

New `lib/verscienta/communities/room_ban.ex`:
- attributes: `uuid_primary_key`, timestamps.
- relationships: `belongs_to :room, Room` (`allow_nil?: false`), `belongs_to :user, User` (the banned user, `allow_nil?: false`), `belongs_to :banned_by, User`.
- identity: unique `[:room_id, :user_id]`.
- actions: `create :ban` (`accept [:room_id, :user_id]`, `relate_actor(:banned_by)`); `destroy :unban`; `read`.
- registered in the `Communities` domain.
- migration adds `room_bans`.

In `lib/verscienta/communities.ex`:
- `ban_user(room, mod, target)` — guard: `can_moderate?(mod, group)` AND `target.id != mod.id` AND `not can_moderate?(target, group)` (can't ban owner/mods/self). Then `:ban` (idempotent upsert on the unique identity, or create-if-absent). `{:ok, ban}` | `{:error, reason}`.
- `unban(room, mod, target)` — guarded; destroy the ban.
- `banned?(room, user)` — boolean (a `RoomBan` exists for `(room.id, user.id)`).
- Wire `banned?` into the room gate: `RoomLive.mount` redirects a banned user to the group (flash); `post_message/3` rejects a banned user.

Force-disconnect: `RoomLive` broadcasts `{:banned, target_user_id}` after a successful ban; `handle_info({:banned, id})` → if `id == current_user.id`, `push_navigate` to the group (the banned user's session leaves the room → Presence drops them); else (it's a mod/other) just refresh the presence/participant list.

## Section 4: `RoomLive` moderation UI + live

In `lib/verscienta_web/live/room_live.ex`:
- mount: assign `can_moderate: Communities.can_moderate?(user, group)`; add the `banned?` redirect to the existing member/non-member cond.
- Render (mod-only, gated by `@can_moderate`):
  - a **remove** link on each message (`phx-click="remove_message" phx-value-id={m.id}`);
  - a **lock/unlock** toggle in the header reflecting `@room.status`;
  - a **ban** button next to each present non-mod participant (the presence list gains per-user controls for mods — show the username + a ban affordance).
  - When `@room.status == :closed`: hide the composer for non-mods + show a "this room is locked" notice (mods still see the unlock toggle; per the read-only-for-all decision, the composer is hidden for everyone — mods unlock to post).
- Events (each re-checks authorization via the guarded context helper, which returns `{:error, …}` for non-mods → no-op):
  - `handle_event("remove_message", %{"id" => id}, …)` → `Communities.remove_message(...)` → broadcast `{:message_removed, id}`.
  - `handle_event("toggle_lock", _, …)` → flip status via `lock_room` → broadcast `{:room_status, new_status}`.
  - `handle_event("ban", %{"user_id" => uid}, …)` → `Communities.ban_user(room, mod, target)` → broadcast `{:banned, uid}`.
- Handlers: `{:message_removed, id}` → `stream_delete`; `{:room_status, s}` → update `room` assign; `{:banned, id}` → redirect-if-me else refresh.

The presence list now needs the user **ids** (to ban), not just usernames — extend the Presence meta to carry `id` (already tracked as the Presence key + meta `username`; expose the id for the ban button). Non-mods see only usernames.

## Section 5: Testing

- **`remove_message`**: a mod soft-deletes a message (a non-mod → `{:error, :unauthorized}`, message intact); `recent_messages` excludes deleted; the `{:message_removed}` broadcast `stream_delete`s on a second client.
- **`lock_room`**: a mod closes the room → `post_message` returns `{:error, :room_closed}` for a member; a non-mod can't lock; unlock restores posting; the `{:room_status}` broadcast updates the other client (composer hidden when closed).
- **`RoomBan`**: a mod bans a member → `banned?` true, the banned user can't `mount` (redirected) and can't `post_message`; banning the owner/another mod/self is rejected; the `{:banned}` broadcast redirects the banned user's live session; `unban` restores access.
- **Mod-only UI**: a non-mod member's render does NOT contain the remove/lock/ban controls; a mod's does.
- Full suite + `credo --strict` + `dialyzer` + format green.

## Out of scope (deferred)

"[removed]" placeholder text (vs vanish); ban expiry/temporary bans; a moderation audit log / mod dashboard; message reporting/flagging (the separate Moderation & Trust subsystem); message editing; per-message reactions; A/V.

## Definition of Done

- `Message.deleted_at` + `:soft_delete`; `recent_messages` filters deleted; `remove_message/2` (guarded) + migration.
- `Room.:set_status`; `lock_room/3` (guarded); `post_message/3` rejects closed rooms.
- `Communities.RoomBan` resource (+ migration) + `ban_user/3`/`unban/3`/`banned?/2` (guarded; can't ban owner/mod/self); room mount + `post_message` reject banned users.
- `RoomLive`: mod-only remove/lock/ban UI; live `{:message_removed}`/`{:room_status}`/`{:banned}` handlers (force-disconnect on ban); non-mods see no controls; all actions re-checked via `can_moderate?`.
- Tests across remove/lock/ban (authz, live propagation, banned-user gating, mod-only UI); full suite + credo + dialyzer green.
- `docs/todo.md` "Room lifecycle (create/join/leave, moderation controls)" + "Moderation queue / Auto-actions" room-relevant items reflected (room moderation done; the broader Moderation & Trust subsystem is separate). No new dependency.
