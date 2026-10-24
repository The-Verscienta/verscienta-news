# Onboarding Flow Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `/welcome` interest picker entered at registration — pick wellness categories → category follows → land on the seeded For You feed; closes the recommender cold-start loop.

**Architecture:** `User.onboarded_at` + `:complete_onboarding` action mark completion. `AuthController.success/4` redirects new registrations to `/welcome`. `OnboardingLive` shows the 8-category grid, creates category follows via the existing `Social` toggle, completes onboarding, fires an analytics event, and navigates to `/articles?feed=for_you`.

**Tech Stack:** Elixir, Ash 3, Phoenix LiveView, `Verscienta.Social`, `Verscienta.Analytics`, `Content.Category`. All `mix` runs in Docker: `docker compose exec -T app mix …`.

**Spec:** `docs/superpowers/specs/2026-06-05-onboarding-design.md`
**Branch:** `phase-3-onboarding` (spec already committed here).

**Confirmed facts:**
- `AuthController.success/4` (`lib/verscienta_web/controllers/auth_controller.ex`) redirects to `get_session(conn, :return_to) || ~p"/"`; the register activity is `{:password, :register}`.
- `/articles?feed=for_you` is the For You tab (logged-in default; `article_feed_live.ex` `@tabs ~w(for_you following trending latest)`).
- Self-update policy pattern: `authorize_if expr(id == ^actor(:id))` (mirror for `:complete_onboarding`).
- Category follows: `Ash.ActionInput.for_action(:toggle, %{target_type: :category, target_id: to_string(key)}, actor:)` (per `CategoryLive`). `Content.Category` exposes `all/0` (`%{key, label, slug, accent}`) + `keys/0`.
- Sign-in in tests: `conn |> Plug.Test.init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)`.

---

## File Structure

**Create:**
- `lib/verscienta_web/live/onboarding_live.ex`, `test/verscienta_web/live/onboarding_live_test.exs`.
- a migration for `onboarded_at`.
- `test/verscienta/accounts/user_onboarding_test.exs`, `test/verscienta_web/controllers/auth_controller_test.exs`.

**Modify:**
- `lib/verscienta/accounts/user.ex` (attr + action + policy).
- `lib/verscienta_web/controllers/auth_controller.ex` (register redirect).
- `lib/verscienta_web/router.ex` (route).
- `docs/todo.md`.

---

## Task 1: `User.onboarded_at` + `:complete_onboarding`

**Files:** modify `lib/verscienta/accounts/user.ex`; create a migration + `test/verscienta/accounts/user_onboarding_test.exs`.

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/accounts/user_onboarding_test.exs`:
```elixir
defmodule Verscienta.Accounts.UserOnboardingTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Accounts.User

  defp user(name) do
    User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com", username: name,
      password: "password123", password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  test "new users start with nil onboarded_at" do
    assert user("freshuser").onboarded_at == nil
  end

  test "complete_onboarding sets onboarded_at (self-authorized)" do
    u = user("onboarder")
    {:ok, done} = u |> Ash.Changeset.for_update(:complete_onboarding, %{}, actor: u) |> Ash.update()
    assert %DateTime{} = done.onboarded_at
  end
end
```

- [ ] **Step 2: Run it (fails — no attr/action)**

`docker compose exec -T app mix test test/verscienta/accounts/user_onboarding_test.exs` → FAIL.

- [ ] **Step 3: Implement**

In `lib/verscienta/accounts/user.ex`:

(a) attribute (in `attributes do`, near the other optional fields):
```elixir
    attribute :onboarded_at, :utc_datetime_usec, allow_nil?: true, public?: true
```

(b) action (in `actions do`, near `:update_profile`):
```elixir
    update :complete_onboarding do
      description "Marks the user's onboarding as complete."
      accept []
      require_atomic? false

      change fn changeset, _ctx ->
        Ash.Changeset.force_change_attribute(changeset, :onboarded_at, DateTime.utc_now())
      end
    end
```

(c) policy (in `policies do`, next to `:update_profile`):
```elixir
    policy action(:complete_onboarding) do
      authorize_if expr(id == ^actor(:id))
    end
```

(d) migration:
```bash
docker compose exec -T app mix ash.codegen add_user_onboarded_at
docker compose exec -T app mix ash.migrate
```
Confirm a migration adding the nullable `onboarded_at` column was generated.

- [ ] **Step 4: Run the test (passes)**

`docker compose exec -T app mix test test/verscienta/accounts/user_onboarding_test.exs` → PASS.

- [ ] **Step 5: format, warnings, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix compile --force --warnings-as-errors 2>&1 | tail -4
docker compose exec -T app mix credo --strict lib/verscienta/accounts/user.ex 2>&1 | tail -4
git add lib/verscienta/accounts/user.ex priv/repo/migrations test/verscienta/accounts/user_onboarding_test.exs
git commit -m "feat(onboarding): User.onboarded_at + complete_onboarding action"
```

---

## Task 2: AuthController register → /welcome

**Files:** modify `lib/verscienta_web/controllers/auth_controller.ex`; create `test/verscienta_web/controllers/auth_controller_test.exs`.

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/controllers/auth_controller_test.exs` (tests the pure redirect-target decision in isolation — avoids the full AshAuthentication HTTP flow):
```elixir
defmodule VerscientaWeb.AuthControllerTest do
  use ExUnit.Case, async: true

  alias VerscientaWeb.AuthController

  test "new registrations route to /welcome" do
    assert AuthController.post_auth_path({:password, :register}, "/somewhere") == "/welcome"
  end

  test "sign-in and other activities use return_to" do
    assert AuthController.post_auth_path({:password, :sign_in}, "/dashboard") == "/dashboard"
    assert AuthController.post_auth_path({:confirm_new_user, :confirm}, "/x") == "/x"
    assert AuthController.post_auth_path(:anything, "/y") == "/y"
  end
end
```

- [ ] **Step 2: Run it (fails — no post_auth_path/2)**

`docker compose exec -T app mix test test/verscienta_web/controllers/auth_controller_test.exs` → FAIL.

- [ ] **Step 3: Implement**

In `lib/verscienta_web/controllers/auth_controller.ex`:

(a) extract the redirect decision into a public (testable) function:
```elixir
  @doc false
  def post_auth_path({:password, :register}, _return_to), do: ~p"/welcome"
  def post_auth_path(_activity, return_to), do: return_to
```

(b) change `success/4`'s final redirect to use it (keep all the existing session/token/referral/flash plumbing unchanged — only swap the redirect target):
```elixir
    |> redirect(to: post_auth_path(activity, return_to))
```
(`return_to` is the existing `get_session(conn, :return_to) || ~p"/"`.)

- [ ] **Step 4: Run the test (passes) + auth regression**

```bash
docker compose exec -T app mix test test/verscienta_web/controllers/auth_controller_test.exs 2>&1 | tail -4
docker compose exec -T app mix test test/verscienta_web/auth_nav_test.exs 2>&1 | tail -4
```
Expected: PASS (no auth-nav regression).

- [ ] **Step 5: format, warnings, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix compile --force --warnings-as-errors 2>&1 | tail -4
docker compose exec -T app mix credo --strict lib/verscienta_web/controllers/auth_controller.ex 2>&1 | tail -4
git add lib/verscienta_web/controllers/auth_controller.ex test/verscienta_web/controllers/auth_controller_test.exs
git commit -m "feat(onboarding): route new registrations to /welcome"
```

---

## Task 3: `OnboardingLive` at `/welcome`

**Files:** create `lib/verscienta_web/live/onboarding_live.ex`, `test/verscienta_web/live/onboarding_live_test.exs`; modify `lib/verscienta_web/router.ex`.

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/onboarding_live_test.exs`:
```elixir
defmodule VerscientaWeb.OnboardingLiveTest do
  use VerscientaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias AshAuthentication.Plug.Helpers
  alias Verscienta.Social

  defp user(name) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com", username: name,
      password: "password123", password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp sign_in(conn, u), do: conn |> Plug.Test.init_test_session(%{}) |> Helpers.store_in_session(u)

  defp reload(u), do: Ash.get!(Verscienta.Accounts.User, u.id, authorize?: false)

  test "a fresh user sees the category picker", %{conn: conn} do
    me = user("welcome1")
    {:ok, _lv, html} = conn |> sign_in(me) |> live(~p"/welcome")
    assert html =~ "Nutrition"
    assert html =~ "Herbalism"
    assert html =~ "skip"
  end

  test "selecting categories + continue creates follows, completes, redirects to For You", %{conn: conn} do
    me = user("welcome2")
    {:ok, lv, _html} = conn |> sign_in(me) |> live(~p"/welcome")

    lv |> element(~s(button[phx-value-key="nutrition"])) |> render_click()
    lv |> element(~s(button[phx-value-key="herbalism"])) |> render_click()

    Application.put_env(:verscienta, :analytics_test_pid, self())
    on_exit(fn -> Application.delete_env(:verscienta, :analytics_test_pid) end)

    lv |> element(~s(button[phx-click="continue"])) |> render_click()

    assert_redirect(lv, ~p"/articles?feed=for_you")
    assert Social.following?(reload(me), :category, "nutrition")
    assert Social.following?(reload(me), :category, "herbalism")
    refute Social.following?(reload(me), :category, "movement")
    assert reload(me).onboarded_at != nil
    assert_receive {:analytics, {:capture, "onboarding_completed", _id, %{"category_count" => 2}}}
  end

  test "skip completes onboarding with no follows", %{conn: conn} do
    me = user("welcome3")
    {:ok, lv, _html} = conn |> sign_in(me) |> live(~p"/welcome")
    lv |> element(~s(a[phx-click="skip"], button[phx-click="skip"])) |> render_click()
    assert_redirect(lv, ~p"/articles")
    assert reload(me).onboarded_at != nil
    refute Social.following?(reload(me), :category, "nutrition")
  end

  test "an already-onboarded user is redirected away from /welcome", %{conn: conn} do
    me = user("welcome4")
    {:ok, _} = me |> Ash.Changeset.for_update(:complete_onboarding, %{}, actor: me) |> Ash.update()
    assert {:error, {:live_redirect, %{to: "/articles" <> _}}} = conn |> sign_in(me) |> live(~p"/welcome")
  end
end
```
(Adjust the skip selector to whatever element you render — keep one stable `phx-click="skip"` target.)

- [ ] **Step 2: Run it (fails — no LiveView/route)**

`docker compose exec -T app mix test test/verscienta_web/live/onboarding_live_test.exs` → FAIL.

- [ ] **Step 3: Implement**

(a) Create `lib/verscienta_web/live/onboarding_live.ex`:
```elixir
defmodule VerscientaWeb.OnboardingLive do
  @moduledoc "First-run interest picker at /welcome — seeds the For You feed via category follows."
  use VerscientaWeb, :live_view

  alias Verscienta.Analytics
  alias Verscienta.Content.Category
  alias Verscienta.Social

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if user && user.onboarded_at do
      {:ok, push_navigate(socket, to: ~p"/articles")}
    else
      {:ok,
       assign(socket,
         page_title: "welcome",
         seo: VerscientaWeb.SEO.build(noindex: true),
         categories: Category.all(),
         selected: MapSet.new()
       )}
    end
  end

  @impl true
  def handle_event("toggle_category", %{"key" => key}, socket) do
    case safe_key(key) do
      nil -> {:noreply, socket}
      atom -> {:noreply, update(socket, :selected, &toggle(&1, atom))}
    end
  end

  def handle_event("continue", _params, socket) do
    user = socket.assigns.current_user
    selected = socket.assigns.selected

    Enum.each(selected, fn key -> follow_category(user, key) end)
    complete(user)
    Analytics.capture("onboarding_completed", to_string(user.id), %{
      "category_count" => MapSet.size(selected)
    })

    {:noreply, push_navigate(socket, to: ~p"/articles?feed=for_you")}
  end

  def handle_event("skip", _params, socket) do
    user = socket.assigns.current_user
    complete(user)
    Analytics.capture("onboarding_completed", to_string(user.id), %{"category_count" => 0})
    {:noreply, push_navigate(socket, to: ~p"/articles")}
  end

  defp toggle(set, atom) do
    if MapSet.member?(set, atom), do: MapSet.delete(set, atom), else: MapSet.put(set, atom)
  end

  defp safe_key(key) do
    atom = String.to_existing_atom(key)
    if atom in Category.keys(), do: atom, else: nil
  rescue
    ArgumentError -> nil
  end

  defp follow_category(user, key) do
    Verscienta.Social.Follow
    |> Ash.ActionInput.for_action(:toggle, %{target_type: :category, target_id: to_string(key)}, actor: user)
    |> Ash.run_action!()
  end

  defp complete(user) do
    user
    |> Ash.Changeset.for_update(:complete_onboarding, %{}, actor: user)
    |> Ash.update!()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-6 pb-24 pt-28">
      <.kicker>welcome</.kicker>
      <.headline class="mb-3 text-5xl">what are you into?</.headline>
      <p class="mb-8 text-ink-3">Pick a few topics to personalize your feed. You can change these anytime.</p>

      <div class="mb-10 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <button
          :for={cat <- @categories}
          type="button"
          phx-click="toggle_category"
          phx-value-key={cat.key}
          aria-pressed={to_string(MapSet.member?(@selected, cat.key))}
          class={[
            "border px-4 py-5 text-left text-sm uppercase tracking-wider transition-colors",
            if(MapSet.member?(@selected, cat.key),
              do: "border-zune bg-canvas-2 text-zune",
              else: "border-line text-ink-3 hover:text-ink"
            )
          ]}
        >
          {cat.label}
        </button>
      </div>

      <div class="flex items-center gap-6">
        <button
          type="button"
          phx-click="continue"
          disabled={MapSet.size(@selected) == 0}
          class="bg-zune px-6 py-3 text-sm font-semibold uppercase tracking-wider text-canvas disabled:opacity-40"
        >
          continue{if MapSet.size(@selected) > 0, do: " (#{MapSet.size(@selected)})", else: ""}
        </button>
        <button type="button" phx-click="skip" class="text-sm text-ink-3 hover:text-ink">
          skip for now
        </button>
      </div>
    </div>
    """
  end
end
```
(Reuse `<.kicker>`/`<.headline>` from `CodexComponents` if they're auto-imported in `:live_view`; if not, drop them for plain markup. Match the design system's classes — the exact Tailwind tokens above follow the search/category pages' style; adjust to real token names if any differ.)

(b) In `lib/verscienta_web/router.ex`, add the route inside the `ash_authentication_live_session :authenticated_routes` block (next to `/settings`):
```elixir
      live "/welcome", OnboardingLive, :index
```

- [ ] **Step 4: Run the test (passes)**

`docker compose exec -T app mix test test/verscienta_web/live/onboarding_live_test.exs 2>&1 | tail -6`
Expected: PASS. If the `continue` button's `disabled` prevents `render_click` in the test, ensure the two categories are toggled first (they are) so it's enabled. If `assert_redirect` needs the exact query string, match `~p"/articles?feed=for_you"`.

- [ ] **Step 5: format, warnings, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix compile --force --warnings-as-errors 2>&1 | tail -4
docker compose exec -T app mix credo --strict lib/verscienta_web/live/onboarding_live.ex 2>&1 | tail -4
git add lib/verscienta_web/live/onboarding_live.ex lib/verscienta_web/router.ex test/verscienta_web/live/onboarding_live_test.exs
git commit -m "feat(onboarding): OnboardingLive /welcome category picker (follows + complete + For You redirect)"
```

---

## Task 4: Docs + full verification

**Files:** modify `docs/todo.md`.

- [ ] **Step 1: Check off the todo**

In `docs/todo.md` under "### Growth", change:
`- [ ] Onboarding flow (interest selection seeds the For You feed).`
to:
`- [x] Onboarding flow (interest selection seeds the For You feed). *(/welcome category picker at registration → category follows → For You; onboarded_at; Growth slice 4)*`

- [ ] **Step 2: Full suite + format**

```bash
docker compose exec -T app bash -lc 'mix format && mix format --check-formatted && mix test 2>&1 | tail -6'
```
Expected: format clean; 0 failures. (Known flake: `NotificationBellTest`; if it's the only failure, re-run once.)

- [ ] **Step 3: Warnings + Credo + Dialyzer**

```bash
docker compose exec -T app mix compile --force --warnings-as-errors 2>&1 | tail -4
docker compose exec -T app mix credo --strict 2>&1 | tail -4
docker compose exec -T app mix dialyzer 2>&1 | tail -8
```
Expected: compile no warnings; credo "found no issues"; dialyzer "passed successfully". If dialyzer reports NEW errors, paste them; do NOT commit on red.

- [ ] **Step 4: Commit**

```bash
git add docs/todo.md
git commit -m "docs: check off onboarding flow (Growth slice 4)"
```

- [ ] **Step 5:** Confirm all gates green — branch ready to merge. (This completes the Growth subsystem.)

---

## Notes for the implementer

- `OnboardingLive` is in `:authenticated_routes`, so `current_user` is always present; the `user && user.onboarded_at` mount guard redirects returning/onboarded users away (no picker, no loop — `/welcome` is the only route with this guard).
- Category follows reuse the EXACT call `CategoryLive` uses (`:toggle` with `target_type: :category, target_id: to_string(key)`), so they populate `AffinityProfile.followed_categories` and For You/personalized-search light up immediately.
- `safe_key/1` validates `phx-value-key` against `Category.keys()` so a tampered value can't crash or create a bogus follow.
- The `continue` button is `disabled` at 0 selections (skip is the 0 path); both `continue` and `skip` call `complete/1` so the user is never re-prompted.
- `post_auth_path/2` is extracted public + `@doc false` purely so the register→`/welcome` decision is unit-testable without driving the full AshAuthentication HTTP flow; `success/4` keeps all its existing plumbing.
- The analytics call is fire-and-forget (slice 3) — it never blocks the redirect; in tests the pid-stub captures it.
- `/welcome` gets `noindex` via the slice-1 `SEO.build(noindex: true)` (private first-run flow).
