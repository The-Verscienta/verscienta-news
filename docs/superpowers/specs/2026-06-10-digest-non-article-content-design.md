# Digest Refinements — Slice 1: Non-Article Content

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-10
**Phase:** 3 — Intelligence & Growth › Notifications & Digests
**Todo item:** `Digest refinements (deferred): … non-article digest content (new
followers, comment replies, room activity) …` — this slice delivers the
non-article-content part. (Timezone send-time, admin send-now/preview, and
open/click analytics are separate later slices.)

## Goal

Make the digest a fuller recap by adding an **Activity** section summarizing what
happened to the user since their last digest: new followers, replies/mentions/
comments on their content, reactions, and new messages in their community rooms.
A user with no fresh article highlights but new activity now still receives a
digest.

## Decisions (from brainstorming)

- **Two data paths:** Notifications (followers/replies/mentions/comments/reactions)
  + a Communities query (room activity). Room activity is NOT in the Notifications
  system today, so we query `Communities` directly.
- **Compact detail level:** counts everywhere, plus up to 3 new-follower names and
  per-room message counts. No per-reply snippets/threading.
- **Send-if-either:** the worker sends when *either* article highlights OR activity
  is non-empty (today it skips when highlights are empty).
- **Window:** since the user's last digest — `cutoff = last_digest_at ||
  (now − window_days·86400)`; empty when frequency is `:off`.

## Background (current state)

- `Verscienta.Digests` (`lib/verscienta/digests.ex`): `highlights/1` (≤5 For-You
  articles in the window), `window_days/1` (`:weekly`→7, `:daily`→1, `_`→0),
  `due_user_ids/1`, unsubscribe tokens.
- `Verscienta.Digests.Email` (`lib/verscienta/digests/email.ex`): `build/2` +
  `deliver/2`; `html/2` + `text/2` render the article list + an unsubscribe
  footer. Swoosh.
- `SendDigestWorker` (`lib/verscienta/digests/workers/send_digest_worker.ex`):
  flag-gated; loads the user; skips `:off`; gets `highlights(user)`; **skips if
  empty**; else `Email.deliver/2` + `record_digest_sent`.
- `Notifications.Notification` (`lib/verscienta/notifications/notification.ex`):
  `recipient_id`, `type` (incl. `:followed`, `:replied`, `:mentioned`,
  `:commented`, `:reacted`), `metadata` (map), `create_timestamp :inserted_at`.
  `:followed` notifications carry `metadata["actor_username"]`
  (`lib/verscienta/social/follow.ex:192`).
- `Communities` (`lib/verscienta/communities.ex`): `room_for_group/1`,
  active-membership queries; `Communities.Message` has `room_id`, `user_id`,
  `deleted_at`, `moderation_status` (`:visible` etc.), `inserted_at`. Room URL is
  `~p"/groups/#{group.slug}/room"`.

## Architecture

### 1. `Digests.activity/1` (new)

```elixir
@doc """
Compact summary of non-article activity for `user` since their last digest.
Window: last_digest_at, or `now - window_days·86400` for a first digest; empty
when the user's digest_frequency is :off.
"""
def activity(%User{} = user) :: activity_summary()
```

`activity_summary()` is a map:
```elixir
%{
  followers: %{count: non_neg_integer(), names: [String.t()]},  # names: up to 3
  replies: non_neg_integer(),    # :replied
  mentions: non_neg_integer(),   # :mentioned
  comments: non_neg_integer(),   # :commented (on the user's articles)
  reactions: non_neg_integer(),  # :reacted
  rooms: [%{name: String.t(), slug: String.t(), count: pos_integer()}]
}
```

Implementation:
- `cutoff = activity_cutoff(user)` where
  `activity_cutoff(%{digest_frequency: :off})` is irrelevant (return the empty
  summary before querying), and otherwise
  `user.last_digest_at || DateTime.add(now, -window_days(freq)·86400, :second)`.
- **Notifications:** one read —
  `Notification |> filter(recipient_id == ^user.id and inserted_at >= ^cutoff) |>
  read!(authorize?: false)`. Group by `type`:
  - `followers`: `count` of `:followed`; `names` = up to 3 `metadata["actor_username"]`
    (drop nil/blank).
  - `replies`/`mentions`/`comments`/`reactions`: counts of `:replied`/`:mentioned`/
    `:commented`/`:reacted`.
- **Rooms:** the user's **active** group memberships → their groups (with `name`,
  `slug`) → each group's room (`room_for_group/1`, or load the room) → count of
  new messages since cutoff per room:
  `Message |> filter(room_id in ^room_ids and inserted_at >= ^cutoff and
  user_id != ^user.id and is_nil(deleted_at) and moderation_status == :visible)`,
  grouped/counted per room_id (a single grouped count is preferred; per-room counts
  are acceptable — the user has few groups). Keep only rooms with `count > 0`; map
  each back to `%{name: group.name, slug: group.slug, count: n}`; cap at a small
  number (e.g. 5), highest-count first.
- Return the empty summary (all zeros / empty lists) for an `:off` user without
  querying.

Add a companion predicate:
```elixir
@doc "True when an activity summary has nothing to show."
def activity_empty?(%{followers: %{count: 0}, replies: 0, mentions: 0,
      comments: 0, reactions: 0, rooms: []}), do: true
def activity_empty?(_), do: false
```

> All reads run `authorize?: false` — they're system aggregations scoped by the
> user's own `recipient_id` / membership, consistent with the rest of `Digests`.

### 2. Email rendering (`Digests.Email`)

- `build/2` becomes `build/3` taking `(user, articles, activity)` — OR keep `build/2`
  and add `activity` via a new arg; choose the smaller diff. Recommended: change
  `deliver/2`→`deliver/3` and `build/2`→`build/3` so the worker passes both.
  (Update the existing `deliver(user, articles)` call site in the worker.)
- Add an **Activity** section after the article list in both `html/_` and `text/_`:
  - Header: "Since your last digest" (omit the whole section when
    `activity_empty?` is true).
  - Followers: `:if count > 0` → "N new follower(s)" + the up-to-3 names in parens
    when present.
  - A line each (only when its count > 0): "N repl(y/ies) to your comments",
    "N mention(s)", "N comment(s) on your articles", "N reaction(s)" — each linking
    to `url(~p"/notifications")`.
  - Rooms: for each room, "GroupName — N new message(s)" linking to
    `url(~p"/groups/#{slug}/room")`.
  - HTML escapes all interpolated strings (reuse the existing `esc/1` helper);
    text body mirrors the same lines as plain bullets with full URLs.
- Singular/plural: a tiny helper is fine ("1 new follower" vs "3 new followers"),
  or accept "1 new follower(s)"-style if the file has no pluralizer — keep it
  simple and consistent with the existing email copy.

### 3. `SendDigestWorker` — send-if-either

In `send_digest/1` (the per-user path), after loading the user and skipping `:off`:
```elixir
highlights = Digests.highlights(user)
activity = Digests.activity(user)

if highlights == [] and Digests.activity_empty?(activity) do
  :ok
else
  Email.deliver(user, highlights, activity)
  record_digest_sent(user)
end
```
(`record_digest_sent` and the flag/`:off` guards are unchanged.) The empty-skip now
requires BOTH empty.

### 4. No new attributes / actions / migration / flag

`activity/1` reads existing tables. Still gated by the existing `:digest_emails`
flag (the worker's guard is unchanged). No User schema change.

## Testing

- **`Digests.activity/1`:**
  - Seed, since the cutoff: a `:followed`/`:replied`/`:mentioned`/`:commented`/
    `:reacted` notification for the user → correct per-type counts; `:followed`
    `names` lists the actor usernames (≤3).
  - A notification *before* the cutoff is excluded; a notification for a *different*
    recipient is excluded.
  - Room activity: a group the user is an active member of, with new visible
    messages by *another* user since cutoff → that room appears with the right
    count; the user's *own* messages, deleted/held messages, and pre-cutoff
    messages are excluded; a room with zero new messages is absent.
  - An `:off` user → the empty summary; `activity_empty?` true on it, false when any
    bucket is non-zero.
- **`SendDigestWorker`:**
  - A user with activity but **no** article highlights still gets an email whose
    body contains the activity lines (e.g. "new follower", the room name).
  - A user with neither highlights nor activity → no email.
  - `:off` user / flag-off → no email (existing behavior preserved).
  - A user with highlights AND activity → one email containing both sections.
- **`Digests.Email` (unit):** `build/3` with a populated activity renders the
  Activity header + the non-zero lines + room lines; with `activity_empty?` true,
  no Activity section appears. (Reuse the Swoosh `build` → inspect `html_body`/
  `text_body` pattern.)

## Out of scope (later slices / deferred)

- Producing `:room_message` **notifications** (we query Communities directly here).
- Per-reply/mention snippets, threading, or actor lists beyond follower names.
- Letting users choose/order digest sections.
- The other three digest refinements: per-user-timezone send-time, admin
  send-now + preview, open/click analytics.

## Files touched (summary)

- `lib/verscienta/digests.ex` — `activity/1`, `activity_empty?/1` (+ a private
  cutoff helper).
- `lib/verscienta/digests/email.ex` — `build/3`/`deliver/3` + the Activity section
  in `html`/`text`.
- `lib/verscienta/digests/workers/send_digest_worker.ex` — fetch activity; send
  when either highlights or activity is non-empty; pass activity to the email.
- Tests across the above (`Verscienta.Support.Factory`; Swoosh `assert_email_sent`;
  notification + message + membership seeding).
- No migration, no new resource/attribute/action, no new flag.
