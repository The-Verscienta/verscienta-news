# Digest Scheduling — Cron Fan-out Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A cron-driven worker that fans out per-user `SendDigestWorker` jobs for users whose digest is due.

**Architecture:** `Digests.due_user_ids/1` (frequency match + cutoff) → `EnqueueDigestsWorker` (flag-gated, safe frequency parse, `Oban.insert!` a child per due id) → two `Oban.Plugins.Cron` entries (daily + weekly).

**Tech Stack:** Elixir, Ash 3 (`Ash.Query`), Oban (+ Cron plugin), FunWithFlags. All `mix` runs in Docker: `docker compose exec -T app mix …`.

**Spec:** `docs/superpowers/specs/2026-06-05-digest-schedule-design.md`
**Branch:** `phase-3-digest-schedule` (spec + a `docs/todo.md` deferred-items note already committed here).

**Confirmed facts:**
- Fan-out pattern (`lib/verscienta/aggregation/workers/schedule_fetches_worker.ex`): `use Oban.Worker, queue: :default, max_attempts: 1`; `perform/1` reads a list and `%{"key" => v} |> ChildWorker.new() |> Oban.insert!()` per item.
- Oban test mode is `:manual` (`config/test.exs`). Worker tests: `use Verscienta.DataCase, async: false` + `use Oban.Testing, repo: Verscienta.Repo`; `assert :ok = perform_job(Worker, %{...})`; `assert_enqueued(worker: W, args: %{...})` / `refute_enqueued(worker: W)`.
- `Ash.Query` queries: `require Ash.Query`; `Resource |> Ash.Query.filter(...) |> Ash.read!(authorize?: false)`.
- Slice 1: `Verscienta.Digests` (has `window_days/1`, `highlights/1`, token helpers); `User.digest_frequency` (`:off`/`:daily`/`:weekly`, default `:off`) + `last_digest_at`; `:set_digest_frequency` (accept `[:digest_frequency]`, `require_atomic? false`); `SendDigestWorker` (args `%{"user_id"}`, `unique [keys: [:user_id], period: 3600]`). `:digest_emails` flag.
- Existing crontab in `config/config.exs` ends with `{"30 3 * * *", Verscienta.Accounts.Workers.AccountPurgeWorker}`.

---

## File Structure

**Create:** `lib/verscienta/digests/workers/enqueue_digests_worker.ex`, `test/verscienta/digests/workers/enqueue_digests_worker_test.exs`.
**Modify:** `lib/verscienta/digests.ex` (add `due_user_ids/1` + `due_cutoff/1`), `test/verscienta/digests_test.exs` (add `due_user_ids` tests), `config/config.exs` (two cron entries), `docs/todo.md`.

---

## Task 1: Due-users query + `EnqueueDigestsWorker`

**Files:** modify `lib/verscienta/digests.ex` + `test/verscienta/digests_test.exs`; create `lib/verscienta/digests/workers/enqueue_digests_worker.ex` + `test/verscienta/digests/workers/enqueue_digests_worker_test.exs`.

- [ ] **Step 1: Write the failing `due_user_ids` test**

In `test/verscienta/digests_test.exs`, add this helper near the other helpers (reuse the file's existing `user/1` helper that registers a user):
```elixir
  defp set_digest(u, freq, last_at) do
    u
    |> Ash.Changeset.for_update(:set_digest_frequency, %{digest_frequency: freq}, authorize?: false)
    |> then(fn cs ->
      if last_at, do: Ash.Changeset.force_change_attribute(cs, :last_digest_at, last_at), else: cs
    end)
    |> Ash.update!(authorize?: false)
  end
```
And add the test:
```elixir
  test "due_user_ids matches frequency + cutoff, excludes off and recently-sent" do
    now = DateTime.utc_now()
    weekly_new = set_digest(user("duewnew"), :weekly, nil)
    weekly_old = set_digest(user("duewold"), :weekly, DateTime.add(now, -8 * 86_400, :second))
    weekly_recent = set_digest(user("duewrec"), :weekly, now)
    daily_new = set_digest(user("duednew"), :daily, nil)
    off_user = set_digest(user("dueoff"), :off, nil)

    ids = Verscienta.Digests.due_user_ids(:weekly)
    assert weekly_new.id in ids
    assert weekly_old.id in ids
    refute weekly_recent.id in ids
    refute daily_new.id in ids
    refute off_user.id in ids

    daily_ids = Verscienta.Digests.due_user_ids(:daily)
    assert daily_new.id in daily_ids
    refute weekly_new.id in daily_ids
  end
```

- [ ] **Step 2: Run it (fails)**

`docker compose exec -T app mix test test/verscienta/digests_test.exs` → FAIL (`due_user_ids/1` undefined).

- [ ] **Step 3: Implement `due_user_ids/1` + `due_cutoff/1`**

In `lib/verscienta/digests.ex`: add `require Ash.Query` near the top (after `@moduledoc`), `alias Verscienta.Accounts.User`, and these functions:
```elixir
  @doc "User ids whose digest is due for `frequency` (never sent, or sent before the cutoff)."
  def due_user_ids(frequency) when frequency in [:daily, :weekly] do
    cutoff = due_cutoff(frequency)

    User
    |> Ash.Query.filter(
      digest_frequency == ^frequency and (is_nil(last_digest_at) or last_digest_at < ^cutoff)
    )
    |> Ash.Query.select([:id])
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.id)
  end

  defp due_cutoff(:daily), do: DateTime.add(DateTime.utc_now(), -20 * 3600, :second)
  defp due_cutoff(:weekly), do: DateTime.add(DateTime.utc_now(), -6 * 86_400, :second)
```

- [ ] **Step 4: Run the `due_user_ids` test (passes)**

`docker compose exec -T app mix test test/verscienta/digests_test.exs` → PASS.

- [ ] **Step 5: Write the failing worker test**

Create `test/verscienta/digests/workers/enqueue_digests_worker_test.exs`:
```elixir
defmodule Verscienta.Digests.Workers.EnqueueDigestsWorkerTest do
  use Verscienta.DataCase, async: false
  use Oban.Testing, repo: Verscienta.Repo

  alias Verscienta.Accounts.User
  alias Verscienta.Digests.Workers.EnqueueDigestsWorker
  alias Verscienta.Digests.Workers.SendDigestWorker

  setup do
    FunWithFlags.enable(:digest_emails)
    on_exit(fn -> FunWithFlags.disable(:digest_emails) end)
    :ok
  end

  defp weekly_user(name) do
    u =
      User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: name <> "@example.com", username: name,
        password: "password123", password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    u
    |> Ash.Changeset.for_update(:set_digest_frequency, %{digest_frequency: :weekly}, authorize?: false)
    |> Ash.update!()
  end

  test "enqueues a SendDigestWorker for each due user" do
    me = weekly_user("enqme")
    assert :ok = perform_job(EnqueueDigestsWorker, %{"frequency" => "weekly"})
    assert_enqueued(worker: SendDigestWorker, args: %{"user_id" => me.id})
  end

  test "flag off enqueues nothing" do
    FunWithFlags.disable(:digest_emails)
    _me = weekly_user("flagoffenq")
    assert :ok = perform_job(EnqueueDigestsWorker, %{"frequency" => "weekly"})
    refute_enqueued(worker: SendDigestWorker)
  end

  test "unknown frequency is a no-op" do
    _me = weekly_user("badfreqenq")
    assert :ok = perform_job(EnqueueDigestsWorker, %{"frequency" => "monthly"})
    refute_enqueued(worker: SendDigestWorker)
  end
end
```

- [ ] **Step 6: Run it (fails)**

`docker compose exec -T app mix test test/verscienta/digests/workers/enqueue_digests_worker_test.exs` → FAIL (worker undefined).

- [ ] **Step 7: Implement the worker**

Create `lib/verscienta/digests/workers/enqueue_digests_worker.ex`:
```elixir
defmodule Verscienta.Digests.Workers.EnqueueDigestsWorker do
  @moduledoc "Cron-driven fan-out: enqueues a SendDigestWorker per due user for a frequency."
  use Oban.Worker, queue: :default, max_attempts: 1

  alias Verscienta.Digests
  alias Verscienta.Digests.Workers.SendDigestWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"frequency" => freq}}) do
    if Verscienta.Flags.enabled?(:digest_emails), do: fan_out(parse(freq)), else: :ok
  end

  defp fan_out(nil), do: :ok

  defp fan_out(frequency) do
    frequency
    |> Digests.due_user_ids()
    |> Enum.each(fn id -> %{"user_id" => id} |> SendDigestWorker.new() |> Oban.insert!() end)

    :ok
  end

  defp parse("daily"), do: :daily
  defp parse("weekly"), do: :weekly
  defp parse(_), do: nil
end
```

- [ ] **Step 8: Run the worker test (passes)**

`docker compose exec -T app mix test test/verscienta/digests/workers/enqueue_digests_worker_test.exs 2>&1 | tail -5` → PASS (3 tests).

- [ ] **Step 9: format, warnings, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix compile --force --warnings-as-errors 2>&1 | tail -4
docker compose exec -T app mix credo --strict lib/verscienta/digests.ex lib/verscienta/digests/workers/enqueue_digests_worker.ex 2>&1 | tail -4
git add lib/verscienta/digests.ex lib/verscienta/digests/workers/enqueue_digests_worker.ex test/verscienta/digests_test.exs test/verscienta/digests/workers/enqueue_digests_worker_test.exs
git commit -m "feat(digests): due-users query + EnqueueDigestsWorker fan-out"
```
Expected: NO warnings; credo clean (verify the FULL credo too in Task 2).

### Watch out
- `require Ash.Query` is needed for the `Ash.Query.filter` macro.
- `due_cutoff` is distinct from `window_days/1` (cutoff = send cadence; window = highlight content recency). Don't conflate them.
- Don't use `String.to_atom` on the `"frequency"` arg — `parse/1` whitelists `"daily"`/`"weekly"` and returns `nil` otherwise (→ `fan_out(nil)` → `:ok`).
- The worker enqueues **ids only**; `SendDigestWorker` re-loads + re-checks the flag/`:off`/empty-highlights, so a user who flips settings between fan-out and send is handled correctly.

---

## Task 2: Cron config + docs + verification

**Files:** modify `config/config.exs`, `docs/todo.md`.

- [ ] **Step 1: Add the two cron entries**

In `config/config.exs`, in the `Oban.Plugins.Cron` `crontab:` list, add two entries after the last existing entry (`{"30 3 * * *", Verscienta.Accounts.Workers.AccountPurgeWorker}`). Add a comma to that line and append:
```elixir
      {"30 3 * * *", Verscienta.Accounts.Workers.AccountPurgeWorker},
      {"0 13 * * *", Verscienta.Digests.Workers.EnqueueDigestsWorker, args: %{"frequency" => "daily"}},
      {"0 13 * * 1", Verscienta.Digests.Workers.EnqueueDigestsWorker, args: %{"frequency" => "weekly"}}
```
(Keep all existing entries intact; only add the two new lines + the trailing comma on the AccountPurgeWorker line.)

- [ ] **Step 2: Confirm config loads + the worker is referenced**

```bash
docker compose exec -T app mix compile --force --warnings-as-errors 2>&1 | tail -3
docker compose exec -T app bash -lc 'mix run -e "IO.inspect(Application.get_env(:verscienta, Oban)[:plugins])" 2>&1 | tail -5'
```
Expected: compiles clean; the printed plugins include the Cron plugin with the two `EnqueueDigestsWorker` entries (daily + weekly). (If `mix run -e` is awkward, skip this introspection — the cron validity is covered by the app booting in the test run at Step 4.)

- [ ] **Step 3: Check off the todo**

In `docs/todo.md` under "### Notifications & Digests", update the scheduled-jobs line:
- `- [~] Scheduled digest Oban jobs + unsubscribe management. *(one-click unsubscribe + opt-in done; scheduled cron fan-out = slice 2)*` → `- [x] Scheduled digest Oban jobs + unsubscribe management. *(unsubscribe + opt-in slice 1; cron fan-out EnqueueDigestsWorker daily/weekly slice 2)*`

- [ ] **Step 4: Full verification**

```bash
docker compose exec -T app bash -lc 'mix format && mix format --check-formatted && mix test 2>&1 | tail -6'
docker compose exec -T app mix compile --force --warnings-as-errors 2>&1 | tail -3
docker compose exec -T app mix credo --strict 2>&1 | tail -4
docker compose exec -T app mix dialyzer 2>&1 | tail -8
```
Expected: format clean; 0 failures (known flake `NotificationBellTest` / transient Postgrex — re-run `mix test` once if that's the only failure); compile no warnings; **full credo "found no issues"** (the per-file credo in Task 1 can mis-scan — this full run is the real gate); dialyzer "passed successfully". If credo or dialyzer reports a NEW issue, fix it (or paste it + report BLOCKED) — do NOT commit on red.

- [ ] **Step 5: Commit**

```bash
git add config/config.exs docs/todo.md
git commit -m "feat(digests): schedule daily/weekly digest fan-out via Oban cron; check off slice 2"
```

- [ ] **Step 6:** Confirm all gates green — branch ready to merge.

### Watch out
- The full `mix credo --strict` (Step 4) is the authoritative gate — a per-file/dir credo run can report "0 mods/funs" (scan nothing) and hide an issue. Always confirm the full run says "found no issues".
- Keep the existing crontab entries unchanged; a trailing comma on the previously-last line is required when appending.

---

## Notes for the implementer

- This is a thin scheduling layer over slice 1. The worker does no sending itself — it only enqueues `SendDigestWorker` jobs; all the send-time guards (flag/off/empty/deliver) already live in `SendDigestWorker`.
- **Double-send safety has two layers**: (1) `due_user_ids` excludes users sent within the cutoff (daily 20 h / weekly 6 days); (2) `SendDigestWorker`'s `unique [keys: [:user_id], period: 3600]` dedups any same-hour duplicate enqueue. Both are intentional.
- **Flag gate at the fan-out** means disabling `:digest_emails` stops the cron from even enqueueing (not just sending) — clean kill-switch.
- Cron times (13:00 UTC daily / Mondays) are a tunable default; no per-user-timezone logic in this slice (deferred, tracked in `docs/todo.md`).
- Oban test mode is `:manual`, so `perform_job/2` runs the worker synchronously and `assert_enqueued/refute_enqueued` inspect the jobs table without executing the children.
