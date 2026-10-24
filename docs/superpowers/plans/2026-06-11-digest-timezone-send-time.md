# Digest Per-User-Timezone Send-Time Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Send each user's digest at a configured local hour (08:00 in their own IANA timezone) instead of fixed 13:00 UTC — by making the cron hourly and adding an in-Elixir local-hour filter to `Digests.due_user_ids/2`.

**Architecture:** Config holds `send_hour` (08) + `weekly_weekday` (Monday). The two digest cron entries fire hourly. `due_user_ids/2` SQL-filters by frequency + last-sent cutoff (now selecting `:timezone`), then filters in Elixir to users whose local clock reads the target hour (and weekday for weekly). The existing cutoff still prevents double-sends.

**Tech Stack:** Elixir, Ash 3, Oban (cron), `DateTime.shift_zone` + the registered Tz database, ExUnit + `Verscienta.Support.Factory` + `Oban.Testing`.

**Spec:** `docs/superpowers/specs/2026-06-11-digest-timezone-send-time-design.md`

**Conventions:**
- All `mix` runs inside Docker: `docker compose exec app mix ...`.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Branch: `phase-3-digest-timezone`. `git checkout phase-3-digest-timezone` first.
- **`docs/todo.md` has an unrelated uncommitted user edit (a Monetization billing-provider line). Leave it untouched; never stage/revert it. Stage only your own files in every commit.**

---

### Task 1: Hourly cron + `due_user_ids/2` local-hour filter

**Files:**
- Modify: `config/config.exs`
- Modify: `lib/verscienta/digests.ex`
- Test (create): `test/verscienta/digests/due_send_time_test.exs`
- Test (modify): `test/verscienta/digests_test.exs` (the existing `due_user_ids` test)
- Test (modify): `test/verscienta/digests/workers/enqueue_digests_worker_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/digests/due_send_time_test.exs`:

```elixir
defmodule Verscienta.Digests.DueSendTimeTest do
  use Verscienta.DataCase, async: false

  import Verscienta.Support.Factory, only: [user: 1]

  alias Verscienta.Digests

  # 2026-01-12 is a Monday. In January, America/New_York is EST (UTC-5):
  #   13:00Z → 08:00 EST (Mon);  Asia/Tokyo (UTC+9) → 22:00 (Mon).
  @monday_13z ~U[2026-01-12 13:00:00Z]
  @monday_08z ~U[2026-01-12 08:00:00Z]
  @tuesday_13z ~U[2026-01-13 13:00:00Z]

  # Set frequency (+ optional timezone / last_digest_at) by forcing attributes on
  # the :set_digest_frequency action (no timezone validation runs there, so a
  # deliberately-bad tz can be seeded).
  defp prep(name, freq, tz, last_at \\ nil) do
    user(name)
    |> Ash.Changeset.for_update(:set_digest_frequency, %{digest_frequency: freq}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:timezone, tz)
    |> then(fn cs ->
      if last_at, do: Ash.Changeset.force_change_attribute(cs, :last_digest_at, last_at), else: cs
    end)
    |> Ash.update!(authorize?: false)
  end

  test "daily: matches only users whose local hour == send_hour (8)" do
    ny = prep("dst_ny", :daily, "America/New_York")
    tokyo = prep("dst_tokyo", :daily, "Asia/Tokyo")

    ids = Digests.due_user_ids(:daily, @monday_13z)
    assert ny.id in ids
    refute tokyo.id in ids
  end

  test "Etc/UTC user matches at the UTC send_hour" do
    utc = prep("dst_utc", :daily, "Etc/UTC")

    assert utc.id in Digests.due_user_ids(:daily, @monday_08z)
    refute utc.id in Digests.due_user_ids(:daily, @monday_13z)
  end

  test "a recently-sent user is excluded even in a matching tz" do
    recent = prep("dst_recent", :daily, "America/New_York", DateTime.add(@monday_13z, -3600, :second))
    old = prep("dst_old", :daily, "America/New_York", DateTime.add(@monday_13z, -25 * 3600, :second))

    ids = Digests.due_user_ids(:daily, @monday_13z)
    refute recent.id in ids
    assert old.id in ids
  end

  test "weekly: matches only at send_hour on the weekly weekday (Monday)" do
    u = prep("dst_weekly", :weekly, "America/New_York")

    assert u.id in Digests.due_user_ids(:weekly, @monday_13z)
    # Tuesday 13:00Z → local Tue 08:00 — hour matches, weekday (2) != Monday (1)
    refute u.id in Digests.due_user_ids(:weekly, @tuesday_13z)
  end

  test "a nil/garbage timezone falls back to UTC" do
    bad = prep("dst_bad", :daily, "Not/AZone")

    assert bad.id in Digests.due_user_ids(:daily, @monday_08z)
    refute bad.id in Digests.due_user_ids(:daily, @monday_13z)
  end

  test "send_hour config override shifts who matches" do
    ny = prep("dst_ny2", :daily, "America/New_York")
    tokyo = prep("dst_tokyo2", :daily, "Asia/Tokyo")

    prev = Application.get_env(:verscienta, Verscienta.Digests, [])
    Application.put_env(:verscienta, Verscienta.Digests, Keyword.put(prev, :send_hour, 22))
    on_exit(fn -> Application.put_env(:verscienta, Verscienta.Digests, prev) end)

    ids = Digests.due_user_ids(:daily, @monday_13z)
    assert tokyo.id in ids
    refute ny.id in ids
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec app mix test test/verscienta/digests/due_send_time_test.exs`
Expected: FAIL — `due_user_ids/2` doesn't exist (current arity is 1) and there's no local-hour filter.

- [ ] **Step 3: Add the config**

In `config/config.exs`, add (anywhere in the base config, e.g. near other `config :verscienta, ...` blocks):

```elixir
config :verscienta, Verscienta.Digests, send_hour: 8, weekly_weekday: 1
```

And change the two digest cron entries (currently `{"0 13 * * *", …, "daily"}` and `{"0 13 * * 1", …, "weekly"}`) to fire **hourly**:

```elixir
      {"0 * * * *", Verscienta.Digests.Workers.EnqueueDigestsWorker,
       args: %{"frequency" => "daily"}},
      {"0 * * * *", Verscienta.Digests.Workers.EnqueueDigestsWorker,
       args: %{"frequency" => "weekly"}}
```

- [ ] **Step 4: Implement the local-hour filter in `due_user_ids`**

In `lib/verscienta/digests.ex`, add module attributes near the top:

```elixir
  @default_send_hour 8
  @default_weekly_weekday 1
```

Replace `due_user_ids/1` and `due_cutoff/1` with `due_user_ids/2` + `due_cutoff/2` + the local-time helpers:

```elixir
  @doc """
  User ids whose digest is due for `frequency` at `now` (default `DateTime.utc_now()`):
  matched by frequency + last-sent cutoff, then by the user's *local* clock reading
  the configured `send_hour` (and, for `:weekly`, the configured `weekly_weekday`).
  """
  def due_user_ids(frequency, now \\ DateTime.utc_now()) when frequency in [:daily, :weekly] do
    cutoff = due_cutoff(frequency, now)

    User
    |> Ash.Query.filter(
      digest_frequency == ^frequency and (is_nil(last_digest_at) or last_digest_at < ^cutoff)
    )
    |> Ash.Query.select([:id, :timezone])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&local_send_time?(&1, frequency, now))
    |> Enum.map(& &1.id)
  end

  # A bad/unshiftable timezone falls back to UTC so the user is never stranded.
  defp local_send_time?(%{timezone: tz}, frequency, now) do
    local =
      case DateTime.shift_zone(now, to_string(tz || "Etc/UTC")) do
        {:ok, dt} -> dt
        {:error, _} -> DateTime.shift_zone!(now, "Etc/UTC")
      end

    local.hour == send_hour() and
      (frequency == :daily or Date.day_of_week(local) == weekly_weekday())
  end

  defp due_cutoff(:daily, now), do: DateTime.add(now, -20 * 3600, :second)
  defp due_cutoff(:weekly, now), do: DateTime.add(now, -6 * 86_400, :second)

  defp send_hour, do: digest_config(:send_hour, @default_send_hour)
  defp weekly_weekday, do: digest_config(:weekly_weekday, @default_weekly_weekday)

  defp digest_config(key, default),
    do: :verscienta |> Application.get_env(Verscienta.Digests, []) |> Keyword.get(key, default)
```

(`due_user_ids/1` callers still work via the default `now` arg — `EnqueueDigestsWorker` calls `due_user_ids(frequency)` unchanged.)

- [ ] **Step 5: Run the new test**

Run: `docker compose exec app mix test test/verscienta/digests/due_send_time_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 6: Fix the existing `due_user_ids` test (digests_test.exs)**

The existing test "due_user_ids matches frequency + cutoff, excludes off and recently-sent" (in `test/verscienta/digests_test.exs`) seeds **default-UTC** users and calls `due_user_ids(:weekly)` / `due_user_ids(:daily)` with the real `now` — they'd no longer pass the local-hour filter. Pin `now` to a **Monday 08:00 UTC** (matches default `send_hour: 8` + `weekly_weekday: 1` for UTC users) and pass it through:

Change `now = DateTime.utc_now()` to:
```elixir
    now = ~U[2026-01-12 08:00:00Z]
```
and the two calls to:
```elixir
    ids = Verscienta.Digests.due_user_ids(:weekly, now)
    ...
    daily_ids = Verscienta.Digests.due_user_ids(:daily, now)
```
(The seeded `last_digest_at` values are already relative to `now`, so all the cutoff assertions still hold; the UTC users now match the tz filter at Monday 08:00Z.)

- [ ] **Step 7: Fix the enqueue worker test**

In `test/verscienta/digests/workers/enqueue_digests_worker_test.exs`, the "enqueues a SendDigestWorker for each due user" test runs the worker (which calls `due_user_ids(frequency)` with the *real* now). Make it deterministic by overriding the config to the current UTC hour + weekday so the default-UTC weekly user matches. Add to the file's `setup` block (after the flag enable):

```elixir
  setup do
    FunWithFlags.enable(:digest_emails)
    now = DateTime.utc_now()
    prev = Application.get_env(:verscienta, Verscienta.Digests, [])

    Application.put_env(:verscienta, Verscienta.Digests,
      send_hour: now.hour,
      weekly_weekday: Date.day_of_week(now)
    )

    on_exit(fn ->
      FunWithFlags.disable(:digest_emails)
      Application.put_env(:verscienta, Verscienta.Digests, prev)
    end)

    :ok
  end
```
(This replaces the existing `setup` block's flag-only on_exit. The default-UTC `weekly_user` now matches the local-hour filter at the real `now`. The "flag off" and "unknown frequency" tests never reach the filter, so they're unaffected.)

- [ ] **Step 8: Run the touched suites + compile**

Run: `docker compose exec app mix test test/verscienta/digests/due_send_time_test.exs test/verscienta/digests_test.exs test/verscienta/digests/workers/enqueue_digests_worker_test.exs`
Expected: PASS (all green).

Run: `docker compose exec app mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 9: Commit (do NOT stage docs/todo.md)**

```bash
git add config/config.exs lib/verscienta/digests.ex test/verscienta/digests/due_send_time_test.exs test/verscienta/digests_test.exs test/verscienta/digests/workers/enqueue_digests_worker_test.exs
git commit -m "feat(digests): send at each user's local hour (per-timezone send-time)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Full verification + docs

**Files:**
- Modify: `docs/todo.md` (your hunk only — there is also an unrelated user edit in this file; stage carefully)

- [ ] **Step 1: Format + compile (warnings as errors)**

Run: `docker compose exec app mix format && docker compose exec app mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 2: Credo strict**

Run: `docker compose exec app mix credo --strict`
Expected: no issues.

- [ ] **Step 3: Run the digest suites**

Run: `docker compose exec app mix test test/verscienta/digests/ test/verscienta/digests_test.exs`
Expected: PASS.

- [ ] **Step 4: Run the full suite**

Run: `docker compose exec app mix test`
Expected: PASS, 0 failures. (If a transient seed-contamination count failure appears, re-run; see the project memory on test DB seed contamination.)

- [ ] **Step 5: Update the todo item**

In `docs/todo.md`, the digest-refinements line (currently `[~]`) — strike the
now-done timezone sub-item. The line's first sub-item is
`per-user-timezone / optimal send-time`; change it to struck-through with a note:

```
~~per-user-timezone / optimal send-time~~ *(done — hourly cron + in-Elixir local-hour filter in `Digests.due_user_ids/2`: each user's digest sends at a configured local hour (08:00 default) in their IANA timezone, Monday-local for weekly; bad tz → UTC fallback; existing last-sent cutoff still prevents double-sends)*
```

Keep the line `[~]` (open/click analytics remains). **NOTE:** `docs/todo.md` also
contains an unrelated uncommitted user edit. To commit ONLY your todo hunk without
the user's edit, use `git stash push -- docs/todo.md`, make your edit, `git add
docs/todo.md && git commit`, then `git stash pop` — OR if that's fragile, just
verify your `git add docs/todo.md` + `git diff --cached docs/todo.md` shows BOTH
hunks and decide with care. (The controller may handle this step manually.)

- [ ] **Step 6: Commit**

```bash
git add docs/todo.md
git commit -m "docs(digests): mark per-user-timezone send-time done (slice 3)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review Notes

**Spec coverage:**
- Config (`send_hour`/`weekly_weekday`) + hourly cron → Task 1 Steps 3.
- `due_user_ids/2` local-hour filter (daily hour; weekly hour+weekday; cutoff; tz fallback; injectable `now`) → Task 1 Step 4.
- Tests: new tz matching (daily/weekly/cutoff/UTC-fallback/config-override) + the existing due_user_ids test pinned + the enqueue regression made deterministic → Task 1.
- Verification + todo → Task 2.

**Out of scope (per spec):** per-user preferred hour; adaptive optimal time; DST-skip catch-up; runtime-configurable `send_hour`; the open/click analytics slice. No migration, resource, attribute, action, or flag.

**Note on the todo commit (Task 2 Step 5):** the controller will likely handle the
`docs/todo.md` commit manually (stash the unrelated user edit, commit only the
slice-3 hunk, restore) rather than risk bundling the user's edit.
