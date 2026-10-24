# Live Rooms — Core + Live Messaging Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-05
**Status:** Approved
**Phase:** 3 — Intelligence & Growth · Live Rooms & Real-time (slice 1 of 3 + deferred A/V)
**Depends on:** `Verscienta.Communities` (Group + GroupMembership + owner/visibility), `Phoenix.PubSub` (existing), LiveView streams, FunWithFlags + the communities `Gate` plug. Adds `Phoenix.Presence` (new).
**New dependency:** none (`phoenix_pubsub`/`phoenix_live_view` already present; `Phoenix.Presence` ships with Phoenix).

## Goal

Give each Community Group a real-time live chat room: members open the room, see who's present, and exchange messages that appear live for everyone, with persisted history. Built LiveView + PubSub + Presence (the app's idiomatic real-time stack — no raw Channels). Gated behind a new `:live_rooms` flag and the existing communities gating.

## Decomposition context

Live Rooms & Real-time decomposes into: **1 (this — rooms core + live messaging)**, 2 (typing indicators + live reactions + presence UI), 3 (moderation: remove/kick/lock), and a deferred optional A/V (LiveKit/WebRTC). Rooms are **group-attached**, reusing the Communities access model.

## Decisions

| Decision | Choice |
|----------|--------|
| Anchor | **Group-attached** — one `Room` per `Group` (unique `group_id`) |
| Room creation | **Find-or-create** on first authorized access (no explicit create step) |
| Messages | **Persisted**, load recent N (default 50) on mount; ascending in the stream |
| Access | group **members** read + post; non-members redirected to the group to join |
| Real-time | **PubSub** topic `"room:<id>"` for new messages; **Phoenix.Presence** for who's here; LiveView **streams** for the message list |
| Gating | new `:live_rooms` flag + the room route under the communities `Gate` |
| Route | `GET /groups/:slug/room` → `RoomLive` |

## Section 1: Resources (`Verscienta.Communities`)

**`Room`** (`lib/verscienta/communities/room.ex`):
- attributes: `topic :string` (nullable; falls back to the group name in the UI), `status :atom` (constraints `one_of: [:open, :closed]`, default `:open`), timestamps.
- relationships: `belongs_to :group, Group` (`allow_nil?: false`); `has_many :messages, Message`.
- a unique identity on `group_id` (one room per group).
- actions: a `:find_or_create_for_group` (upsert on `group_id` → returns the group's room); `read`. Policy: authorized for group members (see Section 2).

**`Message`** (`lib/verscienta/communities/message.ex`):
- attributes: `body :string` (`allow_nil?: false`, max length ~2000), `inserted_at` timestamp.
- relationships: `belongs_to :room, Room` (`allow_nil?: false`); `belongs_to :user, User` (`allow_nil?: false`).
- actions: `:post` create (accepts `body`; `relate_actor(:user)`; sets `room_id`); `:recent` read (last N for a room, oldest→newest). Policy: create authorized only for members of the room's group; read for members.

A small context surface on `Verscienta.Communities`: `room_for_group(group)` (find-or-create), `post_message(room, user, body)`, `recent_messages(room, limit \\ 50)`, and a `member?(user, group)` reuse of the existing membership check.

## Section 2: Access + gating

- Add `:live_rooms` to `Verscienta.Flags` (the `@flags` list) + seed it.
- Route `live "/groups/:slug/room", RoomLive, :show` inside a scope that pipes through the communities `Gate` AND the `:live_rooms` flag (mirror the existing `Plugs.Gate, flag: :communities` usage; add a `Plugs.Gate, flag: :live_rooms` or combine). Confirm the exact gating composition against the existing gated group routes.
- Membership policy: a user may read/post in a room only if they are a member of the room's group (reuse `GroupMembership` / the existing `Communities.member?`-style check). The group owner is a member. Non-members hitting the room are redirected to `/groups/:slug` with a flash to join.

## Section 3: `RoomLive` at `/groups/:slug/room`

`lib/verscienta_web/live/room_live.ex` (in the communities-gated, authenticated live_session):
- **mount**: load the group by slug; if the current user is not a member → `push_navigate` to `/groups/:slug` (+ flash). Else: `room = Communities.room_for_group(group)`; `messages = Communities.recent_messages(room)`; `stream(:messages, messages)`; on `connected?(socket)`: `Phoenix.PubSub.subscribe("room:#{room.id}")` and `Presence.track(self(), "room:#{room.id}", current_user.id, %{username: …})`; assign `presence` from `Presence.list`. Set `page_title`, `seo: SEO.build(noindex: true)` (private).
- **render**: a header (group name + topic), a "who's here" list from presence, the message **stream** (each message: author username + body + time), and a composer form (`phx-submit="send"`).
- **`handle_event("send", %{"body" => body}, socket)`**: trim/validate; if non-blank, `Communities.post_message(room, current_user, body)`; broadcast `{:new_message, message}` to `"room:#{room.id}"`; reset the composer. (The sender also receives the broadcast → single append path.)
- **`handle_info({:new_message, message}, socket)`**: `stream_insert(socket, :messages, message)`.
- **`handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket)`** (or the presence handler): recompute the presence list.
- Validate `body` length server-side; ignore blank.

## Section 4: Real-time infrastructure

- **`VerscientaWeb.Presence`** (`use Phoenix.Presence, otp_app: :verscienta, pubsub_server: Verscienta.PubSub`) added to the supervision tree in `lib/verscienta/application.ex` (after the PubSub child). Confirm the PubSub server name used app-wide.
- PubSub topic `"room:#{room_id}"`; broadcast `{:new_message, message}` (the message loaded with `:user` for rendering).
- LiveView streams keep the DOM bounded; messages render oldest→newest.

## Section 5: Testing

- **Resources/context**: `room_for_group/1` is idempotent (same room on repeat); `post_message/3` persists a message related to the room + user; a non-member's post is policy-forbidden; `recent_messages/2` returns oldest→newest, capped.
- **`RoomLive`** (ConnCase, gated flag enabled in test): a member sees the composer + existing history; sending a message renders it; a **second** connected member's LiveView receives the new message (PubSub broadcast → `stream_insert`); a non-member is redirected to `/groups/:slug`.
- **Presence**: a connected member appears in the room's presence list (`Presence.list("room:<id>")` includes the user).
- Flag-gating: with `:live_rooms` off, the route is gated (coming-soon/redirect per the `Gate` behavior).
- Full suite + `credo --strict` + `dialyzer` + format green.

## Out of scope (later slices / deferred)

Typing indicators + live reactions + richer presence UI (slice 2); moderation — remove message, kick/ban, lock/close (slice 3); audio/video (LiveKit/WebRTC, deferred); multiple rooms per group; message edit/delete; threading/replies; attachments/images; @mentions + notifications; unread badges/read receipts; message pagination/infinite-scroll history (load recent N only in v1).

## Definition of Done

- `Communities.Room` + `Communities.Message` resources (find-or-create room, member-authorized post, recent read) + migration(s).
- `Communities` context helpers (`room_for_group/1`, `post_message/3`, `recent_messages/2`).
- `VerscientaWeb.Presence` in the supervision tree; PubSub `"room:<id>"` broadcasts.
- `RoomLive` at `/groups/:slug/room`: member-gated, find-or-create room, streamed history, live new messages, presence "who's here", composer; non-members redirected.
- `:live_rooms` flag + route gating.
- Tests across resources/authz / RoomLive (history, send, cross-session broadcast, non-member redirect) / presence; full suite + credo + dialyzer green.
- `docs/todo.md` "Live discussion rooms via Phoenix Channels + Presence" + "Live reactions / typing / online presence" reflected (the presence half done; reactions/typing in slice 2). No new dependency.
