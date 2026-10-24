# PostHog Analytics (Server-Side) Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture key product-funnel events (signup, publish, follow, article view, search) server-side to PostHog via an `Analytics.Client` behaviour, fire-and-forget and failure-tolerant, for anonymous + signed-in visitors.

**Architecture:** `Verscienta.Analytics` (context + `track_*` helpers) → `Analytics.Client` behaviour (`Req` posts to PostHog `/capture`, fire-and-forget, no-op when unconfigured; `Stub` for tests). An `AnalyticsId` plug gives anonymous visitors a session id; `distinct_id = user.id || analytics_id`. Events fire from Ash after-action changes (signed-in) and LiveView (anon-capable).

**Tech Stack:** Elixir, Ash 3, Phoenix LiveView, `:req` (`Elixir.Req`). All `mix` runs in Docker: `docker compose exec -T app mix …`.

**Spec:** `docs/superpowers/specs/2026-06-05-analytics-design.md`
**Branch:** `phase-3-analytics` (spec already committed here).

**Patterns to mirror (read first):**
- `lib/verscienta/images/client.ex` — behaviour + `Req` impl that calls `Elixir.Req` (note: nested `Req` module → must use `Elixir.Req` for the HTTP lib).
- `lib/verscienta/content/article/changes/enqueue_embedding.ex` — after-action change shape (rescue + `:ok`).
- `lib/verscienta_web/plugs/` (e.g. `CaptureReferral`) — plug style; it's already in the `:browser` pipeline.
- Router: `:browser` pipeline (lines 8–16); `live_session :public_routes` (line ~133) holds the article reader + search.

**Test stub design (important):** the `Analytics.Client.Stub` **sends each call to a configured test pid if set, else no-ops** — cross-process (works for LiveView-fired events), perf-safe (no global list growth across the ~hundreds of user-creating tests), and isolated. Asserting tests are `async: false`, set `analytics_test_pid` to `self()` in `setup`, and use `assert_receive`.

---

## File Structure

**Create:**
- `lib/verscienta/analytics.ex`, `lib/verscienta/analytics/client.ex` (+ nested `Req`), `test/support/analytics_client_stub.ex`.
- `lib/verscienta_web/plugs/analytics_id.ex`.
- change modules: `lib/verscienta/accounts/user/changes/track_signup.ex`, `lib/verscienta/content/article/changes/track_article_published.ex`, `lib/verscienta/social/follow/changes/track_follow.ex`.
- tests: `test/verscienta/analytics_test.exs`, `test/verscienta_web/plugs/analytics_id_test.exs`, `test/verscienta/analytics/instrumentation_test.exs`, additions to a search/reader LiveView test.

**Modify:**
- `config/config.exs`, `config/test.exs`, `config/runtime.exs`.
- `lib/verscienta_web/router.ex` (plug + on_mount), `lib/verscienta_web/live/user_auth.ex` (or the on-mount module) for `:analytics_id`.
- `lib/verscienta/accounts/user.ex`, `lib/verscienta/content/article.ex`, `lib/verscienta/social/follow.ex` (wire changes).
- `lib/verscienta_web/live/article_reader_live.ex`, `lib/verscienta_web/live/search_live.ex`.
- `docs/todo.md`.

---

## Task 1: Analytics context + client + stub + config

**Files:** create `lib/verscienta/analytics.ex`, `lib/verscienta/analytics/client.ex`, `test/support/analytics_client_stub.ex`, `test/verscienta/analytics_test.exs`; modify `config/config.exs`, `config/test.exs`, `config/runtime.exs`.

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/analytics_test.exs`:
```elixir
defmodule Verscienta.AnalyticsTest do
  use ExUnit.Case, async: false

  alias Verscienta.Analytics

  setup do
    Application.put_env(:verscienta, :analytics_test_pid, self())
    on_exit(fn -> Application.delete_env(:verscienta, :analytics_test_pid) end)
    :ok
  end

  describe "distinct_id/2" do
    test "prefers the user id" do
      assert Analytics.distinct_id(%{id: "u1"}, "anon") == "u1"
    end

    test "falls back to analytics_id then anonymous" do
      assert Analytics.distinct_id(nil, "anon-123") == "anon-123"
      assert Analytics.distinct_id(nil, nil) == "anonymous"
    end
  end

  describe "track_* helpers" do
    test "track_search sends length + count, never the raw query" do
      Analytics.track_search("anon-1", "secret query text", 7)
      assert_receive {:analytics, {:capture, "search_performed", "anon-1", props}}
      assert props["query_length"] == String.length("secret query text")
      assert props["result_count"] == 7
      refute Map.has_key?(props, "query")
      refute Enum.any?(Map.values(props), &(&1 == "secret query text"))
    end

    test "track_signup captures signup + identify with username/email" do
      Analytics.track_signup(%{id: "u9", username: "alice", email: "a@example.com"})
      assert_receive {:analytics, {:identify, "u9", %{"username" => "alice", "email" => "a@example.com"}}}
      assert_receive {:analytics, {:capture, "signup", "u9", _}}
    end

    test "track_follow captures the type" do
      Analytics.track_follow("u2", :category)
      assert_receive {:analytics, {:capture, "user_followed", "u2", %{"type" => "category"}}}
    end
  end
end
```

- [ ] **Step 2: Run it (fails — modules undefined)**

`docker compose exec -T app mix test test/verscienta/analytics_test.exs` → FAIL.

- [ ] **Step 3: Implement**

Create `lib/verscienta/analytics/client.ex`:
```elixir
defmodule Verscienta.Analytics.Client do
  @moduledoc "Behaviour + implementations for server-side PostHog capture."

  @callback capture(event :: String.t(), distinct_id :: String.t(), properties :: map) :: :ok
  @callback identify(distinct_id :: String.t(), properties :: map) :: :ok

  def capture(event, distinct_id, properties \\ %{}), do: impl().capture(event, distinct_id, properties)
  def identify(distinct_id, properties), do: impl().identify(distinct_id, properties)

  defp impl, do: Application.get_env(:verscienta, :analytics_client, __MODULE__.Req)

  defmodule Req do
    @moduledoc false
    @behaviour Verscienta.Analytics.Client
    require Logger

    @impl true
    def capture(event, distinct_id, properties), do: send_event(event, distinct_id, properties)

    @impl true
    def identify(distinct_id, properties),
      do: send_event("$identify", distinct_id, %{"$set" => properties})

    defp send_event(event, distinct_id, properties) do
      case api_key() do
        key when is_binary(key) and key != "" ->
          payload = %{
            api_key: key,
            event: event,
            distinct_id: to_string(distinct_id),
            properties: properties
          }

          Task.start(fn -> post(payload) end)
          :ok

        _ ->
          :ok
      end
    end

    defp post(payload) do
      Elixir.Req.post(host() <> "/capture/", json: payload, receive_timeout: 5_000)
    rescue
      e -> Logger.debug("analytics capture failed: #{inspect(e)}")
    catch
      kind, e -> Logger.debug("analytics capture failed: #{inspect({kind, e})}")
    end

    defp api_key, do: Application.get_env(:verscienta, :posthog_api_key)
    defp host, do: Application.get_env(:verscienta, :posthog_host, "https://us.i.posthog.com")
  end
end
```

Create `lib/verscienta/analytics.ex`:
```elixir
defmodule Verscienta.Analytics do
  @moduledoc """
  Server-side product analytics (PostHog). Fire-and-forget — never blocks or
  raises in the request path. `distinct_id` is the user id when signed in,
  else the session `analytics_id`, else `"anonymous"`.
  """
  alias Verscienta.Analytics.Client

  @spec capture(String.t(), String.t(), map()) :: :ok
  def capture(event, distinct_id, properties \\ %{}),
    do: Client.capture(event, distinct_id, properties)

  @spec identify(String.t(), map()) :: :ok
  def identify(distinct_id, properties), do: Client.identify(distinct_id, properties)

  @spec distinct_id(map() | nil, String.t() | nil) :: String.t()
  def distinct_id(%{id: id}, _analytics_id), do: to_string(id)
  def distinct_id(_user, analytics_id) when is_binary(analytics_id), do: analytics_id
  def distinct_id(_user, _analytics_id), do: "anonymous"

  def track_signup(user) do
    id = to_string(user.id)
    identify(id, %{"username" => to_string(user.username), "email" => to_string(user.email)})
    capture("signup", id)
  end

  def track_article_published(article) do
    capture("article_published", to_string(article.author_id), %{
      "category" => to_string(article.category),
      "article_id" => to_string(article.id)
    })
  end

  def track_follow(follower_id, type) do
    capture("user_followed", to_string(follower_id), %{"type" => to_string(type)})
  end

  def track_article_view(article, distinct_id) do
    capture("article_viewed", distinct_id, %{
      "category" => to_string(article.category),
      "article_id" => to_string(article.id)
    })
  end

  def track_search(distinct_id, query, result_count) do
    capture("search_performed", distinct_id, %{
      "query_length" => String.length(query || ""),
      "result_count" => result_count
    })
  end
end
```

Create `test/support/analytics_client_stub.ex`:
```elixir
defmodule Verscienta.Analytics.Client.Stub do
  @moduledoc "Test double: forwards calls to `:analytics_test_pid` if set, else no-ops."
  @behaviour Verscienta.Analytics.Client

  @impl true
  def capture(event, distinct_id, properties),
    do: notify({:capture, event, distinct_id, properties})

  @impl true
  def identify(distinct_id, properties), do: notify({:identify, distinct_id, properties})

  defp notify(msg) do
    case Application.get_env(:verscienta, :analytics_test_pid) do
      pid when is_pid(pid) -> send(pid, {:analytics, msg})
      _ -> :ok
    end

    :ok
  end
end
```
(Confirm `test/support` modules are compiled in the test env — the other stubs live there, so they are.)

Config:
- `config/config.exs`: add `config :verscienta, analytics_client: Verscienta.Analytics.Client.Req` (near the other `*_client` lines).
- `config/test.exs`: add `config :verscienta, analytics_client: Verscienta.Analytics.Client.Stub`.
- `config/runtime.exs`: inside the `:prod`/runtime config, add to the `:verscienta` app env:
  ```elixir
  config :verscienta,
    posthog_host: System.get_env("POSTHOG_HOST", "https://us.i.posthog.com"),
    posthog_api_key: System.get_env("POSTHOG_API_KEY")
  ```
  (Place it consistently with how other runtime env reads are done; a nil/blank `POSTHOG_API_KEY` leaves the Req client a no-op.)

- [ ] **Step 4: Run the test (passes)**

`docker compose exec -T app mix test test/verscienta/analytics_test.exs` → PASS.

- [ ] **Step 5: format, credo, warnings, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix compile --force --warnings-as-errors 2>&1 | tail -4
docker compose exec -T app mix credo --strict lib/verscienta/analytics.ex lib/verscienta/analytics/client.ex 2>&1 | tail -4
git add lib/verscienta/analytics.ex lib/verscienta/analytics/client.ex test/support/analytics_client_stub.ex test/verscienta/analytics_test.exs config/config.exs config/test.exs config/runtime.exs
git commit -m "feat(analytics): Analytics context + PostHog client (Req/Stub) + config"
```

---

## Task 2: AnalyticsId plug + on_mount

**Files:** create `lib/verscienta_web/plugs/analytics_id.ex`, `test/verscienta_web/plugs/analytics_id_test.exs`; modify `lib/verscienta_web/router.ex`, `lib/verscienta_web/live/user_auth.ex` (the `LiveUserAuth` on-mount module).

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/plugs/analytics_id_test.exs`:
```elixir
defmodule VerscientaWeb.Plugs.AnalyticsIdTest do
  use VerscientaWeb.ConnCase, async: true
  import Plug.Conn

  alias VerscientaWeb.Plugs.AnalyticsId

  defp with_session(conn) do
    conn
    |> Plug.Test.init_test_session(%{})
  end

  test "assigns a new analytics_id and stores it in the session", %{conn: conn} do
    conn = conn |> with_session() |> AnalyticsId.call([])
    id = conn.assigns.analytics_id
    assert is_binary(id) and id != ""
    assert get_session(conn, :analytics_id) == id
  end

  test "reuses an existing session analytics_id", %{conn: conn} do
    conn = conn |> with_session() |> put_session(:analytics_id, "existing-id") |> AnalyticsId.call([])
    assert conn.assigns.analytics_id == "existing-id"
    assert get_session(conn, :analytics_id) == "existing-id"
  end
end
```

- [ ] **Step 2: Run it (fails — plug undefined)**

`docker compose exec -T app mix test test/verscienta_web/plugs/analytics_id_test.exs` → FAIL.

- [ ] **Step 3: Implement**

Create `lib/verscienta_web/plugs/analytics_id.ex`:
```elixir
defmodule VerscientaWeb.Plugs.AnalyticsId do
  @moduledoc """
  Ensures every browser session has a stable anonymous `analytics_id`, stored in
  the session and assigned for use as a PostHog `distinct_id` when logged out.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :analytics_id) do
      id when is_binary(id) and id != "" ->
        assign(conn, :analytics_id, id)

      _ ->
        id = Ecto.UUID.generate()
        conn |> put_session(:analytics_id, id) |> assign(:analytics_id, id)
    end
  end
end
```

In `lib/verscienta_web/router.ex`, add the plug to the `:browser` pipeline (after `:fetch_session`, e.g. right before/after `CaptureReferral`):
```elixir
    plug VerscientaWeb.Plugs.AnalyticsId
```

In `lib/verscienta_web/live/user_auth.ex` (the `VerscientaWeb.LiveUserAuth` module — confirm the module name backing the existing `on_mount` clauses), add an on-mount clause:
```elixir
  def on_mount(:analytics_id, _params, session, socket) do
    {:cont, Phoenix.Component.assign(socket, :analytics_id, session["analytics_id"])}
  end
```
And add `{VerscientaWeb.LiveUserAuth, :analytics_id}` to the `on_mount:` list of the `live_session :public_routes` block in the router (the one holding `/articles/:slug` and `/search`).

- [ ] **Step 4: Run the test (passes)**

`docker compose exec -T app mix test test/verscienta_web/plugs/analytics_id_test.exs` → PASS.

- [ ] **Step 5: format, credo, warnings, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix compile --force --warnings-as-errors 2>&1 | tail -4
docker compose exec -T app mix credo --strict lib/verscienta_web/plugs/analytics_id.ex lib/verscienta_web/live/user_auth.ex 2>&1 | tail -4
git add lib/verscienta_web/plugs/analytics_id.ex lib/verscienta_web/router.ex lib/verscienta_web/live/user_auth.ex test/verscienta_web/plugs/analytics_id_test.exs
git commit -m "feat(analytics): anonymous analytics_id session plug + on_mount"
```

---

## Task 3: After-action event changes (signup, published, followed)

**Files:** create the three change modules + `test/verscienta/analytics/instrumentation_test.exs`; modify `user.ex`, `article.ex`, `follow.ex`.

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/analytics/instrumentation_test.exs`:
```elixir
defmodule Verscienta.Analytics.InstrumentationTest do
  use Verscienta.DataCase, async: false

  setup do
    Application.put_env(:verscienta, :analytics_test_pid, self())
    on_exit(fn -> Application.delete_env(:verscienta, :analytics_test_pid) end)
    :ok
  end

  defp user(name) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com", username: name,
      password: "password123", password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  test "registering a user fires signup + identify" do
    _ = user("trackme")
    assert_receive {:analytics, {:capture, "signup", _id, _}}
    assert_receive {:analytics, {:identify, _id, %{"username" => "trackme"}}}
  end

  test "publishing an article fires article_published" do
    a = user("pubtracker")
    {:ok, art} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: "Tracked", blocks: [], category: :nutrition}, actor: a)
      |> Ash.create()

    # drain the signup event from the mailbox window
    receive do
      {:analytics, _} -> :ok
    after
      0 -> :ok
    end

    {:ok, _} = art |> Ash.Changeset.for_update(:publish, %{}, actor: a) |> Ash.update()
    assert_receive {:analytics, {:capture, "article_published", _author_id, %{"category" => "nutrition"}}}
  end

  test "following fires user_followed" do
    me = user("follower")
    other = user("followee")

    Verscienta.Social.Follow
    |> Ash.ActionInput.for_action(:toggle, %{type: :user, id: to_string(other.id)}, actor: me)
    |> Ash.run_action!()

    assert_receive {:analytics, {:capture, "user_followed", _id, %{"type" => "user"}}}
  end
end
```
(Adjust the `:toggle` argument shape to the follow action's actual signature — READ `lib/verscienta/social/follow.ex`; it may take `%{type:, id:}` or positional. The point is: a follow fires `user_followed`.)

- [ ] **Step 2: Run it (fails — no tracking)**

`docker compose exec -T app mix test test/verscienta/analytics/instrumentation_test.exs` → FAIL.

- [ ] **Step 3: Implement**

(a) `lib/verscienta/accounts/user/changes/track_signup.ex`:
```elixir
defmodule Verscienta.Accounts.User.Changes.TrackSignup do
  @moduledoc "After-action: emit a `signup` analytics event."
  use Ash.Resource.Change
  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _cs, user ->
      safe(fn -> Verscienta.Analytics.track_signup(user) end)
      {:ok, user}
    end)
  end

  defp safe(fun) do
    fun.()
    :ok
  rescue
    e ->
      Logger.debug("track_signup failed: #{inspect(e)}")
      :ok
  end
end
```

(b) `lib/verscienta/content/article/changes/track_article_published.ex`:
```elixir
defmodule Verscienta.Content.Article.Changes.TrackArticlePublished do
  @moduledoc "After-action: emit an `article_published` analytics event."
  use Ash.Resource.Change
  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _cs, article ->
      try do
        Verscienta.Analytics.track_article_published(article)
      rescue
        e -> Logger.debug("track_article_published failed: #{inspect(e)}")
      end

      {:ok, article}
    end)
  end
end
```

(c) `lib/verscienta/social/follow/changes/track_follow.ex`:
```elixir
defmodule Verscienta.Social.Follow.Changes.TrackFollow do
  @moduledoc "After-action: emit a `user_followed` analytics event."
  use Ash.Resource.Change
  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _cs, follow ->
      try do
        Verscienta.Analytics.track_follow(follow.user_id, follow.target_type)
      rescue
        e -> Logger.debug("track_follow failed: #{inspect(e)}")
      end

      {:ok, follow}
    end)
  end
end
```
(Use the same `try/rescue` shape consistently; the `TrackSignup` `safe/1` helper variant is equivalent — pick one style across the three. Confirm the Follow attribute names: `user_id` (the follower, set by `relate_actor(:user)`) and `target_type`.)

(d) Wire the changes:
- `lib/verscienta/accounts/user.ex` — add `change Verscienta.Accounts.User.Changes.TrackSignup` to `:register_with_password` (line ~215, alongside the other changes).
- `lib/verscienta/content/article.ex` — add `change Verscienta.Content.Article.Changes.TrackArticlePublished` to `:publish`.
- `lib/verscienta/social/follow.ex` — add `change Verscienta.Social.Follow.Changes.TrackFollow` to `:create`.

- [ ] **Step 4: Run the test (passes) + no regression in those resources' tests**

```bash
docker compose exec -T app mix test test/verscienta/analytics/instrumentation_test.exs 2>&1 | tail -5
docker compose exec -T app mix test test/verscienta/accounts test/verscienta/social test/verscienta/content 2>&1 | tail -5
```
Expected: PASS; no regression (analytics is no-op in those tests since they don't set `analytics_test_pid`).

- [ ] **Step 5: format, credo, warnings, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix compile --force --warnings-as-errors 2>&1 | tail -4
docker compose exec -T app mix credo --strict 2>&1 | tail -4
git add lib/verscienta/accounts lib/verscienta/content lib/verscienta/social test/verscienta/analytics
git commit -m "feat(analytics): signup/article_published/user_followed after-action events"
```

---

## Task 4: LiveView events (article_viewed, search_performed)

**Files:** modify `lib/verscienta_web/live/article_reader_live.ex`, `lib/verscienta_web/live/search_live.ex`; add a test (e.g. `test/verscienta_web/live/analytics_liveview_test.exs`).

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/analytics_liveview_test.exs`:
```elixir
defmodule VerscientaWeb.AnalyticsLiveViewTest do
  use VerscientaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Verscienta.Search.ClientStub

  setup do
    Application.put_env(:verscienta, :analytics_test_pid, self())
    ClientStub.reset()
    on_exit(fn ->
      Application.delete_env(:verscienta, :analytics_test_pid)
      ClientStub.reset()
    end)
    :ok
  end

  defp user(name) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com", username: name,
      password: "password123", password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp publish(a, title) do
    {:ok, art} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: title, blocks: [], category: :nutrition}, actor: a)
      |> Ash.create()

    {:ok, p} = art |> Ash.Changeset.for_update(:publish, %{}, actor: a) |> Ash.update()
    p
  end

  test "viewing an article (connected) fires article_viewed", %{conn: conn} do
    a = user("viewauthor")
    art = publish(a, "Viewable")

    {:ok, _lv, _html} = live(conn, ~p"/articles/#{art.slug}")
    assert_receive {:analytics, {:capture, "article_viewed", distinct_id, %{"category" => "nutrition"}}}
    assert is_binary(distinct_id)
  end

  test "searching fires search_performed with length + count, not the query", %{conn: conn} do
    Application.put_env(:verscienta, :search_stub, %{
      search: {:ok, %{"hits" => [], "facetDistribution" => %{}, "estimatedTotalHits" => 0}}
    })

    {:ok, lv, _html} = live(conn, ~p"/search")
    lv |> form("#search-form", %{"q" => "adaptogen"}) |> render_change()

    assert_receive {:analytics, {:capture, "search_performed", _id, props}}
    assert props["query_length"] == String.length("adaptogen")
    assert props["result_count"] == 0
    refute Enum.any?(Map.values(props), &(&1 == "adaptogen"))
  end
end
```

- [ ] **Step 2: Run it (fails — not instrumented)**

`docker compose exec -T app mix test test/verscienta_web/live/analytics_liveview_test.exs` → FAIL.

- [ ] **Step 3: Implement**

(a) `lib/verscienta_web/live/article_reader_live.ex` — in `mount`, after the article is loaded and assigned, fire the view event **only on the connected mount** (avoids the double dead-render/connected count and bot dead-renders). Add `alias Verscienta.Analytics` and:
```elixir
    if connected?(socket) do
      Analytics.track_article_view(
        article,
        Analytics.distinct_id(socket.assigns[:current_user], socket.assigns[:analytics_id])
      )
    end
```
(Place it where `article` and the assigns are available, e.g. just before the final `{:ok, socket}`.)

(b) `lib/verscienta_web/live/search_live.ex` — add `alias Verscienta.Analytics`; in `handle_event("search", params, socket)`, after computing `results`, fire (skip blank queries):
```elixir
    if query != "" do
      Analytics.track_search(
        Analytics.distinct_id(socket.assigns[:current_user], socket.assigns[:analytics_id]),
        query,
        results.total
      )
    end
```
(`query` and `results` already exist in that handler; `results.total` is the count.)

- [ ] **Step 4: Run the test (passes)**

`docker compose exec -T app mix test test/verscienta_web/live/analytics_liveview_test.exs 2>&1 | tail -5`
Expected: PASS. If `article_viewed` doesn't arrive, confirm the `:analytics_id` on_mount is attached to `:public_routes` (Task 2) and that `live/2` connects (it does). If `socket.assigns[:analytics_id]` is nil in the test, the on_mount/session wiring needs checking.

- [ ] **Step 5: format, credo, warnings, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix compile --force --warnings-as-errors 2>&1 | tail -4
docker compose exec -T app mix credo --strict lib/verscienta_web/live/article_reader_live.ex lib/verscienta_web/live/search_live.ex 2>&1 | tail -4
git add lib/verscienta_web/live/article_reader_live.ex lib/verscienta_web/live/search_live.ex test/verscienta_web/live/analytics_liveview_test.exs
git commit -m "feat(analytics): article_viewed + search_performed LiveView events"
```

---

## Task 5: Docs + full verification

**Files:** modify `docs/todo.md`.

- [ ] **Step 1: Check off the todo**

In `docs/todo.md` under "### Growth", change:
`- [ ] PostHog (self-hosted) analytics + key funnels/events instrumented.`
to:
`- [x] PostHog (self-hosted) analytics + key funnels/events instrumented. *(server-side capture: signup/article_published/user_followed/article_viewed/search_performed; anon+signed-in; Growth slice 3. Client-side posthog-js deferred to post-consent.)*`

- [ ] **Step 2: Full suite + format**

```bash
docker compose exec -T app bash -lc 'mix format && mix format --check-formatted && mix test 2>&1 | tail -6'
```
Expected: format clean; 0 failures. (Known flake: `NotificationBellTest` passes on re-run; if it's the only failure, re-run once.)

- [ ] **Step 3: Warnings + Credo + Dialyzer**

```bash
docker compose exec -T app mix compile --force --warnings-as-errors 2>&1 | tail -4
docker compose exec -T app mix credo --strict 2>&1 | tail -4
docker compose exec -T app mix dialyzer 2>&1 | tail -8
```
Expected: compile no warnings; credo "found no issues"; dialyzer "passed successfully". If dialyzer reports NEW errors (the `Analytics` specs are the likely source), paste them; do NOT commit on red.

- [ ] **Step 4: Commit**

```bash
git add docs/todo.md
git commit -m "docs: check off PostHog analytics (Growth slice 3)"
```

- [ ] **Step 5:** Confirm all gates green — branch ready to merge.

---

## Notes for the implementer

- **Never let analytics break a request.** Every event call site is rescued (the after-action changes) or fire-and-forget (the `Req` client `Task.start`). The `track_*` helpers themselves call `Client.capture` which is the configured impl — in prod that's `Req` (async); in test that's `Stub` (sync `send`).
- **Stub is pid-based** so it works across processes (LiveView events fire in the LV process and `send` to the test pid) and doesn't accumulate global state across the suite. Only tests that set `:analytics_test_pid` observe events; all other tests no-op.
- **`distinct_id` resolution**: `user.id` when signed in, else the session `analytics_id` (from the plug/on_mount), else `"anonymous"`. The two LiveView events pass `Analytics.distinct_id(current_user, analytics_id)`; the three after-action events use the actor/author/follower id directly.
- **`article_viewed` fires only on `connected?(socket)`** — once per real session, and not for bot dead-renders.
- **No raw search text** ever leaves the app — `track_search` sends only `query_length` + `result_count`.
- Confirm the Follow `:create` attribute names (`user_id`, `target_type`) by reading `lib/verscienta/social/follow.ex`; adjust `track_follow` args if they differ.
- The `Req` client must call `Elixir.Req.post/2` (not `Req.post`) because the module is itself named `…Client.Req` — mirror `Verscienta.Images.Client.Req`.
