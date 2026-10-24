# Engagement (Comments · Reactions · Bookmarks) Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-05-31
**Status:** Approved
**Phase:** 1 (MVP) — Subsystem 5 of 6
**Depends on:** Phase 0; Subsystem 1 (Auth — `User`, roles, `live_user_required`/`optional`); Subsystem 2 (Content — `Article`, reader/feed LiveViews, CodexComponents). Phoenix.PubSub is already supervised (`Verscienta.PubSub`).

## Goal

Let signed-in users engage with articles: threaded comments (one level of replies), a small
set of reactions, and save-for-later bookmarks with a personal library page. Comments and
reaction counts update live via Phoenix PubSub.

## Decisions

| Decision | Choice |
|----------|--------|
| Domain | New **`Verscienta.Engagement`** domain (distinct bounded context) |
| Comments | **One-level replies** (top-level + single reply depth); soft-delete tombstone "[deleted]" |
| Reactions | **Articles only**, fixed small set (`:like`, `:insightful`, `:helpful`); one per user per article per kind; toggle |
| Bookmarks | Per user+article toggle + a `/library` page |
| Realtime | **Phoenix PubSub** per-article topic; reader LiveView subscribes + live-updates |
| Who can comment | **Any signed-in user** (confirmed-email gating deferred to Moderation subsystem) |
| Comment edit | Out of scope (create + soft-delete only) |
| Comment reactions | Deferred (reactions on articles only this round) |

## Section 1: Domain & resources

New domain `Verscienta.Engagement`, registered in `config :verscienta, ash_domains`. All three
resources use `AshPostgres`, `Ash.Policy.Authorizer`, and reference `Article`/`User` by id.

### `Comment` (`comments` table)
- `id` uuid pk.
- `body` — `:string`, `allow_nil? false`, public, `max_length` 2000.
- `belongs_to :article, Verscienta.Content.Article` (`allow_nil? false`).
- `belongs_to :user, Verscienta.Accounts.User` (`allow_nil? false`) — the author.
- `belongs_to :parent, Verscienta.Engagement.Comment` (`allow_nil? true`) — reply target; **must be top-level** (its own `parent_id` is nil) and on the same article.
- `deleted_at` — `:utc_datetime_usec`, nullable (soft-delete tombstone).
- `create_timestamp :inserted_at`, `update_timestamp :updated_at`.
- `has_many :replies, Comment` (destination `parent_id`).

### `Reaction` (`reactions` table)
- `id` uuid pk.
- `belongs_to :user` (`allow_nil? false`), `belongs_to :article` (`allow_nil? false`).
- `kind` — `:atom`, `allow_nil? false`, `one_of [:like, :insightful, :helpful]`.
- timestamps.
- identity `unique_user_article_kind` on `[:user_id, :article_id, :kind]`.

### `Bookmark` (`bookmarks` table)
- `id` uuid pk.
- `belongs_to :user` (`allow_nil? false`), `belongs_to :article` (`allow_nil? false`).
- timestamps.
- identity `unique_user_article` on `[:user_id, :article_id]`.

## Section 2: Actions & authorization

### Comment
- `create` — accepts `body`, `article_id`, `parent_id` (nullable). `change relate_actor(:user)`.
  A validation/`before_action` enforces: if `parent_id` present, the parent exists, has
  `parent_id == nil` (no nesting beyond one level), and `parent.article_id == article_id`.
- `soft_delete` — sets `deleted_at` to now; accepts nothing.
- reads: `list_for_article` (arg `article_id`) — all comments for the article (top-level +
  replies), oldest-first, **including tombstones** (rendered as "[deleted]" by the UI), with
  `:user` and `:replies` (+ replies' `:user`) loadable.
- No `update`/edit action in MVP.

### Reaction
- `toggle` — a generic action (or create+destroy pair) keyed by `user/article/kind`: if a
  matching reaction exists, destroy it; else create it. Signed-in only.
- read: `for_article` (arg `article_id`) → all reactions for the article (UI derives per-kind
  counts and the current user's set). Public.

### Bookmark
- `toggle` — create if absent for `user/article`, else destroy. Signed-in only.
- read: `list_for_user` — the actor's bookmarks (with `:article`), newest-first. Private.

### Policies
- `Comment.create` → `actor_present()`. `Comment.soft_delete` → author (`user_id == ^actor(:id)`)
  **or** elevated role (`^actor(:role) in [:moderator, :admin]`). Comment reads → public.
- `Reaction.toggle` / `Bookmark.toggle` → `actor_present()`. Reaction reads → public.
- `Bookmark.list_for_user` → `user_id == ^actor(:id)` (private).

## Section 3: Realtime (PubSub)

- Topic: `"article:" <> article_id`.
- A helper `Verscienta.Engagement.broadcast(article_id, message)` wraps
  `Phoenix.PubSub.broadcast(Verscienta.PubSub, topic, message)`.
- After-action hooks broadcast:
  - comment created → `{:comment_created, comment_id}` (subscribers reload/insert the comment).
  - comment soft-deleted → `{:comment_deleted, comment_id}`.
  - reaction toggled → `{:reactions_changed, article_id}`.
  - (bookmarks are private — no broadcast.)
- The reader LiveView subscribes on mount (if connected) and handles these messages, updating
  a **comments stream** and a **reaction-counts assign**. Messages carry ids only; the
  LiveView re-reads minimal data (keeps payloads small, avoids serializing structs over PubSub).

## Section 4: Reader integration + library page

### Reader `/articles/:slug` (existing `ArticleReaderLive`, `:live_user_optional`)
Below the article body + medical disclaimer, add (only meaningful for published articles):
- **Reactions bar** — the three kinds with live counts; signed-in users toggle (Codex pill
  buttons; active = zune fill). Signed-out: counts shown + "sign in to react".
- **Bookmark** toggle — save / saved state (signed-in only).
- **Comments section**:
  - Post box (signed-in; signed-out sees a sign-in prompt).
  - Top-level comments oldest-first via a LiveView **stream**; each shows author `@username`
    (link), relative time, body, a **reply** box, and its one level of replies.
  - Soft-deleted comments render "[deleted]" but keep their replies visible.
  - Author / moderator / admin sees a **delete** control on their (or any, for mods) comment.
  - Live updates via the article PubSub topic.

### `/library` → `LibraryLive` (`:live_user_required`)
- The current user's bookmarked articles as Codex `news_card`s (newest-first), linking to the
  reader; empty state when none.
- Top-strip nav: add a `library` link in the signed-in branch.

## Section 5: Testing

**Domain (DataCase)**
- Comment: create sets author + article; a reply to a top-level comment works; **a reply to a
  reply is rejected**; a reply whose parent is on a different article is rejected.
- Comment soft_delete: by author succeeds; by a moderator succeeds; by an unrelated user is
  forbidden; `deleted_at` set; `list_for_article` still returns it (tombstone).
- Reaction: toggle creates then destroys; unique per kind (two `:like`s by same user/article →
  one row); per-kind counts; a different kind coexists.
- Bookmark: toggle creates then destroys; `list_for_user` returns only the actor's, newest
  first; another user can't read them.

**Realtime**
- Subscribing to `"article:<id>"` then creating a comment / toggling a reaction delivers the
  expected `{:comment_created, _}` / `{:reactions_changed, _}` message.

**Web (ConnCase / LiveView)**
- Reader renders the reactions bar + comments; a signed-in user posts a comment (appears in
  the stream) and toggles a reaction (count changes) and a bookmark.
- A second connected reader receives the new comment live (PubSub) — or at minimum the
  posting LiveView reflects it (full cross-client test if feasible).
- `/library` requires auth (redirect when signed out) and lists the user's bookmarks.

**Gates:** existing CI (`compile --warnings-as-errors`, `format --check-formatted`,
`credo --strict`, `test`). Migrations via `mix ash.codegen`.

## Out of Scope (deferred)

- Comment editing; nesting beyond one reply level.
- Reactions on comments; emoji/custom reactions beyond the fixed set.
- Mentions/notifications on reply (Notifications is a later subsystem).
- Confirmed-email gating / rate-limiting / spam control / moderation queue (Moderation subsystem).
- Reaction/comment counts denormalized onto Article (compute on read for MVP; denormalize later if needed).
- Search indexing of comments.

## Definition of Done

- A signed-in user can comment on an article, reply once to a top-level comment, and (as
  author or moderator) soft-delete a comment (shows "[deleted]", replies preserved).
- A signed-in user can toggle the three reactions and a bookmark; counts and saved-state
  reflect immediately; a second open reader sees new comments / reaction changes live.
- `/library` lists the user's bookmarked articles and requires auth; nav has a `library` link.
- Comment posting requires a signed-in actor; bookmark lists are private; comment soft-delete
  is author-or-moderator only.
- All tests pass; CI green; migrations committed on `phase-1-engagement`.
