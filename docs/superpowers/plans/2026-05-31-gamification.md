# Gamification (Basic) Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reward engagement with Vitality Points (append-only ledger + cached total), derive levels, grant milestone badges — driven by domain events through Oban — and show points/level/badges on the profile.

**Architecture:** A new `Verscienta.Gamification` domain with `PointsEntry` (idempotent ledger), `Badge`, `UserBadge`; a single `Gamification.award/3` engine (insert entry → bump cached `User.points` → re-evaluate badges → broadcast); an `AwardWorker` Oban job enqueued (best-effort) from after-action hooks on publish/comment/reaction-received and a 30s reading heartbeat; profile displays points/level/badges.

**Tech Stack:** Phoenix 1.8, Ash 3, AshPostgres, Oban, Phoenix.PubSub, LiveView + a small JS hook, Tailwind v4 + Codex components.

---

## Conventions for the executor

- **Run everything in Docker.** Mix in the app service: `docker compose run --rm -T app bash -lc "<cmd>"`. Start DB: `docker compose up -d db`. Generous timeouts. If "dependency not available", prefix `mix deps.get &&`. OOM(137) → split.
- **One task at a time, sequentially.** After each task run `git rev-parse --short HEAD` for the REAL sha. NEVER batch tasks or reference unverified SHAs. **Re-run the FULL gate (`mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `MIX_ENV=test mix test`) after your FINAL edit, BEFORE committing** — do not trust a partial/stale run. Watch for duplicate function clauses / unused vars (they fail --warnings-as-errors).
- **Branch:** `phase-1-gamification` (already checked out; spec committed `bdf1d8d`).
- **Line endings:** `.gitattributes` eol=lf, autocrlf false — don't change. `mix format` before commit. No `.bak` files. No stray debug files in commits.
- **Test DB:** `config/test.exs` pins `verscienta_test`; Oban `testing: :manual` (jobs are enqueued but NOT executed automatically — use `Oban.Testing` `assert_enqueued`/`perform_job`). Seeds contaminate global counts — scope new count asserts to your own user/article.
- **Git identity:** no local override. Commit body ends with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- **Migrations:** Ash resources via `mix ash.codegen <name>` then `mix ash.migrate`.
- **Reuse patterns:**
  - Resource + policy shape: `lib/verscienta/content/source.ex`, `lib/verscienta/engagement/reaction.ex`.
  - Generic action `run fn input, context -> ... end`: `lib/verscienta/engagement/reaction.ex` `:toggle` (gets actor via `context.actor`, args via `input.arguments`).
  - Best-effort after-action enqueue: `lib/verscienta/content/article/changes/enqueue_index.ex` (rescue + `Logger.warning`, always `{:ok, record}`).
  - Oban worker: `lib/verscienta/aggregation/workers/fetch_source_worker.ex` (uses `Oban.Worker`, `unique:`).
  - Article `:publish` has changes you append to (after `EnqueueIndex`); it's `require_atomic? false`.
  - Reaction `:toggle` is a generic action with an inline run-fn — enqueue the reaction-received award INSIDE its create branch (it is NOT after-action-able).
  - Profile `lib/verscienta_web/live/profile_live.ex` loads the user directly via `Ash.read_one!` — add a `.load` there.
  - JS hooks: `assets/js/app.js` has `const Hooks = {}` and `hooks: {...colocatedHooks, ...Hooks}` — add `Hooks.ReadingTimer`.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `lib/verscienta/gamification.ex` | domain + `award/3`, `subscribe/1`, `broadcast/2` |
| `lib/verscienta/gamification/points.ex` | `value/1` point values + `level_for/1` |
| `lib/verscienta/gamification/points_entry.ex` | ledger resource (idempotent) |
| `lib/verscienta/gamification/badge.ex` | badge catalog resource |
| `lib/verscienta/gamification/user_badge.ex` | awarded-badge join |
| `lib/verscienta/gamification/workers/award_worker.ex` | Oban worker → `award/3` |
| `lib/verscienta/accounts/user.ex` | add `points` attr + `add_points` action + relationships |
| `lib/verscienta/content/article/changes/award_publish.ex` | enqueue publish award |
| `lib/verscienta/engagement/comment/changes/award_comment.ex` | enqueue comment award |
| `lib/verscienta/engagement/reaction.ex` | enqueue reaction-received award (in toggle create branch) |
| `lib/verscienta_web/live/article_reader_live.ex` | `reading_complete` handler + ReadingTimer hook attach |
| `assets/js/app.js` | `ReadingTimer` hook |
| `lib/verscienta_web/live/profile_live.ex` | show points/level/badges |
| `config/config.exs` | register `Verscienta.Gamification` |
| `priv/repo/seeds.exs` | badge catalog seeds |
| `test/verscienta/gamification/*_test.exs`, reader/profile test additions | tests |

---

## Task 1: Points config module (TDD)

**Files:**
- Create: `lib/verscienta/gamification/points.ex`
- Test: `test/verscienta/gamification/points_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/gamification/points_test.exs`:
```elixir
defmodule Verscienta.Gamification.PointsTest do
  use ExUnit.Case, async: true

  alias Verscienta.Gamification.Points

  test "value/1 returns per-source point values" do
    assert Points.value(:article_published) == 50
    assert Points.value(:comment_posted) == 5
    assert Points.value(:reaction_received) == 2
    assert Points.value(:reading) == 10
  end

  test "level_for/1: 0 points is level 1" do
    assert Points.level_for(0) == 1
  end

  test "level_for/1 increases with points and never below 1" do
    assert Points.level_for(50) == 2
    assert Points.level_for(200) == 3
    assert Points.level_for(450) == 4
    assert Points.level_for(-5) == 1
  end

  test "sources/0 lists the known point sources" do
    for s <- [:article_published, :comment_posted, :reaction_received, :reading] do
      assert s in Points.sources()
    end
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/gamification/points_test.exs"
```
Expected: fails — module missing.

- [ ] **Step 3: Implement**

Create `lib/verscienta/gamification/points.ex`:
```elixir
defmodule Verscienta.Gamification.Points do
  @moduledoc "Point values per source and the level-from-points formula."

  @values %{
    article_published: 50,
    comment_posted: 5,
    reaction_received: 2,
    reading: 10
  }

  @doc "Point value awarded for a given source."
  def value(source), do: Map.fetch!(@values, source)

  @doc "The known point sources."
  def sources, do: Map.keys(@values)

  @doc """
  Level derived from total points. Level 1 at 0 points; each level needs
  quadratically more points: level = floor(sqrt(points / 50)) + 1.
  Thresholds: L2 @ 50, L3 @ 200, L4 @ 450, L5 @ 800, ...
  """
  def level_for(points) when is_integer(points) do
    p = max(points, 0)
    trunc(:math.sqrt(p / 50)) + 1
  end
end
```

- [ ] **Step 4: Run to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/gamification/points_test.exs"
```
Expected: 4 tests, 0 failures. (Check the level boundaries: sqrt(50/50)=1→L2; sqrt(200/50)=2→L3; sqrt(450/50)=3→L4. They match.)

- [ ] **Step 5: Format + gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors"
git add -A
git commit -m "feat(gamification): Points value + level_for config module"
```
Then `git rev-parse --short HEAD`.

---

## Task 2: User points column + add_points action (TDD)

**Files:**
- Modify: `lib/verscienta/accounts/user.ex`
- Test: `test/verscienta/gamification/user_points_test.exs`
- Migration via codegen

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/gamification/user_points_test.exs`:
```elixir
defmodule Verscienta.Gamification.UserPointsTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Accounts.User

  defp user(name) do
    User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com",
      username: name,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  test "new user starts at 0 points" do
    assert user("alice").points == 0
  end

  test "add_points increments the cached total" do
    u = user("alice")
    {:ok, u} = u |> Ash.Changeset.for_update(:add_points, %{amount: 50}) |> Ash.update(authorize?: false)
    assert u.points == 50
    {:ok, u} = u |> Ash.Changeset.for_update(:add_points, %{amount: 5}) |> Ash.update(authorize?: false)
    assert u.points == 55
  end

  test "points cannot be set through update_profile" do
    u = user("alice")

    {:ok, updated} =
      u
      |> Ash.Changeset.for_update(:update_profile, %{display_name: "Alice", points: 9999}, actor: u)
      |> Ash.update()

    assert updated.points == 0
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta/gamification/user_points_test.exs"
```
Expected: fails — `points` attr + `add_points` action missing.

- [ ] **Step 3: Add the attribute, action, and relationships**

In `lib/verscienta/accounts/user.ex`:
- In the `attributes do` block (near other attributes like `role`), add:
```elixir
    attribute :points, :integer, allow_nil?: false, default: 0, public?: true
```
- In the `actions do` block, add an `add_points` update action (atomic increment):
```elixir
    update :add_points do
      description "System action: increment a user's cached points total."
      accept []
      argument :amount, :integer, allow_nil?: false
      require_atomic? false

      change fn changeset, _ ->
        amount = Ash.Changeset.get_argument(changeset, :amount)
        current = changeset.data.points || 0
        Ash.Changeset.force_change_attribute(changeset, :points, current + amount)
      end
    end
```
- In the `relationships do` block, add:
```elixir
    has_many :points_entries, Verscienta.Gamification.PointsEntry
    has_many :user_badges, Verscienta.Gamification.UserBadge
```
NOTE: those two resources are created in Tasks 3 & 5; the `has_many` references will not resolve until then. If `mix compile` in this task fails because the referenced modules don't exist yet, TEMPORARILY omit the two `has_many` lines and add them in Task 5 (after both resources exist). Prefer: add `points` + `add_points` now (Task 2), add the two `has_many` lines in Task 5. Adjust this step to add ONLY `points` + `add_points` here; note it.
- Confirm `update_profile`'s `accept` list does NOT include `:points` (it accepts only username/display_name/bio/avatar_url) — so the "cannot be set through update_profile" test passes. Do not add `:points` to it.

- [ ] **Step 4: Generate + apply migration**

```powershell
docker compose run --rm -T app bash -lc "mix ash.codegen add_user_points && mix ash.migrate"
```
Expected: migration adding `users.points` integer default 0.

- [ ] **Step 5: Run tests + gate + commit**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/gamification/user_points_test.exs && mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors"
git add -A
git commit -m "feat(gamification): User.points column + system add_points action"
```
Then `git rev-parse --short HEAD`.

---

## Task 3: Gamification domain + PointsEntry ledger (TDD)

**Files:**
- Create: `lib/verscienta/gamification.ex`, `lib/verscienta/gamification/points_entry.ex`
- Modify: `config/config.exs`
- Test: `test/verscienta/gamification/points_entry_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/gamification/points_entry_test.exs`:
```elixir
defmodule Verscienta.Gamification.PointsEntryTest do
  use Verscienta.DataCase, async: true

  require Ash.Query

  alias Verscienta.Gamification.PointsEntry

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

  test "create a points entry" do
    u = user("alice")

    {:ok, entry} =
      PointsEntry
      |> Ash.Changeset.for_create(:create, %{user_id: u.id, amount: 50, source: :article_published, source_ref: "article:1"})
      |> Ash.create(authorize?: false)

    assert entry.amount == 50
    assert entry.source == :article_published
  end

  test "duplicate (user, source, source_ref) is rejected by the unique identity" do
    u = user("alice")
    attrs = %{user_id: u.id, amount: 50, source: :article_published, source_ref: "article:1"}

    {:ok, _} = PointsEntry |> Ash.Changeset.for_create(:create, attrs) |> Ash.create(authorize?: false)
    {:error, _} = PointsEntry |> Ash.Changeset.for_create(:create, attrs) |> Ash.create(authorize?: false)
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta/gamification/points_entry_test.exs"
```
Expected: fails — domain/resource missing.

- [ ] **Step 3: Create the domain**

Create `lib/verscienta/gamification.ex`:
```elixir
defmodule Verscienta.Gamification do
  @moduledoc "Domain for vitality points, levels, and badges."
  use Ash.Domain, otp_app: :verscienta

  resources do
    resource Verscienta.Gamification.PointsEntry
  end

  @doc "PubSub topic for a user's gamification events."
  def topic(user_id), do: "user:" <> to_string(user_id)

  def subscribe(user_id), do: Phoenix.PubSub.subscribe(Verscienta.PubSub, topic(user_id))

  def broadcast(user_id, message),
    do: Phoenix.PubSub.broadcast(Verscienta.PubSub, topic(user_id), message)
end
```
(Badge/UserBadge resources are added to `resources do` in Task 5; `award/3` is added in Task 4.)

- [ ] **Step 4: Create the PointsEntry resource**

Create `lib/verscienta/gamification/points_entry.ex`:
```elixir
defmodule Verscienta.Gamification.PointsEntry do
  @moduledoc "Append-only ledger of awarded vitality points."
  use Ash.Resource,
    otp_app: :verscienta,
    domain: Verscienta.Gamification,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "points_entries"
    repo Verscienta.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [:user_id, :amount, :source, :source_ref]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :amount, :integer, allow_nil?: false, public?: true

    attribute :source, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:article_published, :comment_posted, :reaction_received, :reading]
    end

    attribute :source_ref, :string, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :user, Verscienta.Accounts.User, allow_nil?: false
  end

  identities do
    identity :unique_source_ref, [:user_id, :source, :source_ref]
  end
end
```
NOTE: no `Ash.Policy.Authorizer` here — PointsEntry is written only in system context (`authorize?: false`) by the award engine; it has no actor-facing actions. (If the app globally requires authorizers, add `authorizers: [Ash.Policy.Authorizer]` + a `policy action_type([:read, :create]) do authorize_if always() end`; but the simpler no-authorizer form is fine since all calls pass `authorize?: false`.)

- [ ] **Step 5: Register the domain**

In `config/config.exs`, add `Verscienta.Gamification` to `ash_domains`:
```elixir
  ash_domains: [Verscienta.Accounts, Verscienta.Content, Verscienta.Engagement, Verscienta.Gamification]
```

- [ ] **Step 6: Generate + apply migration**

```powershell
docker compose run --rm -T app bash -lc "mix ash.codegen add_points_entries && mix ash.migrate"
```
Expected: `points_entries` table + unique index on `(user_id, source, source_ref)`.

- [ ] **Step 7: Run tests + gate + commit**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/gamification/points_entry_test.exs && mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors"
git add -A
git commit -m "feat(gamification): Gamification domain + PointsEntry ledger"
```
Then `git rev-parse --short HEAD`.

---

## Task 4: award/3 engine (points only, no badges yet) (TDD)

**Files:**
- Modify: `lib/verscienta/gamification.ex`
- Test: `test/verscienta/gamification/award_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/gamification/award_test.exs`:
```elixir
defmodule Verscienta.Gamification.AwardTest do
  use Verscienta.DataCase, async: true

  require Ash.Query

  alias Verscienta.Accounts.User
  alias Verscienta.Gamification
  alias Verscienta.Gamification.PointsEntry

  defp user(name) do
    User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com",
      username: name,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp reload(u), do: Ash.get!(User, u.id, authorize?: false)
  defp entry_count(u), do: PointsEntry |> Ash.Query.filter(user_id == ^u.id) |> Ash.read!(authorize?: false) |> length()

  test "award writes a ledger entry and bumps cached points" do
    u = user("alice")
    :ok = Gamification.award(u.id, :article_published, "article:1")

    assert reload(u).points == 50
    assert entry_count(u) == 1
  end

  test "award is idempotent on duplicate source_ref" do
    u = user("alice")
    :ok = Gamification.award(u.id, :comment_posted, "comment:1")
    :ok = Gamification.award(u.id, :comment_posted, "comment:1")

    assert reload(u).points == 5
    assert entry_count(u) == 1
  end

  test "distinct source_refs accumulate" do
    u = user("alice")
    :ok = Gamification.award(u.id, :comment_posted, "comment:1")
    :ok = Gamification.award(u.id, :comment_posted, "comment:2")

    assert reload(u).points == 10
    assert entry_count(u) == 2
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta/gamification/award_test.exs"
```
Expected: fails — `award/3` missing.

- [ ] **Step 3: Implement award/3 (points only)**

In `lib/verscienta/gamification.ex`, add `require Ash.Query` near the top and the `award/3` function (badges added in Task 6):
```elixir
  require Ash.Query

  alias Verscienta.Gamification.Points
  alias Verscienta.Gamification.PointsEntry

  @doc """
  Award points to a user for a source event, idempotent by source_ref.
  Inserts a ledger entry, bumps the cached total. Returns :ok.
  """
  def award(user_id, source, source_ref) do
    amount = Points.value(source)

    case insert_entry(user_id, source, source_ref, amount) do
      {:ok, _entry} ->
        bump_points(user_id, amount)
        broadcast(user_id, {:points_changed, user_id})
        :ok

      # Duplicate (already awarded) — no-op.
      {:error, _} ->
        :ok
    end
  end

  defp insert_entry(user_id, source, source_ref, amount) do
    PointsEntry
    |> Ash.Changeset.for_create(:create, %{
      user_id: user_id,
      amount: amount,
      source: source,
      source_ref: source_ref
    })
    |> Ash.create(authorize?: false)
  end

  defp bump_points(user_id, amount) do
    user = Ash.get!(Verscienta.Accounts.User, user_id, authorize?: false)

    user
    |> Ash.Changeset.for_update(:add_points, %{amount: amount})
    |> Ash.update!(authorize?: false)
  end
```
NOTE: the idempotency relies on the `unique_source_ref` identity raising on duplicate insert → caught as `{:error, _}` → no-op (no double bump). The `Points` alias is used here; ensure it's aliased.

- [ ] **Step 4: Run tests + gate + commit**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/gamification/award_test.exs && mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors"
git add -A
git commit -m "feat(gamification): award/3 engine — idempotent ledger + cached total"
```
Then `git rev-parse --short HEAD`.

---

## Task 5: Badge + UserBadge resources (TDD)

**Files:**
- Create: `lib/verscienta/gamification/badge.ex`, `lib/verscienta/gamification/user_badge.ex`
- Modify: `lib/verscienta/gamification.ex` (resource lines), `lib/verscienta/accounts/user.ex` (the two has_many from Task 2, if deferred)
- Test: `test/verscienta/gamification/badge_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/gamification/badge_test.exs`:
```elixir
defmodule Verscienta.Gamification.BadgeTest do
  use Verscienta.DataCase, async: true

  require Ash.Query

  alias Verscienta.Gamification.Badge
  alias Verscienta.Gamification.UserBadge

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

  defp badge(key, attrs) do
    Badge
    |> Ash.Changeset.for_create(:upsert, Map.merge(%{key: key, name: to_string(key), description: "d"}, attrs))
    |> Ash.create!(authorize?: false)
  end

  test "upsert by key is idempotent" do
    b1 = badge(:first_article, %{threshold_source: :article_published, threshold_value: 1})
    b2 = badge(:first_article, %{threshold_source: :article_published, threshold_value: 1, name: "First Article"})
    assert b1.id == b2.id
    assert Ash.get!(Badge, b1.id, authorize?: false).name == "First Article"
  end

  test "user_badge unique per (user, badge)" do
    u = user("alice")
    b = badge(:centurion, %{threshold_value: 100})

    {:ok, _} = UserBadge |> Ash.Changeset.for_create(:create, %{user_id: u.id, badge_id: b.id}) |> Ash.create(authorize?: false)
    {:error, _} = UserBadge |> Ash.Changeset.for_create(:create, %{user_id: u.id, badge_id: b.id}) |> Ash.create(authorize?: false)
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta/gamification/badge_test.exs"
```
Expected: fails — resources missing.

- [ ] **Step 3: Create Badge**

Create `lib/verscienta/gamification/badge.ex`:
```elixir
defmodule Verscienta.Gamification.Badge do
  @moduledoc "A milestone badge in the catalog."
  use Ash.Resource,
    otp_app: :verscienta,
    domain: Verscienta.Gamification,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "badges"
    repo Verscienta.Repo
  end

  actions do
    defaults [:read]

    create :upsert do
      description "Create or update a badge by key (used by seeds)."
      accept [:key, :name, :description, :threshold_source, :threshold_value]
      upsert? true
      upsert_identity :unique_key
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :key, :atom, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :description, :string, allow_nil?: true, public?: true

    # threshold_source nil => points-based (User.points >= threshold_value);
    # otherwise count of the user's PointsEntry with that source >= threshold_value.
    attribute :threshold_source, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:article_published, :comment_posted, :reaction_received, :reading]
    end

    attribute :threshold_value, :integer, allow_nil?: false, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :user_badges, Verscienta.Gamification.UserBadge
  end

  identities do
    identity :unique_key, [:key]
  end
end
```

- [ ] **Step 4: Create UserBadge**

Create `lib/verscienta/gamification/user_badge.ex`:
```elixir
defmodule Verscienta.Gamification.UserBadge do
  @moduledoc "A badge awarded to a user."
  use Ash.Resource,
    otp_app: :verscienta,
    domain: Verscienta.Gamification,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "user_badges"
    repo Verscienta.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [:user_id, :badge_id]
      change set_attribute(:awarded_at, &DateTime.utc_now/0)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :awarded_at, :utc_datetime_usec, allow_nil?: false
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :user, Verscienta.Accounts.User, allow_nil?: false
    belongs_to :badge, Verscienta.Gamification.Badge, allow_nil?: false
  end

  identities do
    identity :unique_user_badge, [:user_id, :badge_id]
  end
end
```
NOTE: `set_attribute(:awarded_at, &DateTime.utc_now/0)` function-form may be rejected by this Ash version; if so use `change fn cs, _ -> Ash.Changeset.force_change_attribute(cs, :awarded_at, DateTime.utc_now()) end`.

- [ ] **Step 5: Register resources + add User has_many (if deferred)**

In `lib/verscienta/gamification.ex` `resources do`, add:
```elixir
    resource Verscienta.Gamification.Badge
    resource Verscienta.Gamification.UserBadge
```
In `lib/verscienta/accounts/user.ex` `relationships do`, add (if not already added in Task 2):
```elixir
    has_many :points_entries, Verscienta.Gamification.PointsEntry
    has_many :user_badges, Verscienta.Gamification.UserBadge
```

- [ ] **Step 6: Generate + apply migration**

```powershell
docker compose run --rm -T app bash -lc "mix ash.codegen add_badges && mix ash.migrate"
```
Expected: `badges` (unique `key`) + `user_badges` (unique `(user_id, badge_id)`) tables.

- [ ] **Step 7: Run tests + gate + commit**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/gamification/badge_test.exs && mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors"
git add -A
git commit -m "feat(gamification): Badge catalog + UserBadge resources"
```
Then `git rev-parse --short HEAD`.

---

## Task 6: Badge evaluation in award/3 (TDD)

**Files:**
- Modify: `lib/verscienta/gamification.ex`
- Test: `test/verscienta/gamification/badge_award_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/gamification/badge_award_test.exs`:
```elixir
defmodule Verscienta.Gamification.BadgeAwardTest do
  use Verscienta.DataCase, async: true

  require Ash.Query

  alias Verscienta.Gamification
  alias Verscienta.Gamification.Badge
  alias Verscienta.Gamification.UserBadge

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

  defp badge(key, attrs) do
    Badge
    |> Ash.Changeset.for_create(:upsert, Map.merge(%{key: key, name: to_string(key), description: "d"}, attrs))
    |> Ash.create!(authorize?: false)
  end

  defp badges_for(u), do: UserBadge |> Ash.Query.filter(user_id == ^u.id) |> Ash.read!(authorize?: false)

  test "source-count badge granted on first qualifying entry" do
    badge(:first_comment, %{threshold_source: :comment_posted, threshold_value: 1})
    u = user("alice")

    :ok = Gamification.award(u.id, :comment_posted, "comment:1")
    assert length(badges_for(u)) == 1
  end

  test "points badge granted when total threshold crossed; once only" do
    badge(:centurion, %{threshold_source: nil, threshold_value: 100})
    u = user("alice")

    :ok = Gamification.award(u.id, :article_published, "article:1") # 50
    assert badges_for(u) == []
    :ok = Gamification.award(u.id, :article_published, "article:2") # 100
    assert length(badges_for(u)) == 1

    # further awards don't double-grant
    :ok = Gamification.award(u.id, :article_published, "article:3")
    assert length(badges_for(u)) == 1
  end

  test "does not grant a badge whose threshold isn't met" do
    badge(:wordsmith, %{threshold_source: :article_published, threshold_value: 5})
    u = user("alice")
    :ok = Gamification.award(u.id, :article_published, "article:1")
    assert badges_for(u) == []
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta/gamification/badge_award_test.exs"
```
Expected: fails — no badge evaluation in `award/3` yet.

- [ ] **Step 3: Add badge evaluation to award/3**

In `lib/verscienta/gamification.ex`, after `bump_points(user_id, amount)` in the success branch, call `evaluate_badges(user_id)`; and add the helper. Update `award/3`'s success branch to:
```elixir
      {:ok, _entry} ->
        bump_points(user_id, amount)
        evaluate_badges(user_id)
        broadcast(user_id, {:points_changed, user_id})
        :ok
```
Add helpers:
```elixir
  alias Verscienta.Gamification.Badge
  alias Verscienta.Gamification.UserBadge

  defp evaluate_badges(user_id) do
    user = Ash.get!(Verscienta.Accounts.User, user_id, authorize?: false)
    held = held_badge_ids(user_id)

    Badge
    |> Ash.read!(authorize?: false)
    |> Enum.reject(&(&1.id in held))
    |> Enum.filter(&qualifies?(user, user_id, &1))
    |> Enum.each(&grant_badge(user_id, &1.id))
  end

  defp held_badge_ids(user_id) do
    UserBadge
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read!(authorize?: false)
    |> MapSet.new(& &1.badge_id)
  end

  defp qualifies?(user, _user_id, %{threshold_source: nil, threshold_value: v}), do: user.points >= v

  defp qualifies?(_user, user_id, %{threshold_source: source, threshold_value: v}) do
    count =
      PointsEntry
      |> Ash.Query.filter(user_id == ^user_id and source == ^source)
      |> Ash.read!(authorize?: false)
      |> length()

    count >= v
  end

  defp grant_badge(user_id, badge_id) do
    UserBadge
    |> Ash.Changeset.for_create(:create, %{user_id: user_id, badge_id: badge_id})
    |> Ash.create(authorize?: false)
  end
```
NOTE: `grant_badge` may race/dupe under concurrency, but the `unique_user_badge` identity guards it (a duplicate insert errors harmlessly — `Ash.create` returns `{:error, _}` which we ignore). The `held` pre-check avoids it in the common path. `held_badge_ids/1` uses `MapSet`; `&1.id in held` works on a MapSet via `MapSet.member?`? — use `MapSet.member?(held, &1.id)` explicitly: change the reject to `Enum.reject(&MapSet.member?(held, &1.id))`.

- [ ] **Step 4: Run tests + gate + commit**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/gamification/badge_award_test.exs test/verscienta/gamification/award_test.exs && mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors"
git add -A
git commit -m "feat(gamification): badge evaluation in award/3"
```
Then `git rev-parse --short HEAD`.

---

## Task 7: AwardWorker + earning hooks (TDD)

**Files:**
- Create: `lib/verscienta/gamification/workers/award_worker.ex`
- Create: `lib/verscienta/content/article/changes/award_publish.ex`
- Create: `lib/verscienta/engagement/comment/changes/award_comment.ex`
- Modify: `lib/verscienta/content/article.ex` (attach AwardPublish to `:publish`)
- Modify: `lib/verscienta/engagement/comment.ex` (attach AwardComment to `:create`)
- Modify: `lib/verscienta/engagement/reaction.ex` (enqueue reaction-received in toggle create branch)
- Test: `test/verscienta/gamification/hooks_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/gamification/hooks_test.exs`:
```elixir
defmodule Verscienta.Gamification.HooksTest do
  use Verscienta.DataCase, async: false
  use Oban.Testing, repo: Verscienta.Repo

  alias Verscienta.Gamification.Workers.AwardWorker

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

  defp set_admin(u) do
    u
    |> Ash.Changeset.for_update(:update_profile, %{}, actor: u)
    |> Ash.Changeset.force_change_attribute(:role, :admin)
    |> Ash.update!(authorize?: false)
  end

  defp article(author) do
    {:ok, a} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: "T", blocks: [], category: :movement}, actor: author)
      |> Ash.create()

    a
  end

  test "publishing an article enqueues an article_published award" do
    u = user("alice")
    a = article(u)
    {:ok, _} = a |> Ash.Changeset.for_update(:publish, %{}, actor: u) |> Ash.update()

    assert_enqueued(worker: AwardWorker, args: %{"user_id" => u.id, "source" => "article_published", "source_ref" => "article:" <> a.id})
  end

  test "posting a comment enqueues a comment_posted award" do
    u = user("alice")
    a = article(u)
    {:ok, p} = a |> Ash.Changeset.for_update(:publish, %{}, actor: u) |> Ash.update()

    {:ok, c} =
      Verscienta.Engagement.Comment
      |> Ash.Changeset.for_create(:create, %{body: "hi", article_id: p.id}, actor: u)
      |> Ash.create()

    assert_enqueued(worker: AwardWorker, args: %{"user_id" => u.id, "source" => "comment_posted", "source_ref" => "comment:" <> c.id})
  end

  test "a reaction on an authored article enqueues reaction_received for the author" do
    author = user("alice")
    reactor = user("bob")
    a = article(author)
    {:ok, p} = a |> Ash.Changeset.for_update(:publish, %{}, actor: author) |> Ash.update()

    {:ok, _} =
      Verscienta.Engagement.Reaction
      |> Ash.ActionInput.for_action(:toggle, %{article_id: p.id, kind: :like})
      |> Ash.run_action(actor: reactor)

    assert_enqueued(worker: AwardWorker, args: %{"user_id" => author.id, "source" => "reaction_received"})
  end

  test "AwardWorker.perform calls award (writes entry + points)" do
    u = user("alice")
    assert :ok = perform_job(AwardWorker, %{"user_id" => u.id, "source" => "comment_posted", "source_ref" => "comment:x"})
    assert Ash.get!(Verscienta.Accounts.User, u.id, authorize?: false).points == 5
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta/gamification/hooks_test.exs"
```
Expected: fails — worker/hooks missing.

- [ ] **Step 3: Create the AwardWorker**

Create `lib/verscienta/gamification/workers/award_worker.ex`:
```elixir
defmodule Verscienta.Gamification.Workers.AwardWorker do
  @moduledoc "Awards points (+ badges) for an engagement event."
  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 300]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "source" => source, "source_ref" => source_ref}}) do
    Verscienta.Gamification.award(user_id, String.to_existing_atom(source), source_ref)
  end
end
```
NOTE: `award/3` returns `:ok`. `String.to_existing_atom/1` is safe — the source strings come only from our own hooks (the four known sources, whose atoms exist). `unique: [period: 300]` dedupes identical args within 5 min; the ledger's `source_ref` is the hard idempotency guard regardless.

- [ ] **Step 4: Create the AwardPublish change**

Create `lib/verscienta/content/article/changes/award_publish.ex`:
```elixir
defmodule Verscienta.Content.Article.Changes.AwardPublish do
  @moduledoc "After-action: enqueue an article_published award for the author (best-effort)."
  use Ash.Resource.Change
  require Logger

  alias Verscienta.Gamification.Workers.AwardWorker

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _cs, record ->
      enqueue(record)
      {:ok, record}
    end)
  end

  defp enqueue(%{author_id: nil}), do: :ok

  defp enqueue(%{author_id: author_id, id: id}) do
    %{"user_id" => author_id, "source" => "article_published", "source_ref" => "article:" <> id}
    |> AwardWorker.new()
    |> Oban.insert!()

    :ok
  rescue
    error ->
      Logger.warning("Failed to enqueue publish award: #{inspect(error)}")
      :ok
  end
end
```

- [ ] **Step 5: Create the AwardComment change**

Create `lib/verscienta/engagement/comment/changes/award_comment.ex`:
```elixir
defmodule Verscienta.Engagement.Comment.Changes.AwardComment do
  @moduledoc "After-action: enqueue a comment_posted award (best-effort)."
  use Ash.Resource.Change
  require Logger

  alias Verscienta.Gamification.Workers.AwardWorker

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _cs, record ->
      enqueue(record)
      {:ok, record}
    end)
  end

  defp enqueue(%{user_id: user_id, id: id}) do
    %{"user_id" => user_id, "source" => "comment_posted", "source_ref" => "comment:" <> id}
    |> AwardWorker.new()
    |> Oban.insert!()

    :ok
  rescue
    error ->
      Logger.warning("Failed to enqueue comment award: #{inspect(error)}")
      :ok
  end
end
```

- [ ] **Step 6: Attach the changes**

In `lib/verscienta/content/article.ex` `:publish` action, append after the existing `EnqueueIndex` change:
```elixir
      change Verscienta.Content.Article.Changes.AwardPublish
```
In `lib/verscienta/engagement/comment.ex` `:create` action, append after the existing `BroadcastComment` change:
```elixir
      change Verscienta.Engagement.Comment.Changes.AwardComment
```

- [ ] **Step 7: Enqueue reaction-received in the reaction toggle create branch**

In `lib/verscienta/engagement/reaction.ex`, in the `:toggle` run-fn's `nil ->` (create) branch, after creating the reaction, load the article's author and enqueue. Change the `nil ->` branch to:
```elixir
            nil ->
              created =
                Verscienta.Engagement.Reaction
                |> Ash.Changeset.for_create(:create, %{article_id: article_id, kind: kind}, actor: actor)
                |> Ash.create!(authorize?: true)

              maybe_award_author(article_id, created.id)
              created
```
And add a private helper to the module:
```elixir
  defp maybe_award_author(article_id, reaction_id) do
    article = Ash.get!(Verscienta.Content.Article, article_id, authorize?: false)

    if article.author_id do
      %{"user_id" => article.author_id, "source" => "reaction_received", "source_ref" => "reaction:" <> reaction_id}
      |> Verscienta.Gamification.Workers.AwardWorker.new()
      |> Oban.insert!()
    end

    :ok
  rescue
    _ -> :ok
  end
```
NOTE: this runs inside the toggle's run-fn (a generic action) — there's no after_action there, so enqueue inline but wrap in rescue so a failure can't break the reaction. Do NOT award on the un-react (destroy) path.

- [ ] **Step 8: Run tests + FULL gate + regression, then commit**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/gamification/hooks_test.exs && mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(gamification): AwardWorker + publish/comment/reaction earning hooks"
```
Then `git rev-parse --short HEAD`. Report the full suite count. (Existing engagement/content tests must still pass — the new after-actions only enqueue Oban jobs, which don't execute in `:manual` mode.)

---

## Task 8: Reading-time tracking (TDD)

**Files:**
- Modify: `lib/verscienta_web/live/article_reader_live.ex` (handle `reading_complete` + attach hook)
- Modify: `assets/js/app.js` (ReadingTimer hook)
- Test: `test/verscienta_web/live/article_reader_live_test.exs` (extend)

- [ ] **Step 1: Add the failing test**

Append to `test/verscienta_web/live/article_reader_live_test.exs` (inside the module; `sign_in`, `author`, `published` helpers already exist):
```elixir
  test "signed-in reading_complete awards reading points once per day", %{conn: conn} do
    use Oban.Testing, repo: Verscienta.Repo
    reader = author("dwell_reader")
    a = published(author("dwell_writer"))
    conn = sign_in(conn, reader)

    {:ok, lv, _html} = live(conn, ~p"/articles/#{a.slug}")

    render_hook(lv, "reading_complete", %{})

    today = Date.utc_today()
    ref = "reading:#{reader.id}:#{a.id}:#{today}"

    assert_enqueued(worker: Verscienta.Gamification.Workers.AwardWorker, args: %{"user_id" => reader.id, "source" => "reading", "source_ref" => ref})
  end

  test "signed-out reading_complete enqueues nothing", %{conn: conn} do
    a = published(author("dwell_writer2"))
    {:ok, lv, _html} = live(conn, ~p"/articles/#{a.slug}")
    render_hook(lv, "reading_complete", %{})
    refute_enqueued(worker: Verscienta.Gamification.Workers.AwardWorker)
  end
```
NOTE: `use Oban.Testing` inside a test won't work — instead add `use Oban.Testing, repo: Verscienta.Repo` at the TOP of the test module (after `use VerscientaWeb.ConnCase`). Move it there; remove the inline `use`. `render_hook/3` (from Phoenix.LiveViewTest) pushes the event as if from the JS hook. If `refute_enqueued` needs an args filter, use `refute_enqueued(worker: AwardWorker)`.

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta_web/live/article_reader_live_test.exs"
```
Expected: the two new tests fail (no `reading_complete` handler); existing reader tests pass.

- [ ] **Step 3: Handle reading_complete in the reader**

In `lib/verscienta_web/live/article_reader_live.ex`, add a `handle_event` clause (with the other handle_event clauses, contiguous):
```elixir
  def handle_event("reading_complete", _params, socket) do
    case socket.assigns[:current_user] do
      nil ->
        {:noreply, socket}

      actor ->
        article_id = socket.assigns.article.id
        ref = "reading:#{actor.id}:#{article_id}:#{Date.utc_today()}"

        %{"user_id" => actor.id, "source" => "reading", "source_ref" => ref}
        |> Verscienta.Gamification.Workers.AwardWorker.new()
        |> Oban.insert!()

        {:noreply, socket}
    end
  end
```

- [ ] **Step 4: Attach the ReadingTimer hook in render**

In the reader's `render/1`, add a `phx-hook` container around (or on) the article. The simplest: add an invisible hook element near the top of the article with the id:
```heex
      <div id="reading-timer" phx-hook="ReadingTimer" data-article-id={@article.id}></div>
```
Place it inside the `<article>` (e.g. right after the opening tag). The hook only needs to exist + push the event.

- [ ] **Step 5: Add the ReadingTimer JS hook**

In `assets/js/app.js`, add to the `Hooks` object (the file has `const Hooks = {}` then `Hooks.BlockReorder = ...`; add alongside):
```javascript
Hooks.ReadingTimer = {
  mounted() {
    this.visibleMs = 0
    this.fired = false
    this.last = Date.now()
    this.threshold = 30000

    this.tick = () => {
      if (document.visibilityState === "visible") {
        const now = Date.now()
        this.visibleMs += now - this.last
        this.last = now
        if (!this.fired && this.visibleMs >= this.threshold) {
          this.fired = true
          this.pushEvent("reading_complete", {})
          clearInterval(this.timer)
        }
      } else {
        this.last = Date.now()
      }
    }

    this.timer = setInterval(this.tick, 1000)
  },
  destroyed() {
    if (this.timer) clearInterval(this.timer)
  },
}
```
(It accumulates only visible time; fires once at 30s; cleans up on destroy. `hooks: {...colocatedHooks, ...Hooks}` already wires it.)

- [ ] **Step 6: Run reader tests + FULL gate**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/article_reader_live_test.exs && mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors"
```
Expected: new (2) + existing reader tests pass; gates clean. Confirm no duplicate `handle_event` clauses.

- [ ] **Step 7: Commit**

```powershell
git add -A
git commit -m "feat(gamification): 30s reading-time award via ReadingTimer hook"
```
Then `git rev-parse --short HEAD`.

---

## Task 9: Profile display (TDD)

**Files:**
- Modify: `lib/verscienta_web/live/profile_live.ex`
- Test: `test/verscienta_web/live/profile_live_test.exs` (extend or create)

- [ ] **Step 1: Add the failing test**

Open `test/verscienta_web/live/profile_live_test.exs` (it exists from the Auth subsystem). Add a test (reuse its helpers; if it lacks an article/award helper, inline as below):
```elixir
  test "profile shows points, level, and earned badges", %{conn: conn} do
    # create a user, award points + a badge via the engine
    u =
      Verscienta.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: "pointuser@example.com",
        username: "pointuser",
        password: "password123",
        password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    Verscienta.Gamification.Badge
    |> Ash.Changeset.for_create(:upsert, %{key: :first_comment, name: "First Comment", description: "d", threshold_source: :comment_posted, threshold_value: 1})
    |> Ash.create!(authorize?: false)

    :ok = Verscienta.Gamification.award(u.id, :comment_posted, "comment:1")

    {:ok, _lv, html} = live(conn, ~p"/@pointuser")
    assert html =~ "5"          # points total
    assert html =~ "First Comment"  # badge name
    assert html =~ "level" or html =~ "Level" or html =~ "lv"
  end
```
NOTE: match the existing test file's module/helpers; if it has a `user/1` helper, use it. Keep existing profile tests intact.

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta_web/live/profile_live_test.exs"
```
Expected: the new test fails (points/badges not shown); existing profile tests pass.

- [ ] **Step 3: Load + render points/level/badges**

In `lib/verscienta_web/live/profile_live.ex`:
- In `mount/3`, load badges on the user. Change the read to load `:user_badges` (+ their `:badge`):
```elixir
    user =
      Verscienta.Accounts.User
      |> Ash.Query.filter(username == ^username)
      |> Ash.Query.load(user_badges: [:badge])
      |> Ash.read_one!(authorize?: false)
      |> case do
        nil -> raise Ash.Error.Query.NotFound
        user -> user
      end
```
- Add `alias Verscienta.Gamification.Points` near the top.
- In `render/1`, after the role `<p>`, add a points/level row + badges:
```heex
        <div class="mt-4 flex flex-wrap items-center gap-3 text-[11px] uppercase tracking-wider text-ink-3">
          <span class="text-zune">level {Points.level_for(@user.points)}</span>
          <span>{@user.points} vitality points</span>
        </div>

        <div :if={@user.user_badges != []} class="mt-4 flex flex-wrap gap-2">
          <span
            :for={ub <- @user.user_badges}
            title={ub.badge.description}
            class="border border-line px-3 py-1 text-[11px] uppercase tracking-wider text-ink-2"
          >
            {ub.badge.name}
          </span>
        </div>
```

- [ ] **Step 4: Run tests + FULL gate**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/profile_live_test.exs && mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors"
```
Expected: new + existing profile tests pass; gates clean.

- [ ] **Step 5: Commit**

```powershell
git add -A
git commit -m "feat(gamification): show points, level, and badges on profile"
```
Then `git rev-parse --short HEAD`.

---

## Task 10: Badge seeds + full verification

**Files:**
- Modify: `priv/repo/seeds.exs`

- [ ] **Step 1: Append the badge catalog seeds**

Append to `priv/repo/seeds.exs` (idempotent upsert by key):
```elixir
# Gamification badge catalog (idempotent upsert by key).
badge_catalog = [
  %{key: :first_article, name: "First Article", description: "Published your first article.", threshold_source: :article_published, threshold_value: 1},
  %{key: :wordsmith, name: "Wordsmith", description: "Published five articles.", threshold_source: :article_published, threshold_value: 5},
  %{key: :first_comment, name: "First Comment", description: "Posted your first comment.", threshold_source: :comment_posted, threshold_value: 1},
  %{key: :conversationalist, name: "Conversationalist", description: "Posted ten comments.", threshold_source: :comment_posted, threshold_value: 10},
  %{key: :centurion, name: "Centurion", description: "Earned 100 vitality points.", threshold_source: nil, threshold_value: 100}
]

for attrs <- badge_catalog do
  Verscienta.Gamification.Badge
  |> Ash.Changeset.for_create(:upsert, attrs)
  |> Ash.create!(authorize?: false)
end

IO.puts("Seeded #{length(badge_catalog)} badges")
```
NOTE: `require Ash.Query` is already at the top of seeds.exs. The upsert is idempotent (re-running updates by key, no dupes).

- [ ] **Step 2: Run seeds twice (idempotency)**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "mix ash.setup >/dev/null 2>&1; mix run priv/repo/seeds.exs; mix run priv/repo/seeds.exs"
```
Expected: prints "Seeded 5 badges" both times; no duplicate-key crash (upsert).

- [ ] **Step 3: Full quality-gate run from clean deps**

```powershell
docker compose run --rm -T app bash -lc "mix deps.get && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
```
Expected: format clean, credo 0 issues, no warnings, ALL tests pass. Capture the exact `N tests, 0 failures` line.

- [ ] **Step 4: Manual smoke (optional)**

```powershell
docker compose up -d
docker compose logs app --tail 20
```
Signed in: publish an article → your profile points rise (+50) and "First Article" badge appears after the AwardWorker runs; comment on an article; have another user react to your article (+2); open an article and wait 30s → reading points. Then `docker compose down`.

- [ ] **Step 5: Commit**

```powershell
git add -A
git commit -m "feat(gamification): seed badge catalog; finalize subsystem"
```
Then `git rev-parse --short HEAD`.

---

## Definition of Done (verify all)

- [ ] Publishing (+50), commenting (+5), receiving a reaction (+2 to the author), and 30s reading (+10) award Vitality Points via Oban into an append-only ledger; `User.points` reflects the cached total; all awards idempotent (no double-count on retry, re-publish, reload, same-day reading).
- [ ] Reaction-received awards the article's author and skips authorless aggregated articles.
- [ ] Milestone badges granted once when thresholds crossed (points-based and source-count); levels derived from points.
- [ ] `/@:username` shows points, level, and earned badges.
- [ ] Earning hooks are best-effort (never roll back the user action); `points` not settable via `update_profile`.
- [ ] `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test` all pass (verified AFTER the final edit).
- [ ] Migrations (user.points, points_entries, badges, user_badges) + badge seeds committed on `phase-1-gamification`.
```
