# Caching Layer Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-04
**Status:** Approved
**Phase:** 2 — Social & Gamification (cross-cutting)
**Depends on:** Phase 0; Phoenix.PubSub (`Verscienta.PubSub`); Redis configured in `runtime.exs`; existing hot paths in Social, Content, Engagement, Communities, Gamification.

## Goal

Ship a two-tier cache (ETS L1 + Redis L2) with tag-based invalidation, single-flight loader coordination, and cross-node pub/sub. Wire it into 4 feed reads, 4 count categories, and the existing leaderboard cache (which is migrated into the new module and deleted).

## Decisions

| Decision | Choice |
|----------|--------|
| Architecture | **Single `Verscienta.Cache` module** with 3 ETS tables + Redix pool + Phoenix.PubSub subscriber |
| Tiers | **L1 = ETS (microseconds), L2 = Redis (sub-ms)** |
| Invalidation | **Tag-based + TTL ceiling**; tag→keys index in both ETS and Redis |
| Cross-node | **Phoenix.PubSub topic `"cache:invalidations"`** — works locally today, scales to multi-node when we configure `Phoenix.PubSub.Redis` adapter (no cache code change) |
| Stampede | **Single-flight via `:ets.insert_new/2` lock + 5ms-poll wait, 5s timeout** |
| Encoding | **`:erlang.term_to_binary/2`** (compressed >1KB) + `binary_to_term/2 [:safe]` |
| Failure mode | Redis down → **degrade to L1-only**, log rate-limited warning; never raise |
| Keys | Strings, colon-namespaced (e.g. `"social:trending:limit=20"`, `"article:<id>:counts"`); Redis keys additionally prefixed `vc:` |
| Loader contract | 0-arity returning `{:ok, v}` (cached) or `{:error, _}` (passed through, NOT cached); anything else raises |
| Counter caches | Cache the COUNT() result; no separate increment counters in v1 |
| Public API | `fetch/3, put/4, get/1, delete/1, invalidate_tag/1, invalidate_tags/1, flush/0` |
| Test env | `redis_enabled: false` — ETS only; DataCase clears L1 between tests |
| Telemetry | `[:verscienta, :cache, :fetch]` with `source: :l1 \| :l2 \| :loader` |

## Section 1: File structure

**New files (4):**
- `lib/verscienta/cache.ex` — single public module, ~300 lines.
- `lib/verscienta/cache/redis.ex` — Redix supervisor child + helpers.
- `lib/verscienta/cache/subscriber.ex` — GenServer subscribing to `"cache:invalidations"`.
- `lib/verscienta/cache/lock_sweeper.ex` — GenServer that prunes stale lock rows every 30s.

**Modified files (~10):**
- `mix.exs` — add `{:redix, "~> 1.5"}`.
- `config/config.exs` — `config :verscienta, Verscienta.Cache, redis_enabled: true, default_ttl: 60_000, redis_pool_size: 5`.
- `config/test.exs` — override `redis_enabled: false`.
- `lib/verscienta/application.ex` — start 4 children (`Cache`, `Cache.LockSweeper`, `Cache.Redis` when enabled, `Cache.Subscriber`).
- `lib/verscienta/social.ex` — wrap `trending/1`; add `follower_count/1`, `following_count/1`, `repost_count/1` calls through Cache.
- `lib/verscienta/content.ex` (or `Article` resource module) — wrap `list_published/1`, `list_by_category/2`, `list_for_group/2` (page 1 only).
- `lib/verscienta/engagement.ex` — `comment_count/1`, `reaction_count/1`, `bookmark_count/1` through Cache.
- `lib/verscienta/communities.ex` — `group_member_count/1` through Cache.
- `lib/verscienta/gamification/leaderboards.ex` — swap `Verscienta.Gamification.Cache` for `Verscienta.Cache`.
- `lib/verscienta/gamification/workers/leaderboard_snapshot_worker.ex` — call `Verscienta.Cache.invalidate_tag("leaderboards")` after each snapshot upsert.
- After-action hooks (7 resources) for invalidation: `Article`, `Comment`, `Reaction`, `Bookmark`, `Repost`, `Follow`, `GroupMembership`.

**Deleted files (2):**
- `lib/verscienta/gamification/cache.ex` — replaced.
- `test/verscienta/gamification/cache_test.exs` — merged into `test/verscienta/cache_test.exs`.

**Test files (3):**
- `test/verscienta/cache_test.exs` — unit tests for the Cache module.
- `test/verscienta/social/counts_cache_test.exs` — integration test for follower count caching + invalidation.
- `test/verscienta/content/feeds_cache_test.exs` — integration test for latest-articles caching + invalidation on publish.

## Section 2: Public API

```elixir
defmodule Verscienta.Cache do
  @doc """
  Look up `key`. On hit return `{:ok, value}`. On miss, run `loader.()`:
  if it returns `{:ok, v}`, cache + return `{:ok, v}`; if it returns
  `{:error, reason}`, return `{:error, reason}` WITHOUT caching.

  Options:
    * `:ttl` — milliseconds (default from config, 60_000).
    * `:tags` — list of tag strings for invalidation indexing.
    * `:redis` — when `false`, skip L2 entirely (rare; intended for
      callers who know their result is expensive to serialize).
  """
  @spec fetch(String.t(), keyword(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def fetch(key, opts \\ [], loader)

  @spec put(String.t(), term(), keyword()) :: :ok
  def put(key, value, opts \\ [])

  @spec get(String.t()) :: {:ok, term()} | :miss
  def get(key)

  @spec delete(String.t()) :: :ok
  def delete(key)

  @spec invalidate_tag(String.t()) :: :ok
  def invalidate_tag(tag)

  @spec invalidate_tags([String.t()]) :: :ok
  def invalidate_tags(tags)

  @spec flush() :: :ok
  def flush
end
```

**Key/tag conventions:**
- Keys: `"<domain>:<subject>:<qualifier>"`. Examples: `"social:trending:limit=20"`, `"feed:articles:category:nutrition:page=1"`, `"user:<uuid>:follower_count"`.
- Tags: coarser groupings. Examples: `"articles:trending"`, `"articles:latest"`, `"articles:category:nutrition"`, `"user:<uuid>:counts"`, `"article:<uuid>:counts"`, `"leaderboards"`.

**Loader contract:**
- `{:ok, value}` → cached + `fetch` returns `{:ok, value}`.
- `{:error, reason}` → NOT cached; `fetch` returns `{:error, reason}`.
- Any other shape → `raise ArgumentError`. Catches accidental return of bare values.

**Caller pattern** (uniform across all callers):
```elixir
{:ok, items} = Verscienta.Cache.fetch(key, opts, fn ->
  {:ok, load_from_db()}
end)
```

**Failure mode (Redis down):**
- `fetch` miss + Redis unreachable → run loader, write L1 only, return value. Log rate-limited warning.
- `put` Redis unreachable → write L1 only. Log warning.
- `invalidate_tag` Redis unreachable → delete L1 entries, log warning, **skip PubSub broadcast** (other nodes will serve stale data up to TTL).
- Connection pool exhausted → same as unreachable.

**Telemetry:**
- Event `[:verscienta, :cache, :fetch]`.
- Measurements `%{duration_native: integer}`.
- Metadata `%{key: String.t(), tags: [String.t()], source: :l1 | :l2 | :loader}`.

## Section 3: L1 (ETS), single-flight, tag index

**Three named ETS tables**, created at boot by `Verscienta.Cache.start_link/1`:

1. `:verscienta_cache_l1` — `{key, value, expires_at_ms}`. `:named_table, :public, :set, read_concurrency: true, write_concurrency: true`. Owner: the calling supervisor process.
2. `:verscienta_cache_tags` — `{tag, key}`. `:named_table, :public, :bag, write_concurrency: true`. One row per tag→key pairing; `invalidate_tag/1` looks up all matching rows, then deletes the keyed entries from L1 and the tag rows themselves.
3. `:verscienta_cache_locks` — `{key, owner_pid, monitor_ref, inserted_at_ms}`. `:named_table, :public, :set, write_concurrency: true`. Used for single-flight coordination.

**ETS lifecycle:** `start_link/1` creates the tables if they don't exist and returns `:ignore`. The supervisor owns them; if it dies they die and rebuild on restart. Tables survive any worker churn.

**Single-flight via `:ets.insert_new/2`:**

```elixir
defp fetch_with_lock(key, loader, opts) do
  ref = make_ref()
  case :ets.insert_new(:verscienta_cache_locks, {key, self(), ref, monotonic_ms()}) do
    true ->
      try do
        case loader.() do
          {:ok, value} -> store(key, value, opts); {:ok, value}
          {:error, _} = err -> err
          other -> raise ArgumentError, "loader returned #{inspect(other)}"
        end
      after
        :ets.delete(:verscienta_cache_locks, key)
      end

    false ->
      wait_for_fill(key, _deadline_ms = monotonic_ms() + 5_000)
  end
end

defp wait_for_fill(key, deadline) do
  case lookup_l1(key) do
    {:ok, v} -> {:ok, v}
    :miss ->
      if monotonic_ms() < deadline do
        Process.sleep(5)
        wait_for_fill(key, deadline)
      else
        # Lock-holder may have crashed; sweeper will clean up. Run loader ourselves.
        {:timeout, :loader_starved}
      end
  end
end
```

On timeout we run the loader anyway (best-effort, no deadlock).

**Lock sweeper.** `Verscienta.Cache.LockSweeper` is a small GenServer that runs every 30 seconds:
```elixir
def handle_info(:sweep, state) do
  now = monotonic_ms()
  for {key, pid, _ref, inserted_at} <- :ets.tab2list(:verscienta_cache_locks) do
    if not Process.alive?(pid) or now - inserted_at > 30_000 do
      :ets.delete(:verscienta_cache_locks, key)
    end
  end
  Process.send_after(self(), :sweep, 30_000)
  {:noreply, state}
end
```

**Atomicity caveat.** The tag index can fall briefly out of sync (e.g. crash between L1 insert and tag insert). The worst case is a stale entry an invalidation misses. The TTL ceiling catches it. Documented behavior.

**Memory.** No size cap in v1. Estimated upper bound at current load: ~305MB (10k feed entries × 30KB + 100k counts × 50B). When we approach that we'll add LRU eviction.

## Section 4: L2 (Redis), pub/sub, failure handling

**Redix supervisor.** `Verscienta.Cache.Redis` supervises a pool of 5 `Redix` connections. Pool size 5 in dev/prod, 0 in test. Round-robin connection picking via `:rand.uniform(5)`. URL from `System.get_env("REDIS_URL")`.

```elixir
defmodule Verscienta.Cache.Redis do
  def child_spec(_) do
    Supervisor.child_spec(
      {Supervisor,
       children: pool_children(),
       strategy: :one_for_one,
       name: __MODULE__},
      id: __MODULE__
    )
  end

  defp pool_children do
    if Application.get_env(:verscienta, Verscienta.Cache, [])[:redis_enabled] do
      size = Application.get_env(:verscienta, Verscienta.Cache, [])[:redis_pool_size] || 5
      url = Application.get_env(:verscienta, :redis_url)
      for i <- 0..(size - 1), do: {Redix, name: name(i), uri: url}
    else
      []
    end
  end

  def name(i), do: :"verscienta_cache_redix_#{i}"

  def command(args), do: command(args, :rand.uniform(pool_size()) - 1)
  defp command(args, i), do: Redix.command(name(i), args)
  defp pool_size, do: Application.get_env(:verscienta, Verscienta.Cache, [])[:redis_pool_size] || 5
end
```

`command/1` wraps every Redis call. On `{:error, _}` from `Redix.command` the calling code logs and falls back.

**Encoding.**
- Encode: `:erlang.term_to_binary(value, [:compressed])` — `:compressed` (level 6) only kicks in for terms > ~1KB; small terms pass through uncompressed.
- Decode: `:erlang.binary_to_term(binary, [:safe])`. The `:safe` flag prevents arbitrary atom creation from a poisoned cache entry.

**Keys.** All Redis keys prefixed `vc:`. Tag→keys index uses Redis Sets at `vc:tag:<tag>`.

**Write path (put):**
```redis
SET vc:<key> <encoded> EX <ttl_seconds>
SADD vc:tag:<tag1> <key>
SADD vc:tag:<tag2> <key>
EXPIRE vc:tag:<tag1> <ttl_seconds + 3600>   -- tag index outlives entries by an hour
```

**Invalidate path (invalidate_tag):**
```redis
SMEMBERS vc:tag:<tag>     -> [key1, key2, ...]
DEL vc:<key1> vc:<key2> ...
DEL vc:tag:<tag>
```
Then broadcast `{:cache_invalidate_keys, [key1, key2, ...]}` on Phoenix.PubSub topic `"cache:invalidations"`.

**Cross-node pub/sub via `Verscienta.Cache.Subscriber`** (GenServer):
```elixir
def init(_) do
  Phoenix.PubSub.subscribe(Verscienta.PubSub, "cache:invalidations")
  {:ok, %{}}
end

def handle_info({:cache_invalidate_keys, keys}, state) do
  Enum.each(keys, &delete_l1_only/1)
  {:noreply, state}
end
```

Today (single-node) the Subscriber receives messages from the same node that broadcast them. That's fine — it's a no-op duplicate. When we go multi-node we configure `Phoenix.PubSub` with the Redis adapter and the broadcast becomes cross-node for free.

**Failure modes (detailed):**

| Path | Redis down | L1-only mode behavior |
|------|------------|----------------------|
| `fetch` hit in L1 | n/a | normal fast path |
| `fetch` miss in L1 | skip L2 lookup | run loader, write L1 only, log rate-limited warning |
| `put` | skip Redis | write L1 only, log warning |
| `delete` | skip Redis | delete L1, broadcast PubSub (other nodes' L1 still gets cleared) |
| `invalidate_tag` | skip Redis, skip broadcast | delete local L1 entries, log warning |
| `Redix.command` returns error | per-op fallback as above | log rate-limited |

**Rate-limited warning.** We use a small ETS sentinel (`:verscienta_cache_warning_throttle`) keyed by `:redis_down`. Each warning checks the sentinel timestamp; logs only if >60s elapsed. Cheap, no GenServer needed.

## Section 5: Hot-path wiring, leaderboard migration, testing

### Feed wiring (4 sites)

`lib/verscienta/social.ex`:
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

`lib/verscienta/content.ex` (or `Article.list_published/1` — pick whichever is the public surface):
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

`list_by_category/2` and `list_for_group/2` follow the same shape with keys/tags `"feed:articles:category:#{slug}:page=1"` / `"articles:category:#{slug}"` and `"feed:articles:group:#{id}:page=1"` / `"articles:group:#{id}"`. Page-1 only — paginated tails skip the cache.

### Count wiring (4 categories)

A `Counts` helper per domain. Example for Social:
```elixir
defmodule Verscienta.Social.Counts do
  def follower_count(user_id) do
    key = "user:#{user_id}:follower_count"
    {:ok, n} =
      Verscienta.Cache.fetch(key, [ttl: 300_000, tags: ["user:#{user_id}:counts"]], fn ->
        {:ok, do_follower_count(user_id)}
      end)
    n
  end

  def following_count(user_id), do: ... # same shape, key "user:#{user_id}:following_count"
  def repost_count(article_id), do: ... # tags: ["article:#{article_id}:counts"]
end
```

Mirror for `Engagement.Counts.{comment_count, reaction_count, bookmark_count}` and `Communities.Counts.group_member_count`.

### Invalidation hooks (7 resources)

Each as a small `after_action` change. Pattern:
```elixir
change after_action(fn _cs, follow, _ctx ->
  try do
    Verscienta.Cache.invalidate_tag("user:#{follow.follower_id}:counts")
    Verscienta.Cache.invalidate_tag("user:#{follow.followed_id}:counts")
  rescue
    _ -> :ok
  end
  {:ok, follow}
end)
```

Best-effort `try/rescue` — a Cache outage must not roll back the underlying write.

| Resource | Invalidated tags |
|----------|------------------|
| `Article.:publish` / `:update` / `:destroy` | `articles:latest`, `articles:trending`, `articles:category:<slug>`, `articles:group:<id>` (if grouped), `article:<id>:counts` |
| `Comment.:create` / `:destroy` | `article:<article_id>:counts` |
| `Reaction.:create` / `:destroy` | `article:<article_id>:counts` |
| `Bookmark.:create` / `:destroy` | `article:<article_id>:counts` |
| `Repost.:create` / `:destroy` | `article:<article_id>:counts`, `articles:trending` |
| `Follow.:create` / `:destroy` | `user:<follower_id>:counts`, `user:<followed_id>:counts` |
| `GroupMembership` state→`:active` / `:active`→other | `group:<id>:counts`, `articles:group:<id>` |

### Leaderboard migration

1. Delete `lib/verscienta/gamification/cache.ex` and `test/verscienta/gamification/cache_test.exs`.
2. In `lib/verscienta/gamification/leaderboards.ex`, replace the old `Cache.fetch_or_compute/3` calls with `Verscienta.Cache.fetch/3`. Key: `"leaderboard:#{scope}:#{category || "global"}:#{window}"`. Tag: `"leaderboards"`. TTL: 60_000 (unchanged).
3. In `lib/verscienta/gamification/workers/leaderboard_snapshot_worker.ex`, after each successful `LeaderboardSnapshot.:upsert`, call `Verscienta.Cache.invalidate_tag("leaderboards")`. Keep the existing `Phoenix.PubSub.broadcast(Verscienta.PubSub, "leaderboards", {:snapshot_written, ...})` for LV re-fetch triggering.
4. Update `lib/verscienta_web/live/leaderboard_live.ex` if it references `Verscienta.Gamification.Cache` directly — it should go through `Leaderboards.compute/4` which uses the new Cache transparently.

### Application supervisor

In `lib/verscienta/application.ex` children list, add in order:
```elixir
Verscienta.Cache,
Verscienta.Cache.LockSweeper,
Verscienta.Cache.Redis,        # no-op when redis_enabled: false
Verscienta.Cache.Subscriber
```

### Testing

**`test/verscienta/cache_test.exs`** — unit tests:
1. `fetch/3` returns cached value on hit; runs loader on miss; respects TTL (Process.sleep > TTL → next call re-runs loader).
2. `fetch/3` with `tags:` writes to the tag index; `invalidate_tag/1` deletes matching keys.
3. `delete/1` removes a single key.
4. **Single-flight:** start 10 Tasks concurrently calling `fetch` with the same key + slow loader (Process.sleep 100). Use `:counters.new(1, [:atomics])` inside the loader. Assert counter == 1.
5. Loader returning `{:error, :foo}` propagates without writing to L1.
6. Loader returning a bare value raises `ArgumentError`.
7. `flush/0` empties L1.
8. Telemetry: attach a handler, exercise hit + miss, assert `:source` metadata is `:l1` then `:loader`.

**`test/verscienta/social/counts_cache_test.exs`** — integration:
1. `Counts.follower_count(user_id)` caches the result (second call doesn't hit Postgres — verify via telemetry source `:l1`).
2. Creating a `Follow` after the cache fills invalidates and the next call recomputes.

**`test/verscienta/content/feeds_cache_test.exs`** — integration:
1. `Article.list_published(page: 1)` caches.
2. Publishing a new article invalidates `articles:latest` and the next call sees the new article.
3. `list_published(page: 2)` does NOT cache (no key written).

**Test isolation.** In `test/support/data_case.ex` `setup_sandbox/1`, add:
```elixir
on_exit(fn -> Verscienta.Cache.flush() end)
```
Between tests the L1 starts empty. Redis is `redis_enabled: false` so L2 is a no-op.

**Existing tests.** Should pass without modification — the cache is transparent on a hit, and writes invalidate. The leaderboards tests verify the migration is clean.

### Gates

Existing CI: `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test`, `mix dialyzer`.

## Out of scope (deferred)

- LRU / size-bounded eviction.
- Per-key TTL variance / jitter to spread expiry.
- Probabilistic early expiration.
- Per-user feed caching (following feed, activity feed).
- Counter caches as durable increments.
- Redis cluster / sharding.
- Redis pub/sub for invalidation (we use Phoenix.PubSub).
- Cache key schema versioning.
- Admin LV to introspect cache state.

## Definition of Done

- `Verscienta.Cache` with `fetch/3, put/4, get/1, delete/1, invalidate_tag/1, invalidate_tags/1, flush/0`.
- Redix dep installed; `Cache.Redis` supervisor running 5-connection pool (skipped in test).
- 3 ETS tables created at boot.
- Single-flight: concurrent fetches for the same key produce 1 loader invocation.
- `Cache.LockSweeper` prunes stale lock rows every 30s.
- Phoenix.PubSub `"cache:invalidations"` topic carries cross-node invalidations; `Cache.Subscriber` clears local L1 on receipt.
- 4 feed sites wired (trending, latest page 1, category page 1, group page 1).
- 4 count categories wired through `Counts` helpers per domain.
- After-action invalidation hooks on the 7 resources.
- Old `Verscienta.Gamification.Cache` deleted; leaderboards migrated to `Verscienta.Cache`.
- Telemetry event emitted per fetch with `source: :l1 | :l2 | :loader`.
- All new tests pass; existing tests pass without modification.
- CI gates green; dialyzer clean.
