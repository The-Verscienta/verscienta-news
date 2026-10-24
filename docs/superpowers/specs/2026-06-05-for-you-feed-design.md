# For You Feed (Signal-Based Personalization) Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-05
**Status:** Approved
**Phase:** 3 — Intelligence & Growth · Recommendation & Personalization (slice 1 of 4)
**Depends on:** Content (Article/Tag/Category), Engagement (Reaction/Comment/Bookmark), Social (Follow/Repost/`trending`/`following_feed`), Gamification (`:reading` events), `Verscienta.Cache` (all merged to main). **No new deps; no pgvector.**

## Goal

Add a personalized **"For You"** feed as a fourth tab on the article feed, ranking recent articles for each user by a blend of their **explicit interests** (followed categories/tags), **inferred affinity** (learned from their own engagement history), **social proof** (engagement by people they follow), **freshness**, and a small **global-quality** prior. It is a *discovery* feed: it excludes content the user has already seen or authored, and backfills from Trending when personalized signal is thin. Everything runs on existing data and the existing two-tier cache — no embeddings, no new infrastructure. Semantic/embedding personalization is slice 2 (`pgvector`), a separate spec.

## Decomposition context

"Recommendation & Personalization" is decomposed into four sequential slices, each its own spec → plan → build cycle:

1. **For You v1 — signal-based ranking (this spec).**
2. Embeddings + `pgvector` foundation (Ollama `/api/embeddings`, embedding worker, `:vector` column).
3. Related-content module on article pages.
4. Personalized search ranking + For You v2 (hybrid, folds in semantic similarity).

## Decisions

| Decision | Choice |
|----------|--------|
| Relevance model | **Explicit + inferred affinity + social proof + freshness + global-quality prior** (all existing signals) |
| Compute model | **Compute-on-read at mount**, with per-user caching (final list + slow-changing affinity profile cached separately) |
| Candidate character | **Discovery feed**: exclude the user's own articles + anything already engaged with (read/reacted/bookmarked/reposted/commented) |
| Cold-start / thin signal | **Backfill with Trending** so the page is always full; subtle "follow topics" nudge when signal is low |
| Diversity | **Per-category cap** (~40% of a page max from any one category) |
| Default tab | **For You is the default tab for authenticated users**; anonymous users default to Latest and don't see the For You tab |
| New infra | **None** — plain context module, existing `Verscienta.Cache`, no tables/workers/deps |

## Section 1: Module boundaries

A new plain context module `Verscienta.Recommendations` (sibling to `Social.trending` — **not** an Ash domain), decomposed into small, single-purpose, independently-testable units:

- **`Verscienta.Recommendations`** — public entry point. `for_you(user, opts \\ [])` orchestrates: load profile (cached) → query candidates → fetch social-proof counts → score → diversity-cap → backfill → cache. Returns feed items in the **same shape `Social.following_feed/2` returns** (`%{type: :article, article: %Article{}, repost: nil, timestamp: published_at}`) so the existing feed template renders them unchanged. Also exposes `personalized?(user)` (does the user have any explicit/affinity signal?) to drive the nudge.
- **`Recommendations.Candidates`** — `recent(user, opts)`: the eligible-article query (published, `group_id` nil, `published_at` within the window, minus excluded ids), capped to a bounded pool.
- **`Recommendations.AffinityProfile`** — `for_user(user)`: computes (and caches) the user's interest profile from their engagement history. Pure builder `build(engagements, follows)` is unit-testable without the cache.
- **`Recommendations.Scorer`** — **pure**: `score(candidate, profile, social_count, weights) → float`. No DB, no cache. The heart of the ranking, fully deterministic and unit-tested.

File layout: `lib/verscienta/recommendations.ex` + `lib/verscienta/recommendations/{candidates,affinity_profile,scorer}.ex`.

## Section 2: The affinity profile

`AffinityProfile.for_user/1` returns:

```elixir
%{
  followed_categories: MapSet.t(category_atom),   # from Social.follows_by_type/1
  followed_tag_ids:    MapSet.t(tag_id),
  category_affinity:   %{category_atom => float}, # learned weights, 0..1-ish
  tag_affinity:        %{tag_id => float}
}
```

**Affinity computation.** Gather the user's engagement rows across reactions, bookmarks, non-deleted comments, reposts, and `:reading` gamification events (subject_type `:article`). Each row contributes its engaged `article_id` + a **type weight** × a **recency decay**:

- Type weights (engagement strength): `bookmark: 1.0`, `repost: 1.0`, `comment: 0.7`, `reaction: 0.5`, `reading: 0.3`.
- Recency decay: exponential on the engagement timestamp, ~30-day half-life (older engagement counts less).

Load the distinct engaged articles (with `category` + `tag_ids`) and accumulate each article's weighted contribution onto its category and each of its tags. Normalize category/tag affinity maps to their max so weights are comparable across users. Bounded by the user's own engagement volume.

`followed_categories`/`followed_tag_ids` come straight from `Social.follows_by_type(user.id)` (`:category` values and `:tag` ids).

## Section 3: The scoring model

For a candidate article `C` and profile `P`:

```
score(C) = w_explicit  * explicit(C, P)
         + w_affinity  * affinity(C, P)
         + w_social    * social(C)
         + w_freshness * freshness(C)
         + w_quality   * quality(C)
```

- **explicit** — `(C.category ∈ P.followed_categories ? 1 : 0) + |C.tags ∩ P.followed_tag_ids|`.
- **affinity** — `P.category_affinity[C.category] + Σ P.tag_affinity[t] for t ∈ C.tags`.
- **social** — number of distinct users the viewer follows who engaged with `C` (precomputed for the candidate set; see §4).
- **freshness** — `exp(-ln2 * age_days / 5)` (≈5-day half-life).
- **quality** — small global prior reusing the trending engagement score (recent reactions×1 + comments×2), normalized, so strong content still surfaces with low personal signal.

**Tunable weights** live in one config block on `Recommendations` (the load-test `@thresholds` pattern), defaults e.g. `%{explicit: 3.0, affinity: 2.0, social: 2.0, freshness: 1.5, quality: 0.5}`.

**Diversity cap.** After sorting by score desc, greedily re-rank so no single `category` exceeds ~40% of the returned page; overflow items are deferred and only used if needed to fill the page. Keeps the feed from collapsing to one topic.

## Section 4: Data flow, candidate generation & social proof

`for_you(user, opts)` (`limit` default 30):

1. **Profile** — `AffinityProfile.for_user(user)` (cached, §5).
2. **Candidates** — `Candidates.recent(user, window_days: 30, pool: 500)`: `status == :published and is_nil(group_id) and published_at >= ago(30, "day")`, **excluding** `author_id == user.id` and `id ∈ engaged_ids`, ordered `published_at desc`, limited to the pool size. `engaged_ids` = the union of the user's reaction/bookmark/comment/repost article ids + `:reading` event subject ids (one bounded query per source, unioned).
3. **Social proof** — for the candidate ids, count distinct `followed_user_ids` (`Social.followed_user_ids/1`) who have any engagement (reaction/comment/bookmark/repost) on each candidate → `%{article_id => count}`.
4. **Score & rank** — `Scorer.score/4` per candidate; sort desc; apply the diversity cap; take `limit`.
5. **Backfill** — if fewer than `limit` personalized items, append `Social.trending(limit: limit)` items not already present and not excluded, until full.
6. **Shape & cache** — wrap as `%{type: :article, article:, repost: nil, timestamp: published_at}` items; cache the list (§5).

## Section 5: Caching

Two layers in the existing `Verscienta.Cache`:

- `for_you:affinity:user:<id>` → the affinity profile. TTL ~1h (changes slowly), tag `"user:<id>:for_you"`.
- `for_you:user:<id>:limit=<n>` → the final ranked list. Short TTL ~120s, tags `["for_you", "user:<id>:for_you"]`.

Short list-TTL is the primary freshness mechanism (≤2 min staleness for newly-published content — acceptable). No per-publish fan-out invalidation in v1. The candidate pool is bounded so a cold (miss) computation stays in-memory and fast.

## Section 6: Feed integration

In [`article_feed_live.ex`](lib/verscienta_web/live/article_feed_live.ex):

- Tabs become `[:for_you, :following, :trending, :latest]`. The `:for_you` tab is **shown only to authenticated users**.
- **Default tab**: `:for_you` when `current_user` is present; `:latest` for anonymous. (`normalize_tab/1` accounts for an anonymous user requesting `?feed=for_you` → coerced to `:latest`.)
- New `load_feed(:for_you, socket)` clause → `Recommendations.for_you(current_user, limit: 30)`. Returned items already match the template's article-item shape (no template change).
- **Nudge**: when `Recommendations.personalized?(current_user)` is false (no followed categories/tags and an empty affinity profile), render a subtle inline "Follow topics to personalize your feed" banner above the list. It disappears once the user has signal.

## Section 7: Performance & load-testing

The For You read is the new hot path. The warm read is a per-user cache hit (trivially <50ms); the cold read is the full computation (profile cache hit + bounded candidate query + in-memory scoring + one social-proof query).

- Add a **Benchee scenario** to the existing harness (`bench/cached_reads_bench.exs` via `Scenarios`) for `Recommendations.for_you/2` against a **representative seeded "personalized" user** (one with follows + engagement). Gate the **warm** read at <50ms like the other cached reads; observe the cold read.
- The load-test seeder designates a personalized fixture user (it already creates follows + engagements) and records it in `fixtures.json` (`personalized_user_id`).
- The authenticated per-user **HTTP dead-render** hammer (needs a logged-in session cookie) is **deferred** — the Benchee in-process scenario covers the cached-read target for v1.

## Section 8: Testing

- **`Scorer` (pure)** — deterministic ordering: a candidate matching followed category+tags + high affinity + social proof outranks an unrelated fresh one; each weight moves the score in the expected direction; freshness decays with age.
- **`AffinityProfile.build` (pure)** — given a fixed set of engagements + follows, asserts the expected category/tag weights, type weighting, and recency decay ordering.
- **`Candidates.recent`** — excludes own + already-engaged + group + non-published + out-of-window; respects the pool cap.
- **`Recommendations.for_you/2` (integration, DataCase)** — a user with category/tag follows + engagement gets relevant articles ranked above irrelevant ones; own/seen excluded; a zero-signal user's feed is Trending-backfilled and non-empty; diversity cap holds.
- **Caching** — second call hits cache; `invalidate_tag("for_you")` (or the per-user tag) forces recompute (the leaderboards `cached/3` test pattern).
- Full suite stays green; CI gates (format, compile --warnings-as-errors, credo --strict, dialyzer) green.

## Out of scope (deferred)

- Embeddings / semantic similarity / `pgvector` (slice 2).
- Precompute workers / a `user_feed_entries` table (revisit only if on-read perf fails the gate).
- Personalized **search** ranking (slice 4).
- Onboarding interest-picker UI (Growth subsystem).
- Explicit "not interested" / negative feedback, weight A/B testing, multi-armed bandits.
- Authenticated HTTP-session load test of the dead-render.
- Per-publish cache fan-out invalidation (short TTL suffices for v1).

## Definition of Done

- `Verscienta.Recommendations` context with `Candidates`, `AffinityProfile`, `Scorer`, `for_you/2`, `personalized?/1`; tunable weight block + diversity cap.
- For You tab wired into the feed: default for authenticated users, hidden for anonymous, cold-start Trending backfill, low-signal nudge.
- Two-layer per-user caching (affinity profile + final list) in `Verscienta.Cache`.
- Pure `Scorer`/`AffinityProfile.build` + `Candidates` + `for_you/2` integration + cache tests; full suite green.
- Benchee `for_you` scenario added to the load-test harness with a `personalized_user_id` fixture; warm read gated <50ms.
- CI gates green; no new dependencies; no application code outside the feed LiveView changed beyond additive wiring.
