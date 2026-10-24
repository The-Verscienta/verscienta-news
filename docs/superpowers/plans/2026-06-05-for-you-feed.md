# For You Feed Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-user "For You" feed tab that ranks recent articles by a blend of explicit interests, inferred engagement affinity, social proof, freshness, and a global-quality prior — computed on-read with per-user caching.

**Architecture:** A new plain context module `Verscienta.Recommendations` composed of a pure `Scorer`, a cached `AffinityProfile`, a `Candidates` query, and a `for_you/2` orchestrator. The feed LiveView gains a `for_you` tab (default for logged-in users). No new deps, no pgvector, no Oban workers.

**Tech Stack:** Elixir, Phoenix LiveView, Ash 3 / AshPostgres, `Verscienta.Cache` (ETS+Redis), Benchee (load-test harness). All `mix` runs in Docker: `docker compose exec -T app mix …`.

**Spec:** `docs/superpowers/specs/2026-06-05-for-you-feed-design.md`

**Branch:** `phase-3-for-you-feed` (already created; the spec commit is its first commit).

---

## File Structure

**Create:**
- `lib/verscienta/recommendations/scorer.ex` — pure scoring (`score/5`, `default_weights/0`).
- `lib/verscienta/recommendations/affinity_profile.ex` — `for_user/1` (cached) + pure `build/4`.
- `lib/verscienta/recommendations/candidates.ex` — `recent/2`, `engaged_article_ids/1`.
- `lib/verscienta/recommendations.ex` — `for_you/2`, `personalized?/1` (orchestrator + caching).
- `test/verscienta/recommendations/scorer_test.exs`
- `test/verscienta/recommendations/affinity_profile_test.exs`
- `test/verscienta/recommendations/candidates_test.exs`
- `test/verscienta/recommendations/for_you_test.exs`
- `test/verscienta_web/live/for_you_feed_test.exs`

**Modify:**
- `lib/verscienta_web/live/article_feed_live.ex` — `for_you` tab, default-tab logic, nudge.
- `lib/verscienta/load_test/seeder.ex` — designate a personalized fixture user; record `personalized_user_id`.
- `lib/verscienta/load_test/scenarios.ex` — add the `for_you` cached-read scenario.
- `docs/todo.md` — check off the For You item.

---

## Task 1: Scorer (pure scoring)

**Files:**
- Create: `lib/verscienta/recommendations/scorer.ex`
- Test: `test/verscienta/recommendations/scorer_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/recommendations/scorer_test.exs`:

```elixir
defmodule Verscienta.Recommendations.ScorerTest do
  use ExUnit.Case, async: true

  alias Verscienta.Recommendations.Scorer

  @now ~U[2026-06-05 12:00:00Z]

  defp profile(opts \\ []) do
    %{
      followed_categories: Keyword.get(opts, :followed_categories, MapSet.new()),
      followed_tag_ids: Keyword.get(opts, :followed_tag_ids, MapSet.new()),
      category_affinity: Keyword.get(opts, :category_affinity, %{}),
      tag_affinity: Keyword.get(opts, :tag_affinity, %{})
    }
  end

  defp candidate(opts \\ []) do
    %{
      category: Keyword.get(opts, :category, :nutrition),
      tag_ids: Keyword.get(opts, :tag_ids, []),
      published_at: Keyword.get(opts, :published_at, @now),
      quality: Keyword.get(opts, :quality, 0.0)
    }
  end

  test "default_weights/0 exposes the five tunable weights" do
    w = Scorer.default_weights()
    assert w.explicit == 3.0
    assert w.affinity == 2.0
    assert w.social == 2.0
    assert w.freshness == 1.5
    assert w.quality == 0.5
  end

  test "an explicitly-followed category scores higher than an unfollowed one" do
    p = profile(followed_categories: MapSet.new([:nutrition]))
    followed = Scorer.score(candidate(category: :nutrition), p, 0, Scorer.default_weights(), @now)
    other = Scorer.score(candidate(category: :tcm), p, 0, Scorer.default_weights(), @now)
    assert followed > other
  end

  test "affinity and social proof each increase the score" do
    base = Scorer.score(candidate(), profile(), 0, Scorer.default_weights(), @now)
    with_affinity = Scorer.score(candidate(), profile(category_affinity: %{nutrition: 1.0}), 0, Scorer.default_weights(), @now)
    with_social = Scorer.score(candidate(), profile(), 5, Scorer.default_weights(), @now)
    assert with_affinity > base
    assert with_social > base
  end

  test "freshness decays with age (newer outranks older, all else equal)" do
    fresh = candidate(published_at: @now)
    old = candidate(published_at: DateTime.add(@now, -20 * 86_400, :second))
    assert Scorer.score(fresh, profile(), 0, Scorer.default_weights(), @now) >
             Scorer.score(old, profile(), 0, Scorer.default_weights(), @now)
  end

  test "a fully-relevant candidate outranks an unrelated fresh one" do
    p =
      profile(
        followed_categories: MapSet.new([:nutrition]),
        followed_tag_ids: MapSet.new(["t1"]),
        category_affinity: %{nutrition: 1.0},
        tag_affinity: %{"t1" => 1.0}
      )

    relevant = candidate(category: :nutrition, tag_ids: ["t1"], quality: 1.0)
    unrelated = candidate(category: :tcm, tag_ids: ["t9"], published_at: @now)
    assert Scorer.score(relevant, p, 3, Scorer.default_weights(), @now) >
             Scorer.score(unrelated, p, 0, Scorer.default_weights(), @now)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec -T app mix test test/verscienta/recommendations/scorer_test.exs`
Expected: FAIL — `Verscienta.Recommendations.Scorer` is undefined.

- [ ] **Step 3: Write the implementation**

Create `lib/verscienta/recommendations/scorer.ex`:

```elixir
defmodule Verscienta.Recommendations.Scorer do
  @moduledoc """
  Pure scoring for the For You feed. No DB, no cache — fully deterministic.

  A candidate's score blends explicit interest, inferred affinity, social proof,
  freshness, and a small global-quality prior, each with a tunable weight.
  """

  @default_weights %{explicit: 3.0, affinity: 2.0, social: 2.0, freshness: 1.5, quality: 0.5}
  @freshness_half_life_days 5

  @doc "The tunable scoring weights."
  def default_weights, do: @default_weights

  @doc """
  Score `candidate` for the viewer described by `profile`.

    * candidate — `%{category: atom, tag_ids: [id], published_at: DateTime, quality: float}`
    * profile   — `%{followed_categories: MapSet, followed_tag_ids: MapSet,
                     category_affinity: %{cat => float}, tag_affinity: %{id => float}}`
    * social_count — distinct followed users who engaged with the candidate
    * weights — see `default_weights/0`
    * now — reference time for freshness decay
  """
  def score(candidate, profile, social_count, weights, now) do
    weights.explicit * explicit(candidate, profile) +
      weights.affinity * affinity(candidate, profile) +
      weights.social * social_count +
      weights.freshness * freshness(candidate, now) +
      weights.quality * (candidate.quality || 0.0)
  end

  defp explicit(c, p) do
    cat = if MapSet.member?(p.followed_categories, c.category), do: 1.0, else: 0.0
    tags = Enum.count(c.tag_ids, &MapSet.member?(p.followed_tag_ids, &1)) * 1.0
    cat + tags
  end

  defp affinity(c, p) do
    cat = Map.get(p.category_affinity, c.category, 0.0)
    tags = Enum.reduce(c.tag_ids, 0.0, fn t, acc -> acc + Map.get(p.tag_affinity, t, 0.0) end)
    cat + tags
  end

  defp freshness(c, now) do
    age_days = DateTime.diff(now, c.published_at, :second) / 86_400
    :math.pow(2, -age_days / @freshness_half_life_days)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose exec -T app mix test test/verscienta/recommendations/scorer_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta/recommendations/scorer.ex test/verscienta/recommendations/scorer_test.exs
git commit -m "feat(recommendations): pure For You scorer"
```

---

## Task 2: AffinityProfile (pure build + cached for_user)

**Files:**
- Create: `lib/verscienta/recommendations/affinity_profile.ex`
- Test: `test/verscienta/recommendations/affinity_profile_test.exs`

- [ ] **Step 1: Write the failing test** (pure `build/4` only — no DB)

Create `test/verscienta/recommendations/affinity_profile_test.exs`:

```elixir
defmodule Verscienta.Recommendations.AffinityProfileTest do
  use ExUnit.Case, async: true

  alias Verscienta.Recommendations.AffinityProfile

  @now ~U[2026-06-05 12:00:00Z]

  # article_index: %{article_id => %{category:, tag_ids: []}}
  @index %{
    "a1" => %{category: :nutrition, tag_ids: ["t1"]},
    "a2" => %{category: :herbalism, tag_ids: ["t2"]}
  }

  defp eng(article_id, type, at), do: %{article_id: article_id, type: type, at: at}

  test "build/4 derives followed sets from follows" do
    follows = %{user: [], category: ["nutrition"], source: [], tag: ["t1"]}
    p = AffinityProfile.build([], follows, @index, @now)

    assert p.followed_categories == MapSet.new([:nutrition])
    assert p.followed_tag_ids == MapSet.new(["t1"])
  end

  test "build/4 accumulates normalized affinity weighted by engagement type" do
    follows = %{user: [], category: [], source: [], tag: []}
    # a bookmark (weight 1.0) on a1 vs a reaction (weight 0.5) on a2, same day
    engagements = [eng("a1", :bookmark, @now), eng("a2", :reaction, @now)]
    p = AffinityProfile.build(engagements, follows, @index, @now)

    # normalized to the max (the bookmark), so nutrition == 1.0, herbalism == 0.5
    assert p.category_affinity[:nutrition] == 1.0
    assert_in_delta p.category_affinity[:herbalism], 0.5, 0.001
    assert p.tag_affinity["t1"] == 1.0
  end

  test "build/4 decays older engagement (recent outweighs old for the same type)" do
    follows = %{user: [], category: [], source: [], tag: []}
    recent = [eng("a1", :reaction, @now)]
    old = [eng("a2", :reaction, DateTime.add(@now, -60 * 86_400, :second))]
    p = AffinityProfile.build(recent ++ old, follows, @index, @now)

    assert p.category_affinity[:nutrition] > p.category_affinity[:herbalism]
  end

  test "build/4 ignores engagements for unknown articles" do
    follows = %{user: [], category: [], source: [], tag: []}
    p = AffinityProfile.build([eng("missing", :bookmark, @now)], follows, @index, @now)
    assert p.category_affinity == %{}
    assert p.tag_affinity == %{}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec -T app mix test test/verscienta/recommendations/affinity_profile_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Write the implementation**

Create `lib/verscienta/recommendations/affinity_profile.ex`:

```elixir
defmodule Verscienta.Recommendations.AffinityProfile do
  @moduledoc """
  The viewer's interest profile: explicit follows + inferred per-category/tag
  affinity learned from their engagement history. `for_user/1` is cached (the
  profile changes slowly); `build/4` is the pure core.
  """

  require Ash.Query

  alias Verscienta.Cache
  alias Verscienta.Content.Article
  alias Verscienta.Engagement.{Bookmark, Comment, Reaction}
  alias Verscienta.Gamification.GamificationEvent
  alias Verscienta.Social
  alias Verscienta.Social.Repost

  @type_weights %{bookmark: 1.0, repost: 1.0, comment: 0.7, reaction: 0.5, reading: 0.3}
  @half_life_days 30
  @ttl_ms 3_600_000

  @doc "Cached interest profile for `user` (a struct/map with `:id`)."
  def for_user(user) do
    key = "for_you:affinity:user:#{user.id}"

    {:ok, profile} =
      Cache.fetch(key, [ttl: @ttl_ms, tags: ["user:#{user.id}:for_you"]], fn ->
        {:ok, compute(user)}
      end)

    profile
  end

  defp compute(user) do
    follows = Social.follows_by_type(user.id)
    engagements = gather_engagements(user.id)
    ids = engagements |> Enum.map(& &1.article_id) |> Enum.uniq()
    build(engagements, follows, load_article_index(ids), DateTime.utc_now())
  end

  @doc """
  Pure builder. `engagements` is a list of `%{article_id, type, at}`;
  `article_index` is `%{article_id => %{category:, tag_ids: []}}`.
  """
  def build(engagements, follows, article_index, now) do
    {cat, tag} =
      Enum.reduce(engagements, {%{}, %{}}, fn e, {ca, ta} ->
        case Map.get(article_index, e.article_id) do
          nil ->
            {ca, ta}

          %{category: category, tag_ids: tag_ids} ->
            w = type_weight(e.type) * decay(e.at, now)
            ca = Map.update(ca, category, w, &(&1 + w))
            ta = Enum.reduce(tag_ids, ta, fn t, acc -> Map.update(acc, t, w, &(&1 + w)) end)
            {ca, ta}
        end
      end)

    %{
      followed_categories: to_category_set(follows[:category] || []),
      followed_tag_ids: MapSet.new(follows[:tag] || []),
      category_affinity: normalize(cat),
      tag_affinity: normalize(tag)
    }
  end

  defp to_category_set(values) do
    values
    |> Enum.map(fn v -> safe_atom(v) end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp safe_atom(v) when is_atom(v), do: v
  defp safe_atom(v) when is_binary(v) do
    String.to_existing_atom(v)
  rescue
    ArgumentError -> nil
  end

  defp type_weight(t), do: Map.get(@type_weights, t, 0.0)

  defp decay(at, now) do
    age_days = DateTime.diff(now, at, :second) / 86_400
    :math.pow(2, -age_days / @half_life_days)
  end

  defp normalize(m) when map_size(m) == 0, do: %{}

  defp normalize(m) do
    max = m |> Map.values() |> Enum.max()
    if max <= 0, do: m, else: Map.new(m, fn {k, v} -> {k, v / max} end)
  end

  defp gather_engagements(uid) do
    reactions =
      Reaction
      |> Ash.Query.filter(user_id == ^uid)
      |> Ash.read!(authorize?: false)
      |> Enum.map(&%{article_id: &1.article_id, type: :reaction, at: &1.inserted_at})

    bookmarks =
      Bookmark
      |> Ash.Query.filter(user_id == ^uid)
      |> Ash.read!(authorize?: false)
      |> Enum.map(&%{article_id: &1.article_id, type: :bookmark, at: &1.inserted_at})

    comments =
      Comment
      |> Ash.Query.filter(user_id == ^uid and is_nil(deleted_at))
      |> Ash.read!(authorize?: false)
      |> Enum.map(&%{article_id: &1.article_id, type: :comment, at: &1.inserted_at})

    reposts =
      Repost
      |> Ash.Query.filter(user_id == ^uid)
      |> Ash.read!(authorize?: false)
      |> Enum.map(&%{article_id: &1.article_id, type: :repost, at: &1.inserted_at})

    reading =
      GamificationEvent
      |> Ash.Query.filter(user_id == ^uid and kind == :reading and subject_type == :article)
      |> Ash.read!(authorize?: false)
      |> Enum.map(&%{article_id: &1.subject_id, type: :reading, at: &1.occurred_at})

    reactions ++ bookmarks ++ comments ++ reposts ++ reading
  end

  defp load_article_index([]), do: %{}

  defp load_article_index(ids) do
    Article
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.load(:tags)
    |> Ash.read!(authorize?: false)
    |> Map.new(fn a -> {a.id, %{category: a.category, tag_ids: Enum.map(a.tags, & &1.id)}} end)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose exec -T app mix test test/verscienta/recommendations/affinity_profile_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta/recommendations/affinity_profile.ex test/verscienta/recommendations/affinity_profile_test.exs
git commit -m "feat(recommendations): cached affinity profile"
```

---

## Task 3: Candidates (eligible-article query)

**Files:**
- Create: `lib/verscienta/recommendations/candidates.ex`
- Test: `test/verscienta/recommendations/candidates_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/recommendations/candidates_test.exs`:

```elixir
defmodule Verscienta.Recommendations.CandidatesTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Content.Article
  alias Verscienta.Recommendations.Candidates

  defp user(name) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com",
      username: name,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp published(author, title) do
    Article
    |> Ash.Changeset.for_create(:create, %{title: title, excerpt: "e", category: :nutrition},
      actor: author
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(:publish, %{}, actor: author)
    |> Ash.update!()
  end

  test "returns recent published articles, excluding the viewer's own" do
    me = user("candme")
    author = user("candauthor")
    mine = published(me, "My Own")
    theirs = published(author, "Someone Else")

    ids = Candidates.recent(me) |> Enum.map(& &1.id)
    assert theirs.id in ids
    refute mine.id in ids
  end

  test "excludes articles the viewer has already engaged with" do
    me = user("cme2")
    author = user("cauth2")
    seen = published(author, "Already Bookmarked")
    fresh = published(author, "Not Yet Seen")

    Verscienta.Engagement.Bookmark
    |> Ash.ActionInput.for_action(:toggle, %{article_id: seen.id}, actor: me)
    |> Ash.run_action!()

    ids = Candidates.recent(me) |> Enum.map(& &1.id)
    assert fresh.id in ids
    refute seen.id in ids
  end

  test "excludes drafts and group articles" do
    me = user("cme3")
    author = user("cauth3")
    pub = published(author, "Public")

    {:ok, _draft} =
      Article
      |> Ash.Changeset.for_create(:create, %{title: "Draft", excerpt: "e", category: :nutrition},
        actor: author
      )
      |> Ash.create()

    ids = Candidates.recent(me) |> Enum.map(& &1.id)
    assert pub.id in ids
    assert length(ids) == 1
  end

  test "excludes articles from deactivated or anonymized authors" do
    me = user("cme4")
    author = user("cauth4")
    hidden = published(author, "By Deactivated Author")

    # Deactivate the author (set deactivated_at directly, like AuthHelpers.confirm!).
    Ecto.Adapters.SQL.query!(
      Verscienta.Repo,
      "UPDATE users SET deactivated_at = NOW() WHERE id = $1",
      [Ecto.UUID.dump!(author.id)]
    )

    refute hidden.id in (Candidates.recent(me) |> Enum.map(& &1.id))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec -T app mix test test/verscienta/recommendations/candidates_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Write the implementation**

Create `lib/verscienta/recommendations/candidates.ex`:

```elixir
defmodule Verscienta.Recommendations.Candidates do
  @moduledoc """
  The eligible-article pool for the For You feed: recent, published, non-group
  articles minus the viewer's own and anything they've already engaged with.
  """

  require Ash.Query

  alias Verscienta.Content.Article
  alias Verscienta.Engagement.{Bookmark, Comment, Reaction}
  alias Verscienta.Gamification.GamificationEvent
  alias Verscienta.Social.Repost

  @window_days 30
  @pool 500

  @doc "Recent eligible candidates for `user` (a struct/map with `:id`), with tags loaded."
  def recent(user, opts \\ []) do
    window_days = Keyword.get(opts, :window_days, @window_days)
    pool = Keyword.get(opts, :pool, @pool)
    cutoff = DateTime.add(DateTime.utc_now(), -window_days * 86_400, :second)
    excluded = MapSet.new(engaged_article_ids(user.id))

    Article
    |> Ash.Query.filter(
      status == :published and is_nil(group_id) and published_at >= ^cutoff and
        author_id != ^user.id and is_nil(author.deactivated_at) and is_nil(author.anonymized_at)
    )
    |> Ash.Query.sort(published_at: :desc)
    |> Ash.Query.limit(pool)
    |> Ash.Query.load(:tags)
    |> Ash.read!(authorize?: false)
    |> Enum.reject(&MapSet.member?(excluded, &1.id))
  end

  @doc "All article ids the user has engaged with (reaction/bookmark/comment/repost/reading)."
  def engaged_article_ids(user_id) do
    by(Reaction, user_id, & &1.article_id) ++
      by(Bookmark, user_id, & &1.article_id) ++
      comments(user_id) ++
      by(Repost, user_id, & &1.article_id) ++
      reading(user_id)
  end

  defp by(resource, user_id, getter) do
    resource
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(getter)
  end

  defp comments(user_id) do
    Comment
    |> Ash.Query.filter(user_id == ^user_id and is_nil(deleted_at))
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.article_id)
  end

  defp reading(user_id) do
    GamificationEvent
    |> Ash.Query.filter(user_id == ^user_id and kind == :reading and subject_type == :article)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.subject_id)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose exec -T app mix test test/verscienta/recommendations/candidates_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta/recommendations/candidates.ex test/verscienta/recommendations/candidates_test.exs
git commit -m "feat(recommendations): candidate query with discovery exclusions"
```

---

## Task 4: Recommendations orchestrator (`for_you/2`, `personalized?/1`)

**Files:**
- Create: `lib/verscienta/recommendations.ex`
- Test: `test/verscienta/recommendations/for_you_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/recommendations/for_you_test.exs`:

```elixir
defmodule Verscienta.Recommendations.ForYouTest do
  use Verscienta.DataCase, async: false

  alias Verscienta.Cache
  alias Verscienta.Content.Article
  alias Verscienta.Recommendations

  defp user(name) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com",
      username: name,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp published(author, title, category) do
    Article
    |> Ash.Changeset.for_create(:create, %{title: title, excerpt: "e", category: category},
      actor: author
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(:publish, %{}, actor: author)
    |> Ash.update!()
  end

  defp follow_category!(user, category) do
    Verscienta.Social.Follow
    |> Ash.ActionInput.for_action(:toggle, %{target_type: :category, target_id: category},
      actor: user
    )
    |> Ash.run_action!()
  end

  test "ranks an article in a followed category above an unrelated one" do
    me = user("fy1")
    author = user("fy1a")
    follow_category!(me, "nutrition")

    relevant = published(author, "Nutrition Piece", :nutrition)
    _unrelated = published(author, "TCM Piece", :tcm)

    items = Recommendations.for_you(me, limit: 10)
    titles = Enum.map(items, & &1.article.title)

    assert hd(titles) == "Nutrition Piece"
    assert Enum.all?(items, &(&1.type == :article))
    assert relevant.id == hd(items).article.id
  end

  test "excludes the viewer's own and already-seen articles" do
    me = user("fy2")
    author = user("fy2a")
    own = published(me, "My Article", :nutrition)
    _other = published(author, "Their Article", :nutrition)

    ids = Recommendations.for_you(me, limit: 10) |> Enum.map(& &1.article.id)
    refute own.id in ids
  end

  test "a zero-signal user gets a Trending-backfilled, non-empty feed" do
    me = user("fy3")
    author = user("fy3a")
    published(author, "Popular Piece", :movement)

    items = Recommendations.for_you(me, limit: 10)
    assert items != []
    assert Enum.all?(items, &(&1.type == :article))
  end

  test "personalized?/1 reflects whether the user has interest signal" do
    plain = user("fy4")
    keen = user("fy4b")
    follow_category!(keen, "herbalism")

    refute Recommendations.personalized?(plain)
    assert Recommendations.personalized?(keen)
  end

  test "caches the result until the for_you tag is invalidated" do
    me = user("fy5")
    author = user("fy5a")
    follow_category!(me, "nutrition")
    published(author, "First", :nutrition)

    r1 = Recommendations.for_you(me, limit: 10)
    # a new article does not appear until the cache is invalidated
    published(author, "Second", :nutrition)
    assert Recommendations.for_you(me, limit: 10) == r1

    Cache.invalidate_tag("for_you")
    r3 = Recommendations.for_you(me, limit: 10)
    assert "Second" in Enum.map(r3, & &1.article.title)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec -T app mix test test/verscienta/recommendations/for_you_test.exs`
Expected: FAIL — `Verscienta.Recommendations` undefined.

- [ ] **Step 3: Write the implementation**

Create `lib/verscienta/recommendations.ex`:

```elixir
defmodule Verscienta.Recommendations do
  @moduledoc """
  The "For You" feed: a per-user ranking of recent articles by explicit
  interest, inferred affinity, social proof, freshness, and a global-quality
  prior. Computed on-read with per-user caching; Trending-backfilled when
  personalized signal is thin. No embeddings (slice 2).
  """

  require Ash.Query

  alias Verscienta.Cache
  alias Verscienta.Engagement.{Bookmark, Comment, Reaction}
  alias Verscienta.Recommendations.{AffinityProfile, Candidates, Scorer}
  alias Verscienta.Social
  alias Verscienta.Social.Repost

  @weights Scorer.default_weights()
  @diversity_cap 0.40
  @ttl_ms 120_000

  @doc "Ranked For You feed items for `user`. `opts[:limit]` defaults to 30."
  def for_you(user, opts \\ []) do
    limit = Keyword.get(opts, :limit, 30)
    key = "for_you:user:#{user.id}:limit=#{limit}"

    {:ok, items} =
      Cache.fetch(key, [ttl: @ttl_ms, tags: ["for_you", "user:#{user.id}:for_you"]], fn ->
        {:ok, compute(user, limit)}
      end)

    items
  end

  @doc "Whether the user has any explicit or inferred interest signal."
  def personalized?(user) do
    p = AffinityProfile.for_user(user)

    MapSet.size(p.followed_categories) > 0 or MapSet.size(p.followed_tag_ids) > 0 or
      map_size(p.category_affinity) > 0 or map_size(p.tag_affinity) > 0
  end

  defp compute(user, limit) do
    profile = AffinityProfile.for_user(user)
    candidates = Candidates.recent(user)
    social = social_proof_counts(user, candidates)
    quality = quality_scores(candidates)
    now = DateTime.utc_now()

    ranked =
      Enum.sort_by(
        candidates,
        fn c ->
          cand = %{
            category: c.category,
            tag_ids: Enum.map(c.tags, & &1.id),
            published_at: c.published_at || c.inserted_at,
            quality: Map.get(quality, c.id, 0.0)
          }

          Scorer.score(cand, profile, Map.get(social, c.id, 0), @weights, now)
        end,
        :desc
      )

    personalized =
      ranked
      |> diversity_cap(limit)
      |> Enum.take(limit)
      |> Enum.map(&to_item/1)

    backfill(personalized, user, limit)
  end

  # --- Social proof: distinct followed users who engaged with each candidate ---
  defp social_proof_counts(user, candidates) do
    followed = Social.followed_user_ids(user.id)
    cand_ids = Enum.map(candidates, & &1.id)

    if followed == [] or cand_ids == [] do
      %{}
    else
      [Reaction, Bookmark, Repost]
      |> Enum.flat_map(&engaged_pairs(&1, cand_ids, followed))
      |> Kernel.++(comment_pairs(cand_ids, followed))
      |> Enum.uniq()
      |> Enum.frequencies_by(fn {aid, _uid} -> aid end)
    end
  end

  defp engaged_pairs(resource, cand_ids, followed) do
    resource
    |> Ash.Query.filter(article_id in ^cand_ids and user_id in ^followed)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&{&1.article_id, &1.user_id})
  end

  defp comment_pairs(cand_ids, followed) do
    Comment
    |> Ash.Query.filter(article_id in ^cand_ids and user_id in ^followed and is_nil(deleted_at))
    |> Ash.read!(authorize?: false)
    |> Enum.map(&{&1.article_id, &1.user_id})
  end

  # --- Global-quality prior: normalized recent engagement on the candidate set ---
  defp quality_scores(candidates) do
    cand_ids = Enum.map(candidates, & &1.id)

    if cand_ids == [] do
      %{}
    else
      reactions = freq(Reaction, cand_ids)
      comments = freq_comments(cand_ids)
      raw = Map.new(cand_ids, fn id -> {id, Map.get(reactions, id, 0) + 2 * Map.get(comments, id, 0)} end)
      max = raw |> Map.values() |> Enum.max(fn -> 0 end)
      if max <= 0, do: %{}, else: Map.new(raw, fn {id, v} -> {id, v / max} end)
    end
  end

  defp freq(resource, cand_ids) do
    resource
    |> Ash.Query.filter(article_id in ^cand_ids)
    |> Ash.read!(authorize?: false)
    |> Enum.frequencies_by(& &1.article_id)
  end

  defp freq_comments(cand_ids) do
    Comment
    |> Ash.Query.filter(article_id in ^cand_ids and is_nil(deleted_at))
    |> Ash.read!(authorize?: false)
    |> Enum.frequencies_by(& &1.article_id)
  end

  # --- Diversity: cap any one category to ~40% of the page (overflow deferred) ---
  defp diversity_cap(ranked, limit) do
    cap = max(1, trunc(limit * @diversity_cap))

    {kept, deferred, _counts} =
      Enum.reduce(ranked, {[], [], %{}}, fn art, {keep, defer, counts} ->
        n = Map.get(counts, art.category, 0)

        if n < cap do
          {[art | keep], defer, Map.put(counts, art.category, n + 1)}
        else
          {keep, [art | defer], counts}
        end
      end)

    Enum.reverse(kept) ++ Enum.reverse(deferred)
  end

  # --- Backfill from Trending so the page is always full ---
  defp backfill(items, _user, limit) when length(items) >= limit, do: items

  defp backfill(items, user, limit) do
    present = MapSet.new(items, & &1.article.id)

    extra =
      Social.trending(limit: limit)
      |> Enum.reject(&(MapSet.member?(present, &1.id) or &1.author_id == user.id))
      |> Enum.map(&to_item/1)

    Enum.take(items ++ extra, limit)
  end

  defp to_item(article) do
    %{type: :article, article: article, repost: nil, timestamp: article.published_at || article.inserted_at}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose exec -T app mix test test/verscienta/recommendations/for_you_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Run the whole new suite + verify gates**

Run: `docker compose exec -T app mix test test/verscienta/recommendations/`
Expected: PASS (17 tests).
Run: `docker compose exec -T app bash -lc 'mix format && mix credo --strict'`
Expected: format clean; credo "found no issues".

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta/recommendations.ex test/verscienta/recommendations/for_you_test.exs
git commit -m "feat(recommendations): For You orchestrator with social proof, diversity cap, backfill"
```

---

## Task 5: Feed LiveView integration (`for_you` tab)

**Files:**
- Modify: `lib/verscienta_web/live/article_feed_live.ex`
- Test: `test/verscienta_web/live/for_you_feed_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/for_you_feed_test.exs`:

```elixir
defmodule VerscientaWeb.ForYouFeedTest do
  use VerscientaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AshAuthentication.Plug.Helpers
  alias Verscienta.Content.Article

  defp user(name) do
    u =
      Verscienta.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: name <> "@example.com",
        username: name,
        password: "password123",
        password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    Verscienta.Support.AuthHelpers.confirm!(u)
  end

  defp log_in(conn, user) do
    conn |> Plug.Test.init_test_session(%{}) |> Helpers.store_in_session(user)
  end

  defp published(author, title, category) do
    Article
    |> Ash.Changeset.for_create(:create, %{title: title, excerpt: "e", category: category},
      actor: author
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(:publish, %{}, actor: author)
    |> Ash.update!()
  end

  test "logged-in user lands on the For You tab by default and sees content", %{conn: conn} do
    me = user("fyfeed1")
    author = user("fyfeed1a")
    published(author, "Recommended Reading", :nutrition)

    {:ok, _lv, html} = live(log_in(conn, me), ~p"/articles")
    assert html =~ "for you"
    assert html =~ "Recommended Reading"
  end

  test "low-signal user sees the personalize nudge", %{conn: conn} do
    me = user("fyfeed2")
    author = user("fyfeed2a")
    published(author, "Some Article", :nutrition)

    {:ok, _lv, html} = live(log_in(conn, me), ~p"/articles?feed=for_you")
    assert html =~ "personalize"
  end

  test "anonymous visitor defaults to latest and has no For You tab", %{conn: conn} do
    author = user("fyfeed3a")
    published(author, "Anon Visible", :nutrition)

    {:ok, _lv, html} = live(conn, ~p"/articles")
    assert html =~ "Anon Visible"
    refute html =~ "for you"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec -T app mix test test/verscienta_web/live/for_you_feed_test.exs`
Expected: FAIL — no "for you" tab; default tab still latest for logged-in users.

- [ ] **Step 3: Edit `lib/verscienta_web/live/article_feed_live.ex`**

Replace the module attribute and `mount`/`handle_params`/`normalize_tab`/`load_feed` head region (lines 12–48) with:

```elixir
  @tabs ~w(for_you following trending latest)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "articles")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    user = socket.assigns[:current_user]
    tab = normalize_tab(params["feed"], user)

    {:noreply,
     socket
     |> assign(:tab, tab)
     |> assign(:tabs, visible_tabs(user))
     |> assign(:personalize_nudge?, false)
     |> load_feed(tab)}
  end

  defp visible_tabs(nil), do: ~w(latest following trending)
  defp visible_tabs(_user), do: ~w(for_you following trending latest)

  defp normalize_tab(nil, user), do: default_tab(user)
  defp normalize_tab("for_you", nil), do: "latest"
  defp normalize_tab(t, _user) when t in @tabs, do: t
  defp normalize_tab(_t, user), do: default_tab(user)

  defp default_tab(nil), do: "latest"
  defp default_tab(_user), do: "for_you"

  defp load_feed(socket, "for_you") do
    user = socket.assigns.current_user

    assign(socket,
      articles: [],
      items: Verscienta.Recommendations.for_you(user, limit: 30),
      needs_signin?: false,
      personalize_nudge?: not Verscienta.Recommendations.personalized?(user)
    )
  end

  defp load_feed(socket, "latest") do
    assign(socket, articles: Article.list_published(), items: [], needs_signin?: false)
  end

  defp load_feed(socket, "trending") do
    assign(socket, articles: Social.trending(limit: 30), items: [], needs_signin?: false)
  end

  defp load_feed(socket, "following") do
    case socket.assigns[:current_user] do
      nil ->
        assign(socket, articles: [], items: [], needs_signin?: true)

      user ->
        assign(socket,
          articles: [],
          items: Social.following_feed(user, limit: 30),
          needs_signin?: false
        )
    end
  end
```

- [ ] **Step 4: Edit the `render/1` nav + body** in the same file

Replace the `<nav>` block (the `<.link :for={t <- ~w(latest following trending)} …>`) so it iterates the computed tabs and renders a friendly label:

```heex
      <nav aria-label="feed tabs" class="mb-8 flex gap-5 text-xs lowercase tracking-wider text-ink-3">
        <.link
          :for={t <- @tabs}
          patch={"/articles?feed=" <> t}
          class={[@tab == t && "text-zune", @tab != t && "hover:text-ink"]}
        >
          {String.replace(t, "_", " ")}
        </.link>
      </nav>
```

Then, immediately **before** the `<div :if={@tab == "following" and not @needs_signin?}>` block, add the For You block (renders via the existing `article_grid` by extracting articles from items):

```heex
      <div :if={@tab == "for_you"}>
        <div :if={@personalize_nudge?} class="mb-6 rounded border border-line/40 px-4 py-3 text-xs text-ink-3">
          follow topics to personalize your feed.
        </div>
        <.article_grid articles={Enum.map(@items, & &1.article)} />
      </div>
```

- [ ] **Step 5: Update the moduledoc** (line 2) to mention the new tab:

```elixir
  @moduledoc "Front feed of published articles at /articles — For You / Following / Trending / Latest tabs."
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `docker compose exec -T app mix test test/verscienta_web/live/for_you_feed_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 7: Run the existing feed test to confirm no regression**

Run: `docker compose exec -T app mix test test/verscienta_web/live/article_feed_live_test.exs`
Expected: PASS (anonymous still defaults to latest).

- [ ] **Step 8: Commit**

```bash
git add lib/verscienta_web/live/article_feed_live.ex test/verscienta_web/live/for_you_feed_test.exs
git commit -m "feat(web): For You feed tab (default for logged-in users) with low-signal nudge"
```

---

## Task 6: Load-test harness integration

**Files:**
- Modify: `lib/verscienta/load_test/seeder.ex`
- Modify: `lib/verscienta/load_test/scenarios.ex`

- [ ] **Step 1: Give the fixture user interest signal + record it (seeder)**

In `lib/verscienta/load_test/seeder.ex`, in `seed_engagements!/4`, after the guaranteed mid-user follow block is built, add category follows + a few reactions for `mid_user` so it has both explicit and inferred signal. Locate the line that builds `mid_follow_rows` and add right after it:

```elixir
    # Give the mid_user explicit interest (category follows) so the For You
    # benchmark has real personalized signal.
    mid_category_follows =
      ~w(nutrition herbalism)
      |> Enum.map(fn cat ->
        %{
          user_id: mid_user.id,
          target_type: :category,
          target_id: cat,
          inserted_at: now,
          updated_at: now
        }
      end)
```

Then include `mid_category_follows` in the Follow seeding call. Change:

```elixir
    seed_chunked(Follow, dedupe_follows(follow_rows ++ mid_follow_rows), :discard)
```

to:

```elixir
    seed_chunked(Follow, dedupe_follows(follow_rows ++ mid_follow_rows ++ mid_category_follows), :discard)
```

(The mid_user already receives reactions/bookmarks via the skewed engagement distribution and the hot-article block, supplying inferred affinity.)

- [ ] **Step 2: Record `personalized_user_id` in the fixtures**

In `build_fixtures/4` in the same file, add the key (the mid_user is the personalized fixture):

```elixir
      "mid_user_id" => mid_user.id,
      "personalized_user_id" => mid_user.id,
```

- [ ] **Step 3: Add the For You scenario (scenarios)**

In `lib/verscienta/load_test/scenarios.ex`, add the alias and a spec. Add to the alias list:

```elixir
  alias Verscienta.Recommendations
```

Change `cached_read_specs/1` to include feeds + the For You read:

```elixir
  def cached_read_specs(fx) do
    feed_specs(fx) ++ for_you_specs(fx) ++ count_specs(fx) ++ leaderboard_specs(fx)
  end

  defp for_you_specs(fx) do
    uid = fx["personalized_user_id"]

    [
      spec(
        "feed: for_you",
        "for_you:user:#{uid}:limit=30",
        fn -> Recommendations.for_you(%{id: uid}, limit: 30) end
      )
    ]
  end
```

- [ ] **Step 4: Verify the harness still compiles + seeds (loadtest env)**

Run: `docker compose exec -T -e MIX_ENV=loadtest app mix compile --warnings-as-errors`
Expected: compiles clean.
Run: `docker compose exec -T -e MIX_ENV=loadtest app mix verscienta.load_test.seed --scale tiny`
Expected: seeds; final log shows the run summary; `priv/loadtest/fixtures.json` now contains `personalized_user_id`.

- [ ] **Step 5: Run the bench to confirm the For You warm read is gated and passes**

Run: `docker compose exec -T -e MIX_ENV=loadtest app mix verscienta.load_test.bench`
Expected: the summary includes `PASS  warm feed: for_you (p99)  …ms <= 50ms`; overall "ALL GATES PASSED".

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta/load_test/seeder.ex lib/verscienta/load_test/scenarios.ex
git commit -m "test(loadtest): add For You scenario + personalized fixture user"
```

---

## Task 7: Full verification + todo checkoff

**Files:**
- Modify: `docs/todo.md`

- [ ] **Step 1: Check off the todo item**

In `docs/todo.md`, under "### Recommendation & Personalization", change:

```markdown
- [ ] "For You" feed ranking using interactions, follows, tags, recency.
```

to:

```markdown
- [x] "For You" feed ranking using interactions, follows, tags, recency. *(signal-based v1; embeddings hybrid is slice 4)*
```

- [ ] **Step 2: Run the full suite**

Run: `docker compose exec -T app bash -lc 'mix format && mix format --check-formatted && mix test'`
Expected: format clean; full suite **0 failures** (≈516 prior + 20 new ≈ 536).

- [ ] **Step 3: Credo + Dialyzer**

Run: `docker compose exec -T app bash -lc 'mix credo --strict'`
Expected: "found no issues".
Run: `docker compose exec -T app mix dialyzer`
Expected: "done (passed successfully)".

- [ ] **Step 4: Commit**

```bash
git add docs/todo.md
git commit -m "docs: check off For You feed (signal-based v1)"
```

- [ ] **Step 5: Final review** — confirm all gates green, then this branch is ready to merge to `main` (the operator decides merge/push timing).

---

## Notes for the implementer

- **Item shape:** `for_you/2` returns `%{type: :article, article: %Article{}, repost: nil, timestamp: …}` items (matching `following_feed`). The For You tab renders them via the existing `article_grid` by extracting `& &1.article` — `news_card` needs only `category`, `title`, `published_at`, so backfilled Trending articles render safely without loaded tags.
- **`%{id: uid}` in the bench:** `for_you/2` and its helpers only read `user.id`, so the Benchee scenario passes a bare `%{id: uid}` rather than loading a full `User`.
- **Cache isolation in tests:** `Verscienta.DataCase` flushes `Verscienta.Cache` between tests, so per-user cache keys don't leak across cases.
- **Cold bench path:** the bench deletes only the `for_you:user:…:limit=30` list key before each cold iteration; the affinity-profile key stays warm — which mirrors production, where affinity is deliberately long-cached.
```
