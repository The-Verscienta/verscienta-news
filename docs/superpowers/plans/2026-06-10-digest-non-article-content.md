# Digest Non-Article Content Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an "Activity" section to the digest email summarizing new followers, replies/mentions/comments/reactions (from Notifications) and new community-room messages (from Communities) since the user's last digest — and send the digest when either article highlights OR activity is non-empty.

**Architecture:** A new `Digests.activity/1` builds a compact summary map; `Digests.activity_empty?/1` reports whether it has anything. `Digests.Email.build/3`/`deliver/3` render the Activity section. `SendDigestWorker` fetches both highlights + activity and sends if either is non-empty.

**Tech Stack:** Elixir, Ash 3 (`Notification`, `GroupMembership`, `Message` reads), Swoosh, Oban, ExUnit + `Verscienta.Support.Factory` + Swoosh `assert_email_sent`.

**Spec:** `docs/superpowers/specs/2026-06-10-digest-non-article-content-design.md`

**Conventions:**
- All `mix` runs inside Docker: `docker compose exec app mix ...`.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Branch: `phase-3-digest-non-article`. `git checkout phase-3-digest-non-article` first; STOP if the tree is dirty with unrelated changes.
- `Digests` already has `require Ash.Query` and aliases `User`, `Recommendations`. Call `Verscienta.Notifications.*` / `Verscienta.Communities.*` fully-qualified (no new aliases).
- The `activity_summary` map shape (fixed across the codebase):
  `%{followers: %{count: int, names: [String]}, replies: int, mentions: int, comments: int, reactions: int, rooms: [%{name: String, slug: String, count: int}]}`.

---

### Task 1: `Digests.activity/1` + `activity_empty?/1`

**Files:**
- Modify: `lib/verscienta/digests.ex`
- Test: `test/verscienta/digests/activity_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/digests/activity_test.exs`:

```elixir
defmodule Verscienta.Digests.ActivityTest do
  use Verscienta.DataCase, async: true

  import Verscienta.Support.Factory, only: [user: 1]

  alias Verscienta.Communities
  alias Verscienta.Digests
  alias Verscienta.Notifications.Notification

  require Ash.Query

  defp weekly(u) do
    u
    |> Ash.Changeset.for_update(:set_digest_frequency, %{digest_frequency: :weekly}, actor: u)
    |> Ash.update!()
  end

  defp notif(recipient, type, opts) do
    cs =
      Notification
      |> Ash.Changeset.for_create(:create, %{
        recipient_id: recipient.id,
        actor_id: opts[:actor_id],
        type: type,
        subject_type: opts[:subject_type] || :user,
        subject_id: opts[:subject_id] || Ash.UUID.generate(),
        metadata: opts[:metadata] || %{}
      })

    cs =
      case opts[:inserted_at] do
        nil -> cs
        ts -> Ash.Changeset.force_change_attribute(cs, :inserted_at, ts)
      end

    Ash.create!(cs, authorize?: false)
  end

  defp group(owner, name) do
    Communities.Group
    |> Ash.Changeset.for_create(:create, %{name: name, slug: name <> "-#{System.unique_integer([:positive])}"},
      actor: owner
    )
    |> Ash.create!()
  end

  defp join(g, u) do
    Communities.GroupMembership
    |> Ash.Changeset.for_create(:create, %{group_id: g.id, user_id: u.id, role: :member, status: :active})
    |> Ash.create!(authorize?: false)
  end

  test "summarizes notifications by type within the window" do
    u = weekly(user("act_u"))
    a1 = user("act_f1")
    a2 = user("act_f2")

    notif(u, :followed, actor_id: a1.id, metadata: %{"actor_username" => "act_f1"})
    notif(u, :followed, actor_id: a2.id, metadata: %{"actor_username" => "act_f2"})
    notif(u, :replied, actor_id: a1.id, subject_type: :comment, subject_id: Ash.UUID.generate())
    notif(u, :mentioned, actor_id: a1.id, subject_type: :comment, subject_id: Ash.UUID.generate())
    notif(u, :commented, actor_id: a1.id, subject_type: :article, subject_id: Ash.UUID.generate())
    notif(u, :reacted, actor_id: a1.id, subject_type: :article, subject_id: Ash.UUID.generate())

    # pre-cutoff (8 days ago, window is 7) — excluded
    notif(u, :reacted,
      actor_id: a2.id,
      subject_type: :article,
      subject_id: Ash.UUID.generate(),
      inserted_at: DateTime.add(DateTime.utc_now(), -8 * 86_400, :second)
    )

    a = Digests.activity(u)
    assert a.followers.count == 2
    assert Enum.sort(a.followers.names) == ["act_f1", "act_f2"]
    assert a.replies == 1
    assert a.mentions == 1
    assert a.comments == 1
    assert a.reactions == 1
    refute Digests.activity_empty?(a)
  end

  test "follower names cap at 3" do
    u = weekly(user("act_cap"))

    for n <- 1..5 do
      who = user("cap_#{n}")
      notif(u, :followed, actor_id: who.id, metadata: %{"actor_username" => "cap_#{n}"})
    end

    a = Digests.activity(u)
    assert a.followers.count == 5
    assert length(a.followers.names) == 3
  end

  test "an :off user yields the empty summary" do
    u = user("act_off")
    notif(u, :followed, actor_id: user("act_x").id, metadata: %{"actor_username" => "act_x"})

    a = Digests.activity(u)
    assert Digests.activity_empty?(a)
  end

  test "excludes notifications for other recipients" do
    u = weekly(user("act_me"))
    other = user("act_other")
    notif(other, :followed, actor_id: user("act_y").id, metadata: %{"actor_username" => "act_y"})

    a = Digests.activity(u)
    assert a.followers.count == 0
  end

  test "counts new room messages by others, excluding the user's own" do
    u = weekly(user("rm_u"))
    poster = user("rm_poster")
    g = group(u, "Roomy")
    join(g, poster)
    room = Communities.room_for_group(g)

    {:ok, _} = Communities.post_message(room, poster, "hello")
    {:ok, _} = Communities.post_message(room, poster, "again")
    {:ok, _} = Communities.post_message(room, u, "my own message")

    a = Digests.activity(u)
    assert [%{name: "Roomy", count: 2}] = a.rooms
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec app mix test test/verscienta/digests/activity_test.exs`
Expected: FAIL — `Digests.activity/1` / `activity_empty?/1` are undefined.

- [ ] **Step 3: Implement `activity/1` + helpers**

In `lib/verscienta/digests.ex`, add module attributes near the top (after `@highlight_limit 5`):

```elixir
  @activity_follower_names 3
  @activity_room_limit 5
```

Add the public functions (after `highlights/1`):

```elixir
  @doc """
  Compact non-article activity summary for `user` since their last digest
  (cutoff: `last_digest_at`, or `now - window_days·86400` for a first digest).
  Empty for an `:off` user. Shape:
  `%{followers: %{count, names}, replies, mentions, comments, reactions, rooms}`.
  """
  def activity(%User{digest_frequency: :off}), do: empty_activity()

  def activity(%User{} = user) do
    cutoff = activity_cutoff(user)
    by_type = user |> notifications_since(cutoff) |> Enum.group_by(& &1.type)

    %{
      followers: follower_summary(Map.get(by_type, :followed, [])),
      replies: length(Map.get(by_type, :replied, [])),
      mentions: length(Map.get(by_type, :mentioned, [])),
      comments: length(Map.get(by_type, :commented, [])),
      reactions: length(Map.get(by_type, :reacted, [])),
      rooms: room_activity(user, cutoff)
    }
  end

  @doc "True when an activity summary has nothing to show."
  def activity_empty?(%{
        followers: %{count: 0},
        replies: 0,
        mentions: 0,
        comments: 0,
        reactions: 0,
        rooms: []
      }),
      do: true

  def activity_empty?(_), do: false

  defp empty_activity do
    %{followers: %{count: 0, names: []}, replies: 0, mentions: 0, comments: 0, reactions: 0, rooms: []}
  end

  defp activity_cutoff(%{last_digest_at: nil, digest_frequency: freq}),
    do: DateTime.add(DateTime.utc_now(), -window_days(freq) * 86_400, :second)

  defp activity_cutoff(%{last_digest_at: ts}), do: ts

  defp notifications_since(user, cutoff) do
    Verscienta.Notifications.Notification
    |> Ash.Query.filter(recipient_id == ^user.id and inserted_at >= ^cutoff)
    |> Ash.read!(authorize?: false)
  end

  defp follower_summary(followed) do
    names =
      followed
      |> Enum.map(& &1.metadata["actor_username"])
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.take(@activity_follower_names)

    %{count: length(followed), names: names}
  end

  defp room_activity(user, cutoff) do
    groups =
      Verscienta.Communities.GroupMembership
      |> Ash.Query.filter(user_id == ^user.id and status == :active)
      |> Ash.Query.load(group: [:room])
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.group)
      |> Enum.filter(& &1.room)

    by_room = Map.new(groups, &{&1.room.id, &1})
    room_ids = Map.keys(by_room)

    if room_ids == [] do
      []
    else
      Verscienta.Communities.Message
      |> Ash.Query.filter(
        room_id in ^room_ids and inserted_at >= ^cutoff and user_id != ^user.id and
          is_nil(deleted_at) and moderation_status == :visible
      )
      |> Ash.Query.select([:room_id])
      |> Ash.read!(authorize?: false)
      |> Enum.frequencies_by(& &1.room_id)
      |> Enum.map(fn {room_id, n} ->
        g = by_room[room_id]
        %{name: g.name, slug: g.slug, count: n}
      end)
      |> Enum.sort_by(& &1.count, :desc)
      |> Enum.take(@activity_room_limit)
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose exec app mix test test/verscienta/digests/activity_test.exs`
Expected: PASS (5 tests). Also `docker compose exec app mix compile --warnings-as-errors` (clean).

> If `Ash.Query.load(group: [:room])` errors (e.g. the `:room` relationship name differs), read `lib/verscienta/communities/group.ex` — it has `has_one :room`. If `Communities.Group`'s `:create` action requires different attrs than `%{name, slug}`, read `group.ex` and adjust the test's `group/2` helper to match (the activity implementation is unaffected).

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta/digests.ex test/verscienta/digests/activity_test.exs
git commit -m "feat(digests): Digests.activity/1 — non-article activity summary

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Email Activity section (`build/3`) + worker send-if-either

> These move together: changing `Email.build/2`→`build/3` breaks the worker's only
> call site, so the email change and the worker change must land in one commit to
> keep the tree compiling.

**Files:**
- Modify: `lib/verscienta/digests/email.ex`
- Modify: `lib/verscienta/digests/workers/send_digest_worker.ex`
- Test (create): `test/verscienta/digests/email_test.exs`
- Test (modify): `test/verscienta/digests/workers/send_digest_worker_test.exs`

- [ ] **Step 1: Write the failing tests**

(a) Create `test/verscienta/digests/email_test.exs`:

```elixir
defmodule Verscienta.Digests.EmailTest do
  use Verscienta.DataCase, async: true

  import Verscienta.Support.Factory, only: [user: 1]

  alias Verscienta.Digests.Email

  defp populated_activity do
    %{
      followers: %{count: 2, names: ["alice", "bob"]},
      replies: 1,
      mentions: 0,
      comments: 0,
      reactions: 3,
      rooms: [%{name: "Herbalists", slug: "herbalists", count: 5}]
    }
  end

  defp empty_activity do
    %{followers: %{count: 0, names: []}, replies: 0, mentions: 0, comments: 0, reactions: 0, rooms: []}
  end

  test "build/3 renders the activity section with counts, names, and rooms" do
    email = Email.build(user("e_u"), [], populated_activity())
    body = email.html_body

    assert body =~ "Since your last digest"
    assert body =~ "2 new followers"
    assert body =~ "alice"
    assert body =~ "1 reply"
    assert body =~ "3 reactions"
    assert body =~ "Herbalists"
    assert body =~ "5 new messages"
    # a zero bucket (mentions) is omitted
    refute body =~ "mention"
  end

  test "build/3 with empty activity renders no activity section" do
    email = Email.build(user("e_u2"), [], empty_activity())
    refute email.html_body =~ "Since your last digest"
  end
end
```

(b) Add to `test/verscienta/digests/workers/send_digest_worker_test.exs` (READ it first; mirror its existing setup — `set_swoosh_global`, `FunWithFlags.enable(:digest_emails)`, its `user`/`set_digest` helpers, `Oban.Testing`/`perform_job`):

```elixir
  test "delivers to a user with activity but no article highlights" do
    u = weekly_user("wact")

    Verscienta.Notifications.Notification
    |> Ash.Changeset.for_create(:create, %{
      recipient_id: u.id,
      actor_id: user("wact_follower").id,
      type: :followed,
      subject_type: :user,
      subject_id: Ash.UUID.generate(),
      metadata: %{"actor_username" => "wact_follower"}
    })
    |> Ash.create!(authorize?: false)

    assert :ok = perform_job(SendDigestWorker, %{"user_id" => u.id})

    assert_email_sent(fn email ->
      body = email.html_body || email.text_body || ""
      assert body =~ "new follower"
    end)
  end

  test "sends no email when there is neither activity nor highlights" do
    u = weekly_user("wempty")
    assert :ok = perform_job(SendDigestWorker, %{"user_id" => u.id})
    assert_no_email_sent()
  end
```

> Use the file's existing user/digest helpers. If there is no `weekly_user/1`-style
> helper, add a top-level `defp weekly_user(name)` that registers a user (Factory
> `user/1`) and sets `digest_frequency: :weekly` via the `:set_digest_frequency`
> action (actor: the user). The `wact` user has no published articles, so
> `Digests.highlights/1` returns `[]` — only the activity drives the send. Ensure
> the file imports `Verscienta.Support.Factory`'s `user/1` (add to the `only:` list
> if missing).

- [ ] **Step 2: Run tests to verify they fail**

Run: `docker compose exec app mix test test/verscienta/digests/email_test.exs test/verscienta/digests/workers/send_digest_worker_test.exs`
Expected: FAIL — `Email.build/3` undefined; the activity-only worker user gets no email.

- [ ] **Step 3a: Update `Digests.Email` to `build/3` + add the Activity section**

In `lib/verscienta/digests/email.ex`:

Change `deliver/2`/`build/2` to arity 3:

```elixir
  @doc "Build and deliver the digest email for `user` with `articles` + `activity`."
  def deliver(user, articles, activity),
    do: user |> build(articles, activity) |> Mailer.deliver()

  @doc "Build the digest email struct without delivering it."
  def build(user, articles, activity) do
    new()
    |> from({"Verscienta News", "noreply@verscienta.news"})
    |> to(to_string(user.email))
    |> subject("Your Verscienta digest")
    |> html_body(html(user, articles, activity))
    |> text_body(text(user, articles, activity))
  end
```

Change `html/2`→`html/3` and `text/2`→`text/3`, inserting the activity section before the unsubscribe footer:

```elixir
  defp html(user, articles, activity) do
    unsub = unsubscribe_url(user)

    items =
      Enum.map_join(articles, "", fn a ->
        ~s(<p><a href="#{url(~p"/articles/#{a.slug}")}">#{esc(a.title)}</a><br/>#{esc(a.excerpt || "")}</p>)
      end)

    """
    <h1>Your Verscienta digest</h1>
    #{items}
    #{activity_html(activity)}
    <p style="color:#999;font-size:12px">You're receiving this because you opted in to digests.
    <a href="#{unsub}">Unsubscribe</a>.</p>
    """
  end

  defp text(user, articles, activity) do
    unsub = unsubscribe_url(user)

    items =
      Enum.map_join(articles, "\n", fn a ->
        "- #{oneline(a.title)}: #{url(~p"/articles/#{a.slug}")}"
      end)

    "Your Verscienta digest:\n\n#{items}#{activity_text(activity)}\n\nUnsubscribe: #{unsub}"
  end
```

Add the activity renderers + helpers (among the private functions):

```elixir
  defp activity_html(activity) do
    if Digests.activity_empty?(activity) do
      ""
    else
      notif_url = url(~p"/notifications")

      notif_items =
        activity
        |> activity_lines()
        |> Enum.map_join("", fn line -> ~s(<li><a href="#{notif_url}">#{esc(line)}</a></li>) end)

      room_items =
        Enum.map_join(activity.rooms, "", fn r ->
          ~s(<li><a href="#{url(~p"/groups/#{r.slug}/room")}">#{esc(r.name)} — #{r.count} new #{plural(r.count, "message", "messages")}</a></li>)
        end)

      """
      <h2>Since your last digest</h2>
      <ul>#{notif_items}#{room_items}</ul>
      """
    end
  end

  defp activity_text(activity) do
    if Digests.activity_empty?(activity) do
      ""
    else
      notif_url = url(~p"/notifications")

      lines =
        activity
        |> activity_lines()
        |> Enum.map(fn line -> "- #{line}: #{notif_url}" end)

      rooms =
        Enum.map(activity.rooms, fn r ->
          "- #{oneline(r.name)} — #{r.count} new #{plural(r.count, "message", "messages")}: #{url(~p"/groups/#{r.slug}/room")}"
        end)

      "\n\nSince your last digest:\n" <> Enum.join(lines ++ rooms, "\n")
    end
  end

  # The notification-sourced lines (rooms render separately); zero buckets dropped.
  defp activity_lines(activity) do
    [
      follower_line(activity.followers),
      count_line(activity.replies, "reply to your comments", "replies to your comments"),
      count_line(activity.mentions, "mention", "mentions"),
      count_line(activity.comments, "comment on your articles", "comments on your articles"),
      count_line(activity.reactions, "reaction to your articles", "reactions to your articles")
    ]
    |> Enum.reject(&(&1 == ""))
  end

  defp follower_line(%{count: 0}), do: ""

  defp follower_line(%{count: n, names: names}) do
    suffix = if names == [], do: "", else: " (#{Enum.join(names, ", ")})"
    "#{n} new #{plural(n, "follower", "followers")}#{suffix}"
  end

  defp count_line(0, _singular, _plural_form), do: ""
  defp count_line(n, singular, plural_form), do: "#{n} #{plural(n, singular, plural_form)}"

  defp plural(1, singular, _plural_form), do: singular
  defp plural(_n, _singular, plural_form), do: plural_form
```

- [ ] **Step 3b: Update `SendDigestWorker` for send-if-either**

In `lib/verscienta/digests/workers/send_digest_worker.ex`, replace `deliver_for/1` and `send_and_record/2`:

```elixir
  defp deliver_for(user) do
    highlights = Digests.highlights(user)
    activity = Digests.activity(user)

    if highlights == [] and Digests.activity_empty?(activity) do
      :ok
    else
      send_and_record(user, highlights, activity)
    end
  end

  defp send_and_record(user, highlights, activity) do
    with {:ok, _} <- Email.deliver(user, highlights, activity) do
      user
      |> Ash.Changeset.for_update(:record_digest_sent, %{}, authorize?: false)
      |> Ash.update!()

      :ok
    end
  end
```

(The `perform/1`, flag guard, and `:off` skip in `send_digest/1` are unchanged.)

- [ ] **Step 4: Run tests + compile**

Run: `docker compose exec app mix test test/verscienta/digests/email_test.exs test/verscienta/digests/workers/send_digest_worker_test.exs`
Expected: PASS (email render tests + existing worker tests + the 2 new worker tests).

Run: `docker compose exec app mix compile --warnings-as-errors`
Expected: clean (the `Email.deliver/3` arity now matches the worker; watch for any `plural`/unused-var warning).

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta/digests/email.ex lib/verscienta/digests/workers/send_digest_worker.ex test/verscienta/digests/email_test.exs test/verscienta/digests/workers/send_digest_worker_test.exs
git commit -m "feat(digests): Activity section in the email + send-if-either worker

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Full verification + docs

**Files:**
- Modify: `docs/todo.md`

- [ ] **Step 1: Format + compile (warnings as errors)**

Run: `docker compose exec app mix format && docker compose exec app mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 2: Credo strict**

Run: `docker compose exec app mix credo --strict`
Expected: no issues.

- [ ] **Step 3: Run the digest suites**

Run: `docker compose exec app mix test test/verscienta/digests/`
Expected: PASS (activity, email, both workers, and the core `digests_test.exs`).

- [ ] **Step 4: Run the full suite**

Run: `docker compose exec app mix test`
Expected: PASS, 0 failures. (If a transient seed-contamination count failure appears, re-run; see the project memory on test DB seed contamination.)

- [ ] **Step 5: Update the todo item**

In `docs/todo.md`, the digest-refinements line is a single `[ ]` covering four sub-items; this slice does one. Change:

```
- [ ] Digest refinements (deferred): per-user-timezone / optimal send-time; non-article digest content (new followers, comment replies, room activity); admin "send now" + digest preview; open/click analytics.
```

to (mark in-progress, strike the done sub-item):

```
- [~] Digest refinements (deferred): per-user-timezone / optimal send-time; ~~non-article digest content (new followers, comment replies, room activity)~~ *(done — `Digests.activity/1` Activity section in the digest email: new followers + replies/mentions/comments/reactions from Notifications + per-room new-message counts from Communities, since last_digest_at; worker sends when either highlights or activity is non-empty)*; admin "send now" + digest preview; open/click analytics.
```

- [ ] **Step 6: Commit**

```bash
git add docs/todo.md
git commit -m "docs(digests): mark non-article digest content done (slice 1)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review Notes

**Spec coverage:**
- `Digests.activity/1` (notifications by type + room counts, since-last-digest window, off→empty) + `activity_empty?/1` → Task 1.
- Compact detail (counts + ≤3 follower names + per-room counts) → Tasks 1–2.
- Email Activity section (html + text, omit zero lines, omit whole section when empty) → Task 2.
- Send-if-either → Task 2 (moved with the email arity change so no commit leaves the tree non-compiling).
- Tests for activity, email render, and worker send-conditions → Tasks 1–2.
- Verification + todo update → Task 3.

**Out of scope (per spec), intentionally absent:** producing `:room_message` notifications; per-reply snippets; section customization; the other three digest refinements (timezone send-time, admin send-now/preview, open/click analytics). No migration, no new resource/attribute/action, no new flag.
