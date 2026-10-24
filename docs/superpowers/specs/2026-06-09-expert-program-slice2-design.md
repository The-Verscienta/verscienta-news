# Expert Program — Slice 2: Content Trust Signals + Featured Placement

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-09
**Phase:** 3 — Intelligence & Growth › Expert Program
**Todo items:**
- `[~] Expert badge + elevated trust signals on content/profile.` → byline tags here complete it
- `[ ] Expert-only publishing privileges / featured placement.` → featured + skip-hold here complete it
**Slice:** 2 of 2 (builds on Slice 1's `:expert` role).

## Goal

Surface expert authorship on content, give moderators a featured-placement
curation tool, and grant verified experts the publishing privilege of skipping
the AI moderation auto-hold on their articles. This completes the Expert Program.

## Decisions (from brainstorming)

- **Skip-hold:** expert-authored **articles** skip the AI auto-hold (a
  trusted-author privilege); the AI flag is still created (human review in the
  mod queue) and the article stays visible. Applies to **articles only** (expert
  comments stay fully moderated) and to the **hold** action only (**escalate**
  still fires on dubious expert articles).
- **Featured:** mod/admin-curated on **any** published article (general curation,
  not restricted to expert content), set from a control on the article reader,
  for a duration. Feeds sort currently-featured first.
- **Byline tags:** an "Expert" tag on the article-reader author byline and on
  expert commenters' author lines. Reader + comments only (feed cards deferred).
- **No new feature flag.** Everything keys off the `:expert` role (granted via
  Slice 1's `:expert_program`-gated flow). Featured is decoupled from the flag
  (a general mod tool). Once a user is `:expert`, the signals/privileges apply.

## Architecture

### 1. Expert byline tag

- New reusable function component `expert_tag/1` in
  `lib/verscienta_web/components/codex_components.ex`:
  ```elixir
  attr :class, :string, default: ""

  def expert_tag(assigns) do
    ~H"""
    <span class={[
      "inline-block bg-canvas-3 px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wider text-zune",
      @class
    ]} title="Verified expert">✦ Expert</span>
    """
  end
  ```
  (Confirm `text-zune` / accent token in `assets/css/app.css`; fall back to
  `text-ink` if absent. The literal text "Expert" must render.)
- **Article reader byline** (`ArticleReaderLive.render`, near the author `<a>`):
  add `<.expert_tag :if={@article.author && @article.author.role == :expert} />`.
  `@article.author` is loaded in mount (`Ash.load!(article, [:author, :tags,
  :source], ...)`), and loading the `belongs_to :author` loads the full `User`
  record, so `.role` is available.
- **Comment author lines** (the thread render + the reply render): add
  `<.expert_tag :if={comment.user.role == :expert} />` (and the reply variant)
  next to `@{comment.user.username}`. Comments load `[:user, replies: [:user]]`,
  so `comment.user.role` / `reply.user.role` are available.
- Pure role-driven display; no flag gate.

### 2. Featured placement

- **Article attribute:** add to `Content.Article`:
  ```elixir
  attribute :featured_until, :utc_datetime_usec, allow_nil?: true, public?: true
  ```
- **Action:** mirror `Comment.:set_featured_until`:
  ```elixir
  update :set_featured_until do
    description "Moderator action: feature/unfeature an article (sets featured_until)."
    accept [:featured_until]
    require_atomic? false
    change Verscienta.Content.Article.Changes.InvalidateFeedCache
  end
  ```
  Policy: `policy action(:set_featured_until) do authorize_if expr(^actor(:role)
  in [:moderator, :admin]) end`.
  (`InvalidateFeedCache` busts the cached feeds so the new ordering takes effect.)
- **Calculation** (currently-featured, ignoring expired):
  ```elixir
  calculate :featured_now, :boolean, expr(not is_nil(featured_until) and featured_until > now())
  ```
  (`now()` is an Ash expression backed by Postgres `now()`.)
- **Feed sort:** change the `prepare build(sort: [published_at: :desc])` in
  `:list_published`, `:list_by_group`, and `:list_by_category` to:
  ```elixir
  prepare build(sort: [featured_now: :desc, published_at: :desc])
  ```
  Currently-featured articles sort first (then newest); an expired
  `featured_until` evaluates `featured_now == false`, so it falls back to date
  order. (Sorting by an expr calculation is supported by AshPostgres.)
  **Performance note (recorded decision):** `featured_now` is a volatile
  expression (`featured_until > now()`), so this primary sort key cannot be
  index-backed — the feeds do a scan + sort. This is acceptable because the
  feed reads are fronted by `Verscienta.Cache.fetch` (60s TTL), so the cost is
  bounded. If feed tables grow large, revisit (e.g. a partial index
  `articles(published_at DESC) WHERE featured_until IS NULL` + a separate
  hot-featured query, or a materialized boolean refreshed on a schedule).
- **Reader mod control** (`ArticleReaderLive`):
  - assign `featured?: article.featured_now` (load the calc) and gate a small
    "★ Featured" indicator on it.
  - For mod/admin (`@current_user && @current_user.role in [:moderator,
    :admin]`), show a **feature** button (when not featured) and **unfeature**
    button (when featured).
  - `handle_event("feature", ...)` → `:set_featured_until` with
    `featured_until: DateTime.add(now, 14, :day)`; `handle_event("unfeature",
    ...)` → `featured_until: nil`; both with `actor: current_user`, then reload
    the article (refresh `featured?`) + flash.
  - The article load in mount must include the `featured_now` calc and
    `featured_until` (load `[:featured_now]` alongside author/tags/source).

### 3. Experts' articles skip the AI auto-hold

In `lib/verscienta/moderation/workers/auto_moderate_worker.ex`:
- `maybe_flag/3` is unchanged — the AI flag is still created (so the subject
  still lands in the mod queue for human review).
- Split `enforce(:hold, ...)` so an expert-authored article skips the hold:
  ```elixir
  defp enforce(:hold, :article, id, verdict) do
    if expert_authored_article?(id) do
      :ok
    else
      Subject.hold(:article, id)
      Moderation.record_auto_action(:hold, :article, id, note: note(verdict))
    end
  end

  defp enforce(:hold, type, id, verdict) do
    Subject.hold(type, id)
    Moderation.record_auto_action(:hold, type, id, note: note(verdict))
  end

  defp enforce(:escalate, type, id, verdict) do
    Moderation.escalate(type, id)
    Moderation.record_auto_action(:escalate, type, id, note: note(verdict))
  end

  defp expert_authored_article?(id) do
    case Subject.snapshot(:article, id) do
      {_excerpt, author_id} when not is_nil(author_id) ->
        case Ash.get(Verscienta.Accounts.User, author_id, authorize?: false) do
          {:ok, %{role: :expert}} -> true
          _ -> false
        end

      _ ->
        false
    end
  end
  ```
- Only the article HOLD is skipped: expert comments still hold, and dubious
  expert articles still escalate (visible + queue priority). The change is fully
  contained in the worker; `maybe_enforce`'s rescue still wraps it best-effort.

## Testing

- **expert_tag:** `render_component(&expert_tag/1, %{})` contains "Expert".
- **Reader byline:** an article by an `:expert` author renders the tag; by a
  `:user` author it doesn't.
- **Comment byline:** a thread containing an `:expert` commenter renders the tag
  on that comment; a `:user` commenter's line doesn't.
- **set_featured_until:** a mod sets `featured_until`; a non-mod is rejected
  (policy). Unfeature sets it to nil.
- **Feed sort:** with a currently-featured article + a newer non-featured one,
  `Ash.read!(:list_published)` returns the featured one first; an
  expired-`featured_until` article sorts by date (not first).
- **Reader control:** a mod sees feature/unfeature buttons and clicking feature
  sets `featured_until` (article reloads showing the indicator); a non-mod /
  anon doesn't see the buttons.
- **Skip-hold worker:** with `:auto_moderation` + `:auto_enforcement` on and a
  toxic verdict, an article authored by an `:expert` is NOT held
  (`moderation_status` stays `:visible`) but an AI flag still exists; a
  non-expert author's article IS held; an `:expert` author's toxic **comment**
  IS held (skip is article-only). A dubious expert article is still escalated.

## Out of scope (later)

- Expert tags on feed/listing cards (`news_card` renders no author today).
- Auto-featuring, an admin featuring dashboard, per-category featured slots,
  featured analytics.
- Skipping escalate for experts (escalate keeps content visible; review is fine).

## Files touched (summary)

- `lib/verscienta_web/components/codex_components.ex` — `expert_tag/1`.
- `lib/verscienta_web/live/article_reader_live.ex` — byline + comment tags;
  featured indicator + mod feature/unfeature control + handlers; load `featured_now`.
- `lib/verscienta/content/article.ex` — `featured_until` attribute,
  `:set_featured_until` action + policy, `featured_now` calc, feed-read sorts.
- `lib/verscienta/moderation/workers/auto_moderate_worker.ex` — expert-article
  skip-hold.
- New migration: `articles.featured_until`.
- Tests across the above.
