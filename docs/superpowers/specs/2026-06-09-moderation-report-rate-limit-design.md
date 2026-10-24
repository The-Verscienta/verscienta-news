# Rate-limit community report submissions

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-09
**Status:** Approved — ready for implementation plan
**Slice:** Moderation & Trust fast-follow (deferred from slice 1)

## Context

`Verscienta.Moderation.Flag`'s `report` create action lets an authenticated user
report a comment, article, user profile, or room message. A unique identity on
`(subject_type, subject_id, reporter_id)` already makes duplicate reports of the
*same* subject idempotent (upsert). The remaining abuse vector — called out as a
Non-goal in `docs/superpowers/specs/2026-06-08-moderation-trust-slice1-design.md`
and tracked in `docs/todo.md` under "Moderation fast-follows" — is a single user
spamming reports across many *distinct* subjects.

This fast-follow closes that vector with a per-user rate limit, reusing the
existing Hammer/ETS action-layer infrastructure (`Verscienta.RateLimit`) already
applied to the auth endpoints (sign-in, register, password reset, email change).

## Goal

A per-user limit on `report` submissions. When exceeded, the action returns a
client error and the report dialog surfaces a friendly "you're reporting too
quickly" flash. Honest reporters are unaffected; rapid cross-subject spam is
stopped.

## Non-goals

- IP-based limiting. The `report` action requires an authenticated actor
  (`relate_actor(:reporter)`), so the limiter keys purely on the user id. No
  `:auth_client_ip` plumbing is needed.
- Per-subject-type limits or escalating penalties. One flat per-user bucket.
- Hiding the report affordance on already-reported subjects (separate
  fast-follow item; the upsert already makes a re-report harmless).

## Design

Mirrors the existing auth rate-limit pattern (`RateLimitEmailChange`,
`RateLimitRegister`): an Ash Change at the action layer + a config bucket + a
friendly surface in the caller. `Verscienta.RateLimit.check/2` returns `:ok`
(allowed) or `{:error, retry_after_seconds}` (denied), and fails open on any
backend error.

### 1. Ash Change — `Verscienta.Moderation.Flag.Changes.RateLimitReport`

New module alongside the existing `Verscienta.Moderation.Flag.Changes.CaptureSubject`.

```elixir
defmodule Verscienta.Moderation.Flag.Changes.RateLimitReport do
  @moduledoc "Per-user rate limit on report submissions (Hammer/ETS)."
  use Ash.Resource.Change

  alias Verscienta.RateLimit

  @impl true
  def change(changeset, _opts, context) do
    actor_key = if context.actor, do: to_string(context.actor.id), else: nil

    case RateLimit.check(:report_user, actor_key) do
      :ok ->
        changeset

      {:error, retry} ->
        Ash.Changeset.add_error(changeset,
          field: :reason,
          message: "You're reporting too quickly. Try again in #{retry} seconds."
        )
    end
  end
end
```

Wired into the `report` action in `lib/verscienta/moderation/flag.ex`, immediately
after the existing `change Verscienta.Moderation.Flag.Changes.CaptureSubject`:

```elixir
change Verscienta.Moderation.Flag.Changes.CaptureSubject
change Verscienta.Moderation.Flag.Changes.RateLimitReport
```

A `nil` actor short-circuits to `:ok` (fail-open) inside `RateLimit.check/2`, but
in practice the action is always invoked with an authenticated actor.

### 2. Config — bucket `report_user`

`config/config.exs`, added to the `Verscienta.RateLimit` `:buckets` map:

```elixir
report_user: {600_000, 10}   # 10 reports per 10 minutes
```

`config/test.exs`, added to its `:buckets` map so the existing async
`flag_test.exs` (which does not override the limiter) is unaffected:

```elixir
report_user: {1000, 1_000_000}   # effectively disabled in tests by default
```

### 3. Component flash — `lib/verscienta_web/components/report_dialog.ex`

Today the submit handler collapses both success and error to `done: true`
("reported"), so a rate-limited report would misleadingly show as reported. Split
the error branch: detect the rate-limit error and raise a flash; keep current
behavior for any other error.

```elixir
case Flag
     |> Ash.Changeset.for_create(:report, attrs, actor: actor)
     |> Ash.create(authorize?: true) do
  {:ok, _} ->
    {:noreply, assign(socket, open: false, done: true)}

  {:error, error} ->
    if rate_limited?(error) do
      {:noreply,
       socket
       |> assign(open: false)
       |> put_flash(:error, "You're reporting too quickly. Please slow down and try again shortly.")}
    else
      {:noreply, assign(socket, open: false, done: true)}
    end
end

defp rate_limited?(error) do
  Exception.message(error) =~ "reporting too quickly"
rescue
  _ -> false
end
```

`put_flash/3` from a `live_component` bubbles to the parent LiveView's flash
group, matching how flashes already render app-wide. Detection by message string
matches the convention used by the existing auth rate-limit tests
(`Exception.message(error) =~ "Too many"`).

## Testing

New file `test/verscienta/moderation/rate_limit_report_test.exs`, `async: false`
(ETS state is shared). Follows the `rate_limit_register_test.exs` shape:

```elixir
setup do
  Application.put_env(:verscienta, Verscienta.RateLimit, buckets: %{report_user: {60_000, 2}})
  on_exit(fn -> Application.delete_env(:verscienta, Verscienta.RateLimit) end)
  :ok
end
```

Test body: register one reporter and an author, create 3 distinct published
articles, then report each in turn with the reporter as actor. Assert reports 1
and 2 return `{:ok, _}`, and report 3 returns `{:error, error}` with
`Exception.message(error) =~ "reporting too quickly"`. This exercises the actual
distinct-subject vector the limit exists to close.

Use the existing `flag_test.exs` helpers (`user/1`, `article/1`, `report/4`) as a
reference for building fixtures.

## Trade-offs / notes

- The limiter counts every `report` create attempt, including same-subject
  re-reports (which upsert). That is harmless and marginally stricter — a user
  re-reporting the same item repeatedly still consumes budget. Acceptable.
- Fail-open: any Hammer/ETS error returns `:ok`, so a backend hiccup never blocks
  legitimate reports. Inherited from `RateLimit.check/2`.

## Files touched

- `lib/verscienta/moderation/flag/changes/rate_limit_report.ex` (new)
- `lib/verscienta/moderation/flag.ex` (wire change into `report` action)
- `config/config.exs` (add `report_user` bucket)
- `config/test.exs` (add `report_user` bucket, disabled)
- `lib/verscienta_web/components/report_dialog.ex` (flash on rate-limit error)
- `test/verscienta/moderation/rate_limit_report_test.exs` (new)
- `docs/todo.md` (check off the rate-limit fast-follow item)
