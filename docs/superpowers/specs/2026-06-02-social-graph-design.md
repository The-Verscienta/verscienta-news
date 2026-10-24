# Social Graph Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-02
**Status:** Approved
**Phase:** 2 (Social & Gamification) — Subsystem 1 of 7: Social Graph
**Depends on:** Phase 1 (all subsystems merged). Reuses Accounts (`User`), Content (`Article`, `Source`, `Tag`, `Category`), and Engagement (`Reaction`, `Comment`) patterns.

## Goal

A real social graph: users can **follow** four kinds of targets (other users, categories,
sources, tags), see a **Following** feed and a **Trending** feed, **@mention** other users in
comments, and **repost** (optionally with a quote) articles into their followers' feed. No new
external services. Read-time queries (no materialized feeds) — fan-out is explicitly the next
subsystem's (Activity Feeds) decision.

## Decisions

| Decision | Choice |
|----------|--------|
| Follow model | **Generic polymorphic**: one `Follow(user_id, target_type, target_id)` table |
| Follow targets | `:user`, `:category`, `:source`, `:tag` (Category is an atom value, not an FK) |
| Counts | Ash **aggregates** (no denormalized counters); caching deferred to Phase 2 cross-cutting |
| Following feed | **Read-time fan-in** query over published articles + reposts by followed users |
| Trending feed | Read-time engagement score over a rolling window (default 7 days) |
| Feed pivot | Tabs on existing `ArticleFeedLive` (`/articles`): Latest / Following / Trending, via URL param |
| Mentions | Render-time linkify of `@username` in comments (DB stays plain text); XSS-safe escaping |
| Reposts | `Repost(user_id, article_id, quote?)` resource; toggle; appears in Following feed |
| Real-time | PubSub per-user topic for live counts/button state; live feed insertion deferred |
| Deferred | For-You ranking (Phase 3); mention notifications + real-time feed insertion; follow/repost points; caching layer; denormalized counters; public source/tag landing pages |

## Data model

### `Verscienta.Social` domain
New Ash domain registered in `config :verscienta, ash_domains`. Holds `Follow` and `Repost`.

### `Follow` resource (generic polymorphic)
- **Attributes:**
  - `user_id` (uuid, the follower) — `belongs_to :user, Verscienta.Accounts.User`
  - `target_type` (atom, constraints one_of `[:user, :category, :source, :tag]`, `allow_nil?: false`)
  - `target_id` (string, `allow_nil?: false`) — UUID string for `:user`/`:source`/`:tag`; the
    category value (atom-as-string) for `:category`
  - timestamps
- **Identity:** `identity :unique_follow, [:user_id, :target_type, :target_id]`
- **Actions:**
  - `:toggle` (generic action returning the follow or `nil`): args `target_type`, `target_id`.
    Validates the target exists (user/source/tag by id; category against `Category` helper).
    Rejects self-follow (`target_type == :user and target_id == actor.id`). Creates if absent,
    else destroys. Broadcasts on change. Mirrors `Engagement.Reaction.toggle`.
  - `:following_for` (read): filter `user_id == ^arg(:user_id)`; optional `target_type` filter.
  - `:followers_of` (read): filter `target_type == ^arg(:target_type) and target_id == ^arg(:target_id)`
    and `target_type == :user` variant for follower lists.
  - default `:read`.
- **Policies:** `:toggle` → `authorize_if actor_present()`; `action_type(:destroy)` → `forbid_if always()`
  (toggle destroys with `authorize?: false`); reads public (`authorize_if always()`).

### `Repost` resource
- **Attributes:** `user_id` (reposter), `article_id`, `quote` (string, nullable, `max_length: 500`),
  timestamps. `belongs_to :user, User`; `belongs_to :article, Verscienta.Content.Article`.
- **Identity:** `identity :unique_repost, [:user_id, :article_id]`
- **Actions:**
  - `:toggle`: arg `article_id`, optional `quote`. Create if absent (with quote), else destroy.
    Broadcasts on change.
  - `:update_quote`: change the quote on an existing repost (owner only).
  - reads: `:by_users` (filter `user_id in ^arg(:user_ids)`, for feed assembly), default `:read`.
- **Policies:** create/toggle → `actor_present()`; update/destroy → `expr(user_id == ^actor(:id))`.

### Migration
`mix ash.codegen add_social_follows_reposts` after both resources + domain are defined and
registered. No changes to existing tables.

## Counts & "am I following?"

- On `User`: `count` aggregates `following_count` (Follows where `user_id == id`) and
  `followers_count` (Follows where `target_type == :user and target_id == id` cast to string).
- Per-target follower counts (a tag/source/category's followers) via a small count helper in the
  `Social` context (`Social.follower_count(target_type, target_id)`).
- "Is the actor following X?" resolved per page via a scoped read (`Social.following?(actor, type, id)`),
  used to seed the follow button's initial state. Aggregates/reads now; the Phase 2 caching layer
  (Redis/ETS) optimizes hot counts later.

## Following feed (read-time fan-in)

`Social.following_feed(actor, opts)` returns time-ordered **feed items**, each tagged `:article`
or `:repost`:
1. Load the actor's follows, partitioned by `target_type` into followed user-ids, source-ids,
   tag-ids, category-values.
2. Query published `Article`s where `author_id ∈ user-ids` **OR** `source_id ∈ source-ids` **OR**
   `category ∈ category-values` **OR** exists a tag in tag-ids; sort `published_at desc`.
3. Query `Repost`s by followed users (`:by_users`), load each repost's article, sort by repost
   `inserted_at desc`.
4. Merge both lists by timestamp, newest first, limited/paginated.

A repost item renders the referenced article card with a "↻ @user reposted" header and the optional
quote above it. Empty state (no follows / no content) shows a prompt to find people/topics to follow.

## Trending feed

`Social.trending(opts)` ranks published articles by engagement within a rolling window:
- `score = reactions_in_window·w₁ + comments_in_window·w₂`, ordered desc, limited (default 30).
- Window + weights live in a `Verscienta.Social.Trending` config module (default window 7 days,
  `w₁ = 1`, `w₂ = 2`). Read-time aggregate query now; cached later. Ties broken by `published_at desc`.

## Feed pivot UI

`ArticleFeedLive` (`/articles`) gains three tabs driven by a URL param via `handle_params`:
- `?feed=latest` (default) → existing `:list_published`.
- `?feed=following` → `Social.following_feed/2`; **signed-in only** (signed-out shows a sign-in CTA).
- `?feed=trending` → `Social.trending/1`.

A shared feed-card function component renders both `:article` and `:repost` items (reposts wrap an
article card with the repost header + quote). Tabs are real links (shareable, back-button friendly).
The marketing `/` page is unchanged.

## Follow button + lists (optimistic UI)

- A reusable follow button component (`<.follow_button target_type=… target_id=… following?=… count=…/>`).
  `phx-click` optimistically flips label ("follow" ⇄ "following") and the local count, the server
  `:toggle` confirms, and PubSub syncs other open clients.
- Placement: profile page (user follows), category page `/c/:category` (category follows); source/tag
  buttons where public pages exist (tag/source public landing pages are out of scope for this slice —
  the button component is ready for them).
- Profile (`/@:username`) shows **following/followers** counts and adds list views
  `/@:username/followers` and `/@:username/following` (paginated user lists, each with its own
  follow button).

## @mentions in comments (render-time, XSS-safe)

- Comment bodies remain **plain text** in the DB (no stored HTML).
- `Verscienta.Social.Mentions.linkify(body, opts)`:
  1. Extract `@username` tokens (regex matching the username charset `[A-Za-z0-9_]{3,30}`).
  2. Batch-validate which usernames exist.
  3. Emit safe HTML: existing usernames → `<a href="/@username">@username</a>`; all other text
     HTML-escaped. Returns a `{:safe, iodata}`-compatible result for HEEx.
- Applied in the comment render path (reader LiveView). Mention **notifications** are deferred to the
  Notifications subsystem.

## Real-time (PubSub)

Reuse the per-user topic convention (`Social.topic/subscribe/broadcast`, topic `"user:<id>"`):
- Follow toggle on a `:user` target broadcasts `{:followers_changed, user_id}` to the followed user's
  topic and `{:following_changed, follower_id}` to the follower's topic.
- Open profile pages subscribe and live-update counts + button state.
- Live **feed insertion** (new items appearing without reload) is deferred to the Activity Feeds
  subsystem to keep this slice bounded.

## Safety & integrity

- Self-follow rejected in `:toggle`.
- Direct `:destroy` forbidden on `Follow` (toggle-only path).
- Reposts owner-scoped for update/destroy.
- Mention linkify escapes all non-mention text; only existing usernames are linked.
- Orphaned follows (target later deleted) are filtered at query/count time (existence joins); a
  periodic prune job is a noted follow-up, not a hard FK (Category can't be an FK anyway).

## Testing & gates

- `Follow`: toggle creates/destroys idempotently; identity uniqueness; self-follow rejected; direct
  destroy forbidden; counts/aggregates correct; per-target follower count.
- `Repost`: toggle; one-per-article identity; owner-only update/destroy; quote length constraint.
- `Following feed`: fan-in correctness across all four target types + reposts by followed users;
  signed-out gating.
- `Trending`: ranking order honors the window + weights; ties by recency.
- `Mentions`: linkify links existing users, leaves unknown `@x` as escaped text, and an XSS attempt
  in a comment body is neutralized.
- **Test-DB note:** social seeds must not break existing `list_published` / `list_by_category` count
  assertions (per the seed-contamination lesson) — scope or clean seeded rows in affected tests.
- All CI gates green: `mix compile --warnings-as-errors`, `mix format --check-formatted`,
  `mix credo --strict`, `MIX_ENV=test mix test`.

## Out of scope (deferred)

- "For You" personalized ranking — Phase 3 (recommendation engine).
- Mention notifications + real-time feed insertion — Notifications / Activity Feeds subsystems.
- Follow/repost gamification points — optional, deferred (avoid gaming + scope creep).
- Caching layer (Redis/ETS) for counts/feeds/trending — Phase 2 cross-cutting.
- Denormalized follower/following counters — start with aggregates.
- Public source/tag landing pages — the follow button is ready; the pages themselves are out of scope.

## Definition of Done

- `Follow` (4 target types) + `Repost` resources in a new `Verscienta.Social` domain; migration applied.
- Follow/unfollow toggle with optimistic UI + live counts; follow buttons on profile + category pages.
- Profile shows follower/following counts and followers/following list pages.
- `/articles` has working Latest / Following / Trending tabs (Following gated to signed-in users).
- Following feed merges followed-target articles + reposts by followed users; Trending ranks by
  windowed engagement.
- `@username` in comments renders as safe profile links; XSS attempt neutralized.
- Reposts (with optional quote) work and appear in followers' Following feed.
- All gates green; migration via `mix ash.codegen`; work committed on `social-graph`.
