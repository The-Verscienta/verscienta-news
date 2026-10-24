# Digest Refinements — Slice 3: Per-User-Timezone Send-Time

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-11
**Phase:** 3 — Intelligence & Growth › Notifications & Digests
**Todo item:** `Digest refinements (deferred): per-user-timezone / optimal
send-time …` — this slice delivers the timezone send-time part. (Open/click
analytics is the remaining slice.)

## Goal

Send each user's digest at a fixed **local** hour (08:00 in their own IANA
timezone), instead of the current fixed **13:00 UTC** for everyone — so a user in
Tokyo and a user in New York both receive it at ~08:00 their time.

## Decisions (from brainstorming)

- **Fixed local hour for all** (not per-user preference, not adaptive): one
  configured `send_hour` (08:00) applied in each user's timezone; weekly digests
  on a configured local weekday (Monday).
- **Hourly cron + in-Elixir local-hour filter.** IANA offsets can't be computed in
  SQL, so the cron ticks hourly and `due_user_ids/1` loads candidate users (+
  timezone) and filters to those whose local time matches the target.
- **Keep the existing last-sent cutoff** (daily 20h, weekly 6d) for double-send
  protection.
- **No new user attribute / setting / migration** — `User.timezone` already exists.

## Background (current state)

- Cron (`config/config.exs:110-113`):
  `{"0 13 * * *", EnqueueDigestsWorker, args: %{"frequency" => "daily"}}` and
  `{"0 13 * * 1", EnqueueDigestsWorker, args: %{"frequency" => "weekly"}}` — fixed
  13:00 UTC.
- `EnqueueDigestsWorker` (`lib/verscienta/digests/workers/enqueue_digests_worker.ex`):
  flag-gates on `:digest_emails`, then `fan_out(frequency)` =
  `Digests.due_user_ids(frequency) |> Enum.each(enqueue SendDigestWorker)`.
- `Digests.due_user_ids(frequency)` (`lib/verscienta/digests.ex:187`):
  ```elixir
  def due_user_ids(frequency) when frequency in [:daily, :weekly] do
    cutoff = due_cutoff(frequency)
    User
    |> Ash.Query.filter(digest_frequency == ^frequency and (is_nil(last_digest_at) or last_digest_at < ^cutoff))
    |> Ash.Query.select([:id])
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.id)
  end
  defp due_cutoff(:daily), do: DateTime.add(DateTime.utc_now(), -20 * 3600, :second)
  defp due_cutoff(:weekly), do: DateTime.add(DateTime.utc_now(), -6 * 86_400, :second)
  ```
- `User.timezone` (`lib/verscienta/accounts/user.ex`): `:string`, IANA, validated in
  `:update_profile` (`DateTime.shift_zone` round-trip), default `"Etc/UTC"`. The Tz
  database is registered (`config :elixir, :time_zone_database, Tz.TimeZoneDatabase`).
- `SendDigestWorker` is unique per `user_id` per hour and records `last_digest_at`
  — unchanged here.

## Architecture

### 1. Config (the target local time)

`config/config.exs`:
```elixir
config :verscienta, Verscienta.Digests, send_hour: 8, weekly_weekday: 1
```
(`weekly_weekday` per `Date.day_of_week/1`: 1 = Monday … 7 = Sunday.)

In `Verscienta.Digests`, small readers with defaults:
```elixir
@default_send_hour 8
@default_weekly_weekday 1

defp send_hour, do: digest_config(:send_hour, @default_send_hour)
defp weekly_weekday, do: digest_config(:weekly_weekday, @default_weekly_weekday)

defp digest_config(key, default),
  do: :verscienta |> Application.get_env(Verscienta.Digests, []) |> Keyword.get(key, default)
```

### 2. Cron → hourly

In `config/config.exs`, change both digest cron entries to fire **hourly**, keeping
their `frequency` args:
```elixir
{"0 * * * *", Verscienta.Digests.Workers.EnqueueDigestsWorker, args: %{"frequency" => "daily"}},
{"0 * * * *", Verscienta.Digests.Workers.EnqueueDigestsWorker, args: %{"frequency" => "weekly"}}
```
`EnqueueDigestsWorker` is otherwise **unchanged** — it still calls
`Digests.due_user_ids(frequency)`; the new local-hour filter lives in that function.

### 3. `Digests.due_user_ids/1,2` — add the local-hour filter

```elixir
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

# A user is due "now" if their local clock reads the target hour (and, for weekly,
# the target weekday). A bad/unshiftable timezone falls back to UTC so the user is
# never stranded.
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
```
- `now` is injectable (default `DateTime.utc_now()`) so tests pin a specific UTC
  instant. `due_cutoff/2` takes `now` for consistency.
- Selecting `:timezone` alongside `:id` is the only query change.
- The cutoff still guarantees a user is enqueued at most once per local day (daily)
  / week (weekly): the hourly tick only matches their single local `send_hour`, and
  `last_digest_at` (set by `SendDigestWorker`) keeps them out of the next 20h/6d.

### 4. DST + edge handling (recorded decisions)

- **Spring-forward** (a zone skips 02:00→03:00): if `send_hour` were ever in that
  window the user would miss that day, then be sent the next day (past the 20h
  cutoff). With `send_hour: 8` this effectively never happens.
- **Fall-back** (a zone repeats an hour): the 20h cutoff prevents a second send.
- **Timezone change** by a user mid-period: at most one extra or skipped digest that
  period. Accepted.
- **Default `Etc/UTC`** users send when the UTC hour equals `send_hour` —
  deterministic.
- A `nil`/empty timezone is treated as `Etc/UTC`.

### 5. Unchanged

`:digest_emails` flag gate (in both workers), `SendDigestWorker` (unique per
user/hour, `Digests.deliver/1`, send-if-either), the digest content
(`highlights/activity`), unsubscribe, and the admin send-now/preview tool. No new
resource, attribute, action, migration, or flag.

## Testing

- **`Digests.due_user_ids(:daily, now)`** with a pinned `now`:
  - A `:daily` user whose timezone makes `local.hour == send_hour` at `now` is
    returned; a user in a timezone where it's a different local hour is not.
  - A never-sent user (nil `last_digest_at`) in a matching tz is returned; a user
    sent within the cutoff (recent `last_digest_at`) is excluded even in a matching
    tz.
  - An `Etc/UTC` user is returned when `now`'s UTC hour == `send_hour`.
  - A user with a `nil`/garbage timezone is treated as UTC (matches at UTC
    `send_hour`).
  - Choose `now` and two real IANA zones with a known offset so exactly one matches
    (e.g. `now` = some UTC instant; `"America/New_York"` vs `"Asia/Tokyo"`; assert
    the one whose local hour equals `send_hour`).
- **`Digests.due_user_ids(:weekly, now)`:** a weekly user matches only when local
  hour == `send_hour` AND `Date.day_of_week(local) == weekly_weekday`; a user at the
  right hour on the wrong local weekday is excluded.
- **Config override:** with `send_hour` overridden via `Application.put_env` in the
  test, the matching set shifts accordingly (and is restored on exit).
- **`EnqueueDigestsWorker` (regression):** the worker calls `due_user_ids(frequency)`
  with the default (real) `now`, so to stay deterministic the test **overrides
  `send_hour` to the current UTC hour** (`Application.put_env(:verscienta,
  Verscienta.Digests, send_hour: DateTime.utc_now().hour)`, restored on exit) and
  seeds a due `:daily` user with the default `Etc/UTC` timezone — then the real-now
  local-hour match fires. Assert a `SendDigestWorker` is enqueued (flag on) and that
  nothing is enqueued with the flag off. Keep the precise hour/weekday/tz logic on
  the `due_user_ids/2` tests (which pin `now`).

## Out of scope (later / deferred)

- Per-user preferred send hour (a user setting); adaptive "optimal" send-time from
  activity patterns.
- Sub-hour precision; catch-up sends for a DST-skipped hour.
- Letting admins change `send_hour` at runtime (config-only here).
- The open/click analytics slice.

## Files touched (summary)

- `config/config.exs` — the two cron entries → hourly; add the
  `Verscienta.Digests` config (send_hour/weekly_weekday).
- `lib/verscienta/digests.ex` — `due_user_ids/2` local-hour filter + `local_send_time?/3`,
  `send_hour/0`, `weekly_weekday/0`, `digest_config/2`; `due_cutoff/2` takes `now`.
- Tests: `due_user_ids/2` (daily + weekly tz matching, cutoff, UTC fallback, config
  override) in the digests test; the existing `EnqueueDigestsWorker` test adjusted.
- No migration, no new resource/attribute/action, no new flag.
