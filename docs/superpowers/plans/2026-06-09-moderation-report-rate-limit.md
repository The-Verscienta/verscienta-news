# Report Rate-Limit Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-user rate limit to the `Moderation.Flag.report` action so a single authenticated user cannot spam reports across many distinct subjects, surfacing a friendly flash in the report dialog when exceeded.

**Architecture:** Reuse the existing Hammer/ETS action-layer limiter (`Verscienta.RateLimit.check/2`, which returns `:ok` or `{:error, retry_seconds}` and fails open). Add an Ash `Change` on the `report` action keyed on the actor id, a `report_user` config bucket, and a rate-limit-aware error branch in the `ReportDialog` live_component.

**Tech Stack:** Elixir, Phoenix 1.8 LiveView, Ash 3, Hammer (ETS backend), ExUnit.

**Spec:** `docs/superpowers/specs/2026-06-09-moderation-report-rate-limit-design.md`

---

## File Structure

- **Create** `lib/verscienta/moderation/flag/changes/rate_limit_report.ex` — Ash Change enforcing the per-user limit. One responsibility: gate the changeset on `RateLimit.check(:report_user, actor_id)`.
- **Modify** `lib/verscienta/moderation/flag.ex` — wire the new change into the `report` action.
- **Modify** `config/config.exs:110-119` — add the production `report_user` bucket.
- **Modify** `config/test.exs:71-80` — add a disabled `report_user` bucket so unrelated tests are unaffected.
- **Modify** `lib/verscienta_web/components/report_dialog.ex:59-81` — split the error branch to flash on rate-limit.
- **Create** `test/verscienta/moderation/rate_limit_report_test.exs` — asserts the limit engages on distinct subjects.
- **Modify** `docs/todo.md:222` — check off the fast-follow item.

---

### Task 1: Config buckets

**Files:**
- Modify: `config/config.exs:110-119`
- Modify: `config/test.exs:71-80`

- [ ] **Step 1: Add the production bucket**

In `config/config.exs`, add `report_user` to the `Verscienta.RateLimit` `:buckets` map (after `email_change_actor`):

```elixir
config :verscienta, Verscienta.RateLimit,
  buckets: %{
    sign_in_ip: {300_000, 10},
    sign_in_email: {900_000, 5},
    password_reset_ip: {900_000, 5},
    password_reset_email: {3_600_000, 3},
    register_ip: {3_600_000, 5},
    email_change_ip: {3_600_000, 5},
    email_change_actor: {3_600_000, 3},
    report_user: {600_000, 10}
  }
```

- [ ] **Step 2: Add the disabled test bucket**

In `config/test.exs`, add `report_user` to the `:buckets` map (after `email_change_actor`):

```elixir
config :verscienta, Verscienta.RateLimit,
  buckets: %{
    sign_in_ip: {1000, 1_000_000},
    sign_in_email: {1000, 1_000_000},
    password_reset_ip: {1000, 1_000_000},
    password_reset_email: {1000, 1_000_000},
    register_ip: {1000, 1_000_000},
    email_change_ip: {1000, 1_000_000},
    email_change_actor: {1000, 1_000_000},
    report_user: {1000, 1_000_000}
  }
```

- [ ] **Step 3: Verify it compiles**

Run: `mix compile --warnings-as-errors`
Expected: compiles with no warnings.

- [ ] **Step 4: Commit**

```bash
git add config/config.exs config/test.exs
git commit -m "feat(moderation): add report_user rate-limit bucket"
```

---

### Task 2: Rate-limit Change on the `report` action (TDD)

**Files:**
- Test: `test/verscienta/moderation/rate_limit_report_test.exs` (create)
- Create: `lib/verscienta/moderation/flag/changes/rate_limit_report.ex`
- Modify: `lib/verscienta/moderation/flag.ex` (the `report` action)

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/moderation/rate_limit_report_test.exs`. The `user/1` and `article/1` helpers are copied verbatim from `test/verscienta/moderation/flag_test.exs` (the engineer may be reading this task in isolation):

```elixir
defmodule Verscienta.Moderation.RateLimitReportTest do
  use Verscienta.DataCase, async: false

  alias Verscienta.Moderation.Flag

  setup do
    Application.put_env(:verscienta, Verscienta.RateLimit, buckets: %{report_user: {60_000, 2}})
    on_exit(fn -> Application.delete_env(:verscienta, Verscienta.RateLimit) end)
    :ok
  end

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

  defp article(author) do
    {:ok, a} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: "Flag Me", blocks: [], category: :movement},
        actor: author
      )
      |> Ash.create()

    {:ok, p} = a |> Ash.Changeset.for_update(:publish, %{}, actor: author) |> Ash.update()
    p
  end

  defp report(actor, id) do
    Flag
    |> Ash.Changeset.for_create(
      :report,
      %{subject_type: :article, subject_id: id, reason: :spam},
      actor: actor
    )
    |> Ash.create(authorize?: true)
  end

  test "denies a user after the per-user report limit across distinct subjects" do
    author = user("rl_author")
    reporter = user("rl_reporter")
    [a1, a2, a3] = Enum.map(1..3, fn _ -> article(author) end)

    # Bucket allows 2 reports per window.
    assert {:ok, _} = report(reporter, a1.id)
    assert {:ok, _} = report(reporter, a2.id)

    # Third distinct-subject report is rate-limited.
    assert {:error, error} = report(reporter, a3.id)
    assert Exception.message(error) =~ "reporting too quickly"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/verscienta/moderation/rate_limit_report_test.exs`
Expected: FAIL — the third report returns `{:ok, _}` (no limiter yet), so the `{:error, error}` match raises.

- [ ] **Step 3: Create the Change module**

Create `lib/verscienta/moderation/flag/changes/rate_limit_report.ex`:

```elixir
defmodule Verscienta.Moderation.Flag.Changes.RateLimitReport do
  @moduledoc """
  Per-user rate limit on report submissions, reusing the Hammer/ETS limiter.

  Keyed on the authenticated reporter (the `report` action always has an actor),
  this closes the "spam reports across many distinct subjects" vector that the
  `(subject_type, subject_id, reporter_id)` unique key does not.
  """
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

- [ ] **Step 4: Wire the change into the `report` action**

In `lib/verscienta/moderation/flag.ex`, add the new change immediately after the existing `CaptureSubject` change in the `report` action:

```elixir
change Verscienta.Moderation.Flag.Changes.CaptureSubject
change Verscienta.Moderation.Flag.Changes.RateLimitReport
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/verscienta/moderation/rate_limit_report_test.exs`
Expected: PASS.

- [ ] **Step 6: Run the existing flag tests to confirm no regression**

Run: `mix test test/verscienta/moderation/flag_test.exs`
Expected: PASS (these do not override the limiter; `report_user` is `{1000, 1_000_000}` in test config, so reports flow freely).

- [ ] **Step 7: Commit**

```bash
git add lib/verscienta/moderation/flag/changes/rate_limit_report.ex lib/verscienta/moderation/flag.ex test/verscienta/moderation/rate_limit_report_test.exs
git commit -m "feat(moderation): per-user rate limit on report action"
```

---

### Task 3: Friendly flash in the report dialog

**Files:**
- Modify: `lib/verscienta_web/components/report_dialog.ex:59-81`

No new automated test: the spec scopes the "limit engages" assertion to the
action-level test (Task 2), and a full live_component flash render test adds
disproportionate setup. This task is verified by compile + the manual check in
Step 3.

- [ ] **Step 1: Split the error branch and add the detector**

In `lib/verscienta_web/components/report_dialog.ex`, replace the `case Flag |> ... |> Ash.create(...) do` block inside `handle_event("submit", ...)` (currently the `{:ok, _}` / `{:error, _}` pair) with:

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
               |> put_flash(
                 :error,
                 "You're reporting too quickly. Please slow down and try again shortly."
               )}
            else
              {:noreply, assign(socket, open: false, done: true)}
            end
        end
```

Then add this private helper (place it next to `parse_reason/1`):

```elixir
  defp rate_limited?(error) do
    Exception.message(error) =~ "reporting too quickly"
  rescue
    _ -> false
  end
```

- [ ] **Step 2: Verify it compiles with no warnings**

Run: `mix compile --warnings-as-errors`
Expected: compiles cleanly.

- [ ] **Step 3: Manual verification (optional but recommended)**

With the dev server running, temporarily set `report_user: {600_000, 1}` in `config/config.exs`, submit two reports on different articles as the same user, and confirm the second submission shows the red "You're reporting too quickly…" flash instead of the "reported" label. Revert the temporary config change before committing.

- [ ] **Step 4: Commit**

```bash
git add lib/verscienta_web/components/report_dialog.ex
git commit -m "feat(moderation): flash a friendly message when report is rate-limited"
```

---

### Task 4: Check off the fast-follow item

**Files:**
- Modify: `docs/todo.md:222`

- [ ] **Step 1: Update the todo line**

In `docs/todo.md`, edit the "Moderation fast-follows" line to mark the rate-limit
portion done (leave the other two fast-follows pending):

```markdown
- [ ] Moderation fast-follows (deferred from slice 1): ~~rate-limit report submissions (Hammer, per-user)~~ *(done — per-user `report_user` bucket + dialog flash)*; reporter-resolution notifications; hide report affordance on already-reported subjects.
```

- [ ] **Step 2: Commit**

```bash
git add docs/todo.md
git commit -m "docs(moderation): check off report rate-limit fast-follow"
```

---

## Final verification

- [ ] **Run the full moderation suite**

Run: `mix test test/verscienta/moderation/`
Expected: all pass.

- [ ] **Format check**

Run: `mix format --check-formatted`
Expected: clean (run `mix format` if not).
