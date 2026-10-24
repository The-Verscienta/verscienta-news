# Sponsored Content Placements — Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-15
**Phase:** 4 — Polish, Monetization & Scale
**Status:** Approved, ready for implementation plan

The first of three monetization items in `docs/todo.md`. Order: (1) sponsored content
placements ← *this spec*, (2) featured/promoted challenges, (3) affiliate link integration.

## Goal

Let staff mark an editorial `Article` as **sponsored** and surface a clear, FTC-compliant
"Sponsored" disclosure wherever that article appears — at the point of impression (feed
cards) and the point of reading (article reader). Sponsorship is a *label only*: it does not
change feed placement, ranking, gamification, or moderation.

## Decisions (from brainstorming)

- **Form:** a flag on regular articles (not a separate ad-server / placement-slot system).
- **Who controls it:** admins/moderators only (editorial integrity + platform owns the FTC
  liability). Mirrors the existing `set_featured_until` mod/admin gate.
- **Metadata:** sponsor name + optional sponsor URL, stored **inline on `Article`** (no
  normalized `Sponsor` resource yet — YAGNI).
- **Placement effect:** none. Label only. Orthogonal to the existing `featured_until`
  mechanism (staff may feature *and* sponsor-label the same article).
- **Disclosure surfaces:** both — a badge on feed cards *and* a banner above the article
  body in the reader.

## Data model — three inline fields on `Article`

Add to `lib/verscienta/content/article.ex` attributes:

- `sponsored?` — `:boolean`, `allow_nil?: false`, `default: false`, `public?: true`
- `sponsor_name` — `:string`, `allow_nil?: true`, `public?: true`, `constraints: [max_length: 120]`
- `sponsor_url` — `:string`, `allow_nil?: true`, `public?: true`

A migration adds the three columns (`sponsored?` defaults false / not null; the other two
nullable).

All three fields are added to the `@card_fields` list (so feed/card surfaces can render the
badge without loading `:blocks`/`:embedding`). The `feed_payload_test.exs` drift guard fails
until they're placed — that is the intended forcing function, not an obstacle.

## Action + policy — mirror `set_featured_until`

A dedicated staff action keeps sponsorship orthogonal to author `:update` (an author editing
their post can neither set nor clear sponsorship):

```elixir
update :set_sponsorship do
  description "Moderator action: mark/clear an article as sponsored."
  accept [:sponsored?, :sponsor_name, :sponsor_url]
  require_atomic? false
  # validation (below)
  change Verscienta.Content.Article.Changes.InvalidateFeedCache
end
```

**Policy** (alongside the existing `set_featured_until` policy):

```elixir
policy action(:set_sponsorship) do
  authorize_if expr(^actor(:role) in [:moderator, :admin])
end
```

**Validation** (in the action, before_action or a validation):

- When the resulting `sponsored?` is `true`, `sponsor_name` must be present (non-blank).
- When `sponsor_url` is present, it must parse to an `http`/`https` URL — reuse the same
  scheme-allowlist posture used by block sanitization (`Content.Block` / `BlockRenderer`
  reject non-`http(s)` schemes). Reject `javascript:`, `data:`, etc.
- When `sponsored?` is set to `false`, force `sponsor_name` and `sponsor_url` to `nil` so a
  cleared sponsorship leaves no stale metadata.

`InvalidateFeedCache` flushes the feed cache tags so cards repaint with/without the badge.

## Disclosure UI — two surfaces, reusing existing idioms

### Card badge

In `lib/verscienta_web/components/codex_components.ex`, `news_card/1`:

- Add attrs `sponsored :boolean, default: false` and `sponsor_name :string, default: ""`.
- Render a "Sponsored" badge mirroring the existing Premium badge (lines ~78–83), positioned
  so it coexists with the Premium badge rather than overlapping it (e.g. offset to the left,
  or stacked). Same uppercase/extrabold/tracking treatment; a distinct accent so it reads as
  a disclosure, not a category.
- Wire `sponsored`/`sponsor_name` at **every `news_card` call site** — feeds (latest), category
  pages, For You, Following, Trending, search results, and the library. (Enumerate call sites
  during implementation via grep; the article structs already carry the fields once they're in
  `@card_fields`.)

### Reader banner

New component `LegalComponents.sponsored_disclosure/1` in
`lib/verscienta_web/components/legal_components.ex`:

- `attr :sponsored, :boolean` · `attr :sponsor_name, :string` · `attr :sponsor_url, :string`
- Renders **nothing** when `sponsored` is false (`:if`).
- When sponsored, renders a banner **above the article body**, visually distinct from
  editorial content (so a reader can tell it's a paid relationship). Copy:
  > **SPONSORED** — Sponsored by *{sponsor_name}*
- When `sponsor_url` is present, the sponsor name (or a trailing "↗") links to it with
  `rel="sponsored nofollow"` and `target="_blank"` (Google/FTC best practice for paid links).
- Styled in the Codex idiom, echoing `medical_disclaimer/1` but positioned at the top of the
  article and more prominent.

Rendered in `ArticleReaderLive` above the article body; the reader already loads the article,
so it assigns `sponsored?`/`sponsor_name`/`sponsor_url` alongside the existing `featured_now`
load.

## Staff controls — in the reader, next to feature/unfeature

`ArticleReaderLive` already hosts mod/admin `feature`/`unfeature` controls (≈ lines 470–481,
handlers ≈ 214–219, `set_featured/2` ≈ 406). Add, in the same mod/admin-gated control strip:

- A small inline form (mod/admin only) with `sponsor_name` + `sponsor_url` text inputs and
  two buttons: **Mark sponsored** and **Clear sponsorship**.
- `handle_event("set_sponsorship", …)` and `handle_event("clear_sponsorship", …)` calling a
  `set_sponsorship/2` reducer that mirrors `set_featured/2`: build the changeset for the
  `:set_sponsorship` action with the current actor, run it, reload the article (including the
  new fields), reassign, and surface a flash on error.

No dedicated admin screen — the reader is where feature/unfeature already lives, so this is
consistent and discoverable for moderators reading the article in context.

## Testing

- **Policy:** a non-staff actor is forbidden from `:set_sponsorship`; a moderator and an admin
  are allowed.
- **Validation:** `sponsored?: true` with a blank `sponsor_name` errors; a non-`http(s)`
  `sponsor_url` (e.g. `javascript:alert(1)`) is rejected; clearing nils both fields.
- **`@card_fields` drift guard** (`feed_payload_test.exs`) updated and passing with the three
  new fields.
- **Reader:** renders the disclosure banner with the correct `rel="sponsored nofollow"` link
  when the article is sponsored; renders nothing when it is not.
- **Card:** `news_card` renders the "Sponsored" badge when `sponsored` is true, and not
  otherwise; coexists with the Premium badge when both are set.

## Out of scope (YAGNI / ruled out in brainstorming)

- Campaigns, scheduling, start/end windows.
- Impression / click tracking and sponsored-content analytics.
- A normalized `Sponsor` resource (extractable later if recurring advertisers emerge — would
  also be reused by promoted challenges, spec #2).
- Feed placement / pinning for sponsored items (use the existing `featured_until` separately).
- Author self-serve sponsorship.
