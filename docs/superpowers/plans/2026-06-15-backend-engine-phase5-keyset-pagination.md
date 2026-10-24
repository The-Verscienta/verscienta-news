# Backend Engine Foundations — Phase 5: Keyset Pagination + LiveView Load-More — Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans (or subagent-driven-development). Steps use checkbox (`- [ ]`) syntax. TDD throughout.

**Goal:** Declare keyset pagination on the main Ash list reads and convert their LiveViews to **streams + load-more by cursor**. Meilisearch search stays offset (out of scope).

**Spec:** `docs/superpowers/specs/2026-06-13-backend-engine-foundations-design.md` §5.

**Scope (confirmed with user, 2026-06-15): FULL §5.**
- Article: `:list_published`, `:list_by_category`, `:list_by_group`
- Engagement.Bookmark: `:list_for_user`
- Notifications.Notification: `:for_recipient`
- Social activity: `global_activity`, `personal_activity`, `user_activity` (default read)
- Social trending: kept as a **capped top-N** (see Task 6 rationale — a ranking, not a chronological feed).

**Featured-sort decision (confirmed): pin featured on page 1 only.** Keyset sort is
`published_at: :desc` (+ Ash's automatic PK stable_sort). Featured-first ordering is
applied ONLY on the cached first page, by prepending a small `featured_now == true`
query. Deeper pages are pure reverse-chronological. Phoenix streams dedup by article
id, so a featured article reappearing in a later keyset page updates in place (no dup).

---

## Verified Ash 3.27.8 facts (don't re-derive)

- `pagination keyset?: true, default_limit: 20, required?: false, countable: false, max_page_size: 100`
  - `required?` **defaults to true** → MUST set `required?: false` so existing reads that
    don't pass `page:` keep returning plain lists (e.g. `IndexArticleWorker`, sitemap, digests).
  - `countable: false` avoids a COUNT(*) per page; we use `more?`, not totals.
  - Ash auto-appends the **primary key** as `stable_sort` → keyset is deterministic even when
    `published_at`/`inserted_at` ties. No need to add `id` to the sort manually.
- `Ash.read!(query, page: [limit: 20])` → `%Ash.Page.Keyset{results:, more?:, ...}`.
  Each result carries its cursor at `record.__metadata__.keyset`.
- Next page: `Ash.read!(query, page: [after: cursor, limit: 20])`.
- A keyset sort on a **calculation** (`featured_now`) is unstable (depends on `now()`); the
  read actions therefore sort by `published_at`/`inserted_at` only.

## Shared helper (Task 1 introduces, later tasks reuse)

A tiny module `Verscienta.Pagination` (or inline helpers) to extract cursor + shape:

```elixir
# %Ash.Page.Keyset{} -> %{entries: [record], cursor: term | nil, more?: boolean}
def to_page(%Ash.Page.Keyset{results: results, more?: more?}) do
  cursor = results |> List.last() |> cursor_of()
  %{entries: results, cursor: cursor, more?: more?}
end
defp cursor_of(nil), do: nil
defp cursor_of(record), do: record.__metadata__.keyset
```

LiveView pattern (all converted views):
- mount/handle_params: `page = <ctx>.feed_*(...)`; `stream(socket, :key, page.entries)`;
  `assign(:cursor, page.cursor); assign(:more?, page.more?)`.
- `handle_event("load_more", _, socket)`: fetch next page with `after: socket.assigns.cursor`,
  `stream(socket, :key, page.entries, at: -1)` (append), update `:cursor`/`:more?`.
- Render: existing `phx-update="stream"` container + a "load more" button shown when `@more?`,
  `phx-click="load_more"`. (Infinite-scroll via `phx-viewport-bottom` is a nice-to-have; button
  is the baseline.)

---

## Task 1: Article reads — keyset + featured-pinned page-1 feed functions (TDD)

Files: `lib/verscienta/content/article.ex`, `test/verscienta/content/article_pagination_test.exs` (new).

- [ ] **Step 1 (RED):** Write `article_pagination_test.exs`: seed ~25 published, ungrouped
  articles with distinct `published_at`. Assert: `feed_published(limit: 20)` returns
  `%{entries: (20 items), cursor: (non-nil), more?: true}`; a second call with
  `after: cursor, limit: 20` returns the remaining ~5 with **no id overlap** and `more?: false`.
  Assert a featured article (set `featured_until` in the future) appears **first** on page 1
  even if its `published_at` is old.
- [ ] **Step 2:** On each of `:list_published`, `:list_by_category`, `:list_by_group`:
  - change `prepare build(sort: [...])` from `[featured_now: :desc, published_at: :desc]` to
    `[published_at: :desc]`.
  - add `pagination keyset?: true, default_limit: 20, required?: false, countable: false, max_page_size: 100`.
- [ ] **Step 3:** Add cursor-aware feed functions returning `%{entries:, cursor:, more?:}`:
  - `feed_published(opts \\ [])`, `feed_by_category(category, opts \\ [])`, `feed_by_group(group_id, opts \\ [])`.
  - **Page 1** (no `opts[:after]`): cached under the existing keys/tags/TTL. Build via:
    featured query (`:list_<read>` + `Ash.Query.filter(featured_now == true)`, card fields,
    `sort: [published_at: :desc]`, small `limit`) PLUS keyset page 1
    (`page: [limit: @page_limit]`, card fields). Entries = `featured ++ Enum.reject(page.results, &(&1.id in featured_ids))`.
    cursor = last keyset cursor; more? from the page.
  - **Load-more** (`opts[:after]` present): live (NOT cached), pure keyset
    `page: [after: cursor, limit: @page_limit]`, no featured prepend. Return `to_page/1`.
  - `@page_limit 20`.
- [ ] **Step 4:** Keep back-compat list accessors: `list_published(opts \\ []) ,do: feed_published(opts).entries`
  (and the two siblings). All existing callers (bench, load_test, feed_payload_test,
  feeds_cache_test, seeder_test) keep compiling and passing (they get page-1 entries; ≤20 now).
- [ ] **Step 5 (GREEN):** pagination test green; `mix test test/verscienta/content` green
  (watch `feed_payload_test` drift guard + `feeds_cache_test`). `--warnings-as-errors`, `mix format`.
- [ ] **Commit.**

## Task 2: Article feed LiveViews → streams + load-more

Files: `lib/verscienta_web/live/article_feed_live.ex`, `category_live.ex`, `group_live.ex`.

- [ ] **Step 1:** `CategoryLive` + `GroupLive`: convert `@articles` plain assign → `stream(:articles, page.entries)`;
  store `:cursor`/`:more?`; add `load_more` handler (append) + a load-more button in render
  (replace `<.article_grid articles={@articles} />` with a streamed grid). `article_grid` currently
  takes a list — add a streamed variant or iterate `@streams.articles` directly with the card markup.
- [ ] **Step 2:** `ArticleFeedLive`: the `latest` and `trending` tabs render `@articles` via
  `article_grid`. Convert `latest` to the streamed feed + load-more (uses `feed_published`).
  `trending` stays capped (Task 6) — no load-more. `for_you`/`following` render `@items`
  (recommendation structs, separate paginate-by-limit path) — convert to streams + load-more
  using their existing `limit:`-based functions advanced by an offset/cursor (see Task 5 note;
  if recommendations lack cursors, keep "load more" by growing `limit`, or defer those two tabs
  to a tracked follow-up — DECIDE during execution, prefer growing limit if simple).
  NB: tab switches must `stream(..., reset: true)`.
- [ ] **Step 2b:** LiveView tests: mount renders page 1; `render_click` the load-more appends the
  next page (more dom ids present, no error); tab switch resets. Reuse existing live test patterns.
- [ ] **Step 3:** GREEN + `--warnings-as-errors` + format. **Commit.**

## Task 3: Bookmark `:list_for_user` keyset + LibraryLive load-more

Files: `lib/verscienta/engagement/bookmark.ex`, `lib/verscienta_web/live/library_live.ex`, tests.

- [ ] Add `pagination keyset?: true, default_limit: 20, required?: false, countable: false`
  to `:list_for_user` (sort stays `inserted_at: :desc`; PK stable sort auto-added; keep the
  `load(article: card_fields)` prepare). Add a context/wrapper that returns `to_page/1`.
- [ ] `LibraryLive`: plain `@articles`/bookmarks → `stream` + `:cursor`/`:more?` + load-more.
- [ ] Test: keyset page + next cursor no-overlap; live mount + load-more append. GREEN, format. **Commit.**

## Task 4: Notification `:for_recipient` keyset + NotificationsLive load-more

Files: `lib/verscienta/notifications/notification.ex`, `lib/verscienta/notifications.ex`,
`lib/verscienta_web/live/notifications_live.ex`, tests.

- [ ] Add keyset pagination to `:for_recipient` (sort `inserted_at: :desc`, `required?: false`,
  `countable: false`). Add `Notifications.page_for(user, opts)` returning `to_page/1`
  (keep `list_for/2` for the bell/count callers).
- [ ] `NotificationsLive` already streams — add `:cursor`/`:more?` from `page_for`, a `load_more`
  handler appending the next page, and a load-more button. The real-time `handle_info` insert-at-0
  and `mark_all_read` reset stay; `mark_all_read` re-fetches page 1.
- [ ] Test: keyset no-overlap; live load-more append; real-time insert still works. GREEN, format. **Commit.**

## Task 5: Social activity reads keyset + ActivityLive + ProfileLive load-more

Files: `lib/verscienta/social.ex` (`global_activity`, `personal_activity`, `user_activity`),
`lib/verscienta/social/activity_event.ex`, `lib/verscienta_web/live/activity_live.ex`,
`profile_live.ex`, tests.

- [ ] Add keyset pagination config to the `ActivityEvent` default read (or dedicated reads if the
  three wrappers use distinct filters — they filter by audience/user). Each wrapper grows a
  `page_*` variant returning `to_page/1`; keep `limit:` variants if other callers use them.
  Sort `inserted_at: :desc`, `required?: false`, `countable: false`.
- [ ] `ActivityLive` (global + personal) and `ProfileLive` (user activity tab) already stream —
  add `:cursor`/`:more?` + `load_more` + button. ProfileLive: only the activity tab paginates.
- [ ] Tests: keyset no-overlap per audience; live load-more append. GREEN, format. **Commit.**

## Task 6: Trending — document the cap (no keyset)

- [ ] `Social.Trending.list/1` is a **top-N ranking** off `mv_trending_articles` (score desc),
  not a chronological feed. Paginating a "trending" ranking beyond the top-N is not meaningful
  (scores churn on every refresh; a cursor would be unstable). **Decision: keep trending capped**
  at its current limit; the `trending` feed tab shows the top-N with NO load-more.
  `log()`/document this explicitly so the cap isn't mistaken for incomplete coverage.
- [ ] No code change beyond a clarifying comment in `social.ex`/`trending.ex` and this plan note.

## Task 7: Full verification + finish

- [ ] `mix test` full suite green (re-run `--seed 0` + one random seed; the pre-existing fresh-DB
  disconnect/type-cache flakes are benign — confirm any failure is unrelated).
- [ ] `mix compile --warnings-as-errors`, `mix format --check-formatted`.
- [ ] superpowers:finishing-a-development-branch.

---

## Self-Review / Risks

- **Return-type blast radius:** avoided by keeping list-returning `list_*` accessors; only the
  3 feed LiveViews adopt the new `feed_*` map API. ✅
- **Featured dup on load-more:** handled free by Phoenix stream id-dedup. ✅
- **`required?: false` is load-bearing** — without it every existing non-paginated read of these
  actions breaks. ✅
- **Cache boundary:** page 1 cached (existing TTL/tags); deeper pages live (cursor space is
  unbounded — never cache per-cursor). ✅
- **Search untouched** (Meilisearch offset). **Trending stays a capped top-N** (documented). ✅
- **Highest residual risk:** ArticleFeedLive's `for_you`/`following` tabs render recommendation
  structs (not plain article reads) — their "load more" may need a grow-limit fallback rather
  than keyset. Decide in Task 2; acceptable to defer those two tabs to a follow-up if they balloon.
