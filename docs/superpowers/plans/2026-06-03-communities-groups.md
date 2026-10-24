# Communities & Groups Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** User-created groups (public communities + private groups) with per-group roles, join/request/invite flows, ownership transfer, group-tagged Articles (siloed from global surfaces), a directory, and management UI.

**Architecture:** A new `Verscienta.Communities` domain (`Group`, `GroupMembership`) with membership transitions as generic run-fn actions (like `Social.Follow.toggle`) doing explicit role checks via a `Communities` context (`role/2`, `member?/2`, `can_moderate?/2`). `Article` gains an optional `group_id`; group articles are excluded from `list_published`/trending/following/search by `is_nil(group_id)` filters, and private-group content is gated by active membership in the LiveViews.

**Tech Stack:** Phoenix 1.8, Ash 3 + AshPostgres, LiveView, Tailwind v4 (Codex tokens).

---

## Conventions for the executor

- **Run everything in Docker.** `docker compose run --rm -T app bash -lc "<cmd>"`. Start DB: `docker compose up -d db`. Generous timeouts. If "dependency not available", prefix `mix deps.get &&`.
- **One task at a time.** After each task run `git rev-parse --short HEAD` for the REAL sha. Never batch tasks or guess SHAs. **Re-run the FULL gate (`mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `MIX_ENV=test mix test`) after the FINAL edit of each task, BEFORE committing.**
- **Branch:** `communities` (already checked out; spec committed `4d97fd6`).
- **Line endings:** `.gitattributes` eol=lf, autocrlf false — don't change. `mix format` before commit. No `.bak`.
- **Git identity:** no local override. Commit body ends with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- **Migrations:** `mix ash.codegen <name>` AFTER resources/attrs are defined + registered. Apply in test with `MIX_ENV=test mix ash.setup`. Never hand-write migrations.
- **Reuse patterns (read before editing):**
  - Join resource + generic run-fn action: `lib/verscienta/social/follow.ex` (`action :toggle, :term` with `run fn input, context -> {:ok, result} end`, unique identity, `forbid_if always()` on direct destroy).
  - Slug: `lib/verscienta/content/slug.ex` (`slugify/1`) + `lib/verscienta/content/article/changes/generate_slug.ex` (around-transaction retry).
  - Role-in-policy: `Engagement.Comment` soft_delete (`^actor(:role) in [:moderator, :admin]`), `Content.Source` admin-only.
  - Domain registration: `config/config.exs` `ash_domains`. Domain module pattern: `Verscienta.Social`.
  - Article actions/policies/relationships: `lib/verscienta/content/article.ex` (you ADD `group_id` + isolation filters + `:list_by_group` + a member-posting validation).
  - Search enqueue/index: `lib/verscienta/content/article/changes/enqueue_index.ex` + the search index worker + document builder (you SKIP group articles).
  - Social feed/trending: `lib/verscienta/social.ex` `following_articles/4`, `lib/verscienta/social/trending.ex` (you add `is_nil(group_id)`).
  - LiveView routes: `lib/verscienta_web/router.ex` (public live_session vs `ash_authentication_live_session :authenticated_routes`). Directory/detail LiveView shapes: `ArticleFeedLive`, `ProfileLive`, `AdminSourcesLive`. Editor: `lib/verscienta_web/live/article_editor_live.ex`. Nav: `nav_links/1` in `lib/verscienta_web/components/layouts.ex`.
  - Codex tokens: `bg-canvas`/`bg-canvas-2`, `border-line`, `text-ink`/`text-ink-3`, `text-zune`/`bg-zune`, `text-politics` (error).

---

## File Structure

| File | Responsibility |
|------|----------------|
| `lib/verscienta/communities.ex` | domain + context helpers (`role/2`, `member?/2`, `can_moderate?/2`, `membership/2`, list helpers) |
| `lib/verscienta/communities/group.ex` | `Group` resource (slug, visibility, owner, member_count, transfer_ownership) |
| `lib/verscienta/communities/group_membership.ex` | `GroupMembership` (role/status + join/request/invite/accept/approve/decline/remove/leave/promote/demote) |
| `lib/verscienta/content/article.ex` | `group_id` + member-posting validation + `:list_by_group` + isolation filter on `:list_published` |
| `lib/verscienta/social.ex`, `lib/verscienta/social/trending.ex` | isolation: exclude `group_id` articles from feeds/trending |
| search enqueue/worker/doc builder | isolation: skip group articles |
| `config/config.exs` | register `Verscienta.Communities` |
| `lib/verscienta_web/live/groups_live.ex` | `/groups` directory + create |
| `lib/verscienta_web/live/group_live.ex` | `/groups/:slug` page (+ `:manage`, `:settings` live_actions) |
| `lib/verscienta_web/live/article_editor_live.ex` | "post to group" selector |
| `lib/verscienta_web/router.ex`, `lib/verscienta_web/components/layouts.ex` | routes + nav link |
| `priv/repo/seeds.exs`, tests | seeds + per-task tests |

---

## Task 1: Communities domain + Group + GroupMembership skeleton (TDD)

**Files:**
- Create: `lib/verscienta/communities/group.ex`, `lib/verscienta/communities/group_membership.ex`, `lib/verscienta/communities.ex`
- Modify: `config/config.exs`
- Test: `test/verscienta/communities/group_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/communities/group_test.exs`:
```elixir
defmodule Verscienta.Communities.GroupTest do
  use Verscienta.DataCase, async: true

  require Ash.Query
  alias Verscienta.Communities
  alias Verscienta.Communities.{Group, GroupMembership}

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

  defp create_group!(actor, attrs \\ %{}) do
    base = %{name: "Wellness Circle", description: "A group", visibility: :public}

    Group
    |> Ash.Changeset.for_create(:create, Map.merge(base, attrs), actor: actor)
    |> Ash.create!()
  end

  test "creating a group sets a slug, owner, and an active owner membership" do
    u = user("owner1")
    g = create_group!(u)

    assert g.slug == "wellness-circle"
    assert g.owner_id == u.id

    memberships = GroupMembership |> Ash.Query.filter(group_id == ^g.id) |> Ash.read!(authorize?: false)
    assert [%{user_id: uid, role: :owner, status: :active}] = memberships
    assert uid == u.id
  end

  test "member_count reflects active memberships" do
    u = user("owner2")
    g = create_group!(u) |> Ash.load!(:member_count, authorize?: false)
    assert g.member_count == 1
  end

  test "only the owner can update or destroy the group" do
    owner = user("owner3")
    other = user("other3")
    g = create_group!(owner)

    assert {:error, _} =
             g |> Ash.Changeset.for_update(:update, %{name: "Hacked"}, actor: other) |> Ash.update()

    assert {:ok, _} =
             g |> Ash.Changeset.for_update(:update, %{name: "Renamed"}, actor: owner) |> Ash.update()
  end

  test "list_public excludes private groups" do
    u = user("owner4")
    _pub = create_group!(u, %{name: "Public One", visibility: :public})
    _priv = create_group!(u, %{name: "Private One", visibility: :private})

    names = Group |> Ash.read!(action: :list_public, authorize?: false) |> Enum.map(& &1.name)
    assert "Public One" in names
    refute "Private One" in names
  end

  test "Communities.role/member?/can_moderate? reflect the owner membership" do
    u = user("owner5")
    g = create_group!(u)
    assert Communities.role(u, g) == :owner
    assert Communities.member?(u, g)
    assert Communities.can_moderate?(u, g)
  end
end
```

- [ ] **Step 2: Create the GroupMembership resource**

Create `lib/verscienta/communities/group_membership.ex`:
```elixir
defmodule Verscienta.Communities.GroupMembership do
  @moduledoc "A user's membership in a group, with a per-group role and a status."
  use Ash.Resource,
    otp_app: :verscienta,
    domain: Verscienta.Communities,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @roles [:owner, :mod, :member]
  @statuses [:active, :requested, :invited]

  def roles, do: @roles
  def statuses, do: @statuses

  postgres do
    table "group_memberships"
    repo Verscienta.Repo

    references do
      reference :group, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    # Internal create used by group-creation + the flow actions (always authorize?: false).
    create :create do
      accept [:group_id, :user_id, :role, :status]
    end

    update :set_role do
      accept [:role]
    end

    update :set_status do
      accept [:status]
    end

    destroy :destroy

    read :for_group do
      argument :group_id, :uuid, allow_nil?: false
      argument :status, :atom, allow_nil?: true
      filter expr(group_id == ^arg(:group_id))
      filter expr(is_nil(^arg(:status)) or status == ^arg(:status))
    end

    read :for_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id) and status == :active)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    # All writes go through Communities flow actions with authorize?: false.
    policy action_type([:create, :update, :destroy]) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :role, :atom, allow_nil?: false, public?: true, default: :member, constraints: [one_of: @roles]

    attribute :status, :atom,
      allow_nil?: false,
      public?: true,
      default: :active,
      constraints: [one_of: @statuses]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Verscienta.Accounts.User, allow_nil?: false
    belongs_to :group, Verscienta.Communities.Group, allow_nil?: false
  end

  identities do
    identity :unique_membership, [:user_id, :group_id]
  end
end
```
NOTE: this resource has permissive policies because every mutation is performed by `Verscienta.Communities` flow actions (Tasks 2-3) with `authorize?: false` after explicit role checks — exactly like how `Social.Follow.toggle` destroys with `authorize?: false`. The flow actions are the real authorization boundary. There is no user-facing direct write path (no LiveView calls these directly).

- [ ] **Step 3: Create the Group resource**

Create `lib/verscienta/communities/group.ex`:
```elixir
defmodule Verscienta.Communities.Group do
  @moduledoc "A community/group with a visibility, an owner, and members."
  use Ash.Resource,
    otp_app: :verscienta,
    domain: Verscienta.Communities,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  @visibilities [:public, :private]
  def visibilities, do: @visibilities

  postgres do
    table "groups"
    repo Verscienta.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [:name, :description, :visibility]
      change relate_actor(:owner)
      change Verscienta.Communities.Group.Changes.GenerateSlug

      # `relate_actor(:owner)` has already set group.owner_id, so read it here
      # (the after_action builtin callback is 2-arity: changeset, record).
      change after_action(fn _changeset, group ->
               Verscienta.Communities.GroupMembership
               |> Ash.Changeset.for_create(
                 :create,
                 %{group_id: group.id, user_id: group.owner_id, role: :owner, status: :active}
               )
               |> Ash.create!(authorize?: false)

               {:ok, group}
             end)
    end

    update :update do
      accept [:name, :description, :visibility]
    end

    destroy :destroy

    read :list_public do
      filter expr(visibility == :public)
      prepare build(sort: [inserted_at: :desc])
    end

    read :get_by_slug do
      argument :slug, :string, allow_nil?: false
      get? true
      filter expr(slug == ^arg(:slug))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:create) do
      authorize_if actor_present()
    end

    policy action([:update, :destroy]) do
      authorize_if expr(owner_id == ^actor(:id))
    end
  end

  aggregates do
    count :member_count, :memberships do
      filter expr(status == :active)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true, constraints: [max_length: 100]
    attribute :slug, :string, allow_nil?: false, public?: true
    attribute :description, :string, allow_nil?: true, public?: true, constraints: [max_length: 1000]

    attribute :visibility, :atom,
      allow_nil?: false,
      public?: true,
      default: :public,
      constraints: [one_of: @visibilities]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :owner, Verscienta.Accounts.User, allow_nil?: false
    has_many :memberships, Verscienta.Communities.GroupMembership
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
```

- [ ] **Step 4: Create the slug change**

Create `lib/verscienta/communities/group/changes/generate_slug.ex` (mirror the Article slug change):
```elixir
defmodule Verscienta.Communities.Group.Changes.GenerateSlug do
  @moduledoc "Generate a unique slug for a group from its name, retrying on collisions."
  use Ash.Resource.Change

  alias Verscienta.Content.Slug

  @max_attempts 5
  @suffix_alphabet ~c"abcdefghjkmnpqrstuvwxyz23456789"

  @impl true
  def change(changeset, _opts, _context) do
    base = Slug.slugify(Ash.Changeset.get_attribute(changeset, :name))

    changeset
    |> Ash.Changeset.force_change_attribute(:slug, base)
    |> Ash.Changeset.around_transaction(&attempt(&1, &2, base, 1))
  end

  defp attempt(changeset, callback, base, tries) do
    case callback.(changeset) do
      {:error, error} = failure ->
        if tries < @max_attempts and slug_taken?(error) do
          changeset
          |> Ash.Changeset.force_change_attribute(:slug, "#{base}-#{random_suffix()}")
          |> attempt(callback, base, tries + 1)
        else
          failure
        end

      result ->
        result
    end
  end

  defp slug_taken?(error), do: error |> Exception.message() |> String.contains?("slug")

  defp random_suffix do
    1..4
    |> Enum.map(fn _ -> Enum.random(@suffix_alphabet) end)
    |> List.to_string()
  end
end
```
NOTE: confirm against the real `Article` `GenerateSlug` for the exact `around_transaction` + `slug_taken?` shape (read it); match it. The `~p"/images..."`-style is irrelevant here.

- [ ] **Step 5: Create the domain + context helpers**

Create `lib/verscienta/communities.ex`:
```elixir
defmodule Verscienta.Communities do
  @moduledoc "Domain for communities & groups: groups, memberships, and per-group role helpers."
  use Ash.Domain, otp_app: :verscienta

  require Ash.Query

  alias Verscienta.Communities.GroupMembership

  resources do
    resource Verscienta.Communities.Group
    resource Verscienta.Communities.GroupMembership
  end

  @doc "The active membership for `user` in `group`, or nil."
  def membership(nil, _group), do: nil

  def membership(user, group) do
    GroupMembership
    |> Ash.Query.filter(user_id == ^user.id and group_id == ^group.id)
    |> Ash.read_one!(authorize?: false)
  end

  @doc "The active role of `user` in `group` (:owner/:mod/:member) or nil."
  def role(user, group) do
    case membership(user, group) do
      %{status: :active, role: role} -> role
      _ -> nil
    end
  end

  @doc "Whether `user` is an active member of `group`."
  def member?(user, group), do: role(user, group) != nil

  @doc "Whether `user` can moderate `group` (active owner or mod)."
  def can_moderate?(user, group), do: role(user, group) in [:owner, :mod]
end
```

- [ ] **Step 6: Register the domain**

In `config/config.exs`, append `Verscienta.Communities` to the `ash_domains` list.

- [ ] **Step 7: Generate migration + test DB**
```
docker compose up -d db
docker compose run --rm -T app bash -lc "mix ash.codegen add_communities && MIX_ENV=test mix ash.setup"
```
Expected: migration creating `groups` + `group_memberships` (+ FKs, unique slug, unique membership).

- [ ] **Step 8: Run the test**
```
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/communities/group_test.exs"
```
Expected: 5 tests pass. (If `around_transaction`/`after_action` helpers need `import Ash.Resource.Change.Builtins` or differ, fix per the Article change; the contract is: create → owner membership + slug; owner-only update/destroy; list_public filters; helpers work.)

- [ ] **Step 9: Gate + commit**
```
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(communities): Group + GroupMembership resources + domain + helpers"
```
Then `git rev-parse --short HEAD`.

---

## Task 2: Membership join / leave / request flows (TDD)

**Files:**
- Modify: `lib/verscienta/communities/group_membership.ex` (add generic flow actions)
- Test: `test/verscienta/communities/membership_join_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/communities/membership_join_test.exs`:
```elixir
defmodule Verscienta.Communities.MembershipJoinTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Communities
  alias Verscienta.Communities.{Group, GroupMembership}

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

  defp group!(actor, visibility) do
    Group
    |> Ash.Changeset.for_create(:create, %{name: "G #{visibility} #{System.unique_integer([:positive])}", visibility: visibility}, actor: actor)
    |> Ash.create!()
  end

  defp run!(action, args, actor) do
    GroupMembership
    |> Ash.ActionInput.for_action(action, args, actor: actor)
    |> Ash.run_action!()
  end

  test "join a public group makes you an active member; leave removes you" do
    owner = user("p_owner")
    joiner = user("p_joiner")
    g = group!(owner, :public)

    run!(:join, %{group_id: g.id}, joiner)
    assert Communities.role(joiner, g) == :member

    run!(:leave, %{group_id: g.id}, joiner)
    refute Communities.member?(joiner, g)
  end

  test "cannot join a private group directly" do
    owner = user("pr_owner")
    joiner = user("pr_joiner")
    g = group!(owner, :private)

    assert {:error, _} =
             GroupMembership
             |> Ash.ActionInput.for_action(:join, %{group_id: g.id}, actor: joiner)
             |> Ash.run_action()
  end

  test "request_join a private group creates a pending requested membership" do
    owner = user("rq_owner")
    joiner = user("rq_joiner")
    g = group!(owner, :private)

    run!(:request_join, %{group_id: g.id}, joiner)
    m = Communities.membership(joiner, g)
    assert m.status == :requested
    refute Communities.member?(joiner, g)
  end

  test "owner cannot leave their own group while sole owner" do
    owner = user("o_owner")
    g = group!(owner, :public)

    assert {:error, _} =
             GroupMembership
             |> Ash.ActionInput.for_action(:leave, %{group_id: g.id}, actor: owner)
             |> Ash.run_action()
  end
end
```

- [ ] **Step 2: Add the flow actions**

In `lib/verscienta/communities/group_membership.ex`, add these generic actions inside `actions do` (after the `:create`), and `require Ash.Query` at the top of the module:
```elixir
    action :join, :term do
      argument :group_id, :uuid, allow_nil?: false

      run fn input, context ->
        actor = context.actor
        group = Ash.get!(Verscienta.Communities.Group, input.arguments.group_id, authorize?: false)

        cond do
          group.visibility != :public -> {:error, "This group is private."}
          existing_membership(actor.id, group.id) -> {:error, "Already a member or pending."}
          true -> {:ok, create_membership(group.id, actor.id, :member, :active)}
        end
      end
    end

    action :request_join, :term do
      argument :group_id, :uuid, allow_nil?: false

      run fn input, context ->
        actor = context.actor
        group = Ash.get!(Verscienta.Communities.Group, input.arguments.group_id, authorize?: false)

        cond do
          group.visibility != :private -> {:error, "This group is public — just join."}
          existing_membership(actor.id, group.id) -> {:error, "Already a member or pending."}
          true -> {:ok, create_membership(group.id, actor.id, :member, :requested)}
        end
      end
    end

    action :leave, :term do
      argument :group_id, :uuid, allow_nil?: false

      run fn input, context ->
        actor = context.actor

        case existing_membership(actor.id, input.arguments.group_id) do
          %{role: :owner} -> {:error, "Transfer ownership before leaving."}
          nil -> {:error, "Not a member."}
          m -> {:ok, Ash.destroy!(m, authorize?: false) && m}
        end
      end
    end
```
Add these private helpers to the module (after the `identities` block):
```elixir
  @doc false
  def existing_membership(user_id, group_id) do
    __MODULE__
    |> Ash.Query.filter(user_id == ^user_id and group_id == ^group_id)
    |> Ash.read_one!(authorize?: false)
  end

  @doc false
  def create_membership(group_id, user_id, role, status) do
    __MODULE__
    |> Ash.Changeset.for_create(:create, %{
      group_id: group_id,
      user_id: user_id,
      role: role,
      status: status
    })
    |> Ash.create!(authorize?: false)
  end
```
NOTE: `Ash.destroy!(m, authorize?: false) && m` returns `m` (destroy! returns `:ok`/the record depending on version — if it returns `:ok`, `:ok && m == m`; if it returns the record, also truthy). Ensure the action returns `{:ok, m}`. If `Ash.destroy!` returns `:ok`, `:ok && m` evaluates to `m` (since `:ok` is truthy). Good.

- [ ] **Step 3: Run the test**
```
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/communities/membership_join_test.exs"
```
Expected: 4 tests pass.

- [ ] **Step 4: Gate + commit**
```
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(communities): join/request_join/leave membership flows"
```
Then `git rev-parse --short HEAD`.

---

## Task 3: Invite / accept / approve / remove / promote / demote / transfer (TDD)

**Files:**
- Modify: `lib/verscienta/communities/group_membership.ex`, `lib/verscienta/communities/group.ex`
- Test: `test/verscienta/communities/membership_admin_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/communities/membership_admin_test.exs`:
```elixir
defmodule Verscienta.Communities.MembershipAdminTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Communities
  alias Verscienta.Communities.{Group, GroupMembership}

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

  defp group!(actor, visibility \\ :private) do
    Group
    |> Ash.Changeset.for_create(:create, %{name: "AG #{System.unique_integer([:positive])}", visibility: visibility}, actor: actor)
    |> Ash.create!()
  end

  defp m!(action, args, actor), do: GroupMembership |> Ash.ActionInput.for_action(action, args, actor: actor) |> Ash.run_action!()

  test "invite then accept makes the user active" do
    owner = user("i_owner")
    invitee = user("i_invitee")
    g = group!(owner)

    m!(:invite, %{group_id: g.id, user_id: invitee.id}, owner)
    assert Communities.membership(invitee, g).status == :invited
    refute Communities.member?(invitee, g)

    m!(:accept, %{group_id: g.id}, invitee)
    assert Communities.role(invitee, g) == :member
  end

  test "request then approve makes the user active; non-mod cannot approve" do
    owner = user("a_owner")
    joiner = user("a_joiner")
    rando = user("a_rando")
    g = group!(owner)

    m!(:request_join, %{group_id: g.id}, joiner)

    assert {:error, _} =
             GroupMembership
             |> Ash.ActionInput.for_action(:approve, %{group_id: g.id, user_id: joiner.id}, actor: rando)
             |> Ash.run_action()

    m!(:approve, %{group_id: g.id, user_id: joiner.id}, owner)
    assert Communities.role(joiner, g) == :member
  end

  test "owner promotes a member to mod and back" do
    owner = user("pr_owner")
    member = user("pr_member")
    g = group!(owner, :public)
    m!(:join, %{group_id: g.id}, member)

    m!(:promote, %{group_id: g.id, user_id: member.id}, owner)
    assert Communities.role(member, g) == :mod

    m!(:demote, %{group_id: g.id, user_id: member.id}, owner)
    assert Communities.role(member, g) == :member
  end

  test "mod can remove a member but not the owner" do
    owner = user("rm_owner")
    mod = user("rm_mod")
    member = user("rm_member")
    g = group!(owner, :public)
    m!(:join, %{group_id: g.id}, mod)
    m!(:promote, %{group_id: g.id, user_id: mod.id}, owner)
    m!(:join, %{group_id: g.id}, member)

    m!(:remove, %{group_id: g.id, user_id: member.id}, mod)
    refute Communities.member?(member, g)

    assert {:error, _} =
             GroupMembership
             |> Ash.ActionInput.for_action(:remove, %{group_id: g.id, user_id: owner.id}, actor: mod)
             |> Ash.run_action()
  end

  test "transfer_ownership swaps roles and group.owner_id; ex-owner can then leave" do
    owner = user("t_owner")
    heir = user("t_heir")
    g = group!(owner, :public)
    m!(:join, %{group_id: g.id}, heir)

    Group
    |> Ash.ActionInput.for_action(:transfer_ownership, %{group_id: g.id, user_id: heir.id}, actor: owner)
    |> Ash.run_action!()

    g = Ash.get!(Group, g.id, authorize?: false)
    assert g.owner_id == heir.id
    assert Communities.role(heir, g) == :owner
    assert Communities.role(owner, g) == :mod

    # ex-owner (now mod) can leave
    GroupMembership |> Ash.ActionInput.for_action(:leave, %{group_id: g.id}, actor: owner) |> Ash.run_action!()
    refute Communities.member?(owner, g)
  end
end
```

- [ ] **Step 2: Add invite/accept/approve/decline/remove/promote/demote to GroupMembership**

In `lib/verscienta/communities/group_membership.ex`, add these generic actions (use the `existing_membership/2` + a `moderates?/2` helper):
```elixir
    action :invite, :term do
      argument :group_id, :uuid, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false

      run fn input, context ->
        %{group_id: gid, user_id: uid} = input.arguments

        cond do
          not moderates?(context.actor.id, gid) -> {:error, "Not authorized."}
          existing_membership(uid, gid) -> {:error, "Already a member or pending."}
          true -> {:ok, create_membership(gid, uid, :member, :invited)}
        end
      end
    end

    action :accept, :term do
      argument :group_id, :uuid, allow_nil?: false

      run fn input, context ->
        case existing_membership(context.actor.id, input.arguments.group_id) do
          %{status: :invited} = m -> {:ok, set_status!(m, :active)}
          _ -> {:error, "No pending invite."}
        end
      end
    end

    action :approve, :term do
      argument :group_id, :uuid, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false

      run fn input, context ->
        %{group_id: gid, user_id: uid} = input.arguments

        cond do
          not moderates?(context.actor.id, gid) -> {:error, "Not authorized."}
          true ->
            case existing_membership(uid, gid) do
              %{status: :requested} = m -> {:ok, set_status!(m, :active)}
              _ -> {:error, "No pending request."}
            end
        end
      end
    end

    action :remove, :term do
      argument :group_id, :uuid, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false

      run fn input, context ->
        %{group_id: gid, user_id: uid} = input.arguments

        cond do
          not moderates?(context.actor.id, gid) -> {:error, "Not authorized."}
          true ->
            case existing_membership(uid, gid) do
              %{role: :owner} -> {:error, "Cannot remove the owner."}
              nil -> {:error, "Not a member."}
              m -> {:ok, Ash.destroy!(m, authorize?: false) && m}
            end
        end
      end
    end

    action :promote, :term do
      argument :group_id, :uuid, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false
      run fn input, context -> change_role(context.actor.id, input.arguments, :mod) end
    end

    action :demote, :term do
      argument :group_id, :uuid, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false
      run fn input, context -> change_role(context.actor.id, input.arguments, :member) end
    end
```
Add the helpers:
```elixir
  @doc false
  def moderates?(user_id, group_id) do
    case existing_membership(user_id, group_id) do
      %{status: :active, role: role} -> role in [:owner, :mod]
      _ -> false
    end
  end

  defp owner?(user_id, group_id) do
    case existing_membership(user_id, group_id) do
      %{status: :active, role: :owner} -> true
      _ -> false
    end
  end

  defp change_role(actor_id, %{group_id: gid, user_id: uid}, new_role) do
    cond do
      not owner?(actor_id, gid) -> {:error, "Only the owner can change roles."}
      true ->
        case existing_membership(uid, gid) do
          %{role: :owner} -> {:error, "Cannot change the owner's role here."}
          nil -> {:error, "Not a member."}
          m -> {:ok, set_role!(m, new_role)}
        end
    end
  end

  defp set_status!(m, status),
    do: m |> Ash.Changeset.for_update(:set_status, %{status: status}) |> Ash.update!(authorize?: false)

  defp set_role!(m, role),
    do: m |> Ash.Changeset.for_update(:set_role, %{role: role}) |> Ash.update!(authorize?: false)
```

- [ ] **Step 3: Add `transfer_ownership` to Group**

In `lib/verscienta/communities/group.ex`, add a generic action inside `actions do`:
```elixir
    action :transfer_ownership, :term do
      argument :group_id, :uuid, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false

      run fn input, context ->
        %{group_id: gid, user_id: new_owner_id} = input.arguments
        group = Ash.get!(__MODULE__, gid, authorize?: false)
        alias Verscienta.Communities.GroupMembership

        cond do
          group.owner_id != context.actor.id ->
            {:error, "Only the owner can transfer ownership."}

          true ->
            case GroupMembership.existing_membership(new_owner_id, gid) do
              %{status: :active} = new_m ->
                old_m = GroupMembership.existing_membership(context.actor.id, gid)

                new_m
                |> Ash.Changeset.for_update(:set_role, %{role: :owner})
                |> Ash.update!(authorize?: false)

                old_m
                |> Ash.Changeset.for_update(:set_role, %{role: :mod})
                |> Ash.update!(authorize?: false)

                updated =
                  group
                  |> Ash.Changeset.for_update(:set_owner, %{owner_id: new_owner_id})
                  |> Ash.update!(authorize?: false)

                {:ok, updated}

              _ ->
                {:error, "New owner must be an active member."}
            end
        end
      end
    end
```
And add a private `:set_owner` update action on Group (used only by transfer, authorize?: false):
```elixir
    update :set_owner do
      accept [:owner_id]
    end
```
NOTE: `belongs_to :owner` defines an `owner_id` attribute; accepting `:owner_id` in `:set_owner` lets us reassign it. Confirm `owner_id` is acceptable (belongs_to creates the attribute). The `alias` inside the run fn is fine, or move it to module top.

- [ ] **Step 4: Run the test**
```
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/communities/membership_admin_test.exs"
```
Expected: 5 tests pass.

- [ ] **Step 5: Gate + commit**
```
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(communities): invite/accept/approve/remove/promote/demote/transfer"
```
Then `git rev-parse --short HEAD`.

---

## Task 4: Group-tagged Articles + content isolation (TDD)

**Files:**
- Modify: `lib/verscienta/content/article.ex`, `lib/verscienta/social.ex`, `lib/verscienta/social/trending.ex`, the search enqueue/index path
- Test: `test/verscienta/communities/group_articles_test.exs`

- [ ] **Step 0: Read the search enqueue + index path**
```
docker compose run --rm -T app bash -lc "cat lib/verscienta/content/article/changes/enqueue_index.ex; echo '=== WORKER ==='; ls lib/verscienta/search; echo '---'; sed -n '1,80p' lib/verscienta/search.ex"
```
Find where an article is indexed (the worker / `Search` module) so you can SKIP articles with a `group_id` (don't index group content), and how `following_articles/4` + trending query published articles.

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/communities/group_articles_test.exs`:
```elixir
defmodule Verscienta.Communities.GroupArticlesTest do
  use Verscienta.DataCase, async: true

  require Ash.Query
  alias Verscienta.Communities.{Group, GroupMembership}
  alias Verscienta.Content.Article

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

  defp group!(actor, vis \\ :public) do
    Group
    |> Ash.Changeset.for_create(:create, %{name: "GA #{System.unique_integer([:positive])}", visibility: vis}, actor: actor)
    |> Ash.create!()
  end

  defp publish!(art, actor), do: art |> Ash.Changeset.for_update(:publish, %{}, actor: actor) |> Ash.update!()

  test "an active member can post an article to the group; a non-member cannot" do
    owner = user("ga_owner")
    g = group!(owner)

    {:ok, art} =
      Article
      |> Ash.Changeset.for_create(:create, %{title: "Group Post", excerpt: "e", category: :nutrition, group_id: g.id}, actor: owner)
      |> Ash.create()

    assert art.group_id == g.id

    stranger = user("ga_stranger")

    assert {:error, _} =
             Article
             |> Ash.Changeset.for_create(:create, %{title: "Sneaky", excerpt: "e", category: :nutrition, group_id: g.id}, actor: stranger)
             |> Ash.create()
  end

  test "group articles are excluded from list_published but returned by list_by_group" do
    owner = user("ga2_owner")
    g = group!(owner)

    art =
      Article
      |> Ash.Changeset.for_create(:create, %{title: "In Group", excerpt: "e", category: :nutrition, group_id: g.id}, actor: owner)
      |> Ash.create!()
      |> publish!(owner)

    global = Article |> Ash.read!(action: :list_published, authorize?: false) |> Enum.map(& &1.id)
    refute art.id in global

    in_group = Article |> Ash.read!(action: :list_by_group, actor: nil, authorize?: false, arguments: %{group_id: g.id}) |> Enum.map(& &1.id)
    assert art.id in in_group
  end
end
```
NOTE: adjust the `:list_by_group` read invocation to the project's convention (e.g. `Ash.Query.for_read(Article, :list_by_group, %{group_id: g.id})` then `Ash.read!`). Keep the assertions: member-posting allowed, non-member denied, group article excluded from `list_published`, included in `list_by_group`.

- [ ] **Step 2: Add `group_id` + validation + `:list_by_group` to Article**

In `lib/verscienta/content/article.ex`:
- Add the relationship:
```elixir
    belongs_to :group, Verscienta.Communities.Group, allow_nil?: true
```
- Accept `group_id` in the human `:create` and `:update` actions (add `:group_id` to their `accept` lists).
- Add a member-posting validation as a `before_action` change (only when group_id present), in the `changes do` block:
```elixir
    change fn changeset, context ->
             Ash.Changeset.before_action(changeset, fn cs ->
               case Ash.Changeset.get_attribute(cs, :group_id) do
                 nil ->
                   cs

                 group_id ->
                   actor = context.actor
                   group = Ash.get!(Verscienta.Communities.Group, group_id, authorize?: false)

                   if actor && Verscienta.Communities.member?(actor, group) do
                     cs
                   else
                     Ash.Changeset.add_error(cs,
                       field: :group_id,
                       message: "you must be an active member of the group to post to it"
                     )
                   end
               end
             end)
           end,
           on: [:create, :update]
```
- Add `is_nil(group_id)` to `:list_published`:
```elixir
    read :list_published do
      description "Published, non-group articles, newest first."
      filter expr(status == :published and is_nil(group_id))
      prepare build(sort: [published_at: :desc])
    end
```
- Add the group read:
```elixir
    read :list_by_group do
      argument :group_id, :uuid, allow_nil?: false
      filter expr(status == :published and group_id == ^arg(:group_id))
      prepare build(sort: [published_at: :desc])
    end
```
NOTE: the existing `read policy` (`status == :published` OR author) still applies; group-page private gating is enforced in the LiveView (Task 6) by checking membership before calling `:list_by_group`. The `is_nil(group_id)` on `list_published` is the isolation backstop for the public feed.

- [ ] **Step 3: Isolation in following feed + trending**

In `lib/verscienta/social.ex`, `following_articles/4`, add `and is_nil(group_id)` to the published filter (and to the tag-article subquery if present):
```elixir
    |> Ash.Query.filter(status == :published and is_nil(group_id))
```
In `lib/verscienta/social/trending.ex`, where it lists published article ids, add `and is_nil(group_id)`:
```elixir
    |> Ash.Query.filter(status == :published and is_nil(group_id))
```

- [ ] **Step 4: Isolation in search indexing**

Using Step 0's findings, ensure group articles are NOT indexed: in the index enqueue change (`EnqueueIndex`) or the index worker/`Search` module, skip when `group_id` is set (e.g. `if is_nil(article.group_id), do: enqueue/index, else: :ok`). If the worker re-reads the article, add the `is_nil(group_id)` guard there. Keep it best-effort + consistent with the existing pattern. Document exactly where you added the guard.

- [ ] **Step 5: Generate migration + run the test**
```
docker compose up -d db
docker compose run --rm -T app bash -lc "mix ash.codegen add_article_group_id && MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta/communities/group_articles_test.exs"
```
Expected: a migration adding `articles.group_id` (nullable FK, on_delete nilify); 2 tests pass.

- [ ] **Step 6: Gate + commit**
```
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
```
Run the ENTIRE suite (you changed Article + feeds + search — confirm existing content/search/feed tests still pass; group articles excluded shouldn't break them). Then:
```
git add -A
git commit -m "feat(communities): Article group_id + member-posting + content isolation"
```
Then `git rev-parse --short HEAD`.

---

## Task 5: Groups directory + create + nav (TDD)

**Files:**
- Create: `lib/verscienta_web/live/groups_live.ex`
- Modify: `lib/verscienta_web/router.ex`, `lib/verscienta_web/components/layouts.ex`
- Test: `test/verscienta_web/live/groups_live_test.exs`

- [ ] **Step 1: Add routes** — In `lib/verscienta_web/router.ex`:
  - Public directory + group page in the `:public_routes` live_session:
```elixir
      live "/groups", GroupsLive, :index
      live "/groups/:slug", GroupLive, :show
```
  - Authenticated create + manage + settings in `ash_authentication_live_session :authenticated_routes`:
```elixir
      live "/groups/new", GroupsLive, :new
      live "/groups/:slug/manage", GroupLive, :manage
      live "/groups/:slug/settings", GroupLive, :settings
```

- [ ] **Step 2: Write the failing test**

Create `test/verscienta_web/live/groups_live_test.exs`:
```elixir
defmodule VerscientaWeb.GroupsLiveTest do
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

  defp group!(actor, vis) do
    Verscienta.Communities.Group
    |> Ash.Changeset.for_create(:create, %{name: "Dir #{vis} #{System.unique_integer([:positive])}", visibility: vis}, actor: actor)
    |> Ash.create!()
  end

  test "directory lists public groups, not private ones", %{conn: conn} do
    owner = user("dir_owner")
    pub = group!(owner, :public)
    priv = group!(owner, :private)

    {:ok, _view, html} = live(conn, ~p"/groups")
    assert html =~ pub.name
    refute html =~ priv.name
  end

  test "a signed-in user can create a group", %{conn: conn} do
    me = user("creator")
    {:ok, view, _html} = conn |> sign_in(me) |> live(~p"/groups/new")

    view
    |> form("#group-form", %{"form" => %{"name" => "My Community", "description" => "hi", "visibility" => "public"}})
    |> render_submit()

    g = Verscienta.Communities.Group |> Ash.read!(authorize?: false) |> Enum.find(&(&1.name == "My Community"))
    assert g && g.owner_id == me.id
  end
end
```

- [ ] **Step 3: Create GroupsLive** — Create `lib/verscienta_web/live/groups_live.ex` handling `:index` (directory) and `:new` (create form). Use an AshPhoenix.Form for create (`Group.create`, actor = current_user). Structure:
```elixir
defmodule VerscientaWeb.GroupsLive do
  use VerscientaWeb, :live_view

  alias Verscienta.Communities
  alias Verscienta.Communities.Group

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "groups")}

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, load(socket, socket.assigns.live_action)}

  defp load(socket, :index) do
    public = Ash.read!(Group, action: :list_public, authorize?: false) |> Ash.load!(:member_count, authorize?: false)
    mine = my_groups(socket.assigns[:current_user])
    assign(socket, groups: public, my_groups: mine)
  end

  defp load(socket, :new) do
    form =
      Group
      |> AshPhoenix.Form.for_create(:create, as: "form", actor: socket.assigns.current_user)
      |> to_form()

    assign(socket, form: form)
  end

  defp my_groups(nil), do: []

  defp my_groups(user) do
    Communities.GroupMembership
    |> Ash.Query.for_read(:for_user, %{user_id: user.id})
    |> Ash.read!(authorize?: false)
    |> Ash.load!(:group, authorize?: false)
    |> Enum.map(& &1.group)
  end

  @impl true
  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, group} -> {:noreply, push_navigate(socket, to: ~p"/groups/#{group.slug}")}
      {:error, form} -> {:noreply, assign(socket, form: form)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl px-6 pt-24">
      <div :if={@live_action == :index}>
        <div class="mb-6 flex items-center justify-between">
          <h1 class="text-2xl font-light lowercase text-ink">groups</h1>
          <.link :if={@current_user} navigate={~p"/groups/new"} class="text-xs uppercase tracking-wider text-zune">
            create group
          </.link>
        </div>

        <section :if={@my_groups != []} class="mb-8">
          <h2 class="mb-2 text-xs uppercase tracking-wider text-ink-3">your groups</h2>
          <ul class="divide-y divide-line">
            <li :for={g <- @my_groups} class="py-2">
              <.link navigate={~p"/groups/#{g.slug}"} class="text-ink hover:text-zune">{g.name}</.link>
            </li>
          </ul>
        </section>

        <ul class="divide-y divide-line">
          <li :for={g <- @groups} class="py-3">
            <.link navigate={~p"/groups/#{g.slug}"} class="text-lg text-ink hover:text-zune">{g.name}</.link>
            <p :if={g.description} class="text-sm text-ink-3">{g.description}</p>
            <span class="text-[11px] text-ink-3">{g.member_count} members</span>
          </li>
          <li :if={@groups == []} class="py-8 text-center text-ink-3">no groups yet.</li>
        </ul>
      </div>

      <div :if={@live_action == :new}>
        <h1 class="mb-6 text-2xl font-light lowercase text-ink">create group</h1>
        <.form :let={f} for={@form} id="group-form" phx-submit="save" class="max-w-xl space-y-4">
          <input name={f[:name].name} value={Phoenix.HTML.Form.normalize_value("text", f[:name].value)}
            placeholder="name" class="w-full border border-line bg-canvas-2 px-4 py-3 text-ink" />
          <textarea name={f[:description].name} placeholder="description"
            class="w-full border border-line bg-canvas-2 px-4 py-3 text-ink">{Phoenix.HTML.Form.normalize_value("textarea", f[:description].value)}</textarea>
          <select name={f[:visibility].name} class="w-full border border-line bg-canvas-2 px-4 py-3 text-ink">
            <option value="public">public</option>
            <option value="private">private</option>
          </select>
          <button type="submit" class="bg-zune px-6 py-3 text-xs font-bold uppercase tracking-wider text-black">create</button>
        </.form>
      </div>
    </div>
    """
  end
end
```
Add `require Ash.Query` at the top. Add a "groups" link to `nav_links/1` in `lib/verscienta_web/components/layouts.ex` (near "search"/"activity"):
```elixir
    <a href="/groups" class="transition-colors hover:text-ink">groups</a>
```

- [ ] **Step 4: Run the test**
```
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/groups_live_test.exs"
```
Expected: 2 tests pass.

- [ ] **Step 5: Gate + commit**
```
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(communities): groups directory + create + nav link"
```
Then `git rev-parse --short HEAD`.

---

## Task 6: Group page (state-aware actions + members + articles + private gating) (TDD)

**Files:**
- Create: `lib/verscienta_web/live/group_live.ex`
- Test: `test/verscienta_web/live/group_live_test.exs`

(Routes for `:show`/`:manage`/`:settings` were added in Task 5.)

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/group_live_test.exs`:
```elixir
defmodule VerscientaWeb.GroupLiveTest do
  use VerscientaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias AshAuthentication.Plug.Helpers
  alias Verscienta.Communities

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

  defp group!(actor, vis) do
    Communities.Group
    |> Ash.Changeset.for_create(:create, %{name: "Page #{vis} #{System.unique_integer([:positive])}", visibility: vis}, actor: actor)
    |> Ash.create!()
  end

  test "public group page shows a join button; clicking joins", %{conn: conn} do
    owner = user("gp_owner")
    visitor = user("gp_visitor")
    g = group!(owner, :public)

    {:ok, view, _html} = conn |> sign_in(visitor) |> live(~p"/groups/#{g.slug}")
    assert render(view) =~ "join"

    render_click(element(view, ~s(button[phx-click="join"])))
    assert Communities.member?(visitor, g)
  end

  test "private group hides content from non-members and shows a request gate", %{conn: conn} do
    owner = user("gpr_owner")
    visitor = user("gpr_visitor")
    g = group!(owner, :private)

    {:ok, _view, html} = conn |> sign_in(visitor) |> live(~p"/groups/#{g.slug}")
    assert html =~ "request to join" or html =~ "request"
  end
end
```

- [ ] **Step 2: Create GroupLive** — Create `lib/verscienta_web/live/group_live.ex`. Mount loads the group by slug (`:get_by_slug`, raise NotFound if nil), computes the viewer's membership/role, and (for `:show`) loads members + articles (articles only if public OR active member). Implements `handle_event`s: `join`, `request_join`, `accept`, `leave` (call the `GroupMembership` flow actions with `actor: current_user`, then reload). The `:manage`/`:settings` actions render the management/settings panels (Task 7 fills these — for THIS task, render `:show` fully and stub `:manage`/`:settings` to a "coming up" block OR implement them in Task 7; keep `:show` complete here). Core structure:
```elixir
defmodule VerscientaWeb.GroupLive do
  use VerscientaWeb, :live_view

  require Ash.Query
  alias Verscienta.Communities
  alias Verscienta.Communities.{Group, GroupMembership}
  alias Verscienta.Content.Article

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    group =
      case Group |> Ash.Query.for_read(:get_by_slug, %{slug: slug}) |> Ash.read_one!(authorize?: false) do
        nil -> raise Ash.Error.Query.NotFound
        g -> Ash.load!(g, :member_count, authorize?: false)
      end

    {:ok, socket |> assign(group: group, page_title: group.name) |> assign_view()}
  end

  defp assign_view(socket) do
    user = socket.assigns[:current_user]
    group = socket.assigns.group
    role = Communities.role(user, group)
    membership = Communities.membership(user, group)
    can_view? = group.visibility == :public or role != nil

    articles =
      if can_view? do
        Article |> Ash.Query.for_read(:list_by_group, %{group_id: group.id}) |> Ash.read!(authorize?: false)
      else
        []
      end

    members =
      GroupMembership
      |> Ash.Query.for_read(:for_group, %{group_id: group.id, status: :active})
      |> Ash.read!(authorize?: false)
      |> Ash.load!(:user, authorize?: false)

    assign(socket,
      role: role,
      membership: membership,
      can_view?: can_view?,
      can_moderate?: role in [:owner, :mod],
      is_owner?: role == :owner,
      articles: articles,
      members: members
    )
  end

  @impl true
  def handle_event("join", _p, socket), do: run_membership(socket, :join, %{group_id: socket.assigns.group.id})
  def handle_event("request_join", _p, socket), do: run_membership(socket, :request_join, %{group_id: socket.assigns.group.id})
  def handle_event("accept", _p, socket), do: run_membership(socket, :accept, %{group_id: socket.assigns.group.id})
  def handle_event("leave", _p, socket), do: run_membership(socket, :leave, %{group_id: socket.assigns.group.id})

  defp run_membership(socket, action, args) do
    case GroupMembership |> Ash.ActionInput.for_action(action, args, actor: socket.assigns.current_user) |> Ash.run_action() do
      {:ok, _} -> {:noreply, socket |> reload_group() |> put_flash(:info, "Done")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Action failed")}
    end
  end

  defp reload_group(socket) do
    group = Ash.get!(Group, socket.assigns.group.id, load: [:member_count], authorize?: false)
    socket |> assign(group: group) |> assign_view()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl px-6 pt-24">
      <h1 class="text-3xl font-light lowercase text-ink">{@group.name}</h1>
      <p :if={@group.description} class="mt-1 text-ink-3">{@group.description}</p>
      <p class="mt-1 text-[11px] uppercase tracking-wider text-ink-3">
        {@group.visibility} · {@group.member_count} members
      </p>

      <div class="mt-4 flex gap-3">
        <button :if={@current_user && is_nil(@role) && @group.visibility == :public}
          phx-click="join" class="border border-zune px-3 py-1 text-xs uppercase tracking-wider text-zune">join</button>
        <button :if={@current_user && is_nil(@membership) && @group.visibility == :private}
          phx-click="request_join" class="border border-zune px-3 py-1 text-xs uppercase tracking-wider text-zune">request to join</button>
        <span :if={@membership && @membership.status == :requested} class="text-xs text-ink-3">request pending</span>
        <button :if={@membership && @membership.status == :invited}
          phx-click="accept" class="border border-zune px-3 py-1 text-xs uppercase tracking-wider text-zune">accept invite</button>
        <button :if={@role && @role != :owner} phx-click="leave" class="border border-line px-3 py-1 text-xs uppercase tracking-wider text-ink-3">leave</button>
        <.link :if={@can_moderate?} navigate={~p"/groups/#{@group.slug}/manage"} class="text-xs uppercase tracking-wider text-ink-3">manage</.link>
        <.link :if={@is_owner?} navigate={~p"/groups/#{@group.slug}/settings"} class="text-xs uppercase tracking-wider text-ink-3">settings</.link>
      </div>

      <div :if={not @can_view?} class="mt-10 text-center text-ink-3">this group is private — request to join to see its content.</div>

      <div :if={@can_view?} class="mt-10">
        <h2 class="mb-3 text-xs uppercase tracking-wider text-ink-3">articles</h2>
        <ul class="divide-y divide-line">
          <li :for={a <- @articles} class="py-3">
            <.link navigate={~p"/articles/#{a.slug}"} class="text-ink hover:text-zune">{a.title}</.link>
          </li>
          <li :if={@articles == []} class="py-4 text-ink-3">no articles yet.</li>
        </ul>

        <h2 class="mb-3 mt-8 text-xs uppercase tracking-wider text-ink-3">members</h2>
        <ul class="flex flex-wrap gap-2">
          <li :for={m <- @members}>
            <.link navigate={~p"/@#{m.user.username}"} class="text-sm text-ink hover:text-zune">@{m.user.username}</.link>
          </li>
        </ul>
      </div>

      <.live_component :if={@live_action in [:manage, :settings]} module={VerscientaWeb.GroupLive.ManagePanel}
        id="group-manage" group={@group} live_action={@live_action} current_user={@current_user} />
    </div>
    """
  end
end
```
NOTE: For THIS task, the `:manage`/`:settings` panels are added in Task 7 (the `<.live_component>` line + the ManagePanel module). For Task 6, you may omit that `<.live_component>` line (and the manage/settings routes will just render `:show`'s body without the panel) OR add a minimal placeholder. Keep `:show` fully working + the two tests passing. If `live_user_optional` doesn't assign `current_user` here, the page is in `:public_routes` (optional user) — use `socket.assigns[:current_user]`.

- [ ] **Step 3: Run the test**
```
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/group_live_test.exs"
```
Expected: 2 tests pass.

- [ ] **Step 4: Gate + commit**
```
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(communities): group page with state-aware actions + private gating"
```
Then `git rev-parse --short HEAD`.

---

## Task 7: Manage panel + settings (requests/invite/members/roles + edit/transfer/delete) (TDD)

**Files:**
- Create: `lib/verscienta_web/live/group_live/manage_panel.ex` (LiveComponent)
- Modify: `lib/verscienta_web/live/group_live.ex` (render the panel for `:manage`/`:settings`; guard access)
- Test: `test/verscienta_web/live/group_manage_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/group_manage_test.exs`:
```elixir
defmodule VerscientaWeb.GroupManageTest do
  use VerscientaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias AshAuthentication.Plug.Helpers
  alias Verscienta.Communities
  alias Verscienta.Communities.{Group, GroupMembership}

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

  defp group!(actor, vis \\ :private) do
    Group
    |> Ash.Changeset.for_create(:create, %{name: "Mg #{System.unique_integer([:positive])}", visibility: vis}, actor: actor)
    |> Ash.create!()
  end

  test "owner approves a pending request from the manage panel", %{conn: conn} do
    owner = user("mg_owner")
    joiner = user("mg_joiner")
    g = group!(owner, :private)
    GroupMembership |> Ash.ActionInput.for_action(:request_join, %{group_id: g.id}, actor: joiner) |> Ash.run_action!()

    {:ok, view, _html} = conn |> sign_in(owner) |> live(~p"/groups/#{g.slug}/manage")
    render_click(element(view, ~s([phx-click="approve"][phx-value-user_id="#{joiner.id}"])))

    assert Communities.role(joiner, g) == :member
  end

  test "a non-moderator is denied the manage page", %{conn: conn} do
    owner = user("mg2_owner")
    rando = user("mg2_rando")
    g = group!(owner, :public)

    assert {:error, {:live_redirect, _}} = conn |> sign_in(rando) |> live(~p"/groups/#{g.slug}/manage")
  end

  test "owner deletes the group from settings", %{conn: conn} do
    owner = user("mg3_owner")
    g = group!(owner, :public)

    {:ok, view, _html} = conn |> sign_in(owner) |> live(~p"/groups/#{g.slug}/settings")
    render_click(element(view, ~s([phx-click="delete_group"])))

    assert Group |> Ash.read!(authorize?: false) |> Enum.all?(&(&1.id != g.id))
  end
end
```
NOTE: the non-mod denial mechanism is your choice — either `push_navigate` away in `handle_params` (yielding `{:error, {:live_redirect, _}}`) or `raise NotFound`. Match the assertion to what you implement (the AdminSourcesLive precedent raises NotFound; if you raise, assert with `catch_error`/`assert_raise` instead). Keep the intent: non-mod can't manage; non-owner can't reach settings.

- [ ] **Step 2: Guard manage/settings + render the panel**

In `lib/verscienta_web/live/group_live.ex`, add a `handle_params/3` that, for `:manage`, redirects non-moderators, and for `:settings`, redirects non-owners:
```elixir
  @impl true
  def handle_params(_params, _uri, socket) do
    case socket.assigns.live_action do
      :manage ->
        if socket.assigns.can_moderate?, do: {:noreply, socket}, else: {:noreply, push_navigate(socket, to: ~p"/groups/#{socket.assigns.group.slug}")}

      :settings ->
        if socket.assigns.is_owner?, do: {:noreply, socket}, else: {:noreply, push_navigate(socket, to: ~p"/groups/#{socket.assigns.group.slug}")}

      _ ->
        {:noreply, socket}
    end
  end
```
(`assign_view/1` already set `can_moderate?`/`is_owner?` in mount.)

Add the management `handle_event`s to GroupLive (approve/decline/invite/remove/promote/demote/transfer_ownership/update settings/delete_group), each calling the corresponding flow action with `actor: current_user` then `reload_group/1`. Example:
```elixir
  def handle_event("approve", %{"user_id" => uid}, socket), do: mod_action(socket, GroupMembership, :approve, %{group_id: socket.assigns.group.id, user_id: uid})
  def handle_event("remove", %{"user_id" => uid}, socket), do: mod_action(socket, GroupMembership, :remove, %{group_id: socket.assigns.group.id, user_id: uid})
  def handle_event("promote", %{"user_id" => uid}, socket), do: mod_action(socket, GroupMembership, :promote, %{group_id: socket.assigns.group.id, user_id: uid})
  def handle_event("demote", %{"user_id" => uid}, socket), do: mod_action(socket, GroupMembership, :demote, %{group_id: socket.assigns.group.id, user_id: uid})

  def handle_event("invite", %{"username" => username}, socket) do
    case Verscienta.Accounts.User |> Ash.Query.filter(username == ^username) |> Ash.read_one!(authorize?: false) do
      nil -> {:noreply, put_flash(socket, :error, "No such user")}
      u -> mod_action(socket, GroupMembership, :invite, %{group_id: socket.assigns.group.id, user_id: u.id})
    end
  end

  def handle_event("transfer_ownership", %{"user_id" => uid}, socket),
    do: mod_action(socket, Group, :transfer_ownership, %{group_id: socket.assigns.group.id, user_id: uid})

  def handle_event("delete_group", _p, socket) do
    case Ash.destroy(socket.assigns.group, actor: socket.assigns.current_user) do
      :ok -> {:noreply, push_navigate(socket, to: ~p"/groups")}
      {:ok, _} -> {:noreply, push_navigate(socket, to: ~p"/groups")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Delete failed")}
    end
  end

  defp mod_action(socket, resource, action, args) do
    case resource |> Ash.ActionInput.for_action(action, args, actor: socket.assigns.current_user) |> Ash.run_action() do
      {:ok, _} -> {:noreply, reload_group(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Action failed")}
    end
  end
```
Settings edit form (name/description/visibility) can be an AshPhoenix.Form on `Group.update` with a `save_settings` event; render it under `:settings`.

Render the manage/settings panels inline in GroupLive's render for the respective `live_action` (a LiveComponent is optional — inline is simpler). Show: pending requests (`for_group` status `:requested`) with approve/decline buttons; an invite-by-username form; the active members list with remove + (owner) promote/demote + transfer; and (settings) the edit form + delete button.

NOTE: To keep `assign_view/1` data available for the panels, also load `requests` (status `:requested`) and `invited` lists in `assign_view/1`. Add:
```elixir
    requests =
      GroupMembership |> Ash.Query.for_read(:for_group, %{group_id: group.id, status: :requested}) |> Ash.read!(authorize?: false) |> Ash.load!(:user, authorize?: false)
```
and assign it.

- [ ] **Step 3: Run the test**
```
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/group_manage_test.exs"
```
Expected: 3 tests pass.

- [ ] **Step 4: Gate + commit**
```
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(communities): manage panel + settings (requests/invite/roles/transfer/delete)"
```
Then `git rev-parse --short HEAD`.

---

## Task 8: Editor "post to group" selector (TDD)

**Files:**
- Modify: `lib/verscienta_web/live/article_editor_live.ex`
- Test: `test/verscienta_web/live/editor_group_test.exs`

- [ ] **Step 0: Read the editor** (`lib/verscienta_web/live/article_editor_live.ex`) — find mount, the `article-form`, the save handler + params (you injected cover there already), and where form fields render.

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/editor_group_test.exs`:
```elixir
defmodule VerscientaWeb.EditorGroupTest do
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

  test "an author can post a new article to a group they belong to", %{conn: conn} do
    author = user("eg_author")

    g =
      Verscienta.Communities.Group
      |> Ash.Changeset.for_create(:create, %{name: "Editor Group", visibility: :public}, actor: author)
      |> Ash.create!()

    {:ok, view, _html} = conn |> sign_in(author) |> live(~p"/articles/new")

    view
    |> form("#article-form", %{"form" => %{"title" => "In My Group", "excerpt" => "x", "category" => "nutrition", "group_id" => g.id}})
    |> render_submit()

    art = Verscienta.Content.Article |> Ash.read!(authorize?: false) |> Enum.find(&(&1.title == "In My Group"))
    assert art && art.group_id == g.id
  end
end
```

- [ ] **Step 2: Add the group selector**

In `lib/verscienta_web/live/article_editor_live.ex`:
- In `mount/3`, load the author's active groups:
```elixir
    my_groups =
      Verscienta.Communities.GroupMembership
      |> Ash.Query.for_read(:for_user, %{user_id: socket.assigns.current_user.id})
      |> Ash.read!(authorize?: false)
      |> Ash.load!(:group, authorize?: false)
      |> Enum.map(& &1.group)
```
  and `assign(socket, my_groups: my_groups)` (add `require Ash.Query`).
- In the render, add a `<select name={f[:group_id].name}>` with an empty option + the author's groups (only show the select if `@my_groups != []`):
```heex
<div :if={@my_groups != []}>
  <label class="mb-1 block text-[11px] uppercase tracking-widest text-ink-3">post to group (optional)</label>
  <select name={f[:group_id].name} class="w-full border border-line bg-canvas-2 px-4 py-3 text-ink">
    <option value="">— none —</option>
    <option :for={g <- @my_groups} value={g.id} selected={to_string(f[:group_id].value) == g.id}>{g.name}</option>
  </select>
</div>
```
  `group_id` is already accepted by `Article.create`/`update` (Task 4). The save handler already submits the `form` params (the cover consume injects too) — `group_id` flows through. NOTE: ensure the editor form's `accept`/AshPhoenix form includes `group_id` (it's accepted by the action, so AshPhoenix will pass it). An empty string `group_id` should become `nil` — if Ash rejects `""` as a uuid, normalize `""`→nil in the save handler before submit:
```elixir
    params =
      case params do
        %{"group_id" => ""} -> Map.put(params, "group_id", nil)
        _ -> params
      end
```

- [ ] **Step 3: Run the test**
```
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/editor_group_test.exs"
```
Expected: passes.

- [ ] **Step 4: Gate + commit**
```
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(communities): post-to-group selector in the article editor"
```
Then `git rev-parse --short HEAD`.

---

## Task 9: Seeds + todo + full verification + merge prep

**Files:**
- Modify: `priv/repo/seeds.exs`, `docs/todo.md`

- [ ] **Step 1: Append idempotent group seeds** — At the end of `priv/repo/seeds.exs`, create a sample public group owned by the first seeded user (guard: only if none exists). Adapt to seeded users:
```elixir
# --- Communities seeds (idempotent) ---
require Ash.Query

case Verscienta.Accounts.User |> Ash.read!(authorize?: false) |> Enum.sort_by(& &1.username) do
  [owner | _] ->
    unless Verscienta.Communities.Group |> Ash.read!(authorize?: false) |> Enum.any?(&(&1.name == "Verscienta Founders")) do
      Verscienta.Communities.Group
      |> Ash.Changeset.for_create(:create, %{name: "Verscienta Founders", description: "Early members.", visibility: :public}, actor: owner)
      |> Ash.create!()
    end

  _ ->
    :ok
end
```
(`require Ash.Query` may already be present — don't duplicate.)

- [ ] **Step 2: Run seeds twice for idempotency**
```
docker compose up -d db
docker compose run --rm -T app bash -lc "mix ash.setup && mix run priv/repo/seeds.exs && mix run priv/repo/seeds.exs"
```
Expected: no crash; the guard prevents a duplicate group.

- [ ] **Step 3: Tick the todo** — In `docs/todo.md`, under "### Communities & Groups", flip `[ ]`→`[x]` (match exact wording, append notes):
```markdown
- [x] `Group` + `GroupMembership` resources (public communities, private groups).
- [x] Group creation, join/leave, roles (owner/mod/member).
- [x] Group-scoped content + discussions. *(group-tagged Articles + existing comments; siloed from global feeds/search)*
- [x] Group discovery / directory.
```

- [ ] **Step 4: Full clean-deps gate**
```
docker compose up -d db
docker compose run --rm -T app bash -lc "mix deps.get && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
```
Expected: all green. Capture the exact `N tests, 0 failures` line.

- [ ] **Step 5: Commit**
```
git add -A
git commit -m "feat(communities): seeds + todo updates"
```
Then `git rev-parse --short HEAD`.

---

## Definition of Done (verify all)

- [ ] `Verscienta.Communities` (`Group` + `GroupMembership`) with per-group roles + status flows; `Article.group_id`; migrations applied; domain registered.
- [ ] Public join/leave; private request→approve + invite→accept; promote/demote; ownership transfer; owner-protected settings/delete — all enforced via the flow actions (run-fn role checks).
- [ ] Active members can post group-tagged Articles; non-members denied; `:list_by_group` works; discussions via existing comments.
- [ ] Group content excluded from global `/articles`/trending/following/search; private-group content gated by active membership on the group page.
- [ ] `/groups` directory + create; `/groups/:slug` state-aware page; `/manage` (mod) + `/settings` (owner) panels; editor group selector; "groups" nav link.
- [ ] `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test` all pass.
- [ ] Migrations via `mix ash.codegen`; `docs/todo.md` updated; work committed on `communities`.
```
