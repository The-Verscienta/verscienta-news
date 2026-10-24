# Caching Layer Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `Verscienta.Cache` — a two-tier (ETS L1 + Redis L2) cache with tag-based invalidation, single-flight loader coordination, and Phoenix.PubSub cross-node invalidation — wired into 4 feeds + 4 count categories, replacing the existing leaderboard-only ETS cache.

**Architecture:** Single public module `Verscienta.Cache` manages 3 named ETS tables (data, tag index, locks) and a Redix connection pool. `fetch/3` checks L1 → L2 → runs the loader → writes both layers. Tag-based `invalidate_tag/1` clears matched keys from both layers and broadcasts on the `"cache:invalidations"` Phoenix.PubSub topic; a `Subscriber` GenServer clears local L1 on inbound messages (cross-node-ready for free once we configure the Phoenix.PubSub Redis adapter). Single-flight uses `:ets.insert_new/2` as a lock with a 5ms-poll wait loop and a 30s sweeper for stale locks.

**Tech Stack:** Elixir 1.18.4 / OTP 27.3.4, Phoenix 1.8, `redix ~> 1.5`, `:ets`, `:telemetry`. Tests via ExUnit.

**Conventions (apply to every task):**
- All `mix` commands run **in Docker**: `docker compose exec app mix <...>`. Service name is `app`, not `web`.
- Migrations: this subsystem has **no DB migrations**.
- Test DB resets use `MIX_ENV=test mix ecto.drop -r Verscienta.Repo && mix ecto.create -r Verscienta.Repo && mix ash.migrate` (NEVER `ash.setup`).
- LF line endings; format before commit.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Work on branch `phase-2-caching-layer` (created in Task 0).
- **Redis is disabled in test env** (`config :verscienta, Verscienta.Cache, redis_enabled: false`). Every test that exercises the cache uses L1 only.
- The cache's public API `fetch/3` returns `{:ok, value} | {:error, reason}` uniformly. Callers pattern-match.

---

### Task 0: Branch setup

**Files:** none (git only)

- [ ] **Step 1: Confirm clean main + spec present**

```bash
git checkout main && git pull --ff-only
git log -1 --oneline -- docs/superpowers/specs/2026-06-04-caching-layer-design.md
```
Expected: most recent commit on the spec is `docs: add caching layer design spec` (commit `b4ae579` or similar).

- [ ] **Step 2: Create the feature branch**

```bash
git checkout -b phase-2-caching-layer
```
Expected: on a clean `phase-2-caching-layer` branch off `main`.

---

### Task 1: Install Redix + scaffold `Verscienta.Cache` (ETS tables only)

**Files:**
- Modify: `mix.exs` (add `{:redix, "~> 1.5"}`)
- Modify: `config/config.exs` (Cache config block)
- Modify: `config/test.exs` (`redis_enabled: false`)
- Create: `lib/verscienta/cache.ex` (skeleton: 3 ETS tables, `start_link/1`, `child_spec/1`, public `flush/0`)
- Modify: `lib/verscienta/application.ex` (replace `Verscienta.Gamification.Cache` child with `Verscienta.Cache`)
- Test: `test/verscienta/cache/scaffold_test.exs` (new)

NOTE: this task does NOT yet delete `Verscienta.Gamification.Cache` — that's Task 10. For now, `Verscienta.Cache` runs alongside the old one (we just need the new ETS tables booted).

- [ ] **Step 1: Add the Redix dep**

In `mix.exs`, in `deps/0`, add (alphabetically):
```elixir
{:redix, "~> 1.5"},
```
Then:
```bash
docker compose exec app mix deps.get
```

- [ ] **Step 2: Add config block**

In `config/config.exs`, after the existing FunWithFlags config block (added in the prior feature-flags subsystem), add:
```elixir
config :verscienta, Verscienta.Cache,
  redis_enabled: true,
  redis_pool_size: 5,
  default_ttl: 60_000
```

In `config/test.exs`, override:
```elixir
config :verscienta, Verscienta.Cache,
  redis_enabled: false,
  redis_pool_size: 0,
  default_ttl: 60_000
```

- [ ] **Step 3: Create the Cache module skeleton**

Create `lib/verscienta/cache.ex`:
```elixir
defmodule Verscienta.Cache do
  @moduledoc """
  Two-tier cache (ETS L1 + Redis L2) with tag-based invalidation,
  single-flight loader coordination, and Phoenix.PubSub cross-node
  invalidation.

  Public API:
    * `fetch/3` — look up, compute on miss, cache + return `{:ok, v}` | `{:error, r}`.
    * `put/3` — write directly (skips the loader path).
    * `get/1` — read without computing; `{:ok, v}` | `:miss`.
    * `delete/1` — remove one key from L1 + L2, broadcast.
    * `invalidate_tag/1`, `invalidate_tags/1` — remove every key tagged with `tag`, broadcast.
    * `flush/0` — empty the L1 (test/dev helper).
  """

  @l1 :verscienta_cache_l1
  @tags :verscienta_cache_tags
  @locks :verscienta_cache_locks

  def l1_table, do: @l1
  def tags_table, do: @tags
  def locks_table, do: @locks

  @doc """
  Creates the 3 ETS tables if they don't already exist, then returns `:ignore`
  so the supervisor doesn't track a worker pid. The tables are owned by the
  calling (supervisor) process.
  """
  def start_link(_opts \\ []) do
    ensure_table(@l1, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    ensure_table(@tags, [:named_table, :public, :bag, write_concurrency: true])
    ensure_table(@locks, [:named_table, :public, :set, write_concurrency: true])
    :ignore
  end

  defp ensure_table(name, opts) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, opts)
      _ -> :ok
    end
  end

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc "Empty L1 (data + tag index + locks). Test/dev only."
  def flush do
    :ets.delete_all_objects(@l1)
    :ets.delete_all_objects(@tags)
    :ets.delete_all_objects(@locks)
    :ok
  end
end
```

- [ ] **Step 4: Wire into application supervisor**

In `lib/verscienta/application.ex`, replace the line:
```elixir
        Verscienta.Gamification.Cache,
```
with:
```elixir
        Verscienta.Cache,
        Verscienta.Gamification.Cache,
```
(Keep the old one running for now — leaderboards still call it. Task 10 will delete it.)

- [ ] **Step 5: Failing scaffold test**

Create `test/verscienta/cache/scaffold_test.exs`:
```elixir
defmodule Verscienta.Cache.ScaffoldTest do
  use ExUnit.Case, async: false

  alias Verscienta.Cache

  test "three ETS tables exist after boot" do
    assert :ets.whereis(Cache.l1_table()) != :undefined
    assert :ets.whereis(Cache.tags_table()) != :undefined
    assert :ets.whereis(Cache.locks_table()) != :undefined
  end

  test "flush/0 empties all three tables" do
    :ets.insert(Cache.l1_table(), {"k", "v", 0})
    :ets.insert(Cache.tags_table(), {"tag", "k"})
    :ets.insert(Cache.locks_table(), {"k", self(), make_ref(), 0})

    :ok = Cache.flush()

    assert :ets.tab2list(Cache.l1_table()) == []
    assert :ets.tab2list(Cache.tags_table()) == []
    assert :ets.tab2list(Cache.locks_table()) == []
  end
end
```

- [ ] **Step 6: Reset test DB + run scaffold test**

```bash
docker compose exec -e MIX_ENV=test app sh -c "mix ecto.drop -r Verscienta.Repo && mix ecto.create -r Verscienta.Repo && mix ash.migrate"
docker compose exec -e MIX_ENV=test app mix test test/verscienta/cache/scaffold_test.exs
```
Expected: 2 tests, 0 failures.

- [ ] **Step 7: Verify and commit**

```bash
docker compose exec app mix format
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix credo --strict
```

```bash
git add mix.exs mix.lock config/config.exs config/test.exs \
  lib/verscienta/cache.ex \
  lib/verscienta/application.ex \
  test/verscienta/cache/scaffold_test.exs
git commit -m "$(cat <<'EOF'
feat(cache): install Redix + scaffold Verscienta.Cache with 3 ETS tables

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: L1 `fetch`, `get`, `put`, `delete` (ETS only, no tags yet)

**Files:**
- Modify: `lib/verscienta/cache.ex` (add the 4 core functions)
- Test: `test/verscienta/cache/l1_test.exs` (new)

- [ ] **Step 1: Failing L1 tests**

Create `test/verscienta/cache/l1_test.exs`:
```elixir
defmodule Verscienta.Cache.L1Test do
  use ExUnit.Case, async: false

  alias Verscienta.Cache

  setup do
    Cache.flush()
    on_exit(&Cache.flush/0)
    :ok
  end

  test "fetch/3 miss runs loader, returns {:ok, value}, caches" do
    {:ok, 42} = Cache.fetch("k", [], fn -> {:ok, 42} end)
    assert Cache.get("k") == {:ok, 42}
  end

  test "fetch/3 hit returns cached value without running loader" do
    counter = :counters.new(1, [:atomics])

    {:ok, 7} =
      Cache.fetch("k", [], fn ->
        :counters.add(counter, 1, 1)
        {:ok, 7}
      end)

    {:ok, 7} =
      Cache.fetch("k", [], fn ->
        :counters.add(counter, 1, 1)
        {:ok, 7}
      end)

    assert :counters.get(counter, 1) == 1
  end

  test "fetch/3 respects TTL — entry expires after ttl ms" do
    {:ok, 1} = Cache.fetch("k", [ttl: 50], fn -> {:ok, 1} end)
    assert Cache.get("k") == {:ok, 1}
    Process.sleep(70)
    assert Cache.get("k") == :miss
  end

  test "fetch/3 loader returning {:error, reason} does not cache" do
    {:error, :boom} = Cache.fetch("k", [], fn -> {:error, :boom} end)
    assert Cache.get("k") == :miss
  end

  test "fetch/3 loader returning bare value raises ArgumentError" do
    assert_raise ArgumentError, ~r/loader returned/, fn ->
      Cache.fetch("k", [], fn -> 42 end)
    end
  end

  test "put/3 writes directly, get/1 reads it" do
    :ok = Cache.put("k", "value", ttl: 1_000)
    assert Cache.get("k") == {:ok, "value"}
  end

  test "delete/1 removes a key" do
    :ok = Cache.put("k", 1)
    :ok = Cache.delete("k")
    assert Cache.get("k") == :miss
  end

  test "get/1 on missing key returns :miss" do
    assert Cache.get("nope") == :miss
  end
end
```

- [ ] **Step 2: Implement the 4 functions**

In `lib/verscienta/cache.ex`, after the existing `flush/0`, add:
```elixir
  @doc """
  Look up `key`. On hit return `{:ok, value}`. On miss, run `loader.()`:
  if it returns `{:ok, v}`, cache + return `{:ok, v}`; if it returns
  `{:error, reason}`, return `{:error, reason}` WITHOUT caching.

  Options:
    * `:ttl` — milliseconds (default from config, 60_000).
    * `:tags` — list of tag strings (Task 3 wires the index).
    * `:redis` — when `false`, skip L2 (Task 6 wires L2).
  """
  def fetch(key, opts \\ [], loader) when is_binary(key) and is_function(loader, 0) do
    case lookup_l1(key) do
      {:ok, _} = hit -> hit
      :miss -> run_loader_and_store(key, loader, opts)
    end
  end

  @doc "Read without computing. `{:ok, value}` or `:miss`."
  def get(key) when is_binary(key), do: lookup_l1(key)

  @doc "Write a value directly, bypassing the loader path."
  def put(key, value, opts \\ []) when is_binary(key) do
    ttl = Keyword.get(opts, :ttl, default_ttl())
    expires_at = monotonic_ms() + ttl
    :ets.insert(@l1, {key, value, expires_at})
    :ok
  end

  @doc "Delete one key from L1."
  def delete(key) when is_binary(key) do
    :ets.delete(@l1, key)
    :ok
  end

  # ===== Internals =====

  defp lookup_l1(key) do
    now = monotonic_ms()

    case :ets.lookup(@l1, key) do
      [{^key, value, expires_at}] when expires_at > now -> {:ok, value}
      _ -> :miss
    end
  end

  defp run_loader_and_store(key, loader, opts) do
    case loader.() do
      {:ok, value} ->
        put(key, value, opts)
        {:ok, value}

      {:error, _} = err ->
        err

      other ->
        raise ArgumentError,
              "loader returned #{inspect(other)} — expected {:ok, v} | {:error, r}"
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp default_ttl do
    Application.get_env(:verscienta, __MODULE__, [])
    |> Keyword.get(:default_ttl, 60_000)
  end
```

- [ ] **Step 3: Run L1 tests — should pass**

```bash
docker compose exec -e MIX_ENV=test app mix test test/verscienta/cache/l1_test.exs
```
Expected: 8 tests, 0 failures.

- [ ] **Step 4: Verify and commit**

```bash
docker compose exec app mix format
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix credo --strict
docker compose exec -e MIX_ENV=test app mix test
```

```bash
git add lib/verscienta/cache.ex test/verscienta/cache/l1_test.exs
git commit -m "$(cat <<'EOF'
feat(cache): L1 fetch/get/put/delete with TTL and loader contract

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Tag index + `invalidate_tag` (ETS only)

**Files:**
- Modify: `lib/verscienta/cache.ex` (tag-aware put, invalidate_tag, invalidate_tags)
- Test: `test/verscienta/cache/tags_test.exs` (new)

- [ ] **Step 1: Failing tag tests**

Create `test/verscienta/cache/tags_test.exs`:
```elixir
defmodule Verscienta.Cache.TagsTest do
  use ExUnit.Case, async: false

  alias Verscienta.Cache

  setup do
    Cache.flush()
    on_exit(&Cache.flush/0)
    :ok
  end

  test "fetch/3 with :tags writes to the tag index" do
    {:ok, 1} = Cache.fetch("k", [tags: ["a", "b"]], fn -> {:ok, 1} end)

    tag_rows = :ets.tab2list(Cache.tags_table())
    assert {"a", "k"} in tag_rows
    assert {"b", "k"} in tag_rows
  end

  test "invalidate_tag/1 deletes matching keys from L1 and the tag index" do
    {:ok, 1} = Cache.fetch("k1", [tags: ["a"]], fn -> {:ok, 1} end)
    {:ok, 2} = Cache.fetch("k2", [tags: ["a"]], fn -> {:ok, 2} end)
    {:ok, 3} = Cache.fetch("k3", [tags: ["b"]], fn -> {:ok, 3} end)

    :ok = Cache.invalidate_tag("a")

    assert Cache.get("k1") == :miss
    assert Cache.get("k2") == :miss
    assert Cache.get("k3") == {:ok, 3}

    tag_rows = :ets.tab2list(Cache.tags_table())
    refute Enum.any?(tag_rows, fn {tag, _} -> tag == "a" end)
    assert {"b", "k3"} in tag_rows
  end

  test "invalidate_tags/1 deletes all keys for multiple tags" do
    {:ok, 1} = Cache.fetch("k1", [tags: ["a"]], fn -> {:ok, 1} end)
    {:ok, 2} = Cache.fetch("k2", [tags: ["b"]], fn -> {:ok, 2} end)
    {:ok, 3} = Cache.fetch("k3", [tags: ["c"]], fn -> {:ok, 3} end)

    :ok = Cache.invalidate_tags(["a", "b"])

    assert Cache.get("k1") == :miss
    assert Cache.get("k2") == :miss
    assert Cache.get("k3") == {:ok, 3}
  end

  test "put/3 with :tags writes to the tag index" do
    :ok = Cache.put("k", "v", tags: ["x"])
    assert {"x", "k"} in :ets.tab2list(Cache.tags_table())
  end

  test "invalidate_tag/1 on a nonexistent tag is a no-op" do
    :ok = Cache.invalidate_tag("nope")
  end
end
```

- [ ] **Step 2: Implement tag-aware put + invalidate_tag**

In `lib/verscienta/cache.ex`:

Replace the existing `put/3` with one that also writes the tag index:
```elixir
  def put(key, value, opts \\ []) when is_binary(key) do
    ttl = Keyword.get(opts, :ttl, default_ttl())
    tags = Keyword.get(opts, :tags, [])
    expires_at = monotonic_ms() + ttl
    :ets.insert(@l1, {key, value, expires_at})

    Enum.each(tags, fn tag when is_binary(tag) ->
      :ets.insert(@tags, {tag, key})
    end)

    :ok
  end
```

Add the two invalidation functions:
```elixir
  @doc "Invalidate every L1 key tagged with `tag`."
  def invalidate_tag(tag) when is_binary(tag) do
    keys = :ets.lookup(@tags, tag) |> Enum.map(fn {^tag, key} -> key end)
    Enum.each(keys, &:ets.delete(@l1, &1))
    :ets.delete(@tags, tag)
    :ok
  end

  @doc "Invalidate every key for any of the listed tags."
  def invalidate_tags(tags) when is_list(tags) do
    Enum.each(tags, &invalidate_tag/1)
    :ok
  end
```

- [ ] **Step 3: Run tag tests — should pass**

```bash
docker compose exec -e MIX_ENV=test app mix test test/verscienta/cache/tags_test.exs
```
Expected: 5 tests, 0 failures.

- [ ] **Step 4: Verify and commit**

```bash
docker compose exec app mix format
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix credo --strict
```

```bash
git add lib/verscienta/cache.ex test/verscienta/cache/tags_test.exs
git commit -m "$(cat <<'EOF'
feat(cache): tag index + invalidate_tag (L1)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Single-flight + LockSweeper

**Files:**
- Modify: `lib/verscienta/cache.ex` (refactor `fetch/3` through the lock path)
- Create: `lib/verscienta/cache/lock_sweeper.ex`
- Modify: `lib/verscienta/application.ex` (add LockSweeper child)
- Test: `test/verscienta/cache/single_flight_test.exs` (new)
- Test: `test/verscienta/cache/lock_sweeper_test.exs` (new)

- [ ] **Step 1: Failing single-flight test**

Create `test/verscienta/cache/single_flight_test.exs`:
```elixir
defmodule Verscienta.Cache.SingleFlightTest do
  use ExUnit.Case, async: false

  alias Verscienta.Cache

  setup do
    Cache.flush()
    on_exit(&Cache.flush/0)
    :ok
  end

  test "10 concurrent fetches for the same key run the loader exactly once" do
    counter = :counters.new(1, [:atomics])

    loader = fn ->
      :counters.add(counter, 1, 1)
      Process.sleep(100)
      {:ok, :done}
    end

    results =
      1..10
      |> Enum.map(fn _ -> Task.async(fn -> Cache.fetch("hot_key", [], loader) end) end)
      |> Task.await_many(5_000)

    assert Enum.all?(results, &match?({:ok, :done}, &1))
    assert :counters.get(counter, 1) == 1
  end

  test "if lock-holder loader raises, the lock is released" do
    bomb_loader = fn -> raise "boom" end

    assert_raise RuntimeError, "boom", fn -> Cache.fetch("k", [], bomb_loader) end

    # Subsequent fetch should be able to acquire the lock
    {:ok, :ok_now} = Cache.fetch("k", [], fn -> {:ok, :ok_now} end)
  end
end
```

- [ ] **Step 2: Refactor `fetch/3` through the lock path**

In `lib/verscienta/cache.ex`, replace `fetch/3` and `run_loader_and_store/3`:
```elixir
  def fetch(key, opts \\ [], loader) when is_binary(key) and is_function(loader, 0) do
    case lookup_l1(key) do
      {:ok, _} = hit -> hit
      :miss -> fetch_with_lock(key, loader, opts)
    end
  end

  defp fetch_with_lock(key, loader, opts) do
    ref = make_ref()

    case :ets.insert_new(@locks, {key, self(), ref, monotonic_ms()}) do
      true ->
        try do
          run_loader_and_store(key, loader, opts)
        after
          :ets.delete(@locks, key)
        end

      false ->
        wait_for_fill(key, monotonic_ms() + 5_000, loader, opts)
    end
  end

  defp wait_for_fill(key, deadline, loader, opts) do
    case lookup_l1(key) do
      {:ok, _} = hit ->
        hit

      :miss ->
        if monotonic_ms() < deadline do
          Process.sleep(5)
          wait_for_fill(key, deadline, loader, opts)
        else
          # Lock-holder may have crashed; fall back to running the loader ourselves.
          run_loader_and_store(key, loader, opts)
        end
    end
  end

  defp run_loader_and_store(key, loader, opts) do
    case loader.() do
      {:ok, value} ->
        put(key, value, opts)
        {:ok, value}

      {:error, _} = err ->
        err

      other ->
        raise ArgumentError,
              "loader returned #{inspect(other)} — expected {:ok, v} | {:error, r}"
    end
  end
```

- [ ] **Step 3: Run single-flight test — should pass**

```bash
docker compose exec -e MIX_ENV=test app mix test test/verscienta/cache/single_flight_test.exs
```
Expected: 2 tests, 0 failures.

- [ ] **Step 4: Failing LockSweeper test**

Create `test/verscienta/cache/lock_sweeper_test.exs`:
```elixir
defmodule Verscienta.Cache.LockSweeperTest do
  use ExUnit.Case, async: false

  alias Verscienta.Cache
  alias Verscienta.Cache.LockSweeper

  setup do
    Cache.flush()
    on_exit(&Cache.flush/0)
    :ok
  end

  test "sweep removes lock rows whose owner pid is dead" do
    dead_pid = spawn(fn -> :ok end)
    :timer.sleep(10)
    refute Process.alive?(dead_pid)

    :ets.insert(Cache.locks_table(), {"dead_key", dead_pid, make_ref(), 0})

    :ok = LockSweeper.sweep_now()

    assert :ets.lookup(Cache.locks_table(), "dead_key") == []
  end

  test "sweep removes lock rows older than 30 seconds even if pid is alive" do
    stale_inserted_at = System.monotonic_time(:millisecond) - 31_000
    :ets.insert(Cache.locks_table(), {"stale_key", self(), make_ref(), stale_inserted_at})

    :ok = LockSweeper.sweep_now()

    assert :ets.lookup(Cache.locks_table(), "stale_key") == []
  end

  test "sweep leaves fresh, alive locks alone" do
    :ets.insert(Cache.locks_table(), {"fresh_key", self(), make_ref(), System.monotonic_time(:millisecond)})

    :ok = LockSweeper.sweep_now()

    assert :ets.lookup(Cache.locks_table(), "fresh_key") != []
  end
end
```

- [ ] **Step 5: Create LockSweeper**

Create `lib/verscienta/cache/lock_sweeper.ex`:
```elixir
defmodule Verscienta.Cache.LockSweeper do
  @moduledoc """
  Prunes stale lock rows from `Verscienta.Cache.locks_table/0` every 30s.

  A lock row is stale if its owner pid is no longer alive OR if its
  inserted_at is more than 30s old.
  """
  use GenServer

  @sweep_interval_ms 30_000
  @max_age_ms 30_000

  alias Verscienta.Cache

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Force a sweep right now (test/dev helper)."
  def sweep_now, do: GenServer.call(__MODULE__, :sweep)

  @impl true
  def init(_) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    do_sweep()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    do_sweep()
    schedule()
    {:noreply, state}
  end

  defp do_sweep do
    now = System.monotonic_time(:millisecond)
    table = Cache.locks_table()

    for {key, pid, _ref, inserted_at} <- :ets.tab2list(table) do
      cond do
        not Process.alive?(pid) -> :ets.delete(table, key)
        now - inserted_at > @max_age_ms -> :ets.delete(table, key)
        true -> :ok
      end
    end
  end

  defp schedule, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
```

- [ ] **Step 6: Add LockSweeper to the application supervisor**

In `lib/verscienta/application.ex`, in the children list, after `Verscienta.Cache,` add:
```elixir
        Verscienta.Cache.LockSweeper,
```

- [ ] **Step 7: Run all cache tests**

```bash
docker compose exec -e MIX_ENV=test app mix test test/verscienta/cache/
```
Expected: 18 tests (2 + 8 + 5 + 2 + 3), 0 failures.

- [ ] **Step 8: Verify and commit**

```bash
docker compose exec app mix format
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix credo --strict
```

```bash
git add lib/verscienta/cache.ex \
  lib/verscienta/cache/lock_sweeper.ex \
  lib/verscienta/application.ex \
  test/verscienta/cache/single_flight_test.exs \
  test/verscienta/cache/lock_sweeper_test.exs
git commit -m "$(cat <<'EOF'
feat(cache): single-flight via :ets.insert_new + LockSweeper

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Telemetry events

**Files:**
- Modify: `lib/verscienta/cache.ex` (emit telemetry on every `fetch`)
- Test: `test/verscienta/cache/telemetry_test.exs` (new)

- [ ] **Step 1: Failing telemetry test**

Create `test/verscienta/cache/telemetry_test.exs`:
```elixir
defmodule Verscienta.Cache.TelemetryTest do
  use ExUnit.Case, async: false

  alias Verscienta.Cache

  setup do
    Cache.flush()

    test_pid = self()
    handler_id = "test-#{System.unique_integer()}"

    :telemetry.attach(
      handler_id,
      [:verscienta, :cache, :fetch],
      fn _event, measurements, metadata, _ ->
        send(test_pid, {:cache_event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      Cache.flush()
    end)

    :ok
  end

  test "emits source: :loader on miss" do
    {:ok, 1} = Cache.fetch("k", [tags: ["a"]], fn -> {:ok, 1} end)

    assert_receive {:cache_event, %{duration_native: d}, %{key: "k", tags: ["a"], source: :loader}}
                   when is_integer(d)
  end

  test "emits source: :l1 on hit" do
    {:ok, 1} = Cache.fetch("k", [], fn -> {:ok, 1} end)

    # Drain the miss event
    assert_receive {:cache_event, _, %{source: :loader}}

    {:ok, 1} = Cache.fetch("k", [], fn -> {:ok, :never_called} end)

    assert_receive {:cache_event, _, %{key: "k", source: :l1}}
  end
end
```

- [ ] **Step 2: Add telemetry emission**

In `lib/verscienta/cache.ex`, modify `fetch/3` to wrap the lookup-or-load in a `:telemetry.span`-style measurement. Replace `fetch/3` with:
```elixir
  def fetch(key, opts \\ [], loader) when is_binary(key) and is_function(loader, 0) do
    tags = Keyword.get(opts, :tags, [])
    start = System.monotonic_time()

    {result, source} =
      case lookup_l1(key) do
        {:ok, _} = hit -> {hit, :l1}
        :miss -> {fetch_with_lock(key, loader, opts), :loader}
      end

    emit_telemetry(key, tags, source, System.monotonic_time() - start)
    result
  end

  defp emit_telemetry(key, tags, source, duration_native) do
    :telemetry.execute(
      [:verscienta, :cache, :fetch],
      %{duration_native: duration_native},
      %{key: key, tags: tags, source: source}
    )
  end
```

Note: the `:loader` source covers both "we ran the loader" and "we waited for another process's loader" — both are L1 misses from the caller's perspective. The :l2 source is added in Task 6.

- [ ] **Step 3: Run telemetry tests**

```bash
docker compose exec -e MIX_ENV=test app mix test test/verscienta/cache/telemetry_test.exs
```
Expected: 2 tests, 0 failures.

- [ ] **Step 4: Verify and commit**

```bash
docker compose exec app mix format
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix credo --strict
```

```bash
git add lib/verscienta/cache.ex test/verscienta/cache/telemetry_test.exs
git commit -m "$(cat <<'EOF'
feat(cache): emit [:verscienta, :cache, :fetch] telemetry on every lookup

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: L2 (Redis) + degraded mode when Redis is down

**Files:**
- Create: `lib/verscienta/cache/redis.ex`
- Modify: `lib/verscienta/cache.ex` (L2 lookup/write/invalidate)
- Modify: `lib/verscienta/application.ex` (add Cache.Redis child)
- Test: `test/verscienta/cache/redis_disabled_test.exs` (new — verifies L1-only mode works correctly)

Note: this task's tests verify the DISABLED path (test env). The ENABLED path is exercised manually in dev with Redis running. End-to-end with real Redis is a future load-test concern.

- [ ] **Step 1: Create Cache.Redis pool supervisor**

Create `lib/verscienta/cache/redis.ex`:
```elixir
defmodule Verscienta.Cache.Redis do
  @moduledoc """
  Redix connection pool for `Verscienta.Cache` L2.

  Pool size from `config :verscienta, Verscienta.Cache, redis_pool_size: N`.
  When `redis_enabled: false` (test env), the supervisor starts with no
  children and every `command/1` call returns `{:error, :disabled}` so
  callers degrade to L1-only.
  """
  use Supervisor

  def start_link(_opts \\ []), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    Supervisor.init(pool_children(), strategy: :one_for_one)
  end

  defp pool_children do
    if enabled?() do
      size = config(:redis_pool_size, 5)
      url = Application.get_env(:verscienta, :redis_url, "redis://localhost:6379")

      for i <- 0..(size - 1) do
        Supervisor.child_spec({Redix, {url, [name: name(i)]}}, id: {:redix, i})
      end
    else
      []
    end
  end

  @doc "Pick a connection by round-robin index name."
  def name(i), do: :"verscienta_cache_redix_#{i}"

  @doc """
  Issue a Redis command, picking a random pool member. Returns
  `{:error, :disabled}` if Redis is turned off (test env), or the raw
  `Redix.command/3` result otherwise.
  """
  def command(args) when is_list(args) do
    if enabled?() do
      size = config(:redis_pool_size, 5)
      conn = name(:rand.uniform(size) - 1)

      try do
        Redix.command(conn, args, timeout: 250)
      rescue
        e -> {:error, e}
      catch
        :exit, _ -> {:error, :exit}
      end
    else
      {:error, :disabled}
    end
  end

  def enabled?, do: config(:redis_enabled, true)

  defp config(key, default) do
    Application.get_env(:verscienta, Verscienta.Cache, [])
    |> Keyword.get(key, default)
  end
end
```

- [ ] **Step 2: Wire Cache.Redis into the supervisor**

In `lib/verscienta/application.ex`, in the children list, after `Verscienta.Cache.LockSweeper,` add:
```elixir
        Verscienta.Cache.Redis,
```

- [ ] **Step 3: Add L2 lookup/write/invalidate to `Verscienta.Cache`**

In `lib/verscienta/cache.ex`, after the existing private helpers, add the Redis-aware paths.

First, add aliases at the top of the module:
```elixir
  alias Verscienta.Cache.Redis
  require Logger
```

Then replace `fetch/3` (yes again) with the L2-aware version:
```elixir
  def fetch(key, opts \\ [], loader) when is_binary(key) and is_function(loader, 0) do
    tags = Keyword.get(opts, :tags, [])
    use_redis? = Keyword.get(opts, :redis, true)
    start = System.monotonic_time()

    {result, source} =
      case lookup_l1(key) do
        {:ok, _} = hit ->
          {hit, :l1}

        :miss ->
          case use_redis? and lookup_l2(key) do
            {:ok, value} ->
              # Backfill L1 so the next request skips Redis.
              put_l1_only(key, value, opts)
              {{:ok, value}, :l2}

            _ ->
              {fetch_with_lock(key, loader, opts), :loader}
          end
      end

    emit_telemetry(key, tags, source, System.monotonic_time() - start)
    result
  end

  defp lookup_l2(key) do
    case Redis.command(["GET", redis_key(key)]) do
      {:ok, nil} -> :miss
      {:ok, encoded} when is_binary(encoded) -> {:ok, decode(encoded)}
      {:error, _} -> :miss
    end
  end

  defp redis_key(key), do: "vc:" <> key

  defp encode(term), do: :erlang.term_to_binary(term, [:compressed])
  defp decode(bin), do: :erlang.binary_to_term(bin, [:safe])
```

Then modify `put/3` so it also writes to L2 and to the Redis tag index:
```elixir
  def put(key, value, opts \\ []) when is_binary(key) do
    put_l1_only(key, value, opts)
    put_l2(key, value, opts)
    :ok
  end

  defp put_l1_only(key, value, opts) do
    ttl = Keyword.get(opts, :ttl, default_ttl())
    tags = Keyword.get(opts, :tags, [])
    expires_at = monotonic_ms() + ttl
    :ets.insert(@l1, {key, value, expires_at})
    Enum.each(tags, fn tag when is_binary(tag) -> :ets.insert(@tags, {tag, key}) end)
    :ok
  end

  defp put_l2(key, value, opts) do
    if Keyword.get(opts, :redis, true) do
      ttl_s = div(Keyword.get(opts, :ttl, default_ttl()), 1000)
      tags = Keyword.get(opts, :tags, [])
      encoded = encode(value)

      case Redis.command(["SET", redis_key(key), encoded, "EX", to_string(ttl_s)]) do
        {:ok, _} ->
          Enum.each(tags, fn tag ->
            Redis.command(["SADD", "vc:tag:" <> tag, key])
            # tag index outlives entries by an hour so SMEMBERS still finds keys briefly
            Redis.command(["EXPIRE", "vc:tag:" <> tag, to_string(ttl_s + 3600)])
          end)

        {:error, reason} ->
          warn_once(:redis_down, "Verscienta.Cache.put L2 unavailable: #{inspect(reason)}")
      end
    end
  end
```

Replace `delete/1`:
```elixir
  def delete(key) when is_binary(key) do
    :ets.delete(@l1, key)
    _ = Redis.command(["DEL", redis_key(key)])
    :ok
  end
```

Replace `invalidate_tag/1`:
```elixir
  def invalidate_tag(tag) when is_binary(tag) do
    # L1
    keys = :ets.lookup(@tags, tag) |> Enum.map(fn {^tag, key} -> key end)
    Enum.each(keys, &:ets.delete(@l1, &1))
    :ets.delete(@tags, tag)

    # L2
    case Redis.command(["SMEMBERS", "vc:tag:" <> tag]) do
      {:ok, redis_keys} when is_list(redis_keys) and redis_keys != [] ->
        Redis.command(["DEL" | Enum.map(redis_keys, &("vc:" <> &1))])
        Redis.command(["DEL", "vc:tag:" <> tag])

      _ ->
        :ok
    end

    :ok
  end
```

Add the warn-once helper:
```elixir
  @warning_throttle_table :verscienta_cache_warning_throttle

  defp warn_once(key, msg) do
    ensure_table(@warning_throttle_table, [:named_table, :public, :set])
    now = monotonic_ms()

    case :ets.lookup(@warning_throttle_table, key) do
      [{^key, last}] when now - last < 60_000 ->
        :ok

      _ ->
        :ets.insert(@warning_throttle_table, {key, now})
        Logger.warning(msg)
    end
  end
```

- [ ] **Step 4: Failing test for L1-only mode (Redis disabled)**

Create `test/verscienta/cache/redis_disabled_test.exs`:
```elixir
defmodule Verscienta.Cache.RedisDisabledTest do
  use ExUnit.Case, async: false

  alias Verscienta.Cache
  alias Verscienta.Cache.Redis

  setup do
    Cache.flush()
    on_exit(&Cache.flush/0)
    :ok
  end

  test "Redis.enabled? returns false in test env" do
    refute Redis.enabled?()
  end

  test "Redis.command/1 returns {:error, :disabled} in test env" do
    assert Redis.command(["PING"]) == {:error, :disabled}
  end

  test "fetch/3 works with Redis disabled (L1-only)" do
    {:ok, 42} = Cache.fetch("k", [tags: ["a"]], fn -> {:ok, 42} end)
    assert Cache.get("k") == {:ok, 42}
    :ok = Cache.invalidate_tag("a")
    assert Cache.get("k") == :miss
  end
end
```

- [ ] **Step 5: Run all cache tests**

```bash
docker compose exec -e MIX_ENV=test app mix test test/verscienta/cache/
```
Expected: 21 tests, 0 failures (18 prior + 3 new).

- [ ] **Step 6: Verify and commit**

```bash
docker compose exec app mix format
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix credo --strict
```

```bash
git add lib/verscienta/cache.ex \
  lib/verscienta/cache/redis.ex \
  lib/verscienta/application.ex \
  test/verscienta/cache/redis_disabled_test.exs
git commit -m "$(cat <<'EOF'
feat(cache): L2 Redis backend + degraded L1-only mode

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Cross-node pub/sub — `Cache.Subscriber` + broadcast

**Files:**
- Create: `lib/verscienta/cache/subscriber.ex`
- Modify: `lib/verscienta/cache.ex` (broadcast on `delete`/`invalidate_tag`)
- Modify: `lib/verscienta/application.ex` (add Subscriber child)
- Test: `test/verscienta/cache/subscriber_test.exs` (new)

- [ ] **Step 1: Failing subscriber test**

Create `test/verscienta/cache/subscriber_test.exs`:
```elixir
defmodule Verscienta.Cache.SubscriberTest do
  use ExUnit.Case, async: false

  alias Verscienta.Cache

  setup do
    Cache.flush()
    on_exit(&Cache.flush/0)
    :ok
  end

  test "PubSub broadcast of {:cache_invalidate_keys, keys} deletes those L1 entries" do
    :ok = Cache.put("k1", 1)
    :ok = Cache.put("k2", 2)
    :ok = Cache.put("k3", 3)

    # Simulate a broadcast that another node would have sent.
    Phoenix.PubSub.broadcast(
      Verscienta.PubSub,
      "cache:invalidations",
      {:cache_invalidate_keys, ["k1", "k3"]}
    )

    # Give the Subscriber a moment to process.
    Process.sleep(30)

    assert Cache.get("k1") == :miss
    assert Cache.get("k2") == {:ok, 2}
    assert Cache.get("k3") == :miss
  end
end
```

- [ ] **Step 2: Create the Subscriber GenServer**

Create `lib/verscienta/cache/subscriber.ex`:
```elixir
defmodule Verscienta.Cache.Subscriber do
  @moduledoc """
  Subscribes to the `\"cache:invalidations\"` Phoenix.PubSub topic and
  clears matched L1 entries when other nodes (or this node) broadcast.

  Today (single-node) this is effectively a no-op duplicate of the local
  delete that triggered the broadcast — it just becomes useful when we
  configure `Phoenix.PubSub` with the Redis adapter for multi-node.
  """
  use GenServer

  @topic "cache:invalidations"

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def topic, do: @topic

  @impl true
  def init(_) do
    Phoenix.PubSub.subscribe(Verscienta.PubSub, @topic)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:cache_invalidate_keys, keys}, state) when is_list(keys) do
    table = Verscienta.Cache.l1_table()
    Enum.each(keys, &:ets.delete(table, &1))
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
```

- [ ] **Step 3: Broadcast from `delete/1` and `invalidate_tag/1`**

In `lib/verscienta/cache.ex`, modify `delete/1`:
```elixir
  def delete(key) when is_binary(key) do
    :ets.delete(@l1, key)
    _ = Redis.command(["DEL", redis_key(key)])
    broadcast([key])
    :ok
  end
```

And modify `invalidate_tag/1` to broadcast the union of L1 + L2 keys:
```elixir
  def invalidate_tag(tag) when is_binary(tag) do
    # L1
    l1_keys = :ets.lookup(@tags, tag) |> Enum.map(fn {^tag, key} -> key end)
    Enum.each(l1_keys, &:ets.delete(@l1, &1))
    :ets.delete(@tags, tag)

    # L2
    l2_keys =
      case Redis.command(["SMEMBERS", "vc:tag:" <> tag]) do
        {:ok, keys} when is_list(keys) -> keys
        _ -> []
      end

    if l2_keys != [] do
      Redis.command(["DEL" | Enum.map(l2_keys, &("vc:" <> &1))])
      Redis.command(["DEL", "vc:tag:" <> tag])
    end

    broadcast(Enum.uniq(l1_keys ++ l2_keys))
    :ok
  end
```

Add the broadcast helper:
```elixir
  defp broadcast([]), do: :ok

  defp broadcast(keys) when is_list(keys) do
    Phoenix.PubSub.broadcast(
      Verscienta.PubSub,
      Verscienta.Cache.Subscriber.topic(),
      {:cache_invalidate_keys, keys}
    )
  end
```

- [ ] **Step 4: Add Subscriber to the supervisor**

In `lib/verscienta/application.ex`, in the children list, after `Verscienta.Cache.Redis,` add:
```elixir
        Verscienta.Cache.Subscriber,
```

The final ordering of cache-related children is:
```
Verscienta.Cache,
Verscienta.Cache.LockSweeper,
Verscienta.Cache.Redis,
Verscienta.Cache.Subscriber,
```

- [ ] **Step 5: Run subscriber test**

```bash
docker compose exec -e MIX_ENV=test app mix test test/verscienta/cache/subscriber_test.exs
docker compose exec -e MIX_ENV=test app mix test test/verscienta/cache/
```
Expected: subscriber test passes; all 22 cache tests pass.

- [ ] **Step 6: Verify and commit**

```bash
docker compose exec app mix format
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix credo --strict
```

```bash
git add lib/verscienta/cache.ex \
  lib/verscienta/cache/subscriber.ex \
  lib/verscienta/application.ex \
  test/verscienta/cache/subscriber_test.exs
git commit -m "$(cat <<'EOF'
feat(cache): cross-node invalidation via Phoenix.PubSub Subscriber

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: DataCase auto-flush + check for regressions

**Files:**
- Modify: `test/support/data_case.ex` (add `Cache.flush()` to setup_sandbox on_exit)

- [ ] **Step 1: Inspect existing setup_sandbox**

```bash
docker compose exec app grep -n "setup_sandbox\|FunWithFlags" test/support/data_case.ex
```
Expected: the file has a `setup_sandbox/1` function with `on_exit` blocks for sandbox stop and FunWithFlags cache flush.

- [ ] **Step 2: Add Cache.flush() to the on_exit chain**

In `test/support/data_case.ex`, in `setup_sandbox/1`, add a new `on_exit` line next to the FunWithFlags one:
```elixir
    on_exit(fn -> Verscienta.Cache.flush() end)
```

- [ ] **Step 3: Run full suite — no regressions**

```bash
docker compose exec -e MIX_ENV=test app sh -c "mix ecto.drop -r Verscienta.Repo && mix ecto.create -r Verscienta.Repo && mix ash.migrate && mix test"
```
Expected: 0 failures. Total test count = prior count + 22 new cache tests.

- [ ] **Step 4: Verify and commit**

```bash
docker compose exec app mix format
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix credo --strict
```

```bash
git add test/support/data_case.ex
git commit -m "$(cat <<'EOF'
test(cache): flush Verscienta.Cache L1 between tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Migrate the leaderboard cache (delete old, switch new)

**Files:**
- Delete: `lib/verscienta/gamification/cache.ex`
- Delete: `test/verscienta/gamification/cache_test.exs`
- Modify: `lib/verscienta/gamification/leaderboards.ex` (swap `Verscienta.Gamification.Cache.fetch_or_compute/3` for `Verscienta.Cache.fetch/3`)
- Modify: `lib/verscienta/gamification/workers/leaderboard_snapshot_worker.ex` (call `Verscienta.Cache.invalidate_tag("leaderboards")` after each snapshot upsert)
- Modify: `lib/verscienta/application.ex` (remove `Verscienta.Gamification.Cache,`)

- [ ] **Step 1: Inspect current usage**

```bash
docker compose exec app grep -rn "Verscienta.Gamification.Cache" lib/ test/
```
Expected output identifies the call sites we need to swap.

- [ ] **Step 2: Migrate `Leaderboards.compute_live/3` (or the equivalent cached entry point)**

In `lib/verscienta/gamification/leaderboards.ex`, find the function that wraps `Cache.fetch_or_compute/3`. Replace the wrapper with `Verscienta.Cache.fetch/3`:

Old shape (typical):
```elixir
def some_cached_fn(scope, category, window) do
  key = {scope, category, window}
  Verscienta.Gamification.Cache.fetch_or_compute(key, fn ->
    {:ok, compute(scope, category, window)}
  end, ttl_ms: 60_000)
end
```

New shape:
```elixir
def some_cached_fn(scope, category, window) do
  key = "leaderboard:#{scope}:#{category || "global"}:#{window}"
  {:ok, value} =
    Verscienta.Cache.fetch(key, [ttl: 60_000, tags: ["leaderboards"]], fn ->
      {:ok, compute(scope, category, window)}
    end)
  value
end
```

Adapt exactly to whatever the existing function signature returned. If the existing call returned `{:ok, value}` (because `fetch_or_compute` does), keep that return shape. If it unwrapped, keep that.

- [ ] **Step 3: Add invalidation in the snapshot worker**

In `lib/verscienta/gamification/workers/leaderboard_snapshot_worker.ex`, find the `do_perform/1` body. After each successful `LeaderboardSnapshot.:upsert` call, add:
```elixir
Verscienta.Cache.invalidate_tag("leaderboards")
```
This complements (does NOT replace) the existing `Phoenix.PubSub.broadcast(Verscienta.PubSub, "leaderboards", ...)` that triggers LV re-fetch.

- [ ] **Step 4: Remove the old Cache child from supervisor**

In `lib/verscienta/application.ex`, in the children list, remove the line:
```elixir
        Verscienta.Gamification.Cache,
```

- [ ] **Step 5: Delete the old module and its test**

```bash
docker compose exec app rm lib/verscienta/gamification/cache.ex \
  test/verscienta/gamification/cache_test.exs
```

- [ ] **Step 6: Run gamification + cache tests — no regressions**

```bash
docker compose exec -e MIX_ENV=test app sh -c "mix ecto.drop -r Verscienta.Repo && mix ecto.create -r Verscienta.Repo && mix ash.migrate && mix test test/verscienta/gamification/ test/verscienta/cache/"
```
Expected: 0 failures. (The leaderboards tests should still pass — the cache abstraction is transparent.)

- [ ] **Step 7: Confirm no remaining references**

```bash
docker compose exec app grep -rn "Verscienta.Gamification.Cache" lib/ test/
```
Expected: no output.

- [ ] **Step 8: Verify and commit**

```bash
docker compose exec app mix format
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix credo --strict
docker compose exec -e MIX_ENV=test app mix test
```

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(cache): migrate leaderboard cache to Verscienta.Cache, delete Gamification.Cache

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Feed wiring (4 sites: trending, latest, category, group)

**Files:**
- Modify: `lib/verscienta/social.ex` (wrap `trending/1`)
- Modify: `lib/verscienta/content.ex` or wherever `Article.list_published/1`, `list_by_category/2`, `list_for_group/2` live
- Modify: `lib/verscienta/content/article/changes/` (add an after-action change that invalidates `articles:latest`, `articles:trending`, and matching category/group tags on `Article.:publish` / `:update` / `:destroy`)
- Test: `test/verscienta/content/feeds_cache_test.exs` (new)

- [ ] **Step 1: Failing feed-cache test**

Create `test/verscienta/content/feeds_cache_test.exs`:
```elixir
defmodule Verscienta.Content.FeedsCacheTest do
  use Verscienta.DataCase, async: false

  alias Verscienta.Accounts.User
  alias Verscienta.Cache
  alias Verscienta.Content.Article

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

  defp publish_article!(author, title) do
    a =
      Article
      |> Ash.Changeset.for_create(:create, %{
        title: title,
        blocks: [],
        category: :nutrition
      }, actor: author)
      |> Ash.create!()

    a
    |> Ash.Changeset.for_update(:publish, %{}, actor: author)
    |> Ash.update!()
  end

  test "list_published(page: 1) caches and is invalidated by a new publish" do
    author = user("alice")
    _a = publish_article!(author, "first")

    titles_before = Article.list_published(page: 1) |> Enum.map(& &1.title)
    assert "first" in titles_before

    # Second call should be served from L1 (verify via a direct cache lookup)
    assert {:ok, _} = Cache.get("feed:articles:latest:page=1")

    # Publishing a new article must invalidate the cached feed.
    _b = publish_article!(author, "second")
    assert Cache.get("feed:articles:latest:page=1") == :miss

    titles_after = Article.list_published(page: 1) |> Enum.map(& &1.title)
    assert "second" in titles_after
  end

  test "list_published(page: 2) does NOT cache" do
    author = user("alice")
    _ = publish_article!(author, "a")
    _ = Article.list_published(page: 2)
    assert Cache.get("feed:articles:latest:page=2") == :miss
  end
end
```

(If the `Article.list_published/1` signature doesn't accept `:page`, adapt the test to whatever the current pagination shape is. Discover via grep:
```bash
docker compose exec app grep -A 3 "def list_published\|def list_by_category\|def list_for_group" lib/verscienta/content.ex lib/verscienta/content/article.ex
```
)

- [ ] **Step 2: Wrap `Social.trending/1`**

In `lib/verscienta/social.ex`, locate the `trending/1` function (or `defdelegate trending`). Replace its body — or wrap the delegate target — with:
```elixir
def trending(opts \\ []) do
  limit = Keyword.get(opts, :limit, 20)
  key = "social:trending:limit=#{limit}"

  {:ok, items} =
    Verscienta.Cache.fetch(key, [ttl: 120_000, tags: ["articles:trending"]], fn ->
      {:ok, Verscienta.Social.Trending.list(opts)}
    end)

  items
end
```

If the existing function is a `defdelegate`, replace it with the explicit function above.

- [ ] **Step 3: Wrap `Article.list_published/1`** (page 1 only)

Find the existing `list_published/1`. Rename the current implementation to `do_list_published/1` (private). Add a new public `list_published/1`:
```elixir
def list_published(opts \\ []) do
  page = Keyword.get(opts, :page, 1)

  if page == 1 do
    key = "feed:articles:latest:page=1"

    {:ok, items} =
      Verscienta.Cache.fetch(key, [ttl: 60_000, tags: ["articles:latest"]], fn ->
        {:ok, do_list_published(opts)}
      end)

    items
  else
    do_list_published(opts)
  end
end
```

- [ ] **Step 4: Wrap `list_by_category/2`** (page 1 only)

Same pattern. Key: `"feed:articles:category:#{slug}:page=1"`. Tags: `["articles:category:#{slug}"]`. TTL: 60_000.

```elixir
def list_by_category(slug, opts \\ []) do
  page = Keyword.get(opts, :page, 1)

  if page == 1 do
    key = "feed:articles:category:#{slug}:page=1"
    tags = ["articles:category:#{slug}"]

    {:ok, items} =
      Verscienta.Cache.fetch(key, [ttl: 60_000, tags: tags], fn ->
        {:ok, do_list_by_category(slug, opts)}
      end)

    items
  else
    do_list_by_category(slug, opts)
  end
end
```

- [ ] **Step 5: Wrap `list_for_group/2`** (page 1 only)

Same pattern. Key: `"feed:articles:group:#{group_id}:page=1"`. Tags: `["articles:group:#{group_id}"]`. TTL: 60_000.

```elixir
def list_for_group(group_id, opts \\ []) do
  page = Keyword.get(opts, :page, 1)

  if page == 1 do
    key = "feed:articles:group:#{group_id}:page=1"
    tags = ["articles:group:#{group_id}"]

    {:ok, items} =
      Verscienta.Cache.fetch(key, [ttl: 60_000, tags: tags], fn ->
        {:ok, do_list_for_group(group_id, opts)}
      end)

    items
  else
    do_list_for_group(group_id, opts)
  end
end
```

- [ ] **Step 6: Add invalidation hooks on Article**

Find the Article resource at `lib/verscienta/content/article.ex`. On each of `:publish`, `:update`, `:destroy` actions, add an `after_action` change that invalidates the relevant tags:
```elixir
change after_action(fn _cs, article, _ctx ->
  try do
    Verscienta.Cache.invalidate_tag("articles:latest")
    Verscienta.Cache.invalidate_tag("articles:trending")
    Verscienta.Cache.invalidate_tag("articles:category:#{article.category}")

    if article.group_id do
      Verscienta.Cache.invalidate_tag("articles:group:#{article.group_id}")
    end
  rescue
    _ -> :ok
  end

  {:ok, article}
end)
```

If `Article.category` is an atom (e.g. `:nutrition`), the tag key uses `Atom.to_string/1`. Adapt:
```elixir
Verscienta.Cache.invalidate_tag("articles:category:#{article.category}")
```
Elixir's string interpolation handles atoms via `to_string/1`, which calls `Atom.to_string/1`.

- [ ] **Step 7: Run feed-cache + content tests**

```bash
docker compose exec -e MIX_ENV=test app sh -c "mix ecto.drop -r Verscienta.Repo && mix ecto.create -r Verscienta.Repo && mix ash.migrate && mix test test/verscienta/content/ test/verscienta_web/live/article_feed_live_test.exs"
```
Expected: feed-cache test passes; existing content + ArticleFeedLive tests still pass.

- [ ] **Step 8: Verify and commit**

```bash
docker compose exec app mix format
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix credo --strict
docker compose exec -e MIX_ENV=test app mix test
```

```bash
git add lib/verscienta/social.ex \
  lib/verscienta/content.ex \
  lib/verscienta/content/article.ex \
  test/verscienta/content/feeds_cache_test.exs
git commit -m "$(cat <<'EOF'
feat(cache): wire trending + 3 article feeds (page 1) through Verscienta.Cache

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Count wiring (4 categories) + invalidation hooks

**Files:**
- Create: `lib/verscienta/social/counts.ex` (follower, following, repost counts)
- Create: `lib/verscienta/engagement/counts.ex` (comment, reaction, bookmark counts per article)
- Create: `lib/verscienta/communities/counts.ex` (group member count)
- Modify: `lib/verscienta/social.ex` (delegate to `Social.Counts`)
- Modify: `lib/verscienta/engagement.ex` (delegate to `Engagement.Counts`)
- Modify: `lib/verscienta/communities.ex` (delegate to `Communities.Counts`)
- Modify the 6 resources for after-action invalidation: `Comment`, `Reaction`, `Bookmark`, `Repost`, `Follow`, `GroupMembership`
- Test: `test/verscienta/social/counts_cache_test.exs` (new)

- [ ] **Step 1: Failing counts-cache test**

Create `test/verscienta/social/counts_cache_test.exs`:
```elixir
defmodule Verscienta.Social.CountsCacheTest do
  use Verscienta.DataCase, async: false

  alias Verscienta.Accounts.User
  alias Verscienta.Cache
  alias Verscienta.Social
  alias Verscienta.Social.Counts
  alias Verscienta.Social.Follow

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

  test "follower_count is cached" do
    a = user("alice")

    assert Counts.follower_count(a.id) == 0
    assert {:ok, 0} = Cache.get("user:#{a.id}:follower_count")
  end

  test "creating a Follow invalidates user:<id>:counts" do
    a = user("alice")
    b = user("bob")

    # Prime the cache
    assert Counts.follower_count(a.id) == 0

    # Bob follows alice
    Follow
    |> Ash.Changeset.for_create(:create, %{target_type: :user, target_id: a.id}, actor: b)
    |> Ash.create!()

    # Cache should be invalidated
    assert Cache.get("user:#{a.id}:follower_count") == :miss

    # Next call recomputes
    assert Counts.follower_count(a.id) == 1
  end
end
```

(Adapt the `Follow.:create` accept attrs if Follow uses different field names — Task 4 of feature flags discovered that Follow is polymorphic with `target_type`/`target_id`.)

- [ ] **Step 2: Create `Verscienta.Social.Counts`**

Create `lib/verscienta/social/counts.ex`:
```elixir
defmodule Verscienta.Social.Counts do
  @moduledoc "Cached count helpers for Social-domain entities."

  require Ash.Query

  alias Verscienta.Cache
  alias Verscienta.Social.Follow
  alias Verscienta.Social.Repost

  @ttl 300_000

  def follower_count(user_id) do
    key = "user:#{user_id}:follower_count"

    {:ok, n} =
      Cache.fetch(key, [ttl: @ttl, tags: ["user:#{user_id}:counts"]], fn ->
        {:ok, do_follower_count(user_id)}
      end)

    n
  end

  def following_count(user_id) do
    key = "user:#{user_id}:following_count"

    {:ok, n} =
      Cache.fetch(key, [ttl: @ttl, tags: ["user:#{user_id}:counts"]], fn ->
        {:ok, do_following_count(user_id)}
      end)

    n
  end

  def repost_count(article_id) do
    key = "article:#{article_id}:repost_count"

    {:ok, n} =
      Cache.fetch(key, [ttl: @ttl, tags: ["article:#{article_id}:counts"]], fn ->
        {:ok, do_repost_count(article_id)}
      end)

    n
  end

  defp do_follower_count(user_id) do
    Follow
    |> Ash.Query.filter(target_type == :user and target_id == ^user_id)
    |> Ash.count!(authorize?: false)
  end

  defp do_following_count(user_id) do
    Follow
    |> Ash.Query.filter(follower_id == ^user_id)
    |> Ash.count!(authorize?: false)
  end

  defp do_repost_count(article_id) do
    Repost
    |> Ash.Query.filter(article_id == ^article_id)
    |> Ash.count!(authorize?: false)
  end
end
```

If `Ash.count!/2` doesn't exist on the installed Ash version, use `Ash.read!/2 |> length()`:
```elixir
defp do_follower_count(user_id) do
  Follow
  |> Ash.Query.filter(target_type == :user and target_id == ^user_id)
  |> Ash.read!(authorize?: false)
  |> length()
end
```

- [ ] **Step 3: Create `Verscienta.Engagement.Counts`**

Create `lib/verscienta/engagement/counts.ex`:
```elixir
defmodule Verscienta.Engagement.Counts do
  @moduledoc "Cached count helpers for Engagement-domain entities."

  require Ash.Query

  alias Verscienta.Cache
  alias Verscienta.Engagement.Bookmark
  alias Verscienta.Engagement.Comment
  alias Verscienta.Engagement.Reaction

  @ttl 300_000

  def comment_count(article_id) do
    key = "article:#{article_id}:comment_count"

    {:ok, n} =
      Cache.fetch(key, [ttl: @ttl, tags: ["article:#{article_id}:counts"]], fn ->
        {:ok, do_comment_count(article_id)}
      end)

    n
  end

  def reaction_count(article_id) do
    key = "article:#{article_id}:reaction_count"

    {:ok, n} =
      Cache.fetch(key, [ttl: @ttl, tags: ["article:#{article_id}:counts"]], fn ->
        {:ok, do_reaction_count(article_id)}
      end)

    n
  end

  def bookmark_count(article_id) do
    key = "article:#{article_id}:bookmark_count"

    {:ok, n} =
      Cache.fetch(key, [ttl: @ttl, tags: ["article:#{article_id}:counts"]], fn ->
        {:ok, do_bookmark_count(article_id)}
      end)

    n
  end

  defp do_comment_count(article_id) do
    Comment
    |> Ash.Query.filter(article_id == ^article_id)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp do_reaction_count(article_id) do
    Reaction
    |> Ash.Query.filter(article_id == ^article_id)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp do_bookmark_count(article_id) do
    Bookmark
    |> Ash.Query.filter(article_id == ^article_id)
    |> Ash.read!(authorize?: false)
    |> length()
  end
end
```

- [ ] **Step 4: Create `Verscienta.Communities.Counts`**

Create `lib/verscienta/communities/counts.ex`:
```elixir
defmodule Verscienta.Communities.Counts do
  @moduledoc "Cached count helpers for Communities-domain entities."

  require Ash.Query

  alias Verscienta.Cache
  alias Verscienta.Communities.GroupMembership

  @ttl 300_000

  def group_member_count(group_id) do
    key = "group:#{group_id}:member_count"

    {:ok, n} =
      Cache.fetch(key, [ttl: @ttl, tags: ["group:#{group_id}:counts"]], fn ->
        {:ok, do_group_member_count(group_id)}
      end)

    n
  end

  defp do_group_member_count(group_id) do
    GroupMembership
    |> Ash.Query.filter(group_id == ^group_id and status == :active)
    |> Ash.read!(authorize?: false)
    |> length()
  end
end
```

- [ ] **Step 5: Add invalidation hooks on the 6 resources**

For each resource, add `after_action` changes on `:create` (and `:destroy` where applicable) that invalidate the relevant tags. All wraps are best-effort (`try/rescue`).

In `lib/verscienta/social/follow.ex` `:create` action:
```elixir
change after_action(fn _cs, follow, _ctx ->
  try do
    Verscienta.Cache.invalidate_tag("user:#{follow.follower_id}:counts")
    if follow.target_type == :user do
      Verscienta.Cache.invalidate_tag("user:#{follow.target_id}:counts")
    end
  rescue
    _ -> :ok
  end
  {:ok, follow}
end)
```

In `lib/verscienta/social/repost.ex` `:create` action:
```elixir
change after_action(fn _cs, repost, _ctx ->
  try do
    Verscienta.Cache.invalidate_tag("article:#{repost.article_id}:counts")
    Verscienta.Cache.invalidate_tag("articles:trending")
  rescue
    _ -> :ok
  end
  {:ok, repost}
end)
```

In `lib/verscienta/engagement/comment.ex` `:create` (and `:destroy` / soft-delete actions):
```elixir
change after_action(fn _cs, comment, _ctx ->
  try do
    Verscienta.Cache.invalidate_tag("article:#{comment.article_id}:counts")
  rescue
    _ -> :ok
  end
  {:ok, comment}
end)
```

In `lib/verscienta/engagement/reaction.ex` — within the `:create` (and `:toggle`'s destroy path, if separate):
```elixir
change after_action(fn _cs, reaction, _ctx ->
  try do
    Verscienta.Cache.invalidate_tag("article:#{reaction.article_id}:counts")
  rescue
    _ -> :ok
  end
  {:ok, reaction}
end)
```

In `lib/verscienta/engagement/bookmark.ex` — within the `:create` (and `:destroy`):
```elixir
change after_action(fn _cs, bookmark, _ctx ->
  try do
    Verscienta.Cache.invalidate_tag("article:#{bookmark.article_id}:counts")
  rescue
    _ -> :ok
  end
  {:ok, bookmark}
end)
```

In `lib/verscienta/communities/group_membership.ex` — invalidate on both `:create` and the `:set_status` action (transitioning into or out of `:active` changes the count):
```elixir
change after_action(fn _cs, gm, _ctx ->
  try do
    Verscienta.Cache.invalidate_tag("group:#{gm.group_id}:counts")
  rescue
    _ -> :ok
  end
  {:ok, gm}
end)
```

- [ ] **Step 6: Run counts test + full suite**

```bash
docker compose exec -e MIX_ENV=test app mix test test/verscienta/social/counts_cache_test.exs
docker compose exec -e MIX_ENV=test app mix test
```
Expected: counts test passes; full suite has no regressions.

- [ ] **Step 7: Verify and commit**

```bash
docker compose exec app mix format
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix credo --strict
```

```bash
git add lib/verscienta/social/counts.ex \
  lib/verscienta/engagement/counts.ex \
  lib/verscienta/communities/counts.ex \
  lib/verscienta/social/follow.ex \
  lib/verscienta/social/repost.ex \
  lib/verscienta/engagement/comment.ex \
  lib/verscienta/engagement/reaction.ex \
  lib/verscienta/engagement/bookmark.ex \
  lib/verscienta/communities/group_membership.ex \
  test/verscienta/social/counts_cache_test.exs
git commit -m "$(cat <<'EOF'
feat(cache): wire 4 count categories + invalidation hooks on 6 resources

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: Final verification + todo + merge prep

**Files:**
- Modify: `docs/todo.md`

- [ ] **Step 1: Full reset + full test suite**

```bash
docker compose exec -e MIX_ENV=test app sh -c "mix ecto.drop -r Verscienta.Repo && mix ecto.create -r Verscienta.Repo && mix ash.migrate && mix test"
```
Expected: 0 failures.

- [ ] **Step 2: Manual smoke against dev DB with Redis**

Start the dev compose stack with the (already-running) Redis service:
```bash
docker compose up -d redis
docker compose exec app iex -S mix
```
In IEx:
```elixir
Verscienta.Cache.put("smoke", :hello, ttl: 60_000)
Verscienta.Cache.get("smoke")
# {:ok, :hello}
Verscienta.Cache.delete("smoke")
Verscienta.Cache.Redis.command(["PING"])
# {:ok, "PONG"}
```
Expected: all three calls succeed. Exit IEx.

If Redis ping fails or the `command` returns `{:error, :exit}`, double-check `REDIS_URL` in `.env` and that the redis service is up.

- [ ] **Step 3: Full CI gates**

```bash
docker compose exec app mix format --check-formatted
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix credo --strict
docker compose exec app mix dialyzer
```
Expected: all clean (the `.dialyzer_ignore.exs` already covers the pre-existing block_renderer warning).

- [ ] **Step 4: Update `docs/todo.md`**

In the `### Phase 2 Cross-cutting` block, change:
```markdown
- [ ] Caching layer (Redis + ETS) for feeds, counts, leaderboards.
```
to:
```markdown
- [x] Caching layer (Redis + ETS) for feeds, counts, leaderboards.
```

- [ ] **Step 5: Commit todo update**

```bash
git add docs/todo.md
git commit -m "$(cat <<'EOF'
docs: mark caching layer subsystem complete

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
git rev-parse --short HEAD
```

- [ ] **Step 6: Summarize the branch**

```bash
git log --oneline main..HEAD
git diff --stat main..HEAD
```
Paste the totals.

- [ ] **Step 7: STOP — do not push, do not merge**

The user will push and open the PR.

---

## Spec coverage map

| Spec section | Implementing tasks |
|--------------|--------------------|
| §1 File structure | All tasks |
| §2 Public API (`fetch`, `get`, `put`, `delete`, `invalidate_tag(s)`, `flush`) | Tasks 1, 2, 3, 6, 7 |
| §3 L1 ETS tables + single-flight + LockSweeper | Tasks 1, 2, 4 |
| §4 L2 Redis pool, encoding, PubSub, failure handling | Tasks 6, 7 |
| §5 Hot-path wiring (feeds + counts), leaderboard migration, testing | Tasks 9, 10, 11 |
| Telemetry | Task 5 |
| Test isolation (DataCase flush) | Task 8 |
| Definition of Done | Task 12 |
