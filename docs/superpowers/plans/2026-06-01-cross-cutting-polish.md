# Cross-Cutting MVP Polish Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Production-readiness polish — Codex-styled 404/500 pages, responsive mobile nav, a targeted accessibility pass, and an admin-gated LiveDashboard.

**Architecture:** Static self-contained error templates via `ErrorHTML`; a `JS.toggle` hamburger drawer in the shared root layout (no server state); focus-visible CSS + nav ARIA + a `<main>` landmark; an `:admin_required` plug gating a `/dev/dashboard` LiveDashboard route. No new domains, resources, or migrations.

**Tech Stack:** Phoenix 1.8, LiveView (`Phoenix.LiveView.JS`), `phoenix_live_dashboard`, Tailwind v4 + Codex tokens.

---

## Conventions for the executor

- **Run everything in Docker.** Mix in the app service: `docker compose run --rm -T app bash -lc "<cmd>"`. Start DB: `docker compose up -d db`. Generous timeouts. If "dependency not available", prefix `mix deps.get &&`.
- **One task at a time, sequentially.** After each task run `git rev-parse --short HEAD` for the REAL sha. Never batch tasks or guess SHAs. **Re-run the FULL gate (`mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `MIX_ENV=test mix test`) after the FINAL edit, BEFORE committing.**
- **Branch:** `polish-cross-cutting` (already checked out; spec committed `ef5c3f1`).
- **Line endings:** `.gitattributes` eol=lf, autocrlf false — don't change. `mix format` before commit. No `.bak` files.
- **Git identity:** no local override. Commit body ends with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- **No migrations** in this work. Do NOT run `mix ash.codegen`.
- **Reuse patterns:**
  - `ErrorHTML` is `lib/verscienta_web/controllers/error_html.ex` (currently returns status text; has commented `embed_templates`).
  - Root layout `lib/verscienta_web/components/layouts/root.html.heex` (the `<header>`/`<nav>` is ~lines 37-60; `{@inner_content}` near the bottom).
  - Admin-gate precedent: `AdminSourcesLive` raises 404 for non-admins on mount; the browser pipeline runs `load_from_session` so `conn.assigns.current_user` is available in controllers/plugs.
  - Router dev block (`lib/verscienta_web/router.ex` ~lines 86-100) already has a dev-only `live_dashboard "/dashboard"`; `VerscientaWeb.Telemetry` exists.
  - Codex tokens: canvas `#0c0c0c`, ink `#fff`/`#b6b6b6`/`#6d6d6d`, line `#2a2a2a`, zune `#f2660a`.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `lib/verscienta_web/controllers/error_html.ex` | enable `embed_templates`, keep fallback `render/2` |
| `lib/verscienta_web/controllers/error_html/404.html.heex` | self-contained Codex 404 |
| `lib/verscienta_web/controllers/error_html/500.html.heex` | self-contained Codex 500 |
| `lib/verscienta_web/components/layouts/root.html.heex` | responsive nav (desktop row + mobile drawer), `<nav aria-label>`, `<main>` landmark |
| `assets/css/app.css` | global `:focus-visible` ring |
| `lib/verscienta_web/router.ex` | `:admin_required` plug + admin-gated `/dev/dashboard`; keep mailbox dev-only |
| `test/verscienta_web/controllers/error_html_test.exs` | 404/500 render the Codex copy |
| `test/verscienta_web/nav_test.exs` | mobile hamburger + drawer markup present |
| `test/verscienta_web/dev_dashboard_test.exs` | admin-gated dashboard access |

---

## Task 1: Codex-styled error pages (TDD)

**Files:**
- Modify: `lib/verscienta_web/controllers/error_html.ex`
- Create: `lib/verscienta_web/controllers/error_html/404.html.heex`, `.../500.html.heex`
- Test: `test/verscienta_web/controllers/error_html_test.exs`

- [ ] **Step 1: Check the existing error test (may already exist from Phase 0)**

```powershell
docker compose run --rm -T app bash -lc "cat test/verscienta_web/controllers/error_html_test.exs 2>/dev/null || echo NO_FILE"
```
If it exists, you will REPLACE its body in Step 2 (the default generator test asserts plain "Not Found"/"Internal Server Error" text — that will change). Note its current contents.

- [ ] **Step 2: Write the failing test**

Overwrite `test/verscienta_web/controllers/error_html_test.exs` with:
```elixir
defmodule VerscientaWeb.ErrorHTMLTest do
  use VerscientaWeb.ConnCase, async: true

  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404 with Codex copy" do
    html = render_to_string(VerscientaWeb.ErrorHTML, "404", "html", [])
    assert html =~ "not found"
    assert html =~ "back to the feed"
    assert html =~ "verscienta"
  end

  test "renders 500 with Codex copy" do
    html = render_to_string(VerscientaWeb.ErrorHTML, "500", "html", [])
    assert html =~ "something went wrong"
    assert html =~ "verscienta"
  end

  test "unknown templates fall back to status message" do
    assert render_to_string(VerscientaWeb.ErrorHTML, "418", "html", []) == "I'm a teapot"
  end
end
```

- [ ] **Step 3: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/controllers/error_html_test.exs"
```
Expected: fails — templates not embedded; current `render/2` returns plain status text.

- [ ] **Step 4: Enable embed_templates with a fallback**

Replace `lib/verscienta_web/controllers/error_html.ex` with:
```elixir
defmodule VerscientaWeb.ErrorHTML do
  @moduledoc """
  Renders HTML error pages. 404/500 use Codex-styled, self-contained templates
  (no app layout / asset pipeline). Other statuses fall back to a plain message.
  """
  use VerscientaWeb, :html

  embed_templates "error_html/*"

  # Fallback for any status without a dedicated template (e.g. 418, 403).
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
```
NOTE: `embed_templates` defines `render("404.html", _)` / `render("500.html", _)` clauses from the files; the catch-all `render/2` above handles everything else. Elixir requires the specific (generated) clauses to precede the catch-all — `embed_templates` injects them above this definition since it's called first. If the compiler warns the catch-all shadows the templates, move `embed_templates` ABOVE nothing-needed (it already is). Verify with the test.

- [ ] **Step 5: Create the 404 template**

Create `lib/verscienta_web/controllers/error_html/404.html.heex` — a complete self-contained document:
```heex
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>not found · verscienta news</title>
    <style>
      *{box-sizing:border-box;margin:0;padding:0}
      body{background:#0c0c0c;color:#fff;font-family:"Hanken Grotesk Variable","Hanken Grotesk",ui-sans-serif,system-ui,sans-serif;font-weight:300;min-height:100vh;display:flex;flex-direction:column;justify-content:center;padding:clamp(24px,6vw,96px)}
      .kicker{font-size:11px;letter-spacing:.3em;text-transform:uppercase;color:#6d6d6d;margin-bottom:18px}
      h1{font-size:clamp(64px,16vw,160px);font-weight:200;line-height:.82;letter-spacing:-.02em;text-transform:lowercase}
      h1 .a{color:#f2660a}
      p{margin-top:24px;max-width:34rem;color:#b6b6b6;font-size:clamp(15px,2vw,18px)}
      a.cta{display:inline-block;margin-top:32px;border:1px solid #f2660a;color:#f2660a;font-size:11px;font-weight:700;letter-spacing:.14em;text-transform:uppercase;padding:12px 20px;text-decoration:none}
      a.cta:hover{background:#f2660a;color:#000}
      .mark{margin-top:56px;font-size:12px;font-weight:800;letter-spacing:.05em;text-transform:lowercase;color:#6d6d6d}
      .mark b{color:#f2660a}
    </style>
  </head>
  <body>
    <p class="kicker">error · 404</p>
    <h1>not<br /><span class="a">found</span></h1>
    <p>The page you're looking for has drifted off the edge of the canvas — it may have been unpublished, or the link is wrong.</p>
    <a class="cta" href="/articles">← back to the feed</a>
    <p class="mark">verscienta<b>·</b>news</p>
  </body>
</html>
```

- [ ] **Step 6: Create the 500 template**

Create `lib/verscienta_web/controllers/error_html/500.html.heex`:
```heex
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>something went wrong · verscienta news</title>
    <style>
      *{box-sizing:border-box;margin:0;padding:0}
      body{background:#0c0c0c;color:#fff;font-family:"Hanken Grotesk Variable","Hanken Grotesk",ui-sans-serif,system-ui,sans-serif;font-weight:300;min-height:100vh;display:flex;flex-direction:column;justify-content:center;padding:clamp(24px,6vw,96px)}
      .kicker{font-size:11px;letter-spacing:.3em;text-transform:uppercase;color:#6d6d6d;margin-bottom:18px}
      h1{font-size:clamp(54px,13vw,140px);font-weight:200;line-height:.84;letter-spacing:-.02em;text-transform:lowercase}
      h1 .a{color:#f2660a}
      p{margin-top:24px;max-width:34rem;color:#b6b6b6;font-size:clamp(15px,2vw,18px)}
      a.cta{display:inline-block;margin-top:32px;border:1px solid #f2660a;color:#f2660a;font-size:11px;font-weight:700;letter-spacing:.14em;text-transform:uppercase;padding:12px 20px;text-decoration:none}
      a.cta:hover{background:#f2660a;color:#000}
      .mark{margin-top:56px;font-size:12px;font-weight:800;letter-spacing:.05em;text-transform:lowercase;color:#6d6d6d}
      .mark b{color:#f2660a}
    </style>
  </head>
  <body>
    <p class="kicker">error · 500</p>
    <h1>something<br /><span class="a">went wrong</span></h1>
    <p>An unexpected error occurred on our end. The team has been notified — please try again in a moment.</p>
    <a class="cta" href="/">← back home</a>
    <p class="mark">verscienta<b>·</b>news</p>
  </body>
</html>
```

- [ ] **Step 7: Run the test to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/controllers/error_html_test.exs"
```
Expected: 3 tests pass. The `render_to_string` for `"404"` resolves to the `404.html.heex` template.

- [ ] **Step 8: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors"
git add -A
git commit -m "feat(polish): Codex-styled 404/500 error pages"
```
Then `git rev-parse --short HEAD`.

---

## Task 2: Responsive mobile nav + landmarks (TDD)

**Files:**
- Modify: `lib/verscienta_web/components/layouts/root.html.heex`
- Test: `test/verscienta_web/nav_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/nav_test.exs`:
```elixir
defmodule VerscientaWeb.NavTest do
  use VerscientaWeb.ConnCase, async: true

  test "home page nav has a primary landmark and a mobile menu button", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ ~s(aria-label="primary")
    assert html =~ ~s(aria-label="menu")
    assert html =~ ~s(id="mobile-menu")
    assert html =~ ~s(<main)
  end

  test "signed-out mobile menu contains sign in and register", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    # both desktop + drawer render the links; just assert they're present
    assert html =~ "sign in"
    assert html =~ "register"
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta_web/nav_test.exs"
```
Expected: fails — no `aria-label`/`#mobile-menu`/`<main>` yet.

- [ ] **Step 3: Rework the header + add the drawer + main landmark**

In `lib/verscienta_web/components/layouts/root.html.heex`, replace the `<header>...</header>` block and wrap the content. The current structure is a `<header>` with the mark `<a>` + a `<nav>` of links. Replace from `<header ...>` through `</header>` and the `{@inner_content}` with:
```heex
    <header class="fixed inset-x-0 top-0 z-50 flex items-center gap-7 px-6 py-3.5">
      <a href="/" class="text-[13px] font-extrabold lowercase tracking-wide">
        verscienta<span class="text-zune">·</span>news
      </a>

      <button
        type="button"
        aria-label="menu"
        aria-controls="mobile-menu"
        aria-expanded="false"
        phx-click={Phoenix.LiveView.JS.toggle(to: "#mobile-menu")}
        class="ml-auto flex flex-col gap-1 sm:hidden"
      >
        <span class="block h-0.5 w-5 bg-zune"></span>
        <span class="block h-0.5 w-5 bg-zune"></span>
        <span class="block h-0.5 w-5 bg-zune"></span>
      </button>

      <nav
        aria-label="primary"
        class="ml-auto hidden items-center gap-5 text-xs font-medium lowercase tracking-wider text-ink-3 sm:flex"
      >
        {nav_links(assigns)}
      </nav>
    </header>

    <nav
      id="mobile-menu"
      aria-label="primary mobile"
      class="fixed inset-x-0 top-14 z-40 hidden flex-col gap-4 border-b border-line bg-canvas px-6 py-6 text-sm lowercase tracking-wider text-ink-3"
    >
      {nav_links(assigns)}
    </nav>

    <main>
      {@inner_content}
    </main>
```
NOTE: `nav_links/1` is a shared function component so the desktop row and the mobile drawer render identical links. Define it in the LAYOUTS module (`lib/verscienta_web/components/layouts.ex`), not the heex. See Step 4. If you prefer not to extract a component, inline the SAME link markup in both `<nav>` blocks (duplicated) — but the shared function is cleaner and avoids drift. Use the shared function.

- [ ] **Step 4: Add the `nav_links/1` component**

In `lib/verscienta_web/components/layouts.ex`, add a function component that renders the auth-aware links (move the existing link markup here). Add:
```elixir
  @doc "Renders the primary nav links (shared by desktop strip and mobile drawer)."
  attr :current_user, :map, default: nil

  def nav_links(assigns) do
    ~H"""
    <a href="/search" class="transition-colors hover:text-ink">search</a>
    <a href="/styleguide" class="transition-colors hover:text-ink">styleguide</a>
    <%= if @current_user do %>
      <a href="/articles/new" class="transition-colors hover:text-ink">write</a>
      <a href="/library" class="transition-colors hover:text-ink">library</a>
      <a
        :if={@current_user.role == :admin}
        href="/admin/sources"
        class="transition-colors hover:text-ink"
      >
        admin
      </a>
      <a
        href={"/@" <> to_string(@current_user.username)}
        class="text-ink transition-colors hover:text-zune"
      >
        {"@" <> to_string(@current_user.username)}
      </a>
      <a href="/settings" class="transition-colors hover:text-ink">settings</a>
      <a href="/sign-out" class="transition-colors hover:text-ink">sign out</a>
    <% else %>
      <a href="/sign-in" class="transition-colors hover:text-ink">sign in</a>
      <a href="/register" class="text-zune transition-colors hover:text-ink">register</a>
    <% end %>
    """
  end
```
And in `root.html.heex`, call it as `<.nav_links current_user={assigns[:current_user]} />` inside each `<nav>` instead of `{nav_links(assigns)}` (HEEx function-component call form). Replace both `{nav_links(assigns)}` occurrences with `<.nav_links current_user={assigns[:current_user]} />`. NOTE: `root.html.heex` is rendered within `VerscientaWeb.Layouts`, so `nav_links/1` defined there is in scope as `<.nav_links .../>`.

- [ ] **Step 5: Run the test to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/nav_test.exs"
```
Expected: both tests pass. If `Phoenix.LiveView.JS.toggle` errors in a controller-rendered page, it shouldn't — `JS.toggle` produces a data attribute consumed by the LV JS runtime loaded via app.js on every page. Verify the home page (a controller page) still renders 200.

- [ ] **Step 6: Manual check (optional)**

```powershell
docker compose up -d
docker compose logs app --tail 10
```
Open `http://localhost:4000` at a narrow width → the hamburger shows; click toggles the drawer. At wide width → inline strip; hamburger hidden. Then `docker compose down`.

- [ ] **Step 7: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors"
git add -A
git commit -m "feat(polish): responsive mobile nav drawer + primary/main landmarks"
```
Then `git rev-parse --short HEAD`.

---

## Task 3: Global focus-visible styles + control audit

**Files:**
- Modify: `assets/css/app.css`
- (Audit only) reader/editor/admin/search templates

- [ ] **Step 1: Add the focus-visible ring**

At the bottom of `assets/css/app.css` (after the `::selection` rule), add:
```css
:focus-visible {
  outline: 2px solid var(--color-zune);
  outline-offset: 2px;
}
```

- [ ] **Step 2: Build assets to confirm the CSS compiles**

```powershell
docker compose run --rm -T app bash -lc "mix assets.build"
```
Expected: tailwind/esbuild run clean; `priv/static/assets/css/app.css` regenerates.

- [ ] **Step 3: Audit interactive controls (grep, fix non-semantic ones)**

```powershell
docker compose run --rm -T app bash -lc "grep -rn 'phx-click' lib/verscienta_web/live lib/verscienta_web/components | grep -vE '<button|<a |<\.link' | grep -iE 'div|span' || echo 'NO_NONSEMANTIC_CLICK_TARGETS'"
```
Expected: `NO_NONSEMANTIC_CLICK_TARGETS` (the reader/editor/admin/search controls are already `<button>`/`<a>`). If any `div`/`span` with `phx-click` is found, convert it to a `<button type="button">` with the same classes + `phx-click`, and report which. Do NOT restyle — just make it a semantic control.

- [ ] **Step 4: Compile + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors"
git add -A
git commit -m "feat(polish): app-wide focus-visible ring; semantic control audit"
```
Then `git rev-parse --short HEAD`. (Report the audit result in the commit body if any control was converted.)

---

## Task 4: Admin-gated LiveDashboard (TDD)

**Files:**
- Modify: `lib/verscienta_web/router.ex`
- Test: `test/verscienta_web/dev_dashboard_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/dev_dashboard_test.exs`:
```elixir
defmodule VerscientaWeb.DevDashboardTest do
  use VerscientaWeb.ConnCase, async: false

  alias AshAuthentication.Plug.Helpers

  defp user(name, role) do
    u =
      Verscienta.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: name <> "@example.com",
        username: name,
        password: "password123",
        password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    u
    |> Ash.Changeset.for_update(:update_profile, %{}, actor: u)
    |> Ash.Changeset.force_change_attribute(:role, role)
    |> Ash.update!(authorize?: false)
  end

  defp sign_in(conn, u), do: conn |> Plug.Test.init_test_session(%{}) |> Helpers.store_in_session(u)

  test "signed-out user cannot reach the dashboard", %{conn: conn} do
    conn = get(conn, "/dev/dashboard")
    assert conn.status in [302, 401, 403, 404]
  end

  test "non-admin user cannot reach the dashboard", %{conn: conn} do
    conn = conn |> sign_in(user("plainuser", :user)) |> get("/dev/dashboard")
    assert conn.status in [302, 401, 403, 404]
  end

  test "admin user reaches the dashboard", %{conn: conn} do
    conn = conn |> sign_in(user("adminuser", :admin)) |> get("/dev/dashboard/home")
    # LiveDashboard redirects /dev/dashboard -> /dev/dashboard/home; hitting /home directly returns 200
    assert conn.status == 200
  end
end
```
NOTE: LiveDashboard's index redirects to a node/page path. Hitting `/dev/dashboard/home` directly avoids the redirect for the admin assertion. If the exact sub-path differs in this dashboard version, adjust to the real landing path (run `mix phx.routes | grep dashboard` to see), keeping the assertion "admin gets 200, others don't".

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta_web/dev_dashboard_test.exs"
```
Expected: the admin test fails (the dashboard is currently behind `dev_routes` compile flag, not admin-gated; in test env `dev_routes` is false so the route may 404 for everyone — admin test fails).

- [ ] **Step 3: Add the `:admin_required` plug**

In `lib/verscienta_web/router.ex`, add a private plug function (after the pipelines, before the scopes):
```elixir
  defp admin_required(conn, _opts) do
    case conn.assigns[:current_user] do
      %{role: :admin} ->
        conn

      _ ->
        conn
        |> Phoenix.Controller.put_flash(:error, "Not authorized.")
        |> Phoenix.Controller.redirect(to: "/")
        |> halt()
    end
  end
```
Add `import Plug.Conn` at the top of the router if `halt/1` isn't already imported (Phoenix.Router imports Plug.Conn by default — `halt` should be available; if not, fully-qualify `Plug.Conn.halt(conn)`).

- [ ] **Step 4: Add an admin-gated dashboard pipeline + scope**

In `lib/verscienta_web/router.ex`, add a pipeline:
```elixir
  pipeline :admin do
    plug :admin_required
  end
```
Then add an always-available admin-gated dashboard scope (OUTSIDE the `if dev_routes` block so it works in prod too). Near the dev block, add:
```elixir
  scope "/dev" do
    pipe_through [:browser, :admin]

    import Phoenix.LiveDashboard.Router
    live_dashboard "/dashboard", metrics: VerscientaWeb.Telemetry
  end
```
And REMOVE the `live_dashboard "/dashboard", ...` line from inside the existing `if Application.compile_env(:verscienta, :dev_routes)` block (keep the Swoosh mailbox forward there, dev-only). The dev block becomes:
```elixir
  if Application.compile_env(:verscienta, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
```
NOTE: two `scope "/dev"` blocks are fine (one admin-gated for the dashboard, one dev-only for mailbox). If `import Phoenix.LiveDashboard.Router` twice causes a redefinition warning, import it once at the module level instead. Verify `mix phx.routes | grep -E 'dashboard|mailbox'` shows the dashboard always-present and mailbox only in dev.

- [ ] **Step 5: Run the test to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/dev_dashboard_test.exs"
```
Expected: all 3 pass — signed-out + non-admin are redirected (302) to `/`, admin gets 200 at the dashboard landing path. Adjust the admin landing sub-path per the NOTE if needed.

- [ ] **Step 6: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors"
git add -A
git commit -m "feat(polish): admin-gated LiveDashboard at /dev/dashboard"
```
Then `git rev-parse --short HEAD`.

---

## Task 5: Full verification + todo update + merge prep

**Files:**
- Modify: `docs/todo.md`

- [ ] **Step 1: Tick the cross-cutting todo items**

In `docs/todo.md`, under "### Cross-cutting MVP", update the checkboxes:
```markdown
- [x] Navigation + responsive mobile-first layout across all pages.
- [x] Dark mode baseline (canvas is dark by default; verify reading view).
- [x] Error pages (404/500) styled.
- [ ] Sentry error tracking wired up. *(deferred to deployment — needs DSN)*
- [x] Telemetry basics + LiveDashboard (dev/internal). *(admin-gated /dev/dashboard)*
- [x] Seed script with demo users/content for development. *(done across subsystems)*
- [x] LiveView + ExUnit tests for each major flow. *(done across subsystems)*
- [~] Accessibility pass (focus states, contrast, semantics, keyboard nav). *(focus-visible, nav ARIA, landmarks, control audit; full WCAG cert deferred)*
```

- [ ] **Step 2: Full clean-deps gate run**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "mix deps.get && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
```
Expected: format clean, credo 0 issues, no warnings, ALL tests pass. Capture the exact `N tests, 0 failures` line.

- [ ] **Step 3: Commit**

```powershell
git add -A
git commit -m "docs(polish): mark cross-cutting MVP items done/deferred"
```
Then `git rev-parse --short HEAD`.

---

## Definition of Done (verify all)

- [ ] `/dev/dashboard` reachable by admins only (signed-out/non-admin redirected); mailbox stays dev-only.
- [ ] 404 and 500 render Codex-styled self-contained pages ("not found" / "something went wrong" + links).
- [ ] Top nav is an inline strip on desktop and a `JS.toggle` hamburger drawer on mobile, on both controller and LiveView pages; `<nav aria-label="primary">`, hamburger `aria-label="menu"`, content in `<main>`.
- [ ] App-wide `:focus-visible` ring; all `phx-click` targets are semantic `<button>`/`<a>`.
- [ ] `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test` all pass.
- [ ] No migrations; `docs/todo.md` updated; work committed on `polish-cross-cutting`.
