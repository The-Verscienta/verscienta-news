# Live Rooms — Ephemeral Signals (Typing + Reactions + Presence) Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-05
**Status:** Approved
**Phase:** 3 — Intelligence & Growth · Live Rooms & Real-time (slice 2 of 3 + deferred A/V)
**Depends on:** slice 1 (`RoomLive`, `Communities.Room`/`Message`, `Verscienta.PubSub` topic `"room:<id>"`, `VerscientaWeb.Presence`).
**New dependency:** none. **No new resources / no migration.**

## Goal

Add ephemeral real-time signals to the live room: a "who's typing" indicator, lightweight floating room reactions, and a presence count. All three are transient PubSub-only signals layered on slice 1's room topic and Presence — no persistence. They make the room feel alive without adding to the data model.

## Decomposition context

Live Rooms slices: 1 (core + messaging — shipped), **2 (this — ephemeral signals)**, 3 (moderation), deferred A/V. This slice touches only `RoomLive` and its test.

## Decisions

| Decision | Choice |
|----------|--------|
| Typing | debounced `phx-keyup` → `broadcast {:typing, who}`; per-user 3 s auto-clear; exclude self; clear on send |
| Reactions | **ephemeral** — fixed emoji bar → `broadcast {:reaction, …}` → transient list → ~2.5 s clear (CSS rise+fade) |
| Presence | add a **count** to the existing "here now" line |
| Persistence | **none** — no resources, no migration |
| TTLs | `@typing_ttl_ms` / `@reaction_ttl_ms` module attributes (so tests drive the clear handlers directly) |
| Gating/access | unchanged from slice 1 (member-gated, `:live_rooms` flag) |

## Section 1: Typing indicators

In `RoomLive`:
- Composer input gains `phx-keyup="typing"` with `phx-debounce="400"`.
- `handle_event("typing", _params, socket)` → `Phoenix.PubSub.broadcast(Verscienta.PubSub, topic, {:typing, %{id: user.id, username: user.username}})`; `{:noreply, socket}`.
- `handle_info({:typing, %{id: id, username: name}}, socket)`:
  - ignore if `id == current_user.id` (don't show yourself typing);
  - add `name` to the `typing` map keyed by `name` (or `id`), and `Process.send_after(self(), {:clear_typing, name}, @typing_ttl_ms)` after cancelling any prior timer for that name (store the timer ref so it can be cancelled);
  - `{:noreply, assign(socket, typing: …)}`.
- `handle_info({:clear_typing, name}, socket)` → remove `name`; `{:noreply, …}`.
- On a successful send, also `broadcast {:stop_typing, current_user.username}`; `handle_info({:stop_typing, name})` removes `name` immediately (so the indicator clears when they send).
- Render: a line below the message stream — `"#{Enum.join(names, ", ")} #{is/are} typing…"` — only when the (self-excluded) typing set is non-empty.

Initial `typing` assign is an empty map; `present`/messages unchanged.

## Section 2: Ephemeral room reactions

In `RoomLive`:
- A fixed emoji bar near the composer: `["👏", "❤️", "😂", "🔥"]`, each a `<button phx-click="react" phx-value-emoji={e}>`.
- `handle_event("react", %{"emoji" => emoji}, socket)`: validate `emoji` is in the allowed set; `broadcast {:reaction, %{id: unique_id, emoji: emoji}}`; `{:noreply, socket}`.
- `handle_info({:reaction, %{id: id, emoji: emoji}}, socket)`: append `%{id: id, emoji: emoji}` to the `reactions` list assign; `Process.send_after(self(), {:clear_reaction, id}, @reaction_ttl_ms)`; `{:noreply, …}`.
- `handle_info({:clear_reaction, id}, socket)`: drop the entry with that id; `{:noreply, …}`.
- Render: a fixed/floating layer rendering each active reaction emoji with a CSS rise+fade animation (reuse the design system's motion utilities — `rise`/`fade`/stagger; e.g. an absolutely-positioned container). The unique `id` keys each element so a new identical emoji animates independently.

`unique_id` = `System.unique_integer([:positive])` (or `Ash.UUID`) — distinct per reaction so duplicates don't collide in the DOM/timer.

## Section 3: Presence count

Update slice 1's presence line from `"here now: names"` to include the count, e.g. `"#{length(@present)} here: #{Enum.join(@present, ", ")}"` (or "1 here" / "no one else"). Purely a render change.

## Section 4: Testing

- **Typing**: with two connected members in the same room, the typing member fires the `"typing"` event (via `render_keyup`/`render_hook` or by directly broadcasting); the OTHER member's render shows the username + "typing…". Sending a message clears it (the `{:stop_typing, …}` path). The `{:clear_typing, name}` handler removes the name (send the message directly to the LV — `send(lv.pid, {:clear_typing, name})` then `render/1` — to avoid sleeping on the TTL).
- **Reactions**: a member clicks an emoji (`render_click` on the emoji button) → the other member's render shows the emoji; the `{:clear_reaction, id}` handler removes it (send directly). Validate an out-of-set emoji is ignored.
- **Presence count**: the render includes the count.
- A member does NOT see their own typing indicator.
- Full suite + `credo --strict` + `dialyzer` + format green.

(Testing approach: prefer asserting the immediate broadcast render + driving the clear handlers via direct `send/2` to the LiveView pid, rather than `Process.sleep` on the TTL — deterministic.)

## Out of scope (deferred)

Persisted / per-message reactions (the heavier "Slack-style" alternative — a possible future slice); @mentions, read receipts, unread badges; client-side JS-hook animations (server-side transient is v1); moderation — remove/kick/lock (slice 3); A/V.

## Definition of Done

- Typing indicators in `RoomLive` (debounced broadcast, per-user 3 s auto-clear, self-excluded, cleared on send).
- Ephemeral room reactions (fixed emoji bar, transient broadcast → list → ~2.5 s CSS-animated clear, validated emoji).
- Presence count in the "here now" line.
- Configurable TTL module attributes; no persistence / no migration.
- Tests across typing (appears on the OTHER client, self-excluded, clears on send + via clear handler), reactions (appears, clears, invalid ignored), presence count; full suite + credo + dialyzer green.
- `docs/todo.md` "Live reactions / typing indicators / online presence" → checked off (all three now done). No new dependency.
