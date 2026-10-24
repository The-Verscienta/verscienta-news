# Test Coverage Expansion Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the meaningful coverage gaps found by `mix test --cover` (baseline 78.11%, 920 tests green) and make the coverage number trustworthy + CI-enforced.

**Architecture:** Test-only changes plus two small config changes. New ExUnit test files for untested web flows (referral capture, auth controller, store history, goodbye), targeted additions to existing test files for uncovered branches (leaderboards, snapshot worker, leaderboard live, block renderer, notification bell), a `Communities.Counts` test, then `test_coverage` config in `mix.exs` and `--cover` in CI.

**Tech Stack:** ExUnit, `Phoenix.ConnTest`, `Phoenix.LiveViewTest`, `Oban.Testing`, existing `Verscienta.Support.Factory` / stubs. No new deps.

**Spec:** `docs/superpowers/specs/2026-06-10-test-coverage-expansion-design.md`

---

## Conventions for every task

- **Run commands in the dev container against this worktree.** Wherever a step says `Run: <CMD>`, execute:

  ```
  docker exec news-verscienta-app-1 bash -lc "cd /workspace/.claude/worktrees/ecstatic-stonebraker-d1cb0b && <CMD>"
  ```

  Host `mix` does NOT work (bcrypt/nmake). Git commands run on the host in the worktree directory as usual.

- **These tests pin existing behavior.** Expected first run result is PASS. If a test FAILS, do not silently change app code: first verify the test matches the module's actual contract (re-read the module); if the test is right and the code is wrong, you found a real bug — stop and report it in your task summary instead of fixing it unreviewed.

- **Feature flags persist outside the SQL sandbox** (FunWithFlags ETS cache + DB rows survive across tests; some flags like `:leaderboards`/`:reward_store` are already enabled in the shared test DB). Never blindly disable a flag in `on_exit` — always use the guarded pattern shown in each test so you only restore the prior state.

- **Never assert global row counts** (the test DB can contain committed seed rows). Scope every query/assertion to data the test created.

- Before every commit: `Run: mix format` then `git add <files> && git commit` on the host. Commit messages end with:

  ```
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  ```

---

### Task 1: CaptureReferral plug tests

**Files:**
- Create: `test/verscienta_web/plugs/capture_referral_test.exs`
- Covers: `lib/verscienta_web/plugs/capture_referral.ex` (57% → ~100%)

- [ ] **Step 1: Write the test file**

```elixir
defmodule VerscientaWeb.Plugs.CaptureReferralTest do
  use VerscientaWeb.ConnCase, async: true

  alias VerscientaWeb.Plugs.CaptureReferral

  test "?ref= sets a 30-day HttpOnly Lax cookie" do
    conn =
      Phoenix.ConnTest.build_conn(:get, "/articles?ref=ABCD2345")
      |> CaptureReferral.call(CaptureReferral.init([]))

    assert %{value: "ABCD2345", max_age: 2_592_000, http_only: true, same_site: "Lax"} =
             conn.resp_cookies[CaptureReferral.cookie_name()]
  end

  test "missing ref leaves the conn untouched" do
    conn =
      Phoenix.ConnTest.build_conn(:get, "/articles")
      |> CaptureReferral.call([])

    refute conn.resp_cookies[CaptureReferral.cookie_name()]
  end

  test "empty ref leaves the conn untouched" do
    conn =
      Phoenix.ConnTest.build_conn(:get, "/articles?ref=")
      |> CaptureReferral.call([])

    refute conn.resp_cookies[CaptureReferral.cookie_name()]
  end
end
```

- [ ] **Step 2: Run it**

Run: `MIX_ENV=test mix test test/verscienta_web/plugs/capture_referral_test.exs`
Expected: 3 tests, 0 failures

- [ ] **Step 3: Format + commit**

Run: `mix format test/verscienta_web/plugs/capture_referral_test.exs`

```bash
git add test/verscienta_web/plugs/capture_referral_test.exs
git commit -m "test(referrals): cover CaptureReferral plug cookie behavior"
```

---

### Task 2: ReferralRedirectController test

**Files:**
- Create: `test/verscienta_web/controllers/referral_redirect_controller_test.exs`
- Covers: `lib/verscienta_web/controllers/referral_redirect_controller.ex` (0% → 100%)

Note: `GET /r/:code` is behind the `:gate_referrals` pipeline, so the `:referrals` flag must be on.

- [ ] **Step 1: Write the test file**

```elixir
defmodule VerscientaWeb.ReferralRedirectControllerTest do
  use VerscientaWeb.ConnCase, async: false

  alias VerscientaWeb.Plugs.CaptureReferral

  setup do
    was = FunWithFlags.enabled?(:referrals)
    FunWithFlags.enable(:referrals)
    on_exit(fn -> unless was, do: FunWithFlags.disable(:referrals) end)
    :ok
  end

  test "GET /r/:code drops the referral cookie and redirects home", %{conn: conn} do
    conn = get(conn, ~p"/r/ABCD2345")

    assert redirected_to(conn) == ~p"/"

    assert %{value: "ABCD2345", http_only: true} =
             conn.resp_cookies[CaptureReferral.cookie_name()]
  end
end
```

- [ ] **Step 2: Run it**

Run: `MIX_ENV=test mix test test/verscienta_web/controllers/referral_redirect_controller_test.exs`
Expected: 1 test, 0 failures

- [ ] **Step 3: Format + commit**

Run: `mix format test/verscienta_web/controllers/referral_redirect_controller_test.exs`

```bash
git add test/verscienta_web/controllers/referral_redirect_controller_test.exs
git commit -m "test(referrals): cover /r/:code redirect controller"
```

---

### Task 3: AuthController tests

**Files:**
- Create: `test/verscienta_web/controllers/auth_controller_test.exs`
- Covers: `lib/verscienta_web/controllers/auth_controller.ex` (6.9% → high)

Strategy: direct calls to `success/4`, `failure/3`, `post_auth_path/2` for deterministic branch coverage, plus real POSTs through the AshAuthentication routes for integration honesty (register + referral capture, sign-in failure, sign-out).

- [ ] **Step 1: Write the test file**

```elixir
defmodule VerscientaWeb.AuthControllerTest do
  use VerscientaWeb.ConnCase, async: false

  import Verscienta.Support.Factory, only: [user: 1, sign_in: 2]

  require Ash.Query

  alias Verscienta.Gamification.Referral
  alias VerscientaWeb.AuthController
  alias VerscientaWeb.Plugs.CaptureReferral

  defp set_code(u) do
    u
    |> Ash.Changeset.for_update(:generate_referral_code, %{})
    |> Ash.update!(authorize?: false)
  end

  defp prepared(conn) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Phoenix.Controller.fetch_flash()
  end

  defp register_params(name) do
    %{
      "user" => %{
        "email" => name <> "@example.com",
        "username" => name,
        "password" => "password123",
        "password_confirmation" => "password123"
      }
    }
  end

  describe "success/4 (direct)" do
    test "confirm activity flashes the confirmation message", %{conn: conn} do
      u = user("ac_confirm")
      conn = prepared(conn) |> AuthController.success({:confirm_new_user, :confirm}, u, nil)

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "confirmed"
    end

    test "password-reset activity flashes the reset message", %{conn: conn} do
      u = user("ac_reset")
      conn = prepared(conn) |> AuthController.success({:password, :reset}, u, nil)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "reset"
    end

    test "default activity flashes signed-in and honors return_to", %{conn: conn} do
      u = user("ac_return")

      conn =
        conn
        |> Plug.Test.init_test_session(%{"return_to" => "/articles"})
        |> Phoenix.Controller.fetch_flash()
        |> AuthController.success({:password, :sign_in}, u, nil)

      assert redirected_to(conn) == "/articles"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "signed in"
    end
  end

  test "post_auth_path/2 sends register to /welcome, everything else to return_to" do
    assert AuthController.post_auth_path({:password, :register}, "/x") == ~p"/welcome"
    assert AuthController.post_auth_path({:password, :sign_in}, "/x") == "/x"
  end

  describe "failure/3 (direct)" do
    test "generic failure flashes incorrect credentials", %{conn: conn} do
      err = AshAuthentication.Errors.AuthenticationFailed.exception([])
      conn = prepared(conn) |> AuthController.failure({:password, :sign_in}, err)

      assert redirected_to(conn) == ~p"/sign-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Incorrect email or password"
    end

    test "unconfirmed-user failure gets the special message", %{conn: conn} do
      inner = AshAuthentication.Errors.CannotConfirmUnconfirmedUser.exception([])
      forbidden = Ash.Error.Forbidden.exception(errors: [inner])
      err = AshAuthentication.Errors.AuthenticationFailed.exception(caused_by: forbidden)

      conn = prepared(conn) |> AuthController.failure({:confirm_new_user, :confirm}, err)

      assert redirected_to(conn) == ~p"/sign-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "confirm your account"
    end
  end

  describe "register flow (e2e)" do
    test "register redirects to /welcome and captures the referral cookie", %{conn: conn} do
      was = FunWithFlags.enabled?(:referrals)
      FunWithFlags.enable(:referrals)
      on_exit(fn -> unless was, do: FunWithFlags.disable(:referrals) end)

      referrer = user("ref_owner") |> set_code()

      conn =
        conn
        |> put_req_cookie(CaptureReferral.cookie_name(), referrer.referral_code)
        |> post("/auth/user/password/register", register_params("freshie"))

      assert redirected_to(conn) == ~p"/welcome"

      [r] =
        Referral
        |> Ash.Query.filter(referrer_id == ^referrer.id)
        |> Ash.read!(authorize?: false)

      assert r.status == :pending

      # the response deletes the referral cookie
      assert %{max_age: 0} = conn.resp_cookies[CaptureReferral.cookie_name()]
    end

    test "flag off: register succeeds but captures nothing", %{conn: conn} do
      was = FunWithFlags.enabled?(:referrals)
      FunWithFlags.disable(:referrals)
      on_exit(fn -> if was, do: FunWithFlags.enable(:referrals) end)

      referrer = user("ref_owner2") |> set_code()

      conn =
        conn
        |> put_req_cookie(CaptureReferral.cookie_name(), referrer.referral_code)
        |> post("/auth/user/password/register", register_params("freshie2"))

      assert redirected_to(conn) == ~p"/welcome"

      assert [] =
               Referral
               |> Ash.Query.filter(referrer_id == ^referrer.id)
               |> Ash.read!(authorize?: false)
    end
  end

  test "sign-in failure (e2e) redirects to /sign-in with the error flash", %{conn: conn} do
    _u = user("siguser")

    conn =
      post(conn, "/auth/user/password/sign_in", %{
        "user" => %{"email" => "siguser@example.com", "password" => "wrongpass"}
      })

    assert redirected_to(conn) == ~p"/sign-in"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Incorrect email or password"
  end

  test "sign-out (e2e) flashes and redirects home", %{conn: conn} do
    u = user("souser")
    conn = conn |> sign_in(u) |> get("/sign-out")

    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "signed out"
  end
end
```

- [ ] **Step 2: Run it**

Run: `MIX_ENV=test mix test test/verscienta_web/controllers/auth_controller_test.exs`
Expected: 9 tests, 0 failures

Known adjustment points if a test errors (fix the TEST, these are contract details, not app bugs):
- `AshAuthentication.Errors.AuthenticationFailed.exception([])` / `CannotConfirmUnconfirmedUser.exception([])` may require fields — check the raised struct error message and supply the minimal keyword list it names.
- If the register POST does not reach `success/4` (e.g. 404), print `VerscientaWeb.Router.__routes__/0` paths under `/auth` and use the exact register path; the params stay under the `"user"` key.
- If two registers from `127.0.0.1` trip the per-IP register rate limit, raise the bucket for this file the way `test/verscienta/accounts/rate_limit_register_test.exs` does (`Application.put_env(:verscienta, Verscienta.RateLimit, buckets: %{register_ip: {60_000, 100}})` in `setup` with `on_exit` restore of the prior value).

- [ ] **Step 3: Format + commit**

Run: `mix format test/verscienta_web/controllers/auth_controller_test.exs`

```bash
git add test/verscienta_web/controllers/auth_controller_test.exs
git commit -m "test(auth): cover AuthController success/failure/sign-out + referral capture"
```

---

### Task 4: SettingsReferralsLive tests

**Files:**
- Create: `test/verscienta_web/live/settings_referrals_live_test.exs`
- Covers: `lib/verscienta_web/live/settings_referrals_live.ex` (0% → high)

Note: a freshly-created/updated user has `updated_at ≈ now`, and `rotate_allowed?/1` requires `updated_at` ≥ 24h old — so the success-path test must backdate `updated_at` via SQL **before** mounting.

- [ ] **Step 1: Write the test file**

```elixir
defmodule VerscientaWeb.SettingsReferralsLiveTest do
  use VerscientaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Verscienta.Support.Factory, only: [user: 1, sign_in: 2]

  alias Verscienta.Accounts.User
  alias VerscientaWeb.SettingsReferralsLive

  setup do
    was = FunWithFlags.enabled?(:referrals)
    FunWithFlags.enable(:referrals)
    on_exit(fn -> unless was, do: FunWithFlags.disable(:referrals) end)
    :ok
  end

  defp set_code(u) do
    u
    |> Ash.Changeset.for_update(:generate_referral_code, %{})
    |> Ash.update!(authorize?: false)
  end

  defp backdate_updated_at!(u, hours) do
    Ecto.Adapters.SQL.query!(
      Verscienta.Repo,
      "UPDATE users SET updated_at = NOW() - INTERVAL '#{hours} hours' WHERE id = $1",
      [Ecto.UUID.dump!(u.id)]
    )
  end

  test "mount generates a referral code when missing and shows the share link", %{conn: conn} do
    u = user("srl_nocode")
    assert u.referral_code == nil

    {:ok, _view, html} = conn |> sign_in(u) |> live(~p"/settings/referrals")

    reloaded = Ash.get!(User, u.id, authorize?: false)
    assert is_binary(reloaded.referral_code)
    assert html =~ reloaded.referral_code
    assert html =~ "/r/" <> reloaded.referral_code
  end

  test "rotate replaces the code after the 24h cooldown", %{conn: conn} do
    u = user("srl_rotate") |> set_code()
    old = u.referral_code
    backdate_updated_at!(u, 25)

    {:ok, view, _html} = conn |> sign_in(u) |> live(~p"/settings/referrals")
    html = view |> element(~s{button[phx-click="rotate"]}) |> render_click()

    reloaded = Ash.get!(User, u.id, authorize?: false)
    assert reloaded.referral_code != old
    assert html =~ reloaded.referral_code
  end

  test "rotate inside the cooldown shows the error and keeps the code", %{conn: conn} do
    u = user("srl_cooldown") |> set_code()
    old = u.referral_code

    {:ok, view, _html} = conn |> sign_in(u) |> live(~p"/settings/referrals")
    html = view |> element(~s{button[phx-click="rotate"]}) |> render_click()

    assert html =~ "once every 24 hours"
    assert Ash.get!(User, u.id, authorize?: false).referral_code == old
  end

  test "share_link/1 builds the /r/ URL on the endpoint" do
    assert SettingsReferralsLive.share_link("ABC") ==
             VerscientaWeb.Endpoint.url() <> "/r/ABC"
  end
end
```

- [ ] **Step 2: Run it**

Run: `MIX_ENV=test mix test test/verscienta_web/live/settings_referrals_live_test.exs`
Expected: 4 tests, 0 failures

If the `element/2` selector misses, open `lib/verscienta_web/live/settings_referrals_live.html.heex` and use the rotate button's actual attributes.

- [ ] **Step 3: Format + commit**

Run: `mix format test/verscienta_web/live/settings_referrals_live_test.exs`

```bash
git add test/verscienta_web/live/settings_referrals_live_test.exs
git commit -m "test(referrals): cover settings referrals page incl. rotate cooldown"
```

---

### Task 5: StoreHistoryLive + GoodbyeLive tests

**Files:**
- Create: `test/verscienta_web/live/store_history_live_test.exs`
- Create: `test/verscienta_web/live/goodbye_live_test.exs`
- Covers: `store_history_live.ex` (0%), `goodbye_live.ex` (0%)

- [ ] **Step 1: Write the store history test**

```elixir
defmodule VerscientaWeb.StoreHistoryLiveTest do
  use VerscientaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Verscienta.Support.Factory, only: [user: 1, sign_in: 2]

  alias Verscienta.Gamification
  alias Verscienta.Gamification.RewardItem
  alias Verscienta.Gamification.Seeds
  alias Verscienta.Gamification.Store

  setup do
    was = FunWithFlags.enabled?(:reward_store)
    FunWithFlags.enable(:reward_store)
    on_exit(fn -> unless was, do: FunWithFlags.disable(:reward_store) end)
    Seeds.seed_rewards!()
    :ok
  end

  defp redeem_streak_freeze!(u) do
    item =
      RewardItem
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.key == :streak_freeze))

    {:ok, r} = Store.redeem(u, item)
    r
  end

  test "lists the user's redemptions with item name and cost", %{conn: conn} do
    u = user("hist_u")
    :ok = Gamification.award(u.id, :article_published, "hist-seed", 500)
    r = redeem_streak_freeze!(u)

    {:ok, _view, html} = conn |> sign_in(u) |> live(~p"/store/history")

    assert html =~ "redemptions"
    assert html =~ "Streak freeze"
    assert html =~ "#{r.cost_paid} pts"
  end

  test "does not show another user's redemptions", %{conn: conn} do
    buyer = user("hist_buyer")
    viewer = user("hist_viewer")
    :ok = Gamification.award(buyer.id, :article_published, "hist-seed2", 500)
    _r = redeem_streak_freeze!(buyer)

    {:ok, _view, html} = conn |> sign_in(viewer) |> live(~p"/store/history")

    refute html =~ "Streak freeze"
  end
end
```

- [ ] **Step 2: Write the goodbye test**

```elixir
defmodule VerscientaWeb.GoodbyeLiveTest do
  use VerscientaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders the deletion notice", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/goodbye")
    assert html =~ "goodbye, for now"
    assert html =~ "30 days"
  end

  test "dead render is noindex", %{conn: conn} do
    html = conn |> get(~p"/goodbye") |> html_response(200)
    assert html =~ "noindex"
  end
end
```

- [ ] **Step 3: Run both**

Run: `MIX_ENV=test mix test test/verscienta_web/live/store_history_live_test.exs test/verscienta_web/live/goodbye_live_test.exs`
Expected: 4 tests, 0 failures

If `Gamification.award/4` (with an amount) doesn't exist with that arity, mirror exactly how `test/verscienta_web/live/store_live_test.exs:25` awards points — it uses `Gamification.award(u.id, :article_published, "seed", 60)`.

- [ ] **Step 4: Format + commit**

Run: `mix format test/verscienta_web/live/store_history_live_test.exs test/verscienta_web/live/goodbye_live_test.exs`

```bash
git add test/verscienta_web/live/store_history_live_test.exs test/verscienta_web/live/goodbye_live_test.exs
git commit -m "test(web): cover store history and goodbye pages"
```

---

### Task 6: Communities.Counts tests

**Files:**
- Create: `test/verscienta/communities/counts_test.exs`
- Covers: `lib/verscienta/communities/counts.ex` (0% → 100%)

- [ ] **Step 1: Write the test file**

```elixir
defmodule Verscienta.Communities.CountsTest do
  use Verscienta.DataCase, async: false

  import Verscienta.Support.Factory, only: [user: 1]

  alias Verscienta.Communities.Counts
  alias Verscienta.Communities.{Group, GroupMembership}

  setup do
    Verscienta.Cache.flush()
    :ok
  end

  defp group!(actor, visibility) do
    Group
    |> Ash.Changeset.for_create(
      :create,
      %{name: "Cnt #{System.unique_integer([:positive])}", visibility: visibility},
      actor: actor
    )
    |> Ash.create!()
  end

  defp run!(action, args, actor) do
    GroupMembership
    |> Ash.ActionInput.for_action(action, args, actor: actor)
    |> Ash.run_action!()
  end

  test "counts active members and refreshes after a membership write" do
    owner = user("cnt_owner")
    g = group!(owner, :public)

    # owner's automatic membership
    assert Counts.group_member_count(g.id) == 1

    joiner = user("cnt_joiner")
    run!(:join, %{group_id: g.id}, joiner)

    # the join's InvalidateCounts change must bust the cached value
    assert Counts.group_member_count(g.id) == 2
  end

  test "requested memberships in a private group are not counted" do
    owner = user("cnt_p_owner")
    g = group!(owner, :private)

    requester = user("cnt_requester")
    run!(:request_join, %{group_id: g.id}, requester)

    assert Counts.group_member_count(g.id) == 1
  end
end
```

- [ ] **Step 2: Run it**

Run: `MIX_ENV=test mix test test/verscienta/communities/counts_test.exs`
Expected: 2 tests, 0 failures

If the first test fails with `2 != 1` on the second assertion's cached value, the `InvalidateCounts` change is not firing on `:join` — that is a REAL BUG (the cache spec says write paths invalidate). Report it; do not paper over it by flushing the cache in the test.

- [ ] **Step 3: Format + commit**

Run: `mix format test/verscienta/communities/counts_test.exs`

```bash
git add test/verscienta/communities/counts_test.exs
git commit -m "test(communities): cover cached group member counts + invalidation"
```

---

### Task 7: Leaderboards window math tests

**Files:**
- Create: `test/verscienta/gamification/leaderboards_window_test.exs`
- Covers: `lib/verscienta/gamification/leaderboards.ex` lines 66–77, 135 (weekly/monthly `window_bounds` + `apply_window`)

- [ ] **Step 1: Write the test file**

```elixir
defmodule Verscienta.Gamification.LeaderboardsWindowTest do
  use Verscienta.DataCase, async: false

  import Verscienta.Support.Factory, only: [user: 1]

  alias Verscienta.Gamification
  alias Verscienta.Gamification.Leaderboards
  alias Verscienta.Repo

  defp backdate!(ref, days) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE points_entries SET inserted_at = NOW() - INTERVAL '#{days} days' " <>
        "WHERE source_ref = $1",
      [ref]
    )
  end

  test "weekly window excludes entries older than this week" do
    a = user("wk_user")
    :ok = Gamification.award(a.id, :article_published, "wk-new")
    :ok = Gamification.award(a.id, :article_published, "wk-old")
    backdate!("wk-old", 10)

    assert [%{score: 50, rank: 1}] = Leaderboards.compute(:global, nil, :weekly)
  end

  test "monthly window excludes entries from prior months" do
    a = user("mo_user")
    :ok = Gamification.award(a.id, :article_published, "mo-new")
    :ok = Gamification.award(a.id, :article_published, "mo-old")
    backdate!("mo-old", 40)

    assert [%{score: 50, rank: 1}] = Leaderboards.compute(:global, nil, :monthly)
  end
end
```

- [ ] **Step 2: Run it**

Run: `MIX_ENV=test mix test test/verscienta/gamification/leaderboards_window_test.exs`
Expected: 2 tests, 0 failures

(`:article_published` awards 50 points — see `test/verscienta/gamification/leaderboards_test.exs`. The pattern match `[%{score: 50, rank: 1}]` proves the backdated entry was excluded; other committed users in the test DB can't appear because the sandbox hides other tests' rows and seeds have no points entries — if unrelated rows DO appear, filter the assertion to `Enum.filter(entries, &(&1.user_id == a.id))` and assert score 50.)

- [ ] **Step 3: Format + commit**

Run: `mix format test/verscienta/gamification/leaderboards_window_test.exs`

```bash
git add test/verscienta/gamification/leaderboards_window_test.exs
git commit -m "test(gamification): cover weekly/monthly leaderboard windows"
```

---

### Task 8: LeaderboardSnapshotWorker additions

**Files:**
- Modify: `test/verscienta/gamification/workers/leaderboard_snapshot_worker_test.exs` (append tests inside the existing module; add the `Notification` alias)
- Covers: worker lines 47–50 (default windows), 60/67/86/100–125 (closed period, prior-snapshot load, rank-up notifications), 23–27 flag gate

IMPORTANT: `:leaderboards` is already enabled in the shared test environment (the existing test relies on it). The flag-off test must use the guarded disable/restore pattern.

- [ ] **Step 1: Append these tests to the existing module**

```elixir
  test "default run (no args) always recomputes the all-time board" do
    a = user("lb_default")
    :ok = Gamification.award(a.id, :article_published, "article:lbdef")

    assert :ok = perform_job(LeaderboardSnapshotWorker, %{})

    assert [_ | _] =
             LeaderboardSnapshot
             |> Ash.Query.filter(scope == :global and window == :all_time)
             |> Ash.read!(authorize?: false)
  end

  test "weekly run notifies brand-new top-10 entrants exactly once" do
    alias Verscienta.Notifications.Notification

    a = user("lb_rankup")
    :ok = Gamification.award(a.id, :article_published, "article:lbrank")

    assert :ok = perform_job(LeaderboardSnapshotWorker, %{"window" => "weekly"})

    notifs = fn ->
      Notification
      |> Ash.Query.filter(recipient_id == ^a.id and type == :leaderboard_rank_up)
      |> Ash.read!(authorize?: false)
    end

    assert length(notifs.()) == 1

    # re-running the same period dedupes via notify_once
    assert :ok = perform_job(LeaderboardSnapshotWorker, %{"window" => "weekly"})
    assert length(notifs.()) == 1
  end

  test "flag off: perform is a no-op" do
    was = FunWithFlags.enabled?(:leaderboards)
    FunWithFlags.disable(:leaderboards)
    on_exit(fn -> if was, do: FunWithFlags.enable(:leaderboards) end)

    a = user("lb_flagoff")
    :ok = Gamification.award(a.id, :article_published, "article:lbflag")

    assert :ok = perform_job(LeaderboardSnapshotWorker, %{"window" => "all_time"})

    assert [] =
             LeaderboardSnapshot
             |> Ash.Query.filter(scope == :global)
             |> Ash.read!(authorize?: false)
  end
```

- [ ] **Step 2: Run the file**

Run: `MIX_ENV=test mix test test/verscienta/gamification/workers/leaderboard_snapshot_worker_test.exs`
Expected: 4 tests, 0 failures

If the rank-up test sees 0 notifications: check whether default notification preferences suppress `:leaderboard_rank_up` (look at `Verscienta.Notifications.notify_once/1` and the prefs check) — if prefs are the cause, set the user's prefs to allow it in the test rather than dropping the assertion.

- [ ] **Step 3: Format + commit**

Run: `mix format test/verscienta/gamification/workers/leaderboard_snapshot_worker_test.exs`

```bash
git add test/verscienta/gamification/workers/leaderboard_snapshot_worker_test.exs
git commit -m "test(gamification): cover snapshot worker windows, rank-up notify, flag gate"
```

---

### Task 9: LeaderboardLive additions

**Files:**
- Modify: `test/verscienta_web/live/leaderboard_live_test.exs` (append tests; add aliases + helper)
- Covers: `leaderboard_live.ex` lines 44–46, 50 (handle_info), 52–53, 56 (param parsing), 78 (`cat_qs/1`)

- [ ] **Step 1: Add aliases and the category-award helper to the module top**

```elixir
  alias Verscienta.Gamification.{GamificationEvent, PointsEntry}

  # A points entry plus the matching gamification event carrying the category —
  # the shape the category leaderboard join requires (same helper as
  # leaderboards_math_test.exs).
  defp award_in_category(user, category, ref, amount) do
    now = DateTime.utc_now()

    GamificationEvent
    |> Ash.Changeset.for_create(:create, %{
      user_id: user.id,
      kind: :article_published,
      ref: ref,
      subject_type: :article,
      subject_id: ref,
      metadata: %{"category" => category},
      occurred_at: now,
      local_date: DateTime.to_date(now)
    })
    |> Ash.create!(authorize?: false)

    PointsEntry
    |> Ash.Changeset.for_create(:create, %{
      user_id: user.id,
      amount: amount,
      source: :article_published,
      source_ref: ref
    })
    |> Ash.create!(authorize?: false)
  end
```

- [ ] **Step 2: Append these tests**

```elixir
  test "weekly category board parses params and refreshes on snapshot_written", %{conn: conn} do
    Verscienta.Cache.flush()
    a = user("lb_cat")
    award_in_category(a, "nutrition", "lb-cat-1", 50)

    {:ok, view, html} =
      live(conn, ~p"/leaderboard?window=weekly&scope=category&category=nutrition")

    assert html =~ "lb_cat"

    send(view.pid, {:snapshot_written, :category, "nutrition", :weekly})
    assert render(view) =~ "lb_cat"

    send(view.pid, :unrelated_message)
    assert render(view) =~ "lb_cat"
  end

  test "cat_qs/1 builds the category query fragment" do
    assert VerscientaWeb.LeaderboardLive.cat_qs(nil) == ""
    assert VerscientaWeb.LeaderboardLive.cat_qs("tcm") == "&category=tcm"
  end
```

- [ ] **Step 3: Run the file**

Run: `MIX_ENV=test mix test test/verscienta_web/live/leaderboard_live_test.exs`
Expected: 3 tests, 0 failures

- [ ] **Step 4: Format + commit**

Run: `mix format test/verscienta_web/live/leaderboard_live_test.exs`

```bash
git add test/verscienta_web/live/leaderboard_live_test.exs
git commit -m "test(web): cover leaderboard params, live refresh, cat_qs"
```

---

### Task 10: BlockRenderer additions

**Files:**
- Modify: `test/verscienta/content/block_renderer_test.exs` (append tests)
- Covers: `block_renderer.ex` lines 17, 28, 31, 61, 66, 74–79, 94–95, 100–102 (blockquote, code, unknown type, non-list input, youtube short/fallback, vimeo paths, empty caption)

Note: the fallback-branch tests call `BlockRenderer.to_html/1` directly with raw maps (bypassing `Block.cast_all/1`) because the cast step may infer/normalize the provider; `to_html`'s contract is "already-cast blocks", so raw maps in the cast shape are valid input.

- [ ] **Step 1: Append these tests**

```elixir
  test "blockquote and code blocks render with escaping" do
    html =
      render([
        %{"type" => "blockquote", "data" => %{"text" => "wise words"}},
        %{"type" => "code", "data" => %{"text" => "x = <1>"}}
      ])

    assert html =~ "<blockquote>wise words</blockquote>"
    assert html =~ "<pre><code>x = &lt;1&gt;</code></pre>"
  end

  test "unknown block type and non-list input render to empty string" do
    assert BlockRenderer.to_html([%{"type" => "wat", "data" => %{}}]) == ""
    assert BlockRenderer.to_html(nil) == ""
  end

  test "youtu.be short links embed; unparseable youtube urls degrade to a link" do
    short =
      BlockRenderer.to_html([
        %{
          "type" => "embed",
          "data" => %{"url" => "https://youtu.be/abc123x", "provider" => "youtube"}
        }
      ])

    assert short =~ "youtube.com/embed/abc123x"

    bad =
      BlockRenderer.to_html([
        %{
          "type" => "embed",
          "data" => %{"url" => "https://www.youtube.com/playlist?list=1", "provider" => "youtube"}
        }
      ])

    assert bad =~ "<a "
    refute bad =~ "<iframe"
  end

  test "vimeo embeds by id; unparseable vimeo urls degrade to a link" do
    v =
      BlockRenderer.to_html([
        %{
          "type" => "embed",
          "data" => %{"url" => "https://vimeo.com/123456", "provider" => "vimeo"}
        }
      ])

    assert v =~ "player.vimeo.com/video/123456"

    bad =
      BlockRenderer.to_html([
        %{
          "type" => "embed",
          "data" => %{"url" => "https://vimeo.com/about", "provider" => "vimeo"}
        }
      ])

    assert bad =~ "<a "
    refute bad =~ "<iframe"
  end

  test "image with empty caption omits the figcaption" do
    html =
      BlockRenderer.to_html([
        %{
          "type" => "image",
          "data" => %{"url" => "https://x/y.png", "alt" => "", "caption" => ""}
        }
      ])

    refute html =~ "figcaption"
  end
```

- [ ] **Step 2: Run the file**

Run: `MIX_ENV=test mix test test/verscienta/content/block_renderer_test.exs`
Expected: 16 tests, 0 failures

- [ ] **Step 3: Format + commit**

Run: `mix format test/verscienta/content/block_renderer_test.exs`

```bash
git add test/verscienta/content/block_renderer_test.exs
git commit -m "test(content): cover BlockRenderer embed fallbacks and edge branches"
```

---

### Task 11: NotificationBellLive additions

**Files:**
- Modify: `test/verscienta_web/live/notification_bell_test.exs` (append tests)
- Covers: `notification_bell_live.ex` lines 15 (anonymous mount), 18–19, 22–23, 27 (handle_info branches)

The badge `<span>` only renders when `@count > 0` and carries the class `min-w-4` — assert on that class for visibility.

- [ ] **Step 1: Append these tests**

```elixir
  test "anonymous bell mounts with zero and survives read events", %{conn: conn} do
    {:ok, view, html} =
      live_isolated(conn, VerscientaWeb.NotificationBellLive, session: %{})

    refute html =~ "min-w-4"

    send(view.pid, {:notifications_read})
    refute render(view) =~ "min-w-4"
  end

  test "bell increments on :notification and recounts on :notifications_read", %{conn: conn} do
    me = user("bell_events")

    {:ok, view, html} =
      live_isolated(conn, VerscientaWeb.NotificationBellLive,
        session: %{"user_id" => to_string(me.id)}
      )

    refute html =~ "min-w-4"

    send(view.pid, {:notification, "n1"})
    assert render(view) =~ "min-w-4"

    # the DB still has zero unread, so a read event resets the badge
    send(view.pid, {:notifications_read})
    refute render(view) =~ "min-w-4"

    send(view.pid, :junk)
    refute render(view) =~ "min-w-4"
  end
```

- [ ] **Step 2: Run the file**

Run: `MIX_ENV=test mix test test/verscienta_web/live/notification_bell_test.exs`
Expected: 4 tests, 0 failures

- [ ] **Step 3: Format + commit**

Run: `mix format test/verscienta_web/live/notification_bell_test.exs`

```bash
git add test/verscienta_web/live/notification_bell_test.exs
git commit -m "test(web): cover notification bell anonymous mount and live events"
```

---

### Task 12: Coverage hygiene in mix.exs

**Files:**
- Modify: `mix.exs` (the `project/0` keyword list, after `dialyzer:`)

- [ ] **Step 1: Add the test_coverage config**

In `mix.exs` `project/0`, after the `dialyzer: [...]` entry, add:

```elixir
      test_coverage: [
        ignore_modules: [
          # Ash-generated Inspect protocol impls
          ~r/^Inspect\./,
          # seed/backfill/reindex mix tasks (NOT AiBackfill — it has tests)
          Mix.Tasks.Verscienta.Embeddings.Backfill,
          Mix.Tasks.Verscienta.Flags.Seed,
          Mix.Tasks.Verscienta.Gamification.Backfill,
          Mix.Tasks.Verscienta.Gamification.Seed,
          Mix.Tasks.Verscienta.Reindex,
          # load-test harness (exercised manually, see docs/load-testing.md)
          ~r/^Mix\.Tasks\.Verscienta\.LoadTest\./,
          ~r/^Verscienta\.LoadTest\./,
          # real HTTP clients, replaced by stubs in test by design
          # (NOT Analytics.Client.Req — it has client_req_test.exs)
          Verscienta.AI.Client.Req,
          Verscienta.Aggregation.FeedClient.Req,
          Verscienta.Search.Client.Req,
          # static scaffolding
          VerscientaWeb.StyleguideHTML,
          VerscientaWeb.PageHTML,
          VerscientaWeb.AuthOverrides
        ],
        summary: [threshold: 80]
      ]
```

- [ ] **Step 2: Run the full suite with coverage**

Run: `MIX_ENV=test mix test --cover`
Expected: ~950 tests, 0 failures; a coverage summary table; total noticeably above 78.11% (expected ≈84–87% after the ignore list + new tests).

- [ ] **Step 3: Set the real threshold**

Take the printed total, round DOWN to the nearest whole percent, and replace `threshold: 80` with that number (e.g. total `85.7%` → `threshold: 85`). Re-run:

Run: `MIX_ENV=test mix test --cover`
Expected: 0 failures and `Coverage test passed` (no threshold error).

- [ ] **Step 4: Format + commit**

Run: `mix format mix.exs`

```bash
git add mix.exs
git commit -m "chore(coverage): ignore generated/manual modules, enforce threshold"
```

---

### Task 13: CI enforces coverage

**Files:**
- Modify: `.github/workflows/ci.yml:58`

- [ ] **Step 1: Change the test step**

```yaml
      - run: mix test --cover
```

(replacing `- run: mix test`)

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: run mix test --cover to enforce the coverage threshold"
```

---

### Task 14: Final verification + todo check-off

**Files:**
- Modify: `docs/todo.md:188`

- [ ] **Step 1: Full verification loop**

Run: `mix format --check-formatted`
Expected: exit 0

Run: `mix credo --strict`
Expected: no issues

Run: `MIX_ENV=test mix test --cover`
Expected: 0 failures, coverage threshold passed

- [ ] **Step 2: Check off the todo item**

In `docs/todo.md`, change:

```markdown
- [ ] Expand test coverage (social flows, gamification math, uploads).
```

to (substitute the real numbers from Task 12):

```markdown
- [x] Expand test coverage (social flows, gamification math, uploads). *(coverage-driven 2026-06-10: referral web flow e2e, AuthController, store history/goodbye, group member counts, leaderboard windows/worker/live, BlockRenderer embeds, notification bell; mix.exs ignore_modules + threshold NN%; CI runs `mix test --cover`; total 78%→NN%)*
```

- [ ] **Step 3: Commit**

```bash
git add docs/todo.md
git commit -m "docs(todo): check off test-coverage expansion"
```

---

## Out of scope (per spec)

- Admin flag pages / `FlagComponents` (stretch, skipped — not cheap)
- Property-based tests (separate Phase 4 item)
- Redis integration tests (`Cache.Redis` disabled in test env by design)
- `CoreComponents` render tests (low value per test)
