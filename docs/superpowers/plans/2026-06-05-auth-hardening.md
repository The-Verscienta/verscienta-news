# Auth Hardening Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the final Phase 1 auth follow-ups to Verscienta — rate limiting on auth actions, confirm-first email change, and 30-day-grace soft-delete account deletion.

**Architecture:** Three loosely-coupled units on top of the existing AshAuthentication setup. Rate limiting is enforced inside the Ash actions (`Verscienta.RateLimit` wraps Hammer/ETS; client IP threaded via an `on_mount` seam). Email change uses a second AshAuthentication confirmation add-on that holds the change until the new address confirms. Account deletion deactivates immediately and an Oban worker anonymizes the `User` row (in place — no content rows touched) after 30 days.

**Tech Stack:** Elixir 1.18 / Phoenix 1.8, Ash 3 + AshPostgres 2 + AshAuthentication 4, Oban 2.18, Hammer 7 (ETS), Swoosh, LiveView 1.1.

**Spec:** `docs/superpowers/specs/2026-06-05-auth-hardening-design.md`

---

## Conventions (read once)

- **All `mix` commands run in Docker:** `docker compose run --rm app bash -lc "<cmd>"`. The host has no stable Elixir. Example test run: `docker compose run --rm app bash -lc "mix test test/verscienta/rate_limit_test.exs"`.
- **Branch:** work is on `auth-hardening` (already created). Commit after every green task.
- **Ash migrations:** change the resource, then `mix ash.codegen <name>` generates the migration from the snapshot diff; apply with `mix ecto.migrate`.
- **Tests:** ExUnit. DB tests use the sandbox via `Verscienta.DataCase` / `VerscientaWeb.ConnCase`. User fixture + sign-in helper pattern is in `test/verscienta_web/live/settings_live_test.exs` (`create_user/1`, `sign_in/2`) — reuse it.
- **Commit trailer:** end every commit message with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File Structure

**Created:**
- `lib/verscienta/rate_limit.ex` — Hammer/ETS wrapper; bucket configs; `check/2` (fail-open).
- `lib/verscienta/accounts/preparations/rate_limit_sign_in.ex` — preparation on `sign_in_with_password`.
- `lib/verscienta/accounts/changes/rate_limit_register.ex` — change on `register_with_password`.
- `lib/verscienta/accounts/actions/rate_limited_password_reset.ex` — generic-action run wrapper for reset request.
- `lib/verscienta/accounts/user/senders/send_email_change_confirmation_email.ex` — to the NEW address.
- `lib/verscienta/accounts/user/senders/send_email_changed_notification_email.ex` — to the OLD address.
- `lib/verscienta/accounts/workers/account_purge_worker.ex` — daily Oban cron anonymizer.
- `lib/verscienta_web/live/goodbye_live.ex` — post-deletion confirmation page.
- Tests for each (paths under `test/` mirroring the above).

**Modified:**
- `mix.exs` — add `{:hammer, "~> 7.0"}`.
- `lib/verscienta/application.ex` — start `Verscienta.RateLimit`.
- `lib/verscienta_web/endpoint.ex` — add `:peer_data`, `:x_headers` to LiveView `connect_info`.
- `lib/verscienta_web/live_user_auth.ex` — add `:capture_client_ip` and deactivated-session handling.
- `lib/verscienta/accounts/user.ex` — confirmation add-on for email change; new attributes; new actions (`request_email_change`, `request_deletion`, `cancel_deletion`, `anonymize`); sign-in rejection; policies.
- `lib/verscienta_web/live/settings_live.ex` — change-email form + danger-zone delete form.
- `lib/verscienta_web/router.ex` — `/goodbye` route; `:capture_client_ip` on auth live_sessions.
- `config/config.exs` — rate-limit bucket config; `AccountPurgeWorker` cron.
- `config/test.exs` — loosened rate-limit config.
- `lib/verscienta/content/article.ex` — filter content authored by deactivated users from the feed read.

---

## TASK GROUP 0 — Rate-limit core

### Task 1: `Verscienta.RateLimit` wrapper + Hammer dep

**Files:**
- Modify: `mix.exs`
- Create: `lib/verscienta/rate_limit.ex`
- Modify: `lib/verscienta/application.ex`
- Modify: `config/config.exs`, `config/test.exs`
- Test: `test/verscienta/rate_limit_test.exs`

- [ ] **Step 1: Add the dependency**

In `mix.exs`, in the `deps` list (near `{:oban, "~> 2.18"}`), add:

```elixir
      {:hammer, "~> 7.0"},
```

Run: `docker compose run --rm app bash -lc "mix deps.get"`
Expected: hammer (and its deps) resolve and compile.

- [ ] **Step 2: Write the failing test**

Create `test/verscienta/rate_limit_test.exs`:

```elixir
defmodule Verscienta.RateLimitTest do
  use ExUnit.Case, async: false

  alias Verscienta.RateLimit

  setup do
    # Tight, deterministic limits for the test.
    Application.put_env(:verscienta, RateLimit,
      buckets: %{test_bucket: {60_000, 2}}
    )

    on_exit(fn -> Application.delete_env(:verscienta, RateLimit) end)
    :ok
  end

  test "allows up to the limit then denies" do
    key = "user-#{System.unique_integer([:positive])}"
    assert RateLimit.check(:test_bucket, key) == :ok
    assert RateLimit.check(:test_bucket, key) == :ok
    assert {:error, retry_after} = RateLimit.check(:test_bucket, key)
    assert is_integer(retry_after) and retry_after > 0
  end

  test "different keys have independent buckets" do
    assert RateLimit.check(:test_bucket, "a") == :ok
    assert RateLimit.check(:test_bucket, "a") == :ok
    assert {:error, _} = RateLimit.check(:test_bucket, "a")
    # A fresh key is unaffected.
    assert RateLimit.check(:test_bucket, "b") == :ok
  end

  test "unknown bucket fails open" do
    assert RateLimit.check(:no_such_bucket, "x") == :ok
  end
end
```

- [ ] **Step 3: Run it to confirm it fails**

Run: `docker compose run --rm app bash -lc "mix test test/verscienta/rate_limit_test.exs"`
Expected: FAIL — `Verscienta.RateLimit` is undefined.

- [ ] **Step 4: Implement `Verscienta.RateLimit`**

Create `lib/verscienta/rate_limit.ex`:

```elixir
defmodule Verscienta.RateLimit do
  @moduledoc """
  Thin wrapper over Hammer (ETS backend) for auth rate limiting.

  Buckets are `{scale_ms, limit}` pairs defined in config so they're tunable per
  environment. `check/2` is **fail-open**: any backend error or unknown bucket
  returns `:ok` so a limiter hiccup never locks users out of auth.

  Swapping to a Redis backend later is a one-line change to the `use Hammer`
  line plus config; callers are unaffected.
  """
  use Hammer, backend: :ets

  require Logger

  @default_buckets %{
    sign_in_ip: {300_000, 10},
    sign_in_email: {900_000, 5},
    password_reset_ip: {900_000, 5},
    password_reset_email: {3_600_000, 3},
    register_ip: {3_600_000, 5},
    email_change_ip: {3_600_000, 5},
    email_change_actor: {3_600_000, 3}
  }

  @doc """
  Check a bucket for `key`. Returns `:ok` if under the limit, or
  `{:error, retry_after_seconds}` if over. Fails open on any error.
  """
  @spec check(atom(), String.t() | nil) :: :ok | {:error, pos_integer()}
  def check(_bucket, nil), do: :ok

  def check(bucket, key) when is_atom(bucket) and is_binary(key) do
    case Map.fetch(buckets(), bucket) do
      {:ok, {scale_ms, limit}} ->
        case hit("#{bucket}:#{key}", scale_ms, limit) do
          {:allow, _count} -> :ok
          {:deny, retry_ms} -> {:error, max(div(retry_ms, 1000), 1)}
        end

      :error ->
        :ok
    end
  rescue
    e ->
      Logger.warning("RateLimit backend error on #{inspect(bucket)}: #{inspect(e)}")
      :ok
  end

  defp buckets do
    Application.get_env(:verscienta, __MODULE__, [])
    |> Keyword.get(:buckets, @default_buckets)
  end
end
```

- [ ] **Step 5: Start it in the supervision tree**

In `lib/verscienta/application.ex`, add `Verscienta.RateLimit` to the `children` list (after `Verscienta.Cache.Subscriber`, before `{Oban, ...}`):

```elixir
        Verscienta.Cache.Subscriber,
        {Verscienta.RateLimit, [clean_period: :timer.minutes(10)]},
        {Oban, Application.fetch_env!(:verscienta, Oban)},
```

- [ ] **Step 6: Add base config**

In `config/config.exs` (anywhere after the Oban block), add the default production-ish buckets so they're explicit and tunable:

```elixir
config :verscienta, Verscienta.RateLimit,
  buckets: %{
    sign_in_ip: {300_000, 10},
    sign_in_email: {900_000, 5},
    password_reset_ip: {900_000, 5},
    password_reset_email: {3_600_000, 3},
    register_ip: {3_600_000, 5},
    email_change_ip: {3_600_000, 5},
    email_change_actor: {3_600_000, 3}
  }
```

In `config/test.exs`, loosen so existing auth tests aren't throttled:

```elixir
# Effectively disable auth rate limiting in tests (rate-limit tests override per-test).
config :verscienta, Verscienta.RateLimit,
  buckets: %{
    sign_in_ip: {1000, 1_000_000},
    sign_in_email: {1000, 1_000_000},
    password_reset_ip: {1000, 1_000_000},
    password_reset_email: {1000, 1_000_000},
    register_ip: {1000, 1_000_000},
    email_change_ip: {1000, 1_000_000},
    email_change_actor: {1000, 1_000_000}
  }
```

- [ ] **Step 7: Run the test to confirm it passes**

Run: `docker compose run --rm app bash -lc "mix test test/verscienta/rate_limit_test.exs"`
Expected: PASS (3 tests). Note: the test sets its own `:test_bucket` via `Application.put_env`, overriding config.

- [ ] **Step 8: Commit**

```bash
git add mix.exs mix.lock lib/verscienta/rate_limit.ex lib/verscienta/application.ex config/config.exs config/test.exs test/verscienta/rate_limit_test.exs
git commit -m "feat(auth): add Verscienta.RateLimit Hammer/ETS wrapper"
```

---

### Task 2: Client-IP capture seam

**Files:**
- Modify: `lib/verscienta_web/endpoint.ex`
- Modify: `lib/verscienta_web/live_user_auth.ex`
- Test: `test/verscienta_web/live_user_auth_ip_test.exs`

- [ ] **Step 1: Extend the LiveView socket `connect_info`**

In `lib/verscienta_web/endpoint.ex`, change the `socket "/live"` line to pass peer + forwarded headers:

```elixir
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, :x_headers, session: @session_options]],
    longpoll: [connect_info: [:peer_data, :x_headers, session: @session_options]]
```

- [ ] **Step 2: Write the failing test**

Create `test/verscienta_web/live_user_auth_ip_test.exs`:

```elixir
defmodule VerscientaWeb.LiveUserAuthIpTest do
  use ExUnit.Case, async: false

  alias VerscientaWeb.LiveUserAuth

  test "client_ip prefers left-most x-forwarded-for entry" do
    info = %{x_headers: [{"x-forwarded-for", "203.0.113.7, 10.0.0.1"}]}
    assert LiveUserAuth.client_ip_from_connect_info(info) == "203.0.113.7"
  end

  test "client_ip falls back to peer_data address" do
    info = %{peer_data: %{address: {198, 51, 100, 9}}}
    assert LiveUserAuth.client_ip_from_connect_info(info) == "198.51.100.9"
  end

  test "client_ip is nil when nothing is available" do
    assert LiveUserAuth.client_ip_from_connect_info(%{}) == nil
  end
end
```

- [ ] **Step 3: Run it to confirm it fails**

Run: `docker compose run --rm app bash -lc "mix test test/verscienta_web/live_user_auth_ip_test.exs"`
Expected: FAIL — `client_ip_from_connect_info/1` undefined.

- [ ] **Step 4: Implement the on_mount hook + helper**

In `lib/verscienta_web/live_user_auth.ex`, add the `:capture_client_ip` clause and the pure helper (and `import` is already minimal — use fully-qualified calls):

```elixir
  @doc """
  Stashes the connecting client's IP in the process dictionary so Ash action
  preparations/changes (which run in this same LiveView process when the
  AshAuthentication form components submit) can read it for rate limiting.
  """
  def on_mount(:capture_client_ip, _params, _session, socket) do
    if Phoenix.LiveView.connected?(socket) do
      ip =
        socket
        |> Phoenix.LiveView.get_connect_info(:x_headers)
        |> then(fn x_headers ->
          client_ip_from_connect_info(%{
            x_headers: x_headers || [],
            peer_data: Phoenix.LiveView.get_connect_info(socket, :peer_data) || %{}
          })
        end)

      if ip, do: Process.put(:auth_client_ip, ip)
    end

    {:cont, socket}
  end

  @doc false
  def client_ip_from_connect_info(info) do
    forwarded =
      info
      |> Map.get(:x_headers, [])
      |> List.keyfind("x-forwarded-for", 0)

    cond do
      match?({"x-forwarded-for", _}, forwarded) ->
        {"x-forwarded-for", value} = forwarded

        value
        |> String.split(",")
        |> List.first()
        |> String.trim()

      match?(%{address: _}, Map.get(info, :peer_data)) ->
        %{address: address} = info.peer_data
        address |> :inet.ntoa() |> to_string()

      true ->
        nil
    end
  end
```

- [ ] **Step 5: Run the test to confirm it passes**

Run: `docker compose run --rm app bash -lc "mix test test/verscienta_web/live_user_auth_ip_test.exs"`
Expected: PASS (3 tests).

- [ ] **Step 6: Wire `:capture_client_ip` into the auth live_sessions**

In `lib/verscienta_web/router.ex`, add the hook to the sign-in and reset routes so it runs for sign-in, register, and reset forms:

```elixir
    sign_in_route register_path: "/register",
                  reset_path: "/reset",
                  auth_routes_prefix: "/auth",
                  on_mount: [
                    {VerscientaWeb.LiveUserAuth, :live_no_user},
                    {VerscientaWeb.LiveUserAuth, :capture_client_ip}
                  ],
                  overrides: [
                    VerscientaWeb.AuthOverrides,
                    Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI
                  ]

    reset_route auth_routes_prefix: "/auth",
                on_mount: [{VerscientaWeb.LiveUserAuth, :capture_client_ip}],
                overrides: [
                  VerscientaWeb.AuthOverrides,
                  Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI
                ]
```

- [ ] **Step 7: Verify compile + full suite still green**

Run: `docker compose run --rm app bash -lc "mix compile --warnings-as-errors && mix test"`
Expected: compiles clean; existing suite passes (rate limits loosened in test).

- [ ] **Step 8: Commit**

```bash
git add lib/verscienta_web/endpoint.ex lib/verscienta_web/live_user_auth.ex lib/verscienta_web/router.ex test/verscienta_web/live_user_auth_ip_test.exs
git commit -m "feat(auth): capture client IP for action-layer rate limiting"
```

---

## TASK GROUP A — Rate limit the auth actions

### Task 3: Rate-limit `sign_in_with_password`

**Files:**
- Create: `lib/verscienta/accounts/preparations/rate_limit_sign_in.ex`
- Modify: `lib/verscienta/accounts/user.ex` (sign_in action)
- Test: `test/verscienta/accounts/rate_limit_sign_in_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/accounts/rate_limit_sign_in_test.exs`:

```elixir
defmodule Verscienta.Accounts.RateLimitSignInTest do
  use Verscienta.DataCase, async: false

  alias Verscienta.Accounts.User

  setup do
    Application.put_env(:verscienta, Verscienta.RateLimit,
      buckets: %{sign_in_ip: {60_000, 1_000_000}, sign_in_email: {60_000, 2}}
    )

    on_exit(fn -> Application.delete_env(:verscienta, Verscienta.RateLimit) end)

    user =
      User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: "ratelimit@example.com",
        username: "ratelimituser",
        password: "password123",
        password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    %{user: user}
  end

  test "denies sign-in after the per-email limit with a clear error" do
    attempt = fn ->
      User
      |> Ash.Query.for_read(:sign_in_with_password, %{
        email: "ratelimit@example.com",
        password: "wrong-password"
      })
      |> Ash.read_one()
    end

    # First two attempts fail on credentials (allowed by limiter).
    assert {:error, _} = attempt.()
    assert {:error, _} = attempt.()

    # Third attempt is rate-limited.
    assert {:error, error} = attempt.()
    assert Exception.message(error) =~ "Too many"
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `docker compose run --rm app bash -lc "mix test test/verscienta/accounts/rate_limit_sign_in_test.exs"`
Expected: FAIL — the third attempt is not yet rate-limited (no "Too many" message).

- [ ] **Step 3: Implement the preparation**

Create `lib/verscienta/accounts/preparations/rate_limit_sign_in.ex`:

```elixir
defmodule Verscienta.Accounts.Preparations.RateLimitSignIn do
  @moduledoc "Rate-limits sign-in attempts by client IP and target email."
  use Ash.Resource.Preparation

  alias Verscienta.RateLimit

  @impl true
  def prepare(query, _opts, _context) do
    email = query |> Ash.Query.get_argument(:email) |> to_string() |> String.downcase()
    ip = Process.get(:auth_client_ip)

    with :ok <- RateLimit.check(:sign_in_ip, ip),
         :ok <- RateLimit.check(:sign_in_email, email) do
      query
    else
      {:error, retry_after} ->
        Ash.Query.add_error(query,
          field: :password,
          message: "Too many attempts. Try again in #{retry_after} seconds."
        )
    end
  end
end
```

- [ ] **Step 4: Register the preparation FIRST on the sign-in action**

In `lib/verscienta/accounts/user.ex`, in `read :sign_in_with_password`, add the new preparation **before** the existing `SignInPreparation` (order matters — the limiter must run first):

```elixir
      # validates the provided email and password and generates a token
      prepare Verscienta.Accounts.Preparations.RateLimitSignIn
      prepare AshAuthentication.Strategy.Password.SignInPreparation
```

- [ ] **Step 5: Run the test to confirm it passes**

Run: `docker compose run --rm app bash -lc "mix test test/verscienta/accounts/rate_limit_sign_in_test.exs"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta/accounts/preparations/rate_limit_sign_in.ex lib/verscienta/accounts/user.ex test/verscienta/accounts/rate_limit_sign_in_test.exs
git commit -m "feat(auth): rate-limit sign-in by IP and email"
```

---

### Task 4: Rate-limit `register_with_password` (per-IP)

**Files:**
- Create: `lib/verscienta/accounts/changes/rate_limit_register.ex`
- Modify: `lib/verscienta/accounts/user.ex` (register action)
- Test: `test/verscienta/accounts/rate_limit_register_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/accounts/rate_limit_register_test.exs`:

```elixir
defmodule Verscienta.Accounts.RateLimitRegisterTest do
  use Verscienta.DataCase, async: false

  alias Verscienta.Accounts.User

  setup do
    Application.put_env(:verscienta, Verscienta.RateLimit, buckets: %{register_ip: {60_000, 2}})
    on_exit(fn -> Application.delete_env(:verscienta, Verscienta.RateLimit) end)
    Process.put(:auth_client_ip, "203.0.113.50")
    on_exit(fn -> Process.delete(:auth_client_ip) end)
    :ok
  end

  defp register(n) do
    User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: "reg#{n}@example.com",
      username: "reguser#{n}",
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create(authorize?: false)
  end

  test "denies registration from one IP after the limit" do
    assert {:ok, _} = register(1)
    assert {:ok, _} = register(2)
    assert {:error, error} = register(3)
    assert Exception.message(error) =~ "Too many"
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `docker compose run --rm app bash -lc "mix test test/verscienta/accounts/rate_limit_register_test.exs"`
Expected: FAIL — third registration succeeds (not yet limited).

- [ ] **Step 3: Implement the change**

Create `lib/verscienta/accounts/changes/rate_limit_register.ex`:

```elixir
defmodule Verscienta.Accounts.Changes.RateLimitRegister do
  @moduledoc "Rate-limits registration by client IP."
  use Ash.Resource.Change

  alias Verscienta.RateLimit

  @impl true
  def change(changeset, _opts, _context) do
    case RateLimit.check(:register_ip, Process.get(:auth_client_ip)) do
      :ok ->
        changeset

      {:error, retry_after} ->
        Ash.Changeset.add_error(changeset,
          field: :email,
          message: "Too many attempts. Try again in #{retry_after} seconds."
        )
    end
  end
end
```

- [ ] **Step 4: Register the change FIRST on the register action**

In `lib/verscienta/accounts/user.ex`, in `create :register_with_password`, add as the first `change`:

```elixir
      # Rate-limit by IP before any work
      change Verscienta.Accounts.Changes.RateLimitRegister

      # Sets the email from the argument
      change set_attribute(:email, arg(:email))
```

- [ ] **Step 5: Run the test to confirm it passes**

Run: `docker compose run --rm app bash -lc "mix test test/verscienta/accounts/rate_limit_register_test.exs"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta/accounts/changes/rate_limit_register.ex lib/verscienta/accounts/user.ex test/verscienta/accounts/rate_limit_register_test.exs
git commit -m "feat(auth): rate-limit registration by IP"
```

---

### Task 5: Rate-limit `request_password_reset_token`

**Files:**
- Create: `lib/verscienta/accounts/actions/rate_limited_password_reset.ex`
- Modify: `lib/verscienta/accounts/user.ex` (reset request action)
- Test: `test/verscienta/accounts/rate_limit_password_reset_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/accounts/rate_limit_password_reset_test.exs`:

```elixir
defmodule Verscienta.Accounts.RateLimitPasswordResetTest do
  use Verscienta.DataCase, async: false

  alias Verscienta.Accounts.User

  setup do
    Application.put_env(:verscienta, Verscienta.RateLimit,
      buckets: %{password_reset_ip: {60_000, 1_000_000}, password_reset_email: {60_000, 2}}
    )

    on_exit(fn -> Application.delete_env(:verscienta, Verscienta.RateLimit) end)
    :ok
  end

  defp request_reset do
    User
    |> Ash.ActionInput.for_action(:request_password_reset_token, %{email: "reset@example.com"})
    |> Ash.run_action()
  end

  test "denies repeated reset requests for one email after the limit" do
    assert :ok = request_reset()
    assert :ok = request_reset()
    assert {:error, error} = request_reset()
    assert Exception.message(error) =~ "Too many"
  end
end
```

(Note: `request_password_reset_token` returns `:ok` whether or not the email exists, by design — it must not leak account existence.)

- [ ] **Step 2: Run it to confirm it fails**

Run: `docker compose run --rm app bash -lc "mix test test/verscienta/accounts/rate_limit_password_reset_test.exs"`
Expected: FAIL — third request returns `:ok` (not yet limited).

- [ ] **Step 3: Implement the run wrapper**

Create `lib/verscienta/accounts/actions/rate_limited_password_reset.ex`:

```elixir
defmodule Verscienta.Accounts.Actions.RateLimitedPasswordReset do
  @moduledoc """
  Wraps AshAuthentication's password-reset request run with IP + email rate
  limiting. Delegates to the original implementation when under the limit.
  """
  use Ash.Resource.Actions.Implementation

  alias AshAuthentication.Strategy.Password.RequestPasswordReset
  alias Verscienta.RateLimit

  @impl true
  def run(input, _opts, context) do
    email = input.arguments |> Map.get(:email) |> to_string() |> String.downcase()
    ip = Process.get(:auth_client_ip)

    with :ok <- RateLimit.check(:password_reset_ip, ip),
         :ok <- RateLimit.check(:password_reset_email, email) do
      RequestPasswordReset.run(input, [action: :get_by_email], context)
    else
      {:error, retry_after} ->
        {:error, "Too many attempts. Try again in #{retry_after} seconds."}
    end
  end
end
```

- [ ] **Step 4: Swap the action's `run`**

In `lib/verscienta/accounts/user.ex`, in `action :request_password_reset_token`, replace the `run` line:

```elixir
      # creates a reset token and invokes the relevant senders, behind a rate limiter
      run Verscienta.Accounts.Actions.RateLimitedPasswordReset
```

- [ ] **Step 5: Run the test + verify compile**

Run: `docker compose run --rm app bash -lc "mix compile --warnings-as-errors && mix test test/verscienta/accounts/rate_limit_password_reset_test.exs"`
Expected: PASS.

> If `RequestPasswordReset.run/3`'s arity/opts differ in the installed AshAuthentication 4.x, check `docker compose run --rm app bash -lc "mix run -e 'h AshAuthentication.Strategy.Password.RequestPasswordReset'"` and match the delegated call.

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta/accounts/actions/rate_limited_password_reset.ex lib/verscienta/accounts/user.ex test/verscienta/accounts/rate_limit_password_reset_test.exs
git commit -m "feat(auth): rate-limit password-reset requests by IP and email"
```

---

## TASK GROUP B — Email change (confirm new address first)

### Task 6: Email-change senders

**Files:**
- Create: `lib/verscienta/accounts/user/senders/send_email_change_confirmation_email.ex`
- Create: `lib/verscienta/accounts/user/senders/send_email_changed_notification_email.ex`
- Test: `test/verscienta/accounts/email_change_senders_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/accounts/email_change_senders_test.exs`:

```elixir
defmodule Verscienta.Accounts.EmailChangeSendersTest do
  use ExUnit.Case, async: true
  import Swoosh.TestAssertions

  alias Verscienta.Accounts.User.Senders.SendEmailChangeConfirmationEmail
  alias Verscienta.Accounts.User.Senders.SendEmailChangedNotificationEmail

  test "confirmation email goes to the new address with a confirm link" do
    user = %{email: %Ash.CiString{string: "new@example.com"}}
    SendEmailChangeConfirmationEmail.send(user, "tok123", [])

    assert_email_sent(fn email ->
      assert {_, "new@example.com"} = email.to |> List.first()
      assert email.html_body =~ "tok123"
    end)
  end

  test "notification email goes to the old address" do
    SendEmailChangedNotificationEmail.send_to("old@example.com")

    assert_email_sent(fn email ->
      assert {_, "old@example.com"} = email.to |> List.first()
      assert email.subject =~ "email"
    end)
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `docker compose run --rm app bash -lc "mix test test/verscienta/accounts/email_change_senders_test.exs"`
Expected: FAIL — sender modules undefined.

- [ ] **Step 3: Implement the confirmation sender (to the NEW address)**

Create `lib/verscienta/accounts/user/senders/send_email_change_confirmation_email.ex`:

```elixir
defmodule Verscienta.Accounts.User.Senders.SendEmailChangeConfirmationEmail do
  @moduledoc "Sends an email-change confirmation link to the new address."
  use AshAuthentication.Sender
  use VerscientaWeb, :verified_routes

  import Swoosh.Email

  alias Verscienta.Mailer

  @impl true
  def send(user, token, _opts) do
    new()
    |> from({"Verscienta News", "noreply@verscienta.news"})
    |> to(to_string(user.email))
    |> subject("Confirm your new email address")
    |> html_body(body(token))
    |> Mailer.deliver!()
  end

  defp body(token) do
    url = url(~p"/auth/user/confirm_change?#{[confirm: token]}")

    """
    <p>Click to confirm your new email address for Verscienta News:</p>
    <p><a href="#{url}">#{url}</a></p>
    <p>If you didn't request this, you can ignore this email.</p>
    """
  end
end
```

> The exact confirm path comes from the `confirm_route` you add in Task 7; adjust `~p"/auth/user/confirm_change"` to match the generated route after Task 7 step 4.

- [ ] **Step 4: Implement the notification sender (to the OLD address)**

Create `lib/verscienta/accounts/user/senders/send_email_changed_notification_email.ex`:

```elixir
defmodule Verscienta.Accounts.User.Senders.SendEmailChangedNotificationEmail do
  @moduledoc "Notifies the old address that an email change was requested."
  use VerscientaWeb, :verified_routes

  import Swoosh.Email

  alias Verscienta.Mailer

  @doc "Send the heads-up notification to the previous address."
  def send_to(old_email) when is_binary(old_email) do
    new()
    |> from({"Verscienta News", "noreply@verscienta.news"})
    |> to(old_email)
    |> subject("Your Verscienta email change was requested")
    |> html_body("""
    <p>Someone requested changing the email address on your Verscienta News account.</p>
    <p>If this was you, no action is needed — confirm via the link sent to your new address.</p>
    <p>If this <strong>wasn't</strong> you, please reset your password immediately:
    <a href="#{url(~p"/reset")}">#{url(~p"/reset")}</a></p>
    """)
    |> Mailer.deliver!()
  end
end
```

- [ ] **Step 5: Run the test to confirm it passes**

Run: `docker compose run --rm app bash -lc "mix test test/verscienta/accounts/email_change_senders_test.exs"`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta/accounts/user/senders/send_email_change_confirmation_email.ex lib/verscienta/accounts/user/senders/send_email_changed_notification_email.ex test/verscienta/accounts/email_change_senders_test.exs
git commit -m "feat(auth): email-change confirmation + old-address notification senders"
```

---

### Task 7: `request_email_change` action + confirm-before-swap add-on

**Files:**
- Modify: `lib/verscienta/accounts/user.ex` (add-on, action, policy)
- Modify: `lib/verscienta_web/router.ex` (confirm route)
- Test: `test/verscienta/accounts/email_change_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/accounts/email_change_test.exs`:

```elixir
defmodule Verscienta.Accounts.EmailChangeTest do
  use Verscienta.DataCase, async: true
  import Swoosh.TestAssertions

  alias Verscienta.Accounts.User

  defp user do
    User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: "old@example.com",
      username: "changer",
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  test "request_email_change with correct password does NOT swap email immediately" do
    u = user()

    {:ok, updated} =
      u
      |> Ash.Changeset.for_update(:request_email_change, %{
        new_email: "new@example.com",
        current_password: "password123"
      }, actor: u)
      |> Ash.update()

    # Email is held until confirmation — still the old address.
    assert to_string(updated.email) == "old@example.com"
    # Confirmation email sent to the new address.
    assert_email_sent(fn e -> {_, "new@example.com"} = List.first(e.to) end)
    # Notification sent to the old address.
    assert_email_sent(fn e -> {_, "old@example.com"} = List.first(e.to) end)
  end

  test "request_email_change with wrong password is rejected" do
    u = user()

    assert {:error, _} =
             u
             |> Ash.Changeset.for_update(:request_email_change, %{
               new_email: "new@example.com",
               current_password: "wrong"
             }, actor: u)
             |> Ash.update()
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `docker compose run --rm app bash -lc "mix test test/verscienta/accounts/email_change_test.exs"`
Expected: FAIL — `request_email_change` action undefined.

- [ ] **Step 3: Add the confirm-before-swap confirmation add-on**

In `lib/verscienta/accounts/user.ex`, inside `add_ons do ... end` (alongside `confirm_new_user`), add a second confirmation that monitors email on update and **holds** the change until confirmed:

```elixir
      confirmation :confirm_email_change do
        monitor_fields [:email]
        confirm_on_create? false
        confirm_on_update? true
        # Hold the new email out of the record until the new address confirms.
        inhibit_updates? true
        require_interaction? true
        confirmed_at_field :confirmed_at
        sender Verscienta.Accounts.User.Senders.SendEmailChangeConfirmationEmail
      end
```

> Verify option names against the installed version: `docker compose run --rm app bash -lc "mix run -e 'h AshAuthentication.AddOn.Confirmation'"`. `inhibit_updates?` + `confirm_on_update?` is the documented "confirm before applying" combination; adjust if the installed 4.x names differ.

- [ ] **Step 4: Add the confirm route**

In `lib/verscienta_web/router.ex`, after the existing `confirm_route Verscienta.Accounts.User, :confirm_new_user, ...`, add:

```elixir
    confirm_route Verscienta.Accounts.User, :confirm_email_change,
      auth_routes_prefix: "/auth",
      overrides: [VerscientaWeb.AuthOverrides, Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI]
```

Then update the confirm URL path in `SendEmailChangeConfirmationEmail.body/1` (Task 6 step 3) to the route this generates — run `docker compose run --rm app bash -lc "mix phx.routes | grep confirm"` to read the exact path and set `~p"..."` accordingly.

- [ ] **Step 5: Add the `request_email_change` update action**

In `lib/verscienta/accounts/user.ex`, in the `actions do` block, add:

```elixir
    update :request_email_change do
      description "Request an email change; confirms the new address before applying."
      require_atomic? false
      accept []

      argument :new_email, :ci_string, allow_nil?: false
      argument :current_password, :string, sensitive?: true, allow_nil?: false

      # Verify the current password (same mechanism as change_password).
      validate {AshAuthentication.Strategy.Password.PasswordValidation,
                strategy_name: :password, password_argument: :current_password}

      # Per-actor + per-IP rate limit.
      change fn changeset, %{actor: actor} ->
        ip = Process.get(:auth_client_ip)
        actor_key = if actor, do: to_string(actor.id), else: nil

        with :ok <- Verscienta.RateLimit.check(:email_change_ip, ip),
             :ok <- Verscienta.RateLimit.check(:email_change_actor, actor_key) do
          changeset
        else
          {:error, retry} ->
            Ash.Changeset.add_error(changeset,
              field: :new_email,
              message: "Too many attempts. Try again in #{retry} seconds."
            )
        end
      end

      # Stage the new email — the confirm_email_change add-on inhibits the actual
      # swap until the new address confirms.
      change set_attribute(:email, arg(:new_email))

      # Notify the OLD address after the change is staged.
      change after_action(fn changeset, result, _context ->
               old_email = to_string(changeset.data.email)
               Verscienta.Accounts.User.Senders.SendEmailChangedNotificationEmail.send_to(old_email)
               {:ok, result}
             end)
    end
```

- [ ] **Step 6: Add the policy**

In `lib/verscienta/accounts/user.ex`, in `policies do`, add (next to `update_profile`):

```elixir
    policy action(:request_email_change) do
      authorize_if expr(id == ^actor(:id))
    end
```

- [ ] **Step 7: Run the test + compile**

Run: `docker compose run --rm app bash -lc "mix compile --warnings-as-errors && mix test test/verscienta/accounts/email_change_test.exs"`
Expected: PASS (2 tests).

> If `inhibit_updates?` causes `email` to remain old in the result (it should), the first test passes. If the add-on swaps immediately in this version, consult the `h` output from step 3 and switch to a `pending_email` attribute approach (documented as the fallback in the spec).

- [ ] **Step 8: Commit**

```bash
git add lib/verscienta/accounts/user.ex lib/verscienta_web/router.ex lib/verscienta/accounts/user/senders/send_email_change_confirmation_email.ex test/verscienta/accounts/email_change_test.exs
git commit -m "feat(auth): confirm-first email change with old-address notice + rate limit"
```

---

### Task 8: Settings UI — change-email form

**Files:**
- Modify: `lib/verscienta_web/live/settings_live.ex`
- Test: `test/verscienta_web/live/settings_email_change_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/settings_email_change_test.exs`:

```elixir
defmodule VerscientaWeb.SettingsEmailChangeTest do
  use VerscientaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias AshAuthentication.Plug.Helpers
  alias Verscienta.Accounts.User

  defp create_user do
    User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: "emailer@example.com",
      username: "emailer",
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp sign_in(conn, user) do
    conn |> Plug.Test.init_test_session(%{}) |> Helpers.store_in_session(user)
  end

  test "submitting the email-change form sends confirmation and keeps old email", %{conn: conn} do
    user = create_user()
    conn = sign_in(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/settings")

    lv
    |> form("#email-change-form", email_change: %{
      "new_email" => "fresh@example.com",
      "current_password" => "password123"
    })
    |> render_submit()

    assert_email_sent(fn e -> {_, "fresh@example.com"} = List.first(e.to) end)
    assert to_string(Ash.get!(User, user.id, authorize?: false).email) == "emailer@example.com"
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `docker compose run --rm app bash -lc "mix test test/verscienta_web/live/settings_email_change_test.exs"`
Expected: FAIL — no `#email-change-form` in the page.

- [ ] **Step 3: Add the email-change form + handler**

In `lib/verscienta_web/live/settings_live.ex`, in `mount/3`, build an email-change form and assign it. Add after `assign_form`:

```elixir
     |> assign_email_form()}
  end

  defp assign_email_form(socket) do
    user = socket.assigns.current_user

    form =
      user
      |> AshPhoenix.Form.for_update(:request_email_change, as: "email_change", actor: user)
      |> to_form()

    assign(socket, email_form: form)
  end
```

Add the handlers (after the existing `handle_event("save", ...)`):

```elixir
  @impl true
  def handle_event("validate_email", %{"email_change" => params}, socket) do
    {:noreply, assign(socket, email_form: AshPhoenix.Form.validate(socket.assigns.email_form, params))}
  end

  @impl true
  def handle_event("change_email", %{"email_change" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.email_form, params: params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Check your new inbox to confirm the change.")
         |> assign_email_form()}

      {:error, form} ->
        {:noreply, assign(socket, email_form: form)}
    end
  end
```

Add the markup (inside `render/1`, after the notifications `</section>`):

```heex
      <section class="mt-12 max-w-xl">
        <h2 class="mb-4 text-sm lowercase tracking-wider text-ink-3">email address</h2>
        <p class="mb-4 text-xs text-ink-3">
          Current: {to_string(@current_user.email)}. Changing it requires confirming the new address.
        </p>
        <.form
          :let={f}
          for={@email_form}
          id="email-change-form"
          phx-change="validate_email"
          phx-submit="change_email"
          class="space-y-4"
        >
          <.text_field field={f[:new_email]} label="new email" />
          <div>
            <label class="mb-1 block text-[11px] uppercase tracking-widest text-ink-3">current password</label>
            <input
              type="password"
              name={f[:current_password].name}
              class="w-full border border-line bg-canvas-2 px-4 py-3 text-ink"
            />
            <p :for={msg <- field_errors(f[:current_password])} class="mt-1 text-xs text-politics">{msg}</p>
          </div>
          <button type="submit" class="border border-zune px-4 py-2 text-[11px] font-bold uppercase tracking-wider text-zune hover:bg-zune hover:text-black">
            request email change
          </button>
        </.form>
      </section>
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `docker compose run --rm app bash -lc "mix test test/verscienta_web/live/settings_email_change_test.exs"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta_web/live/settings_live.ex test/verscienta_web/live/settings_email_change_test.exs
git commit -m "feat(settings): password-gated change-email form"
```

---

## TASK GROUP C — Account deletion (30-day grace, anonymize)

### Task 9: Deletion-state attributes + migration

**Files:**
- Modify: `lib/verscienta/accounts/user.ex` (attributes)
- Create: migration (generated)
- Test: `test/verscienta/accounts/user_deletion_fields_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/accounts/user_deletion_fields_test.exs`:

```elixir
defmodule Verscienta.Accounts.UserDeletionFieldsTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Accounts.User

  test "new users start active (no deletion timestamps)" do
    user =
      User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: "fields@example.com",
        username: "fieldsuser",
        password: "password123",
        password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    assert user.deactivated_at == nil
    assert user.deletion_finalizes_at == nil
    assert user.anonymized_at == nil
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `docker compose run --rm app bash -lc "mix test test/verscienta/accounts/user_deletion_fields_test.exs"`
Expected: FAIL — unknown keys `deactivated_at` etc.

- [ ] **Step 3: Add the attributes**

In `lib/verscienta/accounts/user.ex`, in `attributes do`, after `confirmed_at`:

```elixir
    attribute :deactivated_at, :utc_datetime_usec, allow_nil?: true
    attribute :deletion_finalizes_at, :utc_datetime_usec, allow_nil?: true
    attribute :anonymized_at, :utc_datetime_usec, allow_nil?: true
```

- [ ] **Step 4: Generate + run the migration**

Run: `docker compose run --rm app bash -lc "mix ash.codegen add_account_deletion_fields && mix ecto.migrate"`
Expected: a migration adding three nullable timestamp columns; migrate succeeds.

- [ ] **Step 5: Run the test to confirm it passes**

Run: `docker compose run --rm app bash -lc "mix test test/verscienta/accounts/user_deletion_fields_test.exs"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta/accounts/user.ex priv/repo/migrations test/verscienta/accounts/user_deletion_fields_test.exs
git commit -m "feat(auth): add account deletion-state attributes + migration"
```

---

### Task 10: Deletion actions — `request_deletion`, `cancel_deletion`, `anonymize`

**Files:**
- Modify: `lib/verscienta/accounts/user.ex` (actions + policies)
- Test: `test/verscienta/accounts/account_deletion_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/accounts/account_deletion_test.exs`:

```elixir
defmodule Verscienta.Accounts.AccountDeletionTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Accounts.User

  defp user do
    User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: "del@example.com",
      username: "deluser",
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  test "request_deletion sets the grace-period timers" do
    u = user()

    {:ok, updated} =
      u
      |> Ash.Changeset.for_update(:request_deletion, %{
        current_password: "password123",
        confirm_username: "deluser"
      }, actor: u)
      |> Ash.update()

    assert updated.deactivated_at != nil
    assert updated.deletion_finalizes_at != nil
    assert DateTime.diff(updated.deletion_finalizes_at, updated.deactivated_at, :day) == 30
  end

  test "request_deletion rejects a mismatched username" do
    u = user()

    assert {:error, _} =
             u
             |> Ash.Changeset.for_update(:request_deletion, %{
               current_password: "password123",
               confirm_username: "wrong"
             }, actor: u)
             |> Ash.update()
  end

  test "request_deletion rejects a wrong password" do
    u = user()

    assert {:error, _} =
             u
             |> Ash.Changeset.for_update(:request_deletion, %{
               current_password: "nope",
               confirm_username: "deluser"
             }, actor: u)
             |> Ash.update()
  end

  test "cancel_deletion clears the timers" do
    u = user()

    {:ok, deactivated} =
      u
      |> Ash.Changeset.for_update(:request_deletion, %{
        current_password: "password123",
        confirm_username: "deluser"
      }, actor: u)
      |> Ash.update()

    {:ok, restored} =
      deactivated
      |> Ash.Changeset.for_update(:cancel_deletion, %{}, actor: deactivated)
      |> Ash.update()

    assert restored.deactivated_at == nil
    assert restored.deletion_finalizes_at == nil
  end

  test "anonymize scrubs PII but keeps id and role" do
    u = user()

    {:ok, anon} =
      u
      |> Ash.Changeset.for_update(:anonymize, %{}, authorize?: false)
      |> Ash.update()

    assert anon.id == u.id
    assert anon.role == u.role
    assert anon.anonymized_at != nil
    refute to_string(anon.email) == "del@example.com"
    refute to_string(anon.username) == "deluser"
    assert anon.display_name == nil
    assert anon.bio == nil
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `docker compose run --rm app bash -lc "mix test test/verscienta/accounts/account_deletion_test.exs"`
Expected: FAIL — actions undefined.

- [ ] **Step 3: Implement the three actions**

In `lib/verscienta/accounts/user.ex`, in `actions do`, add:

```elixir
    update :request_deletion do
      description "Begin a 30-day-grace account deletion (deactivate now, purge later)."
      require_atomic? false
      accept []

      argument :current_password, :string, sensitive?: true, allow_nil?: false
      argument :confirm_username, :string, allow_nil?: false

      validate {AshAuthentication.Strategy.Password.PasswordValidation,
                strategy_name: :password, password_argument: :current_password}

      validate fn changeset, _ ->
        typed = Ash.Changeset.get_argument(changeset, :confirm_username)

        if to_string(typed) == to_string(changeset.data.username) do
          :ok
        else
          {:error, field: :confirm_username, message: "does not match your username"}
        end
      end

      change fn changeset, _ ->
        now = DateTime.utc_now()

        changeset
        |> Ash.Changeset.force_change_attribute(:deactivated_at, now)
        |> Ash.Changeset.force_change_attribute(
          :deletion_finalizes_at,
          DateTime.add(now, 30, :day)
        )
      end
    end

    update :cancel_deletion do
      description "Cancel a pending deletion and reactivate the account."
      require_atomic? false
      accept []

      change fn changeset, _ ->
        changeset
        |> Ash.Changeset.force_change_attribute(:deactivated_at, nil)
        |> Ash.Changeset.force_change_attribute(:deletion_finalizes_at, nil)
      end
    end

    update :anonymize do
      description "System action: scrub PII and tombstone the account."
      require_atomic? false
      accept []

      change fn changeset, _ ->
        id = changeset.data.id
        short = id |> to_string() |> binary_part(0, 8)

        changeset
        |> Ash.Changeset.force_change_attribute(:email, "deleted+#{id}@verscienta.invalid")
        |> Ash.Changeset.force_change_attribute(:username, "deleted_#{short}")
        |> Ash.Changeset.force_change_attribute(:display_name, nil)
        |> Ash.Changeset.force_change_attribute(:bio, nil)
        |> Ash.Changeset.force_change_attribute(:avatar_url, nil)
        |> Ash.Changeset.force_change_attribute(:flair, %{})
        |> Ash.Changeset.force_change_attribute(:equipped_theme, nil)
        |> Ash.Changeset.force_change_attribute(:anonymized_at, DateTime.utc_now())
      end
    end
```

- [ ] **Step 4: Add policies**

In `policies do`, add:

```elixir
    policy action(:request_deletion) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:cancel_deletion) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:anonymize) do
      # System-only (called by the purge worker with authorize?: false).
      forbid_if always()
    end
```

- [ ] **Step 5: Run the test to confirm it passes**

Run: `docker compose run --rm app bash -lc "mix compile --warnings-as-errors && mix test test/verscienta/accounts/account_deletion_test.exs"`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta/accounts/user.ex test/verscienta/accounts/account_deletion_test.exs
git commit -m "feat(auth): account deletion lifecycle actions (request/cancel/anonymize)"
```

---

### Task 11: Block anonymized sign-in + reactivate on sign-in

**Files:**
- Create: `lib/verscienta/accounts/preparations/reject_anonymized.ex`
- Modify: `lib/verscienta/accounts/user.ex` (sign_in action + after_action reactivation)
- Test: `test/verscienta/accounts/deactivated_signin_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/accounts/deactivated_signin_test.exs`:

```elixir
defmodule Verscienta.Accounts.DeactivatedSignInTest do
  use Verscienta.DataCase, async: false

  alias Verscienta.Accounts.User

  defp user do
    User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: "signin@example.com",
      username: "signinuser",
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
    |> Verscienta.Support.AuthHelpers.confirm!()
  end

  defp sign_in(email) do
    User
    |> Ash.Query.for_read(:sign_in_with_password, %{email: email, password: "password123"})
    |> Ash.read_one()
  end

  test "a deactivated user can sign in, which reactivates them" do
    u = user()

    {:ok, _} =
      u
      |> Ash.Changeset.for_update(:request_deletion, %{
        current_password: "password123",
        confirm_username: "signinuser"
      }, actor: u)
      |> Ash.update()

    assert {:ok, signed_in} = sign_in("signin@example.com")
    assert signed_in.deactivated_at == nil
  end

  test "an anonymized user cannot sign in" do
    u = user()
    {:ok, _} = u |> Ash.Changeset.for_update(:anonymize, %{}, authorize?: false) |> Ash.update()

    assert {:error, _} = sign_in("signin@example.com")
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `docker compose run --rm app bash -lc "mix test test/verscienta/accounts/deactivated_signin_test.exs"`
Expected: FAIL — anonymized user still signs in / deactivated user not reactivated.

- [ ] **Step 3: Implement the anonymized-rejection preparation**

Create `lib/verscienta/accounts/preparations/reject_anonymized.ex`:

```elixir
defmodule Verscienta.Accounts.Preparations.RejectAnonymized do
  @moduledoc "After sign-in, reject anonymized accounts and reactivate merely-deactivated ones."
  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.after_action(query, fn _query, results ->
      case results do
        [%{anonymized_at: %DateTime{}}] ->
          {:error, "This account no longer exists."}

        [%{deactivated_at: %DateTime{}} = user] ->
          {:ok, reactivated} =
            user
            |> Ash.Changeset.for_update(:cancel_deletion, %{}, actor: user)
            |> Ash.update()

          {:ok, [reactivated]}

        other ->
          {:ok, other}
      end
    end)
  end
end
```

- [ ] **Step 4: Register the preparation on sign-in (LAST, after SignInPreparation)**

In `lib/verscienta/accounts/user.ex`, in `read :sign_in_with_password`, the prepare order becomes:

```elixir
      prepare Verscienta.Accounts.Preparations.RateLimitSignIn
      prepare AshAuthentication.Strategy.Password.SignInPreparation
      prepare Verscienta.Accounts.Preparations.RejectAnonymized
```

- [ ] **Step 5: Run the test to confirm it passes**

Run: `docker compose run --rm app bash -lc "mix compile --warnings-as-errors && mix test test/verscienta/accounts/deactivated_signin_test.exs"`
Expected: PASS (2 tests).

> If `SignInPreparation` already returns a token in metadata and `after_action` rebuilds the result list, confirm the token metadata survives reactivation. If not, fetch+return the original user with metadata intact. Verify via the test (it asserts `{:ok, signed_in}`).

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta/accounts/preparations/reject_anonymized.ex lib/verscienta/accounts/user.ex test/verscienta/accounts/deactivated_signin_test.exs
git commit -m "feat(auth): reject anonymized sign-in, reactivate deactivated on sign-in"
```

---

### Task 12: Hide deactivated users from public surfaces

**Files:**
- Modify: `lib/verscienta_web/live/profile_live.ex`
- Modify: `lib/verscienta/content/article.ex` (feed read filter)
- Test: `test/verscienta_web/live/profile_deactivated_test.exs`

- [ ] **Step 1: Inspect the current profile + article feed reads**

Run: `docker compose run --rm app bash -lc "grep -n 'deactivated\\|for_read\\|read ' lib/verscienta_web/live/profile_live.ex lib/verscienta/content/article.ex | head -40"`
Note the profile lookup action and the published-feed read action name (e.g. `:list_published`).

- [ ] **Step 2: Write the failing test**

Create `test/verscienta_web/live/profile_deactivated_test.exs`:

```elixir
defmodule VerscientaWeb.ProfileDeactivatedTest do
  use VerscientaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias Verscienta.Accounts.User

  test "a deactivated user's public profile is not shown", %{conn: conn} do
    user =
      User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: "ghost@example.com",
        username: "ghostuser",
        password: "password123",
        password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    {:ok, _} =
      user
      |> Ash.Changeset.for_update(:request_deletion, %{
        current_password: "password123",
        confirm_username: "ghostuser"
      }, actor: user)
      |> Ash.update()

    # The deactivated profile must NOT render the user. Match profile_live's
    # existing not-found behavior — pick ONE assertion in Step 1's inspection:
    #   * redirect:  assert {:error, {:live_redirect, _}} = live(conn, ~p"/@ghostuser")
    #   * raise:     assert_raise Ash.Error.Query.NotFound, fn -> live(conn, ~p"/@ghostuser") end
    assert {:error, {:live_redirect, _}} = live(conn, ~p"/@ghostuser")
  end
end
```

> Replace the assertion with whichever branch matches how `profile_live.ex` handles an unknown username today (determined in Step 1) — redirect vs. raise. Mirror that same not-found path for deactivated/anonymized users.

- [ ] **Step 3: Run it to confirm it fails**

Run: `docker compose run --rm app bash -lc "mix test test/verscienta_web/live/profile_deactivated_test.exs"`
Expected: FAIL — the deactivated profile still renders.

- [ ] **Step 4: Filter deactivated users from the profile lookup**

In `lib/verscienta_web/live/profile_live.ex`, where it loads the user by username, add a guard: if `user.deactivated_at != nil` (or `anonymized_at`), treat as not-found using the same path the LiveView already uses for unknown usernames.

```elixir
    case load_user_by_username(username) do
      %{deactivated_at: nil, anonymized_at: nil} = user -> # show profile
        ...
      _ -> # not found path (mirror existing behavior)
        ...
    end
```

- [ ] **Step 5: Filter deactivated authors from the article feed**

In `lib/verscienta/content/article.ex`, in the published-list read action identified in Step 1, add an author-active filter:

```elixir
      filter expr(status == :published and is_nil(author.deactivated_at))
```

(Combine with the existing published filter rather than duplicating it.)

- [ ] **Step 6: Run the test to confirm it passes**

Run: `docker compose run --rm app bash -lc "mix compile --warnings-as-errors && mix test test/verscienta_web/live/profile_deactivated_test.exs"`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/verscienta_web/live/profile_live.ex lib/verscienta/content/article.ex test/verscienta_web/live/profile_deactivated_test.exs
git commit -m "feat(auth): hide deactivated users from profile + article feed"
```

> **Out of scope (follow-up):** hiding a deactivated user's comments and de-indexing their content from Meilisearch. Track separately; not required for the grace-period MVP.

---

### Task 13: `AccountPurgeWorker` (daily cron anonymizer)

**Files:**
- Create: `lib/verscienta/accounts/workers/account_purge_worker.ex`
- Modify: `lib/verscienta/accounts/user.ex` (a `read :due_for_purge`)
- Modify: `config/config.exs` (cron)
- Test: `test/verscienta/accounts/workers/account_purge_worker_test.exs`

- [ ] **Step 1: Add a read action for due accounts**

In `lib/verscienta/accounts/user.ex`, in `actions do`:

```elixir
    read :due_for_purge do
      description "Deactivated accounts whose grace period has elapsed and not yet anonymized."
      filter expr(not is_nil(deletion_finalizes_at) and deletion_finalizes_at <= now() and is_nil(anonymized_at))
    end
```

- [ ] **Step 2: Write the failing test**

Create `test/verscienta/accounts/workers/account_purge_worker_test.exs`:

```elixir
defmodule Verscienta.Accounts.Workers.AccountPurgeWorkerTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Accounts.User
  alias Verscienta.Accounts.Workers.AccountPurgeWorker

  defp user(name) do
    User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: "#{name}@example.com",
      username: name,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  test "anonymizes only accounts past their finalize time" do
    past = user("pastuser")
    future = user("futureuser")

    # past: finalize time already elapsed
    past
    |> Ash.Changeset.for_update(:request_deletion, %{
      current_password: "password123",
      confirm_username: "pastuser"
    }, actor: past)
    |> Ash.update!()

    Ecto.Adapters.SQL.query!(
      Verscienta.Repo,
      "UPDATE users SET deletion_finalizes_at = NOW() - interval '1 day' WHERE id = $1",
      [Ecto.UUID.dump!(past.id)]
    )

    # future: still within grace
    future
    |> Ash.Changeset.for_update(:request_deletion, %{
      current_password: "password123",
      confirm_username: "futureuser"
    }, actor: future)
    |> Ash.update!()

    assert :ok = perform_job(AccountPurgeWorker, %{})

    reloaded_past = Ash.get!(User, past.id, authorize?: false)
    reloaded_future = Ash.get!(User, future.id, authorize?: false)

    assert reloaded_past.anonymized_at != nil
    assert reloaded_future.anonymized_at == nil
  end
end
```

- [ ] **Step 3: Run it to confirm it fails**

Run: `docker compose run --rm app bash -lc "mix test test/verscienta/accounts/workers/account_purge_worker_test.exs"`
Expected: FAIL — worker undefined.

- [ ] **Step 4: Implement the worker**

Create `lib/verscienta/accounts/workers/account_purge_worker.ex`:

```elixir
defmodule Verscienta.Accounts.Workers.AccountPurgeWorker do
  @moduledoc "Anonymizes accounts whose 30-day deletion grace period has elapsed. Oban cron-driven."
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Verscienta.Accounts.User

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    User
    |> Ash.read!(action: :due_for_purge, authorize?: false)
    |> Enum.each(fn user ->
      user
      |> Ash.Changeset.for_update(:anonymize, %{}, authorize?: false)
      |> Ash.update!()
    end)

    :ok
  end
end
```

- [ ] **Step 5: Run the test to confirm it passes**

Run: `docker compose run --rm app bash -lc "mix compile --warnings-as-errors && mix test test/verscienta/accounts/workers/account_purge_worker_test.exs"`
Expected: PASS. (`perform_job/2` comes from `Oban.Testing`, already available via `Verscienta.DataCase` if it uses `use Oban.Testing`; if not, add `import Oban.Testing, only: [perform_job: 2]` and `use Oban.Testing, repo: Verscienta.Repo` to the test.)

- [ ] **Step 6: Schedule the cron job**

In `config/config.exs`, in the Oban `crontab`, add a daily run (e.g. 03:30):

```elixir
       {"5 0 * * *", Verscienta.Gamification.Workers.LeaderboardSnapshotWorker},
       {"30 3 * * *", Verscienta.Accounts.Workers.AccountPurgeWorker}
```

- [ ] **Step 7: Commit**

```bash
git add lib/verscienta/accounts/workers/account_purge_worker.ex lib/verscienta/accounts/user.ex config/config.exs test/verscienta/accounts/workers/account_purge_worker_test.exs
git commit -m "feat(auth): AccountPurgeWorker anonymizes accounts after the grace period"
```

---

### Task 14: Settings danger-zone + goodbye page

**Files:**
- Modify: `lib/verscienta_web/live/settings_live.ex`
- Create: `lib/verscienta_web/live/goodbye_live.ex`
- Modify: `lib/verscienta_web/router.ex`
- Test: `test/verscienta_web/live/settings_delete_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/settings_delete_test.exs`:

```elixir
defmodule VerscientaWeb.SettingsDeleteTest do
  use VerscientaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias AshAuthentication.Plug.Helpers
  alias Verscienta.Accounts.User

  defp create_user do
    User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: "doomed@example.com",
      username: "doomed",
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp sign_in(conn, user) do
    conn |> Plug.Test.init_test_session(%{}) |> Helpers.store_in_session(user)
  end

  test "submitting the delete form with correct gate deactivates the account", %{conn: conn} do
    user = create_user()
    conn = sign_in(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/settings")

    render =
      lv
      |> form("#delete-account-form", delete: %{
        "current_password" => "password123",
        "confirm_username" => "doomed"
      })
      |> render_submit()

    # LiveView redirects to the goodbye page on success.
    assert {:error, {:redirect, %{to: "/goodbye"}}} = render
    assert Ash.get!(User, user.id, authorize?: false).deactivated_at != nil
  end

  test "wrong username keeps the account active", %{conn: conn} do
    user = create_user()
    conn = sign_in(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/settings")

    lv
    |> form("#delete-account-form", delete: %{
      "current_password" => "password123",
      "confirm_username" => "not-it"
    })
    |> render_submit()

    assert Ash.get!(User, user.id, authorize?: false).deactivated_at == nil
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `docker compose run --rm app bash -lc "mix test test/verscienta_web/live/settings_delete_test.exs"`
Expected: FAIL — no `#delete-account-form`.

- [ ] **Step 3: Add the goodbye route + LiveView**

Create `lib/verscienta_web/live/goodbye_live.ex`:

```elixir
defmodule VerscientaWeb.GoodbyeLive do
  @moduledoc "Shown after an account-deletion request is accepted."
  use VerscientaWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "account scheduled for deletion")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-6 pt-28 pb-24 max-w-xl">
      <.headline class="mb-6 text-5xl">goodbye, for now</.headline>
      <p class="text-ink-2">
        Your account has been deactivated and is scheduled for permanent deletion in 30 days.
        Sign back in any time before then to cancel and restore it.
      </p>
    </div>
    """
  end
end
```

In `lib/verscienta_web/router.ex`, add `/goodbye` to the public live_session routes block (alongside other public routes):

```elixir
      live "/goodbye", GoodbyeLive, :index
```

- [ ] **Step 4: Add the danger-zone form + handler in settings**

In `lib/verscienta_web/live/settings_live.ex`, add a delete form (initialized in `mount` like the email form):

```elixir
  defp assign_delete_form(socket) do
    user = socket.assigns.current_user

    form =
      user
      |> AshPhoenix.Form.for_update(:request_deletion, as: "delete", actor: user)
      |> to_form()

    assign(socket, delete_form: form)
  end
```

Call `|> assign_delete_form()` in `mount` after `assign_email_form`. Add the handler:

```elixir
  @impl true
  def handle_event("delete_account", %{"delete" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.delete_form, params: params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Your account is scheduled for deletion.")
         |> redirect(to: ~p"/goodbye")}

      {:error, form} ->
        {:noreply, assign(socket, delete_form: form)}
    end
  end
```

Add the markup at the end of `render/1` (a visually distinct danger zone):

```heex
      <section class="mt-16 max-w-xl border border-politics/40 p-6">
        <h2 class="mb-2 text-sm lowercase tracking-wider text-politics">danger zone</h2>
        <p class="mb-4 text-xs text-ink-3">
          Deleting your account deactivates it now and permanently removes your personal data after 30 days.
          Your posts remain but are shown as authored by a deleted user. Sign in within 30 days to cancel.
        </p>
        <.form
          :let={f}
          for={@delete_form}
          id="delete-account-form"
          phx-submit="delete_account"
          class="space-y-4"
        >
          <div>
            <label class="mb-1 block text-[11px] uppercase tracking-widest text-ink-3">current password</label>
            <input type="password" name={f[:current_password].name}
              class="w-full border border-line bg-canvas-2 px-4 py-3 text-ink" />
            <p :for={msg <- field_errors(f[:current_password])} class="mt-1 text-xs text-politics">{msg}</p>
          </div>
          <div>
            <label class="mb-1 block text-[11px] uppercase tracking-widest text-ink-3">type your username ({@current_user.username}) to confirm</label>
            <input type="text" name={f[:confirm_username].name}
              class="w-full border border-line bg-canvas-2 px-4 py-3 text-ink" />
            <p :for={msg <- field_errors(f[:confirm_username])} class="mt-1 text-xs text-politics">{msg}</p>
          </div>
          <button type="submit" class="bg-politics px-6 py-3 text-xs font-bold uppercase tracking-wider text-black hover:brightness-110">
            delete my account
          </button>
        </.form>
      </section>
```

- [ ] **Step 5: Run the test to confirm it passes**

Run: `docker compose run --rm app bash -lc "mix compile --warnings-as-errors && mix test test/verscienta_web/live/settings_delete_test.exs"`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta_web/live/settings_live.ex lib/verscienta_web/live/goodbye_live.ex lib/verscienta_web/router.ex test/verscienta_web/live/settings_delete_test.exs
git commit -m "feat(settings): danger-zone account deletion + goodbye page"
```

---

## Final verification

- [ ] **Step 1: Full verification loop**

Run: `docker compose run --rm app bash -lc "mix format --check-formatted && mix compile --warnings-as-errors && mix credo --strict && mix test"`
Expected: format clean, no warnings, Credo passes, full suite green.

- [ ] **Step 2: Update the roadmap**

In `docs/todo.md`, flip the two auth-hardening items:

```markdown
- [x] Account settings — email change & account deletion. *(30-day-grace soft-delete + confirm-first email change; `/settings`)*
...
- [x] Rate limiting on auth endpoints. *(Hammer/ETS, action-layer, per-IP + per-identity)*
```

Commit: `git add docs/todo.md && git commit -m "docs(todo): mark auth rate limiting + email change/deletion done"`

- [ ] **Step 3: Finish the branch**

Use the `superpowers:finishing-a-development-branch` skill to merge `auth-hardening` into `main` with `--no-ff` (project convention).

---

## Notes on the three flagged unknowns

1. **Email-change add-on option names** (`inhibit_updates?` / `confirm_on_update?`): verified at Task 7 step 3 via `h AshAuthentication.AddOn.Confirmation`. Fallback if the version differs: a `pending_email` attribute + custom confirmation token (spec's documented alternative).
2. **Token revocation on deletion:** the `request_deletion` action deactivates and `RejectAnonymized`/session checks gate access; if you want hard token revocation immediately, add a call to the token resource's revoke-all-for-user in the `request_deletion` change. The existing `log_out_everywhere` add-on already revokes on password change — deletion does not change the password, so add explicit revocation here if required.
3. **`x-forwarded-for` trust in prod:** the `:capture_client_ip` hook trusts the left-most XFF entry. In the Coolify/reverse-proxy deployment, confirm the proxy strips client-supplied XFF and appends the real client IP, so the value can't be spoofed to evade per-IP limits.
