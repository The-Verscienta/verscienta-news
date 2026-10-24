# Moderation Fast-Follows — Reporter Notifications + Already-Reported Affordance

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-10
**Phase:** 3 — Intelligence & Growth › Moderation & Trust
**Todo item:** `Moderation fast-follows (deferred from slice 1): … reporter-resolution
notifications; hide report affordance on already-reported subjects.`
(The rate-limit sub-item is already done.)

## Goal

Two small, independent improvements to the community-reporting loop:

1. **Reporter-resolution notifications** — when a moderator resolves a reported
   subject, notify every human reporter that their report was handled, with a
   **coarse, anonymous** outcome (action taken vs. no action needed; never the
   moderator's identity or the exact sanction).
2. **Already-reported affordance** — across all four report surfaces (article,
   comments, user profiles, room messages), replace the active report button
   with a non-interactive "reported" indicator when the current user has already
   reported that subject (so it survives a page reload, not just the in-session
   post-submit state).

## Decisions (from brainstorming)

- **Notification content:** coarse outcome, anonymous. `dismissed` → "no action
  needed"; `content_removed` / `user_warned` / `user_suspended` → "action was
  taken". Never the moderator username or the precise resolution.
- **Who is notified:** every distinct **human** reporter (`reporter_id` not nil)
  of the subject, on **every** resolution. AI-sourced flags (`source: :ai`, no
  `reporter_id`) notify no one.
- **Affordance scope:** all four surfaces. Article / comments / profile use
  batched loads; room messages check the initial set and accept that a
  newly-streamed message won't reflect a same-session report until reload.
- **No deep-link** from the resolution notification (resolved/removed content may
  be gone); show the captured excerpt instead.

## Background (current behavior)

- `Verscienta.Moderation.Flag` (`lib/verscienta/moderation/flag.ex`): user reports.
  Attributes incl. `reporter_id`, `subject_type` (`:comment|:article|:user|:room_message`),
  `subject_id`, `subject_excerpt`, `source` (`:community|:ai`), `status`,
  `resolution`. Identity `:unique_reporter_subject` on
  `[:subject_type, :subject_id, :reporter_id]` — a user can report a subject only
  once (re-report upserts, no duplicate row).
- `Verscienta.Moderation.resolve/5` (`lib/verscienta/moderation.ex`): loads ALL
  pending flags for a subject, performs the side effect outside the transaction,
  then commits flag updates + the audit `Action` inside a transaction with
  `return_notifications?: true` and flushes notifications after commit. It
  notifies **no reporters** today. `resolution in [:dismissed, :content_removed,
  :user_warned, :user_suspended]`.
- `Verscienta.Notifications.notify/1` (`lib/verscienta/notifications.ex`): the one
  chokepoint. Blocks self-notify (`recipient_id == actor_id`), checks
  `enabled?(recipient, type)` against the user's `notification_prefs` (opt-out
  map, default enabled), creates the `Notification`, broadcasts. Best-effort —
  rescues to `:ok`, never raises.
- `Verscienta.Notifications.Notification` (`lib/verscienta/notifications/notification.ex`):
  `@types` (11 today), `@subject_types` `[:user, :article, :comment, :quest,
  :streak, :leaderboard, :badge]` (note: **`:room_message` is absent**).
  `:create` is system-only; `metadata` is a freeform map.
- `VerscientaWeb.NotificationComponents` (`lib/verscienta_web/components/notification_components.ex`):
  `notification_item/1`, `notification_phrase/1` (takes the type atom today),
  `notification_href/1`, `notification_accent/1`. The actor `@username` span is
  already suppressed when `metadata["actor_username"]` is absent.
- `VerscientaWeb.ReportDialog` (`lib/verscienta_web/components/report_dialog.ex`):
  `report_button/1` → a LiveComponent. After an in-session `submit`, it shows a
  "reported" badge; on a fresh mount it shows "⚐ report" again (no DB check).
- Report buttons render in: `ArticleReaderLive` (article + each comment),
  `ProfileLive` (the profile user), `RoomLive` (each message). All gated on
  `current_user && current_user.id != <author/owner>`.

## Architecture

### Part 1 — Reporter-resolution notifications

**1a. Notification resource (`notification.ex`):**
- Add `:report_resolved` to `@types`.
- Add `:room_message` to `@subject_types` (so a room-message report resolution can
  carry `subject_type: :room_message` without failing validation → being silently
  dropped by `notify/1`'s rescue).

**1b. `Moderation.resolve/5` (`moderation.ex`):**
- The flags loaded at the start of `resolve/5` already carry `reporter_id`. After
  the resolution transaction commits and existing notifications are flushed, add a
  best-effort step that notifies the distinct human reporters:
  ```elixir
  defp notify_reporters(flags, resolution) do
    outcome = if resolution == :dismissed, do: "no_action", else: "action_taken"

    flags
    |> Enum.reject(&is_nil(&1.reporter_id))
    |> Enum.uniq_by(& &1.reporter_id)
    |> Enum.each(fn flag ->
      Verscienta.Notifications.notify(%{
        recipient_id: flag.reporter_id,
        actor_id: nil,
        type: :report_resolved,
        subject_type: flag.subject_type,
        subject_id: to_string(flag.subject_id),
        metadata: %{
          "outcome" => outcome,
          "subject_excerpt" => flag.subject_excerpt
        }
      })
    end)

    :ok
  end
  ```
  Call `notify_reporters(flags, resolution)` after the post-commit notification
  flush (the same place the function already returns `{:ok, count}`), so it runs
  only on a successful resolution. `notify/1` is best-effort; wrap the call site
  defensively only if the surrounding function isn't already tolerant (it returns
  `{:ok, count}` regardless — keep that contract; a notify failure must not change
  the return).
- `uniq_by(:reporter_id)` ensures one notification per reporter even though there
  is already at most one flag per `(subject, reporter)` (defensive + clear intent).

> Note: `resolve/5` resolves one subject's flags per call. A reporter who reported
> multiple distinct subjects that are resolved separately gets one notification per
> subject — correct.

### Part 2 — Already-reported affordance

**2a. Query helpers in `Verscienta.Moderation`:**
```elixir
@doc "MapSet of subject_ids (from `ids`) the reporter has already reported for this type."
def reported_subject_ids(nil, _type, _ids), do: MapSet.new()
def reported_subject_ids(_reporter_id, _type, []), do: MapSet.new()

def reported_subject_ids(reporter_id, subject_type, ids) do
  string_ids = Enum.map(ids, &to_string/1)

  Flag
  |> Ash.Query.filter(
    reporter_id == ^reporter_id and subject_type == ^subject_type and
      subject_id in ^string_ids
  )
  |> Ash.Query.select([:subject_id])
  |> Ash.read!(authorize?: false)
  |> Enum.map(&to_string(&1.subject_id))
  |> MapSet.new()
end

@doc "Whether the reporter has already reported this single subject."
def reported?(nil, _type, _id), do: false

def reported?(reporter_id, subject_type, subject_id) do
  Flag
  |> Ash.Query.filter(
    reporter_id == ^reporter_id and subject_type == ^subject_type and
      subject_id == ^to_string(subject_id)
  )
  |> Ash.exists?(authorize?: false)
end
```
(Confirm `subject_id`'s stored type — it is a UUID column; comparisons use string
ids consistently with how reports are created. If `subject_id` is a native `uuid`
Ash attribute, pass the ids as-is rather than `to_string`; match the existing
`Flag` query/casting convention — verify against `flag.ex` and an existing query.)

**2b. `report_button/1` + the LiveComponent (`report_dialog.ex`):**
- `report_button/1` accepts a new optional attr `reported?` (default `false`) and
  forwards it to the LiveComponent.
- The LiveComponent's `update/2` seeds its internal `reported?` assign from the
  incoming `reported?` (so a DB-confirmed prior report shows the badge on mount),
  while the existing in-session `submit` path still flips it to `true`. Render the
  "reported" badge when `reported?` is true; otherwise the "⚐ report" button.
  (Keep the existing markup; only the initial state source changes.)

**2c. Surface wiring:**
- **`ArticleReaderLive`:** when assigning the article and the comment tree, compute
  `reported?` per subject. Compute the comment set once via
  `Moderation.reported_subject_ids(viewer_id, :comment, comment_ids)` (flatten the
  tree incl. replies) and `Moderation.reported?(viewer_id, :article, article.id)`
  for the article. Pass `reported?` into each `report_button`. Recompute the
  comment set whenever the comment stream is (re)loaded. `viewer_id =
  current_user && current_user.id`.
- **`ProfileLive`:** compute `reported?: Moderation.reported?(viewer_id, :user,
  profile_user.id)` and pass it to the profile's `report_button`.
- **`RoomLive`:** on initial message load, compute
  `Moderation.reported_subject_ids(viewer_id, :room_message, message_ids)` and pass
  `reported?` per message. Messages arriving live via PubSub default
  `reported?: false` (the accepted edge — corrects on reload).

### Part 3 — Notification rendering (`notification_components.ex`)

- **`notification_phrase/1`:** refactor to match on the notification (or at least a
  map carrying `type` + `metadata`) instead of the bare type atom, updating the
  existing clauses mechanically (`def notification_phrase(%{type: :followed})`,
  etc.) and the single call site in `notification_item/1`
  (`notification_phrase(@notification)`). Add:
  ```elixir
  def notification_phrase(%{type: :report_resolved, metadata: %{"outcome" => "action_taken"}}),
    do: "Your report was reviewed — action was taken."

  def notification_phrase(%{type: :report_resolved}),
    do: "Your report was reviewed — no action was needed."
  ```
  (The second clause is the default for `:report_resolved`, covering "no_action"
  and any missing/garbled outcome.)
- **`notification_href/1`:** no new clause — `:report_resolved` has no
  `article_slug` in metadata, so it falls through to the existing `/notifications`
  default. (No deep link by design.)
- **`notification_accent/1`:** add a `:report_resolved` clause with a neutral
  accent (`bg-ink-3`).
- The row already omits the `@username` span when `metadata["actor_username"]` is
  absent, so an actor-less `:report_resolved` renders the phrase alone. Optionally
  surface `metadata["subject_excerpt"]` in the existing subject slot so the
  reporter recognizes which report it was (use the slot the renderer already shows;
  keep it simple).

## Testing

- **Notify (`Moderation.resolve` + notify):**
  - Two community reporters on one subject → both get a `:report_resolved`
    notification when a mod resolves it; a third user who didn't report gets none.
  - `dismissed` → `metadata["outcome"] == "no_action"`; `content_removed` (or any
    sanction) → `"action_taken"`.
  - A subject with only an AI flag (no `reporter_id`) → no `:report_resolved`
    notification.
  - A reporter who set `notification_prefs["report_resolved"] = false` → no
    notification (prefs chokepoint).
  - The notification carries `subject_type` matching the report (incl.
    `:room_message`) and is created with `actor_id: nil`.
  - `resolve/5` still returns `{:ok, count}` unchanged.
- **Affordance:**
  - `reported_subject_ids/3` returns exactly the subset the reporter reported
    (empty for `nil` reporter or empty ids).
  - `reported?/3` true after a report, false otherwise / for `nil`.
  - `report_button` renders the "reported" badge when `reported?: true` and the
    active button when `false`.
  - Article reader: a user who reported a comment sees "reported" on that comment
    after reload (LiveView test); the article button reflects `reported?`.
  - Profile + room: the button reflects a prior report on mount.
- **Component:** `notification_phrase/1` returns the action-taken vs. no-action
  sentence by metadata; the refactor keeps all existing phrases intact (spot-check
  a couple of existing types).

## Out of scope

- Deep-linking the resolution notification to the (possibly removed) subject.
- Revealing the moderator identity or the exact resolution to the reporter.
- Live-updating the "already reported" state for room messages that arrive after
  the page loaded (corrects on reload).
- Showing reporters in the moderation queue, or a per-reporter resolution history.
- Notifying the reported **author** (separate concern; not in this item).

## Files touched (summary)

- `lib/verscienta/notifications/notification.ex` — `:report_resolved` type;
  `:room_message` subject_type.
- `lib/verscienta/moderation.ex` — `notify_reporters/2` in the resolve path;
  `reported_subject_ids/3` + `reported?/3` helpers.
- `lib/verscienta_web/components/report_dialog.ex` — `reported?` attr + initial
  state seeding.
- `lib/verscienta_web/components/notification_components.ex` —
  `notification_phrase/1` refactor + `:report_resolved` phrase/accent.
- `lib/verscienta_web/live/article_reader_live.ex`,
  `lib/verscienta_web/live/profile_live.ex`,
  `lib/verscienta_web/live/room_live.ex` — pass `reported?` to report buttons.
- Tests across the above (using `Verscienta.Support.Factory`).
- No migration (enum widenings are app-level atom lists over existing columns),
  no new resource, no new flag.
