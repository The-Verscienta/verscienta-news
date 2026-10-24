# Moderation Fast-Follows Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Notify reporters when their reported subject is resolved (coarse, anonymous), and show an "already reported" state instead of an active report button across all four report surfaces.

**Architecture:** `Moderation.resolve/5` gains a best-effort `notify_reporters/2` step that fires one anonymous `:report_resolved` notification per distinct human reporter. New `Moderation.reported?/3` + `reported_subject_ids/3` query helpers feed a `reported?` assign into `ReportDialog.report_button/1`, which renders the existing "reported" badge when set. Wiring lives in the four LiveViews (article reader, profile, room) that render report buttons.

**Tech Stack:** Elixir, Ash 3 (`Flag`, `Notification` resources), Phoenix LiveView (streams, live_component), `Verscienta.Notifications.notify/1` chokepoint, ExUnit + `Phoenix.LiveViewTest`, `Verscienta.Support.Factory`.

**Spec:** `docs/superpowers/specs/2026-06-10-moderation-fast-follows-design.md`

**Conventions:**
- All `mix` runs inside Docker: `docker compose exec app mix ...` (service `app`).
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Branch: `phase-3-moderation-fast-follows`. `git checkout phase-3-moderation-fast-follows` first; STOP if the tree is dirty with unrelated changes.
- `Flag.subject_id` and `Flag.reporter_id` are `:uuid`; `Notification.subject_id` is `:string` (so notifications use `to_string(subject_id)`).
- The article reader, profile, and room LiveViews already call cross-context functions fully-qualified (e.g. `Verscienta.Social.reposted?`); follow that — call `Verscienta.Moderation.reported?/3` fully-qualified, do NOT add an alias (avoids credo alias-ordering churn).

---

### Task 1: Reporter-resolution notifications

**Files:**
- Modify: `lib/verscienta/notifications/notification.ex`
- Modify: `lib/verscienta/moderation.ex`
- Test: `test/verscienta/moderation/reporter_notifications_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/moderation/reporter_notifications_test.exs`:

```elixir
defmodule Verscienta.Moderation.ReporterNotificationsTest do
  use Verscienta.DataCase, async: true

  import Verscienta.Support.Factory, only: [user: 1, user: 2, article: 1]

  alias Verscienta.Moderation
  alias Verscienta.Moderation.Flag
  alias Verscienta.Notifications.Notification

  require Ash.Query

  defp report(actor, type, id) do
    Flag
    |> Ash.Changeset.for_create(:report, %{subject_type: type, subject_id: id, reason: :spam},
      actor: actor
    )
    |> Ash.create!(authorize?: true)
  end

  defp resolved_notifs(user) do
    Notification
    |> Ash.Query.filter(recipient_id == ^user.id and type == :report_resolved)
    |> Ash.read!(authorize?: false)
  end

  test "each distinct community reporter is notified with action_taken on a sanction" do
    author = user("rn_author")
    art = article(author)
    rep1 = user("rn_rep1")
    rep2 = user("rn_rep2")
    bystander = user("rn_bystander")
    mod = user("rn_mod", :moderator)

    report(rep1, :article, art.id)
    report(rep2, :article, art.id)

    {:ok, _count} = Moderation.resolve(:article, art.id, :content_removed, mod)

    [n1] = resolved_notifs(rep1)
    assert n1.actor_id == nil
    assert n1.subject_type == :article
    assert n1.subject_id == to_string(art.id)
    assert n1.metadata["outcome"] == "action_taken"

    assert [_] = resolved_notifs(rep2)
    assert resolved_notifs(bystander) == []
  end

  test "dismissed resolution yields a no_action outcome" do
    author = user("rn2_author")
    art = article(author)
    rep = user("rn2_rep")
    mod = user("rn2_mod", :moderator)

    report(rep, :article, art.id)
    {:ok, _} = Moderation.resolve(:article, art.id, :dismissed, mod)

    assert [n] = resolved_notifs(rep)
    assert n.metadata["outcome"] == "no_action"
  end

  test "a reporter who muted report_resolved gets nothing" do
    author = user("rn3_author")
    art = article(author)
    rep = user("rn3_rep")
    mod = user("rn3_mod", :moderator)

    rep
    |> Ash.Changeset.for_update(:update_notification_prefs, %{notification_prefs: %{"report_resolved" => false}},
      actor: rep
    )
    |> Ash.update!()

    report(rep, :article, art.id)
    {:ok, _} = Moderation.resolve(:article, art.id, :dismissed, mod)

    assert resolved_notifs(rep) == []
  end

  test "resolve still returns {:ok, count}" do
    author = user("rn4_author")
    art = article(author)
    report(user("rn4_rep"), :article, art.id)
    mod = user("rn4_mod", :moderator)

    assert {:ok, 1} = Moderation.resolve(:article, art.id, :dismissed, mod)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec app mix test test/verscienta/moderation/reporter_notifications_test.exs`
Expected: FAIL — notifications are not created (`:report_resolved` is not yet a valid type; `notify_reporters` does not exist).

- [ ] **Step 3: Add the notification type + subject_type**

In `lib/verscienta/notifications/notification.ex`, add `:report_resolved` to `@types` and `:room_message` to `@subject_types`:

```elixir
  @types [
    :followed,
    :reacted,
    :commented,
    :replied,
    :mentioned,
    :quest_completed,
    :streak_milestone,
    :leaderboard_rank_up,
    :badge_earned,
    :expert_application_approved,
    :expert_application_rejected,
    :report_resolved
  ]
  @subject_types [:user, :article, :comment, :quest, :streak, :leaderboard, :badge, :room_message]
```

- [ ] **Step 4: Add `notify_reporters/2` and call it in the resolve path**

In `lib/verscienta/moderation.ex`, in `do_resolve/5`, add the notify call after the existing `Ash.Notifier.notify(notifications)` line and before `{:ok, length(pending)}`:

```elixir
        Ash.Notifier.notify(notifications)
        notify_reporters(pending, resolution)

        {:ok, length(pending)}
```

Add the private helper (place it just after `do_resolve/5`, before `commit_resolution/8`):

```elixir
  # Best-effort: tell each distinct human reporter that their report was handled,
  # with a coarse, anonymous outcome (never the moderator or the exact sanction).
  # AI-sourced flags have a nil reporter_id and are skipped.
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

(`Verscienta.Notifications.notify/1` is best-effort — it rescues internally and checks the recipient's prefs — so a notification failure cannot change `resolve/5`'s `{:ok, count}` return.)

- [ ] **Step 5: Run test to verify it passes**

Run: `docker compose exec app mix test test/verscienta/moderation/reporter_notifications_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta/notifications/notification.ex lib/verscienta/moderation.ex test/verscienta/moderation/reporter_notifications_test.exs
git commit -m "feat(moderation): notify reporters when their report is resolved

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Notification rendering for `:report_resolved`

**Files:**
- Modify: `lib/verscienta_web/components/notification_components.ex`
- Test: `test/verscienta_web/components/notification_components_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/components/notification_components_test.exs`:

```elixir
defmodule VerscientaWeb.NotificationComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias VerscientaWeb.NotificationComponents

  describe "notification_phrase/1" do
    test "report_resolved action_taken" do
      phrase =
        NotificationComponents.notification_phrase(%{
          type: :report_resolved,
          metadata: %{"outcome" => "action_taken"}
        })

      assert phrase == "Your report was reviewed — action was taken."
    end

    test "report_resolved no_action (and missing outcome) falls to the neutral phrase" do
      assert NotificationComponents.notification_phrase(%{
               type: :report_resolved,
               metadata: %{"outcome" => "no_action"}
             }) == "Your report was reviewed — no action was needed."

      assert NotificationComponents.notification_phrase(%{type: :report_resolved, metadata: %{}}) ==
               "Your report was reviewed — no action was needed."
    end

    test "existing types still resolve via the delegating clause" do
      assert NotificationComponents.notification_phrase(%{type: :followed, metadata: %{}}) ==
               "followed you"
    end
  end

  describe "notification_item/1 for report_resolved" do
    test "renders the phrase and the excerpt, with no actor span and a /notifications link" do
      notification = %{
        id: "11111111-1111-1111-1111-111111111111",
        type: :report_resolved,
        read_at: nil,
        inserted_at: DateTime.utc_now(),
        metadata: %{"outcome" => "action_taken", "subject_excerpt" => "a spammy comment"}
      }

      html = render_component(&NotificationComponents.notification_item/1, %{notification: notification})

      assert html =~ "action was taken"
      assert html =~ "a spammy comment"
      refute html =~ "@"
      assert html =~ ~s(href="/notifications")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec app mix test test/verscienta_web/components/notification_components_test.exs`
Expected: FAIL — `notification_phrase/1` has no `report_resolved` clause; the item still calls `notification_phrase(@notification.type)`.

- [ ] **Step 3: Refactor `notification_phrase/1` + render the excerpt**

In `lib/verscienta_web/components/notification_components.ex`:

(a) Change the phrase call site in `notification_item/1` from:

```elixir
        <span class="text-ink-3">{notification_phrase(@notification.type)}</span>
```

to:

```elixir
        <span class="text-ink-3">{notification_phrase(@notification)}</span>
```

(b) Add an excerpt span immediately after the existing `article_title` span:

```elixir
        <span :if={@notification.metadata["article_title"]} class="text-ink">
          {@notification.metadata["article_title"]}
        </span>
        <span
          :if={@notification.metadata["subject_excerpt"] not in [nil, ""]}
          class="italic text-ink-2"
        >
          “{@notification.metadata["subject_excerpt"]}”
        </span>
```

(c) Add the three map-matching `notification_phrase` clauses ABOVE the existing atom clauses (just under `def notification_phrase(:followed)`'s `@doc false`):

```elixir
  @doc false
  def notification_phrase(%{type: :report_resolved, metadata: %{"outcome" => "action_taken"}}),
    do: "Your report was reviewed — action was taken."

  def notification_phrase(%{type: :report_resolved}),
    do: "Your report was reviewed — no action was needed."

  def notification_phrase(%{type: type}), do: notification_phrase(type)

  def notification_phrase(:followed), do: "followed you"
```

(Remove the now-duplicated `@doc false` that preceded `notification_phrase(:followed)` so there is exactly one. The existing atom clauses stay unchanged; the delegating `%{type: type}` clause routes every other notification map to them.)

> No `notification_accent/1` clause is needed — the existing `notification_accent(_)` default already returns `"bg-ink-3"` (the neutral accent) for `:report_resolved`. No `notification_href/1` clause is needed — `:report_resolved` carries no `article_slug`, so it falls through to the `/notifications` default.

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose exec app mix test test/verscienta_web/components/notification_components_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta_web/components/notification_components.ex test/verscienta_web/components/notification_components_test.exs
git commit -m "feat(moderation): render report_resolved notifications

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `Moderation` already-reported query helpers

**Files:**
- Modify: `lib/verscienta/moderation.ex`
- Test: `test/verscienta/moderation/reported_helpers_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/moderation/reported_helpers_test.exs`:

```elixir
defmodule Verscienta.Moderation.ReportedHelpersTest do
  use Verscienta.DataCase, async: true

  import Verscienta.Support.Factory, only: [user: 1, article: 1]

  alias Verscienta.Moderation
  alias Verscienta.Moderation.Flag

  defp report(actor, type, id) do
    Flag
    |> Ash.Changeset.for_create(:report, %{subject_type: type, subject_id: id, reason: :spam},
      actor: actor
    )
    |> Ash.create!(authorize?: true)
  end

  test "reported?/3 reflects whether the user reported the subject" do
    author = user("rh_author")
    art = article(author)
    rep = user("rh_rep")
    other = user("rh_other")

    refute Moderation.reported?(rep.id, :article, art.id)
    report(rep, :article, art.id)

    assert Moderation.reported?(rep.id, :article, art.id)
    refute Moderation.reported?(other.id, :article, art.id)
    refute Moderation.reported?(nil, :article, art.id)
  end

  test "reported_subject_ids/3 returns only the reported subset" do
    author = user("rh2_author")
    a1 = article(author)
    a2 = article(author)
    a3 = article(author)
    rep = user("rh2_rep")

    report(rep, :article, a1.id)
    report(rep, :article, a3.id)

    set = Moderation.reported_subject_ids(rep.id, :article, [a1.id, a2.id, a3.id])

    assert MapSet.member?(set, to_string(a1.id))
    refute MapSet.member?(set, to_string(a2.id))
    assert MapSet.member?(set, to_string(a3.id))
  end

  test "reported_subject_ids/3 is empty for a nil reporter or empty ids" do
    assert Moderation.reported_subject_ids(nil, :article, ["x"]) == MapSet.new()
    assert Moderation.reported_subject_ids("11111111-1111-1111-1111-111111111111", :article, []) ==
             MapSet.new()
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec app mix test test/verscienta/moderation/reported_helpers_test.exs`
Expected: FAIL — `Moderation.reported?/3` / `reported_subject_ids/3` are undefined.

- [ ] **Step 3: Add the helpers**

In `lib/verscienta/moderation.ex`, add these public functions (place them after `pending_groups/0`, near the other public query functions):

```elixir
  @doc """
  Whether `reporter_id` has already reported the single subject `{subject_type,
  subject_id}`. `nil` reporter (anonymous) is always false.
  """
  def reported?(nil, _subject_type, _subject_id), do: false

  def reported?(reporter_id, subject_type, subject_id) do
    Flag
    |> Ash.Query.filter(
      reporter_id == ^reporter_id and subject_type == ^subject_type and
        subject_id == ^subject_id
    )
    |> Ash.exists?(authorize?: false)
  end

  @doc """
  The MapSet of `subject_id`s (as strings, drawn from `ids`) that `reporter_id`
  has already reported for `subject_type`. One batched query. Empty for a nil
  reporter or empty `ids`.
  """
  def reported_subject_ids(nil, _subject_type, _ids), do: MapSet.new()
  def reported_subject_ids(_reporter_id, _subject_type, []), do: MapSet.new()

  def reported_subject_ids(reporter_id, subject_type, ids) do
    Flag
    |> Ash.Query.filter(
      reporter_id == ^reporter_id and subject_type == ^subject_type and subject_id in ^ids
    )
    |> Ash.Query.select([:subject_id])
    |> Ash.read!(authorize?: false)
    |> MapSet.new(&to_string(&1.subject_id))
  end
```

(`subject_id` is a `:uuid` attribute; Ash casts the incoming uuid-string `ids` for the `==` / `in` comparison. Returning `to_string(&1.subject_id)` normalizes for `MapSet.member?(set, to_string(id))` lookups in the templates.)

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose exec app mix test test/verscienta/moderation/reported_helpers_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta/moderation.ex test/verscienta/moderation/reported_helpers_test.exs
git commit -m "feat(moderation): reported?/3 + reported_subject_ids/3 query helpers

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `report_button` "already reported" state

**Files:**
- Modify: `lib/verscienta_web/components/report_dialog.ex`
- Test: `test/verscienta_web/live/report_dialog_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/verscienta_web/live/report_dialog_test.exs`. First read the file to match its existing harness (it already mounts the component in some host); add a focused render-component assertion. Append these tests inside the module (before the final `end`):

```elixir
  test "report_button renders the reported badge when reported?: true" do
    import Phoenix.LiveViewTest, only: [render_component: 2]

    html =
      render_component(&VerscientaWeb.ReportDialog.report_button/1, %{
        id: "rb-1",
        subject_type: :article,
        subject_id: "11111111-1111-1111-1111-111111111111",
        current_user: %{id: "22222222-2222-2222-2222-222222222222"},
        reported?: true
      })

    assert html =~ "reported"
    refute html =~ "⚐ report"
  end

  test "report_button renders the active button when reported?: false" do
    import Phoenix.LiveViewTest, only: [render_component: 2]

    html =
      render_component(&VerscientaWeb.ReportDialog.report_button/1, %{
        id: "rb-2",
        subject_type: :article,
        subject_id: "11111111-1111-1111-1111-111111111111",
        current_user: %{id: "22222222-2222-2222-2222-222222222222"},
        reported?: false
      })

    assert html =~ "⚐ report"
  end
```

> If `report_dialog_test.exs` does not exist, create it as
> `defmodule VerscientaWeb.ReportDialogTest do use ExUnit.Case, async: true` with
> the two tests above.

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec app mix test test/verscienta_web/live/report_dialog_test.exs`
Expected: FAIL — `report_button/1` does not accept `reported?`, so the badge does not show when `reported?: true`.

- [ ] **Step 3: Add the `reported?` attr + seed the done state**

In `lib/verscienta_web/components/report_dialog.ex`:

(a) Add the attr and forward it in `report_button/1`:

```elixir
  attr :id, :string, required: true
  attr :subject_type, :atom, required: true
  attr :subject_id, :string, required: true
  attr :current_user, :any, required: true
  attr :reported?, :boolean, default: false

  def report_button(assigns) do
    ~H"""
    <.live_component
      module={__MODULE__}
      id={@id}
      subject_type={@subject_type}
      subject_id={@subject_id}
      current_user={@current_user}
      reported?={@reported?}
    />
    """
  end
```

(b) Seed `done` from `reported?` in `update/2` (a DB-confirmed prior report shows the badge on mount; an in-session submit keeps `done: true`):

```elixir
  @impl true
  def update(assigns, socket) do
    done? = socket.assigns[:done] == true or assigns[:reported?] == true

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:done, done?)
     |> assign_new(:open, fn -> false end)}
  end
```

(The existing `mount/1` still sets `open: false, done: false`; `update/2` runs after and folds in `reported?`. The `submit` path still sets `done: true`. The render is unchanged — it already shows "reported" when `@done`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose exec app mix test test/verscienta_web/live/report_dialog_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta_web/components/report_dialog.ex test/verscienta_web/live/report_dialog_test.exs
git commit -m "feat(moderation): report_button reported? state

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Wire the article reader (article + comments)

**Files:**
- Modify: `lib/verscienta_web/live/article_reader_live.ex`
- Test: `test/verscienta_web/live/article_reader_live_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/verscienta_web/live/article_reader_live_test.exs` (match the file's existing helpers/imports; it uses `Verscienta.Support.Factory`). Add:

```elixir
  test "a user who already reported the article sees the reported state", %{conn: conn} do
    author = user("arr_author")
    art = article(author)
    reporter = user("arr_reporter")

    Verscienta.Moderation.Flag
    |> Ash.Changeset.for_create(:report, %{subject_type: :article, subject_id: art.id, reason: :spam},
      actor: reporter
    )
    |> Ash.create!(authorize?: true)

    {:ok, _lv, html} = live(sign_in(conn, reporter), ~p"/articles/#{art.slug}")

    assert html =~ "reported"
    refute html =~ "⚐ report"
  end

  test "a user who has NOT reported the article sees the active report button", %{conn: conn} do
    author = user("arr2_author")
    art = article(author)
    viewer = user("arr2_viewer")

    {:ok, _lv, html} = live(sign_in(conn, viewer), ~p"/articles/#{art.slug}")

    assert html =~ "⚐ report"
  end
```

> Confirm the test module imports `Verscienta.Support.Factory` (`user/1`, `article/1`, `sign_in/2`). If `sign_in/2` isn't imported there, add it to the existing `import Verscienta.Support.Factory, only: [...]`.

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec app mix test test/verscienta_web/live/article_reader_live_test.exs`
Expected: FAIL — the first test fails (the report button still renders `⚐ report` for a prior reporter on reload).

- [ ] **Step 3: Compute + pass `reported?`**

In `lib/verscienta_web/live/article_reader_live.ex`:

(a) In `mount/3`, after `comments = load_top_comments(article.id, actor && actor.id)` (line ~51), compute the reported sets and add them to the `assign(...)`:

```elixir
        comments = load_top_comments(article.id, actor && actor.id)
        viewer_id = actor && actor.id
```

Then add these two keys inside the existing `assign(...)` keyword list (e.g. after `reply_to: nil,`):

```elixir
           reply_to: nil,
           reported_article?: Verscienta.Moderation.reported?(viewer_id, :article, article.id),
           reported_comment_ids:
             Verscienta.Moderation.reported_subject_ids(viewer_id, :comment, comment_ids(comments)),
```

(b) Add the `comment_ids/1` helper (place near `mention_set/1`):

```elixir
  defp comment_ids(comments) do
    Enum.flat_map(comments, fn
      %{replies: replies} = c when is_list(replies) -> [c.id | Enum.map(replies, & &1.id)]
      c -> [c.id]
    end)
  end
```

(c) In `render/1`, pass `reported?` to the article report button (line ~405):

```elixir
        <.report_button
          :if={@current_user && @current_user.id != @article.author_id}
          id={"report-article-#{@article.id}"}
          subject_type={:article}
          subject_id={@article.id}
          current_user={@current_user}
          reported?={@reported_article?}
        />
```

(d) And to the comment report button (line ~538):

```elixir
              <.report_button
                :if={@current_user && @current_user.id != comment.user_id}
                id={"report-comment-#{comment.id}"}
                subject_type={:comment}
                subject_id={comment.id}
                current_user={@current_user}
                reported?={MapSet.member?(@reported_comment_ids, to_string(comment.id))}
              />
```

> A comment streamed in later (a new comment by another user, via `restream_comment`) is not in `@reported_comment_ids`, so it renders the active button — correct (the viewer hasn't reported a brand-new comment). A comment the viewer reports during the session flips the live_component's own `done` state immediately; on reload, `@reported_comment_ids` includes it.

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose exec app mix test test/verscienta_web/live/article_reader_live_test.exs`
Expected: PASS (no regressions in the existing reader tests).

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta_web/live/article_reader_live.ex test/verscienta_web/live/article_reader_live_test.exs
git commit -m "feat(moderation): reported state on the article reader (article + comments)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Wire the profile + room surfaces

**Files:**
- Modify: `lib/verscienta_web/live/profile_live.ex`
- Modify: `lib/verscienta_web/live/room_live.ex`
- Test: `test/verscienta_web/live/profile_social_test.exs` (or the existing profile LiveView test)

- [ ] **Step 1: Write the failing test**

Add a profile test. Find the existing profile LiveView test file (e.g. `test/verscienta_web/live/profile_social_test.exs` or `profile_activity_test.exs`) and add — matching its imports (`Verscienta.Support.Factory`):

```elixir
  test "a user who already reported a profile sees the reported state", %{conn: conn} do
    target = user("pr_target")
    reporter = user("pr_reporter")

    Verscienta.Moderation.Flag
    |> Ash.Changeset.for_create(:report, %{subject_type: :user, subject_id: target.id, reason: :spam},
      actor: reporter
    )
    |> Ash.create!(authorize?: true)

    {:ok, _lv, html} = live(sign_in(conn, reporter), ~p"/@#{target.username}")

    assert html =~ "reported"
    refute html =~ "⚐ report"
  end
```

> If no profile LiveView test file imports the helpers you need, create
> `test/verscienta_web/live/profile_report_test.exs` with the standard
> `use VerscientaWeb.ConnCase, async: true`, `import Phoenix.LiveViewTest`, and
> `import Verscienta.Support.Factory, only: [user: 1, sign_in: 2]`.

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec app mix test <the profile test file>`
Expected: FAIL — the profile report button ignores prior reports.

- [ ] **Step 3: Wire the profile**

In `lib/verscienta_web/live/profile_live.ex` `mount/3`, add a `reported_user?` assign (compute from `current_user`):

```elixir
    viewer = socket.assigns[:current_user]

    {:ok,
     socket
     |> assign(
       user: user,
       page_title: "@#{username}",
       seo:
         SEO.build(
           title: profile_display_name(user),
           description: profile_description(user),
           canonical: url(~p"/@#{to_string(user.username)}")
         ),
       streak: Profile.streak_for(user.id),
       best_rank: Profile.best_top10_rank(user.id),
       reported_user?: Verscienta.Moderation.reported?(viewer && viewer.id, :user, user.id)
     )
     |> assign_social()}
```

And pass it to the report button (line ~112):

```elixir
          <.report_button
            :if={@current_user && @current_user.id != @user.id}
            id={"report-user-#{@user.id}"}
            subject_type={:user}
            subject_id={@user.id}
            current_user={@current_user}
            reported?={@reported_user?}
          />
```

- [ ] **Step 4: Wire the room**

In `lib/verscienta_web/live/room_live.ex` `mount_room/4`, capture the messages, compute the reported set, assign it, and pass it per message. Change the end of `mount_room/4`:

```elixir
    messages = Communities.recent_messages(room)

    {:ok,
     socket
     |> assign(
       group: group,
       room: room,
       topic: topic,
       page_title: group.name,
       seo: VerscientaWeb.SEO.build(noindex: true),
       can_moderate: Communities.can_moderate?(user, group),
       present: presence_users(topic),
       typing: MapSet.new(),
       typing_timers: %{},
       reactions: [],
       reported_message_ids:
         Verscienta.Moderation.reported_subject_ids(
           user.id,
           :room_message,
           Enum.map(messages, & &1.id)
         )
     )
     |> stream(:messages, messages)}
```

And pass `reported?` to the message report button (line ~305):

```elixir
          <.report_button
            :if={@current_user && @current_user.id != m.user_id}
            id={"report-msg-#{m.id}"}
            subject_type={:room_message}
            subject_id={m.id}
            current_user={@current_user}
            reported?={MapSet.member?(@reported_message_ids, to_string(m.id))}
          />
```

> Messages arriving live via `handle_info({:new_message, message}, ...)` are not in
> `@reported_message_ids`, so they render the active button until the next page
> load — the accepted edge from the design.

- [ ] **Step 5: Run tests to verify they pass**

Run: `docker compose exec app mix test <the profile test file> test/verscienta_web/live/room_live_test.exs`
Expected: PASS (no regressions in the existing profile/room tests).

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta_web/live/profile_live.ex lib/verscienta_web/live/room_live.ex test/verscienta_web/live/
git commit -m "feat(moderation): reported state on profile + room report buttons

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Full verification + docs

**Files:**
- Modify: `docs/todo.md`

- [ ] **Step 1: Format + compile (warnings as errors)**

Run: `docker compose exec app mix format && docker compose exec app mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 2: Credo strict**

Run: `docker compose exec app mix credo --strict`
Expected: no issues. (If a new alias-ordering issue appears, fix it; the LiveView edits use fully-qualified `Verscienta.Moderation.*` to avoid this.)

- [ ] **Step 3: Run the focused suites**

Run: `docker compose exec app mix test test/verscienta/moderation/ test/verscienta_web/components/notification_components_test.exs test/verscienta_web/live/report_dialog_test.exs test/verscienta_web/live/article_reader_live_test.exs`
Expected: PASS.

- [ ] **Step 4: Run the full suite**

Run: `docker compose exec app mix test`
Expected: PASS, 0 failures.

- [ ] **Step 5: Check off the todo item**

In `docs/todo.md`, update the moderation fast-follows line to mark the two sub-items done. Change:

```
- [ ] Moderation fast-follows (deferred from slice 1): ~~rate-limit report submissions (Hammer, per-user)~~ *(done — per-user `report_user` bucket + dialog flash)*; reporter-resolution notifications; hide report affordance on already-reported subjects.
```

to:

```
- [x] Moderation fast-follows (deferred from slice 1): ~~rate-limit report submissions (Hammer, per-user)~~ *(done)*; reporter-resolution notifications *(done — anonymous coarse-outcome `:report_resolved` notification to each distinct human reporter on resolve)*; hide report affordance on already-reported subjects *(done — `Moderation.reported?/3` + `reported_subject_ids/3` feed a `reported?` state into `report_button` across article/comments/profile/room)*.
```

- [ ] **Step 6: Commit**

```bash
git add docs/todo.md
git commit -m "docs(moderation): check off moderation fast-follows

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review Notes

**Spec coverage:**
- Reporter-resolution notifications (anonymous, coarse outcome, distinct human reporters, AI flags skipped, prefs-gated) → Task 1.
- `:report_resolved` type + `:room_message` subject_type → Task 1.
- Notification rendering (outcome phrase, excerpt, no actor, neutral accent/default href) → Task 2.
- `reported?/3` + `reported_subject_ids/3` → Task 3.
- `report_button` `reported?` state → Task 4.
- All four surfaces wired (article, comments, profile, room) → Tasks 5–6.
- Tests for notify, rendering, helpers, component, and each surface → every task.
- Verification + todo check-off → Task 7.

**Out of scope (per spec), intentionally absent:** deep-linking resolution notifications; revealing the moderator/exact sanction; live-updating "already reported" for newly-streamed room messages; notifying the reported author. No migration (enum widenings are app-level over existing columns), no new resource, no new flag.
