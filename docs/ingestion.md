# Ingestion — Broadway pipeline (Codex Phase 1 stubs)

Status: **stubs only** — modules below compile without `broadway` dep; enable by adding `{:broadway, "~> 1.1"}` to overlay `mix.exs` and wiring Oban.

## Flow

1. **Sources** (`config/sources.exs` not yet — hard-coded in `Sources` module): RSS feeds, JSON APIs, HTML scrape URLs. Each source declares `category` hint, `trust_score`, `poll_interval`.
2. **Broadway** (`VerscientaNews.Ingestion.Pipeline`): producer polls, `Floki`/`Req` fetch, `ElixirFeedParser` for RSS, normalize to `%NormalizedArticle{url, title, html, published_at, source, category_guess}`. `Broadway.Batchers` dedupe (SHA256 url+title).
3. **AI stage** (`VerscientaNews.AI.Llama.enrich/1`): POST to Ollama; returns `ai_summary`, `ai_tags`, `quality_score`, `toxicity`. Degrades: if Ollama down, publish without AI fields and log `{:error, :ollama_unavailable}`.
4. **Bridge** (`VerscientaNews.Ingestion.Bridge.create_draft/1`): maps to Kiln `Post`/`Article` blocks (`rich_text` from HTML → Portable Text), sets `quality_score`/`source_url` custom fields, state `pending_review` if `quality_score < 75` or flagged.

## Quality rubric (AI prompt)

- 0–100: freshness (30), source trust (30), completeness (20), claim density/hedging (20). ≥75 auto-publish eligible.

## Stub files

- `projects/verscienta_news/services/pipeline.ex`
- `projects/verscienta_news/services/ai_llama.ex`
- `projects/verscienta_news/services/recommendation.ex`

Add deps then run `mix kiln.plugins.doctor && mix test test/verscienta_news/ingestion_test.exs` (fixture RSS in `test/fixtures/rss/`).
