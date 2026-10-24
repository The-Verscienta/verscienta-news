# Auth & Profiles Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make AshAuthentication functional (email+password, confirmation, reset) and add lean user profiles with roles, public `/@:username` pages, and a `/settings` editor.

**Architecture:** Flesh out the existing `Verscienta.Accounts.User` Ash resource using AshAuthentication's official generators for strategy wiring, then layer profile attributes, authorization policies, and Codex-styled LiveViews on top. Keep the already-routed built-in auth LiveViews, themed via daisyUI dark + `AuthOverrides`.

**Tech Stack:** Phoenix 1.8, Ash 3, AshAuthentication 4 (+ AshAuthentication.Phoenix), AshPostgres, bcrypt_elixir, Swoosh (local adapter, `/dev/mailbox`), LiveView, Tailwind v4 + daisyUI, CodexComponents.

---

## Conventions for the executor

- **Run everything in Docker.** Mix commands run inside the app service:
  `docker compose run --rm app bash -lc "<cmd>"`. The `db` service must be up for DB/test commands: `docker compose up -d db` first; `docker compose down` when finished with a server.
- **Memory note:** compiling the full Ash tree from a cold `_build` can OOM. If a combined command is killed (exit 137), split it into separate `docker compose run` calls and/or prefix with `ERL_FLAGS="+S 2 +A 4"`.
- **Branch:** work on `phase-1-auth-profiles` (already checked out; the spec is committed there).
- **Git identity:** do NOT set a local override. Commit message body ends with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- **Migrations:** generate with `mix ash.codegen <name>` (Ash owns the schema); never hand-write migrations.
- **TDD note:** Ash resource/strategy wiring is largely generator-driven; those tasks gate on *compile + generated actions exist + migration applies*. Behavioral tasks (policies, profile update, LiveViews) are genuine TDD — write the failing test first.
- After each task: `mix format`, then commit.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `lib/verscienta/accounts/user.ex` | User resource: strategies, attributes, actions, policies |
| `lib/verscienta/accounts/user/senders/*.ex` | Confirmation + reset email senders (generated, then customized) |
| `lib/verscienta/accounts/emails.ex` | Builds the Swoosh emails (generated/customized) |
| `lib/verscienta_web/components/layouts/root.html.heex` | Auth-aware top strip nav |
| `lib/verscienta_web/live/profile_live.ex` | Public profile at `/@:username` |
| `lib/verscienta_web/live/settings_live.ex` | Profile editor at `/settings` |
| `lib/verscienta_web/auth_overrides.ex` | Codex theming of built-in auth UI |
| `lib/verscienta_web/router.ex` | Remove magic-link; add `/@:username`, `/settings` |
| `config/config.exs` | daisyUI dark default theme |
| `priv/repo/seeds.exs` | A confirmed admin user for dev |
| `test/verscienta/accounts_test.exs` | Domain tests (auth + profile + authz) |
| `test/verscienta_web/live/profile_live_test.exs` | Public profile tests |
| `test/verscienta_web/live/settings_live_test.exs` | Settings editor tests |
| `test/verscienta_web/auth_nav_test.exs` | Auth-aware nav tests |

---

## Task 1: Password strategy (email + password + reset)

Use the official generator — it adds the `email`/`hashed_password` attributes, the `password` strategy with `resettable`, `register_with_password`/`sign_in_with_password`/reset actions, the reset sender, the `unique_email` identity, and the `bcrypt_elixir` dep.

**Files:**
- Modify (by generator): `lib/verscienta/accounts/user.ex`, `mix.exs`, `lib/verscienta/accounts/user/senders/*`, possibly `lib/verscienta/accounts/emails.ex`
- Create (by codegen): a migration under `priv/repo/migrations/`

- [ ] **Step 1: Run the password strategy generator**

```powershell
docker compose run --rm app bash -lc "mix ash_authentication.add_strategy password --yes"
```
Expected: the task edits `user.ex` (adds `password` strategy, `email`/`hashed_password` attributes, register/sign-in/reset actions, `unique_email` identity), adds `bcrypt_elixir` to `mix.exs`, creates sender module(s), and prints next steps. If it reports it already added something, that's fine.

- [ ] **Step 2: Fetch deps and compile**

```powershell
docker compose run --rm app bash -lc "mix deps.get && mix compile"
```
Expected: compiles (warnings ok). `bcrypt_elixir` is fetched.

- [ ] **Step 3: Confirm the expected actions now exist**

```powershell
docker compose run --rm app bash -lc "mix run -e 'IO.inspect(Ash.Resource.Info.actions(Verscienta.Accounts.User) |> Enum.map(& &1.name))'"
```
Expected: the printed list includes `:register_with_password`, `:sign_in_with_password`, and a reset action (e.g. `:request_password_reset` and `:reset_password` / `:password_reset_with_password` — names vary by version; note the exact names you see, they're used in later tasks/tests).

- [ ] **Step 4: Generate and apply the migration**

```powershell
docker compose up -d db
docker compose run --rm app bash -lc "mix ash.codegen add_password_strategy && mix ash.migrate"
```
Expected: a migration adding `email` (citext/unique) and `hashed_password` to `users`; migration applies cleanly.

- [ ] **Step 5: Format and commit**

```powershell
docker compose run --rm app bash -lc "mix format"
git add -A
git commit -m "feat(auth): add email+password strategy with reset"
```
(Append the Co-Authored-By trailer.)

---

## Task 2: Profile attributes, username identity & roles

Add the lean profile fields and role enum. Username is **required at registration** (social site).

**Files:**
- Modify: `lib/verscienta/accounts/user.ex`
- Create (by codegen): migration

- [ ] **Step 1: Add the profile attributes**

In `lib/verscienta/accounts/user.ex`, inside the `attributes do … end` block (which after Task 1 has `id`, `email`, `hashed_password`), add:
```elixir
    attribute :username, :ci_string do
      allow_nil? false
      public? true
      constraints match: ~r/^[a-z0-9_]{3,30}$/
    end

    attribute :display_name, :string, allow_nil?: true, public?: true
    attribute :bio, :string, allow_nil?: true, public?: true, constraints: [max_length: 500]
    attribute :avatar_url, :string, allow_nil?: true, public?: true

    attribute :role, :atom do
      allow_nil? false
      public? true
      default :user
      constraints one_of: [:user, :expert, :moderator, :admin]
      writable? false
    end

    attribute :confirmed_at, :utc_datetime_usec, allow_nil?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
```
(`role` is `writable? false` so it can never be set through any action's `accept`; seeds/console set it via `Ash.Changeset.force_change_attribute/3`.)

- [ ] **Step 2: Add the username identity**

In the `identities do … end` block (created by Task 1 with `identity :unique_email, [:email]`), add:
```elixir
    identity :unique_username, [:username]
```
If there is no `identities` block yet, add one inside the resource:
```elixir
  identities do
    identity :unique_email, [:email]
    identity :unique_username, [:username]
  end
```

- [ ] **Step 3: Accept `username` during registration**

The password strategy generated a `register_with_password` action. Make it accept `username`. Find the `register_with_password` action; if it uses an explicit `accept [...]`, add `:username`. If the strategy defines registration via the DSL without a visible action body, add an override action accepting username. The reliable approach: in the `authentication do … strategies do password :password do … end end` block, set:
```elixir
        register_action_accept [:username]
```
(Place `register_action_accept [:username]` inside the `password :password do … end` strategy block.) This adds `username` to the generated registration action's accepted inputs.

- [ ] **Step 4: Compile**

```powershell
docker compose run --rm app bash -lc "mix compile"
```
Expected: compiles. If `register_action_accept` is rejected by this version, instead add `:username` to the explicit `accept` list of the `register_with_password` action and report the substitution.

- [ ] **Step 5: Generate and apply the migration**

```powershell
docker compose up -d db
docker compose run --rm app bash -lc "mix ash.codegen add_user_profile_fields && mix ash.migrate"
```
Expected: migration adds `username` (citext, unique index), `display_name`, `bio`, `avatar_url`, `role`, `confirmed_at`, timestamps; applies cleanly.

- [ ] **Step 6: Format and commit**

```powershell
docker compose run --rm app bash -lc "mix format"
git add -A
git commit -m "feat(auth): add profile fields, username identity, and role enum"
```

---

## Task 3: Email confirmation add-on

Add the confirmation add-on so new users confirm via email. The router's `confirm_route` references the action name `:confirm_new_user`.

**Files:**
- Modify: `lib/verscienta/accounts/user.ex`
- Create (by codegen): migration (confirmation stores no new column by default, but codegen ensures snapshot parity)

- [ ] **Step 1: Add the confirmation add-on**

In `lib/verscienta/accounts/user.ex`, inside `authentication do … add_ons do … end end` (which currently has `log_out_everywhere`), add a confirmation add-on:
```elixir
      confirmation :confirm_new_user do
        monitor_fields [:email]
        confirm_on_create? true
        confirm_on_update? false
        confirmed_at_field :confirmed_at
        sender Verscienta.Accounts.User.Senders.SendConfirmationEmail
      end
```

- [ ] **Step 2: Create the confirmation sender**

Create `lib/verscienta/accounts/user/senders/send_confirmation_email.ex`:
```elixir
defmodule Verscienta.Accounts.User.Senders.SendConfirmationEmail do
  @moduledoc "Sends the account confirmation email."
  use AshAuthentication.Sender
  use VerscientaWeb, :verified_routes

  @impl true
  def send(user, token, _opts) do
    Verscienta.Accounts.Emails.send_confirmation_email(user, token)
  end
end
```

- [ ] **Step 3: Add the email builder**

Create (or extend) `lib/verscienta/accounts/emails.ex`. If Task 1's generator already created this module with a reset function, ADD the confirmation function alongside it rather than overwriting. Full module if it does not exist:
```elixir
defmodule Verscienta.Accounts.Emails do
  @moduledoc "Builds and delivers account-related emails."
  import Swoosh.Email

  def send_confirmation_email(user, token) do
    deliver(user, "Confirm your Verscienta News account", """
    Welcome to Verscienta News!

    Confirm your account by visiting the link below:

    #{url(~p"/auth/user/confirm_new_user?#{[confirm: token]}")}
    """)
  end

  def send_password_reset_email(user, token) do
    deliver(user, "Reset your Verscienta News password", """
    Reset your password by visiting the link below:

    #{url(~p"/password-reset/#{token}")}
    """)
  end

  defp url(path), do: VerscientaWeb.Endpoint.url() <> path

  defp deliver(user, subject, body) do
    new()
    |> to(to_string(user.email))
    |> from({"Verscienta News", "noreply@verscienta.news"})
    |> subject(subject)
    |> text_body(body)
    |> Verscienta.Mailer.deliver()
  end
end
```
NOTE: the exact reset/confirm URL paths depend on the router macros. After writing, verify the real paths in Step 5 and correct the `~p` paths if needed. If Task 1 already generated a working reset email, KEEP its reset path and only add `send_confirmation_email/2` (mirroring its style); do not duplicate `send_password_reset_email`.

- [ ] **Step 4: Compile**

```powershell
docker compose run --rm app bash -lc "mix compile"
```
Expected: compiles. If `url(~p"...")` raises a verified-route error, the path doesn't exist — list routes (next step) and fix.

- [ ] **Step 5: Verify the confirm/reset route paths**

```powershell
docker compose run --rm app bash -lc "mix phx.routes | grep -iE 'confirm|reset|password'"
```
Expected: shows the confirmation route (matching `/auth/user/confirm_new_user`) and the reset route. Correct the `~p` paths in `emails.ex` to match the actual routes shown, then recompile.

- [ ] **Step 6: Codegen + migrate (snapshot parity)**

```powershell
docker compose up -d db
docker compose run --rm app bash -lc "mix ash.codegen add_confirmation || true; mix ash.migrate"
```
Expected: either a no-op ("No changes") or a small migration; migrate succeeds.

- [ ] **Step 7: Format and commit**

```powershell
docker compose run --rm app bash -lc "mix format"
git add -A
git commit -m "feat(auth): add email confirmation add-on and senders"
```

---

## Task 4: Verify the full email round-trip in dev

No code unless a path is wrong — this is a behavioral checkpoint that registration sends a confirmation email to `/dev/mailbox`.

- [ ] **Step 1: Boot the app**

```powershell
docker compose up -d db
docker compose up -d app
docker compose logs app --tail 30   # poll until "Running VerscientaWeb.Endpoint"
```

- [ ] **Step 2: Register a user through the UI**

In a browser: open `http://localhost:4000/register`, register with email `test@example.com`, a username `tester`, and a password (min length per the strategy, usually 8). Submit.
Expected: registration succeeds and the app indicates a confirmation email was sent (or you're signed in but unconfirmed, per strategy defaults).

- [ ] **Step 3: Confirm the email landed in the mailbox**

Open `http://localhost:4000/dev/mailbox`.
Expected: a "Confirm your Verscienta News account" email is present with a working confirm link. Click it; the account becomes confirmed (`confirmed_at` set).

- [ ] **Step 4: Tear down**

```powershell
docker compose down
```

- [ ] **Step 5: Commit (only if you had to fix a path)**

```powershell
git add -A
git commit -m "fix(auth): correct confirmation/reset email link paths"
```
(Skip if nothing changed.)

---

## Task 5: Profile update action + authorization policies (TDD)

Add the `update_profile` action and policies: public read, owner-only update, role/email never settable via profile update.

**Files:**
- Modify: `lib/verscienta/accounts/user.ex`
- Test: `test/verscienta/accounts_test.exs`

- [ ] **Step 1: Write the failing tests**

Replace the contents of `test/verscienta/accounts_test.exs` with:
```elixir
defmodule Verscienta.AccountsTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Accounts.User

  defp register(attrs) do
    User
    |> Ash.Changeset.for_create(:register_with_password, attrs)
    |> Ash.create(authorize?: false)
  end

  defp base_attrs(overrides) do
    Map.merge(
      %{
        email: "a@example.com",
        username: "alice",
        password: "password123",
        password_confirmation: "password123"
      },
      overrides
    )
  end

  test "registers a user with email, username and password" do
    {:ok, user} = register(base_attrs(%{}))
    assert to_string(user.email) == "a@example.com"
    assert to_string(user.username) == "alice"
    assert user.role == :user
  end

  test "username must be unique" do
    {:ok, _} = register(base_attrs(%{}))
    {:error, _} = register(base_attrs(%{email: "b@example.com", username: "alice"}))
  end

  test "username format is validated" do
    {:error, _} = register(base_attrs(%{username: "Bad Name!"}))
  end

  test "owner can update their own profile" do
    {:ok, user} = register(base_attrs(%{}))

    {:ok, updated} =
      user
      |> Ash.Changeset.for_update(:update_profile, %{display_name: "Alice A", bio: "hi"}, actor: user)
      |> Ash.update()

    assert updated.display_name == "Alice A"
    assert updated.bio == "hi"
  end

  test "a different user cannot update someone else's profile" do
    {:ok, owner} = register(base_attrs(%{}))
    {:ok, other} = register(base_attrs(%{email: "b@example.com", username: "bob"}))

    assert {:error, _} =
             owner
             |> Ash.Changeset.for_update(:update_profile, %{display_name: "hacked"}, actor: other)
             |> Ash.update()
  end

  test "role cannot be set through update_profile" do
    {:ok, user} = register(base_attrs(%{}))

    {:ok, updated} =
      user
      |> Ash.Changeset.for_update(:update_profile, %{role: :admin, display_name: "x"}, actor: user)
      |> Ash.update()

    assert updated.role == :user
  end

  test "anyone can read users (public profiles)" do
    {:ok, _} = register(base_attrs(%{}))
    assert [_] = Ash.read!(User)
  end
end
```

- [ ] **Step 2: Run the tests to confirm they fail**

```powershell
docker compose up -d db
docker compose run --rm app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta/accounts_test.exs"
```
Expected: failures — `update_profile` action does not exist yet and/or policies not in place.

- [ ] **Step 3: Add the `update_profile` action**

In `lib/verscienta/accounts/user.ex`, inside `actions do … end`, add:
```elixir
    update :update_profile do
      description "Update the current user's own profile fields."
      accept [:username, :display_name, :bio, :avatar_url]
      require_atomic? false
    end
```

- [ ] **Step 4: Add authorization policies**

In `lib/verscienta/accounts/user.ex`, replace the `policies do … end` block with (keep the AshAuthentication bypass first):
```elixir
  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:update_profile) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action_type(:create) do
      authorize_if always()
    end
  end
```
(`role`'s `writable? false` from Task 2 is what actually prevents role escalation; the policy enforces owner-only profile edits. The create policy keeps registration working when authorization runs.)

- [ ] **Step 5: Run the tests to confirm they pass**

```powershell
docker compose run --rm app bash -lc "MIX_ENV=test mix test test/verscienta/accounts_test.exs"
docker compose down
```
Expected: all tests pass. If the owner-update test fails because `actor:` isn't threaded, ensure you pass `actor: user` in `for_update` (the test does). If create now requires an actor, the `:create` policy above covers it.

- [ ] **Step 6: Format and commit**

```powershell
docker compose run --rm app bash -lc "mix format"
git add -A
git commit -m "feat(auth): profile update action and authorization policies"
```

---

## Task 6: Router cleanup + dark auth theme

Remove the out-of-scope magic-link route and make the built-in auth pages sit on the dark Codex canvas.

**Files:**
- Modify: `lib/verscienta_web/router.ex`
- Modify: `config/config.exs`
- Modify: `lib/verscienta_web/auth_overrides.ex`

- [ ] **Step 1: Remove the magic-link route**

In `lib/verscienta_web/router.ex`, delete the entire `magic_sign_in_route(Verscienta.Accounts.User, :magic_link, … )` call (and its trailing block). Leave `sign_in_route`, `auth_routes`, `sign_out_route`, `reset_route`, and `confirm_route` intact.

- [ ] **Step 2: Make daisyUI default to the dark theme**

The dark theme is defined in `assets/css/app.css` with `default: false` and the light theme `default: true`. Open `assets/css/app.css`, find the two `@plugin "../vendor/daisyui-theme"` blocks, set the **dark** block's `default:` to `true` and the **light** block's `default:` to `false`. (This keeps both themes available but makes dark the default so auth pages match the canvas.)

- [ ] **Step 3: Light Codex theming via AuthOverrides**

Replace the body of `lib/verscienta_web/auth_overrides.ex` with a minimal Zune-accent override:
```elixir
defmodule VerscientaWeb.AuthOverrides do
  @moduledoc "AshAuthentication UI overrides — Codex theming."
  use AshAuthentication.Phoenix.Overrides

  override AshAuthentication.Phoenix.Components.Banner do
    set :text, "verscienta·news"
    set :text_class, "text-2xl font-extralight lowercase text-ink"
  end
end
```
If the `Banner` component name/options differ in this version and compilation fails, fall back to the empty overrides module (just the `use` line) and report it — theming will then rely on the daisyUI dark default alone.

- [ ] **Step 4: Compile and verify auth pages render dark**

```powershell
docker compose up -d db
docker compose up -d app
docker compose logs app --tail 20   # poll until up
docker compose run --rm app bash -lc "mix phx.routes | grep -i magic || echo NO_MAGIC_ROUTE"
(Invoke-WebRequest http://localhost:4000/sign-in -UseBasicParsing).StatusCode
(Invoke-WebRequest http://localhost:4000/register -UseBasicParsing).StatusCode
docker compose down
```
Expected: `NO_MAGIC_ROUTE`; both pages return `200`.

- [ ] **Step 5: Format and commit**

```powershell
docker compose run --rm app bash -lc "mix format"
git add -A
git commit -m "feat(auth): remove magic-link route, default to dark Codex auth theme"
```

---

## Task 7: Auth-aware top strip nav (TDD)

Show sign-in/register when signed out; `@username` / settings / sign-out when signed in. This needs the current user in the conn/layout assigns; the browser pipeline already runs `load_from_session`, so the assign is `@current_user`.

**Files:**
- Modify: `lib/verscienta_web/components/layouts/root.html.heex`
- Test: `test/verscienta_web/auth_nav_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/auth_nav_test.exs`:
```elixir
defmodule VerscientaWeb.AuthNavTest do
  use VerscientaWeb.ConnCase, async: true

  test "signed-out nav shows sign in and register", %{conn: conn} do
    html = get(conn, ~p"/") |> html_response(200)
    assert html =~ "sign in"
    assert html =~ "register"
  end

  test "signed-in nav shows username and sign out", %{conn: conn} do
    user =
      Verscienta.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: "nav@example.com",
        username: "navuser",
        password: "password123",
        password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    conn =
      conn
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
      |> get(~p"/")

    html = html_response(conn, 200)
    assert html =~ "navuser"
    assert html =~ "sign out"
  end
end
```

- [ ] **Step 2: Run it to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta_web/auth_nav_test.exs"
```
Expected: failure — the signed-in assertions fail because the nav is static.

- [ ] **Step 3: Make the strip nav auth-aware**

In `lib/verscienta_web/components/layouts/root.html.heex`, replace the `<nav>` inside the strip header with:
```heex
      <nav class="ml-auto flex items-center gap-5 text-xs font-medium lowercase tracking-wider text-ink-3">
        <a href="/styleguide" class="transition-colors hover:text-ink">styleguide</a>
        <%= if @current_user do %>
          <a href={"/@" <> to_string(@current_user.username)} class="text-ink transition-colors hover:text-zune">
            @{@current_user.username}
          </a>
          <a href="/settings" class="transition-colors hover:text-ink">settings</a>
          <a href="/sign-out" class="transition-colors hover:text-ink">sign out</a>
        <% else %>
          <a href="/sign-in" class="transition-colors hover:text-ink">sign in</a>
          <a href="/register" class="text-zune transition-colors hover:text-ink">register</a>
        <% end %>
      </nav>
```
NOTE: `@current_user` must be assigned for non-LiveView (controller) renders. The `:browser` pipeline runs `load_from_session`, which sets the assign when a user is in session. If the test shows `@current_user` is not assigned (KeyError), add a tiny plug to the `:browser` pipeline: `plug :assign_current_user` defined in the router as
```elixir
  defp assign_current_user(conn, _),
    do: Plug.Conn.assign(conn, :current_user, conn.assigns[:current_user])
```
placed after `load_from_session`. Only add this if the KeyError actually occurs (use `assigns[:current_user]` access in the template — already safe — so it likely won't).

- [ ] **Step 4: Verify the sign-out path**

```powershell
docker compose run --rm app bash -lc "mix phx.routes | grep -i sign-out"
```
Expected: a `/sign-out` route exists (from `sign_out_route`). If the path differs, update the `href` in the template to match.

- [ ] **Step 5: Run the test to confirm it passes**

```powershell
docker compose run --rm app bash -lc "MIX_ENV=test mix test test/verscienta_web/auth_nav_test.exs"
docker compose down
```
Expected: both tests pass.

- [ ] **Step 6: Format and commit**

```powershell
docker compose run --rm app bash -lc "mix format"
git add -A
git commit -m "feat(auth): auth-aware top strip navigation"
```

---

## Task 8: Public profile LiveView `/@:username` (TDD)

**Files:**
- Create: `lib/verscienta_web/live/profile_live.ex`
- Modify: `lib/verscienta_web/router.ex`
- Test: `test/verscienta_web/live/profile_live_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/profile_live_test.exs`:
```elixir
defmodule VerscientaWeb.ProfileLiveTest do
  use VerscientaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  defp create_user(username) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: username <> "@example.com",
      username: username,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  test "renders a known user's profile", %{conn: conn} do
    create_user("zara")
    {:ok, _lv, html} = live(conn, ~p"/@zara")
    assert html =~ "zara"
    assert html =~ "user"
  end

  test "unknown username returns 404", %{conn: conn} do
    assert_raise Ash.Error.Query.NotFound, fn ->
      live(conn, ~p"/@nobody")
    end
  end
end
```
(If LiveView wraps the NotFound differently, the test may need `Phoenix.LiveViewTest` to surface it; if `assert_raise` doesn't match, change to assert the mount returns `{:error, {:live_redirect, ...}}` or a 404 — adjust to the actual behavior and note it.)

- [ ] **Step 2: Run it to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta_web/live/profile_live_test.exs"
```
Expected: failure (route + LiveView don't exist).

- [ ] **Step 3: Create the ProfileLive**

Create `lib/verscienta_web/live/profile_live.ex`:
```elixir
defmodule VerscientaWeb.ProfileLive do
  @moduledoc "Public read-only user profile at /@:username."
  use VerscientaWeb, :live_view

  import VerscientaWeb.CodexComponents

  on_mount {VerscientaWeb.LiveUserAuth, :live_user_optional}

  @impl true
  def mount(%{"username" => username}, _session, socket) do
    user =
      Verscienta.Accounts.User
      |> Ash.Query.filter(username == ^username)
      |> Ash.read_one!(authorize?: false)
      |> case do
        nil -> raise Ash.Error.Query.NotFound
        user -> user
      end

    {:ok, assign(socket, user: user, page_title: "@#{username}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-6 pb-24 pt-28">
      <div class="border border-line bg-canvas-2 p-10">
        <div class="flex items-center gap-6">
          <div class="flex h-20 w-20 items-center justify-center bg-zune text-2xl font-extrabold text-black">
            {avatar_initials(@user)}
          </div>
          <div>
            <.headline class="text-5xl">{display(@user)}</.headline>
            <p class="mt-2 text-sm tracking-wide text-ink-3">@{@user.username}</p>
          </div>
        </div>

        <p class="mt-6 inline-block bg-canvas-3 px-3 py-1 text-[11px] font-bold uppercase tracking-wider text-ink-2">
          {@user.role}
        </p>

        <%= if @user.bio do %>
          <p class="mt-6 max-w-2xl text-base font-light leading-relaxed text-ink-2">{@user.bio}</p>
        <% end %>
      </div>
    </div>
    """
  end

  defp display(user), do: user.display_name || to_string(user.username)

  defp avatar_initials(user) do
    (user.display_name || to_string(user.username))
    |> String.trim()
    |> String.slice(0, 2)
    |> String.upcase()
  end
end
```

- [ ] **Step 4: Add the route**

In `lib/verscienta_web/router.ex`, inside the second `scope "/", VerscientaWeb do … pipe_through :browser` block, after the `get "/styleguide", …` line, add:
```elixir
    live "/@:username", ProfileLive, :show
```

- [ ] **Step 5: Run the test to confirm it passes**

```powershell
docker compose run --rm app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/profile_live_test.exs"
docker compose down
```
Expected: render test passes. If the 404 assertion's exact error type differs, adjust the test to the observed behavior (and keep it asserting that an unknown username does NOT render a profile).

- [ ] **Step 6: Format and commit**

```powershell
docker compose run --rm app bash -lc "mix format"
git add -A
git commit -m "feat(profiles): public /@:username profile page"
```

---

## Task 9: Settings LiveView `/settings` (TDD)

**Files:**
- Create: `lib/verscienta_web/live/settings_live.ex`
- Modify: `lib/verscienta_web/router.ex`
- Test: `test/verscienta_web/live/settings_live_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/settings_live_test.exs`:
```elixir
defmodule VerscientaWeb.SettingsLiveTest do
  use VerscientaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  defp create_user(username) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: username <> "@example.com",
      username: username,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  test "redirects to sign-in when signed out", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/settings")
  end

  test "owner can edit their profile", %{conn: conn} do
    user = create_user("edna")
    conn = AshAuthentication.Plug.Helpers.store_in_session(conn, user)

    {:ok, lv, _html} = live(conn, ~p"/settings")

    html =
      lv
      |> form("#settings-form", form: %{"display_name" => "Edna E", "bio" => "curator"})
      |> render_submit()

    assert html =~ "Saved" or html =~ "Edna E"

    updated =
      Verscienta.Accounts.User
      |> Ash.get!(user.id, authorize?: false)

    assert updated.display_name == "Edna E"
  end

  test "shows validation error for bad username", %{conn: conn} do
    user = create_user("frank")
    conn = AshAuthentication.Plug.Helpers.store_in_session(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/settings")

    html =
      lv
      |> form("#settings-form", form: %{"username" => "Bad Name!"})
      |> render_change()

    assert html =~ "must" or html =~ "invalid" or html =~ "match"
  end
end
```

- [ ] **Step 2: Run it to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta_web/live/settings_live_test.exs"
```
Expected: failure (route + LiveView don't exist).

- [ ] **Step 3: Create the SettingsLive**

Create `lib/verscienta_web/live/settings_live.ex`:
```elixir
defmodule VerscientaWeb.SettingsLive do
  @moduledoc "Authenticated profile editor at /settings."
  use VerscientaWeb, :live_view

  on_mount {VerscientaWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    {:ok, assign(socket, page_title: "settings") |> assign_form(user)}
  end

  defp assign_form(socket, user) do
    form =
      AshPhoenix.Form.for_update(user, :update_profile,
        as: "form",
        actor: user
      )
      |> to_form()

    assign(socket, form: form, current_user: user)
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form, params)
    {:noreply, assign(socket, form: form)}
  end

  @impl true
  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved")
         |> assign_form(user)}

      {:error, form} ->
        {:noreply, assign(socket, form: form)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-6 pb-24 pt-28">
      <.headline class="mb-10 text-6xl">settings</.headline>

      <.form
        :let={f}
        for={@form}
        id="settings-form"
        phx-change="validate"
        phx-submit="save"
        class="max-w-xl space-y-6"
      >
        <div>
          <label class="mb-1 block text-[11px] uppercase tracking-widest text-ink-3">username</label>
          <input
            type="text"
            name={f[:username].name}
            value={Phoenix.HTML.Form.normalize_value("text", f[:username].value)}
            class="w-full border border-line bg-canvas-2 px-4 py-3 text-ink"
          />
          <.error :for={msg <- Enum.map(f[:username].errors, &translate_error/1)}>{msg}</.error>
        </div>

        <div>
          <label class="mb-1 block text-[11px] uppercase tracking-widest text-ink-3">display name</label>
          <input
            type="text"
            name={f[:display_name].name}
            value={Phoenix.HTML.Form.normalize_value("text", f[:display_name].value)}
            class="w-full border border-line bg-canvas-2 px-4 py-3 text-ink"
          />
        </div>

        <div>
          <label class="mb-1 block text-[11px] uppercase tracking-widest text-ink-3">bio</label>
          <textarea
            name={f[:bio].name}
            rows="4"
            class="w-full border border-line bg-canvas-2 px-4 py-3 text-ink"
          >{Phoenix.HTML.Form.normalize_value("textarea", f[:bio].value)}</textarea>
        </div>

        <div>
          <label class="mb-1 block text-[11px] uppercase tracking-widest text-ink-3">avatar url</label>
          <input
            type="text"
            name={f[:avatar_url].name}
            value={Phoenix.HTML.Form.normalize_value("text", f[:avatar_url].value)}
            class="w-full border border-line bg-canvas-2 px-4 py-3 text-ink"
          />
        </div>

        <button
          type="submit"
          class="bg-zune px-6 py-3 text-xs font-bold uppercase tracking-wider text-black transition-[filter] hover:brightness-110"
        >
          save
        </button>
      </.form>
    </div>
    """
  end
end
```

- [ ] **Step 4: Add the route**

In `lib/verscienta_web/router.ex`, in the same browser scope, after the `live "/@:username", …` line, add:
```elixir
    live "/settings", SettingsLive, :edit
```
IMPORTANT ordering: ensure `live "/settings", …` is declared BEFORE `live "/@:username", …` is NOT required (they don't overlap — `/settings` has no `@`). But if any catch-all exists, keep `/settings` above `/@:username` to be safe.

- [ ] **Step 5: Run the test to confirm it passes**

```powershell
docker compose run --rm app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/settings_live_test.exs"
docker compose down
```
Expected: all three tests pass. If the redirect tuple shape differs (`:live_redirect` vs `:redirect`), adjust the first test to the observed shape. If `.error`/`translate_error` helpers aren't available in this app's `CoreComponents`, replace the error markup with a plain `<%= for {msg, _} <- f[:username].errors do %><p class="text-politics text-xs">...<% end %>` block and report it.

- [ ] **Step 6: Format and commit**

```powershell
docker compose run --rm app bash -lc "mix format"
git add -A
git commit -m "feat(profiles): /settings profile editor"
```

---

## Task 10: Seeds + full verification

**Files:**
- Modify: `priv/repo/seeds.exs`

- [ ] **Step 1: Add an idempotent dev admin user to seeds**

Append to `priv/repo/seeds.exs`:
```elixir
# Dev admin user (idempotent). Password: "password123".
alias Verscienta.Accounts.User

existing =
  User
  |> Ash.Query.filter(email == "admin@verscienta.news")
  |> Ash.read_one!(authorize?: false)

if is_nil(existing) do
  User
  |> Ash.Changeset.for_create(:register_with_password, %{
    email: "admin@verscienta.news",
    username: "admin",
    password: "password123",
    password_confirmation: "password123"
  })
  |> Ash.create!(authorize?: false)
  |> then(fn user ->
    user
    |> Ash.Changeset.for_update(:update_profile, %{display_name: "Verscienta Admin"}, actor: user)
    |> Ash.Changeset.force_change_attribute(:role, :admin)
    |> Ash.Changeset.force_change_attribute(:confirmed_at, DateTime.utc_now())
    |> Ash.update!(authorize?: false)
  end)

  IO.puts("Seeded admin@verscienta.news")
end
```
If `Ash.Changeset.for_update` + `force_change_attribute` on `:role`/`:confirmed_at` doesn't persist (because `update_profile` doesn't accept them), instead build the role/confirm change with a bare `:update` action: `Ash.Changeset.for_update(user, :update) |> force_change_attribute(...)`. Use whichever persists; verify in Step 2.

- [ ] **Step 2: Run seeds and verify the admin exists with role**

```powershell
docker compose up -d db
docker compose run --rm app bash -lc "mix ash.setup && mix run priv/repo/seeds.exs && mix run -e 'u = Verscienta.Accounts.User |> Ash.Query.filter(username == \"admin\") |> Ash.read_one!(authorize?: false); IO.inspect({u.role, u.confirmed_at})'"
```
Expected: prints `{:admin, ~U[...]}` (role admin, confirmed_at set). Re-running seeds prints nothing new (idempotent).

- [ ] **Step 3: Full quality-gate run**

```powershell
docker compose run --rm app bash -lc "mix compile --warnings-as-errors && mix format --check-formatted && mix credo --strict && MIX_ENV=test mix ash.setup && MIX_ENV=test mix test"
docker compose down
```
Expected: compiles clean, format clean, credo 0 issues, all tests pass (Accounts + profile + settings + nav + the Phase 0 smoke tests). If `mix format --check-formatted` complains, run `mix format` and commit. If credo flags new files, fix or justify.

- [ ] **Step 4: Manual end-to-end smoke (optional but recommended)**

```powershell
docker compose up -d
docker compose logs app --tail 20   # poll until up
```
In a browser: register → confirm via `/dev/mailbox` → sign out → sign in → visit `/@<yourusername>` → edit at `/settings` → sign out. Then:
```powershell
docker compose down
```

- [ ] **Step 5: Commit**

```powershell
git add -A
git commit -m "feat(auth): seed dev admin user; finalize auth & profiles"
```

---

## Definition of Done (verify all)

- [ ] Register → confirmation email in `/dev/mailbox` → confirm → sign in → sign out all work.
- [ ] Password reset works end to end via emailed link.
- [ ] `/@:username` renders a Codex profile; unknown usernames don't render a profile.
- [ ] `/settings` requires auth, edits profile fields, shows validation errors, persists changes.
- [ ] `role` defaults to `:user` and cannot be set via `update_profile`.
- [ ] Top-strip nav reflects signed-in vs signed-out state.
- [ ] Magic-link route removed; auth pages render on the dark canvas.
- [ ] `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test` all pass.
- [ ] Migrations + seeds committed; all work on `phase-1-auth-profiles`.
```
