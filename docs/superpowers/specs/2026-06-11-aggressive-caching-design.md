# Aggressive Caching Strategy & Invalidation Rules Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-11
**Status:** Approved
**Phase:** 4 — Polish, Monetization & Scale (Performance & Scale)
**Depends on:** Phase 2 caching layer (`Verscienta.Cache`: ETS L1 + Redis L2, tags,
single-flight, PubSub cross-node); materialized views + refresh worker; N+1 audit.

## Goal

Make the cache strategy *aggressive*: long TTLs backed by **complete event-driven
invalidation** (TTL becomes a safety net, not the freshness mechanism), close the
coverage gaps on hot uncached reads, and make the invalidation rules a single,
enforced source of truth instead of ad-hoc strings scattered across ~15 call sites.

## Current state (audit)

Cached today: feed page 1 (latest/category/group, 60s), trending (120s),
leaderboards (60s), engagement/social/group counts (300s), for_you (120s) +
affinity (1h), related (600s), sitemap (1h). Invalidation: article writes →
feed tags (every Article action carries `InvalidateFeedCache`); engagement/
follow/repost/membership writes → count tags; snapshot + MV refresh workers →
`leaderboards`/`articles:trending`.

**Gaps found:**
1. Tag strings are constructed ad hoc in ~15 places — nothing prevents a typo'd
   tag silently never invalidating.
2. `InvalidateFeedCache` branches on the article's **post-write** status:
   archiving a published article takes the "not published" branch and leaves the
   stale entry in the cached latest/category feeds until TTL.
3. Account deactivation/anonymization removes the author's articles from feeds —
   but invalidates nothing; cached feeds serve them until TTL.
4. `for_you`, `related`, `sitemap` are TTL-only: no event invalidates them, so
   their TTLs are forced low (120s for the For You feed) to bound staleness.
5. The notification bell runs an uncached `unread_count` DB query on **every page
   navigation** (nested LiveView mount) — the single hottest uncached read.
6. `ProfileLive` calls the uncached `Social.follower_count/following_count`
   directly, bypassing the cached `Social.Counts` helpers that already exist.

## Decisions

| Decision | Choice |
|----------|--------|
| Tag registry | New `Verscienta.Cache.Tags` — one function per tag; moduledoc carries the full invalidation matrix. All `fetch`/`invalidate` sites migrate; raw tag strings in domain code become a code-review smell |
| Invalidation rule for articles | `InvalidateFeedCache` invalidates the full visibility set when the article **was published before OR is published after** the write (publish, edit, archive, hold/shadow/unhold/unshadow, feature). Draft-only writes (autosave every 2s!) keep invalidating only the group tag |
| Visibility set | `articles:latest`, `articles:trending`, `articles:category:<cat>`, `articles:group:<id>` (when set) **+ now `sitemap`, `for_you`, `related`** — publishing/unpublishing changes candidates for all three |
| Deactivation | New `Verscienta.Accounts.User.Changes.InvalidateContentCaches` on `:deactivate`/`:reactivate` (and the purge worker's anonymize path): invalidates `articles:latest`, `articles:trending`, all 8 `articles:category:*`, `sitemap`, `for_you`, `related` — the author's articles must vanish/reappear immediately |
| Unread badge | `Notifications.unread_count/1` cached per user (key `user:<id>:unread_notifications`, tag `user:<id>:notifications`, TTL 10 min) — invalidated in `notify/1` (after create), `mark_read/2`, `mark_all_read/1`. All notification writes flow through these three |
| Profile counts | `ProfileLive` switches to the cached `Social.Counts.follower_count/1` + `following_count/1` (identical semantics, already invalidated by follow writes). The per-viewer `following_this?` stays uncached (viewer-specific) |
| TTLs (the "aggressive" part) | feeds 60s→**600s**; trending 120s→**600s**; leaderboards 60s→**600s**; engagement/social/group counts 300s→**1800s**; for_you 120s→**600s**; related 600s→**3600s**; sitemap stays 3600s; affinity stays 3600s; unread **600s**. Safe because every one now has a complete write-path invalidation |
| Out of scope | Caching the article record itself (policy/viewer-dependent reads — held/shadow placeholders); per-target follower counts for category/tag/source pages (would need a new tag family on Follow writes — noted as follow-up); fragment/HTML caching |

## The invalidation matrix (single source of truth → `Cache.Tags` moduledoc)

| Tag | Cached under it | Invalidated by |
|-----|-----------------|----------------|
| `articles:latest` | latest feed p1 | article was/is-published writes; user deactivate/reactivate/anonymize |
| `articles:trending` | trending list | same + MV refresh worker (5 min) |
| `articles:category:<c>` | category feed p1 | same (the article's category) / all categories on deactivation |
| `articles:group:<id>` | group feed p1 | any write to an article in that group |
| `sitemap` | sitemap.xml | article was/is-published writes; deactivation |
| `for_you` | every user's For You feed | article was/is-published writes; deactivation |
| `user:<id>:for_you` | one user's For You feed + affinity profile | that user's follow writes |
| `related` | per-article related lists | article was/is-published writes; deactivation |
| `article:<id>:counts` | comment/reaction/bookmark/repost counts | that article's comment/reaction/bookmark/repost writes |
| `user:<id>:counts` | follower/following counts | follow writes touching that user |
| `group:<id>:counts` | member count | membership writes for that group |
| `user:<id>:notifications` | unread badge count | notification create / mark_read / mark_all_read for that user |
| `leaderboards` | all live boards | snapshot worker; MV refresh worker |

## File structure

**New:** `lib/verscienta/cache/tags.ex`;
`lib/verscienta/accounts/user/changes/invalidate_content_caches.ex`;
`test/verscienta/cache_invalidation_rules_test.exs`.

**Modified:** the ~15 fetch/invalidate call sites (mechanical migration to
`Cache.Tags` + new TTLs); `invalidate_feed_cache.ex` (was/is-published rule +
wider set); `notifications.ex` (cached `unread_count` + 3 invalidation points);
`profile_live.ex` (cached count helpers); `accounts/user.ex` (attach the new
change); the account purge worker (anonymize path).

## Error handling & testing

- All invalidation stays best-effort (existing `safe_invalidate` pattern):
  a Redis outage degrades to L1-only and TTLs bound staleness, never raising
  into the write path.
- `cache_invalidation_rules_test.exs` exercises each matrix row end-to-end:
  warm the cache, perform the write, assert the key is gone (`Cache.get == :miss`).
  Existing feeds/counts cache tests already cover the old rows; new tests cover
  archive-of-published, deactivation, unread count, and the for_you/sitemap/
  related rows.
- TTL constants are asserted nowhere (tests flush per test), so raises are riskless.
