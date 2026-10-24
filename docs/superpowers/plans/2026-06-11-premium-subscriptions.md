# Premium Subscriptions (PayPal) Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Users buy a premium subscription (monthly/annual) via PayPal's redirect checkout; webhooks keep state in sync; `Accounts.premium?/1` is the gating interface for future paywalls.

**Architecture:** New `Verscienta.Billing` Ash domain with one `Subscription` resource; a Req-based PayPal REST client behind a behaviour (config-swappable, like `Analytics.Client`); server-driven redirect checkout (no client JS); webhook controller verifies signatures and enqueues an Oban worker that re-fetches subscription state from PayPal (payloads are triggers, not truth).

**Tech Stack:** Phoenix 1.8 / Ash 3 / AshPostgres / Oban / Req / Jason / Verscienta.Cache (ETS+Redis).

**Spec:** `docs/superpowers/specs/2026-06-11-premium-subscriptions-design.md`

## Execution notes (read first)

- **All `mix` commands run inside the Docker app container** (host mix fails on bcrypt nmake). Canonical form: `docker exec news-verscienta-app-1 mix <task>`. If this worktree has its own compose stack, use its app container name instead (check `docker ps`). Verify the container sees this worktree's files before starting (run `docker exec news-verscienta-app-1 ls` and compare); if it only mounts the main checkout, start a worktree stack per `docs`/memory conventions.
- Oban test mode is `:manual` — tests use `use Oban.Testing, repo: Verscienta.Repo` + `assert_enqueued`/`perform_job`.
- Test stubs are config-swapped modules in `test/support/` (see `Verscienta.Analytics.Client.Stub`), NOT Mox.
- Run `mix precommit` at the end (format + credo + tests).
- Commit after every green task.

---

### Task 1: Billing domain + Subscription resource + migration

**Files:**
- Create: `lib/verscienta/billing.ex`
- Create: `lib/verscienta/billing/subscription.ex`
- Modify: `config/config.exs` (add `Verscienta.Billing` to `ash_domains`)
- Create: `test/verscienta/billing/subscription_test.exs`
- Generated: `priv/repo/migrations/*_add_billing_subscriptions.exs` (via ash.codegen)

- [ ] **Step 1: Write the failing resource test**

Create `test/verscienta/billing/subscription_test.exs`:

```elixir
defmodule Verscienta.Billing.SubscriptionTest do
  use Verscienta.DataCase, async: false

  alias Verscienta.Billing.Subscription
  import Verscienta.Factory

  defp start!(user, plan) do
    Subscription
    |> Ash.Changeset.for_create(:start, %{plan: plan}, actor: user, authorize?: false)
    |> Ash.create!()
  end

  test "start creates a pending subscription for the actor" do
    u = user("sub-starter")
    sub = start!(u, :monthly)

    assert sub.status == :pending
    assert sub.plan == :monthly
    assert sub.user_id == u.id
    assert sub.paypal_subscription_id == nil
    assert sub.current_period_end == nil
  end

  test "plan and status are constrained" do
    u = user("sub-constrained")

    assert {:error, %Ash.Error.Invalid{}} =
             Subscription
             |> Ash.Changeset.for_create(:start, %{plan: :weekly}, actor: u, authorize?: false)
             |> Ash.create()
  end

  test "attach_paypal sets the PayPal id, enforced unique" do
    u = user("sub-attach")
    other = user("sub-attach-2")

    sub = start!(u, :monthly)

    sub =
      sub
      |> Ash.Changeset.for_update(
        :attach_paypal,
        %{paypal_subscription_id: "I-UNIQ1", plan: :annual},
        authorize?: false
      )
      |> Ash.update!()

    assert sub.paypal_subscription_id == "I-UNIQ1"
    assert sub.plan == :annual

    dup = start!(other, :monthly)

    assert {:error, %Ash.Error.Invalid{}} =
             dup
             |> Ash.Changeset.for_update(
               :attach_paypal,
               %{paypal_subscription_id: "I-UNIQ1", plan: :monthly},
               authorize?: false
             )
             |> Ash.update()
  end

  test "sync updates status and current_period_end" do
    u = user("sub-sync")
    until = DateTime.add(DateTime.utc_now(), 30, :day)

    sub =
      start!(u, :monthly)
      |> Ash.Changeset.for_update(
        :sync,
        %{status: :active, current_period_end: until},
        authorize?: false
      )
      |> Ash.update!()

    assert sub.status == :active
    assert DateTime.compare(sub.current_period_end, until) == :eq
  end

  test "current_for_user returns only non-terminal subscriptions" do
    u = user("sub-current")
    sub = start!(u, :monthly)

    read_current = fn ->
      Subscription
      |> Ash.Query.for_read(:current_for_user, %{user_id: u.id})
      |> Ash.read!(authorize?: false)
    end

    assert [%{id: id}] = read_current.()
    assert id == sub.id

    sub
    |> Ash.Changeset.for_update(:sync, %{status: :cancelled}, authorize?: false)
    |> Ash.update!()

    assert [] = read_current.()
  end

  test "owner can read own subscription, others cannot" do
    owner = user("sub-owner")
    stranger = user("sub-stranger")
    sub = start!(owner, :monthly)

    assert {:ok, _} = Ash.get(Subscription, sub.id, actor: owner)
    assert {:error, %Ash.Error.Invalid{}} = Ash.get(Subscription, sub.id, actor: stranger)
  end
end
```

Note: `Ash.get` with a policy filter returns `NotFound` wrapped in `Ash.Error.Invalid` for the stranger — if the actual error class differs when you run it (e.g. `Ash.Error.Query.NotFound` inside `Invalid`), match on what Ash actually returns, asserting it is an error.

- [ ] **Step 2: Run test to verify it fails**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta/billing/subscription_test.exs`
Expected: FAIL — `Verscienta.Billing.Subscription` is not available (module undefined).

- [ ] **Step 3: Create the resource**

Create `lib/verscienta/billing/subscription.ex`:

```elixir
defmodule Verscienta.Billing.Subscription do
  @moduledoc """
  A user's premium subscription, mirroring a PayPal subscription.

  Lifecycle: `:pending` (checkout started) → `:active` ↔ `:suspended`
  (payment failure/recovery) → `:cancelled` | `:expired` (terminal).
  A cancelled subscription keeps premium until `current_period_end`.
  """
  use Ash.Resource,
    otp_app: :verscienta,
    domain: Verscienta.Billing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "billing_subscriptions"
    repo Verscienta.Repo

    custom_indexes do
      index [:user_id, :status]
    end
  end

  actions do
    defaults [:read]

    create :start do
      description "Begin checkout: a pending subscription for the acting user."
      accept [:plan]
      change relate_actor(:user)
    end

    update :attach_paypal do
      description "Record the PayPal subscription id after the create API call."
      accept [:paypal_subscription_id, :plan]
    end

    update :sync do
      description "Mirror PayPal state. Transition rules live in Verscienta.Billing.sync/1."
      accept [:status, :current_period_end]
    end

    read :current_for_user do
      description "The user's non-terminal subscription (at most one by construction)."
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id) and status in [:pending, :active, :suspended])
      prepare build(sort: [inserted_at: :desc])
    end

    read :for_user do
      description "All of a user's subscriptions, newest first."
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
      prepare build(sort: [inserted_at: :desc])
    end

    read :by_paypal_id do
      argument :paypal_subscription_id, :string, allow_nil?: false
      filter expr(paypal_subscription_id == ^arg(:paypal_subscription_id))
    end
  end

  policies do
    # Writes have no authorizing policy on purpose: all writes go through
    # Verscienta.Billing context functions with authorize?: false (system-only),
    # matching the pattern used by other system-driven resources.
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :plan, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:monthly, :annual]]

    attribute :status, :atom,
      allow_nil?: false,
      public?: true,
      default: :pending,
      constraints: [one_of: [:pending, :active, :suspended, :cancelled, :expired]]

    attribute :paypal_subscription_id, :string, allow_nil?: true, public?: true

    attribute :current_period_end, :utc_datetime_usec, allow_nil?: true, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Verscienta.Accounts.User, allow_nil?: false
  end

  identities do
    identity :unique_paypal_subscription_id, [:paypal_subscription_id]
  end
end
```

Create `lib/verscienta/billing.ex` (domain shell only — context functions come in Task 3):

```elixir
defmodule Verscienta.Billing do
  @moduledoc """
  Premium subscriptions billed through PayPal.

  Checkout is a server-driven redirect: we create a local pending Subscription
  + a PayPal subscription, send the user to PayPal's approve URL, and webhooks
  (plus the return URL) drive `sync/1`, which re-fetches state from the PayPal
  API — webhook payloads are triggers, not truth.
  """
  use Ash.Domain, otp_app: :verscienta

  resources do
    resource Verscienta.Billing.Subscription
  end
end
```

In `config/config.exs`, add `Verscienta.Billing` to the `ash_domains` list:

```elixir
  ash_domains: [
    Verscienta.Accounts,
    Verscienta.Content,
    Verscienta.Engagement,
    Verscienta.Gamification,
    Verscienta.Social,
    Verscienta.Notifications,
    Verscienta.Communities,
    Verscienta.Flags.Domain,
    Verscienta.Moderation,
    Verscienta.Experts,
    Verscienta.Billing
  ]
```

- [ ] **Step 4: Generate + run the migration**

Run: `docker exec news-verscienta-app-1 mix ash.codegen add_billing_subscriptions`
Expected: generates `priv/repo/migrations/*_add_billing_subscriptions.exs` creating `billing_subscriptions` with the unique index on `paypal_subscription_id` and the `[user_id, status]` index. Review the generated file.

Run: `docker exec news-verscienta-app-1 mix ecto.migrate`
Expected: migration runs.

- [ ] **Step 5: Run the test to verify it passes**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta/billing/subscription_test.exs`
Expected: PASS (the `mix test` alias migrates the test DB first; if not, run `MIX_ENV=test mix ecto.migrate` in the container).

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta/billing.ex lib/verscienta/billing/subscription.ex config/config.exs priv/repo/migrations test/verscienta/billing/subscription_test.exs priv/resource_snapshots
git commit -m "feat(billing): Billing domain + Subscription resource"
```

---

### Task 2: PayPal client behaviour + Req impl + test stub + config

**Files:**
- Create: `lib/verscienta/billing/paypal/client.ex`
- Create: `test/support/paypal_client_stub.ex`
- Modify: `config/config.exs`, `config/test.exs`, `config/runtime.exs`
- Create: `test/verscienta/billing/paypal_client_test.exs`

- [ ] **Step 1: Write the failing tests** (pure parsing + stub dispatch — the live Req HTTP paths are not unit-tested, matching every other `*.Client.Req` in this codebase)

Create `test/verscienta/billing/paypal_client_test.exs`:

```elixir
defmodule Verscienta.Billing.PayPalClientTest do
  use ExUnit.Case, async: false

  alias Verscienta.Billing.PayPal.Client

  describe "Req.parse_subscription/1" do
    test "extracts status, plan, custom_id and next billing time" do
      data = %{
        "status" => "ACTIVE",
        "plan_id" => "P-123",
        "custom_id" => "user-uuid",
        "billing_info" => %{"next_billing_time" => "2026-07-11T10:00:00Z"}
      }

      assert %{
               status: "ACTIVE",
               plan_id: "P-123",
               custom_id: "user-uuid",
               next_billing_time: %DateTime{year: 2026, month: 7, day: 11}
             } = Client.Req.parse_subscription(data)
    end

    test "tolerates missing billing info and bad timestamps" do
      assert %{status: "CANCELLED", next_billing_time: nil} =
               Client.Req.parse_subscription(%{"status" => "CANCELLED"})

      assert %{next_billing_time: nil} =
               Client.Req.parse_subscription(%{
                 "status" => "ACTIVE",
                 "billing_info" => %{"next_billing_time" => "not-a-time"}
               })
    end
  end

  describe "dispatch through configured client" do
    test "calls route to the stub in test env" do
      Application.put_env(:verscienta, :paypal_test_pid, self())
      on_exit(fn -> Application.delete_env(:verscienta, :paypal_test_pid) end)

      assert {:ok, %{id: "I-STUB123", approve_url: "https://paypal.test/" <> _}} =
               Client.create_subscription("P-M", "uid", "http://r", "http://c")

      assert_received {:paypal, {:create_subscription, "P-M", "uid", "http://r", "http://c"}}

      assert {:ok, %{status: "ACTIVE"}} = Client.get_subscription("I-STUB123")
      assert :ok = Client.cancel_subscription("I-STUB123", "test")
      assert {:ok, :verified} = Client.verify_webhook_signature([], "{}")
    end

    test "stub responses are overridable per test" do
      Application.put_env(:verscienta, :paypal_stub_responses, %{
        get_subscription: {:error, :down}
      })

      on_exit(fn -> Application.delete_env(:verscienta, :paypal_stub_responses) end)

      assert {:error, :down} = Client.get_subscription("I-ANY")
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta/billing/paypal_client_test.exs`
Expected: FAIL — module `Verscienta.Billing.PayPal.Client` undefined.

- [ ] **Step 3: Implement the client**

Create `lib/verscienta/billing/paypal/client.ex`:

```elixir
defmodule Verscienta.Billing.PayPal.Client do
  @moduledoc """
  Behaviour + Req implementation for PayPal's REST Subscriptions API.
  Swap implementations via `config :verscienta, :paypal_client, Module`.
  """

  @type subscription :: %{
          status: String.t() | nil,
          plan_id: String.t() | nil,
          custom_id: String.t() | nil,
          next_billing_time: DateTime.t() | nil
        }

  @callback create_subscription(
              plan_id :: String.t(),
              custom_id :: String.t(),
              return_url :: String.t(),
              cancel_url :: String.t()
            ) :: {:ok, %{id: String.t(), approve_url: String.t()}} | {:error, term}
  @callback get_subscription(id :: String.t()) :: {:ok, subscription} | {:error, term}
  @callback cancel_subscription(id :: String.t(), reason :: String.t()) :: :ok | {:error, term}
  @callback verify_webhook_signature(headers :: [{String.t(), String.t()}], raw_body :: binary) ::
              {:ok, :verified} | {:ok, :failed} | {:error, term}

  def create_subscription(plan_id, custom_id, return_url, cancel_url),
    do: impl().create_subscription(plan_id, custom_id, return_url, cancel_url)

  def get_subscription(id), do: impl().get_subscription(id)
  def cancel_subscription(id, reason), do: impl().cancel_subscription(id, reason)

  def verify_webhook_signature(headers, raw_body),
    do: impl().verify_webhook_signature(headers, raw_body)

  defp impl, do: Application.get_env(:verscienta, :paypal_client, __MODULE__.Req)

  defmodule Req do
    @moduledoc false
    @behaviour Verscienta.Billing.PayPal.Client
    require Logger

    @impl true
    def create_subscription(plan_id, custom_id, return_url, cancel_url) do
      body = %{
        plan_id: plan_id,
        custom_id: custom_id,
        application_context: %{
          brand_name: "Verscienta News",
          user_action: "SUBSCRIBE_NOW",
          return_url: return_url,
          cancel_url: cancel_url
        }
      }

      with {:ok, %{"id" => id, "links" => links}} <- api_post("/v1/billing/subscriptions", body) do
        case Enum.find(links, &(&1["rel"] == "approve")) do
          %{"href" => approve_url} -> {:ok, %{id: id, approve_url: approve_url}}
          _ -> {:error, :no_approve_link}
        end
      end
    end

    @impl true
    def get_subscription(id) do
      with {:ok, data} <- api_get("/v1/billing/subscriptions/" <> id) do
        {:ok, parse_subscription(data)}
      end
    end

    @impl true
    def cancel_subscription(id, reason) do
      with {:ok, _} <- api_post("/v1/billing/subscriptions/#{id}/cancel", %{reason: reason}) do
        :ok
      end
    end

    @impl true
    def verify_webhook_signature(headers, raw_body) do
      h = Map.new(headers, fn {k, v} -> {String.downcase(k), v} end)

      fields = %{
        "auth_algo" => h["paypal-auth-algo"],
        "cert_url" => h["paypal-cert-url"],
        "transmission_id" => h["paypal-transmission-id"],
        "transmission_sig" => h["paypal-transmission-sig"],
        "transmission_time" => h["paypal-transmission-time"],
        "webhook_id" => Application.get_env(:verscienta, :paypal_webhook_id)
      }

      if Enum.any?(Map.values(fields), &is_nil/1) or raw_body in [nil, ""] do
        {:ok, :failed}
      else
        # Validate raw_body is a single complete JSON document before splicing.
        # Jason.decode rejects trailing garbage, which kills injection attempts.
        # We splice the raw bytes unmodified (via Jason.Fragment) because PayPal's
        # signature covers the exact body it sent; re-encoding could change them.
        case Jason.decode(raw_body) do
          {:ok, _} ->
            payload =
              fields
              |> Map.put("webhook_event", Jason.Fragment.new(raw_body))
              |> Jason.encode!()

            case api_post_raw("/v1/notifications/verify-webhook-signature", payload) do
              {:ok, %{"verification_status" => "SUCCESS"}} -> {:ok, :verified}
              {:ok, _} -> {:ok, :failed}
              {:error, reason} -> {:error, reason}
            end

          _ ->
            {:ok, :failed}
        end
      end
    end

    @doc false
    def parse_subscription(data) when is_map(data) do
      %{
        status: data["status"],
        plan_id: data["plan_id"],
        custom_id: data["custom_id"],
        next_billing_time: parse_time(get_in(data, ["billing_info", "next_billing_time"]))
      }
    end

    defp parse_time(iso) when is_binary(iso) do
      case DateTime.from_iso8601(iso) do
        {:ok, dt, _offset} -> dt
        _ -> nil
      end
    end

    defp parse_time(_), do: nil

    # ===== HTTP plumbing (also used by Verscienta.Billing.PayPal.Provision) =====

    @doc false
    def api_post(path, body) do
      with {:ok, token} <- access_token() do
        Elixir.Req.post(base_url() <> path,
          json: body,
          auth: {:bearer, token},
          receive_timeout: 15_000
        )
        |> handle_response()
      end
    end

    @doc false
    def api_post_raw(path, payload) do
      with {:ok, token} <- access_token() do
        Elixir.Req.post(base_url() <> path,
          body: payload,
          headers: [{"content-type", "application/json"}],
          auth: {:bearer, token},
          receive_timeout: 15_000
        )
        |> handle_response()
      end
    end

    @doc false
    def api_get(path) do
      with {:ok, token} <- access_token() do
        Elixir.Req.get(base_url() <> path, auth: {:bearer, token}, receive_timeout: 15_000)
        |> handle_response()
      end
    end

    defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299,
      do: {:ok, body}

    defp handle_response({:ok, %{status: status, body: body}}) do
      Logger.warning("PayPal API error #{status}: #{inspect(body)}")
      {:error, {:paypal_http, status}}
    end

    defp handle_response({:error, reason}) do
      Logger.warning("PayPal API request failed: #{inspect(reason)}")
      {:error, reason}
    end

    # PayPal access tokens live ~9h; 30min cache (L1 only) stays safely under.
    defp access_token do
      Verscienta.Cache.fetch("billing:paypal_token", [ttl: :timer.minutes(30), redis: false], fn ->
        fetch_token()
      end)
    end

    defp fetch_token do
      case Elixir.Req.post(base_url() <> "/v1/oauth2/token",
             form: [grant_type: "client_credentials"],
             auth: {:basic, client_id() <> ":" <> client_secret()},
             receive_timeout: 15_000
           ) do
        {:ok, %{status: 200, body: %{"access_token" => token}}} -> {:ok, token}
        {:ok, %{status: status}} -> {:error, {:paypal_auth, status}}
        {:error, reason} -> {:error, reason}
      end
    end

    defp base_url,
      do: Application.get_env(:verscienta, :paypal_base_url, "https://api-m.sandbox.paypal.com")

    defp client_id, do: Application.get_env(:verscienta, :paypal_client_id) || ""
    defp client_secret, do: Application.get_env(:verscienta, :paypal_client_secret) || ""
  end
end
```

Create `test/support/paypal_client_stub.ex`:

```elixir
defmodule Verscienta.Billing.PayPal.ClientStub do
  @moduledoc """
  Test double: returns happy-path canned responses, overridable per test via
  `Application.put_env(:verscienta, :paypal_stub_responses, %{get_subscription: ...})`,
  and forwards every call to `:paypal_test_pid` when set.
  """
  @behaviour Verscienta.Billing.PayPal.Client

  @impl true
  def create_subscription(plan_id, custom_id, return_url, cancel_url) do
    notify({:create_subscription, plan_id, custom_id, return_url, cancel_url})

    respond(
      :create_subscription,
      {:ok, %{id: "I-STUB123", approve_url: "https://paypal.test/approve/I-STUB123"}}
    )
  end

  @impl true
  def get_subscription(id) do
    notify({:get_subscription, id})

    respond(
      :get_subscription,
      {:ok,
       %{
         status: "ACTIVE",
         plan_id: "P-MONTHLY-STUB",
         custom_id: nil,
         next_billing_time: DateTime.add(DateTime.utc_now(), 30, :day)
       }}
    )
  end

  @impl true
  def cancel_subscription(id, reason) do
    notify({:cancel_subscription, id, reason})
    respond(:cancel_subscription, :ok)
  end

  @impl true
  def verify_webhook_signature(headers, raw_body) do
    notify({:verify_webhook_signature, headers, raw_body})
    respond(:verify_webhook_signature, {:ok, :verified})
  end

  defp respond(key, default) do
    Application.get_env(:verscienta, :paypal_stub_responses, %{}) |> Map.get(key, default)
  end

  defp notify(msg) do
    case Application.get_env(:verscienta, :paypal_test_pid) do
      pid when is_pid(pid) -> send(pid, {:paypal, msg})
      _ -> :ok
    end
  end
end
```

Config changes — `config/config.exs` (next to the other `*_client` defaults):

```elixir
config :verscienta, paypal_client: Verscienta.Billing.PayPal.Client.Req
```

`config/test.exs` (next to the other stubs):

```elixir
config :verscienta,
  paypal_client: Verscienta.Billing.PayPal.ClientStub,
  paypal_client_id: "test-client-id",
  paypal_client_secret: "test-secret",
  paypal_webhook_id: "test-webhook-id",
  paypal_plan_id_monthly: "P-MONTHLY-STUB",
  paypal_plan_id_annual: "P-ANNUAL-STUB"
```

`config/runtime.exs` (in the env-agnostic section near the PostHog block):

```elixir
# PayPal billing — optional in every env. When unset, premium subscriptions
# are disabled and /premium shows an "unavailable" notice. Display prices are
# cosmetic only; the charged price lives in the PayPal Plan.
config :verscienta,
  paypal_base_url: System.get_env("PAYPAL_BASE_URL", "https://api-m.sandbox.paypal.com"),
  paypal_client_id: System.get_env("PAYPAL_CLIENT_ID"),
  paypal_client_secret: System.get_env("PAYPAL_CLIENT_SECRET"),
  paypal_webhook_id: System.get_env("PAYPAL_WEBHOOK_ID"),
  paypal_plan_id_monthly: System.get_env("PAYPAL_PLAN_ID_MONTHLY"),
  paypal_plan_id_annual: System.get_env("PAYPAL_PLAN_ID_ANNUAL"),
  paypal_price_monthly: System.get_env("PAYPAL_PRICE_MONTHLY", "$5"),
  paypal_price_annual: System.get_env("PAYPAL_PRICE_ANNUAL", "$48")
```

CAUTION: `config/test.exs` is loaded at compile time and `runtime.exs` runs after it for test env too — the runtime block above would override the test stub creds with nils when env vars are unset. Guard it:

```elixir
if config_env() != :test do
  config :verscienta,
    paypal_base_url: System.get_env("PAYPAL_BASE_URL", "https://api-m.sandbox.paypal.com"),
    paypal_client_id: System.get_env("PAYPAL_CLIENT_ID"),
    paypal_client_secret: System.get_env("PAYPAL_CLIENT_SECRET"),
    paypal_webhook_id: System.get_env("PAYPAL_WEBHOOK_ID"),
    paypal_plan_id_monthly: System.get_env("PAYPAL_PLAN_ID_MONTHLY"),
    paypal_plan_id_annual: System.get_env("PAYPAL_PLAN_ID_ANNUAL"),
    paypal_price_monthly: System.get_env("PAYPAL_PRICE_MONTHLY", "$5"),
    paypal_price_annual: System.get_env("PAYPAL_PRICE_ANNUAL", "$48")
end
```

(Check how `posthog_api_key` handles this — if the existing pattern is unguarded, the price/base_url defaults are harmless but the nil creds are not; keep the guard.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta/billing/paypal_client_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta/billing/paypal/client.ex test/support/paypal_client_stub.ex config/config.exs config/test.exs config/runtime.exs test/verscienta/billing/paypal_client_test.exs
git commit -m "feat(billing): PayPal REST client behaviour + Req impl + test stub"
```

---

### Task 3: Billing context functions (checkout, sync, cancel, premium?)

**Files:**
- Modify: `lib/verscienta/billing.ex`
- Create: `test/verscienta/billing/billing_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/verscienta/billing/billing_test.exs`:

```elixir
defmodule Verscienta.BillingTest do
  use Verscienta.DataCase, async: false

  alias Verscienta.Billing
  import Verscienta.Factory

  setup do
    Verscienta.Cache.flush()

    on_exit(fn ->
      Application.delete_env(:verscienta, :paypal_stub_responses)
      Application.delete_env(:verscienta, :paypal_test_pid)
      Verscienta.Cache.flush()
    end)

    :ok
  end

  defp stub!(responses),
    do: Application.put_env(:verscienta, :paypal_stub_responses, responses)

  defp remote(status, next_billing_time \\ nil) do
    {:ok, %{status: status, plan_id: "P-X", custom_id: nil, next_billing_time: next_billing_time}}
  end

  describe "start_checkout/4" do
    test "creates a pending subscription and returns the PayPal approve url" do
      u = user("checkout-1")

      assert {:ok, "https://paypal.test/approve/" <> _} =
               Billing.start_checkout(u, :monthly, "http://x/return", "http://x/cancel")

      assert %{status: :pending, plan: :monthly, paypal_subscription_id: "I-STUB123"} =
               Billing.latest_subscription(u.id)
    end

    test "reuses an existing pending subscription instead of stacking rows" do
      u = user("checkout-2")
      {:ok, _} = Billing.start_checkout(u, :monthly, "http://x/r", "http://x/c")
      {:ok, _} = Billing.start_checkout(u, :annual, "http://x/r", "http://x/c")

      assert [%{plan: :annual, status: :pending}] = Billing.subscriptions_for(u.id)
    end

    test "rejects a second subscription while one is active" do
      u = user("checkout-3")
      {:ok, _} = Billing.start_checkout(u, :monthly, "http://x/r", "http://x/c")
      :ok = Billing.sync("I-STUB123")

      assert {:error, :already_subscribed} =
               Billing.start_checkout(u, :monthly, "http://x/r", "http://x/c")
    end

    test "returns :unavailable when PayPal is not configured" do
      original = Application.get_env(:verscienta, :paypal_client_id)
      Application.put_env(:verscienta, :paypal_client_id, nil)
      on_exit(fn -> Application.put_env(:verscienta, :paypal_client_id, original) end)

      assert {:error, :unavailable} =
               Billing.start_checkout(user("checkout-4"), :monthly, "r", "c")
    end

    test "propagates PayPal create failures and keeps the pending row for reuse" do
      stub!(%{create_subscription: {:error, :paypal_down}})
      u = user("checkout-5")

      assert {:error, :paypal_down} = Billing.start_checkout(u, :monthly, "r", "c")
      assert %{status: :pending, paypal_subscription_id: nil} = Billing.latest_subscription(u.id)
    end
  end

  describe "sync/1" do
    setup do
      u = user("sync-user")
      {:ok, _} = Billing.start_checkout(u, :monthly, "http://x/r", "http://x/c")
      %{u: u}
    end

    test "activates a pending subscription from PayPal state", %{u: u} do
      :ok = Billing.sync("I-STUB123")
      assert %{status: :active, current_period_end: %DateTime{}} = Billing.latest_subscription(u.id)
    end

    test "unknown subscription id" do
      assert {:error, :unknown_subscription} = Billing.sync("I-NOPE")
    end

    test "suspend and recover", %{u: u} do
      stub!(%{get_subscription: remote("SUSPENDED")})
      :ok = Billing.sync("I-STUB123")
      assert %{status: :suspended} = Billing.latest_subscription(u.id)

      stub!(%{get_subscription: remote("ACTIVE", DateTime.add(DateTime.utc_now(), 30, :day))})
      :ok = Billing.sync("I-STUB123")
      assert %{status: :active} = Billing.latest_subscription(u.id)
    end

    test "cancel keeps current_period_end and is terminal", %{u: u} do
      :ok = Billing.sync("I-STUB123")
      %{current_period_end: until} = Billing.latest_subscription(u.id)
      assert %DateTime{} = until

      stub!(%{get_subscription: remote("CANCELLED")})
      :ok = Billing.sync("I-STUB123")

      assert %{status: :cancelled, current_period_end: kept} = Billing.latest_subscription(u.id)
      assert DateTime.compare(kept, until) == :eq

      # Terminal: a later ACTIVE report must not resurrect it.
      stub!(%{get_subscription: remote("ACTIVE")})
      :ok = Billing.sync("I-STUB123")
      assert %{status: :cancelled} = Billing.latest_subscription(u.id)
    end

    test "unrecognized PayPal status is a no-op", %{u: u} do
      stub!(%{get_subscription: remote("SOMETHING_NEW")})
      :ok = Billing.sync("I-STUB123")
      assert %{status: :pending} = Billing.latest_subscription(u.id)
    end

    test "PayPal fetch failure propagates (so Oban retries)" do
      stub!(%{get_subscription: {:error, :timeout}})
      assert {:error, :timeout} = Billing.sync("I-STUB123")
    end
  end

  describe "cancel/1" do
    test "cancels via PayPal then syncs to cancelled" do
      u = user("cancel-1")
      {:ok, _} = Billing.start_checkout(u, :monthly, "http://x/r", "http://x/c")
      :ok = Billing.sync("I-STUB123")

      Application.put_env(:verscienta, :paypal_test_pid, self())
      stub!(%{get_subscription: remote("CANCELLED")})

      assert :ok = Billing.cancel(u)
      assert_received {:paypal, {:cancel_subscription, "I-STUB123", _reason}}
      assert %{status: :cancelled} = Billing.latest_subscription(u.id)
    end

    test "without an active subscription" do
      assert {:error, :no_active_subscription} = Billing.cancel(user("cancel-2"))
    end

    test "PayPal failure leaves local state untouched" do
      u = user("cancel-3")
      {:ok, _} = Billing.start_checkout(u, :monthly, "http://x/r", "http://x/c")
      :ok = Billing.sync("I-STUB123")

      stub!(%{cancel_subscription: {:error, :paypal_down}})
      assert {:error, :paypal_down} = Billing.cancel(u)
      assert %{status: :active} = Billing.latest_subscription(u.id)
    end
  end

  describe "premium?/1" do
    test "false with no subscription" do
      refute Billing.premium?(user("prem-0").id)
    end

    test "true when active, and cache invalidates on sync" do
      u = user("prem-1")
      {:ok, _} = Billing.start_checkout(u, :monthly, "http://x/r", "http://x/c")

      refute Billing.premium?(u.id)
      :ok = Billing.sync("I-STUB123")
      assert Billing.premium?(u.id)
    end

    test "cancelled stays premium until period end, not after" do
      u = user("prem-2")
      {:ok, _} = Billing.start_checkout(u, :monthly, "http://x/r", "http://x/c")

      stub!(%{get_subscription: remote("ACTIVE", DateTime.add(DateTime.utc_now(), 10, :day))})
      :ok = Billing.sync("I-STUB123")
      stub!(%{get_subscription: remote("CANCELLED")})
      :ok = Billing.sync("I-STUB123")
      assert Billing.premium?(u.id)

      # Past period end → not premium. Rewind by writing a past timestamp.
      sub = Billing.latest_subscription(u.id)

      sub
      |> Ash.Changeset.for_update(
        :sync,
        %{current_period_end: DateTime.add(DateTime.utc_now(), -1, :day)},
        authorize?: false
      )
      |> Ash.update!()

      Verscienta.Cache.flush()
      refute Billing.premium?(u.id)
    end

    test "suspended is not premium" do
      u = user("prem-3")
      {:ok, _} = Billing.start_checkout(u, :monthly, "http://x/r", "http://x/c")
      :ok = Billing.sync("I-STUB123")

      stub!(%{get_subscription: remote("SUSPENDED")})
      :ok = Billing.sync("I-STUB123")
      refute Billing.premium?(u.id)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta/billing/billing_test.exs`
Expected: FAIL — `Billing.start_checkout/4` undefined.

- [ ] **Step 3: Implement the context functions**

Replace `lib/verscienta/billing.ex` with:

```elixir
defmodule Verscienta.Billing do
  @moduledoc """
  Premium subscriptions billed through PayPal.

  Checkout is a server-driven redirect: we create a local pending Subscription
  + a PayPal subscription, send the user to PayPal's approve URL, and webhooks
  (plus the return URL) drive `sync/1`, which re-fetches state from the PayPal
  API — webhook payloads are triggers, not truth.

  `premium?/1` is consumed by `Verscienta.Accounts.premium?/1`, the single
  gating interface for premium features. Don't query this domain for gating.
  """
  use Ash.Domain, otp_app: :verscienta

  require Ash.Query

  alias Verscienta.Billing.PayPal.Client
  alias Verscienta.Billing.Subscription
  alias Verscienta.Cache

  resources do
    resource Verscienta.Billing.Subscription
  end

  @paypal_status_map %{
    "APPROVAL_PENDING" => :pending,
    "APPROVED" => :pending,
    "ACTIVE" => :active,
    "SUSPENDED" => :suspended,
    "CANCELLED" => :cancelled,
    "EXPIRED" => :expired
  }

  @premium_cache_ttl :timer.minutes(5)

  @doc "True when PayPal credentials + both plan ids are configured."
  def configured? do
    [:paypal_client_id, :paypal_client_secret, :paypal_plan_id_monthly, :paypal_plan_id_annual]
    |> Enum.all?(fn key ->
      case Application.get_env(:verscienta, key) do
        v when is_binary(v) and v != "" -> true
        _ -> false
      end
    end)
  end

  def plan_id(:monthly), do: Application.get_env(:verscienta, :paypal_plan_id_monthly)
  def plan_id(:annual), do: Application.get_env(:verscienta, :paypal_plan_id_annual)

  @doc "Cosmetic display price (the charged price lives in the PayPal Plan)."
  def display_price(:monthly), do: Application.get_env(:verscienta, :paypal_price_monthly, "$5")
  def display_price(:annual), do: Application.get_env(:verscienta, :paypal_price_annual, "$48")

  @doc """
  Begin checkout for `user` on `plan`. Creates (or reuses) a pending local
  subscription, creates the PayPal subscription, and returns the approve URL
  to redirect the user to. `{:error, :unavailable | :already_subscribed | term}`.
  """
  def start_checkout(user, plan, return_url, cancel_url) when plan in [:monthly, :annual] do
    cond do
      not configured?() ->
        {:error, :unavailable}

      match?(%{status: s} when s in [:active, :suspended], current_subscription(user.id)) ->
        {:error, :already_subscribed}

      true ->
        with {:ok, sub} <- ensure_pending(current_subscription(user.id), user, plan),
             {:ok, %{id: paypal_id, approve_url: approve_url}} <-
               Client.create_subscription(plan_id(plan), to_string(user.id), return_url, cancel_url),
             {:ok, _} <- attach(sub, paypal_id, plan) do
          {:ok, approve_url}
        end
    end
  end

  defp ensure_pending(nil, user, plan) do
    Subscription
    |> Ash.Changeset.for_create(:start, %{plan: plan}, actor: user, authorize?: false)
    |> Ash.create()
  end

  defp ensure_pending(%Subscription{status: :pending} = sub, _user, plan) do
    sub
    |> Ash.Changeset.for_update(:attach_paypal, %{plan: plan}, authorize?: false)
    |> Ash.update()
  end

  defp attach(sub, paypal_id, plan) do
    sub
    |> Ash.Changeset.for_update(
      :attach_paypal,
      %{paypal_subscription_id: paypal_id, plan: plan},
      authorize?: false
    )
    |> Ash.update()
  end

  @doc """
  Re-fetch `paypal_subscription_id` from PayPal and mirror its status locally.
  Idempotent; terminal local rows (:cancelled, :expired) never transition.
  `current_period_end` is only overwritten when PayPal reports a next billing
  time, so a cancelled subscription keeps its paid-through date.
  """
  def sync(paypal_subscription_id) do
    case by_paypal_id(paypal_subscription_id) do
      nil ->
        {:error, :unknown_subscription}

      %Subscription{status: status} when status in [:cancelled, :expired] ->
        :ok

      sub ->
        with {:ok, remote} <- Client.get_subscription(paypal_subscription_id) do
          apply_sync(sub, remote)
        end
    end
  end

  defp apply_sync(sub, remote) do
    attrs =
      %{status: Map.get(@paypal_status_map, remote.status, sub.status)}
      |> maybe_put_period_end(remote.next_billing_time)

    sub
    |> Ash.Changeset.for_update(:sync, attrs, authorize?: false)
    |> Ash.update!()

    invalidate_premium(sub.user_id)
    :ok
  end

  defp maybe_put_period_end(attrs, %DateTime{} = dt), do: Map.put(attrs, :current_period_end, dt)
  defp maybe_put_period_end(attrs, _), do: attrs

  @doc "User-initiated cancel: cancel at PayPal, then mirror the new state."
  def cancel(user) do
    case current_subscription(user.id) do
      %Subscription{status: s, paypal_subscription_id: id}
      when s in [:active, :suspended] and is_binary(id) ->
        with :ok <- Client.cancel_subscription(id, "Cancelled by user") do
          sync(id)
        end

      _ ->
        {:error, :no_active_subscription}
    end
  end

  @doc "The user's non-terminal subscription, or nil."
  def current_subscription(user_id) do
    Subscription
    |> Ash.Query.for_read(:current_for_user, %{user_id: user_id})
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  @doc "The user's most recent subscription of any status, or nil."
  def latest_subscription(user_id), do: subscriptions_for(user_id) |> List.first()

  @doc "All of a user's subscriptions, newest first."
  def subscriptions_for(user_id) do
    Subscription
    |> Ash.Query.for_read(:for_user, %{user_id: user_id})
    |> Ash.read!(authorize?: false)
  end

  @doc "Find a subscription by its PayPal id, or nil."
  def by_paypal_id(paypal_subscription_id) do
    Subscription
    |> Ash.Query.for_read(:by_paypal_id, %{paypal_subscription_id: paypal_subscription_id})
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  @doc """
  Whether the user has premium: an active subscription, or a cancelled one
  paid through past now. Cached ~5 min; `sync/1` invalidates.
  Consume via `Verscienta.Accounts.premium?/1`.
  """
  def premium?(user_id) do
    case Cache.fetch(premium_cache_key(user_id), [ttl: @premium_cache_ttl], fn ->
           {:ok, compute_premium(user_id)}
         end) do
      {:ok, value} -> value
      _ -> false
    end
  end

  defp compute_premium(user_id) do
    now = DateTime.utc_now()

    subscriptions_for(user_id)
    |> Enum.any?(fn
      %{status: :active} -> true
      %{status: :cancelled, current_period_end: %DateTime{} = until} -> DateTime.after?(until, now)
      _ -> false
    end)
  end

  defp premium_cache_key(user_id), do: "billing:premium:#{user_id}"

  def invalidate_premium(user_id), do: Cache.delete(premium_cache_key(user_id))
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta/billing/`
Expected: PASS (both billing test files).

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta/billing.ex test/verscienta/billing/billing_test.exs
git commit -m "feat(billing): checkout, sync, cancel and premium? context functions"
```

---

### Task 4: `Accounts.premium?/1`

**Files:**
- Modify: `lib/verscienta/accounts.ex`
- Create: `test/verscienta/accounts/premium_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/accounts/premium_test.exs`:

```elixir
defmodule Verscienta.Accounts.PremiumTest do
  use Verscienta.DataCase, async: false

  alias Verscienta.{Accounts, Billing}
  import Verscienta.Factory

  setup do
    Verscienta.Cache.flush()
    on_exit(fn -> Verscienta.Cache.flush() end)
    :ok
  end

  test "premium?/1 is false for nil and non-subscribers, true for active subscribers" do
    refute Accounts.premium?(nil)

    u = user("acct-premium")
    refute Accounts.premium?(u)

    {:ok, _} = Billing.start_checkout(u, :monthly, "http://x/r", "http://x/c")
    :ok = Billing.sync("I-STUB123")

    assert Accounts.premium?(u)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta/accounts/premium_test.exs`
Expected: FAIL — `Accounts.premium?/1` undefined.

- [ ] **Step 3: Implement**

In `lib/verscienta/accounts.ex`, add alongside the other public functions:

```elixir
  @doc """
  Whether the user currently has premium (active, or cancelled but paid
  through). THE single gating interface for premium features — do not query
  `Verscienta.Billing` directly for gating.
  """
  def premium?(%Verscienta.Accounts.User{id: id}), do: Verscienta.Billing.premium?(id)
  def premium?(nil), do: false
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta/accounts/premium_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta/accounts.ex test/verscienta/accounts/premium_test.exs
git commit -m "feat(accounts): premium?/1 gating interface backed by Billing"
```

---

### Task 5: Webhook endpoint (raw-body reader, controller, sync worker, route)

**Files:**
- Create: `lib/verscienta_web/plugs/cache_body_reader.ex`
- Create: `lib/verscienta_web/controllers/paypal_webhook_controller.ex`
- Create: `lib/verscienta/billing/workers/sync_subscription_worker.ex`
- Modify: `lib/verscienta_web/endpoint.ex` (Plug.Parsers `body_reader`)
- Modify: `lib/verscienta_web/router.ex` (webhook pipeline + route)
- Create: `test/verscienta_web/controllers/paypal_webhook_controller_test.exs`
- Create: `test/verscienta/billing/workers/sync_subscription_worker_test.exs`

- [ ] **Step 1: Write the failing controller test**

Create `test/verscienta_web/controllers/paypal_webhook_controller_test.exs`:

```elixir
defmodule VerscientaWeb.PayPalWebhookControllerTest do
  use VerscientaWeb.ConnCase, async: false
  use Oban.Testing, repo: Verscienta.Repo

  alias Verscienta.Billing.Workers.SyncSubscriptionWorker

  setup do
    on_exit(fn ->
      Application.delete_env(:verscienta, :paypal_stub_responses)
      Application.delete_env(:verscienta, :paypal_test_pid)
    end)

    :ok
  end

  defp post_event(conn, event) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/webhooks/paypal", Jason.encode!(event))
  end

  test "verified subscription event enqueues a sync job", %{conn: conn} do
    event = %{
      "event_type" => "BILLING.SUBSCRIPTION.ACTIVATED",
      "resource" => %{"id" => "I-WH1"}
    }

    conn = post_event(conn, event)

    assert response(conn, 200)
    assert_enqueued(worker: SyncSubscriptionWorker, args: %{paypal_subscription_id: "I-WH1"})
  end

  test "verification receives the raw body bytes", %{conn: conn} do
    Application.put_env(:verscienta, :paypal_test_pid, self())
    event = %{"event_type" => "BILLING.SUBSCRIPTION.ACTIVATED", "resource" => %{"id" => "I-WH5"}}
    raw = Jason.encode!(event)

    post_event(conn, event)

    assert_received {:paypal, {:verify_webhook_signature, _headers, ^raw}}
  end

  test "payment events resolve the subscription via billing_agreement_id", %{conn: conn} do
    event = %{
      "event_type" => "PAYMENT.SALE.COMPLETED",
      "resource" => %{"id" => "PAY-1", "billing_agreement_id" => "I-WH2"}
    }

    conn = post_event(conn, event)

    assert response(conn, 200)
    assert_enqueued(worker: SyncSubscriptionWorker, args: %{paypal_subscription_id: "I-WH2"})
  end

  test "failed signature verification returns 400 and enqueues nothing", %{conn: conn} do
    Application.put_env(:verscienta, :paypal_stub_responses, %{
      verify_webhook_signature: {:ok, :failed}
    })

    event = %{"event_type" => "BILLING.SUBSCRIPTION.ACTIVATED", "resource" => %{"id" => "I-WH3"}}
    conn = post_event(conn, event)

    assert response(conn, 400)
    refute_enqueued(worker: SyncSubscriptionWorker)
  end

  test "unhandled event types are acknowledged without work", %{conn: conn} do
    event = %{"event_type" => "CUSTOMER.DISPUTE.CREATED", "resource" => %{"id" => "X"}}
    conn = post_event(conn, event)

    assert response(conn, 200)
    refute_enqueued(worker: SyncSubscriptionWorker)
  end

  test "handled event without a subscription id is acknowledged", %{conn: conn} do
    event = %{"event_type" => "BILLING.SUBSCRIPTION.ACTIVATED", "resource" => %{}}
    conn = post_event(conn, event)

    assert response(conn, 200)
    refute_enqueued(worker: SyncSubscriptionWorker)
  end
end
```

Create `test/verscienta/billing/workers/sync_subscription_worker_test.exs`:

```elixir
defmodule Verscienta.Billing.Workers.SyncSubscriptionWorkerTest do
  use Verscienta.DataCase, async: false
  use Oban.Testing, repo: Verscienta.Repo

  alias Verscienta.Billing
  alias Verscienta.Billing.Workers.SyncSubscriptionWorker
  import Verscienta.Factory

  setup do
    Verscienta.Cache.flush()
    on_exit(fn -> Application.delete_env(:verscienta, :paypal_stub_responses) end)
    :ok
  end

  test "activates the subscription it syncs" do
    u = user("wh-worker")
    {:ok, _} = Billing.start_checkout(u, :monthly, "http://x/r", "http://x/c")

    assert :ok =
             perform_job(SyncSubscriptionWorker, %{"paypal_subscription_id" => "I-STUB123"})

    assert %{status: :active} = Billing.latest_subscription(u.id)
  end

  test "unknown subscription id is swallowed (no retry storm)" do
    assert :ok = perform_job(SyncSubscriptionWorker, %{"paypal_subscription_id" => "I-NOPE"})
  end

  test "PayPal errors bubble as {:error, _} so Oban retries" do
    u = user("wh-worker-2")
    {:ok, _} = Billing.start_checkout(u, :monthly, "http://x/r", "http://x/c")

    Application.put_env(:verscienta, :paypal_stub_responses, %{
      get_subscription: {:error, :timeout}
    })

    assert {:error, :timeout} =
             perform_job(SyncSubscriptionWorker, %{"paypal_subscription_id" => "I-STUB123"})
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta_web/controllers/paypal_webhook_controller_test.exs test/verscienta/billing/workers/sync_subscription_worker_test.exs`
Expected: FAIL — no route / modules undefined.

- [ ] **Step 3: Implement**

Create `lib/verscienta_web/plugs/cache_body_reader.ex`:

```elixir
defmodule VerscientaWeb.Plugs.CacheBodyReader do
  @moduledoc """
  `Plug.Parsers` body reader that stashes the raw bytes of webhook request
  bodies in `conn.private[:raw_body]`. Signature verification needs the exact
  bytes PayPal signed — re-encoding parsed params can change them. Only
  `/webhooks/` paths are cached to avoid holding bodies for normal traffic.
  """

  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)

    conn =
      if String.starts_with?(conn.request_path, "/webhooks/") do
        Plug.Conn.put_private(conn, :raw_body, (conn.private[:raw_body] || "") <> body)
      else
        conn
      end

    {:ok, body, conn}
  end
end
```

In `lib/verscienta_web/endpoint.ex`, add `body_reader` to the existing `Plug.Parsers` plug (keep all existing options):

```elixir
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    body_reader: {VerscientaWeb.Plugs.CacheBodyReader, :read_body, []}
```

Create `lib/verscienta/billing/workers/sync_subscription_worker.ex`:

```elixir
defmodule Verscienta.Billing.Workers.SyncSubscriptionWorker do
  @moduledoc """
  Re-fetches a PayPal subscription and mirrors its state locally. Enqueued by
  the webhook controller; the webhook payload is only a trigger — this worker
  asks the PayPal API for current state, which makes event ordering and
  duplicate deliveries irrelevant.
  """
  use Oban.Worker, queue: :default, max_attempts: 5

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"paypal_subscription_id" => id}}) do
    case Verscienta.Billing.sync(id) do
      :ok ->
        :ok

      {:error, :unknown_subscription} ->
        Logger.warning("PayPal webhook for unknown subscription #{id}")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

Create `lib/verscienta_web/controllers/paypal_webhook_controller.ex`:

```elixir
defmodule VerscientaWeb.PayPalWebhookController do
  use VerscientaWeb, :controller

  require Logger

  alias Verscienta.Billing.PayPal.Client
  alias Verscienta.Billing.Workers.SyncSubscriptionWorker

  @handled_events ~w(
    BILLING.SUBSCRIPTION.ACTIVATED
    BILLING.SUBSCRIPTION.CANCELLED
    BILLING.SUBSCRIPTION.SUSPENDED
    BILLING.SUBSCRIPTION.EXPIRED
    BILLING.SUBSCRIPTION.PAYMENT.FAILED
    PAYMENT.SALE.COMPLETED
  )

  def handle(conn, params) do
    raw_body = conn.private[:raw_body] || ""

    case Client.verify_webhook_signature(conn.req_headers, raw_body) do
      {:ok, :verified} ->
        enqueue_sync(params)
        send_resp(conn, 200, "ok")

      other ->
        Logger.warning("PayPal webhook rejected: #{inspect(other)}")
        send_resp(conn, 400, "invalid signature")
    end
  end

  defp enqueue_sync(%{"event_type" => type} = params) when type in @handled_events do
    case subscription_id(params) do
      nil ->
        Logger.warning("PayPal webhook #{type} without a subscription id")
        :ok

      id ->
        %{paypal_subscription_id: id}
        |> SyncSubscriptionWorker.new()
        |> Oban.insert()

        :ok
    end
  end

  defp enqueue_sync(_params), do: :ok

  # Subscription events carry the id at resource.id; sale events reference the
  # subscription as resource.billing_agreement_id.
  defp subscription_id(%{"event_type" => "PAYMENT.SALE.COMPLETED"} = params),
    do: get_in(params, ["resource", "billing_agreement_id"])

  defp subscription_id(params), do: get_in(params, ["resource", "id"])
end
```

In `lib/verscienta_web/router.ex`, add a webhook pipeline (after the `:api` pipeline) and scope (before the `/admin` scopes):

```elixir
  pipeline :webhook do
    plug :accepts, ["json"]
  end
```

```elixir
  # Payment provider webhooks — no session/CSRF; signature-verified in-controller.
  scope "/webhooks", VerscientaWeb do
    pipe_through :webhook

    post "/paypal", PayPalWebhookController, :handle
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta_web/controllers/paypal_webhook_controller_test.exs test/verscienta/billing/workers/sync_subscription_worker_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full webhook-adjacent suite to catch endpoint regressions** (the body_reader touches every request)

Run: `docker exec news-verscienta-app-1 mix test test/verscienta_web`
Expected: PASS — no regressions from the parser change.

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta_web/plugs/cache_body_reader.ex lib/verscienta_web/controllers/paypal_webhook_controller.ex lib/verscienta/billing/workers/sync_subscription_worker.ex lib/verscienta_web/endpoint.ex lib/verscienta_web/router.ex test/verscienta_web/controllers/paypal_webhook_controller_test.exs test/verscienta/billing/workers/sync_subscription_worker_test.exs
git commit -m "feat(billing): PayPal webhook endpoint + sync worker"
```

---

### Task 6: Return/cancel controller

**Files:**
- Create: `lib/verscienta_web/controllers/billing_controller.ex`
- Modify: `lib/verscienta_web/router.ex`
- Create: `test/verscienta_web/controllers/billing_controller_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/controllers/billing_controller_test.exs`:

```elixir
defmodule VerscientaWeb.BillingControllerTest do
  use VerscientaWeb.ConnCase, async: false

  alias Verscienta.Billing
  import Verscienta.Factory

  setup do
    Verscienta.Cache.flush()
    on_exit(fn -> Application.delete_env(:verscienta, :paypal_stub_responses) end)
    :ok
  end

  describe "GET /premium/return" do
    test "activates the subscription and welcomes the user", %{conn: conn} do
      u = user("ret-1")
      {:ok, _} = Billing.start_checkout(u, :monthly, "http://x/r", "http://x/c")

      conn = get(conn, ~p"/premium/return?subscription_id=I-STUB123")

      assert redirected_to(conn) == ~p"/premium"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "active"
      assert %{status: :active} = Billing.latest_subscription(u.id)
    end

    test "not-yet-active subscription gets a processing notice", %{conn: conn} do
      u = user("ret-2")
      {:ok, _} = Billing.start_checkout(u, :monthly, "http://x/r", "http://x/c")

      Application.put_env(:verscienta, :paypal_stub_responses, %{
        get_subscription:
          {:ok, %{status: "APPROVAL_PENDING", plan_id: nil, custom_id: nil, next_billing_time: nil}}
      })

      conn = get(conn, ~p"/premium/return?subscription_id=I-STUB123")

      assert redirected_to(conn) == ~p"/premium"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "processing"
    end

    test "unknown subscription id redirects gracefully", %{conn: conn} do
      conn = get(conn, ~p"/premium/return?subscription_id=I-NOPE")
      assert redirected_to(conn) == ~p"/premium"
    end

    test "missing subscription id redirects", %{conn: conn} do
      conn = get(conn, ~p"/premium/return")
      assert redirected_to(conn) == ~p"/premium"
    end
  end

  test "GET /premium/cancelled flashes and redirects", %{conn: conn} do
    conn = get(conn, ~p"/premium/cancelled")

    assert redirected_to(conn) == ~p"/premium"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "cancelled"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta_web/controllers/billing_controller_test.exs`
Expected: FAIL — no route.

- [ ] **Step 3: Implement**

Create `lib/verscienta_web/controllers/billing_controller.ex`:

```elixir
defmodule VerscientaWeb.BillingController do
  @moduledoc """
  PayPal checkout landing pages. The return URL re-fetches state from PayPal
  (`Billing.sync/1`) instead of trusting query params; the webhook drives the
  same idempotent transition, so whichever lands first wins.
  """
  use VerscientaWeb, :controller

  alias Verscienta.Billing

  def return(conn, %{"subscription_id" => id}) do
    _ = Billing.sync(id)

    case Billing.by_paypal_id(id) do
      %{status: :active} ->
        conn
        |> put_flash(:info, "Welcome to Premium! Your subscription is active.")
        |> redirect(to: ~p"/premium")

      _ ->
        conn
        |> put_flash(
          :info,
          "Thanks! PayPal is still processing your subscription — it will activate shortly."
        )
        |> redirect(to: ~p"/premium")
    end
  end

  def return(conn, _params), do: redirect(conn, to: ~p"/premium")

  def cancelled(conn, _params) do
    conn
    |> put_flash(:info, "Checkout cancelled — you have not been charged.")
    |> redirect(to: ~p"/premium")
  end
end
```

In `lib/verscienta_web/router.ex`, inside the existing "Always-on public routes" scope (`scope "/", VerscientaWeb do pipe_through :browser`), add next to the other `get` routes:

```elixir
    get "/premium/return", BillingController, :return
    get "/premium/cancelled", BillingController, :cancelled
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta_web/controllers/billing_controller_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta_web/controllers/billing_controller.ex lib/verscienta_web/router.ex test/verscienta_web/controllers/billing_controller_test.exs
git commit -m "feat(billing): PayPal checkout return/cancel landing routes"
```

---

### Task 7: Shared billing components + `/premium` pricing LiveView

**Files:**
- Create: `lib/verscienta_web/components/billing_components.ex`
- Create: `lib/verscienta_web/live/premium_live.ex`
- Modify: `lib/verscienta_web/router.ex` (add to `:public_routes` live_session)
- Create: `test/verscienta_web/live/premium_live_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/premium_live_test.exs`:

```elixir
defmodule VerscientaWeb.PremiumLiveTest do
  use VerscientaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Verscienta.Factory

  alias Verscienta.Billing

  setup do
    Verscienta.Cache.flush()

    on_exit(fn ->
      Application.delete_env(:verscienta, :paypal_stub_responses)
    end)

    :ok
  end

  test "renders both plan cards for anonymous visitors", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/premium")

    assert html =~ "monthly"
    assert html =~ "annual"
    assert html =~ "$5"
    assert html =~ "$48"
  end

  test "shows unavailable notice when PayPal is unconfigured", %{conn: conn} do
    original = Application.get_env(:verscienta, :paypal_client_id)
    Application.put_env(:verscienta, :paypal_client_id, nil)
    on_exit(fn -> Application.put_env(:verscienta, :paypal_client_id, original) end)

    {:ok, _lv, html} = live(conn, ~p"/premium")
    assert html =~ "aren&#39;t available yet"
  end

  test "anonymous subscribe click goes to sign-in", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/premium")

    assert {:error, {:redirect, %{to: "/sign-in"}}} =
             lv |> element("button[phx-value-plan=monthly]") |> render_click()
  end

  test "signed-in subscribe redirects externally to PayPal", %{conn: conn} do
    u = user("prem-live-1")
    conn = sign_in(conn, u)
    {:ok, lv, _html} = live(conn, ~p"/premium")

    assert {:error, {:redirect, %{to: "https://paypal.test/approve/" <> _}}} =
             lv |> element("button[phx-value-plan=monthly]") |> render_click()

    assert %{status: :pending} = Billing.latest_subscription(u.id)
  end

  test "subscriber sees a status card instead of plan cards", %{conn: conn} do
    u = user("prem-live-2")
    {:ok, _} = Billing.start_checkout(u, :monthly, "http://x/r", "http://x/c")
    :ok = Billing.sync("I-STUB123")

    conn = sign_in(conn, u)
    {:ok, _lv, html} = live(conn, ~p"/premium")

    assert html =~ "your subscription"
    assert html =~ "Active"
    refute html =~ "phx-value-plan"
  end

  test "PayPal create failure flashes an error", %{conn: conn} do
    Application.put_env(:verscienta, :paypal_stub_responses, %{
      create_subscription: {:error, :paypal_down}
    })

    u = user("prem-live-3")
    conn = sign_in(conn, u)
    {:ok, lv, _html} = live(conn, ~p"/premium")

    html = lv |> element("button[phx-value-plan=annual]") |> render_click()
    assert html =~ "Could not start PayPal checkout"
  end
end
```

(`sign_in/2` comes from `test/support/auth_helpers.ex`, already imported via ConnCase — verify the import and its exact name; other LiveView tests show the established usage.)

- [ ] **Step 2: Run test to verify it fails**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta_web/live/premium_live_test.exs`
Expected: FAIL — no route.

- [ ] **Step 3: Implement components + LiveView**

Create `lib/verscienta_web/components/billing_components.ex`:

```elixir
defmodule VerscientaWeb.BillingComponents do
  @moduledoc "Shared subscription display helpers (premium page + settings panel)."
  use Phoenix.Component

  attr :subscription, :map, required: true
  attr :show_cancel, :boolean, default: false

  def subscription_card(assigns) do
    ~H"""
    <div class="border border-line bg-canvas-2 p-6">
      <p class="text-[11px] uppercase tracking-wider text-zune">your subscription</p>
      <p class="mt-3 text-xl font-extrabold text-ink">{plan_label(@subscription.plan)}</p>
      <p class="mt-1 text-sm text-ink-2">{status_line(@subscription)}</p>
      <button
        :if={@show_cancel and @subscription.status in [:active, :suspended]}
        phx-click="cancel_subscription"
        data-confirm="Cancel your premium subscription? You'll keep premium until the end of the current billing period."
        class="mt-4 border border-politics/60 px-4 py-2 text-xs uppercase tracking-wider text-politics hover:bg-politics/10"
      >
        cancel subscription
      </button>
    </div>
    """
  end

  def plan_label(:monthly), do: "Premium — Monthly"
  def plan_label(:annual), do: "Premium — Annual"

  def status_line(%{status: :pending}), do: "Waiting for PayPal confirmation."

  def status_line(%{status: :active, current_period_end: %DateTime{} = until}),
    do: "Active — renews #{fmt(until)}."

  def status_line(%{status: :active}), do: "Active."

  def status_line(%{status: :suspended}),
    do: "Payment problem — PayPal is retrying. Update your payment method in PayPal."

  def status_line(%{status: :cancelled, current_period_end: %DateTime{} = until}),
    do: "Cancelled — premium until #{fmt(until)}."

  def status_line(%{status: :cancelled}), do: "Cancelled."
  def status_line(%{status: :expired}), do: "Expired."

  defp fmt(dt), do: Calendar.strftime(dt, "%b %d, %Y")
end
```

Create `lib/verscienta_web/live/premium_live.ex`:

```elixir
defmodule VerscientaWeb.PremiumLive do
  @moduledoc "Premium pricing page + PayPal checkout entry point."
  use VerscientaWeb, :live_view

  import VerscientaWeb.BillingComponents

  alias Verscienta.Billing

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Premium")
     |> assign(:configured?, Billing.configured?())
     |> assign_subscription()}
  end

  defp assign_subscription(socket) do
    case socket.assigns[:current_user] do
      nil -> assign(socket, :subscription, nil)
      user -> assign(socket, :subscription, Billing.latest_subscription(user.id))
    end
  end

  @impl true
  def handle_event("subscribe", %{"plan" => plan}, socket) when plan in ["monthly", "annual"] do
    case socket.assigns[:current_user] do
      nil ->
        {:noreply, redirect(socket, to: ~p"/sign-in")}

      user ->
        plan = String.to_existing_atom(plan)

        case Billing.start_checkout(
               user,
               plan,
               url(~p"/premium/return"),
               url(~p"/premium/cancelled")
             ) do
          {:ok, approve_url} ->
            {:noreply, redirect(socket, external: approve_url)}

          {:error, :already_subscribed} ->
            {:noreply,
             socket
             |> put_flash(:error, "You already have a subscription.")
             |> assign_subscription()}

          {:error, _reason} ->
            {:noreply,
             put_flash(socket, :error, "Could not start PayPal checkout. Please try again.")}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-6 pb-24 pt-28">
      <p class="text-[11px] uppercase tracking-[0.2em] text-zune">verscienta premium</p>
      <.headline class="mt-2 text-6xl">Go Premium</.headline>
      <p class="mt-4 max-w-xl text-sm leading-relaxed text-ink-2">
        Support independent wellness journalism. Premium perks roll out over time —
        your subscription funds the newsroom from day one.
      </p>

      <%= cond do %>
        <% not @configured? -> %>
          <div class="mt-10 max-w-xl border border-line bg-canvas-2 p-6 text-sm text-ink-2">
            Premium subscriptions aren't available yet. Check back soon.
          </div>
        <% @subscription && @subscription.status in [:active, :suspended] -> %>
          <div class="mt-10 max-w-xl">
            <.subscription_card subscription={@subscription} />
            <p class="mt-4 text-xs text-ink-3">
              Manage or cancel from <.link navigate={~p"/settings"} class="underline">settings</.link>.
            </p>
          </div>
        <% true -> %>
          <div
            :if={@subscription && @subscription.status in [:pending, :cancelled]}
            class="mt-10 max-w-3xl text-sm text-ink-2"
          >
            {pending_or_cancelled_note(@subscription)}
          </div>
          <div class="mt-10 grid max-w-3xl gap-6 sm:grid-cols-2">
            <div class="border border-line bg-canvas-2 p-8">
              <p class="text-[11px] uppercase tracking-wider text-ink-3">monthly</p>
              <p class="mt-3 text-4xl font-extrabold text-ink">
                {Billing.display_price(:monthly)}<span class="text-sm font-normal text-ink-3">/month</span>
              </p>
              <button
                phx-click="subscribe"
                phx-value-plan="monthly"
                class="mt-6 w-full bg-zune px-4 py-3 text-xs font-bold uppercase tracking-wider text-black hover:opacity-90"
              >
                subscribe with paypal
              </button>
            </div>
            <div class="border border-zune bg-canvas-2 p-8">
              <p class="text-[11px] uppercase tracking-wider text-zune">annual — best value</p>
              <p class="mt-3 text-4xl font-extrabold text-ink">
                {Billing.display_price(:annual)}<span class="text-sm font-normal text-ink-3">/year</span>
              </p>
              <button
                phx-click="subscribe"
                phx-value-plan="annual"
                class="mt-6 w-full bg-zune px-4 py-3 text-xs font-bold uppercase tracking-wider text-black hover:opacity-90"
              >
                subscribe with paypal
              </button>
            </div>
          </div>
          <p class="mt-6 max-w-3xl text-xs text-ink-3">
            Billed by PayPal. Cards accepted without a PayPal account. Cancel anytime —
            premium stays until the end of the paid period.
          </p>
      <% end %>
    </div>
    """
  end
end
```

In `lib/verscienta_web/router.ex`, add to the existing `:public_routes` live_session (alongside `/articles` etc.):

```elixir
      live "/premium", PremiumLive, :index
```

Note: `.headline` is a Codex component (see `codex_components.ex`, auto-imported). If the sign-in route is not literally `/sign-in`, check `ash_authentication`'s `sign_in_route` default in the router and adjust the test + redirect.

- [ ] **Step 4: Run test to verify it passes**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta_web/live/premium_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta_web/components/billing_components.ex lib/verscienta_web/live/premium_live.ex lib/verscienta_web/router.ex test/verscienta_web/live/premium_live_test.exs
git commit -m "feat(billing): /premium pricing page with PayPal redirect checkout"
```

---

### Task 8: Settings subscription panel

**Files:**
- Modify: `lib/verscienta_web/live/settings_live.ex`
- Create: `test/verscienta_web/live/settings_billing_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/settings_billing_test.exs`:

```elixir
defmodule VerscientaWeb.SettingsBillingTest do
  use VerscientaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Verscienta.Factory

  alias Verscienta.Billing

  setup do
    Verscienta.Cache.flush()
    on_exit(fn -> Application.delete_env(:verscienta, :paypal_stub_responses) end)
    :ok
  end

  defp activate!(u) do
    {:ok, _} = Billing.start_checkout(u, :monthly, "http://x/r", "http://x/c")
    :ok = Billing.sync("I-STUB123")
  end

  test "shows go-premium link when there is no subscription", %{conn: conn} do
    conn = sign_in(conn, user("set-bill-0"))
    {:ok, _lv, html} = live(conn, ~p"/settings")

    assert html =~ "premium subscription"
    assert html =~ "Go premium"
  end

  test "shows the subscription with a cancel button", %{conn: conn} do
    u = user("set-bill-1")
    activate!(u)

    conn = sign_in(conn, u)
    {:ok, _lv, html} = live(conn, ~p"/settings")

    assert html =~ "Premium — Monthly"
    assert html =~ "cancel subscription"
  end

  test "cancelling updates status and flashes", %{conn: conn} do
    u = user("set-bill-2")
    activate!(u)

    conn = sign_in(conn, u)
    {:ok, lv, _html} = live(conn, ~p"/settings")

    Application.put_env(:verscienta, :paypal_stub_responses, %{
      get_subscription:
        {:ok, %{status: "CANCELLED", plan_id: nil, custom_id: nil, next_billing_time: nil}}
    })

    html = lv |> element("button[phx-click=cancel_subscription]") |> render_click()

    assert html =~ "Cancelled — premium until"
    refute has_element?(lv, "button[phx-click=cancel_subscription]")
    assert %{status: :cancelled} = Billing.latest_subscription(u.id)
  end

  test "PayPal cancel failure flashes an error and keeps state", %{conn: conn} do
    u = user("set-bill-3")
    activate!(u)

    conn = sign_in(conn, u)
    {:ok, lv, _html} = live(conn, ~p"/settings")

    Application.put_env(:verscienta, :paypal_stub_responses, %{
      cancel_subscription: {:error, :paypal_down}
    })

    html = lv |> element("button[phx-click=cancel_subscription]") |> render_click()

    assert html =~ "Could not cancel"
    assert %{status: :active} = Billing.latest_subscription(u.id)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta_web/live/settings_billing_test.exs`
Expected: FAIL — panel not rendered.

- [ ] **Step 3: Implement**

In `lib/verscienta_web/live/settings_live.ex`:

1. Import the components near the other imports/aliases at the top of the module:

```elixir
  import VerscientaWeb.BillingComponents
```

2. In `mount`, add to the assign chain (the existing mount assigns several keys — add this one):

```elixir
    |> assign(:subscription, Verscienta.Billing.latest_subscription(user.id))
```

(`user` here is whatever variable mount already binds for the current user — match the existing code.)

3. Add a section in `render/1` immediately BEFORE the danger-zone section (`<section class="mt-16 max-w-xl border border-politics/40 p-6">`):

```heex
      <section class="mt-12 max-w-xl">
        <h2 class="mb-2 text-sm lowercase tracking-wider text-ink-3">premium subscription</h2>
        <%= if @subscription do %>
          <.subscription_card subscription={@subscription} show_cancel={true} />
        <% else %>
          <p class="text-sm text-ink-2">
            No subscription. <.link navigate={~p"/premium"} class="underline">Go premium</.link>.
          </p>
        <% end %>
      </section>
```

4. Add the event handler next to the other `handle_event` clauses:

```elixir
  @impl true
  def handle_event("cancel_subscription", _params, socket) do
    user = socket.assigns.current_user

    case Verscienta.Billing.cancel(user) do
      :ok ->
        {:noreply,
         socket
         |> assign(:subscription, Verscienta.Billing.latest_subscription(user.id))
         |> put_flash(
           :info,
           "Subscription cancelled. Premium stays active until the end of the billing period."
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not cancel with PayPal. Please try again.")}
    end
  end
```

(If SettingsLive already has one `@impl true def handle_event` group, add the clause without a duplicate `@impl` annotation, matching the file's style.)

- [ ] **Step 4: Run tests to verify they pass (plus existing settings tests)**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta_web/live/settings_billing_test.exs test/verscienta_web/live/settings_live_test.exs`
(Adjust the second path to the actual existing settings test filename — check `ls test/verscienta_web/live/ | grep -i settings`.)
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta_web/live/settings_live.ex test/verscienta_web/live/settings_billing_test.exs
git commit -m "feat(billing): subscription panel with cancel in /settings"
```

---

### Task 9: Premium badge on profile

**Files:**
- Modify: `lib/verscienta_web/live/profile_live.ex`
- Create: `test/verscienta_web/live/profile_premium_badge_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/profile_premium_badge_test.exs`:

```elixir
defmodule VerscientaWeb.ProfilePremiumBadgeTest do
  use VerscientaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Verscienta.Factory

  alias Verscienta.Billing

  setup do
    Verscienta.Cache.flush()
    :ok
  end

  test "premium subscriber's profile shows the badge", %{conn: conn} do
    u = user("badge-premium")
    {:ok, _} = Billing.start_checkout(u, :monthly, "http://x/r", "http://x/c")
    :ok = Billing.sync("I-STUB123")

    conn = sign_in(conn, u)
    {:ok, _lv, html} = live(conn, ~p"/@#{u.username}")

    assert html =~ "★ Premium"
  end

  test "non-subscriber profile has no premium badge", %{conn: conn} do
    u = user("badge-none")
    conn = sign_in(conn, u)
    {:ok, _lv, html} = live(conn, ~p"/@#{u.username}")

    refute html =~ "★ Premium"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta_web/live/profile_premium_badge_test.exs`
Expected: first test FAILS (no badge rendered).

- [ ] **Step 3: Implement**

In `lib/verscienta_web/live/profile_live.ex`:

1. In `mount` (where `@user` is assigned after loading the profile user), add:

```elixir
    |> assign(:premium?, Verscienta.Accounts.premium?(user))
```

(`user` = the loaded profile user variable; also add the same assign anywhere else the profile user is re-assigned, e.g. `handle_params`, if applicable — grep for `assign(socket, :user,` in the file.)

2. In `render/1`, after the role/expert badge `<p>` elements (around line 88–94), add:

```heex
        <p
          :if={@premium?}
          class="ml-2 mt-6 inline-block bg-zune px-3 py-1 text-[11px] font-bold uppercase tracking-wider text-black"
        >
          ★ Premium
        </p>
```

- [ ] **Step 4: Run tests to verify they pass (plus existing profile tests)**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta_web/live/profile_premium_badge_test.exs test/verscienta_web/live/profile_live_test.exs`
(Adjust the second path to the actual profile test filename.)
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta_web/live/profile_live.ex test/verscienta_web/live/profile_premium_badge_test.exs
git commit -m "feat(billing): premium badge on public profile"
```

---

### Task 10: Provisioning mix task

**Files:**
- Create: `lib/verscienta/billing/paypal/provision.ex`
- Create: `lib/mix/tasks/verscienta.billing.setup.ex`
- Create: `test/verscienta/billing/provision_test.exs`

- [ ] **Step 1: Write the failing test** (pure payload builder only — the HTTP side is a one-time operator tool exercised manually against the PayPal sandbox)

Create `test/verscienta/billing/provision_test.exs`:

```elixir
defmodule Verscienta.Billing.PayPal.ProvisionTest do
  use ExUnit.Case, async: true

  alias Verscienta.Billing.PayPal.Provision

  test "monthly plan payload" do
    payload = Provision.plan_payload("PROD-1", :monthly, "5.00", "USD")

    assert payload.product_id == "PROD-1"
    assert payload.name == "Verscienta Premium — Monthly"
    assert [cycle] = payload.billing_cycles
    assert cycle.frequency == %{interval_unit: "MONTH", interval_count: 1}
    assert cycle.total_cycles == 0
    assert cycle.pricing_scheme.fixed_price == %{value: "5.00", currency_code: "USD"}
    assert payload.payment_preferences.auto_bill_outstanding == true
  end

  test "annual plan payload" do
    payload = Provision.plan_payload("PROD-1", :annual, "48.00", "EUR")

    assert payload.name == "Verscienta Premium — Annual"
    assert [%{frequency: %{interval_unit: "YEAR"}}] = payload.billing_cycles
    assert [%{pricing_scheme: %{fixed_price: %{currency_code: "EUR"}}}] = payload.billing_cycles
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta/billing/provision_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement**

Create `lib/verscienta/billing/paypal/provision.ex`:

```elixir
defmodule Verscienta.Billing.PayPal.Provision do
  @moduledoc """
  One-time PayPal product/plan provisioning, driven by
  `mix verscienta.billing.setup`. Not used at runtime.
  """

  alias Verscienta.Billing.PayPal.Client.Req

  @product_name "Verscienta Premium"

  def run(monthly_price, annual_price, currency) do
    with :ok <- ensure_no_existing_plans(),
         {:ok, product_id} <- create_product(),
         {:ok, monthly_id} <- create_plan(plan_payload(product_id, :monthly, monthly_price, currency)),
         {:ok, annual_id} <- create_plan(plan_payload(product_id, :annual, annual_price, currency)) do
      {:ok, %{monthly: monthly_id, annual: annual_id}}
    end
  end

  def plan_payload(product_id, interval, price, currency) do
    {unit, name} =
      case interval do
        :monthly -> {"MONTH", "#{@product_name} — Monthly"}
        :annual -> {"YEAR", "#{@product_name} — Annual"}
      end

    %{
      product_id: product_id,
      name: name,
      status: "ACTIVE",
      billing_cycles: [
        %{
          frequency: %{interval_unit: unit, interval_count: 1},
          tenure_type: "REGULAR",
          sequence: 1,
          total_cycles: 0,
          pricing_scheme: %{fixed_price: %{value: price, currency_code: currency}}
        }
      ],
      payment_preferences: %{
        auto_bill_outstanding: true,
        payment_failure_threshold: 2
      }
    }
  end

  defp ensure_no_existing_plans do
    case Req.api_get("/v1/billing/plans?page_size=20") do
      {:ok, %{"plans" => plans}} when is_list(plans) ->
        if Enum.any?(plans, &String.starts_with?(&1["name"] || "", @product_name)) do
          {:error, :plans_already_exist}
        else
          :ok
        end

      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_product do
    # category must come from PayPal's fixed product-category list.
    body = %{name: @product_name, type: "SERVICE", category: "MEMBERSHIP_CLUBS"}

    case Req.api_post("/v1/catalogs/products", body) do
      {:ok, %{"id" => id}} -> {:ok, id}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_plan(payload) do
    case Req.api_post("/v1/billing/plans", payload) do
      {:ok, %{"id" => id}} -> {:ok, id}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

Create `lib/mix/tasks/verscienta.billing.setup.ex`:

```elixir
defmodule Mix.Tasks.Verscienta.Billing.Setup do
  @shortdoc "Provision the PayPal product + premium plans (one-time per environment)"
  @moduledoc """
  Creates the Verscienta Premium product and monthly/annual billing plans in
  PayPal, then prints the plan ids to set as env vars.

      mix verscienta.billing.setup --monthly 5.00 --annual 48.00 [--currency USD]

  Requires PAYPAL_BASE_URL (sandbox default), PAYPAL_CLIENT_ID and
  PAYPAL_CLIENT_SECRET. Aborts if Verscienta plans already exist in the
  PayPal account.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [monthly: :string, annual: :string, currency: :string])

    monthly = Keyword.get(opts, :monthly) || Mix.raise("--monthly PRICE is required (e.g. 5.00)")
    annual = Keyword.get(opts, :annual) || Mix.raise("--annual PRICE is required (e.g. 48.00)")
    currency = Keyword.get(opts, :currency, "USD")

    Mix.Task.run("app.start")

    case Verscienta.Billing.PayPal.Provision.run(monthly, annual, currency) do
      {:ok, %{monthly: m, annual: a}} ->
        Mix.shell().info("""

        PayPal product + plans created. Set these env vars:

          PAYPAL_PLAN_ID_MONTHLY=#{m}
          PAYPAL_PLAN_ID_ANNUAL=#{a}
        """)

      {:error, :plans_already_exist} ->
        Mix.raise(
          "Verscienta Premium plans already exist in this PayPal account — " <>
            "find their ids in the PayPal dashboard instead of re-creating."
        )

      {:error, reason} ->
        Mix.raise("PayPal provisioning failed: #{inspect(reason)}")
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta/billing/provision_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta/billing/paypal/provision.ex lib/mix/tasks/verscienta.billing.setup.ex test/verscienta/billing/provision_test.exs
git commit -m "feat(billing): mix verscienta.billing.setup PayPal provisioning task"
```

---

### Task 11: Full verification + todo update

**Files:**
- Modify: `docs/todo.md`

- [ ] **Step 1: Run the full verification loop**

Run: `docker exec news-verscienta-app-1 mix precommit`
Expected: format clean, Credo clean, all tests pass (coverage threshold 83% enforced — billing tests above should keep it green; if coverage dips, the untested Req HTTP paths are the likely cause and `mix.exs` `ignore_modules` already covers other `*.Client.Req` modules — add `Verscienta.Billing.PayPal.Client.Req` and `Verscienta.Billing.PayPal.Provision` + the mix task there, matching the existing entries).

Fix anything that fails before proceeding.

- [ ] **Step 2: Update `docs/todo.md`**

Change the Phase 4 Monetization line:

```markdown
- [x] Premium subscriptions (billing integration: Stripe or equivalent). *(PayPal Subscriptions: server-redirect checkout, monthly+annual plans, webhook-driven lifecycle sync, `Accounts.premium?/1` gating interface, /premium + settings panel + profile badge, `mix verscienta.billing.setup` provisioning; spec `docs/superpowers/specs/2026-06-11-premium-subscriptions-design.md`)*
```

- [ ] **Step 3: Commit**

```bash
git add docs/todo.md
git commit -m "docs(todo): premium subscriptions (PayPal) done"
```

---

## Manual post-merge operator steps (not part of this implementation)

1. Create a PayPal app (sandbox first) → set `PAYPAL_CLIENT_ID` / `PAYPAL_CLIENT_SECRET`.
2. Run `mix verscienta.billing.setup --monthly 5.00 --annual 48.00` → set `PAYPAL_PLAN_ID_MONTHLY` / `PAYPAL_PLAN_ID_ANNUAL`.
3. In the PayPal developer dashboard, create a webhook pointing at `https://<host>/webhooks/paypal` subscribed to: BILLING.SUBSCRIPTION.ACTIVATED / CANCELLED / SUSPENDED / EXPIRED / PAYMENT.FAILED and PAYMENT.SALE.COMPLETED → set `PAYPAL_WEBHOOK_ID`.
4. Smoke-test a sandbox subscription end-to-end before setting live creds (`PAYPAL_BASE_URL=https://api-m.paypal.com`).
