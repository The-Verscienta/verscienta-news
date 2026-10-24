# Featured / Promoted Challenges — Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-15
**Phase:** 4 — Polish, Monetization & Scale
**Status:** Approved, ready for implementation plan

The second of three monetization items in `docs/todo.md`. Order: (1) sponsored content
placements ✅ (merged, PR #65), (2) featured/promoted challenges ← *this spec*, (3) affiliate
link integration. Built on `main` after #65, so the item-1 disclosure idiom
(`VerscientaWeb.LegalComponents.sponsored_disclosure/1`) is available to reuse.

## Goal

Let admins promote a challenge (`Quest`) — pinning it to the top of `/quests` with a
highlighted, time-boxed treatment — and optionally attach a sponsor (name + link) shown with a
clear FTC disclosure. Promotion is **display-only**: it changes prominence and branding on
`/quests`, not assignment, ranking, or rewards.

## Decisions (from brainstorming)

- **Form:** featured/promoted mechanism on the existing `Quest` resource **plus** an optional
  sponsor. Not a separate campaign/ad system.
- **Promotion mechanism:** a time-boxed `featured_until` timestamp (mirrors
  `Article.featured_until` + `featured_now`), so a sponsor campaign auto-expires. Not a manual
  boolean.
- **Effect:** display-only. Assignment is unchanged — `QuestAssignerWorker` still assigns every
  active quest to every user. A promoted challenge is simply an active `Quest` row that is also
  featured (and optionally sponsored). Promotion pins + highlights it on `/quests`.
- **Sponsor metadata:** optional `sponsor_name` + `sponsor_url`, stored inline on `Quest`
  (no normalized `Sponsor` resource — YAGNI, same call as item 1).
- **Who controls it:** **admin only** (tighter than item-1 article sponsorship's mod+admin —
  deliberate, because a sponsor campaign is a billing relationship). Enforced by the admin
  route.
- **Where staff control it:** a new minimal admin screen `/admin/challenges` (mirrors the
  existing admin LiveViews), since sponsor campaigns are time-sensitive and a deploy-to-launch
  workflow is unacceptable.
- **Campaign end input:** a **datetime-local** picker for `featured_until` (not a date-only
  input).
- **Rewards:** unchanged. A sponsored challenge just carries whatever `points_reward` its
  catalog row defines; no bonus mechanism.
- **Feature flag:** respects the existing `:quests` flag (the `/quests` page and the assigner
  worker are already gated by it); no new flag.

## Data model — three fields on `Quest`

Add to `lib/verscienta/gamification/quest.ex` attributes:

- `featured_until` — `:utc_datetime_usec`, `allow_nil?: true`, `public?: true`
- `sponsor_name` — `:string`, `allow_nil?: true`, `public?: true`, `constraints: [max_length: 120]`
- `sponsor_url` — `:string`, `allow_nil?: true`, `public?: true`

Add a calculation (mirrors `Article.featured_now`):

```elixir
calculate :featured_now, :boolean, expr(not is_nil(featured_until) and featured_until > now())
```

A migration adds the three columns (all nullable). `Quest` has no `@card_fields`/drift-guard
machinery (that is Article-specific), so nothing else needs updating.

## Action + policy

### Action

Add to `lib/verscienta/gamification/quest.ex`:

```elixir
update :set_promotion do
  description "Admin action: promote/sponsor a challenge (or clear it)."
  accept [:featured_until, :sponsor_name, :sponsor_url]
  require_atomic? false
  change Verscienta.Gamification.Quest.Changes.NormalizeQuestSponsor
end
```

A "clear promotion" is the same action with `featured_until: nil, sponsor_name: nil,
sponsor_url: nil`.

### Validation — `NormalizeQuestSponsor` change module

Create `lib/verscienta/gamification/quest/changes/normalize_quest_sponsor.ex`. Mirrors item 1's
`Verscienta.Content.Article.Changes.NormalizeSponsorship`, adapted: there is no `sponsored?`
boolean here (sponsorship is "has a sponsor_name"); a challenge can be promoted *without* a
sponsor.

Rules:
- Empty-string `sponsor_name`/`sponsor_url` normalize to `nil`.
- `sponsor_url`, when present, must be an `http`/`https` URL (scheme **and** host required, so
  `javascript:alert(1)` is rejected) and ≤ 2048 bytes. Use the same `is_binary(url) and
  byte_size(url) > 2048` guard ordering as item 1 (avoids a `FunctionClauseError` crash vector
  on non-binary input).
- If `sponsor_url` is present, `sponsor_name` must also be present (a link needs a visible
  label).

### Authorization

`Quest` currently has **no** `Ash.Policy.Authorizer` (all reads/writes use `authorize?:
false` — seeds, workers, `QuestsLive`). To avoid widening that to the whole resource, the
`:set_promotion` action is invoked **server-side from the admin-gated LiveView** with
`authorize?: false`; authorization is enforced by the route. The `/admin/challenges` route
lives in the `:admin` scope (`pipe_through [:browser, :admin]` + `:admin_required` on_mount),
exactly like `/admin/digests` and `/admin/flags`, so a non-admin cannot mount the LiveView and
therefore cannot emit its events. This matches how the other admin LiveViews manage their
resources (confirm `AdminSourcesLive`'s pattern during implementation and match it; if Source
uses Ash policies, add a parallel admin policy to `Quest` instead).

## Admin screen — `/admin/challenges` (`AdminChallengesLive`)

Mirrors `AdminSourcesLive` in structure (the closest existing "list + per-row edit" admin
LiveView). Admin-only scope.

- **Lists all quests** (`Quest |> Ash.read!(authorize?: false)`), showing for each: `name`,
  `cadence`, `active?`, current promotion state (`featured_until` + whether `featured_now`),
  and sponsor (`sponsor_name`).
- **Per-quest controls** (a small form per row, or a form for a selected quest):
  - `featured_until` — a `<input type="datetime-local">`.
  - `sponsor_name` — text input.
  - `sponsor_url` — text input.
  - **Promote / Save** button → `:set_promotion`.
  - **Clear promotion** button → `:set_promotion` with the three fields nilled.
- `handle_event`s call a `set_promotion/2`-style reducer that runs the action (`authorize?:
  false`, admin guaranteed by the route), reloads the quest list, flashes on error.
- **datetime-local handling:** the browser sends a value like `2026-06-30T17:00` (no zone /
  seconds). Parse it to `:utc_datetime_usec` for the attribute — interpret the wall-clock
  input as UTC via `NaiveDateTime.from_iso8601/1` (append `:00` seconds if needed) →
  `DateTime.from_naive!(_, "Etc/UTC")`. An empty value clears `featured_until`. Document this
  as a deliberate "admin enters UTC" simplification (no per-admin timezone conversion — YAGNI).

**Route:** add to the existing `:admin` scope in `lib/verscienta_web/router.ex`:

```elixir
live_session :admin_challenges,
  on_mount: [
    {VerscientaWeb.LiveUserAuth, :current_user},
    {VerscientaWeb.LiveUserAuth, :admin_required}
  ] do
  live "/challenges", AdminChallengesLive, :index
end
```

## Display on `/quests` (`QuestsLive` + its template)

- In `QuestsLive.load/1`, the per-assignment quest is already joined. Additionally load /
  compute `featured_now` for each quest (load the calculation, or compute it in Elixir from
  `featured_until` against `DateTime.utc_now()`).
- **Sort promoted-and-current challenges to the top** of the assignments list, then the rest in
  the existing order. The list is small and unpaginated, so a plain `Enum.sort_by/3` suffices —
  no keyset/featured-pin complexity like the article feed.
- **Render** (in the `/quests` template — `quests_live.html.heex` or the inline render; confirm
  during implementation):
  - Promoted challenges get a highlighted card treatment (a distinct border/accent — reuse the
    Codex tokens, e.g. `border-zune`, consistent with the article featured/sponsored styling).
  - When `sponsor_name` is present, show a **"Sponsored by {sponsor_name}"** disclosure. Reuse
    `VerscientaWeb.LegalComponents.sponsored_disclosure/1` from item 1 (it already renders the
    `rel="sponsored nofollow noopener noreferrer"` link, the plain-text fallback when no URL,
    and renders nothing when not sponsored) — pass `sponsored={quest.sponsor_name not in [nil,
    ""]}`, `sponsor_name`, `sponsor_url`. If its banner styling is too heavy for a compact
    challenge card, add a small sibling component in `LegalComponents`
    (`sponsored_tag/1`) that shares the same `rel` + copy conventions; prefer reuse first.

## Rewards & assignment — unchanged

No bonus-reward mechanism, no per-user targeting, no change to `QuestAssignerWorker`. A
promoted/sponsored challenge is an ordinary active `Quest`; promotion only affects `/quests`
presentation. The whole feature is dark unless the `:quests` flag is enabled (existing gate).

## Testing

- **`set_promotion` validation** (`Quest` action test): a non-`http(s)` `sponsor_url` is
  rejected; a >2048-char `sponsor_url` is rejected; `sponsor_url` present with a blank
  `sponsor_name` is rejected; setting all three then clearing (nil) leaves them nil; promoting
  with only `featured_until` (no sponsor) succeeds.
- **`featured_now` calc**: a future `featured_until` ⇒ true; a past one ⇒ false; nil ⇒ false.
- **Admin LiveView** (`AdminChallengesLive`): an admin can promote a quest (datetime-local
  value persisted as the right UTC instant) and clear it; a non-admin requesting
  `/admin/challenges` is redirected by the route (mirror an existing admin-route auth test).
- **`/quests` display**: a promoted+current challenge sorts ahead of a non-promoted one and
  renders the sponsor disclosure (`rel="sponsored nofollow noopener noreferrer"`); a
  non-promoted challenge shows no disclosure and no highlight.

## Out of scope (YAGNI / ruled out in brainstorming)

- Sponsor-funded bonus rewards (use the quest's existing `points_reward`).
- Per-user campaign targeting / promoted-challenge-only assignment paths.
- Impression / click tracking and sponsored-challenge analytics.
- A normalized `Sponsor` resource (still extractable later; would unify item 1 + item 2 sponsor
  fields).
- Full quest CRUD in the admin screen (quests remain seed-defined; the admin screen only sets
  promotion/sponsor fields).
- Per-admin timezone conversion for the datetime-local input (admin enters UTC).
