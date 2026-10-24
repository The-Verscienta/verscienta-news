# Moderation Auto-Actions — Slice 2: Shadowban

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-09
**Phase:** 3 — Intelligence & Growth › Moderation & Trust
**Todo item:** `[~] Auto-actions (hold, shadow, escalate) with audit log.`
**Slice:** 2 of 2 (SHADOW). Slice 1 (hold + escalate + audit) is on branch
`phase-3-moderation-auto-actions` / PR #23.

## Goal

Add **SHADOW** — a silent, author-only-visible shadowban — as a manual
moderator action. A shadowed comment or article is **invisible to everyone
except its author**, who continues to see it as normal and is unaware it has
been hidden (no placeholder, no "under review" notice). This completes the
"hold, shadow, escalate" todo item.

## Decisions (from brainstorming)

- **Semantics:** SHADOW is silent and author-only-visible (vs HOLD, which is a
  transparent "under review" placeholder). The author sees their content
  normally; everyone else sees nothing at all.
- **Trigger:** Manual moderator action only — NOT auto-fired from the AI verdict.
  (Auto-shadow for repeat offenders is a future follow-up.)
- **Coverage:** Comments + Articles. Room messages deferred.
- **Persistence:** Shadow is a deliberate sanction. Resolving a flag does NOT
  lift a shadow (contrast with HOLD, which `resolve/5` lifts). Only an explicit
  `:unshadow` action restores it.
- **Comment-thread filtering** lives in the load/render layer (since
  `Comment.list_for_article` runs `authorize?: false`), not as an Ash policy.
- **A non-author hitting a shadowed article's URL gets a plain 404** (the
  existing `NotFound`), not a notice — the silent shadowban behavior.

## Key insight: most of the work is already done

Slice 1 filters `moderation_status == :visible` across every global public read
(article feeds `list_published`/`list_by_category`/`list_by_group`, the search
index worker + DB fallback, recommendation candidates + comments, room messages,
sitemap, trending, following feed incl. reposts, bulk reindex, and engagement
comment counts). A new `:shadowed` value is therefore **automatically excluded
from all of them for everyone** — no per-surface changes needed. The author does
not see their own shadowed content in *global* feeds either, which is the
believable shadowban behavior (the author notices their content only at its
direct page and in their own comment threads, both of which on real platforms a
shadowbanned user still sees).

The only NEW work is the small set of places an author sees their **own** content.

## Architecture

### 1. State + primitives

- **Widen the enum** on `Engagement.Comment` and `Content.Article`:
  `moderation_status` constraint becomes `one_of: [:visible, :held, :shadowed]`
  (still a `:atom` over a `text` column; default `:visible`, `writable?: false`).
  Run `mix ash_postgres.generate_migrations` — the column is plain `text`, so this
  likely produces no DB change (one_of is app-level), but run it to keep snapshots
  in sync and apply whatever it generates.
- **System update actions** on Comment + Article (mirroring `:hold`/`:unhold`):
  ```elixir
  update :shadow do
    accept []
    require_atomic? false
    change set_attribute(:moderation_status, :shadowed)
    # Article only: change EnqueueIndex; change InvalidateFeedCache
    # Comment only: change InvalidateCounts (the existing Changes.InvalidateCounts)
  end

  update :unshadow do
    accept []
    require_atomic? false
    change set_attribute(:moderation_status, :visible)
    # Article only: change EnqueueIndex; change InvalidateFeedCache
    # Comment only: change InvalidateCounts
  end
  ```
  (Article `:shadow` must reindex/invalidate so the shadowed article drops from
  search + cached feeds, exactly like `:hold`. Comment `:shadow` must invalidate
  counts so the shadowed comment drops from the article's count, like `:hold`.)
- **`Moderation.Subject`** gains (mirroring `hold/unhold/held?`):
  ```elixir
  def shadow(:comment, id),  do: do_update(Comment, id, :shadow)
  def shadow(:article, id),  do: do_update(Article, id, :shadow)
  def shadow(_, _),          do: :ok          # :room_message/:user no-op in slice 2
  def unshadow(:comment, id), do: do_update(Comment, id, :unshadow)
  def unshadow(:article, id), do: do_update(Article, id, :unshadow)
  def unshadow(_, _),         do: :ok
  def shadowed?(:comment, id), do: status_is?(Comment, id, :shadowed)
  def shadowed?(:article, id), do: status_is?(Article, id, :shadowed)
  def shadowed?(_, _),         do: false
  ```
  Generalize the existing `status_held?/2` into a `status_is?(resource, id, status)`
  helper (or add a parallel `status_shadowed?/2`) — keep `held?/2` working.

### 2. Article — author sees it, public 404s (silent)

`Content.Article` read policy (currently `authorize_if expr(status == :published)`):

```elixir
policy action_type(:read) do
  authorize_if expr(status == :published and moderation_status != :shadowed)
  authorize_if expr(not is_nil(^actor(:id)) and author_id == ^actor(:id))
end
```

- Non-author / anonymous read of a shadowed (but published) article → first
  clause fails (`moderation_status == :shadowed`), second fails (not the author)
  → **forbidden** → `read_article/2` (which uses `authorize?: true`) returns `nil`
  → `ArticleReaderLive.mount` raises the existing `NotFound` (404). Silent.
- Author read → second clause authorizes → loads. `held?` is `false` for a
  shadowed article, so the reader renders the body **normally** (no notice). No
  reader-template change is needed.
- HELD articles are unaffected: `moderation_status == :held` ≠ `:shadowed`, so the
  first clause still authorizes public read of a held article (the reader then
  shows the Slice-1 "under review" notice). The distinction is intentional: HOLD
  is publicly visible-as-quarantined; SHADOW is publicly non-existent.
- No SEO/noindex work: crawlers are anonymous → 404, so a shadowed article is
  never indexed or exposed.

> Note: this policy governs `authorize?: true` reads (the reader page). The global
> feed reads (`list_published` etc.) run `authorize?: false` and already filter
> `== :visible`, so they're unaffected by the policy change. Verify no other
> `authorize?: true` article read in the app needs to see shadowed content
> (moderation tooling uses `Subject.*` with `authorize?: false`, so it does not).

### 3. Comments — author sees their own; others don't see it at all

`ArticleReaderLive.load_top_comments/1` loads the comment tree with
`authorize?: false` (and `replies: [:user]`). Add a viewer-aware filter applied
after load, before assigning:

```elixir
defp visible_to(comments, viewer_id) do
  comments
  |> Enum.reject(&shadowed_and_not_owned?(&1, viewer_id))
  |> Enum.map(fn c ->
    case c do
      %{replies: replies} when is_list(replies) ->
        %{c | replies: Enum.reject(replies, &shadowed_and_not_owned?(&1, viewer_id))}
      _ -> c
    end
  end)
end

defp shadowed_and_not_owned?(%{moderation_status: :shadowed, user_id: uid}, viewer_id),
  do: uid != viewer_id
defp shadowed_and_not_owned?(_, _), do: false
```

- `viewer_id` is `socket.assigns[:current_user] && socket.assigns.current_user.id`
  (anonymous → `nil` → all shadowed comments dropped).
- An owned shadowed comment is kept and rendered with its normal body — no
  placeholder. `comment_body/1` needs no `:shadowed` clause (its catch-all returns
  `c.body`; the filter does the hiding). Deleted/held clauses keep precedence.
- The single-comment refresh path (`load_top_comment/1`, used when a reply lands)
  should apply the same filter so a freshly-broadcast subtree doesn't re-introduce
  others' shadowed comments. Real-time staleness (an already-open thread not
  live-updating when a comment is shadowed) is accepted — it filters on next load.

### 4. Audit + reversibility

- Extend `Moderation.Action.action` `one_of` with `:shadow` and `:unshadow`
  (so the audit log records both; likely no DB migration — `text` column).
- `Moderation.resolve/5` / `perform_side_effect` is **unchanged** — it lifts holds
  but must not touch shadow. (Explicitly: a shadowed subject whose flag is
  dismissed stays shadowed.)

  Implementation note: `resolve/5`/`perform_side_effect` are unchanged, but
  `Subject.unhold/2` is guarded to act only when the subject is actually `:held`
  (no-op otherwise) — otherwise the `:unhold` action's unconditional
  set-to-`:visible` would clobber a shadow when a flag on shadowed content is
  resolved.

### 5. Queue UI + manual action

- `Moderation.apply_manual_action/4` gains two clauses (mod/admin guard already in
  place from Slice 1):
  ```elixir
  def apply_manual_action(:shadow, type, id, mod) -> Subject.shadow + record(:shadow)
  def apply_manual_action(:unshadow, type, id, mod) -> Subject.unshadow + record(:unshadow)
  ```
  Update the public guard's `when action in [...]` to include `:shadow, :unshadow`.
- `Moderation.pending_groups/0` gains `shadowed?: Subject.shadowed?(type, id)` per
  group (like `held?`).
- `AdminModerationLive`: add a `🕶 shadowed` badge (`:if={g.shadowed?}`) and
  `shadow` (`:if={not g.shadowed?}`) / `unshadow` (`:if={g.shadowed?}`) buttons,
  wired to the existing `apply_action/4` handler with the new action atoms.

## Testing

- **Primitives:** `Subject.shadow/unshadow` set `moderation_status`;
  `Subject.shadowed?/2` reflects it; `:user`/`:room_message` no-op.
- **Article visibility:** a shadowed published article → `read_article` returns
  `nil` for an anonymous actor and for a non-author actor (404 path), but returns
  the article for its author. A LiveView test: author can load `/articles/:slug`
  and see the body; a different logged-in user (and anon conn) get the NotFound /
  redirect.
- **Comment visibility:** in a thread with a shadowed comment, the comment's
  author sees its body; a different viewer and an anonymous viewer do not see it
  at all (not even a placeholder). Replies covered.
- **Inherited global exclusion:** a shadowed article is absent from
  `Article.list_published` read action and search-index inclusion; a shadowed
  comment is absent from the article's comment count. (Light assertions — the
  `== :visible` filters already cover these; one or two confirmations.)
- **Audit:** a manual `:shadow` writes an Action `:shadow` (`automated?: false`,
  moderator set); `:unshadow` writes `:unshadow`.
- **Resolve does not unshadow:** shadow a subject, resolve its flag with
  `:dismissed`, assert it is still shadowed.
- **Queue UI:** moderator can shadow then unshadow a flagged subject from the
  queue; the `🕶 shadowed` badge toggles.

## Out of scope

- Room-message shadow (deferred; `Subject.shadow(:room_message, _)` is a no-op in
  Slice 2).
- Auto-shadow for repeat offenders (future; shadow stays manual-only here).
- Real-time live-update of already-open threads/pages when content is shadowed
  (filtered on next load).
- Bookmarked-then-shadowed articles in a user's library (edge case; the bookmark
  loads the `:article` relationship without a moderation filter — a user who
  bookmarked someone else's now-shadowed article could still open it via the
  bookmark. Low priority; note as a known minor leak, address only if it matters).

## Files touched (summary)

- `lib/verscienta/engagement/comment.ex`, `lib/verscienta/content/article.ex` —
  widen `moderation_status` enum; `:shadow`/`:unshadow` actions; Article read
  policy.
- `lib/verscienta/moderation/subject.ex` — `shadow/2`, `unshadow/2`, `shadowed?/2`.
- `lib/verscienta/moderation/action.ex` — `:shadow`/`:unshadow` enum.
- `lib/verscienta/moderation.ex` — `apply_manual_action` clauses + guard;
  `pending_groups` `shadowed?`.
- `lib/verscienta_web/live/article_reader_live.ex` — comment `visible_to/2` filter
  in `load_top_comments`/`load_top_comment`.
- `lib/verscienta_web/live/admin_moderation_live.ex` — badge + shadow/unshadow
  buttons.
- `priv/repo/migrations/*` + snapshots (likely no-op enum widening).
- Tests across the above.
