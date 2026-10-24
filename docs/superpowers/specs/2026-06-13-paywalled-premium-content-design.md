# Paywalled Premium Content — Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-13
**Todo item:** Phase 4 → Monetization → "Paywalled / premium content tiers"
**Builds on:** [Premium Subscriptions (PayPal billing)](2026-06-11-premium-subscriptions-design.md) — that
spec shipped the billing machinery and `Accounts.premium?/1`; this spec is the content-gating
consumer it was built for.

## Goal

An author can mark an article **premium**. Non-entitled readers see a teaser (cover, title,
excerpt) plus an upgrade call-to-action instead of the body; entitled readers (active premium
subscribers), the author, and admins/mods see the full article. The whole feature sits behind an
off-by-default `:paywall` feature flag.

## Decisions (locked during brainstorming)

- **Paywall model:** hard gate (full body lock), not metered and not a freemium split.
- **Marking:** per-article author toggle (a boolean on `Article`), set in the editor like
  draft/publish — not editorial-curated-only, not role-derived.
- **Discovery & SEO:** premium articles stay discoverable everywhere (feeds, search, category
  pages, sitemap) as teasers with a "Premium" badge; crawlers get Google-compliant paywall
  structured data so the hard gate is not read as cloaking.
- **Enforcement site:** the reader LiveView is the security boundary (Approach A) — not an Ash
  field policy, not split content storage.
- **Tier shape:** a single boolean `premium?`, not a tier enum (YAGNI; revisit when a second tier
  exists).

## Scope

In scope:

- `premium?` boolean attribute on `Article` (author-writable; default `false`).
- A single entitlement helper `Content.body_visible?(article, actor)` — the only place the access
  rule lives.
- Reader gating in `ArticleReaderLive`: strip `blocks` from socket assigns for gated reads; render
  teaser + upgrade panel.
- Editor toggle in `ArticleEditorLive`, shown only when the `:paywall` flag is on for the author.
- "Premium" badge on card/list surfaces.
- Paywall-compliant JSON-LD in the SEO layer for gated articles.
- `:paywall` feature flag (off by default) wired through `Verscienta.Flags` + `flags/seeds.ex`.
- Tests across all of the above.

Out of scope (explicitly):

- Metered paywall (N free reads/month) and freemium per-section splits — rejected in favor of a
  hard gate.
- Multiple premium tiers / a tier enum.
- Sponsored content, affiliate links, featured/promoted challenges — each a separate monetization
  spec.
- Any change to the billing/checkout flow itself (already shipped).
- Per-group or per-category premium policies.

## Approach (A — reader-level gate + single entitlement helper)

The security boundary is the point of render: gated bodies must never enter socket assigns or the
rendered HTML for a non-entitled reader. Discovery surfaces already render from `card_fields/0`
(which excludes `blocks`), so teasers leak nothing by construction.

### 1. Data model

- Add to `Article` ([`lib/verscienta/content/article.ex`](../../../lib/verscienta/content/article.ex)):

  ```elixir
  attribute :premium?, :boolean, allow_nil?: false, default: false, public?: true
  ```

- Add `:premium?` to the `@card_fields` list so teaser surfaces can badge without loading bodies.
- One migration adds the `premium` boolean column with default `false`; all existing articles
  remain free.
- The attribute is writable through the existing `:create`/`:update` (and draft/publish) actions —
  no new action.

### 2. Entitlement helper — single decision point

A pure function in the `Content` domain:

```elixir
@doc "Whether `actor` may see the full body of `article`."
def body_visible?(article, actor) do
  cond do
    not Verscienta.Flags.enabled?(:paywall) -> true   # kill switch / billing-not-configured safety
    not article.premium?                    -> true
    author_or_staff?(article, actor)        -> true
    Verscienta.Accounts.premium?(actor)     -> true
    true                                    -> false
  end
end
```

`author_or_staff?/2` returns true when the actor is the article's author, or has role `:moderator`
or `:admin` (the same `^actor(:role) in [:moderator, :admin]` check already used in
[`article.ex:245`](../../../lib/verscienta/content/article.ex) and `user.ex`). This function is the
only place the access rule is expressed; the reader, badge, and SEO layers consult it or
`premium?`.

### 3. Reader gating — the security boundary (`ArticleReaderLive`)

- After loading the article, compute `body_visible? = Content.body_visible?(article, actor)`.
- **Gated (`body_visible?` false):** assign the article with `blocks: []` and `gated?: true`. The
  template renders cover + title + excerpt + a **Premium upgrade panel**:
  - signed-in non-premium → "Subscribe to read" CTA → `/premium`
  - anonymous → "Sign in to subscribe" framing, also routing to `/premium`
  Body blocks never enter assigns or HTML.
- **Visible:** unchanged — full body renders as today.
- The reading-time / vitality-points heartbeat runs **only** when the body is visible; a gated
  teaser view is not a "read."

### 4. Editor toggle (`ArticleEditorLive`)

- A "Premium (subscribers only)" checkbox bound to `premium?`, rendered only when
  `Verscienta.Flags.enabled?(:paywall, for: current_user)` — mirrors the `:writing_assistant`
  gating already at [`article_editor_live.ex:30`](../../../lib/verscienta_web/live/article_editor_live.ex).
- Persists through the normal save/publish path.

### 5. Discovery badge

- A "Premium" badge on `news_card` / `tile` surfaces when `article.premium?`, placed next to the
  existing `featured_now` badge. No body content is present on these surfaces (they read
  `card_fields`), so there is nothing to leak.

### 6. SEO (paywall-compliant)

- In the SEO layer ([`lib/verscienta_web/seo.ex`](../../../lib/verscienta_web/seo.ex)) and the
  reader meta, when `article.premium?` emit `NewsArticle` JSON-LD with:
  - `"isAccessibleForFree": false`
  - a `hasPart` `WebPageElement` whose `cssSelector` matches the gated body container, with
    `"isAccessibleForFree": false`.
- Free articles emit today's JSON-LD unchanged.
- This is Google's documented paywalled-content signal — it tells crawlers the gate is intentional,
  avoiding a cloaking penalty.

### 7. Kill switch & rollout

- Add `:paywall` to `Verscienta.Flags.@known_flags` and to the off-by-default set in
  [`flags/seeds.ex`](../../../lib/verscienta/flags/seeds.ex).
- **Flag off** ⇒ `body_visible?` short-circuits true (all premium articles read free) **and** the
  editor toggle is hidden. This is the correct safe state when PayPal billing is not configured.
- **Dependency (documented, not code-enforced):** operators should not enable `:paywall` until
  `Verscienta.Billing.configured?/0` is true, otherwise readers hit a gate with no way to pay.

## Error handling & edge cases

- **`actor` is nil (anonymous):** `Accounts.premium?(nil)` already returns `false`; gated path with
  the "sign in to subscribe" CTA.
- **Author viewing own gated article:** always visible (so authors can preview).
- **Premium article that is also held/shadowed by moderation:** existing moderation gating takes
  precedence and is unchanged; paywall gating composes on top (a held article still shows the
  "under review" placeholder, not the teaser).
- **Flag flipped off after articles were marked premium:** they simply render free; the `premium?`
  flag value persists for when the flag is turned back on.
- **Direct API/read access:** out of scope — the app has no public content API; the reader is the
  only body-rendering path.

## Testing strategy

- **Unit — `body_visible?/2` truth table:** free article (true); premium + entitled subscriber
  (true); premium + anonymous (false); premium + author (true); premium + admin/mod (true);
  premium + flag-off (true).
- **Reader:** a gated render's HTML contains the teaser, the Premium badge, and the upgrade CTA but
  **not** a sentinel string placed in the body blocks; an entitled reader's and the author's render
  contain the full body. The reading-time heartbeat is not started on a gated view.
- **Editor:** the toggle persists `premium?`; the toggle is absent from the rendered editor when the
  `:paywall` flag is off.
- **Discovery:** a premium article's card shows the Premium badge and its excerpt, and the rendered
  feed HTML does not contain the body sentinel.
- **SEO:** a premium article emits `isAccessibleForFree: false` JSON-LD; a free article does not.

## Files touched (anticipated)

- `lib/verscienta/content/article.ex` — attribute + `@card_fields`.
- `priv/repo/migrations/<ts>_add_article_premium.exs` — column.
- `lib/verscienta/content.ex` (or wherever domain helpers live) — `body_visible?/2`.
- `lib/verscienta_web/live/article_reader_live.{ex,heex}` — gating + teaser/CTA.
- `lib/verscienta_web/live/article_editor_live.{ex,heex}` — toggle.
- `lib/verscienta_web/components/*` — Premium badge on card/tile.
- `lib/verscienta_web/seo.ex` — paywall JSON-LD.
- `lib/verscienta/flags.ex`, `lib/verscienta/flags/seeds.ex` — `:paywall` flag.
- `test/...` — unit + reader + editor + discovery + SEO tests.
