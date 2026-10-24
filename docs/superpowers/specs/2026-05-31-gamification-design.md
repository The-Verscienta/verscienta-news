# Gamification (Basic) Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-05-31
**Status:** Approved
**Phase:** 1 (MVP) — Subsystem 6 of 6 (final MVP subsystem)
**Depends on:** Phase 0; Auth (`User`, `/@:username` profile); Content (`Article`, `:publish`); Engagement (`Comment.:create`, `Reaction.:toggle`); Oban (configured + supervised); Phoenix.PubSub.

## Goal

Reward engagement with Vitality Points, derive levels from points, and grant milestone badges
— all driven by domain events through Oban, displayed on the public profile. Points: publishing,
commenting, receiving reactions, and timed reading. Append-only ledger, idempotent awards.

## Decisions

| Decision | Choice |
|----------|--------|
| Domain | New **`Verscienta.Gamification`** domain |
| Points storage | Append-only **`PointsEntry` ledger** (idempotency key `source_ref`) + cached `points` integer on `User` |
| Level | **Derived** from points via a pure function (no table/column) |
| Award mechanism | **Oban job** (`AwardWorker`) enqueued from Ash after-action hooks; `award/4` idempotent by `source_ref` |
| Point sources | `:article_published`, `:comment_posted`, `:reaction_received`, `:reading` |
| Reaction-received | Awards the **article's author**; skips authorless aggregated articles |
| Reading | **30s visible dwell** via a LiveView JS heartbeat; once per user per article per **calendar day** |
| Badges | **Milestone `Badge` catalog + `UserBadge`** awards; re-evaluated on each `award/4` |
| Claw-back | **None** — award-only; soft-deleting a comment / un-reacting does not subtract points |
| Profile | Show points, derived level, and earned badges (all public) |

## Section 1: Domain & resources

New domain `Verscienta.Gamification` in `config :verscienta, ash_domains`.

### `PointsEntry` (`points_entries`)
- `id` uuid pk.
- `belongs_to :user, Verscienta.Accounts.User` (`allow_nil? false`).
- `amount` — `:integer`, `allow_nil? false`.
- `source` — `:atom`, `allow_nil? false`, `one_of [:article_published, :comment_posted, :reaction_received, :reading]`.
- `source_ref` — `:string`, `allow_nil? false` (idempotency key, e.g. `"article:<uuid>"`, `"reading:<uid>:<aid>:<date>"`).
- `create_timestamp :inserted_at`.
- identity `unique_source_ref` on `[:user_id, :source, :source_ref]`.

### `Badge` (`badges`)
- `id` uuid pk; `key` — `:atom`, unique identity `unique_key`; `name` — `:string`; `description` — `:string`.
- `threshold_source` — `:atom`, nullable (`nil` = points-based; otherwise a `PointsEntry` source to count).
- `threshold_value` — `:integer` (points total for points-based, or count of entries of `threshold_source`).
- Seeded catalog; read-public.

### `UserBadge` (`user_badges`)
- `belongs_to :user`, `belongs_to :badge`; `awarded_at :utc_datetime_usec`.
- identity `unique_user_badge` on `[:user_id, :badge_id]`.

### `User` change
- Add `attribute :points, :integer, allow_nil?: false, default: 0, public?: true`. Updated by the award engine (writable only via a system update, not user-facing actions — like `role`, kept out of `update_profile`'s accept list).
- `has_many :user_badges`, `has_many :points_entries` (for display/aggregation).

## Section 2: Award engine

`Verscienta.Gamification.Points` — config module:
```
@values %{article_published: 50, comment_posted: 5, reaction_received: 2, reading: 10}
def value(source), do: Map.fetch!(@values, source)
def level_for(points) — pure: e.g. level = floor(:math.sqrt(points / 50)) + 1 (documented thresholds)
```

`Verscienta.Gamification.award(user_id, source, source_ref)`:
1. Insert a `PointsEntry` with `amount = Points.value(source)`. **Idempotent**: an existing `(user_id, source, source_ref)` → no-op (rescue/ignore the unique-constraint error, return `:ok` without re-incrementing).
2. On a genuinely new entry, increment the user's cached `points` by `amount` (a system update action `add_points`).
3. **Re-evaluate badges**: for each `Badge` the user now qualifies for (points-based: `user.points >= threshold_value`; source-count: count of the user's `PointsEntry` with that `source` >= `threshold_value`) and doesn't already hold → create a `UserBadge`.
4. Broadcast `{:points_changed, user_id}` on a `"user:<id>"` topic (for optional live profile/nav update; ids only).

`award/4` is the single writer; all hooks/worker call it. Reading the catalog + counting entries are cheap reads with `authorize?: false` (system context).

## Section 3: Earning hooks (Oban)

`Verscienta.Gamification.Workers.AwardWorker` (queue `:default`, `unique` on args) — `perform` calls
`Gamification.award(user_id, source, source_ref)`. Hooks (Ash after-action changes on existing resources)
enqueue it:

- **Article publish** — change on `Verscienta.Content.Article.:publish`: enqueue `{author_id, :article_published, "article:<id>"}` (skip if `author_id` nil — aggregated). `source_ref` is article-stable, so re-publishing/editing never double-awards.
- **Comment posted** — change on `Verscienta.Engagement.Comment.:create`: enqueue `{user_id, :comment_posted, "comment:<id>"}`. Replies included. No claw-back on soft-delete.
- **Reaction received** — change on `Verscienta.Engagement.Reaction` create (within `:toggle`'s create path, or an after-action on the create): load the article's `author_id`; if present, enqueue `{author_id, :reaction_received, "reaction:<id>"}`. Authorless (aggregated) → skip. (Un-reacting destroys the reaction but does not claw back — award-only.)
- **Reading** — see Section 4.

After-action hooks that enqueue Oban jobs are **best-effort** (rescue + log; never roll back the user's action), mirroring the engagement `EnqueueIndex`/search pattern.

## Section 4: Reading-time tracking

- JS hook `ReadingTimer` (in `assets/js`, registered on the LiveSocket): on mount starts counting; listens to `visibilitychange` to pause when hidden; once accumulated **visible** time reaches **30s**, `pushEvent("reading_complete", %{})` exactly once per mount, then stops.
- The reader LiveView (`ArticleReaderLive`) handles `"reading_complete"`: for a signed-in user, enqueue
  `AwardWorker` with `{user_id, :reading, "reading:<user_id>:<article_id>:<Date.utc_today()>"}`. Signed-out → ignore.
- The daily `source_ref` dedupes across reloads/multiple opens; `award/4`'s idempotency is the hard guard.
- The hook attaches only on the reader; a `phx-hook` on a container element with the article id in a data attribute.

## Section 5: Profile display + seeds

- **`/@:username`** (`ProfileLive`): load the user's `points`, `user_badges` (+ `:badge`); render a derived
  **level** chip, the **points** total, and earned **badge** chips (name; description on hover/title). All public.
- **Seeds** (idempotent): a starter `Badge` catalog —
  - `first_article` — "First Article" — source `:article_published`, value 1
  - `wordsmith` — "Wordsmith" — source `:article_published`, value 5
  - `first_comment` — "First Comment" — source `:comment_posted`, value 1
  - `conversationalist` — "Conversationalist" — source `:comment_posted`, value 10
  - `centurion` — "Centurion" — points-based, value 100
  Seeds upsert by `key`.
- No leaderboard, reward store, or quests (Phase 2).

## Section 6: Testing

All tests stub nothing external; Oban `testing: :manual`.

**Domain (DataCase)**
- `award/3`: writes a `PointsEntry` with the right amount and bumps `User.points`; a duplicate `source_ref`
  is a no-op (points unchanged, one entry).
- Badge award: crossing a points threshold grants the badge once; re-running `award` doesn't double-grant;
  a source-count badge (e.g. 1 article) grants on the first qualifying entry.
- `Points.level_for/1`: boundary values (0 → level 1, threshold crossings).

**Hooks + worker**
- Publishing an article enqueues `AwardWorker {author_id, :article_published, "article:<id>"}`; an aggregated
  (authorless) publish path enqueues nothing.
- Posting a comment enqueues `{user_id, :comment_posted, ...}`.
- A reaction on an authored article enqueues `{author_id, :reaction_received, ...}`; on an aggregated
  (authorless) article enqueues nothing.
- `AwardWorker.perform/1` calls `award/3` (assert the points/entry result).

**Reader (LiveView)**
- A signed-in `reading_complete` event enqueues a reading AwardWorker once; a second event same day is still
  one award (dedupe via source_ref — assert only one entry after running the job twice). Signed-out: no enqueue.

**Profile**
- A user with points + an earned badge shows the points total, a level, and the badge name on `/@:username`.

**Gates:** existing CI (`compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, `test`).
Migrations via `mix ash.codegen`.

## Out of Scope (deferred — Phase 2+)

- Leaderboards (weekly/monthly/global/category), reward store, quests/challenges, streaks.
- Point claw-back / decay / undo.
- Notifications on level-up / badge earned (Notifications subsystem).
- Real-time profile/nav points display beyond a simple broadcast hook (broadcast emitted; live nav update optional).
- Per-category or expert-weighted scoring; anti-abuse/rate-limiting of point farming.
- Denormalized leaderboard snapshots.

## Definition of Done

- Publishing, commenting, receiving a reaction, and 30s of reading award Vitality Points via Oban, recorded in
  an append-only ledger and reflected in `User.points`; all awards idempotent (no double-counting on retry,
  re-publish, reload).
- Reaction-received awards the article's author and skips authorless aggregated articles.
- Milestone badges are granted when thresholds are crossed (once each); levels derive from points.
- `/@:username` shows points, level, and earned badges.
- Point-earning hooks are best-effort (never roll back the user action).
- All tests pass; CI green; migrations + badge seeds committed on `phase-1-gamification`.
