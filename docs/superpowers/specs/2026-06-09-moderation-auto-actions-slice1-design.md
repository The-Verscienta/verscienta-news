# Moderation Auto-Actions — Slice 1: Hold + Escalate + Audit Log

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-09
**Phase:** 3 — Intelligence & Growth › Moderation & Trust
**Todo item:** `[ ] Auto-actions (hold, shadow, escalate) with audit log.`
**Slice:** 1 of 2 (hold + escalate + audit). Shadow is Slice 2.

## Goal

Build on the Llama detection pipeline so the system can take **automated
enforcement actions** on flagged content — not just queue a flag for a human.
Slice 1 delivers two auto-actions plus the audit trail:

- **HOLD** — hide content pending human review (transparent quarantine).
- **ESCALATE** — keep content live but route the flag to the top of the
  moderator queue at elevated priority.

Both are also available as **manual moderator tools**, and every action
(automated or human, including reversals) is recorded in the durable
`Moderation.Action` audit log. **SHADOW** (silent, author-only-visible
shadowban) is deferred to Slice 2 because it requires viewer-aware filtering and
was chosen to be manual-only.

## Decisions (from brainstorming)

- **Trigger:** the AI detector verdict drives auto-actions (extends the
  `AutoModerateWorker` we just shipped).
- **Visibility semantics:** HOLD is transparent (hidden from public; author sees
  an "under review" placeholder). SHADOW (Slice 2) is silent/author-only.
  ESCALATE makes no visibility change.
- **Auto-mapping:** toxicity ≥ threshold → HOLD; dubious-claim (articles) →
  ESCALATE. SHADOW does not auto-fire (manual-only; Slice 2).
- **Two-stage gating:** `:auto_moderation` controls *detection* (flag creation,
  as today). A new `:auto_enforcement` flag (default **OFF**) additionally gates
  *enforcement* (hold/escalate actually acting). Hold/escalate act only when
  BOTH are on, so an operator can watch AI-flag quality before letting it act.
- **Content state:** a single new `moderation_status` field per content resource
  (not an overload of Article's existing `status`).
- **Reversibility:** resolving any flag first lifts an auto-hold (restore to
  visible), then the resolution's existing side effect applies
  (`content_removed` removes; others leave content visible).

## Architecture

```
submit → AutoModerateWorker (queue :ai)
  ├─ detection (gated by :auto_moderation): Detector.analyze → Moderation.ai_flag   [unchanged]
  └─ enforcement (gated by :auto_enforcement, AND a flag was raised):
       ├─ toxic            → Subject.hold(type, id)      + Action(:hold,     automated?: true)
       └─ dubious (article)→ Moderation.escalate(flag)   + Action(:escalate, automated?: true)

moderator queue (AdminModerationLive)
  ├─ manual: hold / escalate / restore buttons          → Action(..., automated?: false)
  └─ resolve/5: dismissed|warned|suspended → Subject.unhold + side effect
                content_removed            → Subject.remove
```

### 1. Content moderation-status model

Add to `Engagement.Comment`, `Content.Article`, `Communities.Message`:

```elixir
attribute :moderation_status, :atom,
  allow_nil?: false,
  default: :visible,
  writable?: false,
  public?: true,
  constraints: [one_of: [:visible, :held]]   # :shadowed added in Slice 2
```

Per-resource system update actions (`authorize?: false`, used only by the
moderation context/worker):

```elixir
update :hold do
  accept []
  require_atomic? false
  change set_attribute(:moderation_status, :held)
  # Article only: change Verscienta.Content.Article.Changes.EnqueueIndex
end

update :unhold do
  accept []
  require_atomic? false
  change set_attribute(:moderation_status, :visible)
  # Article only: change Verscienta.Content.Article.Changes.EnqueueIndex
end
```

Three migrations add `moderation_status text not null default 'visible'` to
`comments`, `articles`, `room_messages` (generated via
`mix ash_postgres.generate_migrations`).

Polymorphic dispatch in `Moderation.Subject` (mirrors `remove/2`):

```elixir
@spec hold(subject_type, Ecto.UUID.t()) :: :ok
def hold(:comment, id),      do: do_update(Comment, id, :hold)
def hold(:article, id),      do: do_update(Article, id, :hold)
def hold(:room_message, id), do: do_update(Message, id, :hold)
def hold(:user, _id),        do: :ok
def hold(_, _),              do: :ok

@spec unhold(subject_type, Ecto.UUID.t()) :: :ok
def unhold(:comment, id),      do: do_update(Comment, id, :unhold)
# ...same shape; :user / fallthrough → :ok
```

### 2. Filtering (held content is hidden from the public)

Held content is treated like soft-deleted for **listing**, and like a tombstone
for **threaded display**. No viewer-aware logic in Slice 1.

- **Articles**
  - `Article.list_published` (feed, category pages): add
    `moderation_status == :visible` to the existing filter.
  - `Recommendations` (related, For-You): add the same predicate where
    published articles are selected.
  - **Search:** held articles are removed from the Meili index. The `:hold` /
    `:unhold` actions enqueue `EnqueueIndex`; the index inclusion logic
    (whatever decides "is this article indexable") must require
    `moderation_status == :visible` so a held article is deleted from the index
    and a restored one re-added. The Postgres FTS fallback adds the same filter.
  - **Reader** (`ArticleReaderLive`): if `moderation_status == :held`, render an
    "under review" notice in place of the article body (author transparency;
    others cannot read the content). The article is already excluded from all
    lists, so it is only reachable by direct URL.
- **Comments** (`ArticleReaderLive` thread render): a held comment renders an
  `[under review]` placeholder, mirroring the existing
  `comment_body(%{deleted_at: nil})` → `"[deleted]"` pattern. Comment counts
  exclude held comments.
- **Room messages** (`Communities.room_messages/1`): add
  `moderation_status == :visible` alongside the existing `is_nil(deleted_at)`
  filter, so held messages drop out of the live room list.

### 3. Escalate / Flag priority

Add to `Moderation.Flag`:

```elixir
attribute :priority, :atom,
  allow_nil?: false,
  default: :normal,
  public?: true,
  constraints: [one_of: [:normal, :high]]
```

New system action:

```elixir
update :escalate do
  description "Raise a flag to high priority (manual mod action or auto on dubious claims)."
  accept []
  require_atomic? false
  change set_attribute(:priority, :high)
end
```

`Moderation.pending_groups/0` adds `priority:` to each group (the max priority
across the group's flags) and changes the sort to: **priority `:high` first**,
then `count` desc, then `first_reported_at` asc.

`Moderation.escalate(subject_type, subject_id)` sets every pending flag for the
subject to `:high` (worker + manual both call it).

### 4. Audit log (`Moderation.Action`)

- Extend the `action` enum:
  `[:dismiss, :remove_content, :warn_user, :suspend_user, :hold, :escalate, :restore]`.
- Make `moderator_id` **nullable** (automated actions have no moderator).
- Add `attribute :automated?, :boolean, allow_nil?: false, default: false, public?: true`.
- `:record` action accepts `automated?` and tolerates a nil `moderator_id`.
- Migration: add `automated boolean not null default false`; drop NOT NULL on
  `moderator_id`.
- New context helper:

```elixir
@doc "Record a system/automated moderation action (no moderator). Best-effort."
def record_auto_action(action, subject_type, subject_id, opts \\ [])
# builds an Action via :record with automated?: true, moderator_id: nil,
# target_user_id from Subject.snapshot, note from opts; authorize?: false
```

The existing manual-resolution path (`record_action/7`) sets
`automated?: false` and keeps the moderator.

### 5. Worker auto-mapping (`AutoModerateWorker`)

`maybe_flag/3` keeps creating the AI flag exactly as today. After the flag is
created, if `Flags.enabled?(:auto_enforcement)`:

- **toxic** (`reason: :harassment`): `Subject.hold(type, id)` then
  `Moderation.record_auto_action(:hold, type, id, note: ...)`.
- **dubious** (article, `reason: :misinformation`):
  `Moderation.escalate(type, id)` then
  `Moderation.record_auto_action(:escalate, type, id, note: ...)`.

Enforcement is wrapped so a failure logs and returns `:ok` — it must never crash
the worker, fail the user's submit, or block the flag. With `:auto_enforcement`
off, the worker behaves exactly as today (flag only, no content change).

### 6. Reversibility + queue UI

- **`Moderation.resolve/5`** — within the existing side-effect step:
  - `:content_removed` → `Subject.remove/2` (unchanged; held state is moot once
    removed).
  - `:dismissed` / `:user_warned` / `:user_suspended` → `Subject.unhold/2`
    (restore to visible) in addition to the existing user side effect.
  - The chosen resolution is recorded as a `Moderation.Action` exactly as today
    (`automated?: false`).
- **`AdminModerationLive`** — per group:
  - Show state badges: `⏸ held` when the subject is held, `⚑ escalated` when the
    group priority is `:high` (badge derived from new `pending_groups` fields).
  - Order groups by priority (escalated first) per the new sort.
  - Add manual buttons: **hold** (`Subject.hold` + Action), **escalate**
    (`Moderation.escalate` + Action), **restore** (`Subject.unhold` + Action).
    Each is mod/admin gated and recorded with `automated?: false`. These are new
    `handle_event`s alongside the existing `resolve`.

### 7. Feature flags

Add `:auto_enforcement` to `Verscienta.Flags.@known_flags` and to the
`@phase3_off` seed list (materialized **off**), with label
"Automatic enforcement".

## Testing

- **Subject hold/unhold:** `Subject.hold/unhold` set `moderation_status` for
  comment/article/message; `:user` and unknown → `:ok` no-op.
- **Filtering:** a held article is absent from `list_published` and
  recommendations, and its reader page shows the "under review" notice; a held
  comment renders `[under review]` and is excluded from counts; a held room
  message is absent from `room_messages/1`. A restored subject reappears.
- **Search:** holding an article enqueues a reindex and the index excludes it;
  unhold re-includes it (assert the enqueue + the indexable predicate).
- **Escalate:** `Moderation.escalate` sets pending flags to `:high`;
  `pending_groups/0` orders an escalated group ahead of a higher-count normal
  group.
- **Audit log:** `record_auto_action` writes an Action with `automated?: true`,
  nil moderator, correct `action`/`subject`/`target_user_id`. Manual actions
  write `automated?: false` with the moderator.
- **Worker enforcement:** with `:auto_moderation` + `:auto_enforcement` both on,
  a toxic comment is held and a `:hold` Action recorded; a dubious article is
  escalated and an `:escalate` Action recorded. With `:auto_enforcement` OFF,
  the flag is still created but NO hold/escalate/Action occurs. An enforcement
  failure (e.g. subject vanished) does not raise.
- **Reversibility:** resolving a held subject with `:dismissed` restores it to
  visible; with `:content_removed` it is removed; both record the resolution
  Action.
- **Queue UI:** manual hold/escalate/restore buttons perform the action, record
  an Action, and refresh the queue; held/escalated badges render.

Stub the AI client (existing `AI.Client.Stub`) for worker tests; use
`Oban.Testing` where jobs are involved.

## Out of scope (Slice 2 / later)

- **SHADOW** — silent, author-only-visible shadowban (viewer-aware filtering);
  manual moderator tool. Slice 2.
- Auto-shadow for repeat offenders; author notifications on hold; finer Detector
  severity gradation; per-action configurable verdict→action mapping.

## Files touched (summary)

- `lib/verscienta/engagement/comment.ex`, `lib/verscienta/content/article.ex`,
  `lib/verscienta/communities/message.ex` — `moderation_status` + `:hold`/`:unhold`.
- `lib/verscienta/moderation/subject.ex` — `hold/2`, `unhold/2`.
- `lib/verscienta/moderation/flag.ex` — `priority` + `:escalate`.
- `lib/verscienta/moderation/action.ex` — enum + nullable moderator + `automated?`.
- `lib/verscienta/moderation.ex` — `escalate/2`, `record_auto_action/…`,
  `resolve/5` unhold wiring, `pending_groups/0` priority + sort.
- `lib/verscienta/moderation/workers/auto_moderate_worker.ex` — enforcement step.
- `lib/verscienta/content/article.ex` (`list_published`), `lib/verscienta/recommendations*`,
  `lib/verscienta/search/*`, `lib/verscienta/communities.ex`,
  `lib/verscienta_web/live/article_reader_live.ex` — filtering.
- `lib/verscienta_web/live/admin_moderation_live.ex` — badges, ordering, manual buttons.
- `lib/verscienta/flags.ex`, `lib/verscienta/flags/seeds.ex` — `:auto_enforcement`.
- `priv/repo/migrations/*` — moderation_status ×3, flag priority, action automated/nullable.
- Tests across the above.
