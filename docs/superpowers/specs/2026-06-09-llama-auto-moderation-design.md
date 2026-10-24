# Llama-based Toxicity + Dubious-Claim Detection on Submit

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-09
**Phase:** 3 — Intelligence & Growth › Moderation & Trust
**Todo item:** `[ ] Llama-based toxicity + dubious-claim detection on submit.`
**Branch:** `phase-3-moderation-trust`

## Goal

When a user submits content, run a Llama (Ollama) check for **toxicity** and, for
articles, **dubious claims**. When a check crosses a threshold, create a
**system-sourced moderation flag** that drops into the existing moderator queue
alongside human reports. A human still decides the outcome — this slice does
**not** auto-hide, hold, shadow, or escalate content (that is the *next* todo
item: "Auto-actions (hold, shadow, escalate) with audit log").

## Decisions (from brainstorming)

- **Timing:** Async, post-submit. The submit succeeds instantly; an Oban `:ai`
  worker scores the content afterward. This matches the codebase's
  graceful-degradation + worker pattern and never blocks UX on a slow/down Llama.
- **Coverage:** Comments (`Engagement.Comment`), Articles on publish
  (`Content.Article`), and Room messages (`Communities.Message`).
- **Detection split:** Toxicity is checked for all three subject types.
  Dubious-claim detection is requested and acted on for **articles only**
  (wellness misinformation is the real risk there; comments/messages get
  toxicity-only).
- **Result storage:** System-sourced flag only. Below-threshold content stores
  nothing. No new score columns on Comment/Article/Message; no separate AIScore
  resource.
- **Gating:** Behind the existing, already-seeded-**off** `:auto_moderation`
  feature flag. The feature is inert until an operator switches it on.

## Architecture

```
submit (Comment.create / Article.publish / Message.post)
   └─ after_action: EnqueueAutoModerate
        └─ if Flags.enabled?(:auto_moderation): Oban insert (unique per subject)
             └─ AutoModerateWorker (queue :ai)
                  ├─ load subject's current text
                  ├─ Moderation.Detector.analyze(subject_type, text)
                  │     └─ AI.Client.generate/2 → strict JSON verdict
                  └─ on threshold crossing: Flag :ai_flag  ──► existing mod queue
```

### 1. `Moderation.Flag` resource changes

File: `lib/verscienta/moderation/flag.ex`

- Add attribute `source :atom`, `allow_nil?: false`, `default: :community`,
  `constraints: [one_of: [:community, :ai]]`, `public?: true`.
- Relax `reporter` relationship to `allow_nil?: true` (AI flags have no human
  reporter). The existing `:report` action keeps `relate_actor(:reporter)`, so
  community flags still always have a reporter.
- New create action `:ai_flag` (`authorize?: false` — system only):
  - `accept [:subject_type, :subject_id, :reason, :note]`
  - `change set_attribute(:source, :ai)`
  - `change Verscienta.Moderation.Flag.Changes.CaptureSubject` (reuse — fills
    `subject_excerpt` + `subject_author_id`)
  - **No** `RateLimitReport`, **no** `relate_actor`.
  - Plain create (no `upsert?`). Dedup is handled in application code (see below).
- **Dedup (as shipped):** `Moderation.ai_flag/4` skips creation when a pending
  AI flag already exists for the subject (`ai_flag_exists?/2`), and the worker is
  enqueued with per-subject Oban job uniqueness
  (`unique: [keys: [:subject_type, :subject_id], states: incomplete]`). This keeps
  the schema and action simple. Trade-off: the check-then-insert is not atomic and
  is not backed by a DB unique constraint, so two concurrent `:ai` jobs for the
  same subject could in principle both insert (the Oban uniqueness window is 60s
  and only covers *incomplete* jobs). The blast radius is tiny — the `:ai` queue is
  low-concurrency, the feature is behind an off-by-default flag, and a duplicate is
  cosmetic (two rows in one queue group), never unsafe or auto-actioned.
  - **Optional future hardening (not shipped):** a partial unique index
    `unique_ai_subject` on `[:subject_type, :subject_id]`
    `where source == :ai and status == :pending`, with `upsert? true` on the
    action, would make the at-most-one-pending-AI-flag-per-subject guarantee
    DB-enforced. Deferred for simplicity; revisit only if duplicates are observed.
- Policy: add `policy action(:ai_flag) do authorize_if always() end` is
  unnecessary because `authorize?: false` bypasses policies; ensure the action is
  only ever called by the worker with `authorize?: false`.

### 2. `Moderation.Detector` (new)

File: `lib/verscienta/moderation/detector.ex`

- `@spec analyze(atom(), String.t()) :: {:ok, verdict} | {:error, term}`
- Builds a prompt instructing Llama to return **strict JSON only**:
  ```json
  {
    "toxic": true,
    "toxicity_severity": "none|low|high",
    "toxicity_reason": "short phrase",
    "dubious_claim": false,
    "claim_reason": "short phrase"
  }
  ```
  For non-article subjects the prompt omits the dubious-claim fields (and any
  returned claim fields are ignored).
- Calls `Verscienta.AI.Client.generate/2` (the existing behaviour, pluggable/
  stubbable via config).
- Reuses the article-text extraction already used by enrich/embed for article
  bodies (blocks JSONB → plain text); comments/messages use `body` directly.
- Truncates text to a sane cap (e.g. 4_000 chars) before prompting.
- Parses + validates the JSON; malformed output → `{:error, :invalid}`.

### 3. `Moderation.Workers.AutoModerateWorker` (new)

File: `lib/verscienta/moderation/workers/auto_moderate_worker.ex`

- `use Oban.Worker, queue: :ai, max_attempts: 3, unique: [...]` — unique per
  `{subject_type, subject_id}` over a short period (mirrors EnrichArticleWorker).
- Args: `%{"subject_type" => ..., "subject_id" => ...}`.
- Steps:
  1. Re-check `Flags.enabled?(:auto_moderation)`; if off → `:ok` (no-op).
  2. Load the subject's current text via `Moderation.Subject` (extend with a
     text accessor) or a small per-type loader. If the subject is gone →
     `:ok` (discard).
  3. `Detector.analyze/2`.
  4. Map verdict → flag(s):
     - toxic over threshold → `reason: :harassment`
     - (article only) dubious_claim true → `reason: :misinformation`
     - `note` = the model's rationale (`toxicity_reason` / `claim_reason`),
       truncated to the `note` 1000-char limit.
     - If both trip on an article, prefer one flag with the most severe reason
       (single flag per subject due to the partial-unique identity); include
       both rationales in the note.
  5. Create via `Flag` `:ai_flag` action with `authorize?: false`. Upsert
     identity makes a duplicate a harmless no-op.
- Error handling (mirror enrich worker):
  - `{:error, :timeout | network}` → return `{:error, reason}` to retry.
  - `{:error, :invalid}` (parse/permanent) → log warn, return `:ok` (discard).
  - Ollama unavailable → graceful: log, `:ok` (no flag). Never raises.

### 4. Enqueue wiring

New change: `lib/verscienta/moderation/changes/enqueue_auto_moderate.ex`
(`after_action`). Inserts the worker job for the created/published subject, but
**only** when `Flags.enabled?(:auto_moderation)` — otherwise no-op so jobs don't
pile up while the flag is off.

Wire it in:
- `Engagement.Comment` `:create` — after `RejectIfSuspended`.
- `Content.Article` `:publish` — alongside `EnqueueEnrich`/`EnqueueEmbedding`.
- `Communities.Message` `:post` — after `RejectIfSuspended`.

The change must read the persisted record (id + type) in `after_action`.

### 5. Thresholds / config

`config :verscienta, Verscienta.Moderation,` with defaults, e.g.:
- `toxicity_min_severity: :high` (flag when severity is `:high`)
- Reads are via a small `Detector`/worker config helper so tests can override.

### 6. Queue UI

File: `lib/verscienta_web/live/admin_moderation_live.ex` (+ template)

- Render AI-sourced flags with a label (e.g. "🤖 Flagged by AI") and handle a
  `nil` reporter gracefully (no crash, no "reported by —").
- `pending_groups/0` already returns pending flags; AI flags appear because they
  are `status: :pending`. Confirm the grouping/queue read does not assume a
  non-nil reporter.

## Testing

Stub `AI.Client` via config (already supported by the behaviour):

- Toxic comment → one AI flag, `source: :ai`, `reason: :harassment`, populated
  `note`, `subject_excerpt`/`subject_author_id` captured.
- Dubious article → AI flag `reason: :misinformation`.
- Toxic article that is also dubious → single flag, most-severe reason, both
  rationales in note.
- Clean content → no flag.
- `:auto_moderation` off → no job enqueued (assert no Oban job).
- Ollama error / invalid JSON → no flag, worker returns without raising.
- Duplicate guard: running the worker twice for the same subject → still one
  pending AI flag.
- Comment/message verdict with `dubious_claim: true` → ignored (toxicity-only).

Use `Oban.Testing` (jobs are queued-not-run in test env) to assert enqueue, and
run the worker directly (`perform_job/2`) for the create-flag assertions.

## Out of scope (next todo items)

- Auto-actions: hold / shadow / escalate, with audit log.
- AI writing assistant for authors.
- Reporter-resolution notifications; hide-report affordance on already-reported
  subjects (separate fast-follows).

## Files touched (summary)

- `lib/verscienta/moderation/flag.ex` — `source`, nullable reporter, `:ai_flag`
  action, `unique_ai_subject` identity.
- `lib/verscienta/moderation/detector.ex` — **new**.
- `lib/verscienta/moderation/workers/auto_moderate_worker.ex` — **new**.
- `lib/verscienta/moderation/changes/enqueue_auto_moderate.ex` — **new**.
- `lib/verscienta/moderation/subject.ex` — add text accessor (if needed).
- `lib/verscienta/engagement/comment.ex` — wire enqueue change.
- `lib/verscienta/content/article.ex` — wire enqueue change.
- `lib/verscienta/communities/message.ex` — wire enqueue change.
- `lib/verscienta_web/live/admin_moderation_live.ex` (+ template) — AI label /
  nil-reporter handling.
- `priv/repo/migrations/*_add_flag_source_and_ai_identity.exs` — **new**.
- `config/config.exs` (+ `config/test.exs`) — Moderation thresholds / client stub.
- Tests across the above.
