# Affiliate Link Integration + Disclosure — Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-15
**Phase:** 4 — Polish, Monetization & Scale
**Status:** Approved, ready for implementation plan

The third and final monetization item in `docs/todo.md`. Order: (1) sponsored content
placements ✅ (PR #65), (2) featured/promoted challenges ✅ (PR #66), (3) affiliate link
integration ← *this spec*. Branched off `main` after both merged.

## Goal

Automatically turn outbound links in article prose that point to configured affiliate partners
into commission-earning links (append the partner's tracking param + set the FTC/Google paid-link
`rel`), and show a clear affiliate disclosure on any article that contains such links — with zero
author effort.

## Decisions (from brainstorming)

- **Detection:** automatic partner-domain rewrite. A static list of affiliate partners; any
  article-body link whose host matches a partner is rewritten and triggers the disclosure. No
  author tagging (avoids forget-to-disclose compliance risk).
- **Config home:** application config (`config/runtime.exs`, env-driven) — affiliate programs are
  static infrastructure (a fixed tracking tag per partner). No DB resource / admin UI.
- **Rewrite timing:** render-time only. The stored article blocks keep the author's original
  URLs; rewriting is applied when the reader renders the body. Changing the config re-applies on
  next render. Canonical content is never mutated.
- **HTML manipulation:** regex-based, consistent with `Verscienta.Aggregation.Html` (the codebase
  has no HTML parser dep; Floki is intentionally NOT added). Operates on our own well-formed
  `BlockRenderer`/MDEx output.
- **Link behavior:** set `rel="sponsored nofollow"` (merged with existing rel tokens), but do NOT
  force `target="_blank"` — affiliate links keep their authored link behavior.
- **Feature flag:** an off-by-default `:affiliate_links` FunWithFlags flag (consistent with
  `:paywall`, `:web_push`, etc.). When off: no rewriting, no disclosure.
- **Scope:** article body only — not comments or other user-generated content.

## Config — static partner list

In `config/runtime.exs`:

```elixir
config :verscienta, :affiliate_partners,
  Verscienta.Content.Affiliate.parse_partners(System.get_env("AFFILIATE_PARTNERS"))
```

The exact env-parsing format is an implementation detail; the in-memory shape each partner takes
is:

```elixir
%{host: "amazon.com", param: "tag", value: "verscienta-20", label: "Amazon"}
```

- `host` — the partner domain; matched against a link's URI host by exact match OR subdomain
  (a link host `www.amazon.com` or `smile.amazon.com` matches partner `amazon.com`).
- `param` / `value` — the query parameter appended for commission attribution.
- `label` — human name (currently unused in the disclosure copy, reserved for future per-partner
  display; keep it in the struct).

An empty or unset list makes the feature inert even when the flag is on. For local/dev the
default is `[]`.

## Rewriter — `Verscienta.Content.Affiliate`

A single focused module. Public interface:

- `partners() :: [partner_map]` — reads `:affiliate_partners` from config (default `[]`).
- `rewrite_html(html :: String.t()) :: {String.t(), boolean()}` — **pure** (flag-agnostic):
  rewrites based on the configured partner list only, and returns the rewritten HTML plus whether
  ANY link was rewritten (drives the disclosure). With no partners configured it naturally returns
  `{html, false}` unchanged. The `:affiliate_links` flag check is NOT inside this function — it
  lives in the reader (see "Reader integration"), which keeps `rewrite_html/1` cleanly unit-testable
  by just configuring partners.

Algorithm:
1. Scan each `<a ...>` opening tag via a regex over the well-formed HTML (e.g. capture each
   `<a` tag's attribute string).
2. Extract the `href` value; parse with `URI.parse/1`. If the host matches a partner (exact or
   subdomain suffix, case-insensitive):
   - **Append the tracking param** to the query string: if the link already contains `param`,
     leave it as-is (do not duplicate/overwrite); otherwise append (`?param=value` when no
     existing query, `&param=value` when there is). Re-encode safely.
   - **Merge rel:** ensure the tokens `sponsored` and `nofollow` are present in the `rel`
     attribute, preserving and deduping any existing tokens (e.g. `noopener noreferrer` →
     `noopener noreferrer sponsored nofollow`). If the tag had no `rel`, add `rel="sponsored
     nofollow"`.
   - Mark that the document contains ≥1 affiliate link.
3. Non-matching links are left exactly as-is.

Robustness notes (the HTML is our own sanitized output, not arbitrary user HTML):
- hrefs are URL-encoded (no raw `>`/`"` inside), so attribute extraction is tractable by regex.
- Only `http`/`https` links are candidates (BlockRenderer already drops other schemes); a link
  with no host (relative/anchor) never matches a partner.
- The rewriter must be idempotent: running it twice yields the same output (param-already-present
  skip + rel-token dedup guarantee this).

## Reader integration

In `lib/verscienta_web/live/article_reader_live.ex`, where `@body_html` is currently built
(`BlockRenderer.to_html(article.blocks)` for the non-gated case), pipe the result through the
affiliate rewriter and assign both the rewritten HTML and a `@has_affiliate?` flag:

- When the body is gated/absent (`premium_gated?` / held), `@body_html` stays nil and
  `@has_affiliate?` is `false` (no body → nothing to rewrite, no disclosure).
- The rewrite honours the `:affiliate_links` flag: when off, the body HTML is unchanged and
  `@has_affiliate?` is `false`.

## Disclosure — `LegalComponents.affiliate_disclosure/1`

A new component in `lib/verscienta_web/components/legal_components.ex` (alongside
`medical_disclaimer/1`, `sponsored_disclosure/1`, `sponsored_tag/1`):

- `attr :has_affiliate, :boolean, required: true`
- Renders nothing when `has_affiliate` is false (`:if`).
- When true, renders a banner **above the article body**, visually consistent with the other
  legal disclosures (Codex tokens), reading approximately:
  > **AFFILIATE DISCLOSURE** — This article contains affiliate links. We may earn a commission on
  > qualifying purchases, at no extra cost to you. [→ read our affiliate policy]
- The policy link points to an existing legal page if one fits, otherwise omit the link in v1
  (decide in the plan by checking the existing legal routes — do not invent a route).

Placed in the reader template above the body block (the same anchor region as the existing
sponsored disclosure), so it appears before the affiliate links (FTC "clear and conspicuous").

## Feature flag

`:affiliate_links`, off by default. Register/seed it the same way the other off-by-default flags
are handled. The **reader** checks `Verscienta.Flags.enabled?(:affiliate_links)` and only calls
`Affiliate.rewrite_html/1` when the flag is on; when off it leaves the body HTML unchanged and sets
`@has_affiliate?` to `false` (links render unmodified, no disclosure). `rewrite_html/1` itself stays
pure (no flag check) for testability.

## Testing

- **`Affiliate.rewrite_html/1` units** (pure — configure partners in the test): partner-domain
  link → tracking param appended + `rel` contains `sponsored nofollow`; subdomain match; link that
  already has the param → not duplicated; link with an existing query string → param appended with
  `&`; existing `rel="noopener noreferrer"` → merged/deduped to include `sponsored nofollow`;
  non-partner link → untouched and `affiliate?` reflects no match; multiple links → flag true if
  any match; idempotency (rewrite∘rewrite == rewrite); no partners configured → `{html, false}`
  unchanged.
- **Reader integration:** with the `:affiliate_links` flag ON, an article whose body links to a
  partner renders the affiliate disclosure and the rewritten link (param + rel); an article with no
  partner links renders neither; with the flag OFF, a partner-linking article renders neither
  (links unmodified). (Manage the flag within the test + clean up after — see the FunWithFlags
  test-sandbox guidance in the plan.)
- **Disclosure component:** renders the banner when `has_affiliate` true, nothing when false.

## Out of scope (YAGNI / ruled out in brainstorming)

- DB-managed partners + admin UI (config-only).
- Click tracking / affiliate analytics / earnings reporting.
- Per-link visual markers (rel attributes are invisible, standard practice).
- Rewriting in comments, syndication, or the markdown export path (reader render only).
- Link cloaking / redirect-through-our-domain URLs.
- Per-partner disclosure copy (one generic disclosure; `label` reserved for later).
