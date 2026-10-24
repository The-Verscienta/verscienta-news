# Activity Feeds Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-02
**Status:** Approved
**Phase:** 2 (Social & Gamification) — Subsystem 2 of 7: Activity Feeds
**Depends on:** Social Graph (merged). Reuses Accounts (`User`), Content (`Article`), Engagement
(`Comment`, `Reaction`), Gamification (`UserBadge`), and the `Verscienta.Social` domain + PubSub.

## Goal

A public **actor-action activity stream**: capture user actions (publish, follow, repost, comment,
react, earn badge) as immutable `ActivityEvent`s, and expose a Personal feed (from people you
follow), a Global feed (everyone), and a per-user activity tab on profiles — with real-time
insertion via PubSub. This is distinct from the content "Following feed" (articles/reposts) built in
the Social Graph subsystem, and neighbors the upcoming Notifications subsystem (personal
"what happened to you"), which can later reuse this event model.

## Decisions

| Decision | Choice |
|----------|--------|
| Assembly strategy | **Fan-in / read-time** — one `ActivityEvent` table; feeds are queries. No materialization. |
| Event types | `:published`, `:followed` (user targets only), `:reposted`, `:commented`, `:reacted`, `:earned_badge` |
| Mutability | Each event carries a `source_ref` tying it to its source record. **Toggle actions emit on create and remove the event on toggle-off.** Comment events are **capped to one per (actor, article)**. Publish/badge persist. |
| Object reference | Polymorphic `subject_type` + `subject_id` (string) + a `metadata` display **snapshot** map; `source_ref` for idempotent emit + precise removal |
| Feeds | Personal (people you follow **+ your own activity**; signed-in), Global (all; public), Profile activity tab |
| Real-time | Single `"activity"` PubSub topic; LiveView streams prepend; personal/profile filter by actor |
| Emission | Best-effort (rescued) from existing after-action hooks; never breaks the underlying action |
| Deferred | Fan-out/materialization; Notifications; category/source/tag follow activity; mute/filter prefs; aggregation/grouping; rich pagination |

## Data model

### `Verscienta.Social.ActivityEvent`
Registered in the existing `Verscienta.Social` domain (activity is social).
- **Attributes:**
  - `actor_id` (uuid) — `belongs_to :actor, Verscienta.Accounts.User`, `allow_nil?: false`
  - `verb` (atom, `allow_nil?: false`, one_of `[:published, :followed, :reposted, :commented, :reacted, :earned_badge]`)
  - `subject_type` (atom, `allow_nil?: false`, one_of `[:article, :user, :badge, :comment]`)
  - `subject_id` (string, `allow_nil?: false`) — UUID string or stable id of the object
  - `metadata` (map, default `%{}`, public) — display snapshot, e.g.
    `%{"article_title" => ..., "article_slug" => ..., "target_username" => ..., "badge_label" => ...}`
  - `source_ref` (string, `allow_nil?: false`) — stable key tying the event to its source record,
    e.g. `"reaction:<id>"`, `"follow:<id>"`, `"repost:<id>"`, `"comment:<actor_id>:<article_id>"`
    (the comment cap), `"article_published:<id>"`, `"userbadge:<id>"`. Used for idempotent emit and
    precise removal.
  - `create_timestamp :inserted_at`
- **Actions:**
  - `create :create` — system action; accepts `actor_id`, `verb`, `subject_type`, `subject_id`,
    `metadata`, `source_ref`. Invoked only internally via `Social.emit_activity/1` with
    `authorize?: false`. Idempotent: a duplicate `source_ref` is ignored (upsert on the
    `unique_source_ref` identity, or rescue the unique violation) so re-emits/caps don't duplicate.
  - `destroy :destroy` — system action; used by `Social.remove_activity/1` (with `authorize?: false`).
  - reads: default `:read`; `:global` (sort `inserted_at: :desc`); `:by_actors`
    (arg `actor_ids`, filter `actor_id in ^arg`); `:for_actor` (arg `actor_id`, filter `actor_id == ^arg`);
    `:by_source_ref` (arg `source_ref`, `get? true`).
- **Policies:** `action_type(:read)` → `authorize_if always()`; create/destroy → `authorize_if always()`
  (only ever called with `authorize?: false`); no user-facing mutation.
- **Identities:** `identity :unique_source_ref, [:source_ref]`.
- **Indexes (migration):** `inserted_at` (feed ordering), `actor_id` (personal/profile queries),
  plus the unique index on `source_ref`.
- **Why the snapshot:** rendering needs no joins to the subject and survives later
  archival/deletion of the subject (the line still reads correctly). The actor is loaded via the
  `:actor` relationship (one batched query), since current username is the desired display.

### Migration
`mix ash.codegen add_activity_events` after the resource + domain registration. No changes to
existing tables.

## Emission & removal

`Social.emit_activity(attrs)` where `attrs` = `%{actor_id, verb, subject_type, subject_id, source_ref, metadata}`:
- Creates the `ActivityEvent` (`authorize?: false`), idempotent on `source_ref` (duplicate ignored).
- Broadcasts `{:activity, event_id}` on the `"activity"` topic.
- Best-effort (`rescue -> :ok`) so a failure never breaks the calling action.

`Social.remove_activity(source_ref)`:
- Looks up the event by `source_ref` (`:by_source_ref`); if found, destroys it (`authorize?: false`)
  and broadcasts `{:activity_removed, event_id}` on `"activity"`.
- Best-effort (no-op if absent).

Wired into existing after-action hook points. Toggle actions emit on the **create branch** and remove
on the **destroy branch**; non-toggle actions emit once:

| Source | verb | emit on | remove on | subject | `source_ref` | metadata snapshot |
|--------|------|---------|-----------|---------|--------------|-------------------|
| `Content.Article` `:publish` | `:published` | publish (after_action) | — (persists) | `:article`, id | `article_published:<id>` | `article_title`, `article_slug` |
| `Social.Follow` `:toggle` (user targets only) | `:followed` | create branch | destroy branch | `:user`, followed id | `follow:<follow_id>` | `target_username` |
| `Social.Repost` `:toggle` | `:reposted` | create branch | destroy branch | `:article`, id | `repost:<repost_id>` | `article_title`, `article_slug` |
| `Engagement.Comment` `:create` | `:commented` | create (after_action) | — (capped; persists) | `:article`, id | `comment:<actor_id>:<article_id>` | `article_title`, `article_slug` |
| `Engagement.Reaction` `:toggle` | `:reacted` | create branch | destroy branch | `:article`, id | `reaction:<reaction_id>` | `article_title`, `article_slug`, `kind` |
| `Gamification.UserBadge` `:create` | `:earned_badge` | create (after_action) | — (persists) | `:badge`, id | `userbadge:<id>` | `badge_label` |

Notes:
- **Toggle removal:** un-follow / un-repost / un-react deletes the matching event (matched by the
  source record's id in `source_ref`), so the feed reflects current state. The destroy branch of each
  `:toggle` `run` fn already holds the existing record — call `remove_activity("<type>:<id>")` there.
- **Comment cap:** the `source_ref` is keyed by `(actor_id, article_id)`, so only a user's *first*
  comment on a given article emits an event; subsequent comments are deduped (idempotent emit). The
  event persists (comments are not toggles); a soft-deleted comment leaves the historical event.
- Follow emits for `:user` targets only (category/source/tag follows are out of scope for activity).
- Snapshot fields are looked up at emit time (the records exist then); `metadata` keys are strings.

## Feed queries (fan-in, read-time)

Context functions in `Verscienta.Social`:
- `global_activity(opts)` — `:global` read, `Ash.Query.load(:actor)`, `limit` (default 50).
- `personal_activity(actor, opts)` — `actor_ids = [actor.id | followed_user_ids(actor.id)]`
  (**people you follow plus your own activity**); `:by_actors`, load `:actor`, newest first, limit.
- `user_activity(user_id, opts)` — `:for_actor`, load `:actor`, newest first, limit (profile tab).

## Real-time (PubSub)

- Topic constant `"activity"`. `emit_activity` broadcasts `{:activity, event_id}`; `remove_activity`
  broadcasts `{:activity_removed, event_id}`.
- A small loader `Social.get_activity(event_id)` (loads `:actor`) is used by LiveViews on receipt.
- Global feed LiveView: subscribe `"activity"`; on `{:activity, id}` load + `stream_insert(at: 0)`;
  on `{:activity_removed, id}` `stream_delete_by_dom_id`.
- Personal feed: same, but only insert when `event.actor_id in @feed_actor_ids`
  (your follows + self); removals apply if present.
- Profile activity: same, but only insert when `event.actor_id == @profile_user.id`.
- All three use **LiveView streams** for efficient prepend/remove/bounded DOM. Stream DOM ids derive
  from the event id so removals target the right node.

## UI

- **`/activity` LiveView** with **Personal | Global** tabs via a `tab` URL param (mirrors the
  `/articles` pivot). Personal is signed-in only (sign-in CTA otherwise). Global is public.
- **`/@:username/activity`** — profile activity (route added next to `/followers`, `/following`;
  rendered by `ProfileLive` with a new `:activity` live_action).
- Shared `activity_item/1` function component (in `VerscientaWeb.SocialComponents`): renders a
  one-line entry "**@actor** *verb phrase* **object** · *relative time*", formatted per verb from
  the metadata snapshot, with safe links (actor → `/@username`, article → `/articles/:slug`,
  followed user → `/@username`, badge → profile/none). A small `verb phrase` helper maps verb →
  text ("published", "followed", "reposted", "commented on", "reacted to", "earned the badge").
- Add an **"activity"** link to `nav_links/1`.
- Relative time: a small helper formatting `inserted_at` (e.g. "3h ago"); no new dependency.

## Safety

- Actor username and snapshot titles render as escaped text via HEEx `{...}`.
- Links built from slugs/usernames (safe charsets) using verified routes (`~p`).
- No raw HTML; `metadata` values are plain strings captured at emit time.
- No user-facing mutation: events are created/removed only by the system (`authorize?: false`) from
  the action hooks — a user cannot directly create, edit, or delete another user's events. Removal
  happens solely as the mirror of toggling off one's own action.

## Testing & gates

- **Emission:** each of the 6 hooks creates exactly one event with the right `verb`/`subject_type`/
  `subject_id`/`source_ref`/`metadata` on the creating action.
- **Removal on toggle-off:** un-react / un-follow / un-repost deletes the matching event (assert it's
  gone by `source_ref`); the source record's id keys the removal.
- **Comment cap:** a user's first comment on an article emits one event; a *second* comment on the
  same article by the same user emits **no** additional event (idempotent `source_ref`).
- **Best-effort:** emission failure does not raise out of the underlying action (the action still
  succeeds).
- **Feed queries:** global returns newest-first; personal includes followed actors' events **and the
  actor's own**, and excludes non-followed others; profile returns only that user's events.
- **Gating:** signed-out request to `/activity?tab=personal` shows the sign-in CTA, not a crash;
  `/activity` (global) renders signed-out.
- **Real-time:** a LiveView mounted on the global feed receives a broadcast and renders the new item
  (assert the streamed item markup appears after a simulated emit/broadcast).
- **Seeds:** add a few events; existing tests unaffected (events are additive rows in a new table).
  Because emission now fires from existing hooks, confirm no existing test asserts a count that the
  added rows would break (they target other tables — safe).
- All CI gates green: `mix compile --warnings-as-errors`, `mix format --check-formatted`,
  `mix credo --strict`, `MIX_ENV=test mix test`. Migration via `mix ash.codegen`.

## Out of scope (deferred)

- Fan-out / materialized per-user feed tables (future scale; the event model is the source of truth).
- **Notifications** (next subsystem) — personal recipient-centric stream; may reuse `ActivityEvent`.
- Activity events for category/source/tag follows.
- Mute/filter/visibility preferences; private activity.
- Aggregation/grouping ("@alice and 3 others reacted").
- Cursor pagination / infinite scroll beyond a simple limit + load-more.

## Definition of Done

- `ActivityEvent` resource (with `source_ref` unique identity) in `Verscienta.Social`; migration
  applied; domain registered.
- All 6 actions emit events via best-effort hooks; toggle-off removes the event; comments capped to
  one per (actor, article).
- `/activity` Personal/Global tabs (Personal gated to signed-in); `/@:username/activity` profile tab.
- Personal feed = people you follow + your own activity; Global = everyone; profile = that user's events.
- New events appear (and toggle-removed events disappear) in real time (PubSub + LiveView streams) on
  all three feeds (filtered correctly).
- Activity rendering is XSS-safe and resilient to deleted subjects (snapshot).
- "activity" nav link present.
- All gates green; migration via `mix ash.codegen`; work committed on `activity-feeds`.
