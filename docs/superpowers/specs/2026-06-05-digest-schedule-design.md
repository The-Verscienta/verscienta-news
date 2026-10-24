# Digest Scheduling — Cron Fan-out Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-05
**Status:** Approved
**Phase:** 3 — Intelligence & Growth · Notifications & Digests (slice 2 of 2 — completes the subsystem; push deferred)
**Depends on:** slice 1 (`User.digest_frequency`/`last_digest_at`, `Verscienta.Digests`, `SendDigestWorker`, the `:digest_emails` flag), the `Oban.Plugins.Cron` config, the `ScheduleFetchesWorker` fan-out pattern.
**New dependency:** none.

## Goal

Run the digest engine on a schedule: a cron-driven worker fans out per-user `SendDigestWorker` jobs for users whose `digest_frequency` is due. This is the thin scheduling layer over slice 1's per-user send. Completes the Notifications & Digests subsystem.

## Decomposition context

Notifications & Digests: **slice 1** (digest email + per-user send + unsubscribe) shipped; **slice 2 (this)** = scheduled cron fan-out by frequency. Push/web-push remains a separate deferred future subsystem.

## Decisions

| Decision | Choice |
|----------|--------|
| Fan-out worker | one `EnqueueDigestsWorker` taking a `"frequency"` arg (`"daily"`/`"weekly"`); cron-driven; `max_attempts: 1` (mirrors `ScheduleFetchesWorker`) |
| Schedule | two crontab entries: daily `0 13 * * *`, weekly `0 13 * * 1` (13:00 UTC; tunable) |
| Due query | `digest_frequency == ^freq` AND (`is_nil(last_digest_at)` OR `last_digest_at < cutoff`); cutoff = daily 20 h / weekly 6 days (under the period so a fixed-time cron never skips on the boundary, and overlap/re-run never double-sends) |
| Flag gate | the worker no-ops (`:ok`) when `:digest_emails` is off (so the fan-out itself is gated, not just sends) |
| Enqueue unit | user **ids** only; `SendDigestWorker` re-loads + re-checks `:off`/flag/empty (settings changes between fan-out and send are still honored). `SendDigestWorker`'s `unique [keys: [:user_id], period: 3600]` is a secondary double-send guard |
| Send time | a single global send time (per-user-timezone / optimal send-time stays deferred per slice 1) |

## Section 1: Due-users query

In `lib/verscienta/digests.ex`, add:
- `due_user_ids(frequency)` (`frequency` an atom `:daily`/`:weekly`) — `Ash.Query` on `User`: filter `digest_frequency == ^frequency` AND (`is_nil(last_digest_at)` OR `last_digest_at < ^cutoff`); select/return just the ids. `authorize?: false` (system query).
- `due_cutoff(frequency)` helper (private or public): `:daily` → `now - 20 h`, `:weekly` → `now - 6 days` (as a `DateTime`). (Distinct from `window_days/1`, which governs *highlight content recency*; this governs *send cadence*.)

Use a `User` read action if one fits the existing conventions, or an inline `Ash.Query.filter` in the context (read `user.ex`/the existing `Digests` for the cleanest fit). Returning ids (not full structs) keeps the fan-out lightweight; the worker re-loads each.

## Section 2: `EnqueueDigestsWorker`

`lib/verscienta/digests/workers/enqueue_digests_worker.ex` (Oban; queue `:default`; `max_attempts: 1`):
- `perform(%Oban.Job{args: %{"frequency" => freq_string}})`:
  - if `not Verscienta.Flags.enabled?(:digest_emails)` → `:ok` (no fan-out);
  - convert `freq_string` to an atom safely (`"daily" -> :daily`, `"weekly" -> :weekly`; anything else → `:ok`, ignore — no `String.to_atom` on external input);
  - `Digests.due_user_ids(freq)` → for each id, `%{"user_id" => id} |> SendDigestWorker.new() |> Oban.insert!()` (mirror `ScheduleFetchesWorker`'s `Enum.each`);
  - `:ok`.

## Section 3: Cron config

In `config/config.exs`, add two entries to the existing `Oban.Plugins.Cron` `crontab` list:
```elixir
{"0 13 * * *", Verscienta.Digests.Workers.EnqueueDigestsWorker, args: %{"frequency" => "daily"}},
{"0 13 * * 1", Verscienta.Digests.Workers.EnqueueDigestsWorker, args: %{"frequency" => "weekly"}}
```
(Daily 13:00 UTC; weekly Mondays 13:00 UTC. Keep the existing entries intact.)

## Section 4: Testing

- **`due_user_ids/1`**: a `:weekly` user with `last_digest_at == nil` is included for `:weekly`; a `:weekly` user sent 1 h ago is excluded; a `:daily` user is NOT returned for `:weekly` (and vice versa); an `:off` user is never included; a `:weekly` user sent 8 days ago IS included.
- **`EnqueueDigestsWorker`** (Oban testing — `assert_enqueued` / `all_enqueued`, `:manual` testing mode): with `:digest_emails` ON and one due `:weekly` user, `perform(%Oban.Job{args: %{"frequency" => "weekly"}})` enqueues exactly one `SendDigestWorker` with that `user_id`; with the flag OFF, nothing is enqueued; a recently-sent user is not enqueued; an unknown frequency string → `:ok`, nothing enqueued.
- Full suite + `credo --strict` + `dialyzer` + format green.

(Confirm the project's Oban test config/mode — `config/test.exs` — and use the matching `assert_enqueued`/`Oban.Testing` approach. The `:digest_emails` flag must be enabled in the enqueue tests.)

## Out of scope (still deferred — tracked in `docs/todo.md`)

Push / web-push; per-user-timezone or optimal send-time; non-article digest content (new followers, comment replies, room activity); admin "send now" + digest preview; open/click analytics.

## Definition of Done

- `Digests.due_user_ids/1` (+ cutoff helper) — due = frequency match AND (never sent OR sent before the cutoff).
- `EnqueueDigestsWorker` — flag-gated; safe frequency parse; fans out one `SendDigestWorker` per due user id.
- Two `Oban.Plugins.Cron` entries (daily + weekly) in `config/config.exs`.
- Tests across `due_user_ids` (frequency match, cutoff in/out, off excluded) + the worker (enqueues due users, flag-off no-op, recently-sent excluded, bad frequency no-op); full suite + credo + dialyzer green.
- `docs/todo.md` "Scheduled digest Oban jobs" marked done (the Notifications & Digests digest line items complete; push + refinements remain tracked). No new dependency.
