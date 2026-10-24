# Compliance & Trust — Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-11
**Scope:** Phase 4 "Compliance & Trust" todo items. Account deletion (30-day
soft-delete + anonymization) already shipped; this covers the rest.

> **Note:** This work was sliced and decided autonomously per the session
> instruction ("work on these todo items, if you want to slice them, go
> ahead"). Decisions that need a human call are flagged inline with ⚖️.

## Goals

1. **Legal pages** — Terms of Service, Privacy Policy, Cookie Policy, Medical
   Disclaimer as server-rendered static pages with a site footer linking them.
2. **Medical disclaimer system** — a reusable disclaimer component shown on
   every article in a health-related category, linking to the full page.
3. **Consent management + cookie banner** — explicit opt-in for analytics,
   recorded in a cookie (anonymous) and on the user record (signed in),
   default-deny, gating both anonymous and signed-in behavioral analytics.
4. **GDPR/CCPA data export** — authenticated, rate-limited JSON download of all
   personal data we hold.
5. **Signed Cloudflare Image URLs** — HMAC-signed delivery URLs generated at
   render time when a signing key is configured.

## Non-goals

- Legal review itself (⚖️ the page texts are drafts; a lawyer must review
  before launch — tracked in `docs/todo.md`).
- Gating *operational* server events (signup, article_published, follow) —
  these are treated as legitimate-interest operational telemetry and disclosed
  in the Privacy Policy. Behavioral events (views, shares, searches) are
  consent-gated.
- CCPA "do not sell" tooling beyond the export + deletion + consent controls
  (we don't sell data; policy states it).

## Slice A — Legal pages, footer, medical disclaimer

- `Verscienta.Legal` (lib/verscienta/legal.ex): `policy_version/0` returns the
  current policy date string (`"2026-06-11"`); bumping it is the lever for
  future re-consent. `medical_disclaimer_category?/1` returns true for all
  article categories except `:environment`.
- `VerscientaWeb.LegalController` + `LegalHTML` with templates:
  - `GET /terms`, `GET /privacy`, `GET /cookies`, `GET /medical-disclaimer`
  - Each shows "Last updated" from `Legal.policy_version/0`.
- Site footer (in `root.html.heex`, below `<main>`): links to the four pages,
  lowercase styling matching the header.
- `VerscientaWeb.LegalComponents.medical_disclaimer/1` — bordered callout used
  by `ArticleReaderLive` when `Legal.medical_disclaimer_category?(category)`.

## Slice B — Consent management + cookie banner

**Cookie:** `_verscienta_consent`, value `v1:all` or `v1:essential`,
max-age 365 days, SameSite=Lax. Not signed — tampering only toggles one's own
analytics. The `v1` prefix is `Legal.policy_version/0`-independent (cookie
consent re-prompts only if we bump the cookie schema, not the policy text).

**Plugs** (browser pipeline, before `AnalyticsId`):
- `VerscientaWeb.Plugs.Consent`: reads the cookie → assigns
  `:consent` (`:all | :essential | :unset`). When not `:all`, deletes any
  existing `:analytics_id` from the session (revocation works retroactively).
- `VerscientaWeb.Plugs.AnalyticsId` (modified): only generates/assigns an
  anonymous id when `conn.assigns.consent == :all`.

**Controller:** `POST /consent` (`ConsentController.update`, CSRF-protected)
with `choice=all|essential`. Sets the cookie; if signed in, also records the
choice on the user (`:update_consent` action); redirects back to the referer
(fallback `/`).

**User record:** new `consents :map` attribute (default `%{}`), e.g.
`%{"analytics" => true, "version" => "2026-06-11", "at" => "...iso8601..."}`
written by a new `:update_consent` action (actor must be the user). This is
the auditable consent record for signed-in users.

**Banner:** rendered in `root.html.heex` when `@consent == :unset` (assign is
absent in LiveView renders of the inner layout — the banner lives in the root
layout, which is rendered on every dead render; the two buttons are plain
form POSTs so the page fully reloads and the banner disappears).

**Analytics gating (signed in):** `Analytics.distinct_id/2` returns the user
id only when `user.consents["analytics"] == true`, else falls through to the
(consent-gated) anonymous id, else `nil`; `Analytics.capture/3` with a `nil`
distinct_id is a no-op. Net effect: behavioral events (article views, shares,
searches) fire only with consent, anonymous or signed in. Default is deny for
everyone, including pre-existing users.

**Settings:** new "privacy" section showing the user's recorded consent with a
LiveView toggle that writes via `:update_consent` (plain-form POSTs from a
live render would need CSRF tokens minted in the conn process, so the cookie
is left to the banner; the DB record is checked first by `distinct_id/2` and
therefore wins for signed-in tracking either way), links to the policies, and
the data-export download.

## Slice C — GDPR data export

- `Verscienta.Accounts.DataExport.build(user) :: map` — assembles, with
  `authorize?: false` and explicit `user.id` filters: profile fields, consents,
  notification prefs, authored articles (full content blocks), comments,
  bookmarks, reactions, follows (both directions), points entries, badges,
  expert application. Tokens/hashed password are never exported.
- `GET /settings/export` (`ExportController.show`): requires `current_user`
  (redirects to sign-in otherwise), rate-limited via a new
  `Verscienta.RateLimit` bucket `data_export_user: {86_400_000, 3}` (3/day),
  responds with `send_download` of pretty-printed JSON named
  `verscienta-export-<date>.json`. 429 with flash redirect when limited.
- Link from the settings privacy section.

## Slice D — Signed Cloudflare image URLs

- New optional config `:cloudflare_images_signing_key` (env
  `CLOUDFLARE_IMAGES_SIGNING_KEY`) in runtime.exs.
- `Verscienta.Images.signed_url(url, opts \\ [])`:
  - `nil` → `nil`; non-`imagedelivery.net` URLs → unchanged (placeholders,
    external images).
  - `imagedelivery.net` URLs → when a signing key is configured, append
    `exp` (now + `:ttl`, default 24h) and `sig` = lowercase hex
    HMAC-SHA256 over `"#{path}?exp=#{exp}"` (Cloudflare's documented scheme);
    unchanged when no key.
- Enforced at every render site of stored image URLs:
  `MediaComponents.image_upload_field` preview, `ProfileLive` avatar,
  `ArticleEditorLive` image-block preview, `SEO` og:image (30-day TTL so
  crawler caches don't break). Stored values stay unsigned; signing happens at
  render time only.
- ⚖️ Flipping "require signed URLs" on the Cloudflare variants is an ops task
  once `CLOUDFLARE_IMAGES_SIGNING_KEY` is deployed; documented in todo.md.

## Testing

- Controller tests: legal pages render; consent POST sets cookie/records user
  consent; export requires auth, rate-limits, returns the user's data and not
  others'.
- Plug tests: consent assign matrix; analytics id created only with consent;
  session id dropped on revocation.
- Unit: `Images.signed_url/2` (nil/foreign/unsigned/signed shapes, TTL),
  `Analytics.distinct_id/2` consent matrix, `DataExport.build/1` content.
- LiveView: reader shows the medical disclaimer for `:nutrition`, not for
  `:environment`; settings shows privacy section.

## Migration

One Ash codegen migration: `consents :map` on `users`.
