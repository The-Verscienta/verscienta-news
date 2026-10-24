# Social Graph Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A social graph — polymorphic follows (users/categories/sources/tags), a Following feed, a Trending feed, @mentions in comments, and reposts — built on the existing Ash domains.

**Architecture:** A new `Verscienta.Social` Ash domain with two resources (`Follow`, `Repost`) following the Engagement toggle idiom. Counts and feeds are read-time queries via context helpers (no materialized feeds, no denormalized counters). UI: a reusable follow button, a Latest/Following/Trending tab pivot on the articles feed, follower/following lists on profiles, render-time @mention linkification, and a repost affordance on the reader.

**Tech Stack:** Phoenix 1.8, Ash 3 + AshPostgres, Phoenix LiveView (+ `Phoenix.LiveView.JS`), Phoenix.PubSub, Tailwind v4 (Codex tokens).

---

## Conventions for the executor

- **Run everything in Docker.** Mix in the app service: `docker compose run --rm -T app bash -lc "<cmd>"`. Start DB: `docker compose up -d db`. Generous timeouts. If "dependency not available", prefix `mix deps.get &&`.
- **One task at a time, sequentially.** After each task run `git rev-parse --short HEAD` for the REAL sha. Never batch tasks or guess SHAs. **Re-run the FULL gate (`mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `MIX_ENV=test mix test`) after the FINAL edit of each task, BEFORE committing.**
- **Branch:** `social-graph` (already checked out; spec committed `af9a737`).
- **Line endings:** `.gitattributes` eol=lf, autocrlf false — don't change. `mix format` before commit. No `.bak` files.
- **Git identity:** no local override. Commit body ends with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- **Migrations:** generate with `mix ash.codegen <name>` AFTER the resource is defined + registered. Apply in test with `MIX_ENV=test mix ash.setup` (or `mix ash.migrate`). Never hand-write migrations.
- **Reuse patterns (read these first):**
  - Toggle idiom + policies: `lib/verscienta/engagement/reaction.ex` (generic `action :toggle, :term` with `run fn input, context -> {:ok, result} end`; `forbid_if always()` on destroy).
  - Domain + PubSub helpers: `lib/verscienta/engagement.ex` (`topic/subscribe/broadcast`, context query helpers).
  - Domain registration: `config/config.exs` → `config :verscienta, ash_domains: [...]`.
  - Category enum (NOT a table): `lib/verscienta/content/category.ex` (`keys/0`, `get/1`, `from_slug/1`, `all/0`).
  - `Article` relationships: `belongs_to :author, User` (nullable), `belongs_to :source, Source` (nullable), `many_to_many :tags, Tag`, attribute `category` (atom), `status` (atom), `published_at`. Read action `:list_published` (sort `published_at: :desc`).
  - `User`: attributes `username` (ci_string), `display_name`, `avatar_url`, `points`, `role`; read actions public.
  - Reader LiveView (comments render here) + `ProfileLive` (`/@:username`) + `ArticleFeedLive` (`/articles`) + `CategoryLive` (`/c/:category`) — read each before modifying.
  - Codex tokens: canvas `#0c0c0c`, ink `text-ink`/`text-ink-3`, line `border-line`, accent `text-zune`/`bg-zune`.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `lib/verscienta/social.ex` | `Social` domain + PubSub + context helpers (counts, `following?`, `following_feed`, `trending`) |
| `lib/verscienta/social/follow.ex` | `Follow` resource (polymorphic, toggle, reads, policies) |
| `lib/verscienta/social/repost.ex` | `Repost` resource (toggle, update_quote, reads, policies) |
| `lib/verscienta/social/trending.ex` | Trending window/weights config + scoring query |
| `lib/verscienta/social/mentions.ex` | Render-time `@username` linkify (XSS-safe) |
| `config/config.exs` | register `Verscienta.Social` domain |
| `lib/verscienta_web/components/social_components.ex` | `follow_button/1`, `feed_item/1` function components |
| `lib/verscienta_web/live/article_feed_live.ex` | Latest/Following/Trending tab pivot |
| `lib/verscienta_web/live/profile_live.ex` | counts + follow button + followers/following lists |
| `lib/verscienta_web/live/category_live.ex` | category follow button |
| reader LiveView | @mention rendering in comments + repost affordance |
| `priv/repo/seeds.exs` | sample follows + reposts |
| `test/verscienta/social/*`, `test/verscienta_web/*` | tests per task |

---

## Task 1: `Social` domain + `Follow` resource (TDD)

**Files:**
- Create: `lib/verscienta/social/follow.ex`, `lib/verscienta/social.ex`
- Modify: `config/config.exs`
- Test: `test/verscienta/social/follow_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/social/follow_test.exs`:
```elixir
defmodule Verscienta.Social.FollowTest do
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

  defp toggle!(actor, type, id) do
    Follow
    |> Ash.ActionInput.for_action(:toggle, %{target_type: type, target_id: to_string(id)},
      actor: actor
    )
    |> Ash.run_action!()
  end

  test "toggle creates then destroys a follow (idempotent pair)" do
    a = user("alice")
    b = user("bob")

    toggle!(a, :user, b.id)
    assert Social.following?(a, :user, b.id)

    toggle!(a, :user, b.id)
    refute Social.following?(a, :user, b.id)
  end

  test "the unique identity prevents duplicate follow rows" do
    a = user("carol")
    b = user("dave")
    toggle!(a, :user, b.id)

    # A second create (not toggle) for the same triple must fail the identity.
    assert {:error, _} =
             Follow
             |> Ash.Changeset.for_create(:create, %{target_type: :user, target_id: to_string(b.id)},
               actor: a
             )
             |> Ash.create()
  end

  test "cannot follow yourself" do
    a = user("erin")

    assert {:error, _} =
             Follow
             |> Ash.ActionInput.for_action(:toggle, %{target_type: :user, target_id: to_string(a.id)},
               actor: a
             )
             |> Ash.run_action()
  end

  test "following a category validates the category exists" do
    a = user("frank")
    toggle!(a, :category, "nutrition")
    assert Social.following?(a, :category, "nutrition")

    assert {:error, _} =
             Follow
             |> Ash.ActionInput.for_action(:toggle, %{target_type: :category, target_id: "not_a_category"},
               actor: a
             )
             |> Ash.run_action()
  end

  test "direct destroy is forbidden" do
    a = user("grace")
    b = user("heidi")
    follow = toggle!(a, :user, b.id)
    assert {:error, _} = Ash.destroy(follow, actor: a)
  end
end
```

- [ ] **Step 2: Create the `Follow` resource**

Create `lib/verscienta/social/follow.ex`:
```elixir
defmodule Verscienta.Social.Follow do
  @moduledoc "A user following a polymorphic target: another user, a category, a source, or a tag."
  use Ash.Resource,
    otp_app: :verscienta,
    domain: Verscienta.Social,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  @target_types [:user, :category, :source, :tag]
  def target_types, do: @target_types

  postgres do
    table "follows"
    repo Verscienta.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:target_type, :target_id]
      change relate_actor(:user)
    end

    action :toggle, :term do
      description "Create the follow if absent for (user, target_type, target_id), else destroy it."
      argument :target_type, :atom, allow_nil?: false
      argument :target_id, :string, allow_nil?: false

      run fn input, context ->
        actor = context.actor
        type = input.arguments.target_type
        id = input.arguments.target_id

        cond do
          type not in @target_types ->
            {:error, "Unknown follow target type."}

          type == :user and id == to_string(actor.id) ->
            {:error, "You cannot follow yourself."}

          not Verscienta.Social.Follow.target_exists?(type, id) ->
            {:error, "Follow target does not exist."}

          true ->
            existing =
              __MODULE__
              |> Ash.Query.filter(
                user_id == ^actor.id and target_type == ^type and target_id == ^id
              )
              |> Ash.read_one!(authorize?: false)

            result =
              case existing do
                nil ->
                  __MODULE__
                  |> Ash.Changeset.for_create(:create, %{target_type: type, target_id: id},
                    actor: actor
                  )
                  |> Ash.create!(authorize?: true)

                follow ->
                  Ash.destroy!(follow, authorize?: false)
                  follow
              end

            Verscienta.Social.broadcast_follow_change(actor.id, type, id)
            {:ok, result}
        end
      end
    end

    read :following_for do
      argument :user_id, :uuid, allow_nil?: false
      argument :target_type, :atom, allow_nil?: true
      filter expr(user_id == ^arg(:user_id))
      filter expr(is_nil(^arg(:target_type)) or target_type == ^arg(:target_type))
    end

    read :followers_of do
      argument :target_type, :atom, allow_nil?: false
      argument :target_id, :string, allow_nil?: false
      filter expr(target_type == ^arg(:target_type) and target_id == ^arg(:target_id))
    end
  end

  policies do
    policy action(:toggle) do
      authorize_if actor_present()
    end

    policy action(:create) do
      authorize_if actor_present()
    end

    policy action_type(:read) do
      authorize_if always()
    end

    # Destroy is only ever invoked internally by :toggle with authorize?: false.
    policy action_type(:destroy) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :target_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: @target_types
    end

    attribute :target_id, :string, allow_nil?: false, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Verscienta.Accounts.User, allow_nil?: false
  end

  identities do
    identity :unique_follow, [:user_id, :target_type, :target_id]
  end

  @doc "Whether a follow target currently exists (best-effort, authorize?: false)."
  def target_exists?(:category, id) do
    key = String.to_existing_atom(id)
    Verscienta.Content.Category.get(key) != nil
  rescue
    ArgumentError -> false
  end

  def target_exists?(:user, id), do: record_exists?(Verscienta.Accounts.User, id)
  def target_exists?(:source, id), do: record_exists?(Verscienta.Content.Source, id)
  def target_exists?(:tag, id), do: record_exists?(Verscienta.Content.Tag, id)
  def target_exists?(_type, _id), do: false

  defp record_exists?(resource, id) do
    case Ash.get(resource, id, authorize?: false) do
      {:ok, _} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
```

- [ ] **Step 3: Create the `Social` domain with `following?/3` + PubSub stub**

Create `lib/verscienta/social.ex`:
```elixir
defmodule Verscienta.Social do
  @moduledoc "Domain for the social graph: follows and reposts."
  use Ash.Domain, otp_app: :verscienta

  require Ash.Query

  resources do
    resource Verscienta.Social.Follow
  end

  @doc "Whether `actor` currently follows the given target."
  def following?(nil, _type, _id), do: false

  def following?(actor, type, id) do
    Verscienta.Social.Follow
    |> Ash.Query.filter(user_id == ^actor.id and target_type == ^type and target_id == ^to_string(id))
    |> Ash.read_one!(authorize?: false)
    |> is_struct()
  end

  @doc "PubSub topic for a user's social events."
  def topic(user_id), do: "user:" <> to_string(user_id)

  @doc "Subscribe the calling process to a user's social topic."
  def subscribe(user_id), do: Phoenix.PubSub.subscribe(Verscienta.PubSub, topic(user_id))

  @doc "Broadcast a social message on a user's topic."
  def broadcast(user_id, message),
    do: Phoenix.PubSub.broadcast(Verscienta.PubSub, topic(user_id), message)

  @doc false
  # Broadcasts the relevant follow-change events. For :user targets, notify the
  # followed user (followers changed) and the follower (following changed).
  def broadcast_follow_change(follower_id, :user, target_id) do
    broadcast(target_id, {:followers_changed, target_id})
    broadcast(follower_id, {:following_changed, follower_id})
    :ok
  end

  def broadcast_follow_change(follower_id, _type, _target_id) do
    broadcast(follower_id, {:following_changed, follower_id})
    :ok
  end
end
```

- [ ] **Step 4: Register the domain**

In `config/config.exs`, add `Verscienta.Social` to the `ash_domains` list:
```elixir
config :verscienta,
  ash_domains: [
    Verscienta.Accounts,
    Verscienta.Content,
    Verscienta.Engagement,
    Verscienta.Gamification,
    Verscienta.Social
  ]
```

- [ ] **Step 5: Generate the migration + set up the test DB**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "mix ash.codegen add_social_follows && MIX_ENV=test mix ash.setup"
```
Expected: a migration creating the `follows` table (with the `unique_follow` index) is generated under `priv/repo/migrations/`; the test DB is set up.

- [ ] **Step 6: Run the test**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/social/follow_test.exs"
```
Expected: 5 tests pass.

- [ ] **Step 7: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(social): Social domain + polymorphic Follow resource"
```
Then `git rev-parse --short HEAD`.

---

## Task 2: Follow counts + lists helpers (TDD)

**Files:**
- Modify: `lib/verscienta/social.ex`
- Test: `test/verscienta/social/counts_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/social/counts_test.exs`:
```elixir
defmodule Verscienta.Social.CountsTest do
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

  defp follow!(actor, type, id) do
    Follow
    |> Ash.ActionInput.for_action(:toggle, %{target_type: type, target_id: to_string(id)}, actor: actor)
    |> Ash.run_action!()
  end

  test "follower_count and following_count reflect toggles" do
    a = user("amy")
    b = user("ben")
    c = user("cleo")

    follow!(a, :user, b.id)
    follow!(c, :user, b.id)
    follow!(a, :category, "nutrition")

    assert Social.follower_count(:user, b.id) == 2
    assert Social.following_count(a.id) == 2
    assert Social.following_count(b.id) == 0
    assert Social.follower_count(:category, "nutrition") == 1
  end

  test "followed_user_ids and follower_user_ids return id lists" do
    a = user("dan")
    b = user("eve")
    follow!(a, :user, b.id)

    assert Social.followed_user_ids(a.id) == [b.id]
    assert Social.follower_user_ids(b.id) == [a.id]
  end
end
```

- [ ] **Step 2: Add the count + list helpers to `Social`**

In `lib/verscienta/social.ex`, add these functions (inside the module):
```elixir
  @doc "Number of users/targets `user_id` follows."
  def following_count(user_id) do
    Verscienta.Social.Follow
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.count!(authorize?: false)
  end

  @doc "Number of followers a target has."
  def follower_count(type, id) do
    Verscienta.Social.Follow
    |> Ash.Query.filter(target_type == ^type and target_id == ^to_string(id))
    |> Ash.count!(authorize?: false)
  end

  @doc "The user ids that `user_id` follows (target_type :user)."
  def followed_user_ids(user_id) do
    Verscienta.Social.Follow
    |> Ash.Query.filter(user_id == ^user_id and target_type == :user)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.target_id)
  end

  @doc "The user ids that follow `user_id`."
  def follower_user_ids(user_id) do
    Verscienta.Social.Follow
    |> Ash.Query.filter(target_type == :user and target_id == ^to_string(user_id))
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.user_id)
  end

  @doc "Returns `%{user: [ids], category: [values], source: [ids], tag: [ids]}` for a follower."
  def follows_by_type(user_id) do
    Verscienta.Social.Follow
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read!(authorize?: false)
    |> Enum.group_by(& &1.target_type, & &1.target_id)
    |> Map.put_new(:user, [])
    |> Map.put_new(:category, [])
    |> Map.put_new(:source, [])
    |> Map.put_new(:tag, [])
  end
```
NOTE: `followed_user_ids/1` returns the `target_id` strings (UUID strings). The test compares against `b.id` — Ash UUIDs render as strings in this column, and `b.id` is itself a string-compatible UUID; if the assertion fails on type, change the test to compare `to_string(b.id)`. Confirm by running.

- [ ] **Step 3: Run the test**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/social/counts_test.exs"
```
Expected: 2 tests pass. (If the id-list assertion fails on string-vs-uuid, wrap expected ids in `to_string/1` and re-run.)

- [ ] **Step 4: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(social): follow count + list context helpers"
```
Then `git rev-parse --short HEAD`.

---

## Task 3: `Repost` resource (TDD)

**Files:**
- Create: `lib/verscienta/social/repost.ex`
- Modify: `lib/verscienta/social.ex` (register resource)
- Test: `test/verscienta/social/repost_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/social/repost_test.exs`:
```elixir
defmodule Verscienta.Social.RepostTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Social.Repost

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
    |> Ash.Changeset.for_create(:create, %{title: "T", excerpt: "e", category: :nutrition},
      actor: author
    )
    |> Ash.create!()
  end

  defp toggle!(actor, article_id, quote \\ nil) do
    Repost
    |> Ash.ActionInput.for_action(:toggle, %{article_id: article_id, quote: quote}, actor: actor)
    |> Ash.run_action!()
  end

  test "toggle creates then destroys a repost" do
    u = user("ringo")
    art = article(user("george"))

    toggle!(u, art.id, "great read")
    rows = Repost |> Ash.read!(authorize?: false)
    assert length(rows) == 1
    assert hd(rows).quote == "great read"

    toggle!(u, art.id)
    assert Repost |> Ash.read!(authorize?: false) == []
  end

  test "one repost per (user, article) via identity" do
    u = user("paul")
    art = article(user("john"))
    toggle!(u, art.id)

    assert {:error, _} =
             Repost
             |> Ash.Changeset.for_create(:create, %{article_id: art.id}, actor: u)
             |> Ash.create()
  end

  test "quote length is constrained to 500 chars" do
    u = user("yoko")
    art = article(user("john2"))

    assert {:error, _} =
             Repost
             |> Ash.ActionInput.for_action(:toggle,
               %{article_id: art.id, quote: String.duplicate("x", 501)},
               actor: u
             )
             |> Ash.run_action()
  end
end
```

- [ ] **Step 2: Create the `Repost` resource**

Create `lib/verscienta/social/repost.ex`:
```elixir
defmodule Verscienta.Social.Repost do
  @moduledoc "A user reposting an article into their followers' feed, optionally with a quote."
  use Ash.Resource,
    otp_app: :verscienta,
    domain: Verscienta.Social,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  postgres do
    table "reposts"
    repo Verscienta.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:article_id, :quote]
      change relate_actor(:user)
    end

    action :toggle, :term do
      description "Create the repost if absent for (user, article), else destroy it."
      argument :article_id, :uuid, allow_nil?: false
      argument :quote, :string, allow_nil?: true

      run fn input, context ->
        actor = context.actor
        article_id = input.arguments.article_id
        quote = input.arguments[:quote]

        existing =
          __MODULE__
          |> Ash.Query.filter(user_id == ^actor.id and article_id == ^article_id)
          |> Ash.read_one!(authorize?: false)

        result =
          case existing do
            nil ->
              __MODULE__
              |> Ash.Changeset.for_create(:create, %{article_id: article_id, quote: quote},
                actor: actor
              )
              |> Ash.create!(authorize?: true)

            repost ->
              Ash.destroy!(repost, authorize?: false)
              repost
          end

        Verscienta.Social.broadcast(actor.id, {:reposts_changed, actor.id})
        {:ok, result}
      end
    end

    update :update_quote do
      accept [:quote]
      require_atomic? false
    end

    read :by_users do
      argument :user_ids, {:array, :uuid}, allow_nil?: false
      filter expr(user_id in ^arg(:user_ids))
    end
  end

  policies do
    policy action(:toggle) do
      authorize_if actor_present()
    end

    policy action(:create) do
      authorize_if actor_present()
    end

    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:update_quote) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action_type(:destroy) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :quote, :string, allow_nil?: true, public?: true, constraints: [max_length: 500]
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Verscienta.Accounts.User, allow_nil?: false
    belongs_to :article, Verscienta.Content.Article, allow_nil?: false
  end

  identities do
    identity :unique_repost, [:user_id, :article_id]
  end
end
```

- [ ] **Step 3: Register the resource**

In `lib/verscienta/social.ex`, add to the `resources do` block:
```elixir
  resources do
    resource Verscienta.Social.Follow
    resource Verscienta.Social.Repost
  end
```

- [ ] **Step 4: Generate migration + run the test**

```powershell
docker compose run --rm -T app bash -lc "mix ash.codegen add_social_reposts && MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta/social/repost_test.exs"
```
Expected: a `reposts` table migration is generated; 3 tests pass.

- [ ] **Step 5: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(social): Repost resource with toggle + quote"
```
Then `git rev-parse --short HEAD`.

---

## Task 4: Trending feed (TDD)

**Files:**
- Create: `lib/verscienta/social/trending.ex`
- Modify: `lib/verscienta/social.ex` (`trending/1` delegate)
- Test: `test/verscienta/social/trending_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/social/trending_test.exs`:
```elixir
defmodule Verscienta.Social.TrendingTest do
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

  defp published_article(author, title) do
    art =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: title, excerpt: "e", category: :nutrition},
        actor: author
      )
      |> Ash.create!()

    art
    |> Ash.Changeset.for_update(:publish, %{}, actor: author)
    |> Ash.update!()
  end

  defp react!(actor, article_id, kind) do
    Verscienta.Engagement.Reaction
    |> Ash.ActionInput.for_action(:toggle, %{article_id: article_id, kind: kind}, actor: actor)
    |> Ash.run_action!()
  end

  test "trending ranks articles with more recent engagement higher" do
    author = user("ta")
    r1 = user("tr1")
    r2 = user("tr2")

    hot = published_article(author, "Hot")
    cold = published_article(author, "Cold")

    react!(r1, hot.id, :like)
    react!(r2, hot.id, :insightful)
    react!(r1, cold.id, :like)

    ids = Social.trending(limit: 10) |> Enum.map(& &1.id)
    assert hot.id in ids
    assert cold.id in ids
    assert Enum.find_index(ids, &(&1 == hot.id)) < Enum.find_index(ids, &(&1 == cold.id))
  end

  test "trending excludes unpublished articles" do
    author = user("ta2")

    draft =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: "Draft", excerpt: "e", category: :nutrition},
        actor: author
      )
      |> Ash.create!()

    ids = Social.trending(limit: 10) |> Enum.map(& &1.id)
    refute draft.id in ids
  end
end
```
NOTE: confirm the `Article` publish action name is `:publish`. If different (e.g. `:publish_article`), read `lib/verscienta/content/article.ex` actions and adjust the test helper. The assertion is "published rank by recent engagement; drafts excluded".

- [ ] **Step 2: Create the `Trending` module**

Create `lib/verscienta/social/trending.ex`:
```elixir
defmodule Verscienta.Social.Trending do
  @moduledoc """
  Read-time trending: rank published articles by engagement (reactions + comments)
  within a rolling window. Cached/optimized later via the Phase 2 caching layer.
  """
  require Ash.Query

  # Defaults — tune later.
  @window_days 7
  @reaction_weight 1
  @comment_weight 2

  def window_days, do: @window_days

  @doc "Returns up to `limit` published articles ordered by windowed engagement score, desc."
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 30)
    window_days = Keyword.get(opts, :window_days, @window_days)
    cutoff = DateTime.add(DateTime.utc_now(), -window_days * 24 * 3600, :second)

    reaction_scores = counts_since(Verscienta.Engagement.Reaction, cutoff)
    comment_scores = counts_since(Verscienta.Engagement.Comment, cutoff)

    scores =
      Map.merge(
        Map.new(reaction_scores, fn {id, n} -> {id, n * @reaction_weight} end),
        Map.new(comment_scores, fn {id, n} -> {id, n * @comment_weight} end),
        fn _id, a, b -> a + b end
      )

    ranked_ids =
      scores
      |> Enum.sort_by(fn {_id, score} -> score end, :desc)
      |> Enum.map(fn {id, _} -> id end)

    published_ids = MapSet.new(published_article_ids())

    ranked_ids
    |> Enum.filter(&MapSet.member?(published_ids, &1))
    |> Enum.take(limit)
    |> load_articles()
  end

  # %{article_id => count} for rows of `resource` created at/after cutoff.
  defp counts_since(resource, cutoff) do
    resource
    |> Ash.Query.filter(inserted_at >= ^cutoff)
    |> Ash.read!(authorize?: false)
    |> Enum.frequencies_by(& &1.article_id)
  end

  defp published_article_ids do
    Verscienta.Content.Article
    |> Ash.Query.filter(status == :published)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.id)
  end

  # Loads articles in the given id order (the ranking order).
  defp load_articles(ids) do
    by_id =
      Verscienta.Content.Article
      |> Ash.Query.filter(id in ^ids)
      |> Ash.read!(authorize?: false)
      |> Map.new(&{&1.id, &1})

    Enum.map(ids, &Map.get(by_id, &1))
    |> Enum.reject(&is_nil/1)
  end
end
```
NOTE: this reads window rows into memory and aggregates in Elixir — correct and simple for MVP volumes; the caching layer (Phase 2 cross-cutting) will optimize. Confirm `Verscienta.Engagement.Comment` has an `inserted_at` timestamp and an `article_id`; if soft-deleted comments should be excluded from the score, add a filter (read the Comment resource to see the soft-delete flag, e.g. `is_nil(deleted_at)`), and document it.

- [ ] **Step 3: Add the `trending/1` delegate to `Social`**

In `lib/verscienta/social.ex`, add:
```elixir
  @doc "Top published articles by recent engagement. See Verscienta.Social.Trending."
  defdelegate trending(opts \\ []), to: Verscienta.Social.Trending, as: :list
```

- [ ] **Step 4: Run the test**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/social/trending_test.exs"
```
Expected: 2 tests pass.

- [ ] **Step 5: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(social): trending feed (windowed engagement scoring)"
```
Then `git rev-parse --short HEAD`.

---

## Task 5: Following feed assembly (TDD)

**Files:**
- Modify: `lib/verscienta/social.ex` (`following_feed/2`)
- Test: `test/verscienta/social/following_feed_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/social/following_feed_test.exs`:
```elixir
defmodule Verscienta.Social.FollowingFeedTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Social
  alias Verscienta.Social.{Follow, Repost}

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

  defp published_article(author, title, category \\ :nutrition) do
    art =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: title, excerpt: "e", category: category},
        actor: author
      )
      |> Ash.create!()

    art
    |> Ash.Changeset.for_update(:publish, %{}, actor: author)
    |> Ash.update!()
  end

  defp follow!(actor, type, id) do
    Follow
    |> Ash.ActionInput.for_action(:toggle, %{target_type: type, target_id: to_string(id)}, actor: actor)
    |> Ash.run_action!()
  end

  test "following feed includes articles by followed authors" do
    me = user("me1")
    author = user("auth1")
    art = published_article(author, "By followed author")

    follow!(me, :user, author.id)

    items = Social.following_feed(me, limit: 50)
    assert Enum.any?(items, &(&1.type == :article and &1.article.id == art.id))
  end

  test "following feed includes articles in a followed category" do
    me = user("me2")
    author = user("auth2")
    art = published_article(author, "Mindful piece", :mindfulness)

    follow!(me, :category, "mindfulness")

    items = Social.following_feed(me, limit: 50)
    assert Enum.any?(items, &(&1.type == :article and &1.article.id == art.id))
  end

  test "following feed includes reposts by followed users" do
    me = user("me3")
    reposter = user("rp3")
    author = user("auth3")
    art = published_article(author, "Reposted piece")

    follow!(me, :user, reposter.id)

    Repost
    |> Ash.ActionInput.for_action(:toggle, %{article_id: art.id, quote: "look"}, actor: reposter)
    |> Ash.run_action!()

    items = Social.following_feed(me, limit: 50)
    assert Enum.any?(items, fn i ->
             i.type == :repost and i.article.id == art.id and i.repost.quote == "look"
           end)
  end

  test "following feed is empty when you follow nothing" do
    me = user("me4")
    assert Social.following_feed(me, limit: 50) == []
  end
end
```

- [ ] **Step 2: Implement `following_feed/2`**

In `lib/verscienta/social.ex`, add:
```elixir
  @doc """
  Time-ordered feed items for `actor`: articles from followed targets and reposts by
  followed users. Each item is `%{type: :article | :repost, article: %Article{},
  repost: %Repost{} | nil, timestamp: DateTime.t()}`.
  """
  def following_feed(actor, opts \\ []) do
    limit = Keyword.get(opts, :limit, 30)
    follows = follows_by_type(actor.id)

    user_ids = follows[:user]
    source_ids = follows[:source]
    tag_ids = follows[:tag]
    category_values = Enum.map(follows[:category], &String.to_existing_atom/1)

    article_items = following_articles(user_ids, source_ids, tag_ids, category_values)
    repost_items = following_reposts(user_ids)

    (article_items ++ repost_items)
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
    |> Enum.take(limit)
  end

  defp following_articles([], [], [], []), do: []

  defp following_articles(user_ids, source_ids, tag_ids, category_values) do
    Verscienta.Content.Article
    |> Ash.Query.filter(status == :published)
    |> Ash.Query.filter(
      author_id in ^user_ids or
        source_id in ^source_ids or
        category in ^category_values or
        exists(tags, id in ^tag_ids)
    )
    |> Ash.Query.load(:tags)
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn art ->
      %{type: :article, article: art, repost: nil, timestamp: art.published_at || art.inserted_at}
    end)
  end

  defp following_reposts([]), do: []

  defp following_reposts(user_ids) do
    Verscienta.Social.Repost
    |> Ash.Query.filter(user_id in ^user_ids)
    |> Ash.Query.load(:article)
    |> Ash.read!(authorize?: false)
    |> Enum.reject(&is_nil(&1.article))
    |> Enum.map(fn rp ->
      %{type: :repost, article: rp.article, repost: rp, timestamp: rp.inserted_at}
    end)
  end
```
NOTE: the four-empty-list clause guards against an all-empty `in []` filter. When some lists are non-empty and others empty, `x in []` is simply false in SQL — safe. `String.to_existing_atom/1` on stored category values is safe because they were validated against the `Category` enum at follow time. If `exists(tags, ...)` syntax errors in this Ash version, replace with a join filter or a two-step query (collect article ids having a followed tag via `Verscienta.Content.Article` filtered on `tags.id in ^tag_ids`); confirm against the Ash version and adjust.

- [ ] **Step 3: Run the test**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/social/following_feed_test.exs"
```
Expected: 4 tests pass.

- [ ] **Step 4: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(social): following feed (fan-in articles + reposts)"
```
Then `git rev-parse --short HEAD`.

---

## Task 6: `@mention` linkify (TDD)

**Files:**
- Create: `lib/verscienta/social/mentions.ex`
- Test: `test/verscienta/social/mentions_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/social/mentions_test.exs`:
```elixir
defmodule Verscienta.Social.MentionsTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Social.Mentions

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

  defp html({:safe, io}), do: IO.iodata_to_binary(io)

  test "links an existing @username to the profile" do
    user("alice")
    out = Mentions.linkify("hey @alice nice") |> html()
    assert out =~ ~s(<a href="/@alice">@alice</a>)
    assert out =~ "hey "
    assert out =~ " nice"
  end

  test "leaves an unknown @handle as escaped text (no link)" do
    out = Mentions.linkify("hi @ghost") |> html()
    refute out =~ "<a"
    assert out =~ "@ghost"
  end

  test "escapes HTML in surrounding text (XSS-safe)" do
    user("bob")
    out = Mentions.linkify("<script>x</script> @bob") |> html()
    refute out =~ "<script>"
    assert out =~ "&lt;script&gt;"
    assert out =~ ~s(<a href="/@bob">@bob</a>)
  end
end
```

- [ ] **Step 2: Implement `Mentions.linkify/1`**

Create `lib/verscienta/social/mentions.ex`:
```elixir
defmodule Verscienta.Social.Mentions do
  @moduledoc """
  Render-time linkification of `@username` mentions in plain-text bodies.
  Stored bodies remain plain text; this produces XSS-safe HTML for display:
  existing usernames become profile links, all other text is HTML-escaped.
  """
  require Ash.Query

  @mention_regex ~r/@([A-Za-z0-9_]{3,30})/

  @doc "Returns a `{:safe, iodata}` HEEx-renderable value with mentions linked."
  def linkify(body) when is_binary(body) do
    usernames =
      @mention_regex
      |> Regex.scan(body, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    existing = existing_usernames(usernames)

    iodata =
      body
      |> split_keep_mentions()
      |> Enum.map(fn
        {:mention, handle} ->
          if MapSet.member?(existing, String.downcase(handle)) do
            ["<a href=\"/@", handle, "\">@", handle, "</a>"]
          else
            Phoenix.HTML.html_escape("@" <> handle) |> safe_to_iodata()
          end

        {:text, text} ->
          Phoenix.HTML.html_escape(text) |> safe_to_iodata()
      end)

    {:safe, iodata}
  end

  def linkify(_), do: {:safe, []}

  # Split into ordered {:text, ...} / {:mention, handle} parts.
  defp split_keep_mentions(body) do
    parts = Regex.split(@mention_regex, body, include_captures: true, trim: false)

    Enum.map(parts, fn part ->
      case Regex.run(@mention_regex, part) do
        [^part, handle] -> {:mention, handle}
        _ -> {:text, part}
      end
    end)
    |> Enum.reject(fn {_, v} -> v == "" end)
  end

  defp existing_usernames([]), do: MapSet.new()

  defp existing_usernames(usernames) do
    downcased = Enum.map(usernames, &String.downcase/1)

    Verscienta.Accounts.User
    |> Ash.Query.filter(fragment("lower(?::text) = any(?)", username, ^downcased))
    |> Ash.read!(authorize?: false)
    |> Enum.map(&String.downcase(to_string(&1.username)))
    |> MapSet.new()
  end

  defp safe_to_iodata({:safe, io}), do: io
end
```
NOTE: `username` is a `ci_string` — the `fragment` lowercases for a case-insensitive `= any(...)` match. If the fragment errors in this Ash/AshPostgres version, fall back to loading candidate users with `Ash.Query.filter(username in ^usernames)` and comparing case-insensitively in Elixir. The links are built from the **regex-captured handle** (charset `[A-Za-z0-9_]`), which cannot contain HTML metacharacters, so the anchor is safe; all other text goes through `Phoenix.HTML.html_escape/1`.

- [ ] **Step 3: Run the test**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/social/mentions_test.exs"
```
Expected: 3 tests pass.

- [ ] **Step 4: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(social): XSS-safe @mention linkify"
```
Then `git rev-parse --short HEAD`.

---

## Task 7: Follow button component + PubSub event helper (TDD)

**Files:**
- Create: `lib/verscienta_web/components/social_components.ex`
- Test: `test/verscienta_web/components/social_components_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/components/social_components_test.exs`:
```elixir
defmodule VerscientaWeb.SocialComponentsTest do
  use VerscientaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import VerscientaWeb.SocialComponents

  test "renders a follow button in the not-following state" do
    html =
      render_component(&follow_button/1, %{
        target_type: :user,
        target_id: "abc",
        following?: false,
        count: 3
      })

    assert html =~ "follow"
    assert html =~ ~s(phx-click="toggle_follow")
    assert html =~ ~s(phx-value-target_type="user")
    assert html =~ ~s(phx-value-target_id="abc")
    assert html =~ "3"
  end

  test "renders the following state" do
    html =
      render_component(&follow_button/1, %{
        target_type: :tag,
        target_id: "t1",
        following?: true,
        count: 10
      })

    assert html =~ "following"
  end
end
```

- [ ] **Step 2: Implement the component module**

Create `lib/verscienta_web/components/social_components.ex`:
```elixir
defmodule VerscientaWeb.SocialComponents do
  @moduledoc "Shared social UI: follow button and feed item rendering."
  use Phoenix.Component

  @doc """
  A follow/unfollow button. Emits a `toggle_follow` event with `target_type`/`target_id`
  values; the host LiveView handles it (optimistic + persisted via Social.Follow.toggle).
  """
  attr :target_type, :atom, required: true
  attr :target_id, :string, required: true
  attr :following?, :boolean, default: false
  attr :count, :integer, default: nil
  attr :class, :string, default: ""

  def follow_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_follow"
      phx-value-target_type={@target_type}
      phx-value-target_id={@target_id}
      aria-pressed={to_string(@following?)}
      class={[
        "inline-flex items-center gap-2 border px-3 py-1 text-[11px] font-bold uppercase tracking-wider transition-colors",
        @following? && "border-line text-ink-3 hover:text-ink",
        !@following? && "border-zune text-zune hover:bg-zune hover:text-black",
        @class
      ]}
    >
      {if @following?, do: "following", else: "follow"}
      <span :if={is_integer(@count)} class="text-ink-3">{@count}</span>
    </button>
    """
  end

  @doc "Renders a single Following-feed item (article or repost wrapper)."
  attr :item, :map, required: true

  def feed_item(assigns) do
    ~H"""
    <article class="border-b border-line py-5">
      <p :if={@item.type == :repost} class="mb-2 text-[11px] uppercase tracking-wider text-ink-3">
        ↻ @{@item.repost.user && @item.repost.user.username} reposted
      </p>
      <blockquote
        :if={@item.type == :repost and @item.repost.quote}
        class="mb-3 border-l-2 border-zune pl-3 text-sm text-ink-2"
      >
        {@item.repost.quote}
      </blockquote>
      <a href={"/articles/" <> @item.article.slug} class="block">
        <h3 class="text-lg font-light lowercase text-ink transition-colors hover:text-zune">
          {@item.article.title}
        </h3>
        <p :if={@item.article.excerpt} class="mt-1 text-sm text-ink-3">{@item.article.excerpt}</p>
      </a>
    </article>
    """
  end
end
```
NOTE: `feed_item/1` reads `@item.repost.user.username`; the Following feed must `load(:user)` on reposts for this to render — Task 9 wires that. For now the component test only exercises `follow_button/1`. The `aria-pressed` reflects state for a11y.

- [ ] **Step 3: Run the test**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/components/social_components_test.exs"
```
Expected: 2 tests pass.

- [ ] **Step 4: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(social): follow button + feed item components"
```
Then `git rev-parse --short HEAD`.

---

## Task 8: Profile integration — counts, button, followers/following lists (TDD)

**Files:**
- Modify: `lib/verscienta_web/live/profile_live.ex`
- Modify: `lib/verscienta_web/router.ex` (add `/@:username/followers` + `/@:username/following` live routes)
- Test: `test/verscienta_web/live/profile_social_test.exs`

- [ ] **Step 1: Read the current files**

```powershell
docker compose run --rm -T app bash -lc "cat lib/verscienta_web/live/profile_live.ex"
```
Note the `mount/3`, the `live_session` it sits in (router), and the render structure. The profile is in the `:authenticated_routes` live session today (route `live "/@:username", ProfileLive, :show`).

- [ ] **Step 2: Write the failing test**

Create `test/verscienta_web/live/profile_social_test.exs`:
```elixir
defmodule VerscientaWeb.ProfileSocialTest do
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

  test "shows follower/following counts on a profile", %{conn: conn} do
    me = user("viewer")
    target = user("target")

    {:ok, _view, html} = conn |> sign_in(me) |> live(~p"/@target")
    assert html =~ "followers"
    assert html =~ "following"
    # a follow button is present for another user's profile
    assert html =~ ~s(phx-click="toggle_follow")
    refute target.id == me.id
  end

  test "clicking follow toggles the persisted follow", %{conn: conn} do
    me = user("clicker")
    _target = user("clicked")

    {:ok, view, _html} = conn |> sign_in(me) |> live(~p"/@clicked")

    refute Verscienta.Social.following?(me, :user, target_id(view))
    render_click(element(view, ~s(button[phx-click="toggle_follow"])))
    # re-fetch actor to evaluate following?
    me = Ash.get!(Verscienta.Accounts.User, me.id, authorize?: false)
    assert Verscienta.Social.following_count(me.id) == 1
  end

  defp target_id(_view), do: Ash.read!(Verscienta.Accounts.User, authorize?: false) |> Enum.find(&(&1.username == "clicked")) |> Map.get(:id)

  test "own profile does not show a follow button", %{conn: conn} do
    me = user("solo")
    {:ok, _view, html} = conn |> sign_in(me) |> live(~p"/@solo")
    refute html =~ ~s(phx-click="toggle_follow")
  end
end
```

- [ ] **Step 3: Add the followers/following routes**

In `lib/verscienta_web/router.ex`, inside the SAME `ash_authentication_live_session :authenticated_routes` block that has `live "/@:username", ProfileLive, :show`, add:
```elixir
      live "/@:username/followers", ProfileLive, :followers
      live "/@:username/following", ProfileLive, :following
```

- [ ] **Step 4: Update `ProfileLive`**

In `lib/verscienta_web/live/profile_live.ex`, update `mount/3` to load social data, add `handle_params/3` for the `:show`/`:followers`/`:following` live actions, a `toggle_follow` handler, and PubSub. Use this structure (adapt to the existing module — keep its existing assigns and render, ADD the social parts):
```elixir
  alias Verscienta.Social
  import VerscientaWeb.SocialComponents

  @impl true
  def mount(%{"username" => username}, _session, socket) do
    user =
      Verscienta.Accounts.User
      |> Ash.Query.filter(username == ^username)
      |> Ash.Query.load(user_badges: [:badge])
      |> Ash.read_one!(authorize?: false)
      |> case do
        nil -> raise Ash.Error.Query.NotFound
        u -> u
      end

    if connected?(socket), do: Social.subscribe(user.id)

    {:ok,
     socket
     |> assign(:user, user)
     |> assign_social()}
  end

  defp assign_social(socket) do
    user = socket.assigns.user
    actor = socket.assigns[:current_user]

    socket
    |> assign(:followers_count, Social.follower_count(:user, user.id))
    |> assign(:following_count, Social.following_count(user.id))
    |> assign(:following_this?, Social.following?(actor, :user, user.id))
    |> assign(:is_self?, actor != nil and actor.id == user.id)
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :live_action_list, list_for(socket))}
  end

  defp list_for(%{assigns: %{live_action: :followers, user: user}}) do
    ids = Social.follower_user_ids(user.id)
    load_users(ids)
  end

  defp list_for(%{assigns: %{live_action: :following, user: user}}) do
    ids = Social.followed_user_ids(user.id)
    load_users(ids)
  end

  defp list_for(_socket), do: []

  defp load_users([]), do: []

  defp load_users(ids) do
    Verscienta.Accounts.User
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(authorize?: false)
  end

  @impl true
  def handle_event("toggle_follow", %{"target_type" => type, "target_id" => id}, socket) do
    actor = socket.assigns[:current_user]

    if actor do
      Verscienta.Social.Follow
      |> Ash.ActionInput.for_action(:toggle, %{target_type: String.to_existing_atom(type), target_id: id},
        actor: actor
      )
      |> Ash.run_action!()
    end

    {:noreply, assign_social(socket)}
  end

  @impl true
  def handle_info({:followers_changed, _id}, socket), do: {:noreply, assign_social(socket)}
  def handle_info({:following_changed, _id}, socket), do: {:noreply, assign_social(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}
```
Then in the profile's render, near the existing counts row, add the counts + button (only when not self):
```heex
<div class="mt-4 flex flex-wrap items-center gap-3 text-[11px] uppercase tracking-wider text-ink-3">
  <a href={"/@" <> to_string(@user.username) <> "/followers"} class="hover:text-ink">
    {@followers_count} followers
  </a>
  <a href={"/@" <> to_string(@user.username) <> "/following"} class="hover:text-ink">
    {@following_count} following
  </a>
  <.follow_button
    :if={not @is_self? and @current_user}
    target_type={:user}
    target_id={to_string(@user.id)}
    following?={@following_this?}
  />
</div>

<div :if={@live_action in [:followers, :following]} class="mt-8">
  <h2 class="mb-4 text-sm lowercase tracking-wider text-ink-3">{to_string(@live_action)}</h2>
  <ul class="divide-y divide-line">
    <li :for={u <- @live_action_list} class="py-3">
      <a href={"/@" <> to_string(u.username)} class="text-ink hover:text-zune">
        @{u.username}
      </a>
    </li>
    <li :if={@live_action_list == []} class="py-3 text-ink-3">nobody yet.</li>
  </ul>
</div>
```
NOTE: `ProfileLive` is in the authenticated live session, so `@current_user` is available. If the existing render lacks an `@live_action`-based section, only render the list block for `:followers`/`:following`. Ensure `handle_params/3` runs `assign(:live_action_list, ...)` so `:show` gets `[]`. Keep all existing profile markup (avatar, badges, bio).

- [ ] **Step 5: Run the test**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/profile_social_test.exs"
```
Expected: 3 tests pass. If the `target_id/1` helper in the test is awkward, simplify by capturing the target user struct in the test setup and asserting `Social.following_count(me.id) == 1` after the click.

- [ ] **Step 6: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(social): profile follow button, counts, followers/following lists"
```
Then `git rev-parse --short HEAD`.

---

## Task 9: Feed pivot — Latest / Following / Trending tabs (TDD)

**Files:**
- Modify: `lib/verscienta_web/live/article_feed_live.ex`
- Modify: `lib/verscienta/social.ex` (load `:user` on reposts in `following_feed`)
- Test: `test/verscienta_web/live/feed_pivot_test.exs`

- [ ] **Step 1: Read the current feed LiveView**

```powershell
docker compose run --rm -T app bash -lc "cat lib/verscienta_web/live/article_feed_live.ex"
```
Note its `mount/3` (currently `Ash.read!(Article, action: :list_published, ...)`), render, and the public live session it's in (it's under `:public_routes`, so `@current_user` is optional).

- [ ] **Step 2: Ensure reposts load their author (for the feed item header)**

In `lib/verscienta/social.ex`, in `following_reposts/1`, change the load to include the user:
```elixir
    Verscienta.Social.Repost
    |> Ash.Query.filter(user_id in ^user_ids)
    |> Ash.Query.load([:article, :user])
```

- [ ] **Step 3: Write the failing test**

Create `test/verscienta_web/live/feed_pivot_test.exs`:
```elixir
defmodule VerscientaWeb.FeedPivotTest do
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

  test "feed shows the three tabs", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/articles")
    assert html =~ "latest"
    assert html =~ "following"
    assert html =~ "trending"
  end

  test "following tab prompts sign-in when signed out", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/articles?feed=following")
    assert html =~ "sign in" or html =~ "Sign in"
  end

  test "following tab renders for a signed-in user", %{conn: conn} do
    me = user("feeduser")
    {:ok, _view, html} = conn |> sign_in(me) |> live(~p"/articles?feed=following")
    # empty state is fine; just assert it rendered the following view, not a crash
    assert html =~ "following"
  end
end
```

- [ ] **Step 4: Rework `ArticleFeedLive`**

Rewrite `lib/verscienta_web/live/article_feed_live.ex` to drive content off a `feed` URL param via `handle_params/3`. Keep the module name + any existing helpers; replace mount/render:
```elixir
defmodule VerscientaWeb.ArticleFeedLive do
  use VerscientaWeb, :live_view

  alias Verscienta.Content.Article
  alias Verscienta.Social
  import VerscientaWeb.SocialComponents

  @tabs ~w(latest following trending)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "articles")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = normalize_tab(params["feed"])
    {:noreply, socket |> assign(:tab, tab) |> load_feed(tab)}
  end

  defp normalize_tab(t) when t in @tabs, do: t
  defp normalize_tab(_), do: "latest"

  defp load_feed(socket, "latest") do
    articles = Ash.read!(Article, action: :list_published, authorize?: false)
    assign(socket, articles: articles, items: nil, needs_signin?: false)
  end

  defp load_feed(socket, "trending") do
    assign(socket, articles: Social.trending(limit: 30), items: nil, needs_signin?: false)
  end

  defp load_feed(socket, "following") do
    case socket.assigns[:current_user] do
      nil ->
        assign(socket, articles: [], items: [], needs_signin?: true)

      user ->
        assign(socket, articles: nil, items: Social.following_feed(user, limit: 30), needs_signin?: false)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl px-6 pt-24">
      <nav aria-label="feed tabs" class="mb-8 flex gap-5 text-xs lowercase tracking-wider text-ink-3">
        <.link
          :for={t <- ~w(latest following trending)}
          patch={"/articles?feed=" <> t}
          class={[@tab == t && "text-zune", @tab != t && "hover:text-ink"]}
        >
          {t}
        </.link>
      </nav>

      <div :if={@needs_signin?} class="py-16 text-center text-ink-3">
        <p>sign in to see content from people and topics you follow.</p>
        <a href="/sign-in" class="mt-3 inline-block text-zune hover:text-ink">sign in</a>
      </div>

      <div :if={@tab == "following" and not @needs_signin?}>
        <.feed_item :for={item <- @items} item={item} />
        <p :if={@items == []} class="py-16 text-center text-ink-3">
          your following feed is empty — find people and topics to follow.
        </p>
      </div>

      <div :if={@tab in ["latest", "trending"]} class="divide-y divide-line">
        <a :for={a <- @articles} href={"/articles/" <> a.slug} class="block py-5">
          <h3 class="text-lg font-light lowercase text-ink transition-colors hover:text-zune">
            {a.title}
          </h3>
          <p :if={a.excerpt} class="mt-1 text-sm text-ink-3">{a.excerpt}</p>
        </a>
        <p :if={@articles == []} class="py-16 text-center text-ink-3">nothing here yet.</p>
      </div>
    </div>
    """
  end
end
```
NOTE: this LiveView is in the `:public_routes` live session whose `on_mount` loads `current_user` optionally — so `@current_user` is available (possibly nil). Confirm by reading the router; if `current_user` isn't assigned on this session, use `socket.assigns[:current_user]` (already done) which is nil-safe. The tab links use `patch` so switching tabs runs `handle_params/3` without a full remount.

- [ ] **Step 5: Run the test**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/feed_pivot_test.exs"
```
Expected: 3 tests pass.

- [ ] **Step 6: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(social): Latest/Following/Trending feed pivot"
```
Then `git rev-parse --short HEAD`.

---

## Task 10: Reader integration — @mentions in comments + repost affordance (TDD)

**Files:**
- Modify: the article reader LiveView (find it: `grep -rl "ArticleReaderLive" lib/verscienta_web/live`)
- Test: `test/verscienta_web/live/reader_social_test.exs`

- [ ] **Step 1: Locate + read the reader LiveView**

```powershell
docker compose run --rm -T app bash -lc "ls lib/verscienta_web/live | grep -i read; echo '---'; cat lib/verscienta_web/live/article_reader_live.ex"
```
Find where comments are rendered (the comment body output) and where article-level actions (reactions/bookmark) live — the repost button goes alongside those.

- [ ] **Step 2: Write the failing test**

Create `test/verscienta_web/live/reader_social_test.exs`:
```elixir
defmodule VerscientaWeb.ReaderSocialTest do
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

  defp published_article(author) do
    art =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: "Readable", excerpt: "e", category: :nutrition},
        actor: author
      )
      |> Ash.create!()

    art
    |> Ash.Changeset.for_update(:publish, %{}, actor: author)
    |> Ash.update!()
  end

  test "a @mention in a comment renders as a profile link", %{conn: conn} do
    author = user("rauthor")
    mentioned = user("mentionee")
    art = published_article(author)

    Verscienta.Engagement.Comment
    |> Ash.Changeset.for_create(:create, %{article_id: art.id, body: "hi @mentionee"}, actor: author)
    |> Ash.create!()

    {:ok, _view, html} = conn |> sign_in(author) |> live(~p"/articles/#{art.slug}")
    assert html =~ ~s(href="/@mentionee")
    refute mentioned.id == author.id
  end

  test "signed-in user sees a repost control", %{conn: conn} do
    author = user("rauthor2")
    reader = user("rreader")
    art = published_article(author)

    {:ok, _view, html} = conn |> sign_in(reader) |> live(~p"/articles/#{art.slug}")
    assert html =~ ~s(phx-click="toggle_repost")
  end
end
```
NOTE: confirm the `Comment` create action name + accepted fields (`article_id`, `body`) by reading `lib/verscienta/engagement/comment.ex`; adjust the test's create call if the action differs. Confirm the reader route is `~p"/articles/#{slug}"`.

- [ ] **Step 3: Apply mention linkify in the comment render**

In the reader LiveView, where each comment body is currently rendered (likely `{comment.body}` or similar), replace the plain output with the linkified safe HTML:
```heex
{Verscienta.Social.Mentions.linkify(comment.body)}
```
Because `linkify/1` returns `{:safe, iodata}`, HEEx renders it without escaping the (already-safe) HTML. Keep any existing wrapping markup/classes around it.

- [ ] **Step 4: Add the repost control + handler**

Where the article-level actions render (next to reactions/bookmark), add a repost button for signed-in users:
```heex
<button
  :if={@current_user}
  type="button"
  phx-click="toggle_repost"
  class="inline-flex items-center gap-2 border border-line px-3 py-1 text-[11px] font-bold uppercase tracking-wider text-ink-3 transition-colors hover:text-ink"
>
  ↻ {if @reposted?, do: "reposted", else: "repost"}
</button>
```
Add to `mount/3` (after the article is loaded) an assign for the current user's repost state:
```elixir
    reposted? =
      case socket.assigns[:current_user] do
        nil -> false
        user -> Verscienta.Social.reposted?(user, article.id)
      end

    socket = assign(socket, :reposted?, reposted?)
```
Add the handler:
```elixir
  @impl true
  def handle_event("toggle_repost", _params, socket) do
    actor = socket.assigns[:current_user]

    if actor do
      Verscienta.Social.Repost
      |> Ash.ActionInput.for_action(:toggle, %{article_id: socket.assigns.article.id}, actor: actor)
      |> Ash.run_action!()
    end

    {:noreply, assign(socket, :reposted?, actor != nil and Verscienta.Social.reposted?(actor, socket.assigns.article.id))}
  end
```
And add the `reposted?/2` helper to `lib/verscienta/social.ex`:
```elixir
  @doc "Whether `actor` has reposted the given article."
  def reposted?(nil, _article_id), do: false

  def reposted?(actor, article_id) do
    Verscienta.Social.Repost
    |> Ash.Query.filter(user_id == ^actor.id and article_id == ^article_id)
    |> Ash.read_one!(authorize?: false)
    |> is_struct()
  end
```
NOTE: add `require Ash.Query` at the top of `social.ex` if not already present (it is, from Task 1). The quote-on-repost UI (textarea) is intentionally minimal here — a plain repost toggle. A quote field can be added later; `Repost.toggle` already accepts an optional `quote`.

- [ ] **Step 5: Run the test**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/reader_social_test.exs"
```
Expected: 2 tests pass.

- [ ] **Step 6: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(social): @mentions in comments + repost control on reader"
```
Then `git rev-parse --short HEAD`.

---

## Task 11: Category page follow button (TDD)

**Files:**
- Modify: `lib/verscienta_web/live/category_live.ex`
- Test: `test/verscienta_web/live/category_follow_test.exs`

- [ ] **Step 1: Read the current category LiveView**

```powershell
docker compose run --rm -T app bash -lc "cat lib/verscienta_web/live/category_live.ex"
```
Note its `mount/3` (`/c/:category`), how it resolves the category (slug → key via `Verscienta.Content.Category.from_slug/1`), and the live session (public).

- [ ] **Step 2: Write the failing test**

Create `test/verscienta_web/live/category_follow_test.exs`:
```elixir
defmodule VerscientaWeb.CategoryFollowTest do
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

  test "signed-in user sees a follow button on a category page", %{conn: conn} do
    me = user("catfan")
    {:ok, view, html} = conn |> sign_in(me) |> live(~p"/c/nutrition")
    assert html =~ ~s(phx-click="toggle_follow")

    render_click(element(view, ~s(button[phx-click="toggle_follow"])))
    assert Verscienta.Social.following?(me, :category, "nutrition")
  end

  test "signed-out user does not see a follow button", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/c/nutrition")
    refute html =~ ~s(phx-click="toggle_follow")
  end
end
```

- [ ] **Step 3: Add the follow button + handler to `CategoryLive`**

Add the social wiring (mirror Task 8's `toggle_follow` handler). In `mount/3`, after resolving the category key (call it `category` — an atom like `:nutrition`), assign follow state:
```elixir
    actor = socket.assigns[:current_user]
    category_id = to_string(category)

    socket =
      socket
      |> assign(:category_key, category)
      |> assign(:follow_target_id, category_id)
      |> assign(:following_category?, Verscienta.Social.following?(actor, :category, category_id))
      |> assign(:category_followers, Verscienta.Social.follower_count(:category, category_id))
```
Add the import + handler:
```elixir
  import VerscientaWeb.SocialComponents

  @impl true
  def handle_event("toggle_follow", %{"target_type" => type, "target_id" => id}, socket) do
    actor = socket.assigns[:current_user]

    if actor do
      Verscienta.Social.Follow
      |> Ash.ActionInput.for_action(:toggle, %{target_type: String.to_existing_atom(type), target_id: id},
        actor: actor
      )
      |> Ash.run_action!()
    end

    {:noreply,
     socket
     |> assign(:following_category?, Verscienta.Social.following?(actor, :category, socket.assigns.follow_target_id))
     |> assign(:category_followers, Verscienta.Social.follower_count(:category, socket.assigns.follow_target_id))}
  end
```
In the render (near the category title), add:
```heex
<.follow_button
  :if={@current_user}
  target_type={:category}
  target_id={@follow_target_id}
  following?={@following_category?}
  count={@category_followers}
/>
```
NOTE: `String.to_existing_atom/1` on the `target_type` string ("category") is safe — the atom already exists. Keep all existing category-page markup (the article list).

- [ ] **Step 4: Run the test**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/category_follow_test.exs"
```
Expected: 2 tests pass.

- [ ] **Step 5: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(social): category page follow button"
```
Then `git rev-parse --short HEAD`.

---

## Task 12: Seeds + nav link + full verification + merge prep

**Files:**
- Modify: `priv/repo/seeds.exs`
- Modify: `lib/verscienta_web/components/layouts.ex` (optional: a "following" nav hint — only if trivial)
- Modify: `docs/todo.md` (tick Social Graph items)

- [ ] **Step 1: Read the existing seeds to match style**

```powershell
docker compose run --rm -T app bash -lc "cat priv/repo/seeds.exs | tail -60"
```
Note how users/articles are created (helper functions, idempotency guards) so the social seeds match.

- [ ] **Step 2: Append idempotent social seeds**

At the end of `priv/repo/seeds.exs`, add follows + a repost between existing seeded users/articles, guarded so re-running `mix ash.setup`/seeds doesn't duplicate (toggle is naturally idempotent only as a pair — instead use `Social.following?` guards). Example (adapt names to the actual seeded users/articles in the file):
```elixir
# --- Social graph seeds (idempotent) ---
alias Verscienta.Social
alias Verscienta.Social.{Follow, Repost}

with [%{} = u1, %{} = u2 | _] <-
       Verscienta.Accounts.User |> Ash.read!(authorize?: false) |> Enum.sort_by(& &1.username) do
  unless Social.following?(u1, :user, u2.id) do
    Follow
    |> Ash.ActionInput.for_action(:toggle, %{target_type: :user, target_id: to_string(u2.id)}, actor: u1)
    |> Ash.run_action!()
  end

  unless Social.following?(u1, :category, "nutrition") do
    Follow
    |> Ash.ActionInput.for_action(:toggle, %{target_type: :category, target_id: "nutrition"}, actor: u1)
    |> Ash.run_action!()
  end

  case Verscienta.Content.Article
       |> Ash.Query.filter(status == :published)
       |> Ash.read!(authorize?: false) do
    [art | _] ->
      unless Social.reposted?(u2, art.id) do
        Repost
        |> Ash.ActionInput.for_action(:toggle, %{article_id: art.id, quote: "worth a read"}, actor: u2)
        |> Ash.run_action!()
      end

    [] ->
      :ok
  end
end
```
Add `require Ash.Query` at the top of `seeds.exs` if not present.

- [ ] **Step 3: Run the seeds to confirm they're idempotent**

```powershell
docker compose run --rm -T app bash -lc "mix ash.setup && mix run priv/repo/seeds.exs && mix run priv/repo/seeds.exs"
```
Expected: runs twice with no crash and no duplicate-identity errors (the `following?`/`reposted?` guards prevent re-creates).

- [ ] **Step 4: Tick the todo items**

In `docs/todo.md`, under "### Social Graph", update:
```markdown
- [x] `Follow` resource (user→user, user→topic/tag).
- [x] Follow/unfollow with live counts + optimistic UI.
- [x] "Following" vs "For You" vs "Trending" pivot on the home feed. *(Following + Trending; For You is Phase 3)*
- [x] Mentions (`@user`) parsing + linking in posts/comments. *(comments; posts later)*
- [x] Reposts / quote-reposts.
```

- [ ] **Step 5: Full clean-deps gate**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "mix deps.get && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
```
Expected: format clean, credo 0 issues, no warnings, ALL tests pass. Capture the exact `N tests, 0 failures` line.

- [ ] **Step 6: Commit**

```powershell
git add -A
git commit -m "feat(social): seeds + todo updates for social graph"
```
Then `git rev-parse --short HEAD`.

---

## Definition of Done (verify all)

- [ ] `Follow` (4 target types) + `Repost` in `Verscienta.Social`; migrations applied; domain registered.
- [ ] Follow toggle idempotent; self-follow rejected; direct destroy forbidden; target existence validated.
- [ ] Follower/following counts + followers/following list pages on profiles.
- [ ] Follow buttons on profile + category pages with optimistic state and live count updates (PubSub).
- [ ] `/articles` Latest / Following / Trending tabs; Following gated to signed-in users; Following merges followed-target articles + reposts by followed users; Trending ranks by windowed engagement.
- [ ] `@username` in comments renders as safe profile links; unknown handles stay escaped text; XSS neutralized.
- [ ] Repost toggle on the reader; reposts appear in followers' Following feed.
- [ ] Seeds idempotent and don't break existing list-count test assertions.
- [ ] `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test` all pass.
- [ ] Migrations via `mix ash.codegen`; `docs/todo.md` updated; work committed on `social-graph`.
