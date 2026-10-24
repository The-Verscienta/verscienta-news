# Cross-Cutting MVP Polish Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-01
**Status:** Approved
**Phase:** 1 (MVP) — Cross-cutting polish (post-subsystems)
**Depends on:** All 6 Phase 1 subsystems (merged to main). No new domains/resources.

## Goal

Production-readiness polish across the whole app: Codex-styled error pages, a responsive
mobile navigation, a targeted accessibility pass, and an admin-gated LiveDashboard. No new
business logic; no migrations.

## Decisions

| Decision | Choice |
|----------|--------|
| Error pages | Codex **giant-bleed** style; static, self-contained (no app layout/JS) |
| Mobile nav | Hamburger drawer via **`Phoenix.LiveView.JS.toggle/1`** (client-side, no server state, no custom JS hook) |
| Accessibility | Targeted "pass, not perfection": global focus-visible ring, nav ARIA, control audit, landmark/heading sanity |
| LiveDashboard | Admin-gated at `/dev/dashboard` (reuse `:admin` role pattern) |
| Deferred | Sentry (needs DSN → deployment); full WCAG cert; demo seeds + per-flow tests (already substantially done — mark in todo) |

## Section 1: Styled error pages (404/500)

`VerscientaWeb.ErrorHTML` currently returns plain status text. Change it to render Codex-styled
templates:
- Add `embed_templates "error_html/*"` to `lib/verscienta_web/controllers/error_html.ex`.
- Create `error_html/404.html.heex` and `error_html/500.html.heex` — each a **complete, self-contained**
  HTML document (error rendering does NOT pass through the root layout or asset pipeline, so styles
  must be inlined). Giant-bleed treatment: dark canvas `#0c0c0c`, Hanken Grotesk (system fallback if
  the self-hosted font isn't linked on an error page — use `font-family` stack), a 200-weight lowercase
  headline ("not found" / "something went wrong"), zune `#f2660a` accent, a "← back to the feed" link
  (`/articles`) on 404 and a home link on 500.
- Keep a fallback `render(template, _assigns)` clause delegating to
  `Phoenix.Controller.status_message_from_template/1` for all other status codes.

Inline CSS (a small `<style>` in each template) keeps the page working even when the asset
pipeline/CDN is unavailable. No JS.

## Section 2: Responsive mobile nav

In `lib/verscienta_web/components/layouts/root.html.heex`:
- Wrap the existing inline links in a container that is `hidden sm:flex` (desktop: unchanged inline row).
- Add a hamburger `<button>` visible only on mobile (`sm:hidden`), `type="button"`,
  `aria-label="menu"`, `aria-controls="mobile-menu"`, `aria-expanded="false"`, with
  `phx-click={JS.toggle(to: "#mobile-menu")}` (and optionally toggle `aria-expanded`).
- Add a `#mobile-menu` drawer: a vertical stack of the same links, `hidden sm:hidden` by default
  (so it's hidden on desktop always, and hidden on mobile until toggled). `JS.toggle` flips its
  visibility. The drawer mirrors the auth-aware link set (signed-in vs signed-out, admin-only admin link).
- `import Phoenix.LiveView.JS` (or alias) at the top of the layout module if needed —
  `root.html.heex` is rendered by `VerscientaWeb.Layouts`; `JS` is available in HEEx via
  `Phoenix.LiveView.JS`. Use the fully-qualified `Phoenix.LiveView.JS.toggle/1` to avoid import questions.
- Because `JS.toggle` is purely client-side, NO LiveView mount/assign changes are needed — this works
  identically on controller-rendered pages (home, styleguide, error) and all LiveViews.
- The nav `<nav>` gets `aria-label="primary"`.

NOTE: `root.html.heex` has no `@socket`/JS commands today. `Phoenix.LiveView.JS.toggle/1` returns a
JS struct usable in `phx-click` on any Phoenix-rendered page (the `phoenix_html`/`phoenix_live_view`
JS runtime is loaded via `app.js` on every page through the root layout's `<script>`). Confirm the
toggle works on a plain controller page (the home page) during testing.

## Section 3: Accessibility pass (targeted)

- **Focus visibility:** add a global `:focus-visible` outline in `assets/css/app.css` using the zune
  accent (e.g. `*:focus-visible { outline: 2px solid #f2660a; outline-offset: 2px; }`), so keyboard
  focus is visible on links/buttons/inputs everywhere.
- **Nav ARIA:** `<nav aria-label="primary">` + the hamburger button attributes (Section 2).
- **Control audit:** verify interactive controls are real `<button>`/`<a>` (reader reactions/bookmark/
  delete, editor add-block/move/delete, admin fetch-now, search facets). They already are — fix any
  that aren't; document findings.
- **Images:** block-renderer `image` already emits `alt`; confirm the editor lets authors set it
  (known follow-up if not — note, don't expand scope).
- **Landmarks/headings:** ensure each main page has a single `<h1>`-equivalent headline and content
  sits in `<main>` or `<article>`. Add a `<main>` wrapper in the root layout around `{@inner_content}`
  if not present (improves landmark navigation site-wide).
- Scope: this is a focus-states + ARIA + landmark sweep with a documented fix-list, not a formal
  WCAG AA audit.

## Section 4: LiveDashboard (admin-gated)

`phoenix_live_dashboard` is already a dependency and there is an existing dev-only `/dev/dashboard`
route behind `Application.compile_env(:verscienta, :dev_routes)` (from the Phoenix generator). Make it
**admin-accessible in all environments**, gated:
- In `lib/verscienta_web/router.ex`, add a `/dev/dashboard` live_dashboard route guarded so only
  `:admin` users reach it. Reuse the authenticated live session + an admin on_mount check (mirror the
  `AdminSourcesLive` 404-for-non-admin pattern) OR keep the existing dev-routes block for dev and add a
  separate admin-guarded mount for prod. Simplest: a small plug/on_mount that halts non-admins.
- Include the Oban, Ecto, and Phoenix telemetry pages (LiveDashboard auto-includes metrics from
  `VerscientaWeb.Telemetry`).
- Keep the Swoosh mailbox preview dev-only (unchanged).

NOTE: `live_dashboard` uses its own session/layout. The cleanest admin gate is a `Plug` in a dedicated
pipeline that checks `conn.assigns.current_user.role == :admin` (the browser pipeline already runs
`load_from_session`). Implement an `:admin_required` plug and `pipe_through [:browser, :admin_required]`
for the dashboard scope. Confirm a non-admin gets redirected/404 and an admin gets in.

## Section 5: Testing & gates

- `ErrorHTMLTest`: rendering `"404.html"` and `"500.html"` returns the Codex copy (e.g. "not found",
  "back to the feed"; "something went wrong"). The existing error tests (if any) updated to match.
- Nav: a ConnCase/LiveView test asserting the mobile hamburger button (`aria-label="menu"`) and the
  `#mobile-menu` drawer markup are present, and the desktop link container exists. (JS.toggle behavior
  itself isn't unit-tested; assert the markup + attributes.)
- LiveDashboard gate: a non-admin (and signed-out) request to `/dev/dashboard` is denied
  (redirect/404); an admin reaches it (status 200 or live mount ok).
- All existing CI gates (`compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`,
  `test`) stay green. No migrations.

## Out of Scope (deferred)

- Sentry error tracking (needs a DSN — deployment phase).
- Full WCAG AA audit / automated a11y testing (axe, etc.).
- Demo seeds + "tests for each major flow" — already substantially covered by the 6 subsystems; mark
  the todo items accordingly rather than redo.
- Dark-mode toggle UI (the canvas is dark by default; no light/dark switch in MVP).
- Telemetry → Prometheus/Grafana export (deployment/monitoring phase).

## Definition of Done

- 404 and 500 render Codex-styled, self-contained pages (verified by test + a manual hit).
- The top nav collapses to a working hamburger drawer on mobile and stays an inline strip on desktop,
  on both controller-rendered and LiveView pages; nav has proper ARIA.
- Keyboard focus is visibly indicated app-wide; main pages have a `<main>` landmark; the control audit
  fix-list is applied.
- `/dev/dashboard` is reachable by admins and denied to everyone else.
- All tests pass; CI green; no new migrations; work committed on `polish-cross-cutting`.
- `docs/todo.md` cross-cutting items checked off (or marked deferred for Sentry).
