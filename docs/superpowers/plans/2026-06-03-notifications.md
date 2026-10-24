# Notifications Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A private, in-app notifications system — a `Notification` resource emitted best-effort from action hooks to the affected user, with read state, per-type preferences, a `/notifications` center, and a real-time nav bell.

**Architecture:** New `Verscienta.Notifications` domain with a recipient-scoped `Notification` resource (recipient-only policies). `Notifications.notify/1` (skip-self, preference-aware, best-effort) is called from the existing Follow/Reaction/Comment hooks. Per-type preferences live as a `notification_prefs` map on `User`. Real-time via a `notifications:<user_id>` PubSub topic feeding a `/notifications` LiveView and a nested `NotificationBellLive` in the root layout.

**Tech Stack:** Phoenix 1.8, Ash 3 + AshPostgres, Phoenix LiveView (streams + `live_render`), Phoenix.PubSub, Tailwind v4 (Codex tokens).

---

## Conventions for the executor

- **Run everything in Docker.** `docker compose run --rm -T app bash -lc "<cmd>"`. Start DB: `docker compose up -d db`. Generous timeouts. If "dependency not available", prefix `mix deps.get &&`.
- **One task at a time.** After each task run `git rev-parse --short HEAD` for the REAL sha. Never batch tasks or guess SHAs. **Re-run the FULL gate (`mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `MIX_ENV=test mix test`) after the FINAL edit of each task, BEFORE committing.**
- **Branch:** `notifications` (already checked out; spec committed `09574a6`).
- **Line endings:** `.gitattributes` eol=lf, autocrlf false — don't change. `mix format` before commit. No `.bak`.
- **Git identity:** no local override. Commit body ends with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- **Migrations:** `mix ash.codegen <name>` AFTER the resource/attribute is defined + registered. Apply in test with `MIX_ENV=test mix ash.setup`. Never hand-write migrations.
- **Reuse patterns (read before editing):**
  - Per-user PubSub + emit-from-hooks: `lib/verscienta/social.ex` (`emit_activity`, `topic/subscribe/broadcast`). PubSub server is `Verscienta.PubSub`.
  - Best-effort after-action change: `lib/verscienta/content/article/changes/emit_publish_activity.ex`.
  - Recipient/ownership policies: `Verscienta.Social.Follow` / `Engagement.Comment` (`authorize_if expr(... == ^actor(:id))`).
  - `Engagement.Comment` `:create` accepts `[:body, :article_id, :parent_id]`, relates actor as `:user`, has changes `ValidateParent`, `BroadcastComment`, `AwardComment`, `EmitCommentActivity` (you APPEND a `NotifyComment` change). `belongs_to :parent` (`parent_id`), `belongs_to :article`, `belongs_to :user`.
  - `Engagement.Reaction` `:toggle` and `Social.Follow` `:toggle` — generic actions with create/destroy branches (where activity is already emitted/removed).
  - `Social.Mentions` (`lib/verscienta/social/mentions.ex`) — has `@mention_regex` and a private existing-username lookup; you ADD a public `extract_existing_users/1`.
  - `User` (`lib/verscienta/accounts/user.ex`) — `update_profile` action + policies; you ADD `notification_prefs` + `update_notification_prefs`.
  - `Article` has `title`, `slug`, `author_id`. Settings LiveView + root layout + `nav_links/1` for UI wiring (read them in their tasks).
  - Codex accents: `text-zune`/`bg-zune`, plus metro accents available as Tailwind classes (`text-sport`, `text-business`, etc. — confirm names in `assets/css/app.css` / Category module when picking per-type colors).

---

## File Structure

| File | Responsibility |
|------|----------------|
| `lib/verscienta/notifications.ex` | domain + `notify/1`, `enabled?/2`, topic/subscribe/broadcast, `get/1`, `list/2`, `unread_count/1`, `mark_read/1`, `mark_all_read/1` |
| `lib/verscienta/notifications/notification.ex` | `Notification` resource (recipient-only policies) |
| `lib/verscienta/accounts/user.ex` | `notification_prefs` attr + `update_notification_prefs` action |
| `lib/verscienta/social/mentions.ex` | `extract_existing_users/1` |
| `lib/verscienta/social/follow.ex`, `lib/verscienta/engagement/reaction.ex` | call `notify/1` on create |
| `lib/verscienta/engagement/comment/changes/notify_comment.ex` | comment notifications (commented/replied/mentioned, deduped) |
| `lib/verscienta/engagement/comment.ex` | append `NotifyComment` change |
| `lib/verscienta_web/components/notification_components.ex` | `notification_item/1` + phrase/accent helpers |
| `lib/verscienta_web/live/notifications_live.ex` | `/notifications` center |
| `lib/verscienta_web/live/notification_bell_live.ex` | nested live nav bell |
| `lib/verscienta_web/components/layouts/root.html.heex` | `live_render` the bell |
| `lib/verscienta_web/live/settings_live.ex` | per-type preference toggles |
| `lib/verscienta_web/router.ex`, `config/config.exs` | route + domain registration |
| `priv/repo/seeds.exs`, tests | seeds + per-task tests |

---

## Task 1: `Notifications` domain + `Notification` resource (TDD)

**Files:**
- Create: `lib/verscienta/notifications/notification.ex`, `lib/verscienta/notifications.ex`
- Modify: `config/config.exs`
- Test: `test/verscienta/notifications/notification_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/notifications/notification_test.exs`:
```elixir
defmodule Verscienta.Notifications.NotificationTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Notifications.Notification

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

  defp create!(recipient, actor) do
    Notification
    |> Ash.Changeset.for_create(:create, %{
      recipient_id: recipient.id,
      actor_id: actor.id,
      type: :followed,
      subject_type: :user,
      subject_id: to_string(actor.id),
      metadata: %{"actor_username" => to_string(actor.username)}
    })
    |> Ash.create!(authorize?: false)
  end

  test "create + mark_read sets read_at" do
    r = user("recip1")
    a = user("actor1")
    n = create!(r, a)
    assert is_nil(n.read_at)

    updated = n |> Ash.Changeset.for_update(:mark_read, %{}, actor: r) |> Ash.update!()
    refute is_nil(updated.read_at)
  end

  test "a user can only read their own notifications" do
    r = user("recip2")
    a = user("actor2")
    other = user("other2")
    create!(r, a)

    # recipient sees it
    mine =
      Notification
      |> Ash.Query.for_read(:for_recipient, %{recipient_id: r.id}, actor: r)
      |> Ash.read!()

    assert length(mine) == 1

    # a different user reading the same recipient's feed gets nothing (policy filters)
    theirs =
      Notification
      |> Ash.Query.for_read(:for_recipient, %{recipient_id: r.id}, actor: other)
      |> Ash.read!()

    assert theirs == []
  end

  test "marking someone else's notification read is forbidden" do
    r = user("recip3")
    a = user("actor3")
    other = user("other3")
    n = create!(r, a)

    assert {:error, _} = n |> Ash.Changeset.for_update(:mark_read, %{}, actor: other) |> Ash.update()
  end
end
```
NOTE: `require Ash.Query` is provided by `Verscienta.DataCase`? If `Ash.Query` macros aren't available in the test, add `require Ash.Query` at the top of the test module.

- [ ] **Step 2: Create the resource**

Create `lib/verscienta/notifications/notification.ex`:
```elixir
defmodule Verscienta.Notifications.Notification do
  @moduledoc "A private, recipient-scoped notification."
  use Ash.Resource,
    otp_app: :verscienta,
    domain: Verscienta.Notifications,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @types [:followed, :reacted, :commented, :replied, :mentioned]
  @subject_types [:user, :article, :comment]

  def types, do: @types

  postgres do
    table "notifications"
    repo Verscienta.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [:recipient_id, :actor_id, :type, :subject_type, :subject_id, :metadata]
    end

    update :mark_read do
      accept []
      require_atomic? false
      change set_attribute(:read_at, &DateTime.utc_now/0)
    end

    read :for_recipient do
      argument :recipient_id, :uuid, allow_nil?: false
      filter expr(recipient_id == ^arg(:recipient_id))
      prepare build(sort: [inserted_at: :desc])
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(recipient_id == ^actor(:id))
    end

    policy action(:mark_read) do
      authorize_if expr(recipient_id == ^actor(:id))
    end

    policy action(:create) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :type, :atom, allow_nil?: false, public?: true, constraints: [one_of: @types]

    attribute :subject_type, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: @subject_types]

    attribute :subject_id, :string, allow_nil?: false, public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}, public?: true
    attribute :read_at, :utc_datetime_usec, allow_nil?: true, public?: true

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :recipient, Verscienta.Accounts.User, allow_nil?: false
    belongs_to :actor, Verscienta.Accounts.User, allow_nil?: false
  end
end
```

- [ ] **Step 3: Create the domain**

Create `lib/verscienta/notifications.ex`:
```elixir
defmodule Verscienta.Notifications do
  @moduledoc "Domain for private, recipient-scoped notifications."
  use Ash.Domain, otp_app: :verscienta

  resources do
    resource Verscienta.Notifications.Notification
  end
end
```

- [ ] **Step 4: Register the domain**

In `config/config.exs`, add `Verscienta.Notifications` to the `ash_domains` list (keep existing entries).

- [ ] **Step 5: Generate migration + set up test DB**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "mix ash.codegen add_notifications && MIX_ENV=test mix ash.setup"
```
Expected: a migration creating `notifications` (recipient_id, actor_id, type, subject_type, subject_id, metadata jsonb, read_at, inserted_at + FKs).

- [ ] **Step 6: Run the test**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/notifications/notification_test.exs"
```
Expected: 3 tests pass.

- [ ] **Step 7: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(notifications): Notification resource + domain (recipient-only)"
```
Then `git rev-parse --short HEAD`.

---

## Task 2: `User.notification_prefs` + update action (TDD)

**Files:**
- Modify: `lib/verscienta/accounts/user.ex`
- Test: `test/verscienta/accounts/notification_prefs_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/accounts/notification_prefs_test.exs`:
```elixir
defmodule Verscienta.Accounts.NotificationPrefsTest do
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

  test "notification_prefs defaults to an empty map" do
    u = user("prefs1")
    assert u.notification_prefs == %{}
  end

  test "owner can update their notification_prefs" do
    u = user("prefs2")

    updated =
      u
      |> Ash.Changeset.for_update(:update_notification_prefs, %{notification_prefs: %{"reacted" => false}},
        actor: u
      )
      |> Ash.update!()

    assert updated.notification_prefs == %{"reacted" => false}
  end

  test "a different user cannot update someone else's prefs" do
    u = user("prefs3")
    other = user("prefs3other")

    assert {:error, _} =
             u
             |> Ash.Changeset.for_update(:update_notification_prefs, %{notification_prefs: %{"reacted" => false}},
               actor: other
             )
             |> Ash.update()
  end
end
```

- [ ] **Step 2: Add the attribute + action + policy**

In `lib/verscienta/accounts/user.ex`:
- In the `attributes do` block, add:
```elixir
    attribute :notification_prefs, :map, allow_nil?: false, default: %{}, public?: true
```
- In the `actions do` block, add:
```elixir
    update :update_notification_prefs do
      description "Update the current user's per-type notification preferences."
      accept [:notification_prefs]
      require_atomic? false
    end
```
- In the `policies do` block, add (alongside the `update_profile` policy):
```elixir
    policy action(:update_notification_prefs) do
      authorize_if expr(id == ^actor(:id))
    end
```

- [ ] **Step 3: Generate migration + run the test**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "mix ash.codegen add_user_notification_prefs && MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta/accounts/notification_prefs_test.exs"
```
Expected: a migration adding the `notification_prefs` jsonb column (default `'{}'`); 3 tests pass.

- [ ] **Step 4: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(notifications): User notification_prefs + update action"
```
Then `git rev-parse --short HEAD`.

---

## Task 3: Notifications context — notify/enabled?/queries/real-time (TDD)

**Files:**
- Modify: `lib/verscienta/notifications.ex`
- Test: `test/verscienta/notifications/context_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/notifications/context_test.exs`:
```elixir
defmodule Verscienta.Notifications.ContextTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Notifications

  defp user(name, prefs \\ %{}) do
    u =
      Verscienta.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: name <> "@example.com",
        username: name,
        password: "password123",
        password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    if prefs == %{} do
      u
    else
      u
      |> Ash.Changeset.for_update(:update_notification_prefs, %{notification_prefs: prefs}, actor: u)
      |> Ash.update!()
    end
  end

  defp attrs(recipient, actor, type \\ :followed) do
    %{
      recipient_id: recipient.id,
      actor_id: actor.id,
      type: type,
      subject_type: :user,
      subject_id: to_string(actor.id),
      metadata: %{"actor_username" => to_string(actor.username)}
    }
  end

  test "notify creates a notification and unread_count reflects it" do
    r = user("c_recip")
    a = user("c_actor")

    {:ok, _} = Notifications.notify(attrs(r, a))
    assert Notifications.unread_count(r) == 1
  end

  test "notify skips self" do
    a = user("c_self")
    assert :ok = Notifications.notify(attrs(a, a))
    assert Notifications.unread_count(a) == 0
  end

  test "notify honors a disabled preference" do
    r = user("c_pref", %{"reacted" => false})
    a = user("c_pref_actor")

    assert :ok = Notifications.notify(attrs(r, a, :reacted))
    assert Notifications.unread_count(r) == 0

    {:ok, _} = Notifications.notify(attrs(r, a, :followed))
    assert Notifications.unread_count(r) == 1
  end

  test "mark_all_read clears unread" do
    r = user("c_mar")
    a = user("c_mar_actor")
    {:ok, _} = Notifications.notify(attrs(r, a, :followed))
    {:ok, _} = Notifications.notify(attrs(r, a, :commented))
    assert Notifications.unread_count(r) == 2

    Notifications.mark_all_read(r)
    assert Notifications.unread_count(r) == 0
  end

  test "list returns the recipient's notifications newest-first with actor loaded" do
    r = user("c_list")
    a = user("c_list_actor")
    {:ok, _} = Notifications.notify(attrs(r, a))
    [n] = Notifications.list_for(r, limit: 10)
    assert n.actor.id == a.id
  end
end
```

- [ ] **Step 2: Add the context functions**

In `lib/verscienta/notifications.ex`, add `require Ash.Query` at the top (after `use Ash.Domain`), and add inside the module:
```elixir
  require Ash.Query

  alias Verscienta.Notifications.Notification

  @doc "PubSub topic for a user's notifications."
  def topic(user_id), do: "notifications:" <> to_string(user_id)

  @doc "Subscribe the caller to a user's notifications topic."
  def subscribe(user_id), do: Phoenix.PubSub.subscribe(Verscienta.PubSub, topic(user_id))

  defp broadcast(user_id, message),
    do: Phoenix.PubSub.broadcast(Verscienta.PubSub, topic(user_id), message)

  @doc "Whether a recipient has `type` notifications enabled (opt-out; default true)."
  def enabled?(%{notification_prefs: prefs}, type),
    do: Map.get(prefs || %{}, to_string(type), true) != false

  def enabled?(_user, _type), do: true

  @doc """
  Create a notification (best-effort). Skips self-notifications and types the
  recipient has disabled. Broadcasts `{:notification, id}` on the recipient topic.
  `attrs` requires :recipient_id, :actor_id, :type, :subject_type, :subject_id, :metadata.
  """
  def notify(%{recipient_id: recipient_id, actor_id: actor_id} = attrs) do
    cond do
      recipient_id == actor_id ->
        :ok

      true ->
        recipient = Ash.get!(Verscienta.Accounts.User, recipient_id, authorize?: false)

        if enabled?(recipient, attrs.type) do
          notification =
            Notification
            |> Ash.Changeset.for_create(:create, attrs)
            |> Ash.create!(authorize?: false)

          broadcast(recipient_id, {:notification, notification.id})
          {:ok, notification}
        else
          :ok
        end
    end
  rescue
    _ -> :ok
  end

  @doc "Load one notification (with actor) by id, or nil."
  def get(id) do
    Notification |> Ash.get!(id, load: [:actor], authorize?: false)
  rescue
    _ -> nil
  end

  @doc "A recipient's notifications, newest first, actor loaded."
  def list(user, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Notification
    |> Ash.Query.filter(recipient_id == ^user.id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.load(:actor)
    |> Ash.read!(authorize?: false)
  end

  @doc "Count of a recipient's unread notifications."
  def unread_count(user) do
    Notification
    |> Ash.Query.filter(recipient_id == ^user.id and is_nil(read_at))
    |> Ash.count!(authorize?: false)
  end

  @doc "Mark one notification read (authorized as the recipient) and notify the bell."
  def mark_read(notification, actor) do
    updated =
      notification
      |> Ash.Changeset.for_update(:mark_read, %{}, actor: actor)
      |> Ash.update!()

    broadcast(actor.id, {:notifications_read})
    {:ok, updated}
  rescue
    _ -> :error
  end

  @doc "Mark all of a user's unread notifications read; notify the bell."
  def mark_all_read(user) do
    Notification
    |> Ash.Query.filter(recipient_id == ^user.id and is_nil(read_at))
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn n ->
      n |> Ash.Changeset.for_update(:mark_read, %{}, authorize?: false) |> Ash.update!()
    end)

    broadcast(user.id, {:notifications_read})
    :ok
  rescue
    _ -> :ok
  end
```
NOTE: `mark_all_read` reads + updates each unread row (simple, correct for inbox sizes; optimize later if needed). `mark_read/2` enforces recipient authorization via the `:mark_read` policy (`actor: actor`), so the LiveView passes `current_user`.

- [ ] **Step 3: Run the test**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/notifications/context_test.exs"
```
Expected: 5 tests pass.

- [ ] **Step 4: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(notifications): notify/enabled?/queries/real-time context"
```
Then `git rev-parse --short HEAD`.

---

## Task 4: Notify on follow + reaction (TDD)

**Files:**
- Modify: `lib/verscienta/social/follow.ex`, `lib/verscienta/engagement/reaction.ex`
- Test: `test/verscienta/notifications/follow_reaction_notify_test.exs`

- [ ] **Step 0: Read both toggle create branches**
```
docker compose run --rm -T app bash -lc "sed -n '/action :toggle/,/^    end/p' lib/verscienta/social/follow.ex; echo '====='; sed -n '/action :toggle/,/^    end/p' lib/verscienta/engagement/reaction.ex"
```
Both already emit activity in the create branch (Follow for `:user` targets; Reaction always). You'll add a `notify` call right after the activity emit, in the SAME create branch, matching the bound variable names.

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/notifications/follow_reaction_notify_test.exs`:
```elixir
defmodule Verscienta.Notifications.FollowReactionNotifyTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Notifications

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

  defp types_for(user), do: Notifications.list_for(user, limit: 50) |> Enum.map(& &1.type)

  test "following a user notifies the followed user" do
    a = user("nf_a")
    b = user("nf_b")

    Verscienta.Social.Follow
    |> Ash.ActionInput.for_action(:toggle, %{target_type: :user, target_id: to_string(b.id)}, actor: a)
    |> Ash.run_action!()

    assert :followed in types_for(b)
    assert types_for(a) == []
  end

  test "reacting to an article notifies its author (not the reactor)" do
    author = user("nr_author")
    reactor = user("nr_reactor")
    art = article(author)

    Verscienta.Engagement.Reaction
    |> Ash.ActionInput.for_action(:toggle, %{article_id: art.id, kind: :like}, actor: reactor)
    |> Ash.run_action!()

    assert :reacted in types_for(author)
    assert types_for(reactor) == []
  end

  test "reacting to your OWN article notifies nobody" do
    author = user("nr_self")
    art = article(author)

    Verscienta.Engagement.Reaction
    |> Ash.ActionInput.for_action(:toggle, %{article_id: art.id, kind: :like}, actor: author)
    |> Ash.run_action!()

    assert types_for(author) == []
  end
end
```

- [ ] **Step 2: Notify on follow** — In `lib/verscienta/social/follow.ex`, in the `:toggle` create branch, right after the existing `if type == :user, do: emit_follow_activity(...)`, add:
```elixir
                  if type == :user, do: notify_follow(actor, id)
```
Add the private helper:
```elixir
  defp notify_follow(actor, target_user_id) do
    Verscienta.Notifications.notify(%{
      recipient_id: target_user_id,
      actor_id: actor.id,
      type: :followed,
      subject_type: :user,
      subject_id: to_string(actor.id),
      metadata: %{"actor_username" => to_string(actor.username)}
    })

    :ok
  rescue
    _ -> :ok
  end
```
NOTE: `target_user_id` is the `id` (string) from the toggle args. `notify/1` itself skips self + is best-effort, but the local rescue keeps the toggle safe regardless.

- [ ] **Step 3: Notify on reaction** — In `lib/verscienta/engagement/reaction.ex`, in the `:toggle` create branch, right after the existing `emit_reaction_activity(...)` call, add:
```elixir
              notify_reaction(actor, article_id, created.id, kind)
```
(match the create-branch variable names from Step 0.) Add the private helper:
```elixir
  defp notify_reaction(actor, article_id, _reaction_id, kind) do
    article = Ash.get!(Verscienta.Content.Article, article_id, authorize?: false)

    if article.author_id do
      Verscienta.Notifications.notify(%{
        recipient_id: article.author_id,
        actor_id: actor.id,
        type: :reacted,
        subject_type: :article,
        subject_id: to_string(article_id),
        metadata: %{
          "actor_username" => to_string(actor.username),
          "article_title" => article.title,
          "article_slug" => article.slug,
          "kind" => to_string(kind)
        }
      })
    end

    :ok
  rescue
    _ -> :ok
  end
```

- [ ] **Step 4: Run the test**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/notifications/follow_reaction_notify_test.exs"
```
Expected: 3 tests pass.

- [ ] **Step 5: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(notifications): notify on follow + reaction"
```
Then `git rev-parse --short HEAD`.

---

## Task 5: Mention extraction + comment notifications (commented/replied/mentioned, deduped) (TDD)

**Files:**
- Modify: `lib/verscienta/social/mentions.ex`
- Create: `lib/verscienta/engagement/comment/changes/notify_comment.ex`
- Modify: `lib/verscienta/engagement/comment.ex`
- Test: `test/verscienta/notifications/comment_notify_test.exs`

- [ ] **Step 1: Add `extract_existing_users/1` to Mentions** — In `lib/verscienta/social/mentions.ex`, add a public function (it can reuse `@mention_regex`):
```elixir
  @doc "Returns the existing %User{} structs @mentioned in `body` (deduped, case-insensitive)."
  def extract_existing_users(body) when is_binary(body) do
    handles =
      @mention_regex
      |> Regex.scan(body, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    case handles do
      [] ->
        []

      handles ->
        downcased = Enum.map(handles, &String.downcase/1)

        Verscienta.Accounts.User
        |> Ash.Query.filter(username in ^handles)
        |> Ash.read!(authorize?: false)
        |> Enum.filter(&(String.downcase(to_string(&1.username)) in downcased))
    end
  end

  def extract_existing_users(_), do: []
```

- [ ] **Step 2: Write the failing test**

Create `test/verscienta/notifications/comment_notify_test.exs`:
```elixir
defmodule Verscienta.Notifications.CommentNotifyTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Notifications

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

  defp comment!(actor, article_id, body, parent_id \\ nil) do
    Verscienta.Engagement.Comment
    |> Ash.Changeset.for_create(:create, %{article_id: article_id, body: body, parent_id: parent_id}, actor: actor)
    |> Ash.create!()
  end

  defp types_for(user), do: Notifications.list_for(user, limit: 50) |> Enum.map(& &1.type)

  test "commenting notifies the article author" do
    author = user("cn_author")
    commenter = user("cn_commenter")
    art = article(author)

    comment!(commenter, art.id, "nice piece")
    assert :commented in types_for(author)
  end

  test "a reply notifies the parent comment's author as :replied" do
    author = user("cn2_author")
    parent_author = user("cn2_parent")
    replier = user("cn2_replier")
    art = article(author)

    parent = comment!(parent_author, art.id, "first")
    comment!(replier, art.id, "good point", parent.id)

    assert :replied in types_for(parent_author)
  end

  test "a @mention notifies the mentioned user as :mentioned" do
    author = user("cn3_author")
    commenter = user("cn3_commenter")
    mentioned = user("cn3_mentioned")
    art = article(author)

    comment!(commenter, art.id, "hey @cn3_mentioned look")
    assert :mentioned in types_for(mentioned)
  end

  test "one comment yields at most one notification per recipient (dedup, priority)" do
    # parent author is ALSO @mentioned in the reply → should get ONE :replied (priority), not two
    parent_author = user("cn4_parent")
    replier = user("cn4_replier")
    art = article(user("cn4_author"))

    parent = comment!(parent_author, art.id, "first")
    comment!(replier, art.id, "thanks @cn4_parent", parent.id)

    types = types_for(parent_author)
    assert :replied in types
    assert length(Enum.filter(types, &(&1 in [:replied, :mentioned, :commented]))) == 1
  end

  test "commenting on your own article notifies nobody" do
    author = user("cn5_author")
    art = article(author)
    comment!(author, art.id, "my own note")
    assert types_for(author) == []
  end
end
```

- [ ] **Step 3: Create the `NotifyComment` change**

Create `lib/verscienta/engagement/comment/changes/notify_comment.ex`:
```elixir
defmodule Verscienta.Engagement.Comment.Changes.NotifyComment do
  @moduledoc """
  After-action: notify the article author (:commented), the parent comment's author
  (:replied), and any @mentioned users (:mentioned). Deduped to ONE notification per
  recipient using priority :replied > :mentioned > :commented. Skips the actor.
  """
  use Ash.Resource.Change

  @priority %{replied: 3, mentioned: 2, commented: 1}

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _cs, comment ->
      notify(comment)
      {:ok, comment}
    end)
  end

  defp notify(comment) do
    article = Ash.get!(Verscienta.Content.Article, comment.article_id, authorize?: false)
    actor = Ash.get!(Verscienta.Accounts.User, comment.user_id, authorize?: false)

    meta = %{
      "actor_username" => to_string(actor.username),
      "article_title" => article.title,
      "article_slug" => article.slug,
      "comment_excerpt" => String.slice(comment.body, 0, 140)
    }

    # Build [{recipient_id, type, subject_type, subject_id}] candidates.
    candidates =
      [commented_candidate(article)] ++
        [replied_candidate(comment)] ++
        mention_candidates(comment)

    candidates
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(fn {rid, _t, _st, _sid} -> rid == comment.user_id end)
    |> dedup_by_priority()
    |> Enum.each(fn {rid, type, st, sid} ->
      Verscienta.Notifications.notify(%{
        recipient_id: rid,
        actor_id: comment.user_id,
        type: type,
        subject_type: st,
        subject_id: sid,
        metadata: meta
      })
    end)

    :ok
  rescue
    _ -> :ok
  end

  defp commented_candidate(%{author_id: nil}), do: nil
  defp commented_candidate(%{author_id: author_id, id: article_id}),
    do: {author_id, :commented, :article, to_string(article_id)}

  defp replied_candidate(%{parent_id: nil}), do: nil

  defp replied_candidate(%{parent_id: parent_id}) do
    case Ash.get(Verscienta.Engagement.Comment, parent_id, authorize?: false) do
      {:ok, parent} -> {parent.user_id, :replied, :comment, to_string(parent_id)}
      _ -> nil
    end
  end

  defp mention_candidates(comment) do
    comment.body
    |> Verscienta.Social.Mentions.extract_existing_users()
    |> Enum.map(fn user -> {user.id, :mentioned, :comment, to_string(comment.id)} end)
  end

  # Keep one candidate per recipient_id — the highest priority type.
  defp dedup_by_priority(candidates) do
    candidates
    |> Enum.group_by(fn {rid, _t, _st, _sid} -> rid end)
    |> Enum.map(fn {_rid, list} ->
      Enum.max_by(list, fn {_rid, type, _st, _sid} -> Map.fetch!(@priority, type) end)
    end)
  end
end
```

- [ ] **Step 4: Append the change to Comment `:create`**

In `lib/verscienta/engagement/comment.ex`, in the `:create` action, add after the existing `EmitCommentActivity` change:
```elixir
      change Verscienta.Engagement.Comment.Changes.NotifyComment
```

- [ ] **Step 5: Run the test**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/notifications/comment_notify_test.exs"
```
Expected: 5 tests pass.

- [ ] **Step 6: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(notifications): comment notifications (commented/replied/mentioned, deduped)"
```
Then `git rev-parse --short HEAD`.

---

## Task 6: `notification_item` component + phrase/accent helpers (TDD)

**Files:**
- Create: `lib/verscienta_web/components/notification_components.ex`
- Test: `test/verscienta_web/components/notification_item_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/components/notification_item_test.exs`:
```elixir
defmodule VerscientaWeb.NotificationItemTest do
  use VerscientaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import VerscientaWeb.NotificationComponents

  defp notif(type, metadata) do
    %{
      id: "n1",
      type: type,
      subject_type: :article,
      subject_id: "a1",
      metadata: metadata,
      read_at: nil,
      inserted_at: ~U[2026-06-03 12:00:00.000000Z],
      actor: %{username: "alice"}
    }
  end

  test "renders a :commented notification with actor + link" do
    html =
      render_component(&notification_item/1, %{
        notification: notif(:commented, %{"actor_username" => "alice", "article_title" => "Hello", "article_slug" => "hello"})
      })

    assert html =~ "@alice"
    assert html =~ "commented"
    assert html =~ ~s(href="/articles/hello")
  end

  test "renders a :followed notification linking to the actor profile" do
    html =
      render_component(&notification_item/1, %{
        notification: %{
          id: "n2",
          type: :followed,
          subject_type: :user,
          subject_id: "u2",
          metadata: %{"actor_username" => "bob"},
          read_at: nil,
          inserted_at: ~U[2026-06-03 12:00:00.000000Z],
          actor: %{username: "bob"}
        }
      })

    assert html =~ "followed you"
    assert html =~ ~s(href="/@bob")
  end
end
```

- [ ] **Step 2: Create the component module**

Create `lib/verscienta_web/components/notification_components.ex`:
```elixir
defmodule VerscientaWeb.NotificationComponents do
  @moduledoc "UI for notifications: a single notification row."
  use Phoenix.Component

  @doc "Renders one notification row with a colored type bar, message, and link to the subject."
  attr :notification, :map, required: true
  attr :id, :string, default: nil

  def notification_item(assigns) do
    ~H"""
    <a
      id={@id || ("notification-" <> @notification.id)}
      href={notification_href(@notification)}
      class={[
        "flex items-baseline gap-3 border-b border-line py-3 pl-3 text-sm",
        is_nil(@notification.read_at) && "bg-ink/5"
      ]}
    >
      <span class={["mt-1 inline-block h-2 w-2 shrink-0 rounded-full", notification_accent(@notification.type)]}>
      </span>
      <span class="flex-1">
        <span class="font-medium text-ink">@{@notification.metadata["actor_username"]}</span>
        <span class="text-ink-3">{notification_phrase(@notification.type)}</span>
        <span :if={@notification.metadata["article_title"]} class="text-ink">
          {@notification.metadata["article_title"]}
        </span>
      </span>
      <span class="text-[11px] text-ink-3">{notification_relative_time(@notification.inserted_at)}</span>
    </a>
    """
  end

  @doc false
  def notification_phrase(:followed), do: "followed you"
  def notification_phrase(:reacted), do: "reacted to"
  def notification_phrase(:commented), do: "commented on"
  def notification_phrase(:replied), do: "replied to your comment on"
  def notification_phrase(:mentioned), do: "mentioned you in"
  def notification_phrase(_), do: "notified you"

  @doc false
  def notification_accent(:mentioned), do: "bg-zune"
  def notification_accent(:replied), do: "bg-zune"
  def notification_accent(:followed), do: "bg-ink-3"
  def notification_accent(_), do: "bg-ink-3"

  @doc false
  def notification_href(%{type: :followed, metadata: meta}),
    do: "/@" <> to_string(meta["actor_username"])

  def notification_href(%{metadata: %{"article_slug" => slug}}) when is_binary(slug),
    do: "/articles/" <> slug

  def notification_href(_), do: "/notifications"

  @doc false
  def notification_relative_time(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  def notification_relative_time(_), do: ""
```
(Close the module with `end`.) NOTE: per-type accent classes use `bg-zune` and `bg-ink-3` (guaranteed to exist). If you want distinct metro accents per type, confirm the class names exist in `assets/css/app.css` first; otherwise keep zune/ink-3. All dynamic values render through HEEx `{...}` (escaped); hrefs are built from safe slugs/usernames.

- [ ] **Step 3: Run the test**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/components/notification_item_test.exs"
```
Expected: 2 tests pass.

- [ ] **Step 4: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(notifications): notification_item component + helpers"
```
Then `git rev-parse --short HEAD`.

---

## Task 7: `/notifications` center LiveView (TDD)

**Files:**
- Create: `lib/verscienta_web/live/notifications_live.ex`
- Modify: `lib/verscienta_web/router.ex`
- Test: `test/verscienta_web/live/notifications_live_test.exs`

- [ ] **Step 1: Add the route** — In `lib/verscienta_web/router.ex`, inside the `ash_authentication_live_session :authenticated_routes` block (with `/settings`, profile routes), add:
```elixir
      live "/notifications", NotificationsLive, :index
```

- [ ] **Step 2: Write the failing test**

Create `test/verscienta_web/live/notifications_live_test.exs`:
```elixir
defmodule VerscientaWeb.NotificationsLiveTest do
  use VerscientaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias AshAuthentication.Plug.Helpers
  alias Verscienta.Notifications

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

  defp notify!(recipient, actor) do
    {:ok, _} =
      Notifications.notify(%{
        recipient_id: recipient.id,
        actor_id: actor.id,
        type: :followed,
        subject_type: :user,
        subject_id: to_string(actor.id),
        metadata: %{"actor_username" => to_string(actor.username)}
      })
  end

  test "shows the recipient's notifications", %{conn: conn} do
    me = user("nl_me")
    a = user("nl_actor")
    notify!(me, a)

    {:ok, _view, html} = conn |> sign_in(me) |> live(~p"/notifications")
    assert html =~ "@nl_actor"
    assert html =~ "followed you"
  end

  test "mark all read clears unread count", %{conn: conn} do
    me = user("nl_me2")
    a = user("nl_actor2")
    notify!(me, a)
    assert Notifications.unread_count(me) == 1

    {:ok, view, _html} = conn |> sign_in(me) |> live(~p"/notifications")
    render_click(element(view, "button[phx-click=mark_all_read]"))

    assert Notifications.unread_count(me) == 0
  end

  test "a new notification appears in real time", %{conn: conn} do
    me = user("nl_me3")
    a = user("nl_actor3")

    {:ok, view, _html} = conn |> sign_in(me) |> live(~p"/notifications")
    notify!(me, a)

    assert render(view) =~ "@nl_actor3"
  end
end
```

- [ ] **Step 3: Create the LiveView**

Create `lib/verscienta_web/live/notifications_live.ex`:
```elixir
defmodule VerscientaWeb.NotificationsLive do
  use VerscientaWeb, :live_view

  alias Verscienta.Notifications
  import VerscientaWeb.NotificationComponents

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    if connected?(socket), do: Notifications.subscribe(user.id)

    {:ok,
     socket
     |> assign(:page_title, "notifications")
     |> stream(:notifications, Notifications.list_for(user, limit: 50))}
  end

  @impl true
  def handle_event("mark_all_read", _params, socket) do
    Notifications.mark_all_read(socket.assigns.current_user)
    # reload so read styling refreshes
    {:noreply, stream(socket, :notifications, Notifications.list_for(socket.assigns.current_user, limit: 50), reset: true)}
  end

  @impl true
  def handle_info({:notification, id}, socket) do
    case Notifications.get(id) do
      nil -> {:noreply, socket}
      n -> {:noreply, stream_insert(socket, :notifications, n, at: 0)}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl px-6 pt-24">
      <div class="mb-6 flex items-center justify-between">
        <h1 class="text-2xl font-light lowercase text-ink">notifications</h1>
        <button
          type="button"
          phx-click="mark_all_read"
          class="text-xs lowercase tracking-wider text-ink-3 hover:text-ink"
        >
          mark all read
        </button>
      </div>

      <div id="notifications-list" phx-update="stream">
        <.notification_item
          :for={{dom_id, n} <- @streams.notifications}
          id={dom_id}
          notification={n}
        />
      </div>
    </div>
    """
  end
end
```
NOTE: this LiveView is in the authenticated session, so `@current_user` exists. The stream is named `:notifications` (default dom id `"notifications-<id>"`); `notification_item` renders with `id={dom_id}`. `mark_all_read` re-streams with `reset: true` so the read styling updates. The real-time test asserts `render(view)` after a `notify!` (the LiveView is subscribed in mount under `connected?`).

- [ ] **Step 4: Run the test**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/notifications_live_test.exs"
```
Expected: 3 tests pass.

- [ ] **Step 5: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(notifications): /notifications center LiveView"
```
Then `git rev-parse --short HEAD`.

---

## Task 8: Nested `NotificationBellLive` in the root layout (TDD)

**Files:**
- Create: `lib/verscienta_web/live/notification_bell_live.ex`
- Modify: `lib/verscienta_web/components/layouts/root.html.heex`
- Test: `test/verscienta_web/live/notification_bell_test.exs`

- [ ] **Step 0: Read the root layout** to see where `@current_user` is referenced and where to place the bell:
```
docker compose run --rm -T app bash -lc "cat lib/verscienta_web/components/layouts/root.html.heex"
```

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/notification_bell_test.exs`:
```elixir
defmodule VerscientaWeb.NotificationBellTest do
  use VerscientaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias AshAuthentication.Plug.Helpers
  alias Verscienta.Notifications

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

  test "renders unread count for a signed-in user", %{conn: conn} do
    me = user("bell_me")
    actor = user("bell_actor")

    {:ok, _} =
      Notifications.notify(%{
        recipient_id: me.id,
        actor_id: actor.id,
        type: :followed,
        subject_type: :user,
        subject_id: to_string(actor.id),
        metadata: %{"actor_username" => to_string(actor.username)}
      })

    {:ok, _view, html} = conn |> sign_in(me) |> live(~p"/notifications")
    # the nested bell renders in the layout with the unread count
    assert html =~ "1"
    assert html =~ ~s(href="/notifications")
  end

  test "signed-out user sees no bell", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/articles")
    refute html =~ ~s(id="notification-bell")
  end
end
```

- [ ] **Step 2: Create the bell LiveView**

Create `lib/verscienta_web/live/notification_bell_live.ex`:
```elixir
defmodule VerscientaWeb.NotificationBellLive do
  use VerscientaWeb, :live_view

  alias Verscienta.Notifications

  @impl true
  def mount(_params, %{"user_id" => user_id}, socket) do
    user = Ash.get!(Verscienta.Accounts.User, user_id, authorize?: false)
    if connected?(socket), do: Notifications.subscribe(user.id)

    {:ok, assign(socket, user: user, count: Notifications.unread_count(user)), layout: false}
  end

  def mount(_params, _session, socket), do: {:ok, assign(socket, user: nil, count: 0), layout: false}

  @impl true
  def handle_info({:notification, _id}, socket) do
    {:noreply, assign(socket, :count, socket.assigns.count + 1)}
  end

  def handle_info({:notifications_read}, socket) do
    {:noreply, assign(socket, :count, Notifications.unread_count(socket.assigns.user))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <a
      id="notification-bell"
      href="/notifications"
      class="relative inline-flex items-center text-ink-3 transition-colors hover:text-ink"
      aria-label="notifications"
    >
      <.icon name="hero-bell" class="size-5" />
      <span
        :if={@count > 0}
        class="absolute -right-2 -top-2 inline-flex min-w-4 items-center justify-center rounded-full bg-zune px-1 text-[10px] font-bold text-black"
      >
        {@count}
      </span>
    </a>
    """
  end
end
```
NOTE: `layout: false` prevents the nested LiveView from re-wrapping itself in the app/root layout. The `hero-bell` icon comes from the project's `<.icon>` component (heroicons) — if `hero-bell` isn't available, use any existing hero icon name present in the project (grep `hero-` in `lib/verscienta_web` for a valid name) or render a small "bell" text/glyph. Confirm `<.icon>` is in scope via `use VerscientaWeb, :live_view` (it imports core components).

- [ ] **Step 3: Render the bell in the root layout**

In `lib/verscienta_web/components/layouts/root.html.heex`, place the bell in the header for signed-in users (near the nav). Add, inside the header (e.g. just before the desktop `<nav>` or the hamburger), guarded by current_user:
```heex
        <div :if={assigns[:current_user]} class="flex items-center">
          {live_render(@conn, VerscientaWeb.NotificationBellLive,
            id: "notification-bell-live",
            session: %{"user_id" => @current_user.id})}
        </div>
```
NOTE: the root layout is rendered at the initial HTTP request (dead render) for BOTH controller pages and LiveView pages, so `@conn` is available here. `live_render(@conn, ...)` mounts an independent LiveView that persists across the parent LiveView's updates (the root layout isn't re-rendered on live patches). If `@conn` is NOT in scope in this layout (verify in Step 0 — some setups only expose `@current_user`), use the form `live_render(@socket, ...)` is NOT correct for a dead render; instead confirm the conn is available (Phoenix passes `@conn` to the root layout). If neither is available, fall back to passing the bell as a normal nested render is not possible — in that case, render a plain `<a href="/notifications">` with a server-computed count from `assigns[:current_user]` and skip the live bell (document this fallback). Prefer the `live_render(@conn, ...)` path.

- [ ] **Step 4: Run the test**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/notification_bell_test.exs"
```
Expected: 2 tests pass.

- [ ] **Step 5: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(notifications): live nav bell with unread badge"
```
Then `git rev-parse --short HEAD`.

---

## Task 9: Settings preferences section (TDD)

**Files:**
- Modify: `lib/verscienta_web/live/settings_live.ex`
- Test: `test/verscienta_web/live/settings_notifications_test.exs`

- [ ] **Step 0: Read the settings LiveView**
```
docker compose run --rm -T app bash -lc "cat lib/verscienta_web/live/settings_live.ex"
```
Note its `mount/3`, how it loads/edits the current user, existing form/handle_event patterns, and the render structure (you ADD a notifications section; preserve existing profile editing).

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/settings_notifications_test.exs`:
```elixir
defmodule VerscientaWeb.SettingsNotificationsTest do
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

  test "settings shows notification preference toggles", %{conn: conn} do
    me = user("set_me")
    {:ok, _view, html} = conn |> sign_in(me) |> live(~p"/settings")
    assert html =~ "notifications"
    assert html =~ "reacted" or html =~ "Reacted"
  end

  test "toggling a preference persists it", %{conn: conn} do
    me = user("set_me2")
    {:ok, view, _html} = conn |> sign_in(me) |> live(~p"/settings")

    view
    |> form("#notification-prefs-form", %{"prefs" => %{"reacted" => "false"}})
    |> render_submit()

    reloaded = Ash.get!(Verscienta.Accounts.User, me.id, authorize?: false)
    assert reloaded.notification_prefs["reacted"] == false
  end
end
```

- [ ] **Step 2: Add the preferences section to SettingsLive**

In `lib/verscienta_web/live/settings_live.ex`:
- Ensure the current user is assigned (it already is for profile editing). Add a `handle_event("save_notification_prefs", %{"prefs" => prefs}, socket)` that coerces checkbox values to booleans and calls `User.update_notification_prefs`:
```elixir
  @impl true
  def handle_event("save_notification_prefs", %{"prefs" => prefs}, socket) do
    user = socket.assigns.current_user

    normalized =
      Map.new(Verscienta.Notifications.Notification.types(), fn type ->
        key = to_string(type)
        {key, Map.get(prefs, key) not in [nil, "false", false]}
      end)

    {:ok, updated} =
      user
      |> Ash.Changeset.for_update(:update_notification_prefs, %{notification_prefs: normalized}, actor: user)
      |> Ash.update()

    {:noreply, assign(socket, :current_user, updated)}
  end
```
- In the render, add a notifications section/form (place after the profile form). A checkbox per type, defaulting to the current pref (enabled unless explicitly false):
```heex
<section class="mt-12">
  <h2 class="mb-4 text-sm lowercase tracking-wider text-ink-3">notifications</h2>
  <form id="notification-prefs-form" phx-submit="save_notification_prefs" class="space-y-2">
    <label :for={type <- Verscienta.Notifications.Notification.types()} class="flex items-center gap-2 text-sm text-ink">
      <input
        type="hidden"
        name={"prefs[" <> to_string(type) <> "]"}
        value="false"
      />
      <input
        type="checkbox"
        name={"prefs[" <> to_string(type) <> "]"}
        value="true"
        checked={Map.get(@current_user.notification_prefs, to_string(type), true) != false}
      />
      <span class="lowercase">{type}</span>
    </label>
    <button type="submit" class="mt-3 border border-zune px-3 py-1 text-[11px] font-bold uppercase tracking-wider text-zune hover:bg-zune hover:text-black">
      save preferences
    </button>
  </form>
</section>
```
NOTE: the hidden `value="false"` before each checkbox is the standard HTML trick so an UNCHECKED box still submits `"false"` (checked submits `"true"`, which wins as the later field). The `normalized` map in the handler maps every known type to a boolean. The test submits `%{"reacted" => "false"}` directly; the handler's `not in [nil, "false", false]` yields `false` for "reacted" and `true` (default) for the keys not present — confirm the assertion (`reacted => false`) holds and adjust the normalization if your settings form differs. Preserve all existing settings markup.

- [ ] **Step 3: Run the test**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/settings_notifications_test.exs"
```
Expected: 2 tests pass.

- [ ] **Step 4: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(notifications): per-type preference toggles in settings"
```
Then `git rev-parse --short HEAD`.

---

## Task 10: Seeds + todo + full verification + merge prep

**Files:**
- Modify: `priv/repo/seeds.exs`, `docs/todo.md`

- [ ] **Step 1: Read the seeds tail**
```
docker compose run --rm -T app bash -lc "tail -40 priv/repo/seeds.exs"
```

- [ ] **Step 2: Append idempotent notification seeds**

At the END of `priv/repo/seeds.exs`, add a sample notification (idempotent: only create if the recipient has none). Adapt to seeded users:
```elixir
# --- Notification seeds (idempotent) ---
case Verscienta.Accounts.User |> Ash.read!(authorize?: false) |> Enum.sort_by(& &1.username) do
  [recipient, actor | _] ->
    if Verscienta.Notifications.unread_count(recipient) == 0 do
      Verscienta.Notifications.notify(%{
        recipient_id: recipient.id,
        actor_id: actor.id,
        type: :followed,
        subject_type: :user,
        subject_id: to_string(actor.id),
        metadata: %{"actor_username" => to_string(actor.username)}
      })
    end

  _ ->
    :ok
end
```
(Note: notifications are also generated naturally by the existing follow/comment/reaction seeds via the hooks — that's expected.)

- [ ] **Step 3: Run seeds twice for idempotency**
```
docker compose up -d db
docker compose run --rm -T app bash -lc "mix ash.setup && mix run priv/repo/seeds.exs && mix run priv/repo/seeds.exs"
```
Expected: no crash; the guard prevents piling up duplicate sample notifications.

- [ ] **Step 4: Tick the todo items**

In `docs/todo.md`, under "### Notifications", read the exact lines first, then flip `[ ]`→`[x]` with notes:
```markdown
- [x] `Notification` resource (type, actor, subject, read state).
- [x] In-app notification center (colored bar by type per design system).
- [x] Real-time delivery via PubSub/Presence. *(PubSub; nested live bell + center)*
- [x] Notification preferences. *(per-type opt-out in /settings)*
```

- [ ] **Step 5: Full clean-deps gate**
```
docker compose up -d db
docker compose run --rm -T app bash -lc "mix deps.get && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
```
Expected: format clean, credo 0 issues, no warnings, ALL tests pass. Capture the exact `N tests, 0 failures` line.

- [ ] **Step 6: Commit**
```
git add -A
git commit -m "feat(notifications): seeds + todo updates"
```
Then `git rev-parse --short HEAD`.

---

## Definition of Done (verify all)

- [ ] `Notification` resource (recipient-only policies) in `Verscienta.Notifications`; `User.notification_prefs`; migrations applied; domain registered.
- [ ] All 5 triggers notify the correct recipient, skipping self, honoring preferences, deduped per comment (priority `:replied > :mentioned > :commented`).
- [ ] `/notifications` center: list, colored-by-type, mark-all-read, real-time prepend.
- [ ] Nested live nav bell with unread badge updating in real time (signed-in only).
- [ ] `/settings` per-type preference toggles persist.
- [ ] @mentions in comments notify the mentioned user.
- [ ] `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test` all pass.
- [ ] Migrations via `mix ash.codegen`; `docs/todo.md` updated; work committed on `notifications`.
