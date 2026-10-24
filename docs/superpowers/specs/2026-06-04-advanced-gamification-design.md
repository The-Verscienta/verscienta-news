# Advanced Gamification Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-04
**Status:** Approved
**Phase:** 2 — Social & Gamification
**Depends on:** Phase 1 Gamification (basic) — [`PointsEntry`, `Badge`, `UserBadge`, `User.points`, `award/3`, `AwardWorker`]; Engagement (`Comment`, `Reaction`, `Bookmark`); Social Graph (`Follow`, `Repost`); Communities (`GroupMembership`); Notifications (`Notification` resource + preferences); Oban; Phoenix.PubSub.

## Goal

Layer the full advanced-gamification loop on top of the existing points/level/badge engine:
**Quests** (daily/weekly), **Streaks** (with weekly freeze grace), **Leaderboards** (weekly/monthly/all-time × global/per-category, snapshotted), a **Reward Store** (digital perks, points-spend), and **Referrals** (qualify on first daily-quest completion). One spec, six features, one merge.

A single `GamificationEvent` stream is the spine: every points-worthy or quest-worthy action is recorded once (idempotent), and Streaks + Quests + Leaderboards consume it.

## Decisions

| Decision | Choice |
|----------|--------|
| Domain | Continue extending **`Verscienta.Gamification`** (file-tree grouped by feature) |
| Event spine | New **`GamificationEvent`** table, populated via `Events.record/4`; one row per qualifying action; idempotent by `(user_id, kind, ref)` |
| Quest model | **Data-driven catalog** + **`QuestAssignment`** per user/period; progress driven by `GamificationEvent` matches |
| Streak rule | Any engagement counts; **1 freeze/week** auto-refilled; bought freezes accumulate above the cap |
| Leaderboards | **Weekly + monthly + all-time × global + per-category** (3 × 9 = 27 boards); snapshots Oban cron; current period live-query + 60s ETS cache |
| Window TZ | Leaderboard window boundaries are **UTC** (globally consistent); streaks + quest days are **per-user-local** |
| Reward store | Digital perks only; **direct points spend** (no separate currency) |
| Spend writer | Parallel `spend/3` to existing `award/3`; both single-writer through the `:redemption` source on `PointsEntry` |
| Referrals | Code on profile + `?ref=`/`/r/<code>`; reward on **first daily-quest completion**; per-IP and per-month caps |
| Anti-abuse | Daily per-source caps + per-IP signup throttle + `GamificationAudit` table + hourly anomaly scan |
| Notifications | Notify on quest_complete, streak_milestone, rank-up (closed periods), badge_earned; `actor_id` made nullable for system notifications |
| Timezone | New `User.timezone` (IANA, default `Etc/UTC`); user-settable in `/settings` |
| Claw-back | None — award-only stance preserved; revoked referrals halt future awards but don't subtract |

## Section 1: New resources

All under `Verscienta.Gamification`. **Bold** = new, _italic_ = existing-and-reused, ~~strike~~ = modified.

**Event spine**
- **`GamificationEvent`** — append-only behavior stream; wider than `PointsEntry`; single source of truth for streaks, quests, and (via points joins) category leaderboards.
- _`PointsEntry`_ — points ledger preserved. The `source` `one_of` is extended with `:redemption` (negative amounts, store), `:referral_bonus` (positive, referral qualification), and `:quest` (positive, quest completion). Phase 1 sources retained.

**Quests**
- **`Quest`** — catalog row (`key`, `name`, `description`, `cadence`, `goal_kind`, `goal_count`, `predicate`, `points_reward`, `active?`).
- **`QuestAssignment`** — per-user per-period row tracking `progress`, `completed_at`; values snapshotted from the catalog at assignment time.

**Streaks**
- **`Streak`** — one row per user (`current_length`, `longest_length`, `last_active_date`, `freezes_available`, `freeze_week_start`, `last_freeze_used_on`).

**Leaderboards**
- **`LeaderboardSnapshot`** — closed-period board (scope, category, window, period); top-100 entries stored as JSONB.

**Reward Store**
- **`RewardItem`** — catalog row (`key`, `name`, `description`, `cost`, `kind`, `payload`, `active?`, `cooldown_hours`, `stock_per_user`).
- **`Redemption`** — per-user purchase (`reward_item_id`, `cost_paid`, `redeemed_at`, `consumed_at`, `points_entry_id`).

**Referrals**
- **`Referral`** — `(referrer_id, referee_id)` unique; `code_used`, `signup_ip`, `status`, `qualified_at`, `revoked_at`, `revoked_reason`.

**Anti-abuse**
- **`GamificationAudit`** — `(user_id, kind, severity, details, occurred_at)`.

**User changes** (~~_`User`_~~)
- `timezone` — `:string`, default `"Etc/UTC"`, public, IANA.
- `referral_code` — `:string` (8 char Crockford base32), unique, generated on email confirm.
- `referred_by_id` — nullable `belongs_to :referrer, User`.
- `flair` — `:map`, default `%{}` (unlocked + equipped cosmetic ids).
- `equipped_theme` — `:string`, nullable.

## Section 2: `GamificationEvent` & hooks

### Schema
- `id` uuid pk
- `belongs_to :user, allow_nil?: false`
- `kind` — `:atom`, `one_of` (extensible): `:article_published`, `:comment_posted`, `:reaction_received`, `:reading`, `:followed_user`, `:bookmarked`, `:reposted`, `:joined_group`, `:invited_friend_signed_up`
- `ref` — `:string`, idempotency key (e.g. `"comment:<id>"`, `"reading:<uid>:<aid>:<date>"`)
- `subject_type` — `:atom`, nullable; `subject_id` — `:string`, nullable (analytics/predicates)
- `metadata` — `:map`, default `%{}` (e.g. `%{"category" => "nutrition"}`)
- `occurred_at` — `:utc_datetime_usec`, indexed
- `local_date` — `:date`, indexed (user's local-tz date of `occurred_at`, set by `Events.record`)
- identity `unique_event` on `(user_id, kind, ref)`
- index `(user_id, local_date)`, `(user_id, kind, local_date)`

### Producer

`Verscienta.Gamification.Events.record(user_id, kind, ref, opts)`:
1. Resolve `user.timezone`; compute `local_date = DateTime.utc_now() |> DateTime.shift_zone!(tz) |> DateTime.to_date()`.
2. Check daily per-source cap (Section 8). Over cap → write `GamificationAudit` row (once per user/kind/local_date), return `{:ok, :capped}`. Do not insert event.
3. Insert `GamificationEvent` (rescue dup-key → `{:ok, :duplicate}`).
4. If `kind in PointsEntry.sources()`, enqueue existing `AwardWorker` (preserving Phase 1 award path).
5. Broadcast `{:gamification_event, user_id, event}` on `"user:<id>"`.
6. Enqueue `ProgressWorker` (one Oban job per event) that bumps matching quest assignments, extends the streak, and re-evaluates milestone notifications.

`Events.record` is the only writer; hooks always go through it.

### Hooks

After-action hooks on existing resources (mirrors the current `AwardWorker` enqueue pattern, all best-effort + rescued):
- `Article.:publish` (existing) → route through `Events.record(author_id, :article_published, "article:<id>", %{category: ...})`. Authorless aggregated articles skip.
- `Comment.:create` (existing) → `Events.record(user_id, :comment_posted, "comment:<id>", %{category: ...})`.
- `Reaction` create within `:toggle` (existing) → load article's `author_id`; if present, `Events.record(author_id, :reaction_received, "reaction:<id>", ...)`.
- `ArticleReaderLive` `reading_complete` (existing) → `Events.record(user_id, :reading, "reading:<uid>:<aid>:<local_date>", %{category: ...})`.
- **New:** `Follow.:create` → `Events.record(user_id, :followed_user, "follow:<id>")`.
- **New:** `Bookmark.:create` → `Events.record(user_id, :bookmarked, "bookmark:<id>", %{category: ...})`.
- **New:** `Repost.:create` → `Events.record(user_id, :reposted, "repost:<id>", %{category: ...})`.
- **New:** `GroupMembership.:join` → `Events.record(user_id, :joined_group, "joined_group:<id>")`.

### Backfill

One-shot Oban task `Verscienta.Gamification.Backfill.events_from_points_entries` synthesizes a `GamificationEvent` for each existing `PointsEntry`, idempotent via `ref` (uses the entry's existing `source_ref`). Run once after migration so existing users start with non-empty streak/leaderboard histories. Re-running is a no-op.

## Section 3: Quest engine

### `Quest`
- `id` uuid pk; `key` atom unique; `name`, `description` strings
- `cadence` — `:atom`, `one_of [:daily, :weekly]`
- `goal_kind` — `:atom` (matches `GamificationEvent.kind`)
- `goal_count` — `:integer`
- `predicate` — `:map`, default `%{}` (e.g. `%{"category" => "nutrition"}`)
- `points_reward` — `:integer`
- `active?` — `:boolean`, default `true`

### `QuestAssignment`
- `id` uuid pk
- `belongs_to :user`, `belongs_to :quest`
- `period_start_date`, `period_end_date` — `:date` (user-local; weekly = local Monday → Sunday)
- `progress` — `:integer`, default 0
- `goal_count`, `points_reward` — snapshotted from catalog at assignment time
- `completed_at` — `:utc_datetime_usec`, nullable
- `claimed?` — `:boolean`, default `false` (reserved; v1 auto-claims on completion)
- identity `unique_assignment` on `(user_id, quest_id, period_start_date)`
- index `(user_id, period_end_date)` for the "open assignments" lookup

### Assignment

`Verscienta.Gamification.Workers.QuestAssignerWorker` — cron hourly:
- For each user whose local-midnight has just passed since the last run, assign every `active?` daily quest for today.
- On the user's local Monday, additionally assign every `active?` weekly quest.
- Idempotent via `unique_assignment`.
- A fallback check inside `Events.record` lazy-assigns for first-time-of-day users (a user who logs in mid-day before the cron has caught up).

### Progress

`ProgressWorker` (per event, Section 2):
1. Load the user's open assignments (`period_start_date <= event.local_date <= period_end_date`).
2. For each assignment whose `quest.goal_kind == event.kind` and whose `quest.predicate` matches event `metadata`/`subject_*`: atomic `progress = progress + 1`.
3. If `progress >= goal_count` and `completed_at is nil`: set `completed_at = now`, call `Gamification.award(user_id, :quest, "quest:<assignment_id>", points_reward)` (idempotent), enqueue `:quest_completed` notification (idempotent by subject = assignment id).

Phase 1's `award/3` derived the amount from `Points.value/1`. Quest and referral payouts are variable, so `award` is extended to `award(user_id, source, source_ref, amount \\ nil)` — when `amount` is nil it falls back to `Points.value(source)` (Phase 1 behavior preserved); when provided it uses the explicit amount. Same idempotency rules.

### Predicate matching

v1 supports simple equality maps; the `ProgressWorker` matches by checking each key in `predicate` against `event.metadata[key]` (with `subject_type` / `subject_id` available too). No DSL, no OR, no distinct-count. Deferred.

### Seeded catalog (v1)

| key | cadence | goal_kind | goal_count | reward |
|-----|---------|-----------|------------|--------|
| `daily_reader` | daily | `:reading` | 3 | 30 |
| `daily_commenter` | daily | `:comment_posted` | 1 | 20 |
| `weekly_publisher` | weekly | `:article_published` | 2 | 200 |
| `weekly_reader` | weekly | `:reading` | 20 | 100 |

Notable omission: a "react N times" daily quest needs an actor-side `:reaction_given` event kind, which is *not* in the v1 `GamificationEvent.kind` enum (only `:reaction_received` exists, and that's the author side). Deferred — trivial to seed once `:reaction_given` is added.

## Section 4: Streaks

### `Streak`
- `id` uuid pk
- `belongs_to :user`, identity on `user_id`
- `current_length` — `:integer`, default 0
- `longest_length` — `:integer`, default 0
- `last_active_date` — `:date`, nullable (user-local)
- `freezes_available` — `:integer`, default 0
- `freeze_week_start` — `:date`, nullable (user-local Monday)
- `last_freeze_used_on` — `:date`, nullable

### Extend logic (inside `ProgressWorker`, per event)
1. Load (or create) the user's `Streak`.
2. If `last_active_date == event.local_date` → no-op.
3. Else compute `gap = Date.diff(event.local_date, last_active_date)` (or `nil` if first ever):
   - `gap == nil` → `current_length = 1`, `last_active_date = event.local_date`.
   - `gap == 1` → `current_length += 1`, `last_active_date = event.local_date`.
   - `gap == 2` and `freezes_available > 0` → consume freeze: `freezes_available -= 1`; `last_freeze_used_on = last_active_date + 1 day`; `current_length += 1`; `last_active_date = event.local_date`.
   - `gap >= 2` and no freeze → reset: `current_length = 1`, `last_active_date = event.local_date`.
4. `longest_length = max(longest_length, current_length)`.
5. If `current_length` crossed a milestone (7, 30, 100, 365), enqueue `:streak_milestone` notification idempotent by `"streak:<user_id>:<length>"`.

### Freeze refill

`Verscienta.Gamification.Workers.FreezeRefillWorker` — cron daily. For any user whose local current-ISO-week ≠ `freeze_week_start`, set `freezes_available = 1` and `freeze_week_start = local Monday of current week`. Auto-refill does **not** accumulate (capped at 1). Bought freezes (Reward Store) bypass the cap by directly incrementing the counter.

### Broken-streak detection

No sweeper. The next extending event detects `gap >= 2` and resets. The profile UI derives "Streak ended on X" from `current_local_date - last_active_date > 1` (computed in the LiveView from the user's tz), without writing.

### Display

Profile + nav show `current_length 🔥`; tooltip includes `longest_length`, `freezes_available`, and either "Active today" / "Last active: <date>" / "Streak ended".

## Section 5: Leaderboards

### `LeaderboardSnapshot`
- `id` uuid pk
- `scope` — `:atom`, `one_of [:global, :category]`
- `category` — `:string`, nullable (slug; required iff `scope == :category`)
- `window` — `:atom`, `one_of [:weekly, :monthly, :all_time]`
- `period_start_date`, `period_end_date` — `:date` (UTC; sentinel `1970-01-01` for `:all_time`)
- `entries` — `:map` (jsonb), shape: `[%{"user_id" => "...", "score" => 1234, "rank" => 1}, ...]`, truncated to top 100
- `total_participants` — `:integer`
- `computed_at` — `:utc_datetime_usec`
- identity `unique_snapshot` on `(scope, category, window, period_start_date)`
- index `(scope, window, period_start_date desc)`

### Windowing

All leaderboard windows use **UTC** boundaries (globally consistent). Streaks and quest days remain per-user-local. This is documented in the UI ("Resets weekly, UTC").

### Scoring

Score = `SUM(PointsEntry.amount)` (positive only — `:redemption` rows excluded by `amount > 0` filter) where `inserted_at` falls in the window. Category boards additionally join `points_entries` to `gamification_events` on `(user_id, points_entries.source_ref = gamification_events.ref)` filtering `metadata->>'category' = $1`.

### Snapshot worker

`Verscienta.Gamification.Workers.LeaderboardSnapshotWorker` (queue `:default`):
- Cron at `00:05 UTC` daily.
- Closes weekly boards every Monday and monthly boards on the 1st (one row per `(scope, category, window)`).
- Recomputes all-time boards daily (overwrites the sentinel-date row).
- Per-board Oban `unique` on job args; idempotent upsert via the unique identity.
- Diffs new top-10 vs prior snapshot's top-10; for each new top-10 entrant emits `:leaderboard_rank_up` notification idempotent by `"leaderboard:<scope>:<category>:<window>:<period_start>:<user_id>"`.

### Live boards (current period)

Same aggregate, no window-end filter, top 100. Wrapped in `Verscienta.Gamification.Cache` (ETS) keyed by `(scope, category, window)` with **60s TTL**. A `Task.Supervisor`-based `LiveLeaderboardRefresher` warms only `(:global, nil, :weekly)` for v1; others populate on first request.

### Indexes (migrations add)

- `points_entries (inserted_at desc, user_id) include (amount)`
- `gamification_events ((metadata->>'category'))` partial on points-worthy kinds
- `points_entries (source_ref)` (for the join)

### UI

- `/leaderboard` — tabs (Weekly / Monthly / All-time), pivot (Global / each of the 8 categories), top 100 + signed-in user's pinned row (rank computed via count-rank if outside top 100). PubSub on `"leaderboards"` triggers re-fetch when a snapshot lands.
- Profile `/@:username`: best top-10 rank chip (single highest rank across all current boards).

## Section 6: Reward Store

### `RewardItem`
- `id` uuid pk; `key` atom unique; `name`, `description` strings
- `cost` — `:integer`
- `kind` — `:atom`, `one_of [:flair_frame, :flair_color, :badge_cosmetic, :streak_freeze, :comment_boost, :theme]`
- `payload` — `:map` (kind-specific config)
- `active?` — `:boolean`, default `true`
- `cooldown_hours` — `:integer`, nullable
- `stock_per_user` — `:integer`, nullable (nil = unlimited; 1 = one-time unlock)

### `Redemption`
- `id` uuid pk
- `belongs_to :user`, `belongs_to :reward_item`
- `cost_paid` — `:integer` (snapshotted)
- `redeemed_at` — `:utc_datetime_usec`
- `consumed_at` — `:utc_datetime_usec`, nullable (consumables)
- `points_entry_id` — uuid (FK to `points_entries`)
- index `(user_id, reward_item_id, redeemed_at desc)`

### Spend writer

`Verscienta.Gamification.spend(user_id, source, source_ref, amount)` — parallel to `award/3`. Inserts a `PointsEntry` with `amount = -abs(amount)`, `source = :redemption`, idempotent via `source_ref`. Updates cached `User.points` (`add_points` action accepts negative).

### `Store.redeem(user, reward_item, opts)` flow (single DB transaction)

1. `SELECT ... FOR UPDATE` on the user row.
2. Re-load `user.points`; if `< cost` → `{:error, :insufficient_points}`.
3. Check `stock_per_user`: count user's redemptions of this item; if `>= stock_per_user` → `{:error, :out_of_stock_for_user}`.
4. Check `cooldown_hours`: if `now - latest_redemption < cooldown` → `{:error, :on_cooldown}`.
5. Insert `Redemption`.
6. `spend(user_id, :redemption, "redemption:<redemption_id>", cost)`.
7. Apply effect (see below).
8. Commit; broadcast `{:points_changed, user_id}` and `{:store_redeemed, user_id, redemption}`.

Any failure rolls back the whole transaction. Hammer/ETS rate-limit: max 10 redemptions per user per hour → audit row + error.

### Effects

- `:flair_frame`, `:flair_color`, `:badge_cosmetic`, `:theme` — unlock by appending to `user.flair["unlocked_<kind>"]`. Equipping is a separate UI action (no cost).
- `:streak_freeze` — `streak.freezes_available += 1` (no week cap on bought freezes).
- `:comment_boost` — flips `featured_until = now + 24h` on a user-chosen `target_comment_id` (required arg; must belong to the redeeming user). UI checks `featured_until > now`; no sweeper needed. **`Comment` schema change:** adds `featured_until` `:utc_datetime_usec`, nullable, public.

### Seeded catalog (v1)

| key | kind | cost | cooldown_hours | stock_per_user |
|-----|------|------|----------------|----------------|
| `flair_color_orange` | `:flair_color` | 100 | nil | 1 |
| `flair_color_metro` | `:flair_color` | 250 | nil | 1 |
| `flair_frame_halo` | `:flair_frame` | 500 | nil | 1 |
| `streak_freeze` | `:streak_freeze` | 50 | nil | nil |
| `comment_boost` | `:comment_boost` | 80 | 24 | nil |
| `theme_zune_classic` | `:theme` | 1000 | nil | 1 |

### UI

- `/store` — grid of active items; balance header; button states: `Buy | Equipped | Owned | On cooldown until <X> | Need N more pts`.
- `/store/history` — your redemptions, descending.

## Section 7: Referrals

### `User` additions

- `referral_code` — `:string`, 8 char Crockford base32 (no ambiguous chars), unique, indexed. Generated on **email confirmation**.
- `referred_by_id` — nullable `belongs_to :referrer, User`.

### `Referral`
- `id` uuid pk
- `belongs_to :referrer, User`, `belongs_to :referee, User`
- `code_used` — `:string` (snapshotted at signup; survives referrer's code rotation)
- `signup_ip` — `:string`
- `status` — `:atom`, `one_of [:pending, :qualified, :revoked]`, default `:pending`
- `qualified_at` — `:utc_datetime_usec`, nullable
- `revoked_at` — `:utc_datetime_usec`, nullable
- `revoked_reason` — `:string`, nullable
- identity `unique_pair` on `(referrer_id, referee_id)`
- index `(referrer_id, status, qualified_at desc)`

### Capture flow

1. `/r/<code>` (and `?ref=<code>`) sets cookie `verscienta_ref=<code>` (HttpOnly, SameSite=Lax, 30-day).
2. On `User.:register`, if cookie is present and resolves to a confirmed user other than the registrant: set `referred_by_id`, create `Referral` `(status: :pending, code_used, signup_ip)`. Clear cookie.

### Qualification

In `ProgressWorker`, on first daily-cadence `QuestAssignment.completed_at` for a user with `referred_by_id`: find the pending `Referral`; mark `:qualified` with `qualified_at = now`; call `award(referrer_id, :referral_bonus, "referral:<referral_id>", 100)` (idempotent).

### Caps & throttles

- **Monthly referrer cap.** Max 10 qualified referrals/calendar-month (UTC). Beyond the cap: status still flips to `:qualified` but `award` is skipped; audit row `kind: :referral_cap_hit, severity: :info`.
- **Per-IP signup throttle.** If `signup_ip` has produced ≥3 referee accounts in 24h: new `Referral` is created with `status = :revoked, revoked_reason = "ip_throttle"`; audit row `kind: :ip_throttle, severity: :warn`. Revoked never qualifies.
- **Self-IP referrer/referee.** Always `:revoked` with `revoked_reason = "self_referral_ip"`.
- **Admin revoke.** Sets `:revoked`; future re-qualification awards blocked; previously awarded points not clawed back.

### Code rotation

`/settings/referrals` includes a "Regenerate code" action (1×/24h rate-limited). Old code stops resolving immediately. Historical `Referral.code_used` is the audit trail.

### UI

- `/settings/referrals` — shows code, share link `https://verscienta.news/r/<code>`, copy button, counts (pending/qualified/total points earned), list of referees (display_name + status).
- Profile chip with total qualified referrals — opt-in toggle on the referrals page, default off.

## Section 8: Anti-abuse, notifications, settings, UI

### Daily per-source caps (enforced in `Events.record`)

| kind | daily cap |
|------|-----------|
| `:reading` | 30 |
| `:comment_posted` | 30 |
| `:reaction_received` | 50 |
| `:article_published` | 5 |
| `:followed_user` | 20 |
| `:bookmarked` | 20 |
| `:reposted` | 20 |
| `:joined_group` | 20 |

Over-cap events: not inserted, no audit duplication (one audit row per user/kind/local_date). Capped events therefore do **not** drive quest progress or streaks — intended anti-farming behavior.

### `GamificationAudit`
- `id` uuid pk
- `belongs_to :user`
- `kind` — `:atom`, `one_of` `[:source_cap_hit, :referral_cap_hit, :ip_throttle, :self_referral, :store_cooldown_hit, :store_rate_limit, :anomaly_point_spike]`
- `severity` — `:atom`, `one_of [:info, :warn, :critical]`
- `details` — `:map` (kind-specific context)
- `occurred_at` — `:utc_datetime_usec`, indexed
- indexes `(user_id, occurred_at desc)`, partial on `severity in (:warn, :critical)`

### Anomaly scan

`Verscienta.Gamification.Workers.AnomalyScanWorker` — cron hourly. For any user with >500 points earned in the last hour: write `:anomaly_point_spike` row with `severity: :critical`. v1 takes no auto-action; admin review only.

### Notifications

Extend `Verscienta.Notifications.Notification`:
- `@types` gains `:quest_completed`, `:streak_milestone`, `:leaderboard_rank_up`, `:badge_earned`.
- `@subject_types` gains `:quest`, `:streak`, `:leaderboard`, `:badge`.
- `actor_id` made **nullable** (system-generated notifications). UI renders system icon when `actor` is nil. Migration: `ALTER COLUMN actor_id DROP NOT NULL`; the `belongs_to :actor` declaration drops `allow_nil?: false`.
- All four new types respect per-type opt-out via existing `/settings` notification preferences.

Emission sites (best-effort, idempotent by subject):
- `:quest_completed` — on `QuestAssignment.completed_at` set (subject = assignment id).
- `:streak_milestone` — on milestone crossings (7/30/100/365), subject = streak id, metadata `%{length}`.
- `:leaderboard_rank_up` — on **closed-period** snapshot diff entering top-10 (live boards do not notify).
- `:badge_earned` — emitted by the existing badge engine when a new `UserBadge` is created.

### Settings

`/settings`:
- **Timezone** picker (IANA). Browser default detection via `Intl.DateTimeFormat().resolvedOptions().timeZone`, user-overridable. Tooltip notes: change applies to future events only.
- Notification preference rows for the four new types.
- Link to `/settings/referrals`.

### UI surfaces

| Route | What |
|-------|------|
| `/quests` | Daily + weekly assignments with progress bars; completed quests collapse with checkmark. |
| `/leaderboard` | Weekly/Monthly/All-time × Global/per-category; top 100 + pinned user row. |
| `/store` | Reward grid + balance + state-aware buttons. |
| `/store/history` | Your redemptions table. |
| `/settings/referrals` | Code, share link, referee list, regenerate. |
| `/@:username` | Existing profile + streak chip + best-rank chip + equipped flair + badge grid. |
| Home nav | Compact balance + streak chip in user dropdown. |

All LiveViews subscribe to `"user:<id>"` for live updates to balance/streak/quest progress; `/leaderboard` also subscribes to `"leaderboards"`.

## Section 9: Testing

All tests stub nothing external; Oban `testing: :manual`.

### Domain (DataCase)
- `Events.record/4`: idempotent on dup `(user_id, kind, ref)`; populates `local_date` from user timezone; over-cap returns `:capped` + writes audit + does not insert event + does not progress quests.
- Quest engine: assignment cron assigns daily/weekly per cadence; `ProgressWorker` bumps only matching events; predicate (`metadata.category`) filters; completion awards points once (idempotent by `source_ref`); editing the catalog `points_reward` doesn't retro-change an in-flight assignment.
- Streak: extend on consecutive days; freeze used on gap=2 with availability; reset on gap≥2 with no freeze; milestone notifications emit once per milestone; `FreezeRefillWorker` refills weekly with cap 1; bought freezes push above 1.
- `LeaderboardSnapshotWorker`: closes weekly/monthly at UTC boundary; top 100; rank-up notifications for new top-10; category boards filter by event metadata.
- Live leaderboard query: ETS TTL respected; same data as the snapshot query for a closed period.
- `Store.redeem/2`: transactional rollback on mid-effect failure; insufficient/cooldown/stock errors; `comment_boost` requires `target_comment_id` and flips `featured_until`; rate-limit (>10/hr) writes audit + errors.
- Referral: cookie capture sets `referred_by_id` + creates pending row; qualification flips on first daily-quest completion and awards 100 pts idempotently; per-IP throttle revokes the 4th in 24h; monthly cap blocks award but flips status; code rotation invalidates old code.
- `GamificationAudit`: rows written by each documented path; severity levels correct.

### LiveView
- `/quests`: today's assignments + progress; completed renders checkmark; PubSub progress updates without reload.
- `/leaderboard`: top-100 render; user-row pinned when outside top 100; tab/pivot changes; PubSub triggers re-fetch.
- `/store`: balance updates after redeem; insufficient-points state; cooldown countdown; `comment_boost` target-comment flow.
- `/settings/referrals`: code visible, copy hook test, referees list filtered to current user, regenerate respects 24h rate-limit.
- `/settings`: timezone change persists + confirmation; notification preference rows persist.

### Hooks
- New hooks on `Follow.:create`, `Bookmark.:create`, `Repost.:create`, `GroupMembership.:join` call `Events.record` with correct kind + ref + metadata.
- Existing points hooks route through `Events.record` and still enqueue `AwardWorker` — assert both an event row and a points entry land.

### Backfill
- `events_from_points_entries` on a seeded DB produces one `GamificationEvent` per existing `PointsEntry`; re-running is a no-op.

### Property-based (`:property` tagged)
- Streak math: random (date, event?) sequences over 180 days → `current_length ≤ longest_length`, `last_active_date ≤ today`, no negative lengths, ≤1 freeze auto-refill per week.
- Points ledger: sum of `PointsEntry.amount` per user matches cached `User.points` after arbitrary award/spend sequences.

### Gates
- Existing CI: `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test`.
- Migrations via `mix ash.codegen`.
- `mix verscienta.gamification.seed` (idempotent) — seeds quest catalog + reward catalog + (no-op) timezone default. Run on prod deploy.

## Out of scope (deferred)

- Real-world goods / sponsor fulfillment in the store.
- OR-predicates, distinct-count, and admin UI for quest & reward catalog management (DB-seeded in v1; edit via console or migration).
- A `:reaction_given` event kind (would unlock a "react N times" daily quest).
- Auto-action on `:anomaly_point_spike` beyond an audit row (no leaderboard exclusion in v1).
- Push / email digests for quests, streaks, leaderboards (in-app notifications only).
- Tiered referral rewards (single 100-pt bonus only).
- Multi-equip across the same cosmetic kind (one frame, one color, one theme at a time).
- Decimal / fractional points; point decay; claw-back on un-react.

## Definition of Done

- `GamificationEvent` stream records every points-worthy and quest-worthy action; backfill task populates history; daily caps enforced.
- Daily and weekly quests assign at user-local boundaries, track progress, award points on completion, and emit notifications — all idempotent.
- Streaks extend on consecutive local days, accept one auto-refilled freeze per week, and emit milestone notifications.
- Closed-period weekly/monthly/all-time leaderboards (global + per-category) snapshot via Oban cron, with rank-up notifications for new top-10 entrants; current-period boards query live with ETS cache.
- Reward Store transactionally deducts points, applies effect, and supports cooldowns, per-user stock, and rate-limiting.
- Referral codes generate on email confirmation, qualify on first daily-quest completion, award the referrer 100 pts (idempotent), and are protected by per-IP and per-month throttles.
- All new LiveViews ship with tests; notifications integrate via the existing `Notification` resource (with the four new types + nullable actor); timezone setting persists on `User`.
- All CI gates pass; migrations and seeds committed on `phase-2-advanced-gamification`.
