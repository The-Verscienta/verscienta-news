# Digest Refinements — Slice 2: Admin Send-Now + Preview

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-11
**Phase:** 3 — Intelligence & Growth › Notifications & Digests
**Todo item:** `Digest refinements (deferred): … admin "send now" + digest preview …`
— this slice delivers the admin send-now + preview part. (Per-user-timezone
send-time and open/click analytics are separate later slices.)

## Goal

Give admins a tool to **preview** any user's rendered digest (built, never sent)
and to **send it now** on demand — useful for QA (eyeballing the new Activity
section) and ops (manually re-triggering a user's digest).

## Decisions (from brainstorming)

- **Send-now = admin override (real send):** build + deliver the digest to the
  user's real email **regardless of the `:digest_emails` flag** (so it works
  pre-launch), and update `last_digest_at` (a real send — prevents a duplicate
  from the next cron). Sends nothing when the digest is empty (`:off` or no
  content).
- **Preview never sends** and never touches `last_digest_at`.
- **Refactor:** extract the worker's send logic into `Digests.deliver/1`; the cron
  worker calls it after its flag check, admin send-now calls it directly (the
  bypass). DRYs the path so send-now reuses the exact rendering + recording.
- **Preview rendering:** the email HTML is shown in a **sandboxed iframe**
  (`srcdoc` + `sandbox=""`) to isolate email CSS/JS from the admin page.
- **Lookup:** find a user by exact **username or email**.

## Background (current state)

- `Verscienta.Digests` (`lib/verscienta/digests.ex`): `highlights/1`, `activity/1`,
  `activity_empty?/1`, `window_days/1`, unsubscribe tokens.
- `Verscienta.Digests.Email` (`lib/verscienta/digests/email.ex`): `build/3`
  (returns a `Swoosh.Email` struct with `subject`/`html_body`/`text_body`, no
  send) + `deliver/3`.
- `SendDigestWorker` (`lib/verscienta/digests/workers/send_digest_worker.ex`):
  `perform/1` flag-gates on `:digest_emails`, then `send_digest/1` skips `:off`,
  `deliver_for/1` builds highlights+activity and sends if either non-empty,
  `send_and_record/3` delivers + runs `:record_digest_sent` (sets `last_digest_at`).
- `User`: `digest_frequency` (`:off|:daily|:weekly`), `last_digest_at`, `email`
  (AshAuthentication CiString), `username`, `role`. `:record_digest_sent` system
  action sets `last_digest_at`.
- Admin gating: `/admin` scope `pipe_through [:browser, :admin]`; `live_session`
  with `on_mount [{LiveUserAuth, :current_user}, {LiveUserAuth, :admin_required}]`
  (e.g. `:admin_flags` at router.ex:251). `:admin_required` raises
  `VerscientaWeb.LiveUserAuth.NotFound` (404) for non-admins. Existing admin
  LiveViews: `AdminFlagsLive`, `AdminModerationLive`, `AdminSourcesLive`,
  `AdminExpertsLive`. No `/admin/digests` exists yet.

## Architecture

### 1. `Digests.deliver/1` (extract send logic)

```elixir
@doc """
Build and send `user`'s digest. Returns:
  {:ok, :sent}    — an email was delivered + last_digest_at recorded
  {:ok, :skipped} — nothing to send (no highlights and no activity, incl. :off)
  {:error, term}  — delivery failed (caller/Oban may retry)
Does NOT check the :digest_emails flag — callers decide that (the cron worker
gates on it; admin send-now bypasses it).
"""
def deliver(%User{} = user) do
  highlights = highlights(user)
  activity = activity(user)

  if highlights == [] and activity_empty?(activity) do
    {:ok, :skipped}
  else
    case Verscienta.Digests.Email.deliver(user, highlights, activity) do
      {:ok, _} ->
        user
        |> Ash.Changeset.for_update(:record_digest_sent, %{}, authorize?: false)
        |> Ash.update!()

        {:ok, :sent}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

`SendDigestWorker` is refactored to use it:
```elixir
defp send_digest(id) do
  case Ash.get(User, id, authorize?: false) do
    {:ok, user} ->
      case Digests.deliver(user) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end

    {:error, _} ->
      :ok
  end
end
```
- The `perform/1` `:digest_emails` flag guard is unchanged (cron still gated).
- The previous explicit `:off` skip is dropped — `deliver/1` returns `{:ok, :skipped}`
  for an `:off` user (its window is 0 → empty highlights + empty activity).
- The worker still returns `:ok` for skips and a missing user; it returns
  `{:error, reason}` on a delivery failure so Oban retries (this matches the prior
  `with`-based behavior — a failed deliver was not marked sent).

### 2. `Digests.preview/1` (build, never send)

```elixir
@doc "Build `user`'s digest for preview (no send). Returns subject/html/text/empty?."
def preview(%User{} = user) do
  highlights = highlights(user)
  activity = activity(user)
  email = Verscienta.Digests.Email.build(user, highlights, activity)

  %{
    subject: email.subject,
    html: email.html_body,
    text: email.text_body,
    empty?: highlights == [] and activity_empty?(activity)
  }
end
```

### 3. `AdminDigestLive` at `/admin/digests`

- **Route:** add to the `/admin` scope a `live_session :admin_digests` with
  `on_mount [{LiveUserAuth, :current_user}, {LiveUserAuth, :admin_required}]` and
  `live "/digests", AdminDigestLive, :index`.
- **State:** `query` (the lookup string), `target` (the resolved `%User{}` or nil),
  `preview` (the `Digests.preview/1` map or nil), `lookup_error` (string or nil).
- **Lookup** (`handle_event("lookup", %{"q" => q})`): resolve a user by exact
  username or email — e.g. `User |> Ash.Query.filter(username == ^q or email == ^q)
  |> Ash.read_one(authorize?: false)`. (Email is a CiString; comparing to the
  trimmed input is fine. If the dual-field filter is awkward with the CiString
  type, fall back to two reads: username first, then email.) On a hit, assign
  `target` + `preview: Digests.preview(user)`, clear `lookup_error`. On a miss,
  set `lookup_error: "No user found for \"#{q}\""` and clear target/preview.
- **Render:**
  - The lookup form (text input + "Look up" button).
  - When `target`: a small info row (email, `digest_frequency`, `last_digest_at`),
    the digest **subject**, an "empty digest — nothing would be sent" note when
    `preview.empty?`, the HTML preview in
    `<iframe srcdoc={@preview.html} sandbox="" class="w-full h-[600px] border border-line bg-white">`,
    and the text body in a collapsible `<details><pre>`.
  - A **Send now** button: `phx-click="send_now"` with
    `data-confirm={"Send a real digest email to #{@target.email} now?"}`.
- **Send now** (`handle_event("send_now", _)`): re-assert `target` present, then
  `Digests.deliver(target)`:
  - `{:ok, :sent}` → flash `:info` "Digest sent."; reload the user
    (`Ash.get!`, fresh `last_digest_at`) + refresh `preview`.
  - `{:ok, :skipped}` → flash `:info` "Nothing to send (empty digest)."
  - `{:error, _}` → flash `:error` "Could not send the digest."
- Match the existing admin LiveView styling (Codex tokens; mirror
  `AdminFlagsLive`/`AdminSourcesLive` layout conventions).

### 4. Safety

- Admin-only via `:admin_required` (404 for non-admins).
- Send-now sends a **real email to the user** → guarded by the JS `data-confirm`.
- Preview is read-only (no delivery, no `last_digest_at` change).
- All reads `authorize?: false` (admin system context), consistent with the rest
  of `Digests`.

## Testing

- **`Digests.deliver/1`:** a user with highlights and/or activity →
  `{:ok, :sent}`, an email is sent, `last_digest_at` is set; an `:off` user (or a
  user with no content) → `{:ok, :skipped}`, no email, `last_digest_at` unchanged.
  (No flag dependency — assert it sends even with `:digest_emails` disabled.)
- **`SendDigestWorker` (regression):** existing tests still pass — flag off → no
  send; flag on + non-empty → sent + recorded; `:off`/empty → no email; missing
  user → `:ok`. (The refactor must not change observable worker behavior.)
- **`Digests.preview/1`:** subject is the digest subject; `html` contains the
  article/activity content for a populated user; `empty?` true for an `:off`/empty
  user; no email sent.
- **`AdminDigestLive`:** a non-admin gets the 404 (NotFound) on `/admin/digests`;
  an admin can look up a user by username and by email and sees the preview
  (the iframe `srcdoc` carries the html; the subject renders); a missing lookup
  shows the friendly error; **Send now** for a populated user delivers
  (`assert_email_sent`) and flashes "sent" + advances `last_digest_at`; Send-now
  for an empty/`:off` user flashes "nothing to send" and sends no email.

## Out of scope (later / deferred)

- Scheduling a send for later; bulk/segment send; a "send to all due" button.
- Editing digest content or toggling sections from the admin UI.
- Open/click instrumentation in the preview (that's the analytics slice).
- A nav link to `/admin/digests` from a global admin menu (add opportunistically;
  the route + direct URL suffice for this slice).
- The other digest refinements: per-user-timezone send-time, open/click analytics.

## Files touched (summary)

- `lib/verscienta/digests.ex` — `deliver/1`, `preview/1`.
- `lib/verscienta/digests/workers/send_digest_worker.ex` — call `Digests.deliver/1`
  (drop the redundant `:off`/`deliver_for`/`send_and_record` logic; keep the flag
  guard).
- `lib/verscienta_web/live/admin_digest_live.ex` — new admin LiveView.
- `lib/verscienta_web/router.ex` — `/admin/digests` route.
- Tests: `Digests.deliver`/`preview` (digests test), the worker regression
  (existing file), and an `AdminDigestLive` LiveView test.
- No migration, no new resource/attribute/action, no new flag.
