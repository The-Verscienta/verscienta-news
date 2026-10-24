# Slice 1 — first shippable

**Goal:** one category of articles a person can read on the fired Kiln page, with trust ahead of engagement.

The public URL is the article alias `/[field:category]/[slug]`. Kiln fires that page. Slice 1 has no second reader.

Kiln workflow states are `draft`, `in_review`, `published`, and `archived`. Ingested drafts are created in `in_review`. There is no `pending_review` state. The review queue is `/editor?status=in_review`. There is no `/editor/moderation` route.

## In

- `VerscientaNews.Catalog.Article` (`type: :article`, alias `/[field:category]/[slug]`).
- Allowlist registry `VerscientaNews.Ingestion.Allowlist`, mirrored in `docs/source-rights.md`. The poller refuses a host that is not in the registry.
- `VerscientaNews.Ingestion.Poller` (Oban cron `*/15 * * * *`, Req, Floki, ElixirFeedParser). `Poller.apply_license/1` truncates or drops the body **before** it is stored.
- Every ingested draft is `in_review` until a human approves it. No score threshold.
- Ollama is optional and advisory. A down Ollama leaves the draft in `in_review`.
- Human review on `/editor?status=in_review`, using the checklist in `docs/moderation.md`. Approve moves `in_review` → `published`.
- Fired page shows attribution, the medical disclaimer, and the claim badge.
- Search is Kiln Postgres full text.

## Out

Follows, comments, reactions, reposts, communities, activity feeds, `VerscientaNews.FollowGraph`. Vitality, points, badges, leaderboards, quests, reward store. For You and other recommendations. Meilisearch and pgvector search. LiveKit and live rooms. A Svelte reader, Svelte TipTap, and a Next.js app. Broadway. Redis and Dragonfly. Newsletter sends and billing checkout (Kiln already contains both; using them is not a Slice 1 exit). Verified Expert and a `verified` claim status.

## Exit criteria

All of these pass:

- `mix kiln.plugins.doctor` is green.
- `VerscientaNews.Ingestion.Allowlist` is the only poll registry. Each entry has `url`, `license`, `attribution_text`, `robots`, `robots_notes`, `owner_contact`, and `takedown_sla`. `Poller.allowlisted?/1` is false for a host that is not listed. `mix test test/verscienta_news/allowlist_test.exs` passes.
- Seed 20 items across 2 categories. Each stays `in_review` until a human approves it. The fired `/[field:category]/[slug]` page shows attribution, the disclaimer "Not medical advice — for information only. Consult a qualified professional.", and claim status.
- A second poll of the same `source_url` does not create a duplicate. `excerpt_link` sources store at most 280 characters of plain text. `link_only` sources store no body. `full_text` sources may store the body.
- With the `ml` Compose profile stopped, 3 new polls remain `in_review` and unpublished.
- Kiln search returns the seeded articles.
- Removing a source from `Allowlist` causes the poller to reject that host. Taking down a URL unpublishes it and adds it to the blocklist checked before insert.
- The Slice 1 build does not add `Broadway`, `Leaderboard`, `LiveKit`, or `VerscientaNews.Social` to `ash_domains`.

## Approve

See the checklist in `docs/moderation.md`. Approve publishes. It does not set `claim_status` to `verified`. `claim_status` in Slice 1 is `unreviewed`, `flagged`, or `cleared`.

## Non-goals

Svelte offline, a native app, a headless Astro or Next.js site, and ops hardening beyond a single Postgres node.

## After exit

1. Verified Expert, which may add claim status `verified`, and richer moderation tooling.
2. Follow graph: follows, comments, reactions, activity.
3. A Svelte reader of the fired page.
4. Meilisearch and recommendations, with a cold-start spec.
5. Gamification only if the metrics are not dwell time and not pay-to-rank.
