# Auth Pages Codex Restyle Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle all four AshAuthentication auth pages (`/register`, `/sign-in`, `/reset`, confirm) into the site's Codex design language using a split-editorial LiveView layout plus `AuthOverrides`, and remove the stray "Ash Framework" banner logo.

**Architecture:** A new `VerscientaWeb.Layouts.auth/1` LiveView layout renders a two-column split (left brand/value panel, right form column). It is wired into each auth route via the macros' `:layout` option, so it nests inside the existing root layout (header/footer chrome stay). `AuthOverrides` restyles the Ash form internals (inputs, buttons, links, root containers) to Codex tokens and nils the banner image.

**Tech Stack:** Phoenix 1.8 LiveView, Ash 3 / AshAuthentication.Phoenix, Tailwind v4 (Codex `@theme` tokens), DaisyUI (base layer, kept as fallback). Tests via ExUnit `ConnCase`. Runs in Docker container `news-verscienta-app-1`.

**Design deviation flagged for sign-off:** The approved mockup showed a small "create account" heading in the right column. Because `/register` and `/sign-in` are one `SignInLive` that toggles forms client-side, a static heading can't be correct for both, and the per-form `<h2>` is disabled in this setup. This plan keeps the **left panel as the page hero** and the right column fields-only. If you want toggling per-form headings instead, say so before execution.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `lib/verscienta_web/components/layouts.ex` | Adds `auth/1` layout fn (split shell) | Modify |
| `lib/verscienta_web/router.ex` | Adds `layout:` to auth route macros | Modify (lines ~204–232) |
| `lib/verscienta_web/auth_overrides.ex` | Codex restyle of Ash form internals + nil banner image | Modify |
| `test/verscienta_web/auth_chrome_test.exs` | Asserts split panel renders, no Ash logo, Codex classes present | Create |

## Conventions used by every command below

This worktree runs mix through the shared dev container. **Worktree name:** `modest-tereshkova-1b1678`. Run every `mix` command as (PowerShell tool avoids path mangling):

```bash
MSYS_NO_PATHCONV=1 docker exec \
  -e MIX_DEPS_PATH=/workspace/deps \
  -e MIX_BUILD_ROOT=/workspace/_build/wt-modest \
  -e MIX_TEST_PARTITION=_wt_modest \
  -w /workspace/.claude/worktrees/modest-tereshkova-1b1678 \
  news-verscienta-app-1 mix <args>
```

Shorthand below: `MIX = docker exec … news-verscienta-app-1 mix`. If a new test DB fails with a `template1 ... collation version mismatch`, run once:
`docker exec news-verscienta-db-1 psql -U postgres -c "ALTER DATABASE template1 REFRESH COLLATION VERSION"`.

---

## Task 1: Split auth layout + remove the Ash banner logo

**Files:**
- Modify: `lib/verscienta_web/components/layouts.ex` (add `auth/1` after `app/1`, ~line 27)
- Modify: `lib/verscienta_web/router.ex` (auth macros, ~lines 204–232)
- Modify: `lib/verscienta_web/auth_overrides.ex`
- Test: `test/verscienta_web/auth_chrome_test.exs` (create)

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/auth_chrome_test.exs`:

```elixir
defmodule VerscientaWeb.AuthChromeTest do
  use VerscientaWeb.ConnCase, async: true

  describe "auth pages use the Codex split layout" do
    test "register page shows the brand panel and drops the Ash logo", %{conn: conn} do
      html = get(conn, ~p"/register") |> html_response(200)

      # Left brand panel copy
      assert html =~ "wellness, evidence-first."
      assert html =~ "journalism you can trust"
      # Codex accent bar / panel container marker
      assert html =~ "auth-brand-panel"

      # The Ash Framework banner logo must be gone
      refute html =~ "ash-hq.org"
      refute html =~ "ash-framework-light.png"
    end

    test "sign-in and reset render the same brand panel", %{conn: conn} do
      for path <- ["/sign-in", "/reset"] do
        html = get(conn, path) |> html_response(200)
        assert html =~ "wellness, evidence-first.", "missing brand panel on #{path}"
        refute html =~ "ash-hq.org", "ash logo leaked on #{path}"
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `MIX test test/verscienta_web/auth_chrome_test.exs`
Expected: FAIL — `html` contains `ash-hq.org` and does not contain `"wellness, evidence-first."`.

- [ ] **Step 3: Add the `auth/1` layout function**

In `lib/verscienta_web/components/layouts.ex`, add immediately after the `app/1` function (after its closing `end`, ~line 27):

```elixir
  @doc """
  Layout for the AshAuthentication pages (sign-in, register, reset, confirm).

  Renders a two-column split: a brand/value panel on the left and the auth
  form (`@inner_content`) on the right. Sits inside the root layout, so the
  site header and footer still render around it.
  """
  def auth(assigns) do
    ~H"""
    <div class="flex min-h-screen flex-col pt-14 sm:flex-row">
      <aside
        id="auth-brand-panel"
        class="flex flex-col justify-center gap-5 border-line bg-canvas-2 px-6 py-12 sm:w-2/5 sm:border-r sm:px-10 lg:px-16"
      >
        <span aria-hidden="true" class="block h-1 w-8 bg-zune"></span>
        <a href="/" class="text-sm font-extrabold lowercase tracking-wide text-ink">
          verscienta<span class="text-zune">·</span>news
        </a>
        <h1 class="font-sans text-4xl font-extralight lowercase leading-[0.95] tracking-tight text-ink sm:text-5xl">
          wellness,<br />evidence-first.
        </h1>
        <p class="hidden max-w-xs text-sm leading-relaxed text-ink-3 sm:block">
          herbalism, nutrition, movement, mind, and more — journalism you can trust.
          create a free account to join the conversation.
        </p>
      </aside>

      <div class="flex flex-1 items-center justify-center px-6 py-12">
        <div class="w-full max-w-sm">
          <.flash_group flash={@flash} />
          {@inner_content}
        </div>
      </div>
    </div>
    """
  end
```

- [ ] **Step 4: Wire the layout into the auth routes**

In `lib/verscienta_web/router.ex`, add `layout: {VerscientaWeb.Layouts, :auth}` to each auth macro, preserving every existing option. Replace the block at ~lines 204–232 with:

```elixir
    sign_in_route register_path: "/register",
                  reset_path: "/reset",
                  auth_routes_prefix: "/auth",
                  layout: {VerscientaWeb.Layouts, :auth},
                  on_mount: [
                    {VerscientaWeb.LiveUserAuth, :live_no_user},
                    {VerscientaWeb.LiveUserAuth, :capture_client_ip}
                  ],
                  overrides: [
                    VerscientaWeb.AuthOverrides,
                    Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI
                  ]

    # Remove this if you do not want to use the reset password feature
    reset_route auth_routes_prefix: "/auth",
                layout: {VerscientaWeb.Layouts, :auth},
                on_mount: [{VerscientaWeb.LiveUserAuth, :capture_client_ip}],
                overrides: [
                  VerscientaWeb.AuthOverrides,
                  Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI
                ]

    # Remove this if you do not use the confirmation strategy
    confirm_route Verscienta.Accounts.User, :confirm_new_user,
      auth_routes_prefix: "/auth",
      layout: {VerscientaWeb.Layouts, :auth},
      overrides: [VerscientaWeb.AuthOverrides, Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI]

    confirm_route Verscienta.Accounts.User, :confirm_email_change,
      as: :auth_email_change,
      auth_routes_prefix: "/auth",
      layout: {VerscientaWeb.Layouts, :auth},
      overrides: [VerscientaWeb.AuthOverrides, Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI]
```

- [ ] **Step 5: Nil the Ash banner image in AuthOverrides**

In `lib/verscienta_web/auth_overrides.ex`, replace the existing Banner override so the Ash logo is removed and the in-form banner is hidden (the left panel now carries the brand):

```elixir
defmodule VerscientaWeb.AuthOverrides do
  @moduledoc "AshAuthentication UI overrides — Codex theming."
  use AshAuthentication.Phoenix.Overrides

  alias AshAuthentication.Phoenix.{Components, ConfirmLive, ResetLive, SignInLive}

  # The split layout's left panel carries the brand, so hide the in-form banner
  # entirely and strip the Ash Framework logo URLs.
  override Components.Banner do
    set :root_class, "hidden"
    set :image_url, nil
    set :dark_image_url, nil
    set :text, nil
    set :text_class, nil
  end
end
```

Note: `SignInLive`, `ResetLive`, `ConfirmLive`, and `Components` are aliased now so Task 2 can extend this module without touching the alias line.

- [ ] **Step 6: Run the test to verify it passes**

Run: `MIX test test/verscienta_web/auth_chrome_test.exs`
Expected: PASS (3 assertions across 2 tests). If the brand-panel assertions pass but `ash-hq.org` still appears, confirm `AuthOverrides` is listed **before** the DaisyUI override in every route (it is, per Step 4).

- [ ] **Step 7: Commit**

```bash
git add lib/verscienta_web/components/layouts.ex lib/verscienta_web/router.ex \
        lib/verscienta_web/auth_overrides.ex test/verscienta_web/auth_chrome_test.exs
git commit -m "feat(auth): split-editorial Codex layout for auth pages; drop Ash logo"
```

---

## Task 2: Codex restyle of the Ash form internals

Restyle inputs, buttons, links, and root containers to Codex tokens via `AuthOverrides`. The override keys/modules mirror `deps/ash_authentication_phoenix/lib/ash_authentication_phoenix/overrides/daisy_ui.ex`; `AuthOverrides` wins because it is first in each route's `overrides:`.

**Files:**
- Modify: `lib/verscienta_web/auth_overrides.ex`
- Test: `test/verscienta_web/auth_chrome_test.exs` (add a describe block)

- [ ] **Step 1: Write the failing test**

Append to `test/verscienta_web/auth_chrome_test.exs`, inside the module:

```elixir
  describe "auth form internals use Codex tokens" do
    test "inputs, submit button and toggle links carry Codex classes", %{conn: conn} do
      html = get(conn, ~p"/register") |> html_response(200)

      # Inputs: Codex field styling, full width, no leftover daisyUI-only look
      assert html =~ "border-line"
      assert html =~ "bg-canvas"
      assert html =~ "w-full"

      # Submit button: zune Codex button
      assert html =~ "bg-zune"

      # The full-screen daisyUI grid wrapper must be gone
      refute html =~ "grid h-screen place-items-center bg-base-100"
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `MIX test test/verscienta_web/auth_chrome_test.exs -o "describe:auth form internals use Codex tokens"`
(or run the whole file). Expected: FAIL — `bg-zune` absent and `grid h-screen place-items-center bg-base-100` still present (from the DaisyUI `*Live` root_class).

- [ ] **Step 3: Add the Codex form overrides**

In `lib/verscienta_web/auth_overrides.ex`, add these overrides after the `Components.Banner` override (before the final `end`). The input/button/link classes use Codex tokens defined in `assets/css/app.css`:

```elixir
  # --- Live roots: drop the full-screen daisyUI grid; the layout owns centering ---
  override SignInLive do
    set :root_class, "w-full"
  end

  override ResetLive do
    set :root_class, "w-full"
  end

  override ConfirmLive do
    set :root_class, "w-full"
  end

  # --- Component wrappers: remove daisyUI flex/py framing, keep a centered column ---
  override Components.SignIn do
    set :root_class, "w-full"
    set :strategy_class, "mx-auto w-full"
    set :authentication_error_container_class, "text-politics text-center text-sm"
    set :authentication_error_text_class, ""
    set :strategy_display_order, :forms_first
  end

  override Components.Reset do
    set :root_class, "w-full"
    set :strategy_class, "mx-auto w-full"
  end

  override Components.Confirm do
    set :root_class, "w-full"
    set :strategy_class, "mx-auto w-full"
  end

  # --- Password container + toggle links (forgot / already-have-an-account) ---
  override Components.Password do
    set :root_class, "w-full"

    set :interstitial_class,
        "flex flex-row justify-between content-between text-xs mt-4"

    set :toggler_class,
        "flex-none text-zune hover:text-ink px-2 first:pl-0 last:pr-0 lowercase"

    set :sign_in_toggle_text, "already have an account?"
    set :register_toggle_text, "need an account?"
    set :reset_toggle_text, "forgot your password?"
  end

  # --- Inputs: Codex field styling, full width ---
  override Components.Password.Input do
    set :field_class, "mb-3"
    set :label_class, "block text-xs lowercase text-ink-3 mb-1"

    set :input_class,
        "w-full rounded border border-line bg-canvas px-3 py-2 text-sm text-ink " <>
          "placeholder:text-ink-3 focus:border-zune focus:outline-none focus:ring-1 focus:ring-zune"

    set :input_class_with_error,
        "w-full rounded border border-politics bg-canvas px-3 py-2 text-sm text-ink " <>
          "focus:border-zune focus:outline-none focus:ring-1 focus:ring-zune"

    set :submit_class,
        "w-full mt-4 bg-zune px-6 py-3 text-xs font-bold uppercase tracking-wider " <>
          "text-black transition-[filter] hover:brightness-110"

    set :error_ul, "text-politics font-light my-2 text-sm"
    set :error_li, nil
    set :input_debounce, 350

    set :identity_input_label, "email"
    set :password_input_label, "password"
    set :password_confirmation_input_label, "confirm password"
  end

  # --- Confirm + Reset submit buttons (separate components from Password.Input) ---
  override Components.Confirm.Input do
    set :submit_class,
        "w-full mt-4 bg-zune px-6 py-3 text-xs font-bold uppercase tracking-wider " <>
          "text-black transition-[filter] hover:brightness-110"
  end

  override Components.Reset.Form do
    set :label_class, "block text-xs lowercase text-ink-3 mb-1"
    set :spacer_class, "py-1"
  end

  # --- Divider ("or") between strategies ---
  override Components.HorizontalRule do
    set :root_class, "flex items-center gap-3 my-4 text-xs lowercase text-ink-3"
    set :hr_outer_class, "flex-1 border-t border-line"
    set :hr_inner_class, "hidden"
    set :text_outer_class, "contents"
    set :text_inner_class, "contents"
    set :text, "or"
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `MIX test test/verscienta_web/auth_chrome_test.exs`
Expected: PASS (all describe blocks). If `grid h-screen place-items-center bg-base-100` still appears, a `*Live` root_class override is missing — verify all three (`SignInLive`, `ResetLive`, `ConfirmLive`) are present.

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta_web/auth_overrides.ex test/verscienta_web/auth_chrome_test.exs
git commit -m "feat(auth): Codex-style auth inputs, buttons, links and dividers"
```

---

## Task 3: Verification — existing tests, lint, assets, manual

**Files:** none (verification only).

- [ ] **Step 1: Run the full auth + smoke test set (must stay green)**

Run:
```bash
MIX test test/verscienta_web/auth_chrome_test.exs \
         test/verscienta_web/auth_nav_test.exs \
         test/verscienta_web/controllers/auth_controller_test.exs \
         test/verscienta_web/live_user_auth_ip_test.exs \
         test/verscienta_web/smoke/author_journey_test.exs
```
Expected: all PASS. The `live_user_auth_ip_test` passing confirms the `:capture_client_ip` `on_mount` survived the router change. If any fail, capture with `grep -B3 -A20 ') test '` (do **not** pipe through `tail`).

- [ ] **Step 2: Format check**

Run: `MIX format --check-formatted`
Expected: no output, exit 0. If it fails, run `MIX format` and re-commit.

- [ ] **Step 3: Credo (reuse test build to avoid a dev recompile)**

Run: `docker exec -e MIX_ENV=test … news-verscienta-app-1 mix credo lib/verscienta_web/auth_overrides.ex lib/verscienta_web/components/layouts.ex`
Expected: no new issues on the changed files.

- [ ] **Step 4: Rebuild assets so the dev server compiles the new Tailwind classes**

The new Codex classes are already used elsewhere (`bg-zune`, `border-line`, `bg-canvas`), so Tailwind will emit them. Rebuild to be safe:

Run: `MIX tailwind verscienta` then `MIX assets.deploy` is **not** needed in dev; the dev watcher rebuilds. If verifying statically, run `MIX tailwind verscienta` and confirm exit 0.

- [ ] **Step 5: Manual visual verification**

The dev server at `http://localhost:4000` serves the **main** checkout, not this worktree. Two options:
1. Defer pixel verification until after merge, then load `/register`, `/sign-in`, `/reset` at desktop (≥640px) and mobile (<640px) widths. Confirm: no Ash logo; left panel with zune bar + "wellness, evidence-first."; full-width Codex inputs; zune Register button; panel collapses above the form on mobile.
2. Or use the worktree asset + `python -m http.server priv/static` harness (see `verscienta-worktree-mix-recipe` memory) for an isolated preview.

Checklist for the reviewer's eyes:
- [ ] `/register` — no Ash logo; split panel; full-width inputs; zune button; toggle links zune.
- [ ] `/sign-in` — same panel; sign-in form; "need an account?" / "forgot your password?" links styled.
- [ ] `/reset` — same panel; email field + zune submit.
- [ ] Mobile width — panel stacks above the form, subline hidden, no horizontal scroll.

- [ ] **Step 6: Final commit (only if Steps 2–4 required fixes)**

```bash
git add -A
git commit -m "chore(auth): formatting/lint fixups for Codex auth restyle"
```

---

## Self-Review notes (author)

- **Spec coverage:** layout (Task 1 Step 3) ✓; router wiring all 4 macros (Task 1 Step 4) ✓; banner logo removal (Task 1 Step 5) ✓; inputs/labels/buttons/links/divider/root_class (Task 2) ✓; preserve `on_mount` + opts (Task 1 Step 4, verified by Task 3 Step 1) ✓; new render assertions + existing tests (Tasks 1–3) ✓; responsive (Task 1 Step 3 `sm:` classes; Task 3 Step 5 manual) ✓.
- **Deviation:** right-column per-page heading omitted by design (see header note) — pending user sign-off.
- **Type/key consistency:** override module names and keys match `daisy_ui.ex` exactly (`Components.Password.Input`, `Components.Confirm.Input`, `Components.Reset.Form`, `Components.HorizontalRule`, `SignInLive`/`ResetLive`/`ConfirmLive`).
