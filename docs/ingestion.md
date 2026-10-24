# Ingestion — Oban poller (Slice 1)

Status: Oban + Req. No Broadway. Scope is `docs/slice-1.md`. The legal gate is `VerscientaNews.Ingestion.Allowlist`, described in `docs/source-rights.md`.

## Flow

Every ingested draft is created in Kiln state `in_review`.

1. **Registry.** `VerscientaNews.Ingestion.Allowlist.sources/0` is the list of feeds. `Poller.allowlisted?/1` is false for any other host. Dedupe is a unique `source_url` on the article. It is not a hash of the title.
2. **Poller.** `VerscientaNews.Ingestion.Poller`, Oban cron `*/15 * * * *`. `Req` fetches the allowlisted URL. `ElixirFeedParser` parses RSS. `Floki` parses HTML only after `robots.txt` allows it. The draft record is a `NormalizedArticle` with `source_url`, `title`, `html`, `published_at`, and `source`.
3. **License, before storage.** `Poller.apply_license/1` copies `source_license`, `attribution_text`, and `robots` from the registry, then:
   - `full_text` keeps the body
   - `excerpt_link` replaces `html` with at most 280 characters of plain text
   - `link_only` sets `html` to `nil`
4. **AI, advisory.** `VerscientaNews.AI.Llama.enrich/1` may add `ai_summary`, `ai_tags`, `claim_status` (`unreviewed` or `flagged`), and `toxicity_flag`. Those fields do not publish the article. Ollama down logs `{:error, :ollama_unavailable}`, stores the draft without AI fields, and leaves it `in_review`. Local Ollama is Compose profile `ml`.
5. **Draft.** The bridge creates `VerscientaNews.Catalog.Article` in state `in_review`. It does not set a disclaimer acknowledgement. The disclaimer is rendered by the fired template. A `flagged` claim or a toxicity flag opens a `ModerationFlag`. `score/1` returns an advisory map and has no publish effect.

## Verify

```
cd kiln_cms && mix test test/verscienta_news/allowlist_test.exs
# Stop the ml profile: 3 polls → 3 articles in in_review, 0 published
```
