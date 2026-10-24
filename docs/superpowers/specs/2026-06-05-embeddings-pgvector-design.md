# Embeddings + pgvector Foundation Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-05
**Status:** Approved
**Phase:** 3 — Intelligence & Growth · Recommendation & Personalization (slice 2 of 4)
**Depends on:** Content (Article/Tag), AI (Ollama client + enrichment pipeline), `Verscienta.Recommendations` (slice 1), Oban, AshPostgres. **A pgvector-capable Postgres image** (the one external dependency).

## Goal

Stand up the semantic foundation for personalization: generate a vector **embedding** per published article via Ollama, store it in Postgres with **pgvector**, keep it fresh on content changes, and expose a **`Recommendations.similar/2`** primitive that returns the most semantically-similar articles by cosine distance. This slice ships the pipeline + the primitive (fully tested); the consumers are slice 3 (related-content UI) and slice 4 (personalized search + For You hybrid) — **no user-facing UI here.** Uses Ash's native `:vector` type + AshPostgres `vector_cosine_distance` — **no new hex dependency.**

## Decomposition context

Slice 1 (signal-based For You) shipped. This is slice 2. Remaining: slice 3 (related-content module on article pages), slice 4 (personalized search ranking + For You v2 hybrid).

## Decisions

| Decision | Choice |
|----------|--------|
| Embedding model | **`nomic-embed-text`** (768-dim, 8k context) via Ollama |
| Vector storage | pgvector `vector(768)` column on `articles`; **Ash native `:vector` type**, no new dep |
| Index | **HNSW** with `vector_cosine_ops` (cosine distance) |
| Embedded text | `"search_document: " <> title <> excerpt <> body_text` (nomic doc-prefix), truncated to a char budget |
| Generation trigger | On `:publish`, `:create_aggregated`, **and re-embed on** `:update` / `:ai_enrich`; plus a one-time backfill |
| Degradation | Oban worker, feature-flag-gated; Ollama-down → retry; article writes never blocked |
| Postgres image | compose `db` → **`pgvector/pgvector:pg16`** (drop-in for `postgres:16`) |
| This slice's output | The pipeline + `Recommendations.similar/2`; **no UI** (slice 3) |

## Section 1: Infrastructure (pgvector)

- **Compose**: change the `db` service image from `postgres:16` to `pgvector/pgvector:pg16`. It is the official PG16 image plus the `vector` extension; the existing data volume is compatible (same PG16 data layout). Document that production Postgres (Coolify) must also be pgvector-capable.
- **`lib/verscienta/repo.ex`**: `installed_extensions/0` → `["ash-functions", "citext", "vector"]`. The Ash migration generator emits `CREATE EXTENSION IF NOT EXISTS "vector"`.
- **`Article` resource** (`lib/verscienta/content/article.ex`):
  - `attribute :embedding, :vector` with `constraints: [dimensions: 768]`, `public?: false`, `allow_nil?: true`.
  - A system update action `:set_embedding` (`accept [:embedding]`, `authorize?: false`, no after-action hooks that would re-enqueue work) that the worker writes through.
  - A `custom_indexes` entry for the **HNSW** index on `embedding` using `vector_cosine_ops` (declared so the generated migration creates it; written manually in the migration if the generator can't express HNSW options).
- **Migration**: extension + `embedding vector(768)` column + the HNSW cosine index. Generated via `mix ash.codegen`, hand-adjusted for the index if needed.

## Section 2: AI embedding client

- **`Verscienta.AI.Client`**: add `@callback embed(text :: String.t(), opts :: keyword) :: {:ok, [float()]} | {:error, term()}` and a dispatcher `embed/2`.
- **`Verscienta.AI.Client.Req`**: `embed/2` POSTs `#{ollama_url}/api/embeddings` with `%{"model" => embed_model(opts), "prompt" => text}`; on `{:ok, %{status: 200..299, body: %{"embedding" => v}}}` returns `{:ok, v}`; non-2xx → `{:error, {:http_status, …}}`; transport error → `{:error, reason}`. Generous `receive_timeout` (local inference).
- **Config**: `ollama_embed_model` (default `"nomic-embed-text"`), reusing `ollama_url`. Added in `config/config.exs` defaults + `config/runtime.exs` (env-overridable like `ollama_model`).
- **`Verscienta.AI.Client.Stub`** (test): implement `embed/2` returning a deterministic vector (e.g., a fixed 768-length list, or derived from the text length) so worker tests are reproducible without real inference.
- **`Verscienta.AI.embed_article/1`**: builds the document text — `"search_document: "` prefix + title + excerpt + body text (reuse the blocks→text extractor currently private in `Verscienta.Search.Document`; expose it as a shared public helper rather than duplicating), truncated to a fixed char budget (~6000 chars) to stay within the model context. Calls `Client.embed/2`. Returns `{:ok, vector}` | `{:error, reason}`; never raises out to the caller.

## Section 3: Generation pipeline (mirrors AI enrichment)

- **`EmbedArticleWorker`** (`lib/verscienta/ai/workers/embed_article_worker.ex`, Oban queue `:ai`, `unique` per `article_id`, `max_attempts: 3`): gated by the `:embeddings` feature flag (returns `:ok` immediately when off, like the enrichment worker's `:ai_enrichment` gate). Loads the article; `AI.embed_article/1`; on `{:ok, v}` writes via `:set_embedding`; on `{:error, _}` returns the error so Oban retries (graceful degradation — the article already exists, the embedding fills in later).
- **`EnqueueEmbedding`** change (`lib/verscienta/content/article/changes/enqueue_embedding.ex`): an `after_action` that inserts `EmbedArticleWorker` for the article id. Wired onto `:publish`, `:create_aggregated`, `:update`, and `:ai_enrich` (the embeddable content — title/excerpt/blocks — changes on these; `:ai_enrich` rewrites the excerpt after publish). Skips drafts (only enqueue when the resulting article is `:published`).
- **Backfill**: `mix verscienta.embeddings.backfill` enqueues `EmbedArticleWorker` for every published article with `is_nil(embedding)`. Mirrors the enrichment backfill.
- **Feature flag**: add `:embeddings` to the FunWithFlags set (enabled in dev/loadtest seeds where appropriate; the worker no-ops when off).

## Section 4: The similarity primitive

`Verscienta.Recommendations.similar(article, opts \\ [])` (`opts[:limit]` default 10):

- Returns `[]` immediately if `article.embedding` is nil.
- Queries `Article` filtered: `status == :published and is_nil(group_id) and is_nil(author.deactivated_at) and is_nil(author.anonymized_at) and id != ^article.id and not is_nil(embedding)` — the same eligibility filters used by `:list_published` and `Candidates`.
- Sorts ascending by cosine distance to `article.embedding` using AshPostgres `vector_cosine_distance(embedding, ^article.embedding)` (a sort calculation / fragment), limited to `limit`, `:tags` loaded for downstream rendering.
- Lives in `lib/verscienta/recommendations/similar.ex` (or as a function in the `Recommendations` context) — a focused unit consumed by slices 3-4.

## Section 5: Config & ops

- `config/config.exs`: `ollama_embed_model: "nomic-embed-text"` default; `config/runtime.exs`: env override (`OLLAMA_EMBED_MODEL`).
- The Ollama box must `ollama pull nomic-embed-text` — a deploy/runbook step (the dev Ollama is the opt-in `--profile ai` compose service). Document in the README/runbook.
- `docs/todo.md`: the embeddings item under Recommendation & Personalization checked off.

## Section 6: Testing

- **`AI.embed_article/1`** (stub client): asserts the assembled text (prefix + title + excerpt + body), truncation at the budget, and `{:ok, vector}` / `{:error, _}` passthrough.
- **`EmbedArticleWorker`** (Oban testing + stub): running the job sets `article.embedding`; flag-off → no-op `:ok`; client error → job error (retry).
- **`EnqueueEmbedding`**: publishing / `:create_aggregated` enqueues the worker (Oban `assert_enqueued`); a draft create does not.
- **`Recommendations.similar/2`**: set **known** embeddings directly on a few articles (via `:set_embedding`), assert nearest-by-cosine ordering, self/unpublished/group/deactivated-author exclusion, and `[]` for an article with no embedding — deterministic, no real inference.
- Full suite + `credo --strict` + `dialyzer` green; format clean. DataCase/loadtest DBs get the `vector` extension via the migration on the pgvector image.

## Out of scope (deferred)

Related-content UI on article pages (slice 3); personalized search ranking + For You v2 hybrid (slice 4); query-side `embed_query/1` for free-text semantic search (slice 3+); re-ranking/MMR diversity over neighbors; multi-model / re-embedding-on-model-change migration; the actual `ollama pull` (a deploy step, documented).

## Definition of Done

- compose `db` on `pgvector/pgvector:pg16`; `vector` extension installed; `articles.embedding vector(768)` + HNSW cosine index; `Article` `:embedding` attr + `:set_embedding` action.
- `AI.Client.embed/2` (Req + stub) + `ollama_embed_model` config; `AI.embed_article/1` (prefixed, truncated, graceful).
- `EmbedArticleWorker` + `EnqueueEmbedding` (publish/aggregated/update/ai_enrich, published-only) + `:embeddings` flag + `mix verscienta.embeddings.backfill`.
- `Recommendations.similar/2` with full eligibility filters + cosine ordering; `[]` when unembedded.
- Tests across embed_article / worker / enqueue / similar (deterministic, known-vector); full suite + credo + dialyzer green.
- README/runbook note: pgvector image + `ollama pull nomic-embed-text`; `docs/todo.md` item checked off.
- **No new hex dependency.**
