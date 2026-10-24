# AI / Ollama Enrichment Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-04
**Status:** Approved
**Phase:** 2 (Social & Gamification) — Subsystem 6 of 7: AI / Ollama Enrichment
**Depends on:** Phase 1 (Content: Article, Tag) + the aggregation pipeline. Reuses the
external-service client pattern (behaviour + `Req` impl + test `Stub`, à la `Search.Client` /
`Images.Client`), the after-action best-effort Oban enqueue pattern (`EnqueueIndex`), the
graceful-degradation precedent (`Search.Setup` rescue + `Logger.warning`), and the tag
find-or-create idiom (`manage_relationship` + `Tag.upsert_by_name`).

## Goal

Enrich articles with a local LLM (Ollama) — generate a **summary** (→ `excerpt`), **auto-tags**,
a **category** suggestion, and an **evidence-level** classification — via a single JSON-mode call,
written back to the article. **Aggregated** (machine-ingested) articles get **full enrichment**
(AI overwrites the four fields). **User-authored** articles get **fill-empty only** (AI fills
fields the author left blank; never overwrites author curation). Everything is **best-effort**:
Ollama being down or slow never blocks ingest, publishing, or app boot.

## Decisions

| Decision | Choice |
|----------|--------|
| Namespace | Plain `Verscienta.AI` modules (no Ash domain — no new resources) |
| Client | `Verscienta.AI.Client` behaviour + `.Req` impl + test `.Stub`; selected via `config :verscienta, :ai_client` |
| Transport | Ollama `POST /api/generate`, `stream: false`, `format: "json"` (forced JSON), `model` from config |
| Model | `ollama_model` config, default `"llama3.2:3b"` (prod reads `OLLAMA_MODEL`) |
| Enrichments | summary → `excerpt`, auto-tags, category suggestion, evidence-level scoring (all four, one call) |
| Target | **Aggregated:** full enrich (overwrite all four). **User articles:** fill blank fields only; `category` never touched (always author-set) |
| Category (aggregated) | AI **overrides** the source-assigned category, validated against the enum; falls back to existing category if the model returns junk |
| Write-back | A system `update :ai_enrich` action on `Article` (`authorize?: false`), invoked only by the worker |
| Queue | New Oban `:ai` queue (`ai: 3`); worker unique by `article_id`, `max_attempts: 3` |
| Hooks | After-action enqueue on `:create_aggregated` and `:publish` (best-effort) |
| Backfill | `mix verscienta.ai_backfill` enqueues enrichment for existing articles |
| Degradation | Client error → worker retries then gives up; parse/validation failure → no-op; boot never needs Ollama; dev without Ollama simply no-ops |
| Deferred | Embeddings / semantic search (Phase 3 pgvector); on-demand "summarize for me" UI; per-user AI; streaming; moderation/safety classification; re-enrichment scheduling |

## Components

### `Verscienta.AI.Client` (behaviour + impls)
- **Behaviour:** `@callback generate(prompt :: String.t(), opts :: keyword) :: {:ok, String.t()} | {:error, term}`.
  Public `generate/2` delegates to `impl()` = `Application.get_env(:verscienta, :ai_client, __MODULE__.Req)`.
- **`.Req`:** POSTs `%{model: model, prompt: prompt, stream: false, format: "json"}` to
  `#{ollama_url}/api/generate` with a bounded `receive_timeout` (e.g. 60s — local inference is slow).
  Returns `{:ok, response_text}` (the `"response"` field, a JSON string) on 2xx, `{:error, …}` otherwise.
- **`.Stub`** (`test/support/`): returns a canned JSON string (configurable via app env, like
  `ClientStub`), records calls. Tests never hit the network.

### `Verscienta.AI` (context)
- `enrich_article(article)` — the orchestration entry point (called by the worker):
  1. Build plain text from the article: `title` + body via the search subsystem's `blocks_to_text`
     (truncate to a sane char budget so prompts stay bounded).
  2. Build the prompt (see below) and call `Client.generate/2`.
  3. Parse the returned JSON; validate (`parse_enrichment/1`).
  4. Compute the write-set by mode (`aggregated?` → full; else fill-empty), then call
     `Article.ai_enrich`. If nothing to write (empty set), no-op.
  - Wrapped so any failure returns `{:error, reason}` (the worker decides retry); never raises into
    the caller.
- `parse_enrichment/1` — decode JSON → `%{summary, tags, category, evidence_level}`:
  - `summary`: string, trimmed, truncated to the excerpt limit (300); blank → dropped.
  - `tags`: list of strings, trimmed, de-duped, capped (≤5), empties dropped.
  - `category`: only kept if it maps to one of the 8 enum atoms; else dropped.
  - `evidence_level`: only kept if one of `[:anecdotal, :emerging, :established]`; else dropped.
  - Malformed JSON / wrong shape → `{:error, :invalid}` (caller no-ops, no retry storm).

### Prompt
A single instruction asking the model to return **only** JSON with keys `summary` (1–2 sentences),
`tags` (3–5 lowercase topic tags), `category` (exactly one of the 8 wellness categories, listed),
and `evidence_level` (one of the 3, defaulting to `anecdotal` for general/lifestyle content). The
8 categories and 3 evidence levels are enumerated verbatim in the prompt so the model picks valid
values. `format: "json"` guarantees syntactically valid JSON; validation guards semantics.

### `Verscienta.AI.Workers.EnrichArticleWorker`
- `use Oban.Worker, queue: :ai, max_attempts: 3, unique: [keys: [:article_id], period: 60, states: incomplete]`.
- `perform/1`: load the article (`authorize?: false`; skip if missing); call `AI.enrich_article/1`.
  Return `:ok` on success; return `{:error, reason}` to let Oban retry on a transient client error;
  return `:ok` (discard) on a permanent parse failure so it doesn't churn retries.

### `Article` write-back action
```
update :ai_enrich do
  description "System action: write AI-derived fields. Worker-only (authorize?: false)."
  require_atomic? false
  accept [:excerpt, :category, :evidence_level]
  argument :tags, {:array, :string}, default: []
  change manage_relationship(:tags, :tags, type: :append, value_is_key: :name,
           use_identities: [:unique_name], on_lookup: :relate, on_no_match: {:create, :upsert_by_name})
  change Verscienta.Content.Article.Changes.EnqueueIndex   # re-index so search reflects new summary/tags
end
```
- **Policy:** `policy action(:ai_enrich) do forbid_if always() end` (system-context only, like
  `:create_aggregated`). The worker calls it with `authorize?: false`.
- The **worker** decides what to pass: aggregated → all four; user article → only `excerpt` (if
  currently blank), `evidence_level` (if `nil`), `tags` (if the article has none); never `category`
  for user articles. Group articles still skip re-indexing inside `EnqueueIndex` (existing behaviour).

### Enqueue hook — `Changes.EnqueueEnrich`
Mirrors `EnqueueIndex`: an after-action change that best-effort-inserts an `EnrichArticleWorker` job
(`rescue` → `Logger.warning` → `:ok`). Added to `:create_aggregated` (always) and `:publish` (so
user articles get fill-empty enrichment on publish). Idempotent via the worker's `unique`.

### Backfill — `mix verscienta.ai_backfill`
Streams existing articles (default: aggregated ones; optionally all published) and enqueues an
`EnrichArticleWorker` per article. Logs a count of what was enqueued. (No silent caps; if a batch
limit is applied, log it.)

## Config
- `config/runtime.exs`: keep `ollama_url`; add `ollama_model: System.get_env("OLLAMA_MODEL", "llama3.2:3b")`.
  Prod block reads the same env (no raise required — degradation is graceful — but document the vars).
- `config/config.exs`: `config :verscienta, ai_client: Verscienta.AI.Client.Req` and add `ai: 3` to
  the Oban `queues`.
- `config/test.exs`: `config :verscienta, ai_client: Verscienta.AI.Client.Stub`.
- Dev: default `Req` (uses local Ollama if running; graceful no-op otherwise — no separate dev impl).

## Graceful degradation (critical)
- **Ollama down/unreachable/timeout** → `Client.generate` returns `{:error, …}` → worker returns
  `{:error, …}` → Oban retries up to `max_attempts`, then the job is discarded. The article keeps
  its pre-AI fields. Nothing user-facing fails.
- **App boot** never contacts Ollama (unlike the meili index setup, there's no boot-time AI call).
- **Parse/validation failure** → `enrich_article` returns `{:error, :invalid}`; the worker treats it
  as permanent (returns `:ok`/discard) so a consistently-bad response doesn't retry-storm.
- **Enqueue failure** (Oban insert) → rescued + logged; ingest/publish still succeed.

## Testing & gates
- **Client/Stub:** stub returns canned JSON; `generate/2` dispatch resolves to the stub in test.
- **Parsing:** valid JSON → all four fields; invalid category/evidence dropped; >5 tags capped;
  blank summary dropped; malformed JSON → `{:error, :invalid}`.
- **Enrich (aggregated):** all four fields written (summary→excerpt, tags attached, category
  overwritten, evidence set); search re-index enqueued.
- **Enrich (user article, fill-empty):** only blank fields filled; author-set `excerpt`/`category`/
  tags preserved; `category` never changed.
- **Category override fallback:** model returns an out-of-enum category → existing category kept.
- **Degradation:** client `{:error, …}` → article unchanged, worker returns error (retryable);
  permanent parse failure → article unchanged, no retry storm.
- **Hooks:** `:create_aggregated` and `:publish` enqueue an `EnrichArticleWorker` (assert via
  `Oban.Testing`); enqueue is best-effort (failure doesn't break the action).
- **Backfill:** `mix verscienta.ai_backfill` enqueues one job per target article.
- **Isolation preserved:** `ai_enrich` re-index still respects `is_nil(group_id)` (group articles
  not indexed).
- CI gates: `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`,
  `MIX_ENV=test mix test`. Migration (the new `:ai_enrich` action needs none — same columns) via
  `mix ash.codegen` if Ash generates anything; run it to confirm a clean diff. Test DB reset with
  `ecto.drop && ecto.create && ash.migrate` (not `ash.setup`) to avoid seed contamination.

## Out of scope (deferred)
- Embeddings / vector semantic search (Phase 3, `pgvector`).
- On-demand user-triggered "summarize this" UI; per-user AI assistants; chat.
- Streaming responses; token-by-token UI.
- Moderation / safety / toxicity classification.
- Automatic re-enrichment scheduling / cache invalidation; model A/B selection.
- Translating or rewriting article bodies (we only set metadata fields, never rewrite `blocks`).

## Definition of Done
- `Verscienta.AI.Client` (behaviour + `Req` + `Stub`), `Verscienta.AI` context (enrich + parse),
  `EnrichArticleWorker` on the `:ai` queue.
- `Article.ai_enrich` system action (forbidden by policy; worker uses `authorize?: false`); tag
  append + re-index.
- `Changes.EnqueueEnrich` wired into `:create_aggregated` + `:publish` (best-effort).
- `mix verscienta.ai_backfill` task.
- Config: `ollama_model`, `ai_client` (Req prod/dev, Stub test), `ai` Oban queue.
- Full enrich for aggregated (category overridden + validated); fill-empty for user articles.
- Graceful degradation throughout; all gates green; work committed on `ai-ollama`.
