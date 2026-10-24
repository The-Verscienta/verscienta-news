# Activity Feeds Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A public actor-action activity stream — `ActivityEvent`s emitted from existing action hooks, with Personal/Global feeds, a profile activity tab, real-time insert/remove via PubSub, and toggle-off removal + comment capping.

**Architecture:** A new `Verscienta.Social.ActivityEvent` resource (fan-in source of truth). `Social.emit_activity/1` (idempotent on `source_ref`) and `Social.remove_activity/1` are called best-effort from existing after-action hooks / toggle branches. Feeds are read-time queries. LiveViews use streams + a single `"activity"` PubSub topic for live insert/remove.

**Tech Stack:** Phoenix 1.8, Ash 3 + AshPostgres, Phoenix LiveView (streams), Phoenix.PubSub, Tailwind v4 (Codex tokens).

---

## Conventions for the executor

- **Run everything in Docker.** Mix in the app service: `docker compose run --rm -T app bash -lc "<cmd>"`. Start DB: `docker compose up -d db`. Generous timeouts. If "dependency not available", prefix `mix deps.get &&`.
- **One task at a time.** After each task run `git rev-parse --short HEAD` for the REAL sha. Never batch tasks or guess SHAs. **Re-run the FULL gate (`mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `MIX_ENV=test mix test`) after the FINAL edit of each task, BEFORE committing.**
- **Branch:** `activity-feeds` (already checked out; spec committed `2d6baf4`).
- **Line endings:** `.gitattributes` eol=lf, autocrlf false — don't change. `mix format` before commit. No `.bak`.
- **Git identity:** no local override. Commit body ends with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- **Migrations:** `mix ash.codegen <name>` AFTER the resource is defined + registered. Apply in test with `MIX_ENV=test mix ash.setup`. Never hand-write migrations.
- **Reuse patterns (read before editing):**
  - `Verscienta.Social` domain + helpers: `lib/verscienta/social.ex` (`require Ash.Query`, `topic/subscribe/broadcast`, `followed_user_ids/1`, `following_feed/2`). The PubSub server is `Verscienta.PubSub`.
  - Toggle idiom: `lib/verscienta/engagement/reaction.ex`, `lib/verscienta/social/repost.ex`, `lib/verscienta/social/follow.ex` (generic `action :toggle, :term` with a `run fn`).
  - After-action change pattern: `lib/verscienta/content/article/changes/award_publish.ex`, `lib/verscienta/engagement/comment/changes/broadcast_comment.ex`.
  - `Gamification.UserBadge` `:create`: `lib/verscienta/gamification/user_badge.ex` (no authorizer; accepts `user_id`, `badge_id`).
  - `Article` has `title`, `slug`, `:publish` action, `belongs_to :author`. `User` has `username`. Read `lib/verscienta/gamification/badge.ex` for the badge's display field name when needed.
  - Codex tokens: `text-ink`/`text-ink-2`/`text-ink-3`, `text-zune`/`bg-zune`, `border-line`.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `lib/verscienta/social/activity_event.ex` | `ActivityEvent` resource (verb/subject/source_ref/metadata) |
| `lib/verscienta/social.ex` | `emit_activity/1`, `remove_activity/1`, `get_activity/1`, `subscribe_activity/0`, snapshot helpers, feed queries |
| `lib/verscienta/engagement/reaction.ex` | emit/remove `:reacted` in toggle branches |
| `lib/verscienta/social/repost.ex` | emit/remove `:reposted` in toggle branches |
| `lib/verscienta/social/follow.ex` | emit/remove `:followed` (user targets) in toggle branches |
| `lib/verscienta/content/article/changes/emit_publish_activity.ex` | `:published` after-action change |
| `lib/verscienta/engagement/comment/changes/emit_comment_activity.ex` | `:commented` after-action change (capped) |
| `lib/verscienta/gamification/user_badge.ex` | `:earned_badge` after-action change |
| `lib/verscienta_web/components/social_components.ex` | `activity_item/1` + verb-phrase + relative-time helpers |
| `lib/verscienta_web/live/activity_live.ex` | `/activity` Personal/Global tabs + real-time |
| `lib/verscienta_web/live/profile_live.ex` | `:activity` live_action + `/@:username/activity` |
| `lib/verscienta_web/router.ex` | `/activity`, `/@:username/activity` routes |
| `lib/verscienta_web/components/layouts.ex` | "activity" nav link |
| `priv/repo/seeds.exs` | sample events |
| tests | per task |

---

## Task 1: `ActivityEvent` resource + Social emit/remove/get helpers (TDD)

**Files:**
- Create: `lib/verscienta/social/activity_event.ex`
- Modify: `lib/verscienta/social.ex`
- Test: `test/verscienta/social/activity_event_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/social/activity_event_test.exs`:
```elixir
defmodule Verscienta.Social.ActivityEventTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Social

  defp user(name) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com",
      username: name,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  test "emit_activity creates an event and is idempotent on source_ref" do
    u = user("amy")

    {:ok, ev} =
      Social.emit_activity(%{
        actor_id: u.id,
        verb: :followed,
        subject_type: :user,
        subject_id: to_string(u.id),
        source_ref: "follow:abc",
        metadata: %{"target_username" => "bob"}
      })

    assert ev.verb == :followed

    # Re-emit with the same source_ref → no duplicate row.
    {:ok, _} =
      Social.emit_activity(%{
        actor_id: u.id,
        verb: :followed,
        subject_type: :user,
        subject_id: to_string(u.id),
        source_ref: "follow:abc",
        metadata: %{}
      })

    all = Verscienta.Social.ActivityEvent |> Ash.read!(authorize?: false)
    assert length(all) == 1
  end

  test "remove_activity deletes by source_ref" do
    u = user("cleo")

    {:ok, _} =
      Social.emit_activity(%{
        actor_id: u.id,
        verb: :reacted,
        subject_type: :article,
        subject_id: "x",
        source_ref: "reaction:r1",
        metadata: %{}
      })

    assert :ok = Social.remove_activity("reaction:r1")
    assert Verscienta.Social.ActivityEvent |> Ash.read!(authorize?: false) == []
    # removing a missing ref is a no-op
    assert :ok = Social.remove_activity("reaction:nope")
  end

  test "get_activity loads the actor" do
    u = user("dan")

    {:ok, ev} =
      Social.emit_activity(%{
        actor_id: u.id,
        verb: :published,
        subject_type: :article,
        subject_id: "a1",
        source_ref: "article_published:a1",
        metadata: %{"article_title" => "T", "article_slug" => "t"}
      })

    loaded = Social.get_activity(ev.id)
    assert loaded.actor.id == u.id
  end
end
```

- [ ] **Step 2: Create the resource**

Create `lib/verscienta/social/activity_event.ex`:
```elixir
defmodule Verscienta.Social.ActivityEvent do
  @moduledoc "An immutable-ish actor-action event for the activity feed (created/removed only by the system)."
  use Ash.Resource,
    otp_app: :verscienta,
    domain: Verscienta.Social,
    data_layer: AshPostgres.DataLayer

  @verbs [:published, :followed, :reposted, :commented, :reacted, :earned_badge]
  @subject_types [:article, :user, :badge, :comment]

  def verbs, do: @verbs
  def subject_types, do: @subject_types

  postgres do
    table "activity_events"
    repo Verscienta.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:actor_id, :verb, :subject_type, :subject_id, :source_ref, :metadata]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :verb, :atom, allow_nil?: false, public?: true, constraints: [one_of: @verbs]

    attribute :subject_type, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: @subject_types]

    attribute :subject_id, :string, allow_nil?: false, public?: true
    attribute :source_ref, :string, allow_nil?: false, public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}, public?: true

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :actor, Verscienta.Accounts.User, allow_nil?: false
  end

  identities do
    identity :unique_source_ref, [:source_ref]
  end
end
```
NOTE: no authorizer (matches `Gamification.UserBadge`) — this is a system resource created/removed only via `Social` helpers (authorize?: false) and read with authorize?: false from LiveViews.

- [ ] **Step 3: Register the resource**

In `lib/verscienta/social.ex`, add to the `resources do` block:
```elixir
    resource Verscienta.Social.ActivityEvent
```

- [ ] **Step 4: Add the emit/remove/get/subscribe helpers**

In `lib/verscienta/social.ex`, add (inside the module; `require Ash.Query` is already present):
```elixir
  @activity_topic "activity"

  @doc "The PubSub topic for activity events."
  def activity_topic, do: @activity_topic

  @doc "Subscribe the caller to the activity topic."
  def subscribe_activity, do: Phoenix.PubSub.subscribe(Verscienta.PubSub, @activity_topic)

  @doc """
  Create an activity event (idempotent on `source_ref`) and broadcast it.
  Best-effort: never raises out to the calling action. `attrs` is a map with
  `:actor_id, :verb, :subject_type, :subject_id, :source_ref, :metadata`.
  """
  def emit_activity(%{source_ref: ref} = attrs) do
    case Verscienta.Social.ActivityEvent
         |> Ash.Query.filter(source_ref == ^ref)
         |> Ash.read_one!(authorize?: false) do
      nil ->
        event =
          Verscienta.Social.ActivityEvent
          |> Ash.Changeset.for_create(:create, attrs)
          |> Ash.create!(authorize?: false)

        Phoenix.PubSub.broadcast(Verscienta.PubSub, @activity_topic, {:activity, event.id})
        {:ok, event}

      existing ->
        {:ok, existing}
    end
  rescue
    _ -> :ok
  end

  @doc "Remove the activity event with `source_ref` (best-effort) and broadcast its removal."
  def remove_activity(source_ref) do
    case Verscienta.Social.ActivityEvent
         |> Ash.Query.filter(source_ref == ^source_ref)
         |> Ash.read_one!(authorize?: false) do
      nil ->
        :ok

      event ->
        Ash.destroy!(event, authorize?: false)
        Phoenix.PubSub.broadcast(Verscienta.PubSub, @activity_topic, {:activity_removed, event.id})
        :ok
    end
  rescue
    _ -> :ok
  end

  @doc "Load an activity event (with its actor) by id, or nil."
  def get_activity(id) do
    Verscienta.Social.ActivityEvent
    |> Ash.get!(id, load: [:actor], authorize?: false)
  rescue
    _ -> nil
  end

  @doc "Metadata snapshot for an article subject."
  def article_snapshot(%{title: title, slug: slug}),
    do: %{"article_title" => title, "article_slug" => slug}
```

- [ ] **Step 5: Generate migration + set up the test DB**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "mix ash.codegen add_activity_events && MIX_ENV=test mix ash.setup"
```
Expected: a migration creating `activity_events` with the unique `source_ref` index.

- [ ] **Step 6: Run the test**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/social/activity_event_test.exs"
```
Expected: 3 tests pass.

- [ ] **Step 7: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(activity): ActivityEvent resource + emit/remove/get helpers"
```
Then `git rev-parse --short HEAD`.

---

## Task 2: Feed query helpers (TDD)

**Files:**
- Modify: `lib/verscienta/social.ex`
- Test: `test/verscienta/social/activity_feeds_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/social/activity_feeds_test.exs`:
```elixir
defmodule Verscienta.Social.ActivityFeedsTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Social
  alias Verscienta.Social.Follow

  defp user(name) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com",
      username: name,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp emit(actor, ref) do
    {:ok, _} =
      Social.emit_activity(%{
        actor_id: actor.id,
        verb: :published,
        subject_type: :article,
        subject_id: ref,
        source_ref: "article_published:" <> ref,
        metadata: %{}
      })
  end

  defp follow!(actor, id) do
    Follow
    |> Ash.ActionInput.for_action(:toggle, %{target_type: :user, target_id: to_string(id)}, actor: actor)
    |> Ash.run_action!()
  end

  test "global_activity returns events newest-first" do
    a = user("ga1")
    emit(a, "x1")
    emit(a, "x2")
    ids = Social.global_activity(limit: 10) |> Enum.map(& &1.subject_id)
    assert "x1" in ids and "x2" in ids
  end

  test "personal_activity includes followed users AND self, excludes non-followed" do
    me = user("me_a")
    friend = user("friend_a")
    stranger = user("stranger_a")

    follow!(me, friend.id)
    emit(me, "mine")
    emit(friend, "friends")
    emit(stranger, "strangers")

    subjects = Social.personal_activity(me, limit: 50) |> Enum.map(& &1.subject_id)
    assert "mine" in subjects
    assert "friends" in subjects
    refute "strangers" in subjects
  end

  test "user_activity returns only that user's events" do
    a = user("ua1")
    b = user("ua2")
    emit(a, "a-evt")
    emit(b, "b-evt")

    subjects = Social.user_activity(a.id, limit: 50) |> Enum.map(& &1.subject_id)
    assert subjects == ["a-evt"]
  end
end
```

- [ ] **Step 2: Add the feed helpers**

In `lib/verscienta/social.ex`, add:
```elixir
  @doc "All activity events, newest first."
  def global_activity(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Verscienta.Social.ActivityEvent
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.load(:actor)
    |> Ash.read!(authorize?: false)
  end

  @doc "Activity by people `actor` follows, plus the actor's own, newest first."
  def personal_activity(actor, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    actor_ids = [actor.id | followed_user_ids(actor.id)]

    Verscienta.Social.ActivityEvent
    |> Ash.Query.filter(actor_id in ^actor_ids)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.load(:actor)
    |> Ash.read!(authorize?: false)
  end

  @doc "Activity by a single user, newest first."
  def user_activity(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Verscienta.Social.ActivityEvent
    |> Ash.Query.filter(actor_id == ^user_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.load(:actor)
    |> Ash.read!(authorize?: false)
  end
```
NOTE: `followed_user_ids/1` returns target_id strings; `[actor.id | strings]` mixes a UUID and strings in `actor_id in ^actor_ids` — Ash/Ecto casts the strings to uuid in the `in` clause (same pattern used in `following_feed/2`). If a cast error occurs, map all to `to_string/1` first; confirm via the test.

- [ ] **Step 3: Run the test**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/social/activity_feeds_test.exs"
```
Expected: 3 tests pass.

- [ ] **Step 4: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(activity): global/personal/user feed query helpers"
```
Then `git rev-parse --short HEAD`.

---

## Task 3: Emit `:reacted` + `:reposted` in toggle branches (TDD)

**Files:**
- Modify: `lib/verscienta/engagement/reaction.ex`, `lib/verscienta/social/repost.ex`
- Test: `test/verscienta/social/toggle_activity_test.exs`

- [ ] **Step 0: Read both toggle files** to see the exact create/destroy branches:
```powershell
docker compose run --rm -T app bash -lc "sed -n '/action :toggle/,/^    end/p' lib/verscienta/engagement/reaction.ex; echo '====='; sed -n '/action :toggle/,/^    end/p' lib/verscienta/social/repost.ex"
```

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/social/toggle_activity_test.exs`:
```elixir
defmodule Verscienta.Social.ToggleActivityTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Social

  defp user(name) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com",
      username: name,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp article(author) do
    Verscienta.Content.Article
    |> Ash.Changeset.for_create(:create, %{title: "T", excerpt: "e", category: :nutrition}, actor: author)
    |> Ash.create!()
  end

  defp react!(actor, article_id) do
    Verscienta.Engagement.Reaction
    |> Ash.ActionInput.for_action(:toggle, %{article_id: article_id, kind: :like}, actor: actor)
    |> Ash.run_action!()
  end

  defp repost!(actor, article_id) do
    Verscienta.Social.Repost
    |> Ash.ActionInput.for_action(:toggle, %{article_id: article_id}, actor: actor)
    |> Ash.run_action!()
  end

  defp verbs do
    Verscienta.Social.ActivityEvent |> Ash.read!(authorize?: false) |> Enum.map(& &1.verb)
  end

  test "reacting emits :reacted; un-reacting removes it" do
    u = user("react_u")
    art = article(user("react_auth"))

    react!(u, art.id)
    assert :reacted in verbs()

    react!(u, art.id)
    refute :reacted in verbs()
  end

  test "reposting emits :reposted; un-reposting removes it" do
    u = user("repost_u")
    art = article(user("repost_auth"))

    repost!(u, art.id)
    assert :reposted in verbs()

    repost!(u, art.id)
    refute :reposted in verbs()
  end
end
```

- [ ] **Step 2: Wire emit/remove into `Reaction.toggle`**

In `lib/verscienta/engagement/reaction.ex`, inside the `:toggle` `run fn`:
- In the **create branch** (`nil ->`), after the reaction is created (the `created` var) and after `maybe_award_author(...)`, add:
```elixir
              emit_reaction_activity(actor, article_id, created.id)
```
- In the **destroy branch** (`reaction ->`), after `Ash.destroy!(reaction, authorize?: false)`, add:
```elixir
              Verscienta.Social.remove_activity("reaction:" <> reaction.id)
```
Then add this private helper to the module (near `maybe_award_author/2`):
```elixir
  defp emit_reaction_activity(actor, article_id, reaction_id) do
    article = Ash.get!(Verscienta.Content.Article, article_id, authorize?: false)

    Verscienta.Social.emit_activity(%{
      actor_id: actor.id,
      verb: :reacted,
      subject_type: :article,
      subject_id: to_string(article_id),
      source_ref: "reaction:" <> reaction_id,
      metadata: Map.put(Verscienta.Social.article_snapshot(article), "kind", to_string(:like))
    })

    :ok
  rescue
    _ -> :ok
  end
```
NOTE: read the actual create/destroy branch variable names in Step 0 and match them (`created`, `reaction`). The kind is available as the `kind` variable in the run fn — use that instead of the hardcoded `:like` if it's in scope: `Map.put(..., "kind", to_string(kind))`. Keep `emit_*` best-effort (rescue) so a failure never breaks the toggle.

- [ ] **Step 3: Wire emit/remove into `Repost.toggle`**

In `lib/verscienta/social/repost.ex`, inside the `:toggle` `run fn`:
- In the create branch, in the `{:ok, created} ->` case (after the existing `broadcast`), add:
```elixir
                emit_repost_activity(actor, article_id, created.id)
```
- In the destroy branch (`repost ->`), after `Ash.destroy!(repost, authorize?: false)`, add:
```elixir
            Verscienta.Social.remove_activity("repost:" <> repost.id)
```
Add the private helper to the module:
```elixir
  defp emit_repost_activity(actor, article_id, repost_id) do
    article = Ash.get!(Verscienta.Content.Article, article_id, authorize?: false)

    Verscienta.Social.emit_activity(%{
      actor_id: actor.id,
      verb: :reposted,
      subject_type: :article,
      subject_id: to_string(article_id),
      source_ref: "repost:" <> repost_id,
      metadata: Verscienta.Social.article_snapshot(article)
    })

    :ok
  rescue
    _ -> :ok
  end
```

- [ ] **Step 4: Run the test**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/social/toggle_activity_test.exs"
```
Expected: 2 tests pass.

- [ ] **Step 5: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(activity): emit/remove :reacted and :reposted on toggle"
```
Then `git rev-parse --short HEAD`.

---

## Task 4: Emit `:followed` (user targets) in Follow toggle (TDD)

**Files:**
- Modify: `lib/verscienta/social/follow.ex`
- Test: `test/verscienta/social/follow_activity_test.exs`

- [ ] **Step 0: Read the Follow toggle** to see the create/destroy branches + the `type`/`id` vars:
```powershell
docker compose run --rm -T app bash -lc "sed -n '/action :toggle/,/^    end/p' lib/verscienta/social/follow.ex"
```

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/social/follow_activity_test.exs`:
```elixir
defmodule Verscienta.Social.FollowActivityTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Social.Follow

  defp user(name) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com",
      username: name,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp toggle!(actor, type, id) do
    Follow
    |> Ash.ActionInput.for_action(:toggle, %{target_type: type, target_id: to_string(id)}, actor: actor)
    |> Ash.run_action!()
  end

  defp events, do: Verscienta.Social.ActivityEvent |> Ash.read!(authorize?: false)

  test "following a user emits :followed; unfollowing removes it" do
    a = user("fa1")
    b = user("fa2")

    toggle!(a, :user, b.id)
    assert Enum.any?(events(), &(&1.verb == :followed))

    toggle!(a, :user, b.id)
    refute Enum.any?(events(), &(&1.verb == :followed))
  end

  test "following a category emits NO activity event" do
    a = user("fa3")
    toggle!(a, :category, "nutrition")
    refute Enum.any?(events(), &(&1.verb == :followed))
  end
end
```

- [ ] **Step 2: Wire emit/remove into `Follow.toggle`**

In `lib/verscienta/social/follow.ex`, inside the `:toggle` `run fn` `true ->` branch where the `case existing do` lives:
- In the **create branch** (`nil ->`), after the follow is created (the created record), add (only for user targets):
```elixir
                if type == :user, do: emit_follow_activity(actor, id, created_follow.id)
```
  (use the actual created-record variable name from Step 0; the plan's Follow toggle binds the create result — match it.)
- In the **destroy branch** (`follow ->`), after `Ash.destroy!(follow, authorize?: false)`, add:
```elixir
                if type == :user, do: Verscienta.Social.remove_activity("follow:" <> follow.id)
```
Add the private helper:
```elixir
  defp emit_follow_activity(actor, target_user_id, follow_id) do
    target = Ash.get!(Verscienta.Accounts.User, target_user_id, authorize?: false)

    Verscienta.Social.emit_activity(%{
      actor_id: actor.id,
      verb: :followed,
      subject_type: :user,
      subject_id: to_string(target_user_id),
      source_ref: "follow:" <> follow_id,
      metadata: %{"target_username" => to_string(target.username)}
    })

    :ok
  rescue
    _ -> :ok
  end
```
NOTE: In the current Follow toggle, the create branch returns the created record directly (e.g. it may be bound as `created` or be the last expression). Read Step 0 and bind the created follow to a variable so you can pass `.id`. The `result =` assignment in the toggle must still return the same record. The remove uses the existing `follow` record's id (bound in the destroy branch). Keep `emit_follow_activity` best-effort.

- [ ] **Step 3: Run the test**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/social/follow_activity_test.exs"
```
Expected: 2 tests pass.

- [ ] **Step 4: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(activity): emit/remove :followed on user follow toggle"
```
Then `git rev-parse --short HEAD`.

---

## Task 5: Emit `:published`, `:commented` (capped), `:earned_badge` (TDD)

**Files:**
- Create: `lib/verscienta/content/article/changes/emit_publish_activity.ex`, `lib/verscienta/engagement/comment/changes/emit_comment_activity.ex`, `lib/verscienta/gamification/user_badge/changes/emit_badge_activity.ex`
- Modify: `lib/verscienta/content/article.ex` (`:publish`), `lib/verscienta/engagement/comment.ex` (`:create`), `lib/verscienta/gamification/user_badge.ex` (`:create`)
- Test: `test/verscienta/social/persistent_activity_test.exs`

- [ ] **Step 0: Read the three actions + the Badge resource**
```powershell
docker compose run --rm -T app bash -lc "sed -n '/update :publish/,/end/p' lib/verscienta/content/article.ex; echo '==='; sed -n '/create :create/,/end/p' lib/verscienta/engagement/comment.ex; echo '==='; cat lib/verscienta/gamification/badge.ex"
```
Note: the `:publish` action's existing `change` list (you'll append a new change); the Comment `:create` action's change list (it already has `BroadcastComment`); the Badge resource's display field name (e.g. `:name`, `:label`, or `:title`) — use it for the badge snapshot.

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/social/persistent_activity_test.exs`:
```elixir
defmodule Verscienta.Social.PersistentActivityTest do
  use Verscienta.DataCase, async: true

  defp user(name) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com",
      username: name,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp events_with(verb),
    do: Verscienta.Social.ActivityEvent |> Ash.read!(authorize?: false) |> Enum.filter(&(&1.verb == verb))

  test "publishing an article emits :published" do
    author = user("pub_auth")

    art =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: "Pub", excerpt: "e", category: :nutrition}, actor: author)
      |> Ash.create!()

    art |> Ash.Changeset.for_update(:publish, %{}, actor: author) |> Ash.update!()

    assert length(events_with(:published)) == 1
  end

  test "commenting emits :commented, capped to one per (user, article)" do
    author = user("c_auth")

    art =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: "C", excerpt: "e", category: :nutrition}, actor: author)
      |> Ash.create!()

    art |> Ash.Changeset.for_update(:publish, %{}, actor: author) |> Ash.update!()

    commenter = user("commenter")

    for body <- ["first", "second"] do
      Verscienta.Engagement.Comment
      |> Ash.Changeset.for_create(:create, %{article_id: art.id, body: body}, actor: commenter)
      |> Ash.create!()
    end

    # capped: two comments by the same user on the same article → one event
    assert length(events_with(:commented)) == 1
  end
end
```

- [ ] **Step 2: Create the publish-activity change**

Create `lib/verscienta/content/article/changes/emit_publish_activity.ex`:
```elixir
defmodule Verscienta.Content.Article.Changes.EmitPublishActivity do
  @moduledoc "After-action: emit a :published activity event (best-effort)."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _cs, article ->
      if article.author_id do
        Verscienta.Social.emit_activity(%{
          actor_id: article.author_id,
          verb: :published,
          subject_type: :article,
          subject_id: to_string(article.id),
          source_ref: "article_published:" <> article.id,
          metadata: Verscienta.Social.article_snapshot(article)
        })
      end

      {:ok, article}
    end)
  end
end
```
Then in `lib/verscienta/content/article.ex`, add to the `:publish` action's changes (alongside the existing ones):
```elixir
      change Verscienta.Content.Article.Changes.EmitPublishActivity
```

- [ ] **Step 3: Create the comment-activity change (capped)**

Create `lib/verscienta/engagement/comment/changes/emit_comment_activity.ex`:
```elixir
defmodule Verscienta.Engagement.Comment.Changes.EmitCommentActivity do
  @moduledoc "After-action: emit a :commented activity event, capped to one per (user, article)."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _cs, comment ->
      article = Ash.get!(Verscienta.Content.Article, comment.article_id, authorize?: false)

      Verscienta.Social.emit_activity(%{
        actor_id: comment.user_id,
        verb: :commented,
        subject_type: :article,
        subject_id: to_string(comment.article_id),
        source_ref: "comment:" <> comment.user_id <> ":" <> comment.article_id,
        metadata: Verscienta.Social.article_snapshot(article)
      })

      {:ok, comment}
    end)
  rescue
    _ -> Ash.Changeset.after_action(changeset, fn _cs, comment -> {:ok, comment} end)
  end
end
```
NOTE: the `source_ref` keys on `(user_id, article_id)` so the second comment dedupes (cap). `emit_activity` is itself best-effort, but wrap the `Ash.get!` defensively. Then in `lib/verscienta/engagement/comment.ex`, add to the `:create` action's changes (alongside `BroadcastComment`):
```elixir
    change Verscienta.Engagement.Comment.Changes.EmitCommentActivity
```

- [ ] **Step 4: Create the badge-activity change**

Create `lib/verscienta/gamification/user_badge/changes/emit_badge_activity.ex`:
```elixir
defmodule Verscienta.Gamification.UserBadge.Changes.EmitBadgeActivity do
  @moduledoc "After-action: emit an :earned_badge activity event (best-effort)."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _cs, user_badge ->
      badge = Ash.get!(Verscienta.Gamification.Badge, user_badge.badge_id, authorize?: false)

      Verscienta.Social.emit_activity(%{
        actor_id: user_badge.user_id,
        verb: :earned_badge,
        subject_type: :badge,
        subject_id: to_string(user_badge.badge_id),
        source_ref: "userbadge:" <> user_badge.id,
        metadata: %{"badge_label" => badge_label(badge)}
      })

      {:ok, user_badge}
    end)
  rescue
    _ -> Ash.Changeset.after_action(changeset, fn _cs, ub -> {:ok, ub} end)
  end

  # Use the Badge resource's actual display field (read badge.ex in Step 0).
  defp badge_label(%{} = badge), do: to_string(Map.get(badge, :name) || Map.get(badge, :label) || Map.get(badge, :title) || "badge")
end
```
NOTE: replace `badge_label/1` with the real display field once you've read `badge.ex` (Step 0) — prefer a direct field access (e.g. `badge.name`). Then in `lib/verscienta/gamification/user_badge.ex`, add to the `:create` action:
```elixir
    change Verscienta.Gamification.UserBadge.Changes.EmitBadgeActivity
```

- [ ] **Step 5: Run the test**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/social/persistent_activity_test.exs"
```
Expected: 2 tests pass. (The badge path is exercised indirectly by the full suite's gamification tests; the explicit assertions here cover publish + comment cap.)

- [ ] **Step 6: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(activity): emit :published, :commented (capped), :earned_badge"
```
Then `git rev-parse --short HEAD`.

---

## Task 6: `activity_item` component + verb-phrase + relative-time helpers (TDD)

**Files:**
- Modify: `lib/verscienta_web/components/social_components.ex`
- Test: `test/verscienta_web/components/activity_item_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/components/activity_item_test.exs`:
```elixir
defmodule VerscientaWeb.ActivityItemTest do
  use VerscientaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import VerscientaWeb.SocialComponents

  defp event(verb, metadata, actor_username) do
    %{
      id: "evt1",
      verb: verb,
      subject_type: :article,
      subject_id: "a1",
      metadata: metadata,
      inserted_at: ~U[2026-06-02 12:00:00.000000Z],
      actor: %{username: actor_username}
    }
  end

  test "renders a :published activity line with actor and article link" do
    html =
      render_component(&activity_item/1, %{
        event: event(:published, %{"article_title" => "Hello", "article_slug" => "hello"}, "alice")
      })

    assert html =~ "@alice"
    assert html =~ "published"
    assert html =~ "Hello"
    assert html =~ ~s(href="/articles/hello")
  end

  test "renders a :followed line with target username link" do
    html =
      render_component(&activity_item/1, %{
        event: %{
          id: "evt2",
          verb: :followed,
          subject_type: :user,
          subject_id: "u2",
          metadata: %{"target_username" => "bob"},
          inserted_at: ~U[2026-06-02 12:00:00.000000Z],
          actor: %{username: "alice"}
        }
      })

    assert html =~ "followed"
    assert html =~ ~s(href="/@bob")
  end
end
```

- [ ] **Step 2: Add the component + helpers**

In `lib/verscienta_web/components/social_components.ex`, add (the module already `use Phoenix.Component`; add `use VerscientaWeb, :verified_routes` if `~p` is needed, OR build paths as plain strings to avoid the dependency — this plan uses plain-string hrefs to keep the component self-contained):
```elixir
  @doc "Renders one activity feed line: @actor <verb phrase> <object> · <relative time>."
  attr :event, :map, required: true
  attr :id, :string, default: nil

  def activity_item(assigns) do
    ~H"""
    <div id={@id || ("activity-" <> @event.id)} class="flex items-baseline gap-2 border-b border-line py-3 text-sm">
      <a href={"/@" <> to_string(@event.actor.username)} class="font-medium text-ink hover:text-zune">
        @{@event.actor.username}
      </a>
      <span class="text-ink-3">{activity_verb_phrase(@event.verb)}</span>
      {activity_object(assigns)}
      <span class="ml-auto text-[11px] text-ink-3">{activity_relative_time(@event.inserted_at)}</span>
    </div>
    """
  end

  defp activity_object(%{event: %{verb: :followed, metadata: meta}} = assigns) do
    assigns = assign(assigns, :username, meta["target_username"])

    ~H"""
    <a href={"/@" <> to_string(@username)} class="text-ink hover:text-zune">@{@username}</a>
    """
  end

  defp activity_object(%{event: %{verb: :earned_badge, metadata: meta}} = assigns) do
    assigns = assign(assigns, :label, meta["badge_label"])

    ~H"""
    <span class="text-ink">{@label}</span>
    """
  end

  defp activity_object(%{event: %{metadata: meta}} = assigns) do
    assigns =
      assigns
      |> assign(:title, meta["article_title"])
      |> assign(:slug, meta["article_slug"])

    ~H"""
    <a href={"/articles/" <> to_string(@slug)} class="text-ink hover:text-zune">{@title}</a>
    """
  end

  @doc false
  def activity_verb_phrase(:published), do: "published"
  def activity_verb_phrase(:followed), do: "followed"
  def activity_verb_phrase(:reposted), do: "reposted"
  def activity_verb_phrase(:commented), do: "commented on"
  def activity_verb_phrase(:reacted), do: "reacted to"
  def activity_verb_phrase(:earned_badge), do: "earned the badge"
  def activity_verb_phrase(_), do: "did something with"

  @doc false
  def activity_relative_time(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  def activity_relative_time(_), do: ""
```
NOTE: `activity_object/1` is a private function component dispatched by verb (article subjects for published/reposted/commented/reacted; user for followed; badge label for earned_badge). Usernames/slugs/titles come from the metadata snapshot and render as escaped text; hrefs are built from safe charsets. If `render_component` can't call the private `activity_object/1`, inline the verb-branching inside `activity_item/1` with `<%= cond/case %>` instead — the public surface is just `activity_item/1`.

- [ ] **Step 3: Run the test**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/components/activity_item_test.exs"
```
Expected: 2 tests pass.

- [ ] **Step 4: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(activity): activity_item component + verb/time helpers"
```
Then `git rev-parse --short HEAD`.

---

## Task 7: `/activity` LiveView (Personal/Global tabs + real-time) + route + nav (TDD)

**Files:**
- Create: `lib/verscienta_web/live/activity_live.ex`
- Modify: `lib/verscienta_web/router.ex`, `lib/verscienta_web/components/layouts.ex`
- Test: `test/verscienta_web/live/activity_live_test.exs`

- [ ] **Step 1: Add the route**

In `lib/verscienta_web/router.ex`, inside the `:public_routes` `live_session` (the one with the optional current_user on_mount, alongside `/articles`, `/search`), add:
```elixir
      live "/activity", ActivityLive, :index
```

- [ ] **Step 2: Write the failing test**

Create `test/verscienta_web/live/activity_live_test.exs`:
```elixir
defmodule VerscientaWeb.ActivityLiveTest do
  use VerscientaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias AshAuthentication.Plug.Helpers

  defp user(name) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com",
      username: name,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp sign_in(conn, u), do: conn |> Plug.Test.init_test_session(%{}) |> Helpers.store_in_session(u)

  defp emit(actor, ref) do
    Verscienta.Social.emit_activity(%{
      actor_id: actor.id,
      verb: :published,
      subject_type: :article,
      subject_id: ref,
      source_ref: "article_published:" <> ref,
      metadata: %{"article_title" => "Title " <> ref, "article_slug" => ref}
    })
  end

  test "global tab shows recent activity", %{conn: conn} do
    a = user("act_global")
    emit(a, "g1")

    {:ok, _view, html} = live(conn, ~p"/activity")
    assert html =~ "@act_global"
    assert html =~ "Title g1"
    assert html =~ "global"
    assert html =~ "personal"
  end

  test "personal tab prompts sign-in when signed out", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/activity?tab=personal")
    assert html =~ "sign in" or html =~ "Sign in"
  end

  test "live insert: a new event appears via broadcast", %{conn: conn} do
    a = user("act_live")
    {:ok, view, _html} = live(conn, ~p"/activity")

    emit(a, "live1")
    html = render(view)
    assert html =~ "Title live1"
  end
end
```

- [ ] **Step 3: Create the LiveView**

Create `lib/verscienta_web/live/activity_live.ex`:
```elixir
defmodule VerscientaWeb.ActivityLive do
  use VerscientaWeb, :live_view

  alias Verscienta.Social
  import VerscientaWeb.SocialComponents

  @tabs ~w(global personal)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Social.subscribe_activity()
    {:ok, assign(socket, page_title: "activity")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: "global"
    {:noreply, socket |> assign(:tab, tab) |> load_tab(tab)}
  end

  defp load_tab(socket, "personal") do
    case socket.assigns[:current_user] do
      nil ->
        socket
        |> assign(:needs_signin?, true)
        |> assign(:feed_actor_ids, [])
        |> stream(:activity, [], reset: true)

      user ->
        events = Social.personal_activity(user, limit: 50)

        socket
        |> assign(:needs_signin?, false)
        |> assign(:feed_actor_ids, [user.id | Social.followed_user_ids(user.id)])
        |> stream(:activity, events, reset: true)
    end
  end

  defp load_tab(socket, "global") do
    socket
    |> assign(:needs_signin?, false)
    |> assign(:feed_actor_ids, :all)
    |> stream(:activity, Social.global_activity(limit: 50), reset: true)
  end

  @impl true
  def handle_info({:activity, id}, socket) do
    event = Social.get_activity(id)

    if event && relevant?(socket, event) do
      {:noreply, stream_insert(socket, :activity, event, at: 0)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:activity_removed, id}, socket) do
    {:noreply, stream_delete_by_dom_id(socket, :activity, "activity-" <> id)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp relevant?(%{assigns: %{needs_signin?: true}}, _event), do: false
  defp relevant?(%{assigns: %{feed_actor_ids: :all}}, _event), do: true
  defp relevant?(%{assigns: %{feed_actor_ids: ids}}, event), do: event.actor_id in ids

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl px-6 pt-24">
      <nav aria-label="activity tabs" class="mb-8 flex gap-5 text-xs lowercase tracking-wider text-ink-3">
        <.link
          :for={t <- ~w(global personal)}
          patch={"/activity?tab=" <> t}
          class={[@tab == t && "text-zune", @tab != t && "hover:text-ink"]}
        >
          {t}
        </.link>
      </nav>

      <div :if={@needs_signin?} class="py-16 text-center text-ink-3">
        <p>sign in to see activity from people you follow.</p>
        <a href="/sign-in" class="mt-3 inline-block text-zune hover:text-ink">sign in</a>
      </div>

      <div :if={not @needs_signin?} id="activity-feed" phx-update="stream">
        <.activity_item :for={{dom_id, event} <- @streams.activity} id={dom_id} event={event} />
      </div>
    </div>
    """
  end
end
```
NOTE on stream DOM ids: the stream is named `:activity`, so LiveView's default dom id for each item is `"activity-<event.id>"` — which exactly matches the removal target `stream_delete_by_dom_id(:activity, "activity-" <> id)` and `activity_item/1`'s default root id. Pass the stream's `dom_id` to the component (`id={dom_id}`) so the rendered node id and the stream's tracking id are identical. No custom `dom_id:` config needed because the stream name is `activity`. `activity_item/1` already accepts the `id` attr (Task 6). Verify the live-insert and removal both work in the test.

- [ ] **Step 4: Add the nav link**

In `lib/verscienta_web/components/layouts.ex`, in `nav_links/1`, add an "activity" link (place near "search"):
```elixir
    <a href="/activity" class="transition-colors hover:text-ink">activity</a>
```

- [ ] **Step 5: Run the test**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/activity_live_test.exs"
```
Expected: 3 tests pass. If the live-insert test is flaky because the broadcast races the mount subscription, ensure `subscribe_activity()` runs in `mount` under `connected?/1` (it does) and that the test asserts after `render(view)`.

- [ ] **Step 6: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(activity): /activity LiveView with Personal/Global tabs + real-time"
```
Then `git rev-parse --short HEAD`.

---

## Task 8: Profile activity tab (TDD)

**Files:**
- Modify: `lib/verscienta_web/live/profile_live.ex`, `lib/verscienta_web/router.ex`
- Test: `test/verscienta_web/live/profile_activity_test.exs`

- [ ] **Step 0: Read `profile_live.ex`** to see the existing `mount/3`, `handle_params/3`, live_actions (`:show`, `:followers`, `:following`), the PubSub subscribe, and render structure.

- [ ] **Step 1: Add the route**

In `lib/verscienta_web/router.ex`, in the SAME authenticated live session block with the other profile routes, add:
```elixir
      live "/@:username/activity", ProfileLive, :activity
```

- [ ] **Step 2: Write the failing test**

Create `test/verscienta_web/live/profile_activity_test.exs`:
```elixir
defmodule VerscientaWeb.ProfileActivityTest do
  use VerscientaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias AshAuthentication.Plug.Helpers

  defp user(name) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com",
      username: name,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp sign_in(conn, u), do: conn |> Plug.Test.init_test_session(%{}) |> Helpers.store_in_session(u)

  test "profile activity tab shows that user's events", %{conn: conn} do
    target = user("pa_target")
    viewer = user("pa_viewer")

    Verscienta.Social.emit_activity(%{
      actor_id: target.id,
      verb: :published,
      subject_type: :article,
      subject_id: "pa1",
      source_ref: "article_published:pa1",
      metadata: %{"article_title" => "Their Post", "article_slug" => "pa1"}
    })

    {:ok, _view, html} = conn |> sign_in(viewer) |> live(~p"/@pa_target/activity")
    assert html =~ "Their Post"
    assert html =~ "published"
  end
end
```

- [ ] **Step 3: Handle the `:activity` live_action in `ProfileLive`**

In `lib/verscienta_web/live/profile_live.ex`:
- The profile already subscribes to `Social.subscribe(user.id)` in mount. ADD `if connected?(socket), do: Social.subscribe_activity()` in mount as well (so activity events stream in). Keep the existing subscribe.
- Extend `handle_params/3` so the `:activity` action loads a stream of the profile user's activity. Since the existing `handle_params` assigns `:social_list`, add a parallel branch that, for `:activity`, sets up a stream:
```elixir
  @impl true
  def handle_params(_params, _uri, socket) do
    socket =
      socket
      |> assign(:social_list, list_for(socket))
      |> maybe_load_activity()

    {:noreply, socket}
  end

  defp maybe_load_activity(%{assigns: %{live_action: :activity, user: user}} = socket) do
    stream(socket, :activity, Verscienta.Social.user_activity(user.id, limit: 50), reset: true)
  end

  defp maybe_load_activity(socket), do: stream(socket, :activity, [], reset: true)
```
- Add handle_info for activity events (prepend only if the event's actor is this profile user):
```elixir
  @impl true
  def handle_info({:activity, id}, socket) do
    event = Verscienta.Social.get_activity(id)

    if event && event.actor_id == socket.assigns.user.id do
      {:noreply, stream_insert(socket, :activity, event, at: 0)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:activity_removed, id}, socket) do
    {:noreply, stream_delete_by_dom_id(socket, :activity, "activity-" <> id)}
  end
```
  (Keep the EXISTING `{:followers_changed,_}`/`{:following_changed,_}`/catch-all handle_info clauses — add these alongside them; ensure the catch-all stays LAST.)
- In the render, add an activity section shown for the `:activity` action (and a tab link near the followers/following counts):
```heex
<div :if={@live_action == :activity} class="mt-8" id="profile-activity" phx-update="stream">
  <.activity_item :for={{dom_id, event} <- @streams.activity} id={dom_id} event={event} />
</div>
```
Add an "activity" link near the existing followers/following links:
```heex
<.link navigate={~p"/@#{@user.username}/activity"} class="hover:text-ink">activity</.link>
```
NOTE: `import VerscientaWeb.SocialComponents` is already in ProfileLive (from the social-graph work) — `activity_item/1` is available. Use the SAME stream dom-id scheme as Task 7 (`"activity-" <> event.id`) so removals line up. If the profile uses `:if` to gate the followers/following list block, gate the activity block the same way. Ensure streams are always initialized (the `maybe_load_activity/1` fallback streams `[]`) so the render never references an uninitialized stream.

- [ ] **Step 4: Run the test**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/profile_activity_test.exs"
```
Expected: 1 test passes. Run the existing profile tests too:
```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/profile_social_test.exs test/verscienta_web/live/profile_activity_test.exs"
```

- [ ] **Step 5: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(activity): profile activity tab at /@:username/activity"
```
Then `git rev-parse --short HEAD`.

---

## Task 9: Seeds + todo + full verification + merge prep

**Files:**
- Modify: `priv/repo/seeds.exs`, `docs/todo.md`

- [ ] **Step 1: Read the seeds** to match style:
```powershell
docker compose run --rm -T app bash -lc "tail -40 priv/repo/seeds.exs"
```

- [ ] **Step 2: Append idempotent activity seeds**

At the end of `priv/repo/seeds.exs`, emit a couple of sample events (idempotent via `source_ref`). Activity events are also generated naturally by the existing follow/repost seeds, but add an explicit publish event for visibility. Adapt to the seeded users/articles present:
```elixir
# --- Activity feed seeds (idempotent via source_ref) ---
case Verscienta.Content.Article
     |> Ash.Query.filter(status == :published)
     |> Ash.read!(authorize?: false) do
  [%{author_id: author_id} = art | _] when not is_nil(author_id) ->
    Verscienta.Social.emit_activity(%{
      actor_id: author_id,
      verb: :published,
      subject_type: :article,
      subject_id: to_string(art.id),
      source_ref: "article_published:" <> art.id,
      metadata: Verscienta.Social.article_snapshot(art)
    })

  _ ->
    :ok
end
```
(`require Ash.Query` is already at the top of the seeds from the social-graph work; reuse it.)

- [ ] **Step 3: Tick the todo items**

In `docs/todo.md`, under "### Activity Feeds", update the four lines (read the exact wording first; only flip `[ ]`→`[x]` and append notes):
```markdown
- [x] Activity event model (fan-out or fan-in strategy decided + documented). *(fan-in; see spec)*
- [x] Personal activity feed (things you follow). *(plus your own activity)*
- [x] Global activity feed.
- [x] Real-time feed updates via Phoenix PubSub. *(LiveView streams; insert + toggle-off removal)*
```

- [ ] **Step 4: Full clean-deps gate**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "mix deps.get && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
```
Expected: format clean, credo 0 issues, no warnings, ALL tests pass. Capture the exact `N tests, 0 failures` line.

- [ ] **Step 5: Commit**

```powershell
git add -A
git commit -m "feat(activity): seeds + todo updates for activity feeds"
```
Then `git rev-parse --short HEAD`.

---

## Definition of Done (verify all)

- [ ] `ActivityEvent` (with `source_ref` unique identity) in `Verscienta.Social`; migration applied; domain registered.
- [ ] All 6 actions emit events via best-effort hooks; toggle-off (react/follow/repost) removes the event; comments capped to one per (actor, article); publish/badge persist.
- [ ] `global_activity`/`personal_activity` (follows + self)/`user_activity` query helpers correct.
- [ ] `/activity` Personal/Global tabs (Personal gated to signed-in); `/@:username/activity` profile tab.
- [ ] New events appear and toggle-removed events disappear in real time (PubSub + LiveView streams), filtered per feed.
- [ ] `activity_item` rendering is XSS-safe (snapshot strings escaped; safe hrefs) and resilient to deleted subjects.
- [ ] "activity" nav link present.
- [ ] `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test` all pass.
- [ ] Migration via `mix ash.codegen`; `docs/todo.md` updated; work committed on `activity-feeds`.
