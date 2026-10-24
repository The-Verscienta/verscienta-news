# Feature Flags Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install FunWithFlags with Postgres persistence + ETS cache, wrap it behind `Verscienta.Flags` with a hard-coded allowlist, seed 13 flags (7 retroactive ON, 6 Phase 3 OFF), ship a custom Codex admin LiveView, and retroactively gate 7 existing features.

**Architecture:** `Verscienta.Flags` is the single chokepoint — wraps FunWithFlags, raises on unknown flag names. A router plug `VerscientaWeb.Plugs.Gate` short-circuits non-admin requests to a `ComingSoonLive` LiveView when a flag is off; admin sees the page with a "🚧 admin preview" banner. Workers/Ash actions/templates use `Flags.enabled?/1..2` inline. Two admin LiveViews (`AdminFlagsLive` index + `AdminFlagShowLive` drill-down) provide control over all four FunWithFlags dimensions (boolean / actor / group / percentage), with every change logged to a `feature_flag_audits` Ash resource.

**Tech Stack:** Elixir 1.18.4 / OTP 27.3.4, Phoenix 1.8, Ash 3.x, AshPostgres, `fun_with_flags ~> 1.12`, Tailwind v4, daisyUI. Tests via ExUnit + `Phoenix.LiveViewTest`. All `mix` runs in Docker.

**Conventions (apply to every task):**
- Run all `mix` commands **in Docker**: `docker compose exec app mix <...>`. Never run mix on the host. The compose service is `app`, not `web`.
- **Never hand-write Ash migrations.** Use `docker compose exec app mix ash.codegen <descriptive_name>`. Review before committing.
- FunWithFlags ships its OWN migration helper (`FunWithFlags.Store.Persistent.Ecto.Migration` or the equivalent for the installed version — check `hexdocs.pm/fun_with_flags` if the name differs). This is a regular Ecto migration generated via `mix ecto.gen.migration`, NOT `mix ash.codegen`.
- Before each commit: `mix format`; LF line endings; no `.bak` files.
- Each commit body ends with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Test DB resets use `MIX_ENV=test mix ecto.drop -r Verscienta.Repo && mix ecto.create -r Verscienta.Repo && mix ash.migrate` (NOT `ash.setup` — seeding contaminates count assertions; see `[[verscienta-test-db-seed-contamination]]`).
- Work on branch `phase-2-feature-flags` (created in Task 0).
- The 13 flags (atoms): retroactive ON — `:reward_store, :referrals, :quests, :leaderboards, :communities, :reposts, :ai_enrichment`. Phase 3 OFF — `:for_you_feed, :live_rooms, :digest_emails, :auto_moderation, :expert_program, :writing_assistant`.
- **FunWithFlags 1.13 API note (discovered in Task 1):** the public API doesn't have `FunWithFlags.clear_cache/0` (use `FunWithFlags.Store.Cache.flush/0`) and `FunWithFlags.disable/1` errors on never-recorded flags (use `FunWithFlags.clear/1` to remove any gate, or `FunWithFlags.disable/2` with a gate spec like `for_actor:`). The plan has been updated to use these correct calls.
- **Test sandbox note:** Any test that interacts with FunWithFlags (via `Flags.enabled?`, `Flags.enable`, `Store.lookup`, etc.) MUST `use Verscienta.DataCase, async: false` rather than `use ExUnit.Case`. The Ecto adapter checks out connections from a non-test process and needs the sandbox in `shared: true` mode, which DataCase configures for non-async tests.
- Codex Tailwind tokens: `bg-canvas-2`, `text-ink`, `text-ink-3`. Lowercase page titles. Collocated `.html.heex` templates next to LV modules.
- The `:admin` pipeline at `lib/verscienta_web/router.ex` lines 24-39 already gates admin routes via `role: :admin`. Reuse it.

---

### Task 0: Branch setup

**Files:** none (git only)

- [ ] **Step 1: Confirm clean main + spec present**

```bash
git checkout main && git pull --ff-only
git log -1 --oneline -- docs/superpowers/specs/2026-06-04-feature-flags-design.md
```
Expected: the most recent commit on the spec is `docs: add feature flags design spec` (commit `0aa46cd` or similar).

- [ ] **Step 2: Create the feature branch**

```bash
git checkout -b phase-2-feature-flags
```
Expected: on a clean `phase-2-feature-flags` branch off `main`.

---

### Task 1: Install FunWithFlags + Postgres config + migration

**Files:**
- Modify: `mix.exs` (add dep)
- Modify: `config/config.exs` (FunWithFlags config block)
- Modify: `config/test.exs` (test cache + persistence)
- Create: migration via `mix ecto.gen.migration create_fun_with_flags_toggles`
- Test: `test/verscienta/flags_smoke_test.exs` (new; proves install works)

- [ ] **Step 1: Add the dep**

In `mix.exs`, in the `deps/0` list, add:
```elixir
{:fun_with_flags, "~> 1.12"},
```

Then:
```bash
docker compose exec app mix deps.get
```
Expected: `fun_with_flags` and its deps (`gen_smtp` is NOT a dep — FunWithFlags is small) resolve cleanly.

- [ ] **Step 2: Configure FunWithFlags**

In `config/config.exs`, after the existing `config :verscienta, Oban, ...` block, add:
```elixir
config :fun_with_flags, :persistence,
  adapter: FunWithFlags.Store.Persistent.Ecto,
  repo: Verscienta.Repo

config :fun_with_flags, :cache,
  enabled: true,
  ttl: 900

config :fun_with_flags, :cache_bust_notifications,
  enabled: false
```

The `cache_bust_notifications` defaults to `:phoenix_pubsub`. We're single-node today so we disable it to avoid the runtime trying to configure PubSub for FunWithFlags. When we go multi-node, flip it back on and set `client: :phoenix_pubsub, adapter: Phoenix.PubSub, name: Verscienta.PubSub`.

- [ ] **Step 3: Generate the FunWithFlags migration**

```bash
docker compose exec app mix ecto.gen.migration create_fun_with_flags_toggles
```
Expected: creates a file under `priv/repo/migrations/` with a timestamp prefix. The file will be empty inside `def change do … end`.

Now edit the generated file (`priv/repo/migrations/*_create_fun_with_flags_toggles.exs`). Replace the body with:
```elixir
defmodule Verscienta.Repo.Migrations.CreateFunWithFlagsToggles do
  use Ecto.Migration

  def up do
    create table(:fun_with_flags_toggles, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :flag_name, :string, null: false
      add :gate_type, :string, null: false
      add :target, :string, null: false
      add :enabled, :boolean, null: false
    end

    create unique_index(
             :fun_with_flags_toggles,
             [:flag_name, :gate_type, :target],
             name: "fwf_flag_name_gate_target_idx"
           )
  end

  def down do
    drop table(:fun_with_flags_toggles)
  end
end
```

(This is the schema FunWithFlags expects for the Postgres Ecto adapter; it's documented in the library README.)

- [ ] **Step 4: Migrate dev DB**

```bash
docker compose exec app mix ash.migrate
```
Expected: applies the new migration cleanly. Verify with:
```bash
docker compose exec app mix run -e "IO.inspect(Verscienta.Repo.query!(\"SELECT to_regclass('fun_with_flags_toggles')\").rows)"
```
Expected output: `[[%Postgrex.Reference{...}]]` or `[[\"fun_with_flags_toggles\"]]` (or similar — confirms the table exists).

- [ ] **Step 5: Write a smoke test**

Create `test/verscienta/flags_smoke_test.exs`:
```elixir
defmodule Verscienta.FlagsSmokeTest do
  use Verscienta.DataCase, async: false

  alias FunWithFlags.Store.Cache

  setup do
    Cache.flush()
    FunWithFlags.clear(:smoke_test_flag)
    on_exit(fn ->
      Cache.flush()
      FunWithFlags.clear(:smoke_test_flag)
    end)
    :ok
  end

  test "FunWithFlags persists and reads a boolean" do
    refute FunWithFlags.enabled?(:smoke_test_flag)
    {:ok, true} = FunWithFlags.enable(:smoke_test_flag)
    assert FunWithFlags.enabled?(:smoke_test_flag)
  end
end
```

- [ ] **Step 6: Reset test DB + run smoke**

```bash
docker compose exec -e MIX_ENV=test app sh -c "mix ecto.drop -r Verscienta.Repo && mix ecto.create -r Verscienta.Repo && mix ash.migrate"
docker compose exec -e MIX_ENV=test app mix test test/verscienta/flags_smoke_test.exs
```
Expected: 1 test, 0 failures.

If the test fails with "no such function FunWithFlags.enable/1", you have a dep resolution problem — re-run `mix deps.get`. If it fails with a Postgres error about the toggles table, the migration didn't apply — re-run the reset.

- [ ] **Step 7: Verify and commit**

```bash
docker compose exec app mix format
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix credo --strict
```

```bash
git add mix.exs mix.lock config/config.exs \
  priv/repo/migrations/*_create_fun_with_flags_toggles.exs \
  test/verscienta/flags_smoke_test.exs
git commit -m "$(cat <<'EOF'
feat(flags): install FunWithFlags with Postgres + ETS persistence

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `Verscienta.Flags` wrapper + Actor + Group impls

**Files:**
- Create: `lib/verscienta/flags.ex`
- Create: `lib/verscienta/accounts/user/flag_actor.ex`
- Create: `lib/verscienta/accounts/user/flag_group.ex`
- Test: `test/verscienta/flags_test.exs`

- [ ] **Step 1: Failing tests for `Verscienta.Flags`**

Create `test/verscienta/flags_test.exs`:
```elixir
defmodule Verscienta.FlagsTest do
  use Verscienta.DataCase, async: false

  alias Verscienta.Accounts.User
  alias Verscienta.Flags

  setup do
    FunWithFlags.Store.Cache.flush()
    Enum.each(Flags.known_flags(), &FunWithFlags.clear/1)
    on_exit(fn -> FunWithFlags.Store.Cache.flush() end)
    :ok
  end

  defp register(name) do
    User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com",
      username: name,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  test "known_flags lists 13 atoms" do
    assert length(Flags.known_flags()) == 13
    assert :reward_store in Flags.known_flags()
    assert :for_you_feed in Flags.known_flags()
  end

  test "enabled?/1 returns the boolean state" do
    refute Flags.enabled?(:reward_store)
    Flags.enable(:reward_store)
    assert Flags.enabled?(:reward_store)
  end

  test "enabled?/1 raises on an unknown flag" do
    assert_raise ArgumentError, ~r/Unknown feature flag/, fn ->
      Flags.enabled?(:not_a_real_flag)
    end
  end

  test "enabled?/2 with for: honors per-actor overrides" do
    u = register("alice")
    refute Flags.enabled?(:reward_store, for: u)
    Flags.enable(:reward_store, for_actor: u)
    assert Flags.enabled?(:reward_store, for: u)
  end
end
```

- [ ] **Step 2: Create the wrapper**

Create `lib/verscienta/flags.ex`:
```elixir
defmodule Verscienta.Flags do
  @moduledoc """
  Public API for feature flag checks and toggles. Single chokepoint between
  the rest of the app and FunWithFlags. Flag names are atoms; unknown flag
  names raise to catch typos at the call site.
  """

  @known_flags ~w(
    reward_store referrals
    quests leaderboards
    communities reposts
    ai_enrichment
    for_you_feed live_rooms
    digest_emails auto_moderation
    expert_program writing_assistant
  )a

  @doc "Returns the allowlist of known flag atoms."
  def known_flags, do: @known_flags

  @doc """
  Check whether a flag is on. Optional `for:` actor passes a User (or any
  struct implementing `FunWithFlags.Actor`) so percentage rollouts, per-actor
  overrides, and group checks all work.
  """
  def enabled?(flag, opts \\ [])

  def enabled?(flag, for: actor) when is_atom(flag) do
    validate!(flag)
    FunWithFlags.enabled?(flag, for: actor)
  end

  def enabled?(flag, []) when is_atom(flag) do
    validate!(flag)
    FunWithFlags.enabled?(flag)
  end

  @doc "Enable a flag (globally, or scoped with `for_actor:`, `for_group:`, `for_percentage_of:`)."
  def enable(flag, opts \\ []) do
    validate!(flag)
    do_enable(flag, opts)
  end

  @doc "Disable a flag (globally, or scoped)."
  def disable(flag, opts \\ []) do
    validate!(flag)
    do_disable(flag, opts)
  end

  @doc "List all flags currently stored in FunWithFlags."
  def list do
    case FunWithFlags.all_flags() do
      {:ok, flags} -> flags
      _ -> []
    end
  end

  defp validate!(flag) do
    if flag in @known_flags do
      :ok
    else
      raise ArgumentError,
            "Unknown feature flag: #{inspect(flag)}. Add it to Verscienta.Flags.@known_flags."
    end
  end

  defp do_enable(flag, []), do: FunWithFlags.enable(flag)
  defp do_enable(flag, for_actor: actor), do: FunWithFlags.enable(flag, for_actor: actor)
  defp do_enable(flag, for_group: group), do: FunWithFlags.enable(flag, for_group: group)

  defp do_enable(flag, for_percentage_of: {:actors, p}),
    do: FunWithFlags.enable(flag, for_percentage_of: {:actors, p})

  defp do_disable(flag, []), do: FunWithFlags.disable(flag)
  defp do_disable(flag, for_actor: actor), do: FunWithFlags.disable(flag, for_actor: actor)
  defp do_disable(flag, for_group: group), do: FunWithFlags.disable(flag, for_group: group)

  defp do_disable(flag, for_percentage_of: {:actors, _}),
    do: FunWithFlags.disable(flag, for_percentage_of: {:actors, 0})
end
```

- [ ] **Step 3: Run the Flags tests — should pass except the actor test**

```bash
docker compose exec -e MIX_ENV=test app mix test test/verscienta/flags_test.exs
```
Expected: the per-actor test FAILS because `User` doesn't implement `FunWithFlags.Actor` yet. The other 3 tests pass.

- [ ] **Step 4: Create the Actor impl**

Create `lib/verscienta/accounts/user/flag_actor.ex`:
```elixir
defimpl FunWithFlags.Actor, for: Verscienta.Accounts.User do
  @moduledoc """
  FunWithFlags Actor impl for User. The actor id is `"user:<uuid>"` — what
  FunWithFlags hashes for percentage rollouts and stores per-actor toggles
  against.
  """
  def id(%{id: id}), do: "user:#{id}"
end
```

- [ ] **Step 5: Re-run the actor test — should pass**

```bash
docker compose exec -e MIX_ENV=test app mix test test/verscienta/flags_test.exs
```
Expected: all 4 tests pass.

- [ ] **Step 6: Failing tests for the Group impl**

Append to `test/verscienta/flags_test.exs`:
```elixir
  alias Verscienta.Communities.Group
  alias Verscienta.Communities.GroupMembership

  test "enabled?/2 honors :admins group" do
    u = register("alice")
    # Promote alice to admin (the only writable path is a raw update — :role is writable? false)
    Ecto.Adapters.SQL.query!(
      Verscienta.Repo,
      "UPDATE users SET role = 'admin' WHERE id = $1",
      [Ecto.UUID.dump!(u.id)]
    )
    u = Ash.get!(User, u.id, authorize?: false)

    refute Flags.enabled?(:reward_store, for: u)
    Flags.enable(:reward_store, for_group: :admins)
    assert Flags.enabled?(:reward_store, for: u)
  end

  test "enabled?/2 honors :group_member_<id> group" do
    owner = register("owner")

    group =
      Group
      |> Ash.Changeset.for_create(:create, %{name: "Beta", slug: "beta", visibility: :public}, actor: owner)
      |> Ash.create!()

    member = register("bob")

    GroupMembership
    |> Ash.Changeset.for_create(:create, %{group_id: group.id, user_id: member.id, status: :active, role: :member})
    |> Ash.create!(authorize?: false)

    member = Ash.get!(User, member.id, authorize?: false)
    group_atom = String.to_atom("group_member_" <> to_string(group.id))

    refute Flags.enabled?(:reward_store, for: member)
    Flags.enable(:reward_store, for_group: group_atom)
    assert Flags.enabled?(:reward_store, for: member)
  end
```

If the exact `Group.:create` action signature differs (e.g. visibility key name, requires more attrs), discover via grep:
```bash
docker compose exec app grep -A 5 "create :create" lib/verscienta/communities/group.ex
```
and adapt the test fixture. The contract under test is the Group impl, not Group creation.

- [ ] **Step 7: Run failing tests**

```bash
docker compose exec -e MIX_ENV=test app mix test test/verscienta/flags_test.exs
```
Expected: both new tests fail because no Group impl exists yet.

- [ ] **Step 8: Create the Group impl**

Create `lib/verscienta/accounts/user/flag_group.ex`:
```elixir
defimpl FunWithFlags.Group, for: Verscienta.Accounts.User do
  @moduledoc """
  FunWithFlags Group impl for User. Two flavors of group atom:
  - `:admins | :experts | :moderators` — role match.
  - `:group_member_<group_uuid>` — active Verscienta.Communities.GroupMembership match.
  """
  require Ash.Query
  alias Verscienta.Communities.GroupMembership

  def in?(%{role: role}, :admins), do: role == :admin
  def in?(%{role: role}, :experts), do: role == :expert
  def in?(%{role: role}, :moderators), do: role == :moderator

  def in?(%{id: user_id}, group_atom) when is_atom(group_atom) do
    case Atom.to_string(group_atom) do
      "group_member_" <> group_id ->
        GroupMembership
        |> Ash.Query.filter(user_id == ^user_id and group_id == ^group_id and status == :active)
        |> Ash.exists?(authorize?: false)

      _ ->
        false
    end
  end
end
```

- [ ] **Step 9: Run all Flags tests**

```bash
docker compose exec -e MIX_ENV=test app mix test test/verscienta/flags_test.exs
```
Expected: 6 tests, 0 failures.

- [ ] **Step 10: Verify and commit**

```bash
docker compose exec app mix format
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix credo --strict
docker compose exec -e MIX_ENV=test app mix test
```

```bash
git add lib/verscienta/flags.ex \
  lib/verscienta/accounts/user/flag_actor.ex \
  lib/verscienta/accounts/user/flag_group.ex \
  test/verscienta/flags_test.exs
git commit -m "$(cat <<'EOF'
feat(flags): Verscienta.Flags wrapper + User Actor/Group impls

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Gate plug + Coming Soon LV + admin banner

**Files:**
- Create: `lib/verscienta_web/plugs/gate.ex`
- Create: `lib/verscienta_web/live/coming_soon_live.ex`
- Create: `lib/verscienta_web/live/coming_soon_live.html.heex`
- Create: `lib/verscienta_web/components/flag_components.ex` (admin banner component)
- Test: `test/verscienta_web/plugs/gate_test.exs`

- [ ] **Step 1: Failing tests for the gate plug**

Create `test/verscienta_web/plugs/gate_test.exs`:
```elixir
defmodule VerscientaWeb.Plugs.GateTest do
  use VerscientaWeb.ConnCase, async: false

  alias Verscienta.Accounts.User
  alias Verscienta.Flags

  setup do
    FunWithFlags.Store.Cache.flush()
    Enum.each(Flags.known_flags(), &FunWithFlags.clear/1)
    on_exit(fn -> FunWithFlags.Store.Cache.flush() end)
    :ok
  end

  defp register(name, role \\ :user) do
    u =
      User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: name <> "@example.com",
        username: name,
        password: "password123",
        password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    if role != :user do
      Ecto.Adapters.SQL.query!(
        Verscienta.Repo,
        "UPDATE users SET role = $1 WHERE id = $2",
        [Atom.to_string(role), Ecto.UUID.dump!(u.id)]
      )
    end

    Ash.get!(User, u.id, authorize?: false)
  end

  defp sign_in(conn, u) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(u)
  end

  test "flag on — passes through with :active_flag assigned", %{conn: conn} do
    Flags.enable(:reward_store)
    u = register("alice")
    conn = sign_in(conn, u) |> get(~p"/store")
    assert conn.assigns[:active_flag] == :reward_store
    # Status is whatever the downstream /store LV returns; in our setup the LV needs login + renders 200
    assert conn.status in [200, 302]
  end

  test "flag off, non-admin — renders Coming Soon LV", %{conn: conn} do
    u = register("bob")
    conn = sign_in(conn, u) |> get(~p"/store")
    assert conn.status == 200
    assert html_response(conn, 200) =~ "Coming soon"
  end

  test "flag off, admin — passes through with :flag_force_visible", %{conn: conn} do
    a = register("admin1", :admin)
    conn = sign_in(conn, a) |> get(~p"/store")
    assert conn.assigns[:active_flag] == :reward_store
    assert conn.assigns[:flag_force_visible] == true
  end
end
```

NOTE: this test depends on `/store` being gated (Task 9 wires that). Until Task 9 lands, these tests will hit a route without the gate plug attached. We solve this by writing the plug FIRST and a tiny isolated test that doesn't depend on a real route. Replace the above with the simpler test for now:

```elixir
defmodule VerscientaWeb.Plugs.GateTest do
  use VerscientaWeb.ConnCase, async: false

  alias Verscienta.Accounts.User
  alias Verscienta.Flags
  alias VerscientaWeb.Plugs.Gate

  setup do
    FunWithFlags.Store.Cache.flush()
    Enum.each(Flags.known_flags(), &FunWithFlags.clear/1)
    on_exit(fn -> FunWithFlags.Store.Cache.flush() end)
    :ok
  end

  defp register(name, role \\ :user) do
    u =
      User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: name <> "@example.com",
        username: name,
        password: "password123",
        password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    if role != :user do
      Ecto.Adapters.SQL.query!(
        Verscienta.Repo,
        "UPDATE users SET role = $1 WHERE id = $2",
        [Atom.to_string(role), Ecto.UUID.dump!(u.id)]
      )
    end

    Ash.get!(User, u.id, authorize?: false)
  end

  defp build_conn_for(user) do
    Phoenix.ConnTest.build_conn()
    |> Phoenix.ConnTest.bypass_through(VerscientaWeb.Router, [:browser])
    |> Plug.Conn.assign(:current_user, user)
  end

  test "flag on — passes through with :active_flag assigned" do
    Flags.enable(:reward_store)
    u = register("alice")
    conn = build_conn_for(u) |> Gate.call(flag: :reward_store)
    refute conn.halted
    assert conn.assigns.active_flag == :reward_store
  end

  test "flag off, non-admin — halts and renders Coming Soon" do
    u = register("bob")
    conn = build_conn_for(u) |> Gate.call(flag: :reward_store)
    assert conn.halted
    assert conn.resp_body =~ "Coming soon"
  end

  test "flag off, admin — passes through with :flag_force_visible" do
    a = register("admin1", :admin)
    conn = build_conn_for(a) |> Gate.call(flag: :reward_store)
    refute conn.halted
    assert conn.assigns.flag_force_visible == true
  end

  test "flag off, anonymous — halts and renders Coming Soon" do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.bypass_through(VerscientaWeb.Router, [:browser])
      |> Plug.Conn.assign(:current_user, nil)
      |> Gate.call(flag: :reward_store)

    assert conn.halted
    assert conn.resp_body =~ "Coming soon"
  end
end
```

- [ ] **Step 2: Create the Coming Soon LV**

Create `lib/verscienta_web/live/coming_soon_live.ex`:
```elixir
defmodule VerscientaWeb.ComingSoonLive do
  use VerscientaWeb, :live_view

  @impl true
  def mount(_params, %{"flag" => flag}, socket) do
    {:ok, assign(socket, flag: flag, page_title: "coming soon")}
  end

  @doc "Render-time helper: human label for a flag string."
  def human_label(flag_string) do
    Verscienta.Flags.Seeds.labels()
    |> Map.get(String.to_existing_atom(flag_string))
    |> case do
      nil -> flag_string |> String.replace("_", " ") |> String.capitalize()
      label -> label
    end
  rescue
    ArgumentError -> flag_string |> String.replace("_", " ") |> String.capitalize()
  end
end
```

Note: `Verscienta.Flags.Seeds` is created in Task 5. For now, `human_label/1` will fall through to the rescue branch and use the title-cased flag name. That's the correct fallback behavior anyway.

Create `lib/verscienta_web/live/coming_soon_live.html.heex`:
```heex
<div class="mx-auto max-w-xl p-8 text-center space-y-4">
  <h1 class="text-3xl font-bold lowercase text-ink">Coming soon</h1>
  <p class="text-ink-3"><%= human_label(@flag) %> isn't available yet. Check back later.</p>
  <p class="text-xs text-ink-3">
    <.link navigate={~p"/"} class="underline">Back to the front page →</.link>
  </p>
</div>
```

- [ ] **Step 3: Create the Gate plug**

Create `lib/verscienta_web/plugs/gate.ex`:
```elixir
defmodule VerscientaWeb.Plugs.Gate do
  @moduledoc """
  Per-route feature-flag gate.

  Usage in router:
      plug :gate, flag: :reward_store

  Three branches:
  1. Flag on → `:active_flag` assigned, pass through.
  2. Flag off + admin viewer → `:flag_force_visible: true`, pass through.
     The downstream LV can render an admin-only banner.
  3. Flag off + non-admin → render ComingSoonLive and halt the pipeline.
  """
  import Plug.Conn

  alias Verscienta.Flags

  def init(opts), do: opts

  def call(conn, opts) do
    flag = Keyword.fetch!(opts, :flag)
    user = conn.assigns[:current_user]

    enabled? =
      if user, do: Flags.enabled?(flag, for: user), else: Flags.enabled?(flag)

    cond do
      enabled? ->
        assign(conn, :active_flag, flag)

      admin?(user) ->
        conn
        |> assign(:active_flag, flag)
        |> assign(:flag_force_visible, true)

      true ->
        render_coming_soon(conn, flag)
    end
  end

  defp admin?(%{role: :admin}), do: true
  defp admin?(_), do: false

  defp render_coming_soon(conn, flag) do
    conn
    |> assign(:flag_off_for, flag)
    |> Phoenix.LiveView.Controller.live_render(VerscientaWeb.ComingSoonLive,
      session: %{"flag" => Atom.to_string(flag)}
    )
    |> halt()
  end
end
```

If `Phoenix.LiveView.Controller.live_render/3` doesn't exist in the installed phoenix_live_view version, the alternative is `Phoenix.LiveView.Controller` was renamed in some versions. Verify with:
```bash
docker compose exec app mix run -e "IO.inspect(Phoenix.LiveView.Controller.module_info(:exports))"
```
If `live_render` isn't there, the modern API is `Phoenix.LiveView.Plug` mounted as a phoenix-controller endpoint. For this project's Phoenix 1.8 + LV 1.0+ the standard is:
```elixir
Phoenix.Controller.put_view(conn, VerscientaWeb.PageHTML)
|> Phoenix.LiveView.Controller.live_render(VerscientaWeb.ComingSoonLive, session: %{...})
```

If both fail, the fallback is to render the static "Coming soon" HTML directly as a string via `send_resp/3`:
```elixir
conn
|> put_resp_content_type("text/html")
|> send_resp(200, ~s"""
<!doctype html>
<html><body><h1>Coming soon</h1><p>This feature isn't available yet.</p></body></html>
""")
|> halt()
```
Use whichever works; the test only asserts `conn.halted` and that the body contains "Coming soon".

- [ ] **Step 4: Run gate tests**

```bash
docker compose exec -e MIX_ENV=test app mix test test/verscienta_web/plugs/gate_test.exs
```
Expected: 4 tests, 0 failures.

- [ ] **Step 5: Create the admin banner component**

Create `lib/verscienta_web/components/flag_components.ex`:
```elixir
defmodule VerscientaWeb.FlagComponents do
  @moduledoc "Reusable components related to feature flags."
  use Phoenix.Component

  @doc """
  Banner rendered on routes where the flag is off but the viewer is an admin
  (the gate plug bypassed them). Renders nothing unless `force_visible == true`.
  """
  attr :flag, :atom, default: nil
  attr :force_visible, :boolean, default: false

  def flag_admin_banner(assigns) do
    ~H"""
    <%= if @force_visible and @flag do %>
      <div class="mx-auto max-w-3xl mt-2 px-3 py-2 rounded text-xs bg-canvas-2 text-ink-3 border-l-4">
        🚧 Admin preview — <code class="font-mono"><%= @flag %></code> is gated off for non-admins.
      </div>
    <% end %>
    """
  end
end
```

- [ ] **Step 6: Verify and commit**

```bash
docker compose exec app mix format
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix credo --strict
```

```bash
git add lib/verscienta_web/plugs/gate.ex \
  lib/verscienta_web/live/coming_soon_live.ex \
  lib/verscienta_web/live/coming_soon_live.html.heex \
  lib/verscienta_web/components/flag_components.ex \
  test/verscienta_web/plugs/gate_test.exs
git commit -m "$(cat <<'EOF'
feat(flags): Gate plug + ComingSoonLive + admin banner component

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Audit resource

**Files:**
- Create: `lib/verscienta/flags/audit.ex`
- Modify: `lib/verscienta/accounts.ex` or wherever new domains register (actually a new domain — see Step 1)
- Create: `lib/verscienta/flags_domain.ex` (Ash domain wrapping the audit resource)
- Modify: `config/config.exs` (register the new Ash domain)
- Test: `test/verscienta/flags/audit_test.exs`

- [ ] **Step 1: Decide on Ash domain placement**

Audit lives in a new Ash domain `Verscienta.Flags.Domain` (to keep flag-related Ash resources together). Confirm the project's `ash_domains` config in `config/config.exs`:
```bash
docker compose exec app grep -A 10 "ash_domains" config/config.exs
```
Expected: a list of existing domains. The new `Verscienta.Flags.Domain` gets appended.

- [ ] **Step 2: Create the Audit resource**

Create `lib/verscienta/flags/audit.ex`:
```elixir
defmodule Verscienta.Flags.Audit do
  @moduledoc "Audit log for feature flag mutations."
  use Ash.Resource,
    otp_app: :verscienta,
    domain: Verscienta.Flags.Domain,
    data_layer: AshPostgres.DataLayer

  @actions [
    :enable,
    :disable,
    :set_percentage,
    :clear_percentage,
    :add_actor,
    :remove_actor,
    :add_group,
    :remove_group
  ]

  def actions_list, do: @actions

  postgres do
    table "feature_flag_audits"
    repo Verscienta.Repo

    custom_indexes do
      index [:flag_name, :occurred_at]
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [:actor_user_id, :flag_name, :action, :params, :occurred_at]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :flag_name, :string, allow_nil?: false, public?: true

    attribute :action, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: @actions]

    attribute :params, :map, allow_nil?: false, default: %{}, public?: true
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :actor_user, Verscienta.Accounts.User, allow_nil?: true
  end
end
```

- [ ] **Step 3: Create the Ash domain**

Create `lib/verscienta/flags/domain.ex`:
```elixir
defmodule Verscienta.Flags.Domain do
  @moduledoc "Domain for feature-flag-related Ash resources."
  use Ash.Domain, otp_app: :verscienta

  resources do
    resource Verscienta.Flags.Audit
  end
end
```

- [ ] **Step 4: Register the new domain in config**

In `config/config.exs`, find the `ash_domains:` list and append `Verscienta.Flags.Domain`:
```elixir
config :verscienta, ash_domains: [
  # ...existing domains...
  Verscienta.Flags.Domain
]
```

- [ ] **Step 5: Generate migration**

```bash
docker compose exec app mix ash.codegen add_feature_flag_audit
```
Expected: a new migration under `priv/repo/migrations/` creating `feature_flag_audits`. Inspect for sanity.

```bash
docker compose exec app mix ash.migrate
```

- [ ] **Step 6: Failing tests for audit writes**

Create `test/verscienta/flags/audit_test.exs`:
```elixir
defmodule Verscienta.Flags.AuditTest do
  use Verscienta.DataCase, async: false

  require Ash.Query

  alias Verscienta.Accounts.User
  alias Verscienta.Flags.Audit

  defp register(name) do
    User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com",
      username: name,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  test "writes an audit row for a flag mutation" do
    u = register("alice")
    now = DateTime.utc_now()

    Audit
    |> Ash.Changeset.for_create(:create, %{
      actor_user_id: u.id,
      flag_name: "reward_store",
      action: :enable,
      params: %{},
      occurred_at: now
    })
    |> Ash.create!(authorize?: false)

    [a] =
      Audit
      |> Ash.Query.filter(flag_name == "reward_store")
      |> Ash.read!(authorize?: false)

    assert a.action == :enable
    assert a.actor_user_id == u.id
  end

  test "actor_user_id is nullable (system seed case)" do
    Audit
    |> Ash.Changeset.for_create(:create, %{
      actor_user_id: nil,
      flag_name: "for_you_feed",
      action: :disable,
      params: %{},
      occurred_at: DateTime.utc_now()
    })
    |> Ash.create!(authorize?: false)

    [a] =
      Audit
      |> Ash.Query.filter(flag_name == "for_you_feed")
      |> Ash.read!(authorize?: false)

    assert is_nil(a.actor_user_id)
  end
end
```

- [ ] **Step 7: Run audit tests**

```bash
docker compose exec -e MIX_ENV=test app sh -c "mix ecto.drop -r Verscienta.Repo && mix ecto.create -r Verscienta.Repo && mix ash.migrate && mix test test/verscienta/flags/audit_test.exs"
```
Expected: 2 tests, 0 failures.

- [ ] **Step 8: Verify and commit**

```bash
docker compose exec app mix format
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix credo --strict
docker compose exec -e MIX_ENV=test app mix test
```

```bash
git add lib/verscienta/flags/audit.ex \
  lib/verscienta/flags/domain.ex \
  config/config.exs \
  priv/repo/migrations/*_add_feature_flag_audit.exs \
  priv/resource_snapshots/repo/feature_flag_audits/*.json \
  test/verscienta/flags/audit_test.exs
git commit -m "$(cat <<'EOF'
feat(flags): Audit Ash resource for feature flag mutations

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Seeds + mix task

**Files:**
- Create: `lib/verscienta/flags/seeds.ex`
- Create: `lib/mix/tasks/verscienta.flags.seed.ex`
- Test: `test/verscienta/flags/seeds_test.exs`

- [ ] **Step 1: Failing test**

Create `test/verscienta/flags/seeds_test.exs`:
```elixir
defmodule Verscienta.Flags.SeedsTest do
  use Verscienta.DataCase, async: false

  alias Verscienta.Flags
  alias Verscienta.Flags.Seeds

  setup do
    FunWithFlags.Store.Cache.flush()
    Enum.each(Flags.known_flags(), &FunWithFlags.clear/1)
    on_exit(fn -> FunWithFlags.Store.Cache.flush() end)
    :ok
  end

  test "seed! enables the 7 retroactive flags" do
    Seeds.seed!()

    for flag <- Seeds.retroactive_on() do
      assert Flags.enabled?(flag), "expected #{flag} to be enabled after seed!"
    end
  end

  test "seed! materializes Phase 3 placeholders as off rows" do
    Seeds.seed!()

    for flag <- Seeds.phase3_off() do
      refute Flags.enabled?(flag), "expected #{flag} to be disabled after seed!"
    end
  end

  test "seed! is idempotent (running twice produces the same state)" do
    Seeds.seed!()
    state_after_first = Enum.map(Flags.known_flags(), &{&1, Flags.enabled?(&1)})

    Seeds.seed!()
    state_after_second = Enum.map(Flags.known_flags(), &{&1, Flags.enabled?(&1)})

    assert state_after_first == state_after_second
  end

  test "labels covers every known flag" do
    for flag <- Flags.known_flags() do
      assert Map.has_key?(Seeds.labels(), flag), "missing label for #{flag}"
    end
  end
end
```

- [ ] **Step 2: Create the Seeds module**

Create `lib/verscienta/flags/seeds.ex`:
```elixir
defmodule Verscienta.Flags.Seeds do
  @moduledoc "Idempotent seeds for the v1 feature flag catalog."

  alias Verscienta.Flags

  @retroactive_on ~w(reward_store referrals quests leaderboards communities reposts ai_enrichment)a
  @phase3_off ~w(for_you_feed live_rooms digest_emails auto_moderation expert_program writing_assistant)a

  @labels %{
    reward_store: "The reward store",
    referrals: "Referrals",
    quests: "Quests",
    leaderboards: "Leaderboards",
    communities: "Communities & groups",
    reposts: "Reposts",
    ai_enrichment: "AI article enrichment",
    for_you_feed: "The For You feed",
    live_rooms: "Live discussion rooms",
    digest_emails: "Email digests",
    auto_moderation: "Automatic moderation",
    expert_program: "The expert program",
    writing_assistant: "Writing assistant"
  }

  def retroactive_on, do: @retroactive_on
  def phase3_off, do: @phase3_off
  def labels, do: @labels

  def seed! do
    Enum.each(@retroactive_on, fn flag ->
      unless boolean_on?(flag), do: Flags.enable(flag)
    end)

    Enum.each(@phase3_off, fn flag ->
      unless flag_has_any_row?(flag) do
        # Materialize a row so the admin UI lists it as "Off" rather than "Unknown".
        Flags.enable(flag)
        Flags.disable(flag)
      end
    end)

    :ok
  end

  defp boolean_on?(flag) do
    case FunWithFlags.Store.lookup(flag) do
      {:ok, %FunWithFlags.Flag{gates: gates}} ->
        Enum.any?(gates, fn
          %FunWithFlags.Gate{type: :boolean, enabled: true} -> true
          _ -> false
        end)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp flag_has_any_row?(flag) do
    case FunWithFlags.Store.lookup(flag) do
      {:ok, %FunWithFlags.Flag{gates: [_ | _]}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
```

The `Store.lookup/1` API exists in fun_with_flags. If the implementer can't find it, use the higher-level `FunWithFlags.all_flags/0` and find the flag by name. The behavior we want: return true iff the boolean gate is on (for `boolean_on?`) or iff any gate exists (for `flag_has_any_row?`).

- [ ] **Step 3: Create the mix task**

Create `lib/mix/tasks/verscienta.flags.seed.ex`:
```elixir
defmodule Mix.Tasks.Verscienta.Flags.Seed do
  @moduledoc "Idempotent seeds for the v1 feature flag catalog."
  use Mix.Task

  @shortdoc "Seed feature flags"

  def run(_args) do
    Mix.Task.run("app.start")
    Verscienta.Flags.Seeds.seed!()
    IO.puts("Feature flags seeded.")
  end
end
```

- [ ] **Step 4: Run seeds tests**

```bash
docker compose exec -e MIX_ENV=test app mix test test/verscienta/flags/seeds_test.exs
```
Expected: 4 tests, 0 failures.

- [ ] **Step 5: Verify and commit**

```bash
docker compose exec app mix format
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix credo --strict
docker compose exec -e MIX_ENV=test app mix test
```

```bash
git add lib/verscienta/flags/seeds.ex \
  lib/mix/tasks/verscienta.flags.seed.ex \
  test/verscienta/flags/seeds_test.exs
git commit -m "$(cat <<'EOF'
feat(flags): seeds module + mix verscienta.flags.seed task

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Auto-seed in test_helper + DataCase cache-clear

**Files:**
- Modify: `test/test_helper.exs`
- Modify: `test/support/data_case.ex`

- [ ] **Step 1: Inspect the existing test_helper.exs and data_case.ex**

```bash
docker compose exec app cat test/test_helper.exs
docker compose exec app cat test/support/data_case.ex
```

The existing `test_helper.exs` likely contains `ExUnit.start()` and `Ecto.Adapters.SQL.Sandbox.mode(Verscienta.Repo, :manual)`. We want to add the seed call AFTER `ExUnit.start()` but BEFORE any test starts — which means after the sandbox-mode line.

`data_case.ex` likely has a `setup` macro/function that calls `Ecto.Adapters.SQL.Sandbox.checkout(Verscienta.Repo)`. We add the cache-clear `on_exit` there.

- [ ] **Step 2: Add seed call to test_helper.exs**

At the bottom of `test/test_helper.exs`, add:
```elixir
# Seed feature flags once, OUTSIDE the per-test sandbox transaction, so every
# test sees the production-like seeded state (retroactive flags on, Phase 3 off).
# Per-test mutations roll back via the sandbox + the DataCase cache-clear hook.
{:ok, _} = Application.ensure_all_started(:verscienta)
Verscienta.Flags.Seeds.seed!()
```

Note: `Application.ensure_all_started/1` is a no-op if the app already started (which it has, post `ExUnit.start`). It's belt-and-suspenders for the case where some env-specific config delays app startup.

- [ ] **Step 3: Add cache-clear to DataCase setup**

In `test/support/data_case.ex`, find the `setup` block (it likely calls `Ecto.Adapters.SQL.Sandbox.checkout/1` and similar). Add:
```elixir
# Clear FunWithFlags ETS cache after each test so per-test mutations
# (which rolled back via the Ecto sandbox) don't leak via the cache.
on_exit(fn -> FunWithFlags.Store.Cache.flush() end)
```

The exact insertion point depends on the existing DataCase structure. Look for a pattern like:
```elixir
setup tags do
  Verscienta.DataCase.setup_sandbox(tags)
  :ok
end
```
or
```elixir
def setup_sandbox(tags) do
  pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Verscienta.Repo, shared: not tags[:async])
  on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
end
```
Add the `on_exit` for `FunWithFlags.clear_cache/0` next to the sandbox `on_exit`.

If `ConnCase` doesn't `use DataCase`, you may also need to add the cache-clear there. Check:
```bash
docker compose exec app grep -A 20 "setup_sandbox\|setup tags" test/support/conn_case.ex
```
If `ConnCase` has its own `setup`, mirror the change.

- [ ] **Step 4: Reset test DB and run full suite**

```bash
docker compose exec -e MIX_ENV=test app sh -c "mix ecto.drop -r Verscienta.Repo && mix ecto.create -r Verscienta.Repo && mix ash.migrate"
docker compose exec -e MIX_ENV=test app mix test
```
Expected: every previously-passing test still passes (the new gates aren't wired yet, so behavior is unchanged). Total should be the prior count plus the new tests added in Tasks 1-5 (1 smoke + 6 flags + 4 gate + 2 audit + 4 seeds = 17 new). So the count should jump by ~17.

- [ ] **Step 5: Verify and commit**

```bash
docker compose exec app mix format
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix credo --strict
```

```bash
git add test/test_helper.exs test/support/data_case.ex test/support/conn_case.ex
git commit -m "$(cat <<'EOF'
test(flags): auto-seed in test_helper + clear FunWithFlags cache between tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: AdminFlagsLive — index

**Files:**
- Create: `lib/verscienta_web/live/admin_flags_live.ex`
- Create: `lib/verscienta_web/live/admin_flags_live.html.heex`
- Modify: `lib/verscienta_web/router.ex` (add route under `:admin` pipeline)
- Test: `test/verscienta_web/live/admin_flags_live_test.exs`

- [ ] **Step 1: Inspect the existing admin route structure**

```bash
docker compose exec app grep -B 2 -A 10 "admin_required\|:admin\]" lib/verscienta_web/router.ex
```
Expected: there's an `:admin` pipeline and a block like:
```elixir
scope "/admin", VerscientaWeb do
  pipe_through [:browser, :admin]
  live "/sources", AdminSourcesLive, :index
end
```
Add `live "/flags", AdminFlagsLive, :index` to the same block.

- [ ] **Step 2: Inspect the existing AdminSourcesLive for pattern**

```bash
docker compose exec app head -100 lib/verscienta_web/live/admin_sources_live.ex
```
Note the layout structure, how it loads data in mount, how PubSub is used (if at all). Mirror the structure.

- [ ] **Step 3: Failing test**

Create `test/verscienta_web/live/admin_flags_live_test.exs`:
```elixir
defmodule VerscientaWeb.AdminFlagsLiveTest do
  use VerscientaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Verscienta.Accounts.User
  alias Verscienta.Flags

  setup do
    FunWithFlags.Store.Cache.flush()
    Verscienta.Flags.Seeds.seed!()
    on_exit(fn -> FunWithFlags.Store.Cache.flush() end)
    :ok
  end

  defp register(name, role \\ :user) do
    u =
      User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: name <> "@example.com",
        username: name,
        password: "password123",
        password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    if role != :user do
      Ecto.Adapters.SQL.query!(
        Verscienta.Repo,
        "UPDATE users SET role = $1 WHERE id = $2",
        [Atom.to_string(role), Ecto.UUID.dump!(u.id)]
      )
    end

    Ash.get!(User, u.id, authorize?: false)
  end

  defp sign_in(conn, u) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(u)
  end

  test "non-admin is redirected", %{conn: conn} do
    u = register("alice")
    conn = sign_in(conn, u) |> get(~p"/admin/flags")
    assert redirected_to(conn) == "/"
  end

  test "admin sees the 13 flags partitioned into two sections", %{conn: conn} do
    a = register("admin1", :admin)
    conn = sign_in(conn, a)
    {:ok, _view, html} = live(conn, ~p"/admin/flags")

    assert html =~ "Retroactive"
    assert html =~ "Phase 3"
    assert html =~ "reward_store"
    assert html =~ "for_you_feed"
  end

  test "admin can quick-toggle a flag", %{conn: conn} do
    a = register("admin1", :admin)
    conn = sign_in(conn, a)
    {:ok, view, _html} = live(conn, ~p"/admin/flags")

    assert Flags.enabled?(:reward_store)

    view
    |> element("button[phx-value-flag='reward_store'][phx-value-action='disable']")
    |> render_click()

    refute Flags.enabled?(:reward_store)
  end
end
```

- [ ] **Step 4: Create AdminFlagsLive**

Create `lib/verscienta_web/live/admin_flags_live.ex`:
```elixir
defmodule VerscientaWeb.AdminFlagsLive do
  use VerscientaWeb, :live_view

  alias Verscienta.Flags
  alias Verscienta.Flags.Audit
  alias Verscienta.Flags.Seeds

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Verscienta.PubSub, "flags")

    {:ok,
     socket
     |> assign(page_title: "feature flags")
     |> load()}
  end

  defp load(socket) do
    flags = Flags.list()
    retroactive = Seeds.retroactive_on()
    phase3 = Seeds.phase3_off()
    labels = Seeds.labels()

    retroactive_flags = Enum.filter(flags, &(&1.name in retroactive))
    phase3_flags = Enum.filter(flags, &(&1.name in phase3))

    assign(socket,
      retroactive_flags: retroactive_flags,
      phase3_flags: phase3_flags,
      labels: labels
    )
  end

  @impl true
  def handle_event("toggle", %{"flag" => flag_str, "action" => action}, socket) do
    flag = String.to_existing_atom(flag_str)
    actor = socket.assigns.current_user

    case action do
      "enable" ->
        Flags.enable(flag)
        write_audit(actor, flag, :enable, %{})

      "disable" ->
        Flags.disable(flag)
        write_audit(actor, flag, :disable, %{})
    end

    Phoenix.PubSub.broadcast(Verscienta.PubSub, "flags", {:flag_changed, flag})
    {:noreply, load(socket)}
  end

  @impl true
  def handle_info({:flag_changed, _flag}, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp write_audit(actor, flag, action, params) do
    Audit
    |> Ash.Changeset.for_create(:create, %{
      actor_user_id: actor && actor.id,
      flag_name: Atom.to_string(flag),
      action: action,
      params: params,
      occurred_at: DateTime.utc_now()
    })
    |> Ash.create(authorize?: false)
  rescue
    _ -> :ok
  end

  @doc "Render-time helper: summary line for a flag's gates."
  def summary(flag) do
    parts =
      Enum.flat_map(flag.gates, fn gate ->
        case gate do
          %FunWithFlags.Gate{type: :boolean, enabled: e} -> ["Boolean: " <> if(e, do: "on", else: "off")]
          %FunWithFlags.Gate{type: :actor, for: t, enabled: true} -> ["Actor on: " <> t]
          %FunWithFlags.Gate{type: :actor, for: t, enabled: false} -> ["Actor off: " <> t]
          %FunWithFlags.Gate{type: :group, for: t, enabled: true} -> ["Group on: " <> to_string(t)]
          %FunWithFlags.Gate{type: :group, for: t, enabled: false} -> ["Group off: " <> to_string(t)]
          %FunWithFlags.Gate{type: :percentage_of_actors, for: pct} -> ["Rollout: " <> "#{trunc(pct * 100)}%"]
          _ -> []
        end
      end)

    case parts do
      [] -> "(no gates)"
      p -> Enum.join(p, " · ")
    end
  end
end
```

Create `lib/verscienta_web/live/admin_flags_live.html.heex`:
```heex
<div class="mx-auto max-w-3xl p-4 space-y-6">
  <h1 class="text-2xl font-bold lowercase text-ink">feature flags</h1>

  <section class="space-y-3">
    <h2 class="text-sm uppercase tracking-wide text-ink-3">Retroactive (existing features)</h2>
    <ul class="space-y-2">
      <%= for flag <- @retroactive_flags do %>
        <li class="rounded p-3 bg-canvas-2 flex items-center justify-between">
          <div>
            <.link navigate={~p"/admin/flags/#{flag.name}"} class="font-mono text-ink underline">
              <%= flag.name %>
            </.link>
            <p class="text-xs text-ink-3"><%= @labels[flag.name] %></p>
            <p class="text-xs text-ink-3"><%= summary(flag) %></p>
          </div>
          <div class="flex gap-2 text-xs">
            <button phx-click="toggle" phx-value-flag={flag.name} phx-value-action="enable" type="button" class="px-2 py-1 rounded bg-canvas-3">
              On
            </button>
            <button phx-click="toggle" phx-value-flag={flag.name} phx-value-action="disable" type="button" class="px-2 py-1 rounded bg-canvas-3">
              Off
            </button>
          </div>
        </li>
      <% end %>
    </ul>
  </section>

  <section class="space-y-3">
    <h2 class="text-sm uppercase tracking-wide text-ink-3">Phase 3 placeholders</h2>
    <ul class="space-y-2">
      <%= for flag <- @phase3_flags do %>
        <li class="rounded p-3 bg-canvas-2 flex items-center justify-between">
          <div>
            <.link navigate={~p"/admin/flags/#{flag.name}"} class="font-mono text-ink underline">
              <%= flag.name %>
            </.link>
            <p class="text-xs text-ink-3"><%= @labels[flag.name] %></p>
            <p class="text-xs text-ink-3"><%= summary(flag) %></p>
          </div>
          <div class="flex gap-2 text-xs">
            <button phx-click="toggle" phx-value-flag={flag.name} phx-value-action="enable" type="button" class="px-2 py-1 rounded bg-canvas-3">
              On
            </button>
            <button phx-click="toggle" phx-value-flag={flag.name} phx-value-action="disable" type="button" class="px-2 py-1 rounded bg-canvas-3">
              Off
            </button>
          </div>
        </li>
      <% end %>
    </ul>
  </section>
</div>
```

- [ ] **Step 5: Add route**

In `lib/verscienta_web/router.ex`, in the `scope "/admin", VerscientaWeb` block that has `pipe_through [:browser, :admin]`, add:
```elixir
      live "/flags", AdminFlagsLive, :index
```

- [ ] **Step 6: Run tests**

```bash
docker compose exec -e MIX_ENV=test app mix test test/verscienta_web/live/admin_flags_live_test.exs
```
Expected: 3 tests, 0 failures.

- [ ] **Step 7: Verify and commit**

```bash
docker compose exec app mix format
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix credo --strict
```

```bash
git add lib/verscienta_web/live/admin_flags_live.ex \
  lib/verscienta_web/live/admin_flags_live.html.heex \
  lib/verscienta_web/router.ex \
  test/verscienta_web/live/admin_flags_live_test.exs
git commit -m "$(cat <<'EOF'
feat(flags): AdminFlagsLive index at /admin/flags

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: AdminFlagShowLive — drill-down

**Files:**
- Create: `lib/verscienta_web/live/admin_flag_show_live.ex`
- Create: `lib/verscienta_web/live/admin_flag_show_live.html.heex`
- Modify: `lib/verscienta_web/router.ex`
- Test: `test/verscienta_web/live/admin_flag_show_live_test.exs`

- [ ] **Step 1: Failing test**

Create `test/verscienta_web/live/admin_flag_show_live_test.exs`:
```elixir
defmodule VerscientaWeb.AdminFlagShowLiveTest do
  use VerscientaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  require Ash.Query

  alias Verscienta.Accounts.User
  alias Verscienta.Flags
  alias Verscienta.Flags.Audit

  setup do
    FunWithFlags.Store.Cache.flush()
    Verscienta.Flags.Seeds.seed!()
    on_exit(fn -> FunWithFlags.Store.Cache.flush() end)
    :ok
  end

  defp register(name, role \\ :user) do
    u =
      User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: name <> "@example.com",
        username: name,
        password: "password123",
        password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    if role != :user do
      Ecto.Adapters.SQL.query!(
        Verscienta.Repo,
        "UPDATE users SET role = $1 WHERE id = $2",
        [Atom.to_string(role), Ecto.UUID.dump!(u.id)]
      )
    end

    Ash.get!(User, u.id, authorize?: false)
  end

  defp sign_in(conn, u) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(u)
  end

  test "admin can set percentage rollout and an audit row is written", %{conn: conn} do
    a = register("admin1", :admin)
    conn = sign_in(conn, a)

    {:ok, view, _html} = live(conn, ~p"/admin/flags/for_you_feed")

    view
    |> form("form[phx-submit='set_percentage']", %{percentage: "25"})
    |> render_submit()

    # Lookup the flag and confirm a percentage gate is recorded
    {:ok, %FunWithFlags.Flag{gates: gates}} = FunWithFlags.Store.lookup(:for_you_feed)
    assert Enum.any?(gates, fn
      %FunWithFlags.Gate{type: :percentage_of_actors, for: 0.25} -> true
      _ -> false
    end)

    # Audit row exists
    [a] =
      Audit
      |> Ash.Query.filter(flag_name == "for_you_feed" and action == :set_percentage)
      |> Ash.read!(authorize?: false)

    assert a.params["percentage"] == 25
  end

  test "admin can add a user actor override", %{conn: conn} do
    a = register("admin1", :admin)
    target = register("targetuser")
    conn = sign_in(conn, a)

    {:ok, view, _html} = live(conn, ~p"/admin/flags/for_you_feed")

    view
    |> form("form[phx-submit='add_actor']", %{username: "targetuser", state: "on"})
    |> render_submit()

    assert Flags.enabled?(:for_you_feed, for: target)
  end

  test "admin can toggle a role group", %{conn: conn} do
    a = register("admin1", :admin)
    conn = sign_in(conn, a)

    {:ok, view, _html} = live(conn, ~p"/admin/flags/for_you_feed")

    view
    |> element("button[phx-click='toggle_group'][phx-value-group='admins']")
    |> render_click()

    {:ok, %FunWithFlags.Flag{gates: gates}} = FunWithFlags.Store.lookup(:for_you_feed)

    assert Enum.any?(gates, fn
      %FunWithFlags.Gate{type: :group, for: "admins", enabled: true} -> true
      _ -> false
    end)
  end
end
```

- [ ] **Step 2: Create the LV**

Create `lib/verscienta_web/live/admin_flag_show_live.ex`:
```elixir
defmodule VerscientaWeb.AdminFlagShowLive do
  use VerscientaWeb, :live_view

  require Ash.Query

  alias Verscienta.Accounts.User
  alias Verscienta.Flags
  alias Verscienta.Flags.Audit
  alias Verscienta.Flags.Seeds

  @role_groups [:admins, :experts, :moderators]

  @impl true
  def mount(%{"name" => name_str}, _session, socket) do
    flag = String.to_existing_atom(name_str)

    if flag not in Flags.known_flags() do
      {:ok, socket |> put_flash(:error, "Unknown flag.") |> push_navigate(to: ~p"/admin/flags")}
    else
      {:ok,
       socket
       |> assign(page_title: "flag: #{name_str}")
       |> assign(flag: flag, flag_name: name_str)
       |> assign(role_groups: @role_groups)
       |> load()}
    end
  rescue
    ArgumentError ->
      {:ok, socket |> put_flash(:error, "Unknown flag.") |> push_navigate(to: ~p"/admin/flags")}
  end

  defp load(socket) do
    flag = socket.assigns.flag

    {:ok, fwf_flag} = FunWithFlags.Store.lookup(flag)
    audit_rows = recent_audit(flag)

    socket
    |> assign(fwf_flag: fwf_flag)
    |> assign(gates: fwf_flag.gates)
    |> assign(audit_rows: audit_rows)
  end

  defp recent_audit(flag) do
    Audit
    |> Ash.Query.filter(flag_name == ^Atom.to_string(flag))
    |> Ash.Query.sort(occurred_at: :desc)
    |> Ash.Query.limit(20)
    |> Ash.read!(authorize?: false)
  end

  @impl true
  def handle_event("set_boolean", %{"state" => state}, socket) do
    flag = socket.assigns.flag

    case state do
      "on" -> Flags.enable(flag)
      "off" -> Flags.disable(flag)
    end

    write_audit(socket, flag, String.to_existing_atom(state_to_action(state)), %{})
    {:noreply, load(socket)}
  end

  def handle_event("set_percentage", %{"percentage" => pct_str}, socket) do
    flag = socket.assigns.flag
    pct = String.to_integer(pct_str)

    case pct do
      0 ->
        Flags.disable(flag, for_percentage_of: {:actors, 0.0})
        write_audit(socket, flag, :clear_percentage, %{})

      n when n in 1..100 ->
        Flags.enable(flag, for_percentage_of: {:actors, n / 100})
        write_audit(socket, flag, :set_percentage, %{"percentage" => n})
    end

    {:noreply, load(socket)}
  end

  def handle_event("clear_percentage", _, socket) do
    flag = socket.assigns.flag
    Flags.disable(flag, for_percentage_of: {:actors, 0.0})
    write_audit(socket, flag, :clear_percentage, %{})
    {:noreply, load(socket)}
  end

  def handle_event("add_actor", %{"username" => username, "state" => state}, socket) do
    flag = socket.assigns.flag

    case User |> Ash.Query.filter(username == ^username) |> Ash.read_one(authorize?: false) do
      {:ok, %User{} = user} ->
        case state do
          "on" -> Flags.enable(flag, for_actor: user)
          "off" -> Flags.disable(flag, for_actor: user)
        end

        write_audit(socket, flag, :add_actor, %{"username" => username, "state" => state})
        {:noreply, load(socket)}

      _ ->
        {:noreply, put_flash(socket, :error, "No user with that username.")}
    end
  end

  def handle_event("remove_actor", %{"target" => target}, socket) do
    flag = socket.assigns.flag

    case target do
      "user:" <> user_id ->
        case Ash.get(User, user_id, authorize?: false) do
          {:ok, user} ->
            FunWithFlags.disable(flag, for_actor: user)
            write_audit(socket, flag, :remove_actor, %{"target" => target})

          _ -> :ok
        end

      _ -> :ok
    end

    {:noreply, load(socket)}
  end

  def handle_event("toggle_group", %{"group" => group_str}, socket) do
    flag = socket.assigns.flag
    group = String.to_existing_atom(group_str)

    state =
      Enum.find_value(socket.assigns.gates, fn
        %FunWithFlags.Gate{type: :group, for: g, enabled: e} when g == group -> e
        _ -> nil
      end)

    case state do
      nil -> Flags.enable(flag, for_group: group)
      true -> Flags.disable(flag, for_group: group)
      false -> FunWithFlags.clear(flag, for_group: group)
    end

    write_audit(socket, flag, :add_group, %{"group" => group_str})
    {:noreply, load(socket)}
  end

  def handle_event("remove_group", %{"group" => group_str}, socket) do
    flag = socket.assigns.flag
    group = String.to_existing_atom(group_str)
    FunWithFlags.clear(flag, for_group: group)
    write_audit(socket, flag, :remove_group, %{"group" => group_str})
    {:noreply, load(socket)}
  end

  defp state_to_action("on"), do: "enable"
  defp state_to_action("off"), do: "disable"

  defp write_audit(socket, flag, action, params) do
    actor = socket.assigns.current_user

    Audit
    |> Ash.Changeset.for_create(:create, %{
      actor_user_id: actor && actor.id,
      flag_name: Atom.to_string(flag),
      action: action,
      params: params,
      occurred_at: DateTime.utc_now()
    })
    |> Ash.create(authorize?: false)
  rescue
    _ -> :ok
  end

  @doc "Render-time helper: percentage gate value as integer percent or nil."
  def percentage_value(gates) do
    Enum.find_value(gates, fn
      %FunWithFlags.Gate{type: :percentage_of_actors, for: p} -> trunc(p * 100)
      _ -> nil
    end)
  end

  @doc "Render-time helper: list of actor gates as {target, enabled}."
  def actor_gates(gates) do
    Enum.flat_map(gates, fn
      %FunWithFlags.Gate{type: :actor, for: t, enabled: e} -> [{t, e}]
      _ -> []
    end)
  end

  @doc "Render-time helper: enabled-state for a role group (true/false/nil)."
  def role_group_state(gates, group) do
    Enum.find_value(gates, fn
      %FunWithFlags.Gate{type: :group, for: g, enabled: e} when g == group -> e
      _ -> nil
    end)
  end
end
```

`FunWithFlags.clear/2` removes a specific gate. If the installed version uses a different function name, adapt — the contract under test is "the gate row goes away."

Create `lib/verscienta_web/live/admin_flag_show_live.html.heex`:
```heex
<div class="mx-auto max-w-3xl p-4 space-y-6">
  <p class="text-xs text-ink-3"><.link navigate={~p"/admin/flags"} class="underline">← all flags</.link></p>
  <h1 class="text-2xl font-mono text-ink"><%= @flag_name %></h1>

  <section class="space-y-2">
    <h2 class="text-sm uppercase tracking-wide text-ink-3">Boolean (global)</h2>
    <div class="flex gap-2 text-xs">
      <button phx-click="set_boolean" phx-value-state="on" type="button" class="px-3 py-1 rounded bg-canvas-3">On</button>
      <button phx-click="set_boolean" phx-value-state="off" type="button" class="px-3 py-1 rounded bg-canvas-3">Off</button>
    </div>
  </section>

  <section class="space-y-2">
    <h2 class="text-sm uppercase tracking-wide text-ink-3">Percentage rollout</h2>
    <form phx-submit="set_percentage" class="flex items-center gap-2 text-sm">
      <input type="range" name="percentage" min="0" max="100" step="5" value={percentage_value(@gates) || 0} class="flex-1" />
      <button type="submit" class="px-3 py-1 rounded bg-canvas-3 text-xs">Apply</button>
      <button type="button" phx-click="clear_percentage" class="px-2 py-1 text-xs underline">Clear</button>
    </form>
  </section>

  <section class="space-y-2">
    <h2 class="text-sm uppercase tracking-wide text-ink-3">Per-user actors</h2>
    <ul class="space-y-1">
      <%= for {target, enabled} <- actor_gates(@gates) do %>
        <li class="flex justify-between text-xs">
          <span class="font-mono"><%= target %></span>
          <span class="flex gap-2">
            <span class="text-ink-3"><%= if enabled, do: "on", else: "off" %></span>
            <button type="button" phx-click="remove_actor" phx-value-target={target} class="underline">remove</button>
          </span>
        </li>
      <% end %>
    </ul>
    <form phx-submit="add_actor" class="flex gap-2 text-xs items-center">
      <input type="text" name="username" placeholder="username" class="bg-canvas-3 px-2 py-1 rounded flex-1" />
      <select name="state" class="bg-canvas-3 px-2 py-1 rounded">
        <option value="on">on</option>
        <option value="off">off</option>
      </select>
      <button type="submit" class="px-3 py-1 rounded bg-canvas-3">Add</button>
    </form>
  </section>

  <section class="space-y-2">
    <h2 class="text-sm uppercase tracking-wide text-ink-3">Role groups</h2>
    <div class="flex gap-2 text-xs">
      <%= for g <- @role_groups do %>
        <button type="button" phx-click="toggle_group" phx-value-group={g} class="px-3 py-1 rounded bg-canvas-3">
          <%= g %>: <%= case role_group_state(@gates, g) do
                          nil -> "unset"
                          true -> "on"
                          false -> "off"
                        end %>
        </button>
      <% end %>
    </div>
  </section>

  <details class="text-xs">
    <summary class="text-ink-3 cursor-pointer">recent changes (<%= length(@audit_rows) %>)</summary>
    <ul class="mt-2 space-y-1">
      <%= for r <- @audit_rows do %>
        <li class="font-mono text-ink-3">
          <%= Calendar.strftime(r.occurred_at, "%Y-%m-%d %H:%M") %> · <%= r.action %> · <%= inspect(r.params) %>
        </li>
      <% end %>
    </ul>
  </details>
</div>
```

- [ ] **Step 3: Add route**

In `lib/verscienta_web/router.ex`, in the same admin scope:
```elixir
      live "/flags/:name", AdminFlagShowLive, :show
```

- [ ] **Step 4: Run tests**

```bash
docker compose exec -e MIX_ENV=test app mix test test/verscienta_web/live/admin_flag_show_live_test.exs
```
Expected: 3 tests, 0 failures.

- [ ] **Step 5: Verify and commit**

```bash
docker compose exec app mix format
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix credo --strict
```

```bash
git add lib/verscienta_web/live/admin_flag_show_live.ex \
  lib/verscienta_web/live/admin_flag_show_live.html.heex \
  lib/verscienta_web/router.ex \
  test/verscienta_web/live/admin_flag_show_live_test.exs
git commit -m "$(cat <<'EOF'
feat(flags): AdminFlagShowLive drill-down editor with audit log

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Retroactive route gates

**Files:**
- Modify: `lib/verscienta_web/router.ex` (attach `:gate` plug to 7 routes)
- Test: `test/verscienta_web/route_gates_test.exs` (new)

- [ ] **Step 1: Failing tests for route gating**

Create `test/verscienta_web/route_gates_test.exs`:
```elixir
defmodule VerscientaWeb.RouteGatesTest do
  use VerscientaWeb.ConnCase, async: false

  alias Verscienta.Accounts.User
  alias Verscienta.Flags

  setup do
    FunWithFlags.Store.Cache.flush()
    Verscienta.Flags.Seeds.seed!()
    on_exit(fn -> FunWithFlags.Store.Cache.flush() end)
    :ok
  end

  defp register(name) do
    User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com",
      username: name,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp sign_in(conn, u) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(u)
  end

  @gated_routes [
    {"/store", :reward_store},
    {"/quests", :quests},
    {"/leaderboard", :leaderboards},
    {"/groups", :communities}
  ]

  for {path, flag} <- @gated_routes do
    @path path
    @flag flag

    test "GET #{@path} renders Coming Soon when :#{@flag} is off", %{conn: conn} do
      u = register("u_#{System.unique_integer([:positive])}")
      Flags.disable(@flag)

      conn = sign_in(conn, u) |> get(@path)
      assert html_response(conn, 200) =~ "Coming soon"
    end
  end
end
```

- [ ] **Step 2: Attach `:gate` plug at each gated route**

In `lib/verscienta_web/router.ex`, add `plug VerscientaWeb.Plugs.Gate` declarations per route. The cleanest pattern is a small live_session that pipes through the gate plug.

Actually — `live` routes don't accept inline plugs. The mechanism is one of:
- A new pipeline (`:gate_reward_store`) per flag — verbose.
- An `on_mount` hook reading the conn's assigns — but the conn is plug-level, not LV-level.
- A scope with a `pipe_through` referencing a pipeline that has the flag attached.

The simplest pragmatic approach: define small pipelines per flag, group routes by flag in scopes. Add all five pipelines at the top of `router.ex` (near the existing `:browser` and `:admin` pipelines):
```elixir
  pipeline :gate_reward_store do
    plug VerscientaWeb.Plugs.Gate, flag: :reward_store
  end

  pipeline :gate_referrals do
    plug VerscientaWeb.Plugs.Gate, flag: :referrals
  end

  pipeline :gate_quests do
    plug VerscientaWeb.Plugs.Gate, flag: :quests
  end

  pipeline :gate_leaderboards do
    plug VerscientaWeb.Plugs.Gate, flag: :leaderboards
  end

  pipeline :gate_communities do
    plug VerscientaWeb.Plugs.Gate, flag: :communities
  end
```

Then nest scopes under the admin-authenticated session:
```elixir
  scope "/", VerscientaWeb do
    pipe_through :browser

    ash_authentication_live_session :authenticated_routes do
      live "/settings", SettingsLive, :edit
      # ...other always-on routes...
    end
  end

  scope "/", VerscientaWeb do
    pipe_through [:browser, :gate_reward_store]

    ash_authentication_live_session :gated_reward_store_routes do
      live "/store", StoreLive, :index
      live "/store/history", StoreHistoryLive, :index
    end
  end

  scope "/", VerscientaWeb do
    pipe_through [:browser, :gate_quests]

    ash_authentication_live_session :gated_quests_routes do
      live "/quests", QuestsLive, :index
    end
  end

  scope "/", VerscientaWeb do
    pipe_through [:browser, :gate_leaderboards]

    live_session :gated_leaderboard_routes, on_mount: [
      {VerscientaWeb.LiveUserAuth, :current_user},
      {VerscientaWeb.LiveUserAuth, :live_user_optional}
    ] do
      live "/leaderboard", LeaderboardLive, :index
    end
  end

  scope "/", VerscientaWeb do
    pipe_through [:browser, :gate_communities]

    live_session :gated_community_public_routes, on_mount: [
      {VerscientaWeb.LiveUserAuth, :current_user},
      {VerscientaWeb.LiveUserAuth, :live_user_optional}
    ] do
      live "/groups", GroupsLive, :index
      live "/groups/:slug", GroupLive, :show
    end

    ash_authentication_live_session :gated_community_auth_routes do
      live "/groups/new", GroupsLive, :new
      live "/groups/:slug/manage", GroupLive, :manage
      live "/groups/:slug/settings", GroupLive, :settings
    end
  end

  scope "/", VerscientaWeb do
    pipe_through [:browser, :gate_referrals]

    ash_authentication_live_session :gated_referral_routes do
      live "/settings/referrals", SettingsReferralsLive, :index
    end

    get "/r/:code", ReferralRedirectController, :redirect_with_code
  end
```

This requires restructuring the existing router. Inspect the current shape:
```bash
docker compose exec app cat lib/verscienta_web/router.ex
```
Then move each gated route into the appropriate gated scope. Routes that should NOT be gated (e.g. `/`, `/articles`, `/settings`) stay in the existing ungated scopes.

The reposts gate is button-visibility only (no dedicated route), so no router change needed for it.

- [ ] **Step 3: Run route gate tests**

```bash
docker compose exec -e MIX_ENV=test app mix test test/verscienta_web/route_gates_test.exs
```
Expected: 4 tests, 0 failures.

- [ ] **Step 4: Run full suite**

```bash
docker compose exec -e MIX_ENV=test app mix test
```
Expected: ALL tests pass. If existing tests fail because they were hitting `/store`, `/quests`, etc., and now hit the gate plug, the issue is that the seed in `test_helper.exs` should have those flags ON — verify:
```bash
docker compose exec -e MIX_ENV=test app mix run -e "Verscienta.Flags.Seeds.seed!(); IO.inspect(Verscienta.Flags.enabled?(:reward_store))"
```
Expected: `true`. If false, the seeds aren't running.

- [ ] **Step 5: Verify and commit**

```bash
docker compose exec app mix format
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix credo --strict
```

```bash
git add lib/verscienta_web/router.ex test/verscienta_web/route_gates_test.exs
git commit -m "$(cat <<'EOF'
feat(flags): gate /store, /quests, /leaderboard, /groups, /settings/referrals routes

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Retroactive worker + ingest gates

**Files:**
- Modify: `lib/verscienta/gamification/workers/quest_assigner_worker.ex` (gate on `:quests`)
- Modify: `lib/verscienta/gamification/workers/freeze_refill_worker.ex` (gate on `:quests`)
- Modify: `lib/verscienta/gamification/workers/leaderboard_snapshot_worker.ex` (gate on `:leaderboards`)
- Modify: `lib/verscienta/ai/workers/enrich_article_worker.ex` (gate on `:ai_enrichment`)
- Modify: `lib/verscienta/content/article/changes/enqueue_enrich.ex` (gate on `:ai_enrichment`)
- Modify: `lib/verscienta_web/controllers/auth_controller.ex` (gate referral capture on `:referrals`)
- Test: `test/verscienta/flags/worker_gates_test.exs`

- [ ] **Step 1: Failing test for the QuestAssignerWorker gate**

Create `test/verscienta/flags/worker_gates_test.exs`:
```elixir
defmodule Verscienta.Flags.WorkerGatesTest do
  use Verscienta.DataCase, async: false

  require Ash.Query

  alias Verscienta.Accounts.User
  alias Verscienta.Flags
  alias Verscienta.Gamification.Quest
  alias Verscienta.Gamification.QuestAssignment
  alias Verscienta.Gamification.Workers.QuestAssignerWorker

  setup do
    FunWithFlags.Store.Cache.flush()
    Verscienta.Flags.Seeds.seed!()
    on_exit(fn -> FunWithFlags.Store.Cache.flush() end)
    :ok
  end

  defp register(name) do
    User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com",
      username: name,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  test "QuestAssignerWorker no-ops when :quests is off" do
    Flags.disable(:quests)
    u = register("alice")

    # Seed at least one active daily quest
    Quest
    |> Ash.Changeset.for_create(:upsert, %{
      key: :daily_reader,
      name: "Daily Reader",
      cadence: :daily,
      goal_kind: :reading,
      goal_count: 3,
      points_reward: 30,
      active?: true
    })
    |> Ash.create!(authorize?: false)

    {:ok, _} = Oban.Testing.perform_job(QuestAssignerWorker, %{})

    n =
      QuestAssignment
      |> Ash.Query.filter(user_id == ^u.id)
      |> Ash.read!(authorize?: false)
      |> length()

    assert n == 0
  end

  test "QuestAssignerWorker runs when :quests is on" do
    Flags.enable(:quests)
    u = register("alice")

    Quest
    |> Ash.Changeset.for_create(:upsert, %{
      key: :daily_reader,
      name: "Daily Reader",
      cadence: :daily,
      goal_kind: :reading,
      goal_count: 3,
      points_reward: 30,
      active?: true
    })
    |> Ash.create!(authorize?: false)

    {:ok, _} = Oban.Testing.perform_job(QuestAssignerWorker, %{})

    n =
      QuestAssignment
      |> Ash.Query.filter(user_id == ^u.id)
      |> Ash.read!(authorize?: false)
      |> length()

    assert n >= 1
  end
end
```

- [ ] **Step 2: Add the gate to QuestAssignerWorker**

In `lib/verscienta/gamification/workers/quest_assigner_worker.ex`, wrap the existing `perform/1` body:
```elixir
  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    if Verscienta.Flags.enabled?(:quests) do
      do_perform(job)
    else
      :ok
    end
  end

  defp do_perform(%Oban.Job{}) do
    # ...existing body, lifted verbatim...
  end
```

The existing `perform/1` body needs to be moved into `do_perform/1`. Keep the rest of the file unchanged.

- [ ] **Step 3: Add the gate to FreezeRefillWorker**

In `lib/verscienta/gamification/workers/freeze_refill_worker.ex`, wrap `perform/1`:
```elixir
  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    if Verscienta.Flags.enabled?(:quests) do
      do_perform(job)
    else
      :ok
    end
  end

  defp do_perform(%Oban.Job{}) do
    # ...existing body, lifted verbatim...
  end
```

- [ ] **Step 4: Add the gate to LeaderboardSnapshotWorker**

In `lib/verscienta/gamification/workers/leaderboard_snapshot_worker.ex`, wrap `perform/1`:
```elixir
  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    if Verscienta.Flags.enabled?(:leaderboards) do
      do_perform(job)
    else
      :ok
    end
  end

  defp do_perform(%Oban.Job{args: args}) do
    # ...existing body, lifted verbatim...
  end
```

- [ ] **Step 5: Add the gate to EnrichArticleWorker**

In `lib/verscienta/ai/workers/enrich_article_worker.ex`, wrap `perform/1`:
```elixir
  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    if Verscienta.Flags.enabled?(:ai_enrichment) do
      do_perform(job)
    else
      :ok
    end
  end

  defp do_perform(%Oban.Job{args: args}) do
    # ...existing body, lifted verbatim...
  end
```

- [ ] **Step 6: Add the gate to the enqueue hook**

In `lib/verscienta/content/article/changes/enqueue_enrich.ex`, find the `change/3` callback (or wherever the Oban enqueue happens) and wrap the enqueue:
```elixir
if Verscienta.Flags.enabled?(:ai_enrichment) do
  # existing Oban.insert call
end
```

- [ ] **Step 7: Add the gate to referral capture in auth_controller**

In `lib/verscienta_web/controllers/auth_controller.ex`, find the `success/4` callback or wherever `Verscienta.Gamification.Referrals.capture/4` is called. Wrap:
```elixir
if Verscienta.Flags.enabled?(:referrals) do
  # existing Referrals.capture call + cookie cleanup
end
```

- [ ] **Step 8: Run the worker gate tests**

```bash
docker compose exec -e MIX_ENV=test app mix test test/verscienta/flags/worker_gates_test.exs
```
Expected: 2 tests, 0 failures.

- [ ] **Step 9: Run full suite for regressions**

```bash
docker compose exec -e MIX_ENV=test app mix test
```
Expected: full suite green. If existing worker tests fail because they expected the worker to do work, the seeds in `test_helper.exs` should keep these flags ON by default — verify.

- [ ] **Step 10: Verify and commit**

```bash
docker compose exec app mix format
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix credo --strict
```

```bash
git add lib/verscienta/gamification/workers/quest_assigner_worker.ex \
  lib/verscienta/gamification/workers/freeze_refill_worker.ex \
  lib/verscienta/gamification/workers/leaderboard_snapshot_worker.ex \
  lib/verscienta/ai/workers/enrich_article_worker.ex \
  lib/verscienta/content/article/changes/enqueue_enrich.ex \
  lib/verscienta_web/controllers/auth_controller.ex \
  test/verscienta/flags/worker_gates_test.exs
git commit -m "$(cat <<'EOF'
feat(flags): gate workers + ingest hooks (:quests, :leaderboards, :ai_enrichment, :referrals)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Final verification + todo + merge prep

**Files:**
- Modify: `docs/todo.md`

- [ ] **Step 1: Full reset + full test suite**

```bash
docker compose exec -e MIX_ENV=test app sh -c "mix ecto.drop -r Verscienta.Repo && mix ecto.create -r Verscienta.Repo && mix ash.migrate && mix test"
```
Expected: 0 failures.

- [ ] **Step 2: Smoke-run seeds in dev**

```bash
docker compose exec app mix verscienta.flags.seed
```
Expected: prints "Feature flags seeded." and exits cleanly. Re-run: same output, no errors (idempotent).

- [ ] **Step 3: Full CI gates**

```bash
docker compose exec app mix format --check-formatted
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix credo --strict
docker compose exec app mix dialyzer
```
Expected: all clean.

- [ ] **Step 4: Update `docs/todo.md`**

In the `### Phase 2 Cross-cutting` block, change:
```markdown
- [ ] FunWithFlags feature flags for rolling out social features.
```
to:
```markdown
- [x] FunWithFlags feature flags for rolling out social features.
```

- [ ] **Step 5: Commit todo update**

```bash
git add docs/todo.md
git commit -m "$(cat <<'EOF'
docs: mark feature flags subsystem complete

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 6: Open merge to main**

```bash
git push -u origin phase-2-feature-flags
gh pr create --base main --head phase-2-feature-flags \
  --title "Feature flags subsystem" \
  --body "$(cat <<'EOF'
Installs FunWithFlags (Postgres + ETS), wraps it behind `Verscienta.Flags` with a hard-coded allowlist of 13 flags, ships a custom Codex admin LiveView, and retroactively gates 7 existing features with kill-switch insurance.

## What's in

- `Verscienta.Flags` chokepoint module (raises on unknown flags).
- `FunWithFlags.Actor` impl for `User` (id `"user:<uuid>"`); `FunWithFlags.Group` impl supporting role groups (`:admins`, `:experts`, `:moderators`) and per-community membership (`:group_member_<group_id>`).
- `VerscientaWeb.Plugs.Gate` — per-route gate that renders `ComingSoonLive` for non-admins, passes admins through with an "Admin preview" banner.
- `AdminFlagsLive` index + `AdminFlagShowLive` drill-down at `/admin/flags` and `/admin/flags/:name` — full editor for boolean / actor / group / percentage dimensions.
- `Verscienta.Flags.Audit` Ash resource — every mutation logged with actor, flag, action, params, occurred_at.
- `mix verscienta.flags.seed` — idempotent seeds for the 13 flags. Auto-seeded in `test_helper.exs` so existing tests are unaffected.
- Retroactive gates on `/store`, `/store/history`, `/quests`, `/leaderboard`, `/groups[...]`, `/settings/referrals`, `/r/:code`, and on the QuestAssigner / FreezeRefill / LeaderboardSnapshot / EnrichArticle workers + the ingest enqueue hook + the auth-controller referral capture.

Spec: `docs/superpowers/specs/2026-06-04-feature-flags-design.md`
Plan: `docs/superpowers/plans/2026-06-04-feature-flags.md`
EOF
)"
```

- [ ] **Step 7: After review, merge with `--no-ff`**

(Project convention — see `[[verscienta-project-conventions]]`.)

```bash
git checkout main && git pull --ff-only
git merge --no-ff phase-2-feature-flags -m "Merge feature flags subsystem into main"
git push origin main
```

---

## Spec coverage map

| Spec section | Implementing tasks |
|--------------|--------------------|
| §1 File structure overview | All tasks |
| §2 `Verscienta.Flags` + Actor + Group impls | Task 2 |
| §3 Gate plug + Coming Soon LV | Task 3 |
| §4 Admin LVs + Audit resource | Tasks 4, 7, 8 |
| §5 Seeds, retroactive integration, testing | Tasks 5, 6, 9, 10 |
| Out of scope | Documented; no tasks |
| Definition of Done | Task 11 |
