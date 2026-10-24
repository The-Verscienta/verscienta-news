# Auth pages — Codex split-editorial restyle

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-16
**Status:** Approved design, pending implementation plan

## Problem

The AshAuthentication-generated auth pages (`/register`, `/sign-in`, `/reset`, and
the confirm routes) render in a generic DaisyUI visual language that clashes with
the rest of the site:

- The DaisyUI override base
  (`deps/ash_authentication_phoenix/.../overrides/daisy_ui.ex`) sets the banner
  image to the **"Ash Framework" logo**, which overlaps the `verscienta·news`
  wordmark our local `AuthOverrides` sets as banner text.
- The pages use DaisyUI tokens (`bg-base-100`, `btn-primary`, a centered
  `grid h-screen place-items-center` card) instead of the site's **Codex** design
  language (`bg-canvas`, `text-ink`/`ink-2`/`ink-3`, `border-line`, `bg-zune`
  accent, lowercase extralight typography).

The site header/footer chrome already wraps these pages correctly; only the form
area and banner are off-brand.

## Goal

Restyle all four auth pages into the Codex language using a **split-editorial**
layout: a brand/value panel on the left and the auth form on the right. Keep
AshAuthentication's LiveViews intact — drive everything through a custom LiveView
layout plus the existing `AuthOverrides` mechanism.

## Design decisions (resolved during brainstorming)

| Decision | Choice |
|---|---|
| Layout direction | **C — Split editorial** (brand panel + form) |
| Page scope | **All auth pages**: register, sign-in, reset, confirm (both confirm routes) |
| Left panel content | **Wordmark + tagline copy** (flat `canvas-2` + zune accent bar) |
| Panel copy | **B — descriptive/editorial** (see below) |

### Left-panel copy

- Wordmark: `verscienta·news` (zune middot, matching the header).
- Headline (lowercase, extralight): **"wellness, evidence-first."**
- Subline: **"herbalism, nutrition, movement, mind, and more — journalism you can
  trust. create a free account to join the conversation."**
  (Derived from the site SEO description in `lib/verscienta_web/seo.ex`.)
- A zune accent bar (`bg-zune`, ~30×4px) above the headline.

## Architecture

Render order (outermost → innermost):

```
root.html.heex (fixed header + footer chrome)
  └─ Layouts.auth/1  (split shell: left brand panel | right form column)
       └─ Ash auth LiveView (SignInLive / ResetLive / ConfirmLive form)
```

### 1. New auth layout — `VerscientaWeb.Layouts.auth/1`

Added to `lib/verscienta_web/components/layouts.ex` (embedded alongside `app/1`).

- Two-column container (CSS grid/flex) with a sensible min-height so it fills the
  viewport between the fixed header and the footer.
- **Left panel**: `bg-canvas-2`, right `border-line` divider, vertically centered.
  Contains the zune accent bar, wordmark, headline, and subline. On `< sm` it
  collapses to stack above the form, showing only the accent bar + headline
  (subline hidden) to stay compact.
- **Right column**: renders `<.flash_group flash={@flash} />` and
  `{@inner_content}` (the Ash form), vertically centered, constrained to
  ~`max-w-sm`, with comfortable padding.

### 2. Router wiring

In `lib/verscienta_web/router.ex`, add `layout: {VerscientaWeb.Layouts, :auth}` to:

- `sign_in_route` (covers `/sign-in` and `/register`)
- `reset_route`
- `confirm_route` for `:confirm_new_user`
- `confirm_route` for `:confirm_email_change`

All existing options must be preserved verbatim when adding `layout:`:

- `sign_in_route`: `register_path`, `reset_path`, `auth_routes_prefix`, the
  `on_mount` hooks (`{LiveUserAuth, :live_no_user}`,
  `{LiveUserAuth, :capture_client_ip}`), and `overrides`.
- `reset_route` / `confirm_route`s: `auth_routes_prefix`, any `on_mount`, `as`,
  and `overrides`.

The macros support `:layout` directly (`Keyword.pop(opts, :layout)` → passed to
the generated `live_session`), confirmed in
`deps/ash_authentication_phoenix/lib/ash_authentication_phoenix/router.ex`.

### 3. AuthOverrides — Codex restyle of form internals

Extend `lib/verscienta_web/auth_overrides.ex`. `AuthOverrides` is listed **first**
in every route's `overrides:`, so its `set` values win over the DaisyUI base.

- **Banner**: set `image_url` and `dark_image_url` to `nil` (removes the Ash
  logo). The left panel carries the brand, so the in-form banner can be hidden or
  reduced to nothing visually intrusive.
- **Live `root_class`** (SignIn / Reset / Confirm Live components): replace the
  DaisyUI `grid h-screen place-items-center bg-base-100` with a right-column fit
  (`w-full`, appropriate spacing). The layout owns centering and background.
- **Inputs** (`Components.Password.Input` etc.): `w-full` plus Codex field style —
  `bg-canvas border border-line` rounded, `text-ink`, zune focus ring; error
  variant uses `border-politics` instead of `input-error`.
- **Labels**: small, lowercase, `text-ink-3`.
- **Submit buttons**: Codex button —
  `bg-zune text-black uppercase tracking-wider font-bold hover:brightness-110`
  (matches `CodexComponents.button/1`).
- **Links** (forgot password / already-have-an-account / register / reset):
  `text-zune hover:text-ink`.
- **Divider**: `border-line`.

Exact override target modules/keys to be confirmed against
`deps/ash_authentication_phoenix/.../overrides/daisy_ui.ex` during implementation
(it enumerates every overridable component and key).

## Responsive behavior

- `≥ sm`: two columns, left panel ~40–44% width.
- `< sm`: single column. Left panel stacks above the form showing accent bar +
  headline only; subline hidden. Form spans full width with padding.

## Testing & verification

- **Existing tests must still pass** — `auth_nav_test.exs`,
  `controllers/auth_controller_test.exs`, and the smoke author-journey assert flow
  and behavior, not styling. Run them to confirm the restyle is non-breaking.
- **New assertions**: `/register`, `/sign-in`, `/reset` render the new panel
  headline ("wellness, evidence-first.") and **do not** reference the
  `ash-hq.org` logo URL.
- **Manual verification** against the running dev server (`localhost:4000`, now
  past the pending migration) at desktop and mobile widths.
- Run the standard verification loop (`mix compile`, `format`, `credo`, relevant
  tests) per project conventions, in the Docker app container.

## Risks / notes

- Preserve the `on_mount` hooks when adding `layout:` to `sign_in_route` — losing
  `:live_no_user` would let signed-in users hit the auth forms, and losing
  `:capture_client_ip` would break IP capture relied on by
  `live_user_auth_ip_test.exs`.
- The DaisyUI base override remains second in the `overrides:` list as a fallback
  for any component key we don't explicitly override, avoiding unstyled elements.
- CSS source scanning: `assets/css/app.css` already has
  `@source "../../deps/ash_authentication_phoenix"`, and the Codex tokens are
  defined in the `@theme` block, so all classes used here will compile.

## Out of scope

- Changing `core_components.ex` form inputs (used elsewhere) — only auth pages.
- Feature-bullet or category-collage panel variants (considered, not chosen).
- Any change to authentication logic, strategies, or routes beyond `layout:`.
