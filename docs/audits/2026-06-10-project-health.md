# Project Health Audit: Verscienta (Historical — standalone prototype)

> **Scope note (added 2026-10-03, Slice 1 alignment):** This audit assessed the
> **Verscienta standalone** Phoenix app (`Verscienta.*`, Ash + AshPostgres +
> LiveView + `Verscienta.Cache.Redis`/`Redix`/Oban). Slice 1 is now a
> **KilnCMS overlay** (`KilnCMS.*` + `VerscientaNews.Catalog`, Cachex/Hammer/
> PubSub — no Redis per D1/D2, Kiln Postgres FTS, no Leaderboards in Slice 1).
> Recommendations referencing `Verscienta.*` modules, Redis, or Leaderboards
> describe the standalone prototype, not the overlay. Retained as historical
> context; defer to `docs/architecture.md`, `docs/slice-1.md`, and
> `kiln_cms/docs/performance.md` for the current stack.

**Generated**: 2026-06-10
**Mode**: full (5 parallel specialists)
**Branch**: claude/jolly-knuth-02c4ab

## Executive Summary

### Health Score: B (79/100)

| Category | Score | Status |
|----------|-------|--------|
| Architecture | 78/100 | Good |
| Performance | 58/100 | Needs Attention |
| Security | 86/100 | Strong |
| Test Quality | 80/100 | Good |
| Dependencies | 92/100 | Excellent |

No remotely-exploitable Critical/High security issues were found. The dominant
risk theme is **scale cliffs** (unbounded feed reads, near-zero indexes on the
hottest tables) and **caller-side visibility rules** that have already drifted
once (search vs. feeds for deactivated/anonymized authors).

### Fixed in this session (same branch)

1. **Admin flag LiveViews second line of defense** — new `:admin_required`
   on_mount hook wired into the `:admin_flags` live_session (was: role checked
   only by the router plug on dead-render). + hook unit tests.
2. **GroupMembership + Notification policy lockdown** — granular CRUD actions
   (`:create`/`:set_role`/`:set_status`/`:destroy`, notification `:create`)
   were `authorize_if always()`; now `forbid_if always()` (system-context
   only), term actions require an actor. Closes latent self-promote /
   approval-bypass / notification-spoof holes.
3. **Search visibility drift (GDPR-adjacent)** — Postgres fallback search and
   the Meilisearch index worker now exclude deactivated/anonymized authors,
   matching `:list_published`; new `ReindexAuthoredArticles` change de-indexes
   on `request_deletion` and re-indexes on `cancel_deletion`/sign-in
   reactivation.
4. **Notification preferences honored for gamification** — quest/streak/
   leaderboard/badge notifications now route through
   `Notifications.notify_once/1` (new) instead of direct creates, so user
   prefs apply and the live bell updates. + tests.
5. **Hot-path indexes migration** (`20260610120000_add_hot_path_indexes.exs`)
   — partial feed indexes on articles, first-ever indexes on comments,
   reactions(article_id), follows(target), group_memberships(group,status),
   article_tags(tag_id), points_entries(inserted_at).
6. **Feed reads bounded** — `Article.list_published/list_by_category/
   list_by_group` capped at 60 rows (were: entire corpus queried, cached, and
   copied into every socket).
7. **Leaderboard N+1** — top-100 user hydration is now one `id in ^ids` query
   (was: up to 100 sequential `Ash.get`s per render, per viewer).
8. **Mentions N+1** — `@handle` resolution now batched per comment thread and
   passed to a pure `linkify/2` (was: one users query per comment per
   re-render).
9. **Cache L1 eviction** — `LockSweeper` now evicts expired L1 entries + stale
   tag-index rows every 30s (was: unbounded ETS growth for per-user keys).
10. **LoadTest.Seeder prod guard** — `reset!` refuses to `TRUNCATE ... CASCADE`
    unless the connected database is `verscienta_loadtest`.
11. **Session rotation** — `configure_session(renew: true)` on sign-in/out.
12. **Group.transfer_ownership** — collects Ash notifications with
    `return_notifications?: true` and flushes after commit (was: silently
    dropped, the project's known raw-transaction footgun).
13. **Test hygiene** — seed-contamination count asserts scoped to the test's
    author; new non-owner `/articles/:slug/edit` 404 regression test.

### Fixed in follow-up session (same day)

14. **Visibility into policies (arch C2)** — the Article read policy now
    encodes group privacy (no group / public group / active membership) and
    the Comment read policy filters others' shadowed comments (author and
    mod/admin still see them); the reader LiveView's caller-side group check
    was deleted. Gotcha: an Ash filter check referencing the actor evaluates
    to false as a whole with no actor, so anonymous-visible branches must be
    separate actor-free checks.
15. **Counts in SQL (perf M1/M2)** — `counts_for_article` and the trending
    window counts are single `GROUP BY` queries; the reaction toggle
    broadcasts the fresh counts so connected readers assign from the payload
    instead of re-querying.
16. **fast_rss decision (deps)** — kept and pinned `~> 0.5.0`, rationale in
    mix.exs: the only maintained alternative (gluttony) is AGPL-3.0-only, and
    fast_rss's quick-xml backend has no DTD/entity resolution (verified by a
    new hostile-DTD fetcher test); a new Atom-feed test closes the
    RSS-only coverage gap. `mdex` tightened to `~> 0.12.3`.
17. **Shared test factory** — `Verscienta.Support.Factory` (user, role,
    sign_in, article, set_role) replaces the copy-pasted helpers across 140
    test files; genuinely different variants stay local.

### Remaining top recommendations (not yet done)

#### Short-term
- **Following feed bounded (perf M3)** — `Social.following_feed` reads every
  matching article + repost before `Enum.take`; add per-source limits.

#### Long-term / backlog
- Ash code interfaces on domains; stop LiveViews building raw `Ash.Query`
  (especially the `authorize?: false` call sites).
- Move `Article.list_*` cached readers to `Verscienta.Content` domain.
- Batch shadowban checks in activity feeds (perf M4); paginate profile
  followers, group member lists, moderation queue, bookmarks.
- Recommendations cold path: select-only-ids + SQL frequency counts (perf M9).
- Untested surfaces: GoodbyeLive, SettingsReferralsLive, StoreHistoryLive,
  CaptureReferral plug, ReferralRedirectController.
- Analytics fire-and-forget via `Task.Supervisor` instead of bare `Task.start`.
- Group the 4 cache children under a `rest_for_one` supervisor.

## Detailed findings

Full per-category reports in `.claude/audit/reports/`:
`arch-review.md`, `perf-audit.md`, `security-audit.md`, `test-audit.md`,
`deps-audit.md`.
