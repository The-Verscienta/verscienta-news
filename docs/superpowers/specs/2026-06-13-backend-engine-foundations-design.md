# Backend Engine Foundations — Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-13
**Status:** Approved (brainstorming) — pending spec review
**Branch:** `claude/backend-engine-foundations`

## Context

`docs/design/the-codex-engine-v3.html` is the "grounded" backend manifesto. Its
*"not yet"* section lists seven items the manifesto describes but the codebase
does not yet implement. The app currently has **no production data**, which makes
the foundational, schema-shaped items cheap to adopt now and expensive to retrofit
later.

This spec covers the **greenfield foundations** subset — the items that add value
*because* we are pre-data — plus the AshOban conversion. Two manifesto items are
**explicitly deferred** (see Non-Goals).

## Goals

1. **`uuid_v7` primary keys** — sortable, timestamp-ordered IDs across all
   single-PK resources.
2. **AshStateMachine** — formalize the article editorial lifecycle.
3. **AshPaperTrail** — audit trails on audit-sensitive resources that lack
   bespoke history today.
4. **AshOban triggers (scan-based)** — convert the four article async jobs from
   best-effort `after_action` enqueues to idempotent, self-healing triggers.
5. **Keyset pagination** — declare keyset pagination on the main Ash list reads
   and render their LiveViews with streams + load-more.

## Non-Goals (explicitly deferred)

- **Public API (AshJsonApi / AshGraphql).** No current consumer — LiveView does
  not consume it. Adding it now is unused attack surface + maintenance. Defer
  until a real external/mobile consumer exists.
- **Fan-out-on-write + follower threshold.** A scale optimization. The on-read
  feed (`social.ex`) is correct and cached; fan-out-on-write only earns its
  complexity when feed-read latency degrades under real follower counts.
- **Replacing existing bespoke history** (`Content.ArticleRevision`,
  `Gamification.GamificationAudit`, `Flags.Audit`). They already version their
  domains; consolidating onto AshPaperTrail is a separate project.

## Current State (audit summary)

- ~37 resources across 11 Ash domains; **no shared base/`__using__` macro** — each
  resource declares `use Ash.Resource, ...` and `uuid_primary_key :id`
  independently. Join tables (e.g. `Content.ArticleTag`) use composite PKs.
- Article has **two** state attributes: `:status`
  (`:draft | :published | :archived`, default `:draft`) and `:moderation_status`
  (`:visible | :held | :shadowed`, `writable?: false`). `published_at` is stamped
  on first `:publish`.
- Four article async jobs enqueue from `after_action` change modules
  (`EnqueueIndex`, `EnqueueEmbedding`, `EnqueueEnrich`, `EnqueueOgCard`), each
  `Worker.new(args) |> Oban.insert!()` wrapped in a best-effort `rescue`.
- `config :ash, default_page_type: :keyset` is **already set** but no read action
  declares `pagination`. Search (`search.ex`) uses Meilisearch **offset**.
- Oban queues: `default: 10, aggregation: 5, ai: 3`.
- Missing deps: `ash_oban`, `ash_state_machine`, `ash_paper_trail`.

---

## 1. `uuid_v7` Primary Keys

**Change:** Replace `uuid_primary_key :id` → `uuid_v7_primary_key :id` on every
single-PK resource (~35). Composite-PK join tables are untouched.

**Why it's nearly free:** `uuid_v7_primary_key` keeps the Postgres column type
`:uuid`; only the app-side default generator changes (`Ash.UUID` → `Ash.UUIDv7`).
There is no data-shape migration. New rows get timestamp-sortable IDs, improving
B-tree index locality and pairing naturally with keyset pagination.

**Migration:** AshPostgres may emit a default-change migration; column type is
unchanged. Dev DB is reset (no data). Existing UUIDv4 rows (seeds/tests) coexist
with new v7 rows without issue.

**Risk:** Minimal. The only watch-item is any code that *assumes* random/unsortable
IDs (none found) or hardcoded fixture IDs in tests (regenerate as needed).

## 2. AshStateMachine — Article editorial lifecycle

**Scope:** The `:status` attribute only. `:moderation_status` stays a plain
moderator-only attribute — it is orthogonal, and AshStateMachine governs a single
state attribute per resource.

**Add dep:** `ash_state_machine`. Add the extension to `Content.Article`.

**State graph:**

```
default_initial_state :draft
# allowed initial states for create actions: :draft, :published

transitions do
  transition :publish, from: :draft,               to: :published
  transition :archive, from: [:draft, :published], to: :archived
end
```

- **Initial states:** the normal create begins `:draft`; the system
  `:create_aggregated` create action begins `:published` directly (an allowed
  initial state) — it is *not* a transition, since a create has no prior state.
- `:publish` retains the existing `published_at` stamp-on-first-publish change.
- Re-publishing from `:archived` is **not** a transition today (no existing
  unarchive action); omitted intentionally. Adding it later is a one-line
  transition.

**Benefit:** Illegal transitions (e.g. archived→published) raise a typed
`AshStateMachine` error instead of silently `set_attribute`-ing. The rules become
declarative and visible on the resource.

## 3. AshPaperTrail — Audit trails

**Add dep:** `ash_paper_trail`. Apply the extension to:

| Resource | Notes |
|---|---|
| `Moderation.Action` | moderation decisions — high audit value |
| `Moderation.Flag` | report lifecycle |
| `Billing.Subscription` | financial state changes |
| `Experts.ExpertApplication` | approval/rejection trail |
| `Accounts.User` | sensitive — **ignore** auth/secret attributes |

**User redaction:** configure PaperTrail with an explicit `ignore_attributes` list
covering every secret/sensitive field (e.g. `hashed_password`, confirmation/reset
token fields, anything already `sensitive?`/`redact`-marked) so the trail never
persists secrets. A test asserts those fields are absent from recorded changes.

**Versioning style:** use AshPaperTrail's default companion-resource version table
per audited resource (`*_versions`), `:changes` stored as a map. Do **not** touch
the existing bespoke history tables (out of scope).

**Risk:** Low/additive — each audited resource gains a versions table + migration.
No behavior change to existing reads/writes.

## 4. AshOban Triggers (scan-based) — Article async pipeline

**Add dep:** `ash_oban`. Convert the four article jobs from `after_action`
enqueues to AshOban **triggers** (mark-and-scan model): a trigger declares a
`where` condition; AshOban periodically finds matching records and runs the
configured action, which performs/enqueues the work. Lost jobs self-heal on the
next scan.

**Tracking columns (new, on `Content.Article`):**

| Trigger | Column | `where` condition (sketch) |
|---|---|---|
| index   | `last_indexed_at`   | `status == :published and (is_nil(last_indexed_at) or last_indexed_at < updated_at)` |
| embed   | `last_embedded_at`  | published and stale, gated by existing embedding flag |
| enrich  | `last_enriched_at`  | published and stale, gated by existing enrich flag |
| og_card | `og_card_generated_at` | published and (card missing or title/cover changed) |

Each trigger's action updates its tracking column on success (so the scan
converges). Workers keep their existing logic; only the *enqueue mechanism*
changes. Queues stay `ai` (embed/enrich/index) and `default`/`aggregation` as
today; AshOban honors the configured queue per trigger.

**Moderation enqueue:** the `:publish`-time auto-moderation enqueue stays as-is for
this slice (it is not one of the four article-content jobs); revisit if desired.

**Open implementation detail (resolve in plan):** exact scan cadence
(`scheduler_cron`) and whether to also keep an immediate enqueue on the action for
latency-sensitive triggers (AshOban supports running a trigger for a record
immediately in addition to the periodic scan). Default: periodic scan only, tuned
in the plan; index/og_card may warrant immediate-run for freshness.

**Benefit:** Idempotent, self-healing, declarative — a dropped or failed job is
recovered by the next scan instead of being lost to a best-effort `rescue`.

## 5. Keyset Pagination + LiveView streams

**Ash reads** — add `pagination keyset?: true, default_limit: 20` (and a sane
`max_page_size`) to the main list reads:

- `Content.Article`: `:list_published`, `:list_by_category`, `:list_by_group`
- `Engagement.Bookmark`: `:list_for_user`
- Notifications list, Social activity/trending reads (currently hardcoded limits)

**LiveView** — convert the corresponding views to **streams + load-more by
cursor**: initial mount loads page 1 into a stream; a "load more"
event/infinite-scroll fetches the next keyset page and appends via `stream`.
Several of these LiveViews already use streams (activity, article_reader,
notifications, profile, room), so the pattern is established.

**Caching interaction:** keep caching **page 1** (the hot path, existing TTLs);
deeper pages query live (cursor space is unbounded — don't cache per-cursor).

**Search stays offset:** Meilisearch is an external engine; keyset does not apply.
This remains the documented single exception (already noted in v3).

**Risk:** Medium — this is the most UI-touching item. Mitigated by the existing
stream usage and by leaving search untouched.

---

## Implementation Order (phased)

1. **uuid_v7** — schema-wide, do first while resetting the dev DB.
2. **AshStateMachine** — Article `:status`.
3. **AshPaperTrail** — the five audited resources.
4. **AshOban** — scan-based triggers for the four article jobs.
5. **Keyset pagination** — Ash reads + LiveView load-more.

Each phase: add dep (if any) → resource/config change → migration → tests green
(`mix compile --warnings-as-errors`, `mix format`, targeted tests) before the next.

## Testing Strategy

- **uuid_v7:** assert new records' IDs are v7 (version nibble) and monotonic-ish by
  insertion; full suite green after DB reset.
- **State machine:** test each legal transition succeeds and at least one illegal
  transition (e.g. archived→published) raises; `published_at` stamped once.
- **PaperTrail:** assert a version row is created on update for each audited
  resource; assert User secret attributes are **absent** from the recorded changes.
- **AshOban:** with Oban in `:manual`/testing mode, assert a stale published article
  is picked up by each trigger's `where` and the tracking column advances; assert
  idempotency (second scan enqueues nothing).
- **Pagination:** assert keyset page returns `default_limit`, a next-cursor fetches
  the following set with no overlap, and the LiveView appends via stream.

## Risks & Mitigations

- **uuid_v7 macro availability** — confirm `uuid_v7_primary_key` builder in the
  installed Ash 3.x; fallback is `attribute :id, :uuid, default: &Ash.UUIDv7.generate/0`.
- **Test fixtures with hardcoded IDs** — regenerate; greenfield so low impact.
- **AshOban scan cadence vs freshness** — resolve immediate-run vs periodic per
  trigger in the plan (index/og_card likely want immediacy).
- **Pagination + cache** — only page 1 cached; document the boundary.

## Deferred (tracked, not built)

- Public API: AshJsonApi / AshGraphql (no consumer).
- Fan-out-on-write + follower threshold (no scale need).
- Migrating bespoke history (`ArticleRevision`, `GamificationAudit`, `Flags.Audit`)
  onto AshPaperTrail.
