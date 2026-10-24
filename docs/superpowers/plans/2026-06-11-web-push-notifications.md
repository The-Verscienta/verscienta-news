# Web-Push Notifications Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver browser push notifications as a channel alongside in-app/email, behind an off-by-default `:web_push` flag — server side fully tested, browser path ships dark.

**Architecture:** `web_push_encryption` does the crypto; a `PushSubscription` resource stores per-device subscriptions; `Verscienta.WebPush.dispatch/2` (called from `notify/1`) enqueues a `SendWebPushWorker` that sends via a configurable **Sender seam** (real impl + test stub) and prunes dead endpoints. A static `/sw.js` + a JS hook + a JSON controller handle the browser subscribe.

**Tech Stack:** Elixir, Ash 3 + AshPostgres, Oban, `web_push_encryption` (wraps `:jose`), Phoenix controller + LiveView, esbuild (no npm), FunWithFlags.

**Spec:** `docs/superpowers/specs/2026-06-11-web-push-notifications-design.md`

**Conventions:**
- ALL `mix` via Docker: `docker compose exec app mix ...` (use `-T` when piping).
- Commit trailer (exact): `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Branch: `phase-3-web-push`. `git checkout phase-3-web-push`; verify with `git rev-parse --abbrev-ref HEAD` (an external tool has switched branches on this checkout before — re-verify before EACH commit; stage only your own files).
- The analytics Client seam (`lib/verscienta/analytics/client.ex`: a behaviour + `impl()` via `Application.get_env(:verscienta, :analytics_client, Default)` + a `Stub`) is the exact pattern the WebPush Sender mirrors.

---

### Task 1: Dependency + flag + VAPID config + Sender seam + `WebPush.configured?`

**Files:**
- Modify: `mix.exs`, `config/runtime.exs`, `config/config.exs`, `config/test.exs`, `lib/verscienta/flags.ex`, `lib/verscienta/flags/seeds.ex`
- Create: `lib/verscienta/web_push.ex`, `lib/verscienta/web_push/sender.ex`
- Test (create): `test/verscienta/web_push_test.exs`

- [ ] **Step 1: Add the dependency**

In `mix.exs` deps (after `{:req, ...}`): `{:web_push_encryption, "~> 0.3"}`. Run:
`docker compose exec app mix deps.get` (confirm it resolves; note the exact version into `mix.lock`).

- [ ] **Step 2: Write the failing test**

`test/verscienta/web_push_test.exs`:
```elixir
defmodule Verscienta.WebPushTest do
  use ExUnit.Case, async: false

  alias Verscienta.WebPush

  test "configured? is true when VAPID public + private keys are set" do
    assert WebPush.configured?()
  end

  test "configured? is false when a key is blank" do
    prev = Application.get_env(:web_push_encryption, :vapid_details)
    Application.put_env(:web_push_encryption, :vapid_details, Keyword.put(prev, :public_key, ""))
    on_exit(fn -> Application.put_env(:web_push_encryption, :vapid_details, prev) end)
    refute WebPush.configured?()
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `docker compose exec app mix test test/verscienta/web_push_test.exs`
Expected: FAIL — `Verscienta.WebPush` undefined.

- [ ] **Step 4: VAPID + sender config**

`config/runtime.exs` (with the other optional creds, e.g. near LiveKit):
```elixir
config :web_push_encryption, :vapid_details,
  subject: System.get_env("VAPID_SUBJECT", "mailto:noreply@verscienta.news"),
  public_key: System.get_env("VAPID_PUBLIC_KEY"),
  private_key: System.get_env("VAPID_PRIVATE_KEY")
```
`config/config.exs` (default sender): `config :verscienta, :web_push_sender, Verscienta.WebPush.Sender.Live`
`config/test.exs` (stub + placeholder VAPID so `configured?` is true — the stub never does real crypto):
```elixir
config :verscienta, :web_push_sender, Verscienta.WebPush.Sender.Stub

config :web_push_encryption, :vapid_details,
  subject: "mailto:test@verscienta.news",
  public_key: "BTestVapidPublicKeyPlaceholderValueForConfiguredCheckOnly",
  private_key: "test-vapid-private-key-placeholder"
```

- [ ] **Step 5: The Sender seam** — `lib/verscienta/web_push/sender.ex`:
```elixir
defmodule Verscienta.WebPush.Sender do
  @moduledoc "Behaviour + impls for sending an encrypted web-push message to one subscription."

  @callback send(subscription :: map(), message :: String.t()) ::
              {:ok, status :: integer()} | {:error, status :: integer()}

  @doc "Send `message` to `subscription` (`%{endpoint, p256dh, auth}`) via the configured impl."
  def send(subscription, message), do: impl().send(subscription, message)

  defp impl, do: Application.get_env(:verscienta, :web_push_sender, __MODULE__.Live)

  defmodule Live do
    @moduledoc "Real sender — delegates to web_push_encryption. Not unit-tested (network + crypto)."
    @behaviour Verscienta.WebPush.Sender

    @impl true
    def send(%{endpoint: endpoint, p256dh: p256dh, auth: auth}, message) do
      sub = %{endpoint: endpoint, keys: %{"p256dh" => p256dh, "auth" => auth}}

      case WebPushEncryption.send_web_push(message, sub) do
        {:ok, %{status_code: s}} -> {:ok, s}
        {:ok, %{status: s}} -> {:ok, s}
        {:error, %{status_code: s}} -> {:error, s}
        other -> {:error, status_of(other)}
      end
    end

    defp status_of(_), do: 0
  end

  defmodule Stub do
    @moduledoc false
    @behaviour Verscienta.WebPush.Sender

    @impl true
    def send(%{endpoint: endpoint}, message) do
      if pid = Application.get_env(:verscienta, :web_push_test_pid),
        do: Kernel.send(pid, {:web_push, endpoint, message})

      if String.contains?(endpoint, "expired"), do: {:error, 410}, else: {:ok, 201}
    end
  end
end
```
(`WebPushEncryption.send_web_push/2`'s exact return shape: confirm against the installed
version's docs while wiring `Live`; the `{:ok|:error, status}` mapping is what the worker
relies on. `Live` is browser/network-verified, not unit-tested.)

- [ ] **Step 6: `lib/verscienta/web_push.ex`** (start with config; resource/dispatch added in later tasks):
```elixir
defmodule Verscienta.WebPush do
  @moduledoc "Web-push notifications: subscription storage, dispatch, and VAPID config."

  @doc "True when VAPID public + private keys are configured."
  def configured? do
    d = Application.get_env(:web_push_encryption, :vapid_details, [])
    present?(d[:public_key]) and present?(d[:private_key])
  end

  @doc "The VAPID public key (for the browser PushManager applicationServerKey)."
  def vapid_public_key do
    Application.get_env(:web_push_encryption, :vapid_details, [])[:public_key]
  end

  defp present?(v), do: is_binary(v) and v != ""
end
```

- [ ] **Step 7: Add the flag**

`lib/verscienta/flags.ex`: add `web_push` to `@known_flags`.
`lib/verscienta/flags/seeds.ex`: add `web_push` to `@phase3_off` + a label `web_push: "Web push notifications",`.

- [ ] **Step 8: Run tests + flags suite + compile**

Run: `docker compose exec app mix test test/verscienta/web_push_test.exs test/verscienta/flags_test.exs`
Expected: PASS (bump any flag-count assertion to include `web_push`).
Run: `docker compose exec app mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 9: Commit**

```bash
git add mix.exs mix.lock config/runtime.exs config/config.exs config/test.exs lib/verscienta/flags.ex lib/verscienta/flags/seeds.ex lib/verscienta/web_push.ex lib/verscienta/web_push/sender.ex test/verscienta/web_push_test.exs
git commit -m "feat(push): web_push_encryption dep + :web_push flag + VAPID config + Sender seam

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `PushSubscription` resource + migration + save/delete

**Files:**
- Create: `lib/verscienta/notifications/push_subscription.ex`
- Modify: `lib/verscienta/notifications.ex` (register the resource), `lib/verscienta/web_push.ex`
- Migration: generated
- Test (create): `test/verscienta/web_push/push_subscription_test.exs`

- [ ] **Step 1: Write the failing test**

`test/verscienta/web_push/push_subscription_test.exs`:
```elixir
defmodule Verscienta.WebPush.PushSubscriptionTest do
  use Verscienta.DataCase, async: true

  import Verscienta.Support.Factory, only: [user: 1]

  alias Verscienta.WebPush

  defp sub_params(endpoint),
    do: %{"endpoint" => endpoint, "keys" => %{"p256dh" => "pkey", "auth" => "akey"}}

  test "save_subscription upserts by endpoint (no duplicate)" do
    u = user("pushsub1")

    {:ok, _} = WebPush.save_subscription(u, sub_params("https://push.example/abc"))
    {:ok, _} = WebPush.save_subscription(u, sub_params("https://push.example/abc"))

    assert length(WebPush.subscriptions_for(u.id)) == 1
  end

  test "delete_subscription removes by endpoint" do
    u = user("pushsub2")
    {:ok, _} = WebPush.save_subscription(u, sub_params("https://push.example/del"))

    :ok = WebPush.delete_subscription(u, "https://push.example/del")
    assert WebPush.subscriptions_for(u.id) == []
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `docker compose exec app mix test test/verscienta/web_push/push_subscription_test.exs`
Expected: FAIL.

- [ ] **Step 3: Create the resource** — `lib/verscienta/notifications/push_subscription.ex`:
```elixir
defmodule Verscienta.Notifications.PushSubscription do
  @moduledoc "A user's web-push subscription (one per browser/device endpoint)."
  use Ash.Resource,
    otp_app: :verscienta,
    domain: Verscienta.Notifications,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "push_subscriptions"
    repo Verscienta.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      accept [:endpoint, :p256dh, :auth, :user_id]
      upsert? true
      upsert_identity :unique_endpoint
      upsert_fields [:p256dh, :auth, :user_id]
    end

    read :for_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :endpoint, :string, allow_nil?: false
    attribute :p256dh, :string, allow_nil?: false
    attribute :auth, :string, allow_nil?: false
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Verscienta.Accounts.User, allow_nil?: false
  end

  identities do
    identity :unique_endpoint, [:endpoint]
  end
end
```
(If `expr`/`arg` need imports, follow the `Notification` resource's conventions — `require Ash.Query` / `import Ash.Expr` as that file does.)

- [ ] **Step 4: Register the resource** — in `lib/verscienta/notifications.ex` `resources do` block, add:
```elixir
    resource Verscienta.Notifications.PushSubscription
```

- [ ] **Step 5: Add the WebPush functions** — in `lib/verscienta/web_push.ex`:
```elixir
  alias Verscienta.Notifications.PushSubscription

  @doc "Upsert a browser push subscription for `user` from the posted JSON."
  def save_subscription(user, %{"endpoint" => endpoint, "keys" => %{"p256dh" => p256dh, "auth" => auth}}) do
    PushSubscription
    |> Ash.Changeset.for_create(:upsert, %{endpoint: endpoint, p256dh: p256dh, auth: auth, user_id: user.id})
    |> Ash.create(authorize?: false)
  end

  def save_subscription(_user, _params), do: {:error, :invalid_subscription}

  @doc "Delete a `user`'s subscription by endpoint."
  def delete_subscription(user, endpoint) do
    PushSubscription
    |> Ash.Query.for_read(:for_user, %{user_id: user.id})
    |> Ash.Query.filter(endpoint == ^endpoint)
    |> Ash.read!(authorize?: false)
    |> Enum.each(&Ash.destroy!(&1, authorize?: false))

    :ok
  rescue
    _ -> :ok
  end

  @doc "All push subscriptions for a user id."
  def subscriptions_for(user_id) do
    PushSubscription
    |> Ash.Query.for_read(:for_user, %{user_id: user_id})
    |> Ash.read!(authorize?: false)
  end
```
(Add `require Ash.Query` at the top of `web_push.ex`.)

- [ ] **Step 6: Generate + run the migration**

Run: `docker compose exec app mix ash.codegen create_push_subscriptions`
(If the project uses a different generator, mirror how `Notification`'s migration was made — check `priv/repo/migrations/` for the Ash-generated style.) Then migrate dev + test:
```
docker compose exec app mix ecto.migrate
docker compose exec app env MIX_ENV=test mix ecto.migrate
```
Inspect the generated migration: a `push_subscriptions` table with a unique index on `endpoint` and a `user_id` FK.

- [ ] **Step 7: Run the test + compile**

Run: `docker compose exec app mix test test/verscienta/web_push/push_subscription_test.exs`
Expected: PASS.
Run: `docker compose exec app mix compile --warnings-as-errors` — clean.

- [ ] **Step 8: Commit**

```bash
git add lib/verscienta/notifications/push_subscription.ex lib/verscienta/notifications.ex lib/verscienta/web_push.ex priv/repo/migrations/ priv/resource_snapshots/ test/verscienta/web_push/push_subscription_test.exs
git commit -m "feat(push): PushSubscription resource + save/delete/list

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
(Stage whatever the codegen produced — migration + any `priv/resource_snapshots`.)

---

### Task 3: `dispatch/2` + `SendWebPushWorker` + notify integration

**Files:**
- Modify: `lib/verscienta/web_push.ex`, `lib/verscienta/notifications.ex`
- Create: `lib/verscienta/web_push/send_web_push_worker.ex`
- Test (create): `test/verscienta/web_push/dispatch_test.exs`

- [ ] **Step 1: Write the failing tests**

`test/verscienta/web_push/dispatch_test.exs`:
```elixir
defmodule Verscienta.WebPush.DispatchTest do
  use Verscienta.DataCase, async: false
  use Oban.Testing, repo: Verscienta.Repo

  import Verscienta.Support.Factory, only: [user: 1]

  alias Verscienta.WebPush
  alias Verscienta.WebPush.SendWebPushWorker

  setup do
    Application.put_env(:verscienta, :web_push_test_pid, self())
    FunWithFlags.enable(:web_push)

    on_exit(fn ->
      Application.delete_env(:verscienta, :web_push_test_pid)
      FunWithFlags.disable(:web_push)
    end)

    :ok
  end

  defp notif(recipient, actor),
    do: %{recipient_id: recipient.id, actor_id: actor.id, type: :followed, subject_type: :user, subject_id: actor.id, metadata: %{}}

  defp subscribe(u, endpoint),
    do: WebPush.save_subscription(u, %{"endpoint" => endpoint, "keys" => %{"p256dh" => "p", "auth" => "a"}})

  test "dispatch enqueues a worker when flag on + configured + subscribed + channel on" do
    r = user("disp_r")
    a = user("disp_a")
    {:ok, _} = subscribe(r, "https://push.example/disp")

    {:ok, n} = Verscienta.Notifications.notify(notif(r, a))
    assert_enqueued(worker: SendWebPushWorker, args: %{"user_id" => r.id})
    assert n.type == :followed
  end

  test "no job when the flag is off" do
    FunWithFlags.disable(:web_push)
    r = user("disp_off_r")
    a = user("disp_off_a")
    {:ok, _} = subscribe(r, "https://push.example/off")

    Verscienta.Notifications.notify(notif(r, a))
    refute_enqueued(worker: SendWebPushWorker)
  end

  test "no job when the channel toggle is off" do
    r = user("disp_ch_r")
    a = user("disp_ch_a")
    {:ok, _} = subscribe(r, "https://push.example/ch")

    r
    |> Ash.Changeset.for_update(:update_notification_prefs, %{notification_prefs: %{"web_push" => false}}, authorize?: false)
    |> Ash.update!()

    Verscienta.Notifications.notify(notif(r, a))
    refute_enqueued(worker: SendWebPushWorker)
  end

  test "worker sends to each subscription and prunes a 410 endpoint" do
    u = user("disp_worker")
    {:ok, _} = subscribe(u, "https://push.example/live")
    {:ok, _} = subscribe(u, "https://push.example/expired")

    payload = %{"title" => "t", "body" => "b", "url" => "/notifications"}
    assert :ok = perform_job(SendWebPushWorker, %{"user_id" => u.id, "payload" => payload})

    assert_receive {:web_push, "https://push.example/live", _}
    assert_receive {:web_push, "https://push.example/expired", _}

    endpoints = WebPush.subscriptions_for(u.id) |> Enum.map(& &1.endpoint)
    assert "https://push.example/live" in endpoints
    refute "https://push.example/expired" in endpoints
  end
end
```

> **Test-robustness note:** `dispatch/2` only reads `notification.type`, so the **gating
> tests** (flag off / channel off / all-on) can call `WebPush.dispatch(%{type: :followed},
> recipient)` **directly** with a plain map — avoid coupling them to `Notification`'s
> subject-type validation. Keep exactly ONE test that goes through
> `Notifications.notify/1` (with a payload mirroring a valid call in
> `test/verscienta/notifications_test.exs` — check `Notification`'s `@types`/`@subject_types`
> for a valid combo) to prove the `notify → dispatch` wire-up enqueues. Rework the test
> block above accordingly if the full-`notify` path is fragile; the worker/prune test
> (`perform_job`) stays as written.

- [ ] **Step 2: Run to verify they fail**

Run: `docker compose exec app mix test test/verscienta/web_push/dispatch_test.exs`
Expected: FAIL — `dispatch`/worker undefined, no enqueue.

- [ ] **Step 3: The worker** — `lib/verscienta/web_push/send_web_push_worker.ex`:
```elixir
defmodule Verscienta.WebPush.SendWebPushWorker do
  @moduledoc "Sends a prebuilt push payload to each of a user's subscriptions; prunes dead endpoints."
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Verscienta.WebPush
  alias Verscienta.WebPush.Sender

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "payload" => payload}}) do
    message = Jason.encode!(payload)

    for sub <- WebPush.subscriptions_for(user_id) do
      case Sender.send(%{endpoint: sub.endpoint, p256dh: sub.p256dh, auth: sub.auth}, message) do
        {:ok, status} -> maybe_prune(sub, status)
        {:error, status} -> maybe_prune(sub, status)
      end
    end

    :ok
  end

  defp maybe_prune(sub, status) when status in [404, 410], do: Ash.destroy!(sub, authorize?: false)
  defp maybe_prune(_sub, _status), do: :ok
end
```

- [ ] **Step 4: `dispatch/2` + payload** — in `lib/verscienta/web_push.ex`:
```elixir
  alias Verscienta.WebPush.SendWebPushWorker

  @doc """
  Best-effort: enqueue a push for `notification` to `recipient` when web-push is on,
  configured, and the recipient's master `web_push` channel is enabled. (The per-type
  opt-out + self-notify block were already applied by `Notifications.notify/1`.)
  """
  def dispatch(notification, %{} = recipient) do
    if Verscienta.Flags.enabled?(:web_push) and configured?() and channel_on?(recipient) do
      %{"user_id" => recipient.id, "payload" => payload_for(notification)}
      |> SendWebPushWorker.new()
      |> Oban.insert()
    end

    :ok
  rescue
    _ -> :ok
  end

  defp channel_on?(%{notification_prefs: prefs}),
    do: Map.get(prefs || %{}, "web_push", true) != false

  defp channel_on?(_), do: true

  defp payload_for(notification) do
    %{
      "title" => "Verscienta",
      "body" => body_for(notification.type),
      "url" => "/notifications"
    }
  end

  defp body_for(:followed), do: "You have a new follower"
  defp body_for(:replied), do: "Someone replied to you"
  defp body_for(:mentioned), do: "You were mentioned"
  defp body_for(:commented), do: "New comment on your article"
  defp body_for(:reacted), do: "Someone reacted to your post"
  defp body_for(:report_resolved), do: "Your report was reviewed"
  defp body_for(_), do: "You have a new notification"
```
(Deep-link URLs per type + richer copy are out of scope — MVP opens `/notifications`.)

- [ ] **Step 5: Wire into `notify/1`** — in `lib/verscienta/notifications.ex`, after the `broadcast(recipient_id, {:notification, notification.id})` line (≈ line 47), add:
```elixir
        Verscienta.WebPush.dispatch(notification, recipient)
```
(Inside the existing `if enabled?` branch, before `{:ok, notification}`. The whole `notify/1` already `rescue`s, so this stays best-effort.)

- [ ] **Step 6: Run the tests + compile**

Run: `docker compose exec app mix test test/verscienta/web_push/dispatch_test.exs`
Expected: PASS (4 tests).
Run: `docker compose exec app mix compile --warnings-as-errors` — clean.

- [ ] **Step 7: Commit**

```bash
git add lib/verscienta/web_push.ex lib/verscienta/web_push/send_web_push_worker.ex lib/verscienta/notifications.ex test/verscienta/web_push/dispatch_test.exs
git commit -m "feat(push): dispatch + SendWebPushWorker (prune dead endpoints) + notify hook

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `PushSubscriptionController` + routes

**Files:**
- Create: `lib/verscienta_web/controllers/push_subscription_controller.ex`
- Modify: `lib/verscienta_web/router.ex`
- Test (create): `test/verscienta_web/controllers/push_subscription_controller_test.exs`

- [ ] **Step 1: Write the failing test**

`test/verscienta_web/controllers/push_subscription_controller_test.exs`:
```elixir
defmodule VerscientaWeb.PushSubscriptionControllerTest do
  use VerscientaWeb.ConnCase, async: true

  import Verscienta.Support.Factory, only: [user: 1, sign_in: 2]

  alias Verscienta.WebPush

  @sub %{"endpoint" => "https://push.example/ctrl", "keys" => %{"p256dh" => "p", "auth" => "a"}}

  test "POST saves a subscription for the signed-in user", %{conn: conn} do
    u = user("ctrl_save")
    conn = conn |> sign_in(u) |> post(~p"/api/push/subscribe", %{"subscription" => @sub})

    assert json_response(conn, 201)["ok"] == true
    assert WebPush.subscriptions_for(u.id) |> Enum.map(& &1.endpoint) == ["https://push.example/ctrl"]
  end

  test "DELETE removes a subscription", %{conn: conn} do
    u = user("ctrl_del")
    {:ok, _} = WebPush.save_subscription(u, @sub)

    conn =
      conn
      |> sign_in(u)
      |> delete(~p"/api/push/subscribe", %{"endpoint" => "https://push.example/ctrl"})

    assert json_response(conn, 200)["ok"] == true
    assert WebPush.subscriptions_for(u.id) == []
  end

  test "a signed-out POST is rejected", %{conn: conn} do
    conn = post(conn, ~p"/api/push/subscribe", %{"subscription" => @sub})
    assert conn.status in [302, 401]
  end
end
```
(Confirm `sign_in/2` is the project's conn sign-in helper — it's the same one used by `RoomLiveTest`/controller tests.)

- [ ] **Step 2: Run to verify it fails**

Run: `docker compose exec app mix test test/verscienta_web/controllers/push_subscription_controller_test.exs`
Expected: FAIL — no route.

- [ ] **Step 3: The controller** — `lib/verscienta_web/controllers/push_subscription_controller.ex`:
```elixir
defmodule VerscientaWeb.PushSubscriptionController do
  use VerscientaWeb, :controller

  alias Verscienta.WebPush

  def create(conn, %{"subscription" => sub}) do
    case conn.assigns[:current_user] do
      nil ->
        conn |> put_status(401) |> json(%{error: "unauthenticated"})

      user ->
        case WebPush.save_subscription(user, sub) do
          {:ok, _} -> conn |> put_status(201) |> json(%{ok: true})
          {:error, _} -> conn |> put_status(422) |> json(%{error: "invalid_subscription"})
        end
    end
  end

  def delete(conn, %{"endpoint" => endpoint}) do
    case conn.assigns[:current_user] do
      nil -> conn |> put_status(401) |> json(%{error: "unauthenticated"})
      user ->
        WebPush.delete_subscription(user, endpoint)
        conn |> put_status(200) |> json(%{ok: true})
    end
  end
end
```

- [ ] **Step 4: Routes** — in `lib/verscienta_web/router.ex`, add in a `:browser`-pipelined scope where `current_user` is assigned (mirror where other authenticated browser routes live; the controller also guards `nil`):
```elixir
    post "/api/push/subscribe", PushSubscriptionController, :create
    delete "/api/push/subscribe", PushSubscriptionController, :delete
```
(If a signed-out request must be redirected rather than 401, place it behind the existing `require_authenticated_user`/equivalent plug; the test accepts 302 or 401.)

- [ ] **Step 5: Run + compile**

Run: `docker compose exec app mix test test/verscienta_web/controllers/push_subscription_controller_test.exs`
Expected: PASS.
Run: `docker compose exec app mix compile --warnings-as-errors` — clean.

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta_web/controllers/push_subscription_controller.ex lib/verscienta_web/router.ex test/verscienta_web/controllers/push_subscription_controller_test.exs
git commit -m "feat(push): subscribe/unsubscribe JSON endpoints

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Client — service worker + JS hook + settings UI

**Files:**
- Create: `priv/static/sw.js`, `assets/js/push_subscription.js`
- Modify: `lib/verscienta_web.ex` (`static_paths`), `assets/js/app.js`, `lib/verscienta_web/live/settings_live.ex`

> Browser-only — no automated tests. Verify `mix assets.build` succeeds + the settings section renders (a LiveView test asserting the button is present is OK; the JS itself is manual).

- [ ] **Step 1: Service worker** — `priv/static/sw.js`:
```js
self.addEventListener("push", (event) => {
  const data = event.data ? event.data.json() : {}
  event.waitUntil(
    self.registration.showNotification(data.title || "Verscienta", {
      body: data.body || "",
      icon: "/images/icon-192.png",
      data: { url: data.url || "/" },
    })
  )
})

self.addEventListener("notificationclick", (event) => {
  event.notification.close()
  event.waitUntil(clients.openWindow(event.notification.data.url || "/"))
})
```

- [ ] **Step 2: Serve it at root** — in `lib/verscienta_web.ex`, add `"sw.js"` to `static_paths/0`:
```elixir
def static_paths, do: ~w(assets fonts images favicon.ico robots.txt sw.js)
```
(If no `priv/static/images/icon-192.png` exists, the SW falls back gracefully — the
`icon` is optional; add a 192×192 PNG later or drop the `icon` line.)

- [ ] **Step 3: The hook** — `assets/js/push_subscription.js`:
```js
// Browser push opt-in. Not unit-tested (browser-only).
function urlBase64ToUint8Array(base64String) {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4)
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/")
  const raw = atob(base64)
  return Uint8Array.from([...raw].map((c) => c.charCodeAt(0)))
}

export default {
  mounted() {
    const supported = "serviceWorker" in navigator && "PushManager" in window
    if (!supported) {
      this.el.textContent = "Push not supported on this browser"
      this.el.setAttribute("disabled", "true")
      return
    }

    this.el.addEventListener("click", async () => {
      try {
        const reg = await navigator.serviceWorker.register("/sw.js")
        const perm = await Notification.requestPermission()
        if (perm !== "granted") return

        const sub = await reg.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: urlBase64ToUint8Array(this.el.dataset.publicKey),
        })

        const csrf = document.querySelector("meta[name='csrf-token']").getAttribute("content")
        await fetch("/api/push/subscribe", {
          method: "POST",
          headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" },
          body: JSON.stringify({ subscription: sub.toJSON() }),
        })
        this.el.textContent = "Enabled on this device ✓"
      } catch (_e) {
        this.el.textContent = "Couldn't enable push"
      }
    })
  },
}
```

- [ ] **Step 4: Register the hook** — in `assets/js/app.js`: `import PushSubscription from "./push_subscription"` (with the other local-hook imports) + `Hooks.PushSubscription = PushSubscription` (after the other `Hooks.X =` lines).

- [ ] **Step 5: Settings UI** — in `lib/verscienta_web/live/settings_live.ex`, in the notifications section (near the `#notification-prefs-form`, ~line 210), add a flag+configured-gated block. First, in `mount`, assign `web_push_available: Verscienta.Flags.enabled?(:web_push) and Verscienta.WebPush.configured?()` and `vapid_public_key: Verscienta.WebPush.vapid_public_key()`. Then render:
```heex
<div :if={@web_push_available} class="mt-6">
  <h3 class="mb-2 text-xs lowercase tracking-wider text-ink-3">browser push</h3>
  <label class="mb-2 flex items-center gap-2 text-sm">
    <input
      type="checkbox"
      phx-click="toggle_web_push"
      checked={Map.get(@current_user.notification_prefs, "web_push", true) != false}
    /> enable web push for my account
  </label>
  <button
    type="button"
    id="enable-push-device"
    phx-hook="PushSubscription"
    data-public-key={@vapid_public_key}
    class="border border-line px-3 py-1.5 text-xs uppercase"
  >
    enable on this device
  </button>
</div>
```
And a `handle_event("toggle_web_push", _, socket)` that flips `notification_prefs["web_push"]` via `:update_notification_prefs` and re-assigns `current_user`. (Mirror the existing `save_notification_prefs` handler's update pattern.)

- [ ] **Step 6: Build + a render smoke test**

Run: `docker compose exec app mix assets.build` (esbuild bundles app.js with the new hook; `sw.js` is a static file, untouched by esbuild).
Optionally add to the existing `settings_live_test.exs` (if present) a test that, with `:web_push` enabled, the settings page renders `id="enable-push-device"`. If adding a test, enable the flag in that test (`async: false`).

Run: `docker compose exec app mix compile --warnings-as-errors` — clean.

- [ ] **Step 7: Commit**

```bash
git add priv/static/sw.js lib/verscienta_web.ex assets/js/push_subscription.js assets/js/app.js lib/verscienta_web/live/settings_live.ex test/verscienta_web/live/settings_live_test.exs
git commit -m "feat(push): service worker + subscribe hook + settings opt-in

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
(Stage the settings test only if you added/edited it.)

---

### Task 6: Full verification + docs

**Files:**
- Modify: `docs/todo.md`

- [ ] **Step 1: Format + compile**

Run: `docker compose exec app mix format && docker compose exec app mix compile --warnings-as-errors` — clean.

- [ ] **Step 2: Credo strict**

Run: `docker compose exec app mix credo --strict` — no issues.

- [ ] **Step 3: Run the web-push + notifications + flags + controller suites**

Run: `docker compose exec app mix test test/verscienta/web_push/ test/verscienta/web_push_test.exs test/verscienta/notifications_test.exs test/verscienta/flags_test.exs test/verscienta_web/controllers/push_subscription_controller_test.exs`
Expected: PASS.

- [ ] **Step 4: Full suite**

Run: `docker compose exec app mix test`
Expected: PASS, 0 failures. (Transient seed-contamination → re-run; see project memory.)

- [ ] **Step 5: Update the todo**

In `docs/todo.md`, the `(Optional) Web-push notifications.` line → struck through with a note:
```
~~(Optional) Web-push notifications.~~ *(done — behind the off-by-default `:web_push` flag: `web_push_encryption` (VAPID) + a `PushSubscription` resource, `Verscienta.WebPush.dispatch` from `notify/1` → `SendWebPushWorker` (sends via a Sender seam, prunes dead endpoints), subscribe/unsubscribe JSON endpoints, a `/sw.js` service worker + opt-in hook + settings toggle. Mirrors in-app prefs + a master channel toggle. Browser/media path needs VAPID keys + a real browser to validate.)*
```
(If `docs/todo.md` shows an unrelated modified state, stage only your hunk.)

- [ ] **Step 6: Commit**

```bash
git add docs/todo.md
git commit -m "docs(push): mark web-push notifications done

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review Notes

**Spec coverage:** dep+flag+VAPID+Sender seam+configured? → T1; PushSubscription+save/delete → T2; dispatch+worker+notify → T3; controller → T4; SW+hook+settings → T5; verify+todo → T6.

**Out of scope (per spec):** per-type push prefs; deep-link URLs; grouping/badges; full PWA manifest; VAPID rotation; browser testing of the SW/subscribe/crypto.

**Testability boundary:** `Sender.Live`'s real `web_push_encryption` crypto+HTTP, `sw.js`, the JS hook, and the browser subscribe are NOT unit-tested (browser/network) — the Sender stub + `assert_enqueued`/`perform_job` cover the server side. Documented in code comments.

**Watch-outs:** (1) the Ash codegen command + migrating the TEST db (`MIX_ENV=test mix ecto.migrate`) — Task 2 Step 6. (2) confirm `WebPushEncryption.send_web_push/2`'s return shape when wiring `Sender.Live`. (3) the router auth scope for the controller routes — place where `current_user` is assigned; the controller also nil-guards.
