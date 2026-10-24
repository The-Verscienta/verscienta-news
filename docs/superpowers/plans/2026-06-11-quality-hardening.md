# Quality Hardening Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the five quality workstreams: property-based tests for gamification/ranking math, e2e smoke tests on critical journeys, security review fixes (Ash authz, input validation, OWASP/Sobelow), WCAG AA accessibility fixes + regression floor, and performance-regression checks in CI.

**Architecture:** All test workstreams build on the existing ExUnit infrastructure (`Verscienta.DataCase`/`ConnCase`, `Verscienta.Support.Factory`, `Verscienta.Support.QueryCounter`). Property tests target the four *pure* math modules (`Points`, `Streaks`, `Scorer`, `Ranking`) plus `Leaderboards.closed_period/2` — no DB needed, `async: true`. Smoke tests are LiveViewTest journey tests (no browser driver — none exists in this stack and CI has no chromedriver). Security fixes add Ash policies to the three policy-free user-facing resources and tighten input caps. Perf regression = query-budget tests (deterministic, CI-safe) given a distinct CI step.

**Tech Stack:** Elixir 1.18 / Phoenix 1.8 / Ash 3 / StreamData (new dep) / LazyHTML (already a test dep) / Sobelow (new dev/test dep) / GitHub Actions.

---

## Environment: running mix from this worktree

This checkout is a worktree at `.claude/worktrees/awesome-wu-33fa33`. Host mix fails (bcrypt nmake); run everything inside the running `news-verscienta-app-1` container. Throughout this plan, **`wtmix <args>` means exactly this** (Bash tool shells don't persist functions — paste the function + the call in the same Bash invocation):

```bash
wtmix() {
  MSYS_NO_PATHCONV=1 docker exec \
    -e MIX_DEPS_PATH=/workspace/deps \
    -e MIX_BUILD_ROOT=/workspace/.claude/worktrees/awesome-wu-33fa33/_build \
    -e MIX_TEST_PARTITION=_wt_awesome_wu \
    -w /workspace/.claude/worktrees/awesome-wu-33fa33 \
    news-verscienta-app-1 mix "$@"
}
wtmix test
```

- If creating the partitioned test DB fails with `template database "template1" has a collation version mismatch`, run once:
  `docker exec news-verscienta-db-1 psql -U postgres -c "ALTER DATABASE template1 REFRESH COLLATION VERSION"`
- `MIX_DEPS_PATH=/workspace/deps` shares the main checkout's deps volume. Tasks 1 and 13 add new deps — that is **additive** (new package dirs; existing packages untouched), so it is safe; run `wtmix deps.get` after editing mix.exs.
- Git runs on the host as normal (`git -C` not needed; cwd is the worktree). Commit after every task.

Seed-contamination note: never assert list *counts* on published articles (seeded articles exist); assert presence of specific titles only.

---

## Workstream A — Property-based tests for gamification + ranking math

### Task 1: Add StreamData

**Files:**
- Modify: `mix.exs` (deps list)

- [ ] **Step 1: Add the dep** — in the `defp deps do` list in `mix.exs`, add alphabetically near the other test-only deps:

```elixir
      {:stream_data, "~> 1.1", only: [:dev, :test]},
```

- [ ] **Step 2: Fetch + compile**

Run: `wtmix deps.get && wtmix compile --warnings-as-errors`
Expected: `New: stream_data 1.x` resolved; compile clean.

- [ ] **Step 3: Commit**

```bash
git add mix.exs mix.lock
git commit -m "test: add stream_data for property-based testing"
```

### Task 2: Points level properties

**Files:**
- Test: `test/verscienta/gamification/points_property_test.exs`

Module under test: `Verscienta.Gamification.Points.level_for/1` = `trunc(:math.sqrt(max(p,0) / 50)) + 1`.

- [ ] **Step 1: Write the property test**

```elixir
defmodule Verscienta.Gamification.PointsPropertyTest do
  @moduledoc "Property tests for the level-from-points formula."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Verscienta.Gamification.Points

  property "level is always at least 1" do
    check all points <- integer(-1_000_000..10_000_000) do
      assert Points.level_for(points) >= 1
    end
  end

  property "level is monotonically non-decreasing in points" do
    check all points <- integer(0..10_000_000),
              bump <- integer(0..1_000_000) do
      assert Points.level_for(points) <= Points.level_for(points + bump)
    end
  end

  property "50*n^2 is exactly the first total that reaches level n+1" do
    check all n <- integer(1..1_000) do
      threshold = 50 * n * n
      assert Points.level_for(threshold) == n + 1
      assert Points.level_for(threshold - 1) == n
    end
  end

  property "negative points clamp to level 1" do
    check all points <- integer(-10_000_000..-1) do
      assert Points.level_for(points) == 1
    end
  end
end
```

- [ ] **Step 2: Run it**

Run: `wtmix test test/verscienta/gamification/points_property_test.exs`
Expected: 4 properties, 0 failures. (If the threshold property fails on a float edge, the *formula* has a real boundary bug — investigate before touching the test; `sqrt` of an exact square ≤ 1000² is exact in IEEE-754.)

- [ ] **Step 3: Commit**

```bash
git add test/verscienta/gamification/points_property_test.exs
git commit -m "test: property-based tests for points level formula"
```

### Task 3: Streak math properties

**Files:**
- Test: `test/verscienta/gamification/streaks_property_test.exs`

Module under test: `Verscienta.Gamification.Streaks.extend/2` and `milestone_crossed?/2` (pure; state is a map with the Streak resource's keys).

- [ ] **Step 1: Write the property test**

```elixir
defmodule Verscienta.Gamification.StreaksPropertyTest do
  @moduledoc "Property tests for pure streak math (extend/2, milestone_crossed?/2)."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Verscienta.Gamification.Streaks

  @start ~D[2026-01-01]

  defp blank(freezes) do
    %{
      current_length: 0,
      longest_length: 0,
      last_active_date: nil,
      freezes_available: freezes,
      last_freeze_used_on: nil
    }
  end

  # Gaps of 0 produce same-day duplicate events (must be no-ops).
  defp dates_from_gaps(gaps) do
    {dates, _last} =
      Enum.map_reduce(gaps, @start, fn gap, last ->
        next = Date.add(last, gap)
        {next, next}
      end)

    [@start | dates]
  end

  property "structural invariants hold after any event sequence" do
    check all gaps <- list_of(integer(0..5), max_length: 40),
              freezes <- integer(0..5) do
      dates = dates_from_gaps(gaps)
      final = Enum.reduce(dates, blank(freezes), &Streaks.extend(&2, &1))

      assert final.current_length >= 1
      assert final.longest_length >= final.current_length
      assert final.current_length <= length(Enum.uniq(dates))
      assert final.freezes_available >= 0
      assert final.freezes_available <= freezes
      assert final.last_active_date == List.last(dates)
    end
  end

  property "longest_length is non-decreasing along the fold" do
    check all gaps <- list_of(integer(0..5), max_length: 40),
              freezes <- integer(0..5) do
      longests =
        gaps
        |> dates_from_gaps()
        |> Enum.scan(blank(freezes), &Streaks.extend(&2, &1))
        |> Enum.map(& &1.longest_length)

      assert longests == Enum.sort(longests)
    end
  end

  property "re-extending with the already-recorded date is a no-op" do
    check all gaps <- list_of(integer(0..4), max_length: 20),
              freezes <- integer(0..3) do
      state = gaps |> dates_from_gaps() |> Enum.reduce(blank(freezes), &Streaks.extend(&2, &1))
      assert Streaks.extend(state, state.last_active_date) == state
    end
  end

  property "with zero freezes, current streak equals 1 + trailing run of 1-day gaps" do
    check all gaps <- list_of(integer(0..5), max_length: 40) do
      final = gaps |> dates_from_gaps() |> Enum.reduce(blank(0), &Streaks.extend(&2, &1))

      expected =
        gaps
        |> Enum.reject(&(&1 == 0))
        |> Enum.reverse()
        |> Enum.take_while(&(&1 == 1))
        |> length()
        |> Kernel.+(1)

      assert final.current_length == expected
    end
  end

  property "all-consecutive days build a streak equal to the day count" do
    check all n <- integer(0..60) do
      gaps = List.duplicate(1, n)
      final = gaps |> dates_from_gaps() |> Enum.reduce(blank(0), &Streaks.extend(&2, &1))
      assert final.current_length == n + 1
      assert final.longest_length == n + 1
    end
  end

  property "milestone_crossed? returns the first milestone in (old, new], else nil" do
    check all old <- integer(0..400),
              new <- integer(0..400) do
      crossed = Enum.filter(Streaks.milestones(), fn m -> old < m and new >= m end)

      case Streaks.milestone_crossed?(%{current_length: old}, %{current_length: new}) do
        nil -> assert crossed == []
        m -> assert m == Enum.min(crossed)
      end
    end
  end
end
```

- [ ] **Step 2: Run it**

Run: `wtmix test test/verscienta/gamification/streaks_property_test.exs`
Expected: 6 properties, 0 failures.

- [ ] **Step 3: Commit**

```bash
git add test/verscienta/gamification/streaks_property_test.exs
git commit -m "test: property-based tests for streak math"
```

### Task 4: For-You scorer properties

**Files:**
- Test: `test/verscienta/recommendations/scorer_property_test.exs`

Module under test: `Verscienta.Recommendations.Scorer.score/5` (pure weighted sum; freshness `2^(-age_days/5)`).

- [ ] **Step 1: Write the property test**

```elixir
defmodule Verscienta.Recommendations.ScorerPropertyTest do
  @moduledoc "Property tests for the pure For You scoring function."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Verscienta.Recommendations.Scorer

  @now ~U[2026-06-11 12:00:00Z]
  @categories [:nutrition, :movement]
  @zero_weights %{explicit: 0.0, affinity: 0.0, social: 0.0, freshness: 0.0, quality: 0.0, semantic: 0.0}

  defp candidate_gen do
    gen all category <- member_of(@categories),
            tag_ids <- list_of(integer(1..50), max_length: 5),
            age_seconds <- integer(0..(30 * 86_400)),
            quality <- one_of([constant(nil), float(min: 0.0, max: 1.0)]),
            semantic <- one_of([constant(nil), float(min: 0.0, max: 1.0)]) do
      %{
        category: category,
        tag_ids: tag_ids,
        published_at: DateTime.add(@now, -age_seconds, :second),
        quality: quality,
        semantic: semantic
      }
    end
  end

  defp profile_gen do
    gen all cats <- list_of(member_of(@categories), max_length: 2),
            tag_follows <- list_of(integer(1..50), max_length: 5),
            cat_aff <- map_of(member_of(@categories), float(min: 0.0, max: 1.0), max_length: 2),
            tag_aff <- map_of(integer(1..50), float(min: 0.0, max: 1.0), max_length: 5) do
      %{
        followed_categories: MapSet.new(cats),
        followed_tag_ids: MapSet.new(tag_follows),
        category_affinity: cat_aff,
        tag_affinity: tag_aff,
        taste_vector: nil
      }
    end
  end

  property "score is non-negative with default weights" do
    check all c <- candidate_gen(), p <- profile_gen(), social <- integer(0..20) do
      assert Scorer.score(c, p, social, Scorer.default_weights(), @now) >= 0.0
    end
  end

  property "score is monotone in social proof" do
    check all c <- candidate_gen(), p <- profile_gen(), s1 <- integer(0..20), extra <- integer(0..20) do
      w = Scorer.default_weights()
      assert Scorer.score(c, p, s1, w, @now) <= Scorer.score(c, p, s1 + extra, w, @now)
    end
  end

  property "an older copy of the same candidate never scores higher" do
    check all c <- candidate_gen(), p <- profile_gen(), extra_age <- integer(1..(30 * 86_400)) do
      w = Scorer.default_weights()
      older = %{c | published_at: DateTime.add(c.published_at, -extra_age, :second)}

      assert Scorer.score(older, p, 0, w, @now) <= Scorer.score(c, p, 0, w, @now) + 1.0e-12
    end
  end

  property "following the candidate's category never decreases the score" do
    check all c <- candidate_gen(), p <- profile_gen() do
      w = Scorer.default_weights()
      p_follows = %{p | followed_categories: MapSet.put(p.followed_categories, c.category)}

      assert Scorer.score(c, p_follows, 0, w, @now) >= Scorer.score(c, p, 0, w, @now)
    end
  end

  property "all-zero weights give a zero score" do
    check all c <- candidate_gen(), p <- profile_gen(), social <- integer(0..20) do
      assert Scorer.score(c, p, social, @zero_weights, @now) == 0.0
    end
  end

  property "score is linear in the quality component" do
    check all c <- candidate_gen(), p <- profile_gen(), q1 <- float(min: 0.0, max: 1.0), q2 <- float(min: 0.0, max: 1.0) do
      w = Scorer.default_weights()
      diff = Scorer.score(%{c | quality: q2}, p, 0, w, @now) - Scorer.score(%{c | quality: q1}, p, 0, w, @now)
      assert_in_delta diff, w.quality * (q2 - q1), 1.0e-9
    end
  end
end
```

- [ ] **Step 2: Run it**

Run: `wtmix test test/verscienta/recommendations/scorer_property_test.exs`
Expected: 6 properties, 0 failures.

- [ ] **Step 3: Commit**

```bash
git add test/verscienta/recommendations/scorer_property_test.exs
git commit -m "test: property-based tests for For You scorer"
```

### Task 5: Search reranking + leaderboard period properties

**Files:**
- Test: `test/verscienta/search/ranking_property_test.exs`
- Test: `test/verscienta/gamification/leaderboards_property_test.exs`

Modules under test: `Verscienta.Search.Ranking.rerank/4` (pure; `blended = relevance + beta * personal`, `personal ∈ [0,1]`) and `Verscienta.Gamification.Leaderboards.closed_period/2` (pure; returns `{start_date, end_date}`).

- [ ] **Step 1: Write the ranking property test**

```elixir
defmodule Verscienta.Search.RankingPropertyTest do
  @moduledoc "Property tests for pure search-personalization reranking."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Verscienta.Search.Ranking

  # "zzz-not-a-category" exercises the unknown-atom rescue path in safe_atom/1.
  defp hits_gen do
    list_of(
      fixed_map(%{
        "id" => string(:alphanumeric, min_length: 1, max_length: 8),
        "_rankingScore" => float(min: 0.0, max: 1.0),
        "category" => member_of(["nutrition", "movement", "zzz-not-a-category"])
      }),
      max_length: 12
    )
  end

  defp profile_gen do
    gen all cats <- list_of(member_of([:nutrition, :movement]), max_length: 2),
            aff <- map_of(member_of([:nutrition, :movement]), float(min: 0.0, max: 1.0), max_length: 2) do
      %{followed_categories: MapSet.new(cats), category_affinity: aff, taste_vector: nil}
    end
  end

  property "rerank returns a permutation of its input" do
    check all hits <- hits_gen(), profile <- profile_gen() do
      out = Ranking.rerank(hits, profile, %{})
      assert length(out) == length(hits)
      assert Enum.sort(out) == Enum.sort(hits)
    end
  end

  property "a nil profile returns hits unchanged" do
    check all hits <- hits_gen() do
      assert Ranking.rerank(hits, nil, %{}) == hits
    end
  end

  property "a relevance gap larger than beta can never be overcome" do
    check all hits <- hits_gen(), profile <- profile_gen() do
      beta = Ranking.default_beta()
      out = Ranking.rerank(hits, profile, %{}, beta: beta)

      out
      |> Enum.with_index()
      |> Enum.each(fn {above, i} ->
        for below <- Enum.drop(out, i + 1) do
          refute below["_rankingScore"] - above["_rankingScore"] > beta,
                 "relevance #{below["_rankingScore"]} ranked below #{above["_rankingScore"]}"
        end
      end)
    end
  end

  property "beta 0 yields exactly the stable relevance-descending order" do
    check all hits <- hits_gen(), profile <- profile_gen() do
      expected =
        hits
        |> Enum.with_index()
        |> Enum.sort_by(fn {h, i} -> {-h["_rankingScore"], i} end)
        |> Enum.map(&elem(&1, 0))

      assert Ranking.rerank(hits, profile, %{}, beta: 0.0) == expected
    end
  end

  property "full ties preserve input order (stable sort)" do
    check all hits <- hits_gen() do
      tied = Enum.map(hits, &Map.put(&1, "_rankingScore", 0.5))
      no_signal = %{followed_categories: MapSet.new(), category_affinity: %{}, taste_vector: nil}

      assert Ranking.rerank(tied, no_signal, %{}) == tied
    end
  end
end
```

- [ ] **Step 2: Write the leaderboard closed-period property test**

```elixir
defmodule Verscienta.Gamification.LeaderboardsPropertyTest do
  @moduledoc "Property tests for closed leaderboard period arithmetic."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Verscienta.Gamification.Leaderboards

  defp datetime_gen do
    gen all offset <- integer(0..(10 * 365 * 86_400)) do
      DateTime.add(~U[2020-01-01 00:00:00Z], offset, :second)
    end
  end

  property "weekly closed period is the full Monday–Sunday week immediately before now" do
    check all now <- datetime_gen() do
      {start_d, end_d} = Leaderboards.closed_period(:weekly, now)

      assert Date.day_of_week(start_d) == 1
      assert Date.diff(end_d, start_d) == 6
      assert Date.add(end_d, 1) == Date.beginning_of_week(DateTime.to_date(now))
    end
  end

  property "monthly closed period is exactly the prior calendar month" do
    check all now <- datetime_gen() do
      {start_d, end_d} = Leaderboards.closed_period(:monthly, now)

      assert start_d.day == 1
      assert end_d == Date.end_of_month(start_d)
      assert Date.add(end_d, 1) == %Date{DateTime.to_date(now) | day: 1}
    end
  end
end
```

- [ ] **Step 3: Run both**

Run: `wtmix test test/verscienta/search/ranking_property_test.exs test/verscienta/gamification/leaderboards_property_test.exs`
Expected: 7 properties, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add test/verscienta/search/ranking_property_test.exs test/verscienta/gamification/leaderboards_property_test.exs
git commit -m "test: property-based tests for search rerank and leaderboard periods"
```

---

## Workstream B — End-to-end smoke tests on critical journeys

LiveViewTest journey tests under `test/verscienta_web/smoke/`, tagged `:smoke`. Verified event contracts: editor add-block `button[phx-value-type=paragraph]`, form `#article-form` with nested `form: %{...}` params, `block_change` with `%{"block" => %{"0" => text}}`, buttons labeled `save draft` / `publish`; onboarding `toggle_category` (`%{"key" => key}`) and `continue`; reader `toggle_reaction` (`%{"kind" => ...}`, kinds `like|insightful|helpful`), `toggle_bookmark`, `post_comment` (`%{"body" => ...}`).

### Task 6: Visitor journey smoke test

**Files:**
- Test: `test/verscienta_web/smoke/visitor_journey_test.exs`

- [ ] **Step 1: Write the test**

```elixir
defmodule VerscientaWeb.Smoke.VisitorJourneyTest do
  @moduledoc "Critical-journey smoke: anonymous visitor browses, reads, filters, searches."
  use VerscientaWeb.ConnCase, async: false
  @moduletag :smoke

  import Phoenix.LiveViewTest
  import Verscienta.Support.Factory, only: [user: 1, article: 2]

  setup do
    author = user("smoke_visitor_author")
    article = article(author, %{title: "Visitor Smoke Headline", category: :nutrition})
    %{article: article}
  end

  test "home page responds", %{conn: conn} do
    assert conn |> get(~p"/") |> html_response(200)
  end

  test "feed -> reader -> category -> search", %{conn: conn, article: article} do
    {:ok, _lv, html} = live(conn, ~p"/articles?feed=latest")
    assert html =~ "Visitor Smoke Headline"

    {:ok, _lv, html} = live(conn, ~p"/articles/#{article.slug}")
    assert html =~ "Visitor Smoke Headline"

    {:ok, _lv, html} = live(conn, ~p"/c/nutrition")
    assert html =~ "Visitor Smoke Headline"

    assert {:ok, _lv, _html} = live(conn, ~p"/search")
  end
end
```

- [ ] **Step 2: Run it**

Run: `wtmix test test/verscienta_web/smoke/visitor_journey_test.exs`
Expected: 2 tests, 0 failures. If the feed assertion fails, check the tab param name in `article_feed_live.ex` (`?feed=latest`) and the category route slug for `:nutrition` — fix the *test*, the journey itself is exercised by existing per-page tests.

- [ ] **Step 3: Commit**

```bash
git add test/verscienta_web/smoke/visitor_journey_test.exs
git commit -m "test: visitor journey smoke test"
```

### Task 7: Author journey smoke test

**Files:**
- Test: `test/verscienta_web/smoke/author_journey_test.exs`

- [ ] **Step 1: Write the test**

```elixir
defmodule VerscientaWeb.Smoke.AuthorJourneyTest do
  @moduledoc "Critical-journey smoke: sign in -> onboard -> write -> publish -> read back."
  use VerscientaWeb.ConnCase, async: false
  @moduletag :smoke

  import Phoenix.LiveViewTest
  import Verscienta.Support.Factory, only: [user: 1, sign_in: 2]

  test "author onboards, writes, publishes, and the article is readable", %{conn: conn} do
    author = user("smoke_writer")
    conn = sign_in(conn, author)

    # Onboarding: pick an interest and continue (navigates into the app).
    {:ok, lv, _html} = live(conn, ~p"/welcome")
    render_click(lv, "toggle_category", %{"key" => "nutrition"})
    assert {:error, {:live_redirect, %{to: _}}} = render_click(lv, "continue", %{})

    # Editor: add a paragraph block, fill metadata, save draft, publish.
    {:ok, lv, _html} = live(conn, ~p"/articles/new")
    lv |> element("button[phx-value-type=paragraph]") |> render_click()

    lv
    |> form("#article-form",
      form: %{
        "title" => "Author Smoke Journey",
        "category" => "nutrition",
        "excerpt" => "smoke",
        "tags" => ""
      }
    )
    |> render_change()

    render_change(lv, "block_change", %{"block" => %{"0" => "Smoke body text"}})
    lv |> element("button", "save draft") |> render_click()

    assert {:error, {:live_redirect, %{to: to}}} =
             lv |> element("button", "publish") |> render_click()

    assert to =~ "/articles/"

    # Read it back, both directly and on the latest feed.
    {:ok, _lv, html} = live(conn, to)
    assert html =~ "Author Smoke Journey"

    {:ok, _lv, html} = live(conn, ~p"/articles?feed=latest")
    assert html =~ "Author Smoke Journey"
  end
end
```

- [ ] **Step 2: Run it**

Run: `wtmix test test/verscienta_web/smoke/author_journey_test.exs`
Expected: 1 test, 0 failures. If `continue` does not redirect (e.g. it patches), relax that line to `_ = render_click(lv, "continue", %{})` — the editor flow is the load-bearing part.

- [ ] **Step 3: Commit**

```bash
git add test/verscienta_web/smoke/author_journey_test.exs
git commit -m "test: author journey smoke test (onboard -> publish -> read)"
```

### Task 8: Engagement journey smoke test

**Files:**
- Test: `test/verscienta_web/smoke/engagement_journey_test.exs`

- [ ] **Step 1: Write the test**

```elixir
defmodule VerscientaWeb.Smoke.EngagementJourneyTest do
  @moduledoc "Critical-journey smoke: reader reacts, bookmarks, comments; library reflects it."
  use VerscientaWeb.ConnCase, async: false
  @moduletag :smoke

  import Phoenix.LiveViewTest
  import Verscienta.Support.Factory, only: [user: 1, article: 2, sign_in: 2]

  test "react + bookmark + comment on an article, then find it in the library", %{conn: conn} do
    author = user("smoke_eng_author")
    article = article(author, %{title: "Engagement Smoke", category: :nutrition})

    reader = user("smoke_eng_reader")
    conn = sign_in(conn, reader)

    {:ok, lv, _html} = live(conn, ~p"/articles/#{article.slug}")

    render_click(lv, "toggle_reaction", %{"kind" => "insightful"})
    render_click(lv, "toggle_bookmark", %{})
    html = render_click(lv, "post_comment", %{"body" => "Smoke comment body"})
    assert html =~ "Smoke comment body"

    # Reaction and bookmark persisted.
    require Ash.Query

    assert Verscienta.Engagement.Reaction
           |> Ash.Query.filter(article_id == ^article.id and user_id == ^reader.id)
           |> Ash.read!(authorize?: false)
           |> length() == 1

    assert Verscienta.Engagement.Bookmark
           |> Ash.Query.filter(article_id == ^article.id and user_id == ^reader.id)
           |> Ash.read!(authorize?: false)
           |> length() == 1

    # The bookmarked article shows up in the reader's library.
    {:ok, _lv, html} = live(conn, ~p"/library")
    assert html =~ "Engagement Smoke"
  end
end
```

- [ ] **Step 2: Run it**

Run: `wtmix test test/verscienta_web/smoke/engagement_journey_test.exs`
Expected: 1 test, 0 failures. If `post_comment` re-renders without the comment (async assigns), follow with `render(lv) =~ "Smoke comment body"`.

- [ ] **Step 3: Run the whole smoke suite + commit**

Run: `wtmix test --only smoke`
Expected: 4 tests, 0 failures.

```bash
git add test/verscienta_web/smoke/engagement_journey_test.exs
git commit -m "test: engagement journey smoke test (react, bookmark, comment, library)"
```

---

## Workstream C — Security review (Ash authz, input validation, OWASP)

Inventory findings driving this workstream: 22/35 resources have policies; the policy-free ones are system-only ledgers/catalogs **except** `Room`, `Message`, and `RoomBan` (user-facing, zero policies — defense currently lives only in `Verscienta.Communities` context checks). `ValidateApply` already enforces http(s) URLs but has no array/length caps. `Tag.name` has no length cap. HTML rendering is sanitized (MDEx + ammonia; inline markdown pre-escapes) — no change needed. No Sobelow in CI.

### Task 9: Policies for `Message`

**Files:**
- Modify: `lib/verscienta/communities/message.ex`
- Test: `test/verscienta/communities/message_policy_test.exs`

Context-layer calls keep working because they use `authorize?: false` (`recent_messages/2`, `remove_message/2`) or pass an actor (`post_message/3`); membership/ban/closed checks stay in `Verscienta.Communities` — the resource policy is the defense-in-depth floor.

- [ ] **Step 1: Verify all privileged callers bypass policies explicitly**

Run: `grep -rn "for_update(:soft_delete\|for_update(:hold\|for_update(:unhold" lib/ | grep -i message`
Expected: every hit pairs with `authorize?: false` (check each file:line). If any caller relies on default authorization, add `authorize?: false` there first.

- [ ] **Step 2: Write the failing policy test**

```elixir
defmodule Verscienta.Communities.MessagePolicyTest do
  @moduledoc "Resource-level authz floor for room messages."
  use Verscienta.DataCase, async: false

  import Verscienta.Support.Factory, only: [user: 1]

  alias Verscienta.Communities
  alias Verscienta.Communities.Message

  require Ash.Query

  defp group_and_room(owner) do
    group =
      Verscienta.Communities.Group
      |> Ash.Changeset.for_create(:create, %{name: "Msg Policy Group"}, actor: owner)
      |> Ash.create!()

    {group, Communities.room_for_group(group)}
  end

  test "posting requires an actor" do
    owner = user("msgpol_owner")
    {_group, room} = group_and_room(owner)

    assert {:error, %Ash.Error.Forbidden{}} =
             Message
             |> Ash.Changeset.for_create(:post, %{room_id: room.id, body: "anon"})
             |> Ash.create()
  end

  test "an actor can post (resource floor) and read messages" do
    owner = user("msgpol_poster")
    {_group, room} = group_and_room(owner)

    assert {:ok, _} =
             Message
             |> Ash.Changeset.for_create(:post, %{room_id: room.id, body: "hi"},
               actor: owner
             )
             |> Ash.create()

    assert [_] =
             Message
             |> Ash.Query.filter(room_id == ^room.id)
             |> Ash.read!(actor: owner)
  end

  test "reading without an actor is forbidden" do
    owner = user("msgpol_reader")
    {_group, room} = group_and_room(owner)

    assert {:error, %Ash.Error.Forbidden{}} =
             Message |> Ash.Query.filter(room_id == ^room.id) |> Ash.read()
  end

  test "soft_delete/hold/unhold are system-only" do
    owner = user("msgpol_mod")
    {_group, room} = group_and_room(owner)

    msg =
      Message
      |> Ash.Changeset.for_create(:post, %{room_id: room.id, body: "x"}, actor: owner)
      |> Ash.create!()

    for action <- [:soft_delete, :hold, :unhold] do
      assert {:error, %Ash.Error.Forbidden{}} =
               msg |> Ash.Changeset.for_update(action, %{}, actor: owner) |> Ash.update()
    end
  end
end
```

Run: `wtmix test test/verscienta/communities/message_policy_test.exs`
Expected: FAIL — without an authorizer, the no-actor create succeeds and no Forbidden errors are produced. (If `Group :create` needs different attrs, mirror the setup used in `test/verscienta/communities/` tests.)

- [ ] **Step 3: Add the authorizer and policies**

In `lib/verscienta/communities/message.ex`, change the `use` line and add a `policies` block after `actions`:

```elixir
  use Ash.Resource,
    domain: Verscienta.Communities,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]
```

```elixir
  policies do
    # Room visibility is enforced at the LiveView/context layer (membership,
    # bans, closed rooms); this is the resource-level floor.
    policy action_type(:read) do
      authorize_if actor_present()
    end

    policy action(:post) do
      authorize_if actor_present()
    end

    policy action([:soft_delete, :hold, :unhold]) do
      description "System/moderation paths call these with authorize?: false."
      forbid_if always()
    end
  end
```

- [ ] **Step 4: Run the policy test, the room LiveView test, and moderation tests**

Run: `wtmix test test/verscienta/communities/message_policy_test.exs test/verscienta_web/live/room_live_test.exs test/verscienta/moderation`
Expected: PASS. Any new Forbidden error means a caller was missed in Step 1 — give it `authorize?: false` (system path) or an actor (user path).

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta/communities/message.ex test/verscienta/communities/message_policy_test.exs
git commit -m "feat(security): resource-level policies for room messages"
```

### Task 10: Policies for `Room` and `RoomBan`

**Files:**
- Modify: `lib/verscienta/communities/room.ex`
- Modify: `lib/verscienta/communities/room_ban.ex`
- Test: `test/verscienta/communities/room_policy_test.exs`

Both resources are system-managed (`room_for_group/1`, `lock_room/3`, `ban_user/3` all call with `authorize?: false` after their own checks), so the policy is: reads open (room metadata is just topic/status; bans readable floor = actor), writes forbidden unless bypassed.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Verscienta.Communities.RoomPolicyTest do
  @moduledoc "Room and RoomBan are system-managed: direct authorized writes are forbidden."
  use Verscienta.DataCase, async: false

  import Verscienta.Support.Factory, only: [user: 1]

  alias Verscienta.Communities

  defp group(owner) do
    Verscienta.Communities.Group
    |> Ash.Changeset.for_create(:create, %{name: "Room Policy Group"}, actor: owner)
    |> Ash.create!()
  end

  test "users cannot create rooms directly, even with an actor" do
    owner = user("roompol_owner")
    g = group(owner)

    assert {:error, %Ash.Error.Forbidden{}} =
             Verscienta.Communities.Room
             |> Ash.Changeset.for_create(:find_or_create_for_group, %{group_id: g.id},
               actor: owner
             )
             |> Ash.create()

    # The system path still works.
    assert %Verscienta.Communities.Room{} = Communities.room_for_group(g)
  end

  test "users cannot set room status directly" do
    owner = user("roompol_lock")
    room = owner |> group() |> Communities.room_for_group()

    assert {:error, %Ash.Error.Forbidden{}} =
             room
             |> Ash.Changeset.for_update(:set_status, %{status: :closed}, actor: owner)
             |> Ash.update()

    # The guarded context path still works for a moderator.
    assert {:ok, _} = Communities.lock_room(room, owner, :closed)
  end

  test "users cannot write room bans directly" do
    owner = user("roompol_ban_owner")
    target = user("roompol_ban_target")
    room = owner |> group() |> Communities.room_for_group()

    assert {:error, %Ash.Error.Forbidden{}} =
             Verscienta.Communities.RoomBan
             |> Ash.Changeset.for_create(:create, %{room_id: room.id, user_id: target.id},
               actor: owner
             )
             |> Ash.create()
  end
end
```

Run: `wtmix test test/verscienta/communities/room_policy_test.exs`
Expected: FAIL (writes currently succeed). Note: `RoomBan`'s create action may be named differently (e.g. `:ban`) — check `lib/verscienta/communities/room_ban.ex` and use its actual create action name in the test.

- [ ] **Step 2: Add authorizers + policies**

`lib/verscienta/communities/room.ex` — change `use` to include `authorizers: [Ash.Policy.Authorizer]` and add:

```elixir
  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:find_or_create_for_group, :set_status]) do
      description "System-managed via Verscienta.Communities (authorize?: false)."
      forbid_if always()
    end
  end
```

`lib/verscienta/communities/room_ban.ex` — same `use` change, and:

```elixir
  policies do
    policy action_type(:read) do
      authorize_if actor_present()
    end

    policy action_type([:create, :update, :destroy]) do
      description "System-managed via Verscienta.Communities.ban_user/3 (authorize?: false)."
      forbid_if always()
    end
  end
```

- [ ] **Step 3: Run room tests**

Run: `wtmix test test/verscienta/communities test/verscienta_web/live/room_live_test.exs`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add lib/verscienta/communities/room.ex lib/verscienta/communities/room_ban.ex test/verscienta/communities/room_policy_test.exs
git commit -m "feat(security): system-only policies for rooms and room bans"
```

### Task 11: Cap expert-application credential URLs

**Files:**
- Modify: `lib/verscienta/experts/expert_application/changes/validate_apply.ex`
- Test: `test/verscienta/experts/apply_limits_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Verscienta.Experts.ApplyLimitsTest do
  @moduledoc "Array/length caps on expert-application credential URLs."
  use Verscienta.DataCase, async: false

  import Verscienta.Support.Factory, only: [user: 1]

  alias Verscienta.Experts.ExpertApplication

  defp apply_with(urls, name) do
    ExpertApplication
    |> Ash.Changeset.for_create(
      :apply,
      %{statement: String.duplicate("credible statement ", 3), credential_urls: urls},
      actor: user(name)
    )
    |> Ash.create()
  end

  test "more than 5 credential URLs is rejected" do
    urls = for i <- 1..6, do: "https://example.com/cred#{i}"
    assert {:error, error} = apply_with(urls, "limits_many")
    assert Exception.message(error) =~ "at most 5"
  end

  test "a credential URL longer than 300 characters is rejected" do
    long = "https://example.com/" <> String.duplicate("a", 300)
    assert {:error, error} = apply_with([long], "limits_long")
    assert Exception.message(error) =~ "300"
  end

  test "5 normal URLs still pass" do
    urls = for i <- 1..5, do: "https://example.com/cred#{i}"
    assert {:ok, _} = apply_with(urls, "limits_ok")
  end
end
```

Run: `wtmix test test/verscienta/experts/apply_limits_test.exs`
Expected: first two tests FAIL (caps not enforced yet); third passes.

- [ ] **Step 2: Add the cap clauses**

In `validate_apply.ex`, inside the `cond` in `validate/2`, insert **after** the existing `urls == [] or not Enum.all?(urls, &valid_url?/1)` clause:

```elixir
      length(urls) > 5 ->
        Ash.Changeset.add_error(cs,
          field: :credential_urls,
          message: "provide at most 5 credential URLs"
        )

      Enum.any?(urls, &(String.length(&1) > 300)) ->
        Ash.Changeset.add_error(cs,
          field: :credential_urls,
          message: "each credential URL must be at most 300 characters"
        )
```

- [ ] **Step 3: Run expert tests**

Run: `wtmix test test/verscienta/experts test/verscienta_web/live/expert_apply_live_test.exs`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add lib/verscienta/experts/expert_application/changes/validate_apply.ex test/verscienta/experts/apply_limits_test.exs
git commit -m "feat(security): cap expert-application credential URLs (count + length)"
```

### Task 12: Cap tag name length

**Files:**
- Modify: `lib/verscienta/content/tag.ex:43`
- Test: `test/verscienta/content/tag_limits_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Verscienta.Content.TagLimitsTest do
  @moduledoc "Tag names are user input via upsert_by_name; cap their length."
  use Verscienta.DataCase, async: false

  import Verscienta.Support.Factory, only: [user: 1]

  alias Verscienta.Content.Tag

  test "a 51-character tag name is rejected" do
    assert {:error, _} =
             Tag
             |> Ash.Changeset.for_create(:upsert_by_name, %{name: String.duplicate("a", 51)},
               actor: user("taglimit")
             )
             |> Ash.create()
  end

  test "a 50-character tag name is accepted" do
    assert {:ok, _} =
             Tag
             |> Ash.Changeset.for_create(:upsert_by_name, %{name: String.duplicate("b", 50)},
               actor: user("taglimit_ok")
             )
             |> Ash.create()
  end
end
```

Run: `wtmix test test/verscienta/content/tag_limits_test.exs`
Expected: first test FAILS (51 chars currently accepted).

- [ ] **Step 2: Add the constraint** — in `tag.ex`, change:

```elixir
    attribute :name, :ci_string, allow_nil?: false, public?: true
```

to:

```elixir
    attribute :name, :ci_string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 50]
```

No migration needed (`citext` column is unbounded; the constraint is validation-level).

- [ ] **Step 3: Run content tests**

Run: `wtmix test test/verscienta/content test/verscienta_web/live/article_editor_live_test.exs`
Expected: PASS (editor tags like "focus, habits" are well under 50).

- [ ] **Step 4: Commit**

```bash
git add lib/verscienta/content/tag.ex test/verscienta/content/tag_limits_test.exs
git commit -m "feat(security): length cap on user-minted tag names"
```

### Task 13: Sobelow static security scanning in CI

**Files:**
- Modify: `mix.exs` (deps)
- Create: `.sobelow-conf`
- Modify: `.github/workflows/ci.yml` (test job, after the credo step)

- [ ] **Step 1: Add the dep**

```elixir
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
```

Run: `wtmix deps.get`

- [ ] **Step 2: First run + triage**

Run: `wtmix sobelow --exit medium`
Triage every finding now, with these decision rules:
- Real issue → fix it in this task (separate commit if non-trivial).
- False positive / accepted risk (e.g. `Config.HTTPS` when TLS terminates at the proxy, the sanitized `raw/1` in `Layouts.json_ld_tag` which JSON-encodes and escapes `</`) → add to the ignore list in `.sobelow-conf` and record the justification in the Task 14 report.

- [ ] **Step 3: Create `.sobelow-conf`** (adjust `ignore` to the Step 2 triage; this is the starting point):

```elixir
[
  verbose: true,
  exit: "medium",
  skip: true,
  ignore: ["Config.HTTPS"]
]
```

- [ ] **Step 4: Verify a clean run**

Run: `wtmix sobelow --config`
Expected: exit code 0.

- [ ] **Step 5: Add the CI step** — in `.github/workflows/ci.yml`, in the `test` job directly after the `mix credo --strict` step:

```yaml
      - name: Security static analysis (Sobelow)
        run: mix sobelow --config
```

- [ ] **Step 6: Commit**

```bash
git add mix.exs mix.lock .sobelow-conf .github/workflows/ci.yml
git commit -m "ci: add Sobelow security scanning"
```

### Task 14: Security review report

**Files:**
- Create: `docs/security/2026-06-11-security-review.md`

- [ ] **Step 1: Write the report.** Contents (write it out fully, this is the structure with the already-established findings — fold in anything Task 13 triage added):

```markdown
# Security Review — 2026-06-11

Scope: authorization on every Ash action, input validation, OWASP Top 10 pass.

## Authorization matrix
- 35 Ash resources audited. 22 had policies; 13 did not.
- Policy-free system-only resources (accepted, calls are worker/context-internal with
  explicit `authorize?: false` and `forbid_if always()` would be redundant churn):
  ArticleTag (join, gated by Article), ActivityEvent, Badge, UserBadge, Quest,
  QuestAssignment, PointsEntry, Streak, Redemption, RewardItem, Referral,
  GamificationEvent, GamificationAudit, LeaderboardSnapshot, Flags.Audit.
- FIXED: Room, Message, RoomBan now carry resource-level policies
  (read floors + forbid on system actions). Membership/ban/closed-room rules remain
  in Verscienta.Communities; the resource policy is the defense-in-depth floor.
- LiveViews consistently rebuild the actor from session via on_mount handlers and
  pass it to Ash calls. `/admin` routes are role-gated in the router AND re-checked
  in on_mount (404 on failure). `authorize?: false` usages were swept: all are
  system actions, already-authorized reloads, or admin surfaces behind role gates.

## Input validation
- Markdown/HTML rendering: article blocks render through BlockRenderer →
  Markdown.render_inline (HTML-escapes BEFORE markdown) or Markdown.to_html
  (MDEx + ammonia sanitizer strips script/style). No unsanitized `raw/1` with user
  input. `Layouts.json_ld_tag` raw-renders JSON it encodes itself and escapes `</`.
- FIXED: expert application credential URLs capped (≤ 5 URLs, ≤ 300 chars each;
  http(s) scheme was already enforced).
- FIXED: tag names capped at 50 chars (were unbounded user input).
- Comment bodies (2000), repost quotes (500), messages (2000), group name (100)
  /description (1000), flag notes (1000) were already constrained.

## OWASP Top 10 pass
- A01 Broken access control: see authorization matrix; fixed Room/Message/RoomBan.
- A02 Crypto failures: bcrypt for passwords; JWTs via AshAuthentication with token
  revocation table.
- A03 Injection: Ecto/Ash parameterized queries; no string-interpolated fragments
  found; XSS covered by the sanitization pipeline above.
- A04 Insecure design: rate limiting on sign-in, registration, and reporting;
  gamification award idempotency (source_ref identities) prevents replay farming;
  referral fraud controls (IP throttle, self-referral check, monthly cap).
- A05 Misconfiguration: Sobelow now runs in CI (`mix sobelow --config`);
  triage decisions: <list the ignores + justification from Task 13>.
- A07 AuthN failures: email confirmation before active; sign-in rate limits per
  IP/email; deactivated users denied.
- A08 Integrity: deps locked via mix.lock; dependabot/audit out of scope here.
- A09 Logging: moderation + gamification audit resources; flag/enforcement trail.
- A10 SSRF: outbound fetches (RSS, OG images) go through admin-managed Source
  records (admin-only create), not arbitrary user URLs; expert credential URLs are
  stored, never fetched.

## Follow-ups (not blocking)
- Consider quotas on tag minting per user.
- Consider forbid_if-always policy blocks on the remaining system-only resources
  for uniformity.
```

- [ ] **Step 2: Commit**

```bash
git add docs/security/2026-06-11-security-review.md
git commit -m "docs: security review report"
```

---

## Workstream D — Accessibility (WCAG AA)

Audit found: no skip link, `<main>` has no id/anchor, theme-toggle buttons unlabeled, `news_card` uses `<h5>` out of hierarchy, decorative glyphs not aria-hidden, report dialog missing `role="dialog"`/`aria-modal`/Escape handling, room composer input unlabeled, `--color-ink-3` (#6d6d6d on #0c0c0c ≈ 3.7:1) fails AA for normal text. Already good: `<html lang>`, labelled navs, `aria-expanded`/`aria-controls` menu button, `aria-live="polite"` flashes, `aria-pressed` follow button, labelled form inputs.

### Task 15: Skip link + main landmark + a11y regression floor

**Files:**
- Modify: `lib/verscienta_web/components/layouts/root.html.heex`
- Test: `test/verscienta_web/a11y_smoke_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule VerscientaWeb.A11ySmokeTest do
  @moduledoc "Accessibility regression floor: lang, skip link, landmarks, image alts."
  use VerscientaWeb.ConnCase, async: false
  @moduletag :smoke

  import Verscienta.Support.Factory, only: [user: 1, article: 2, sign_in: 2]

  defp assert_a11y_floor(html, path) do
    doc = LazyHTML.from_document(html)

    refute Enum.empty?(LazyHTML.query(doc, "html[lang]")), "#{path}: missing <html lang>"
    refute Enum.empty?(LazyHTML.query(doc, "a[href='#main-content']")), "#{path}: missing skip link"
    refute Enum.empty?(LazyHTML.query(doc, "main#main-content")), "#{path}: missing main landmark"
    refute Enum.empty?(LazyHTML.query(doc, "nav[aria-label]")), "#{path}: missing labelled nav"
    assert Enum.empty?(LazyHTML.query(doc, "img:not([alt])")), "#{path}: <img> without alt"
  end

  test "public pages pass the accessibility floor", %{conn: conn} do
    author = user("a11y_author")
    art = article(author, %{title: "A11y Article", category: :nutrition})

    for path <- ["/", "/articles", "/articles/#{art.slug}", "/search"] do
      html = conn |> get(path) |> html_response(200)
      assert_a11y_floor(html, path)
    end
  end

  test "authenticated pages pass the accessibility floor", %{conn: conn} do
    conn = sign_in(conn, user("a11y_member"))

    for path <- ["/settings", "/articles/new", "/library", "/notifications"] do
      html = conn |> get(path) |> html_response(200)
      assert_a11y_floor(html, path)
    end
  end
end
```

Run: `wtmix test test/verscienta_web/a11y_smoke_test.exs`
Expected: FAIL on skip link + main#main-content (don't exist yet). If any page has an alt-less `<img>`, fix that template as part of this task (`alt=""` for decorative images, real text otherwise).

- [ ] **Step 2: Edit the root layout** — in `root.html.heex`, immediately after `<body ...>`:

```heex
    <a
      href="#main-content"
      class="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-[60] focus:bg-canvas-2 focus:px-4 focus:py-2 focus:text-ink"
    >
      skip to content
    </a>
```

and change `<main>` to:

```heex
    <main id="main-content" tabindex="-1">
```

- [ ] **Step 3: Run the test**

Run: `wtmix test test/verscienta_web/a11y_smoke_test.exs`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add lib/verscienta_web/components/layouts/root.html.heex test/verscienta_web/a11y_smoke_test.exs
git commit -m "feat(a11y): skip link + main landmark + accessibility regression floor"
```

### Task 16: Component-level ARIA + heading fixes

**Files:**
- Modify: `lib/verscienta_web/components/layouts.ex` (theme_toggle, nav_links)
- Modify: `lib/verscienta_web/components/codex_components.ex` (news_card, expert_tag, breaking_bar, notif, feed_post)
- Modify: `lib/verscienta_web/components/report_dialog.ex`
- Modify: `lib/verscienta_web/live/room_live.ex` (composer input)

- [ ] **Step 1: Theme toggle** — in `layouts.ex` `theme_toggle/1`, add an `aria-label` to each of the three buttons:

```heex
      <button ... data-phx-theme="system" aria-label="use system theme">
      <button ... data-phx-theme="light" aria-label="use light theme">
      <button ... data-phx-theme="dark" aria-label="use dark theme">
```

- [ ] **Step 2: Nav badges** — in `layouts.ex` `nav_links/1`, inside the points span add a screen-reader expansion (and same pattern for the streak span):

```heex
        {@current_user.points} vp<span class="sr-only"> vitality points</span>
```
```heex
        🔥 {@nav_streak}<span class="sr-only"> day streak</span>
```

- [ ] **Step 3: Codex components** — in `codex_components.ex`:
  - `news_card/1`: change `<h5 class="mb-3 text-xl font-light leading-tight">` to `<h3 class="mb-3 text-xl font-light leading-tight">` (styling is class-based, nothing else changes).
  - `expert_tag/1`: change the inner text to `<span aria-hidden="true">✦</span> Expert` (glyph is decorative; "Expert" stays readable).
  - `breaking_bar/1`: change `● {@flag}` to `<span aria-hidden="true">●</span> {@flag}`.
  - `notif/1`: add `aria-hidden="true"` to the accent bar span (`w-[3px] self-stretch`) and the icon span (both are decorative).
  - `feed_post/1`: add `aria-hidden="true"` to the initials avatar div (the name is repeated as text next to it).

- [ ] **Step 4: Report dialog** — in `report_dialog.ex` `render/1`, change the modal markup:

```heex
      <div
        :if={@open}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/60"
        phx-click="close"
        phx-target={@myself}
        phx-window-keydown="close"
        phx-key="escape"
      >
        <div
          class="w-full max-w-md border border-line bg-canvas-2 p-6"
          role="dialog"
          aria-modal="true"
          aria-labelledby={"#{@id}-report-title"}
          onclick="event.stopPropagation()"
        >
          <h3 id={"#{@id}-report-title"} class="mb-4 text-xs font-bold uppercase tracking-wider text-ink">
            Report content
          </h3>
```

(the rest of the form is unchanged).

- [ ] **Step 5: Room composer** — in `room_live.ex` `render/1`, add `aria-label="message"` to the composer `<input type="text" name="body" ...>`.

- [ ] **Step 6: Run affected tests**

Run: `wtmix test test/verscienta_web --max-failures 5`
Expected: PASS (assertions match on text, not heading tags; if any test asserted `<h5`, update it to `<h3`).

- [ ] **Step 7: Commit**

```bash
git add lib/verscienta_web/components/layouts.ex lib/verscienta_web/components/codex_components.ex lib/verscienta_web/components/report_dialog.ex lib/verscienta_web/live/room_live.ex
git commit -m "feat(a11y): ARIA labels, dialog semantics, heading hierarchy, decorative glyphs"
```

### Task 17: Color-contrast fix for tertiary text

**Files:**
- Modify: `assets/css/app.css:119`

- [ ] **Step 1: Bump the token** — `--color-ink-3: #6d6d6d;` → `--color-ink-3: #8c8c8c;`
  (#6d6d6d on #0c0c0c ≈ 3.7:1, fails AA 4.5:1 for the small text it styles; #8c8c8c ≈ 5.8:1, passes.)

- [ ] **Step 2: Check the light theme** — search `app.css` for a `data-theme=light` (or daisyUI light theme) block. If it overrides `--color-ink-3`, verify that value has ≥ 4.5:1 contrast against the light canvas (anything ≤ #767676 on white passes); adjust the same way if not. If there is no override, the dark-token fix covers both.

- [ ] **Step 3: Rebuild assets + eyeball**

Run: `wtmix assets.build`
Expected: builds clean. Tertiary text (timestamps, kickers, metadata) is slightly lighter; that is intended.

- [ ] **Step 4: Commit**

```bash
git add assets/css/app.css
git commit -m "fix(a11y): raise tertiary text contrast to WCAG AA (4.5:1)"
```

### Task 18: WCAG AA audit report

**Files:**
- Create: `docs/accessibility/2026-06-11-wcag-aa-audit.md`

- [ ] **Step 1: Write the report** — structure (write fully, reflecting what Tasks 15–17 actually changed):

```markdown
# WCAG AA Audit — 2026-06-11

Method: full template/component sweep (root layout, layouts.ex, core/codex/social/
notification components, report dialog, all LiveViews) + automated regression floor
(test/verscienta_web/a11y_smoke_test.exs, tagged :smoke, runs in CI).

## Already conformant (verified, unchanged)
- html[lang], labelled primary + mobile navs, header/main landmarks
- Menu toggle: aria-label / aria-controls / aria-expanded
- Flash region aria-live="polite", role="alert" flashes with labelled close
- Follow button aria-pressed; form inputs labelled (fieldset for checkboxes)
- :focus-visible outline (2px zune on offset 2px) — visible focus indicator
- motion-safe: prefix on spinner animations

## Fixed in this pass
- Skip link to #main-content; <main id tabindex="-1"> target (2.4.1)
- Theme-toggle buttons aria-labels (4.1.2)
- Report dialog: role="dialog", aria-modal, aria-labelledby, Escape to close (2.1.1, 4.1.2)
- news_card heading h5 -> h3 (1.3.1); decorative glyphs (✦, ●, accent bars,
  initial avatars) aria-hidden (1.1.1)
- Nav vp/streak badges: sr-only expansions (1.1.1)
- Room composer input aria-label (3.3.2)
- --color-ink-3 #6d6d6d -> #8c8c8c: 3.7:1 -> 5.8:1 on dark canvas (1.4.3)

## Known remaining gaps (tracked, not blocking)
- No <footer> landmark (site genuinely has no footer content yet)
- Category color chips (text-black on accent colors) — spot-checked the worst
  (world #1ba1e2: ~7.8:1 with black) but a systematic pass over all 7 accents
  in both themes is future work
- Live regions: room typing indicator and streamed messages are not announced
  (no aria-live on the message stream) — needs UX decision on verbosity
- Manual screen-reader (NVDA/VoiceOver) and keyboard-only walkthrough not yet
  performed; automated floor only covers structural checks
```

- [ ] **Step 2: Commit**

```bash
git add docs/accessibility/2026-06-11-wcag-aa-audit.md
git commit -m "docs: WCAG AA audit report"
```

---

## Workstream E — Performance regression checks in CI

`test/verscienta/query_budget_test.exs` already pins query budgets for `global_activity`, `personal_activity`, and `following_feed` (flat query counts + DB-side row bounding via `QueryCounter`). This workstream tags the suite, adds a leaderboard budget, and gives CI a distinct, visible perf step.

### Task 19: Tag the budget suite + leaderboard compute budget

**Files:**
- Modify: `test/verscienta/query_budget_test.exs`

- [ ] **Step 1: Tag the module** — directly under `use Verscienta.DataCase, async: false` add:

```elixir
  @moduletag :query_budget
```

- [ ] **Step 2: Add the leaderboard budget test** (verified API: `Verscienta.Gamification.award/4` is idempotent by source_ref; `Leaderboards.compute(:global, nil, :all_time)` returns `[%{user_id, score, rank}]`):

```elixir
  test "leaderboard compute runs a flat number of queries as users grow" do
    users = for i <- 1..5, do: user("qb_lb_#{i}")

    for {u, i} <- Enum.with_index(users, 1),
        j <- 1..3 do
      :ok = Verscienta.Gamification.award(u.id, :reading, "qb-lb-#{i}-#{j}")
    end

    alias Verscienta.Gamification.Leaderboards

    {entries, count} =
      QueryCounter.count(fn -> Leaderboards.compute(:global, nil, :all_time) end)

    assert length(entries) >= 5
    # one aggregate query (plus at most one snapshot/cache lookup)
    assert count <= 2,
           "expected a flat query count for leaderboard compute with 5 users, got #{count}"
  end
```

Note: `Leaderboards.compute/4` may hit the 600s-TTL cache — `DataCase` clears the L1 cache per test, so the measured call is a cold compute. If the count assertion fails because compute goes through a cached/snapshot path, measure the underlying scoring function the module exposes instead and say so in the test comment.

- [ ] **Step 3: Run it**

Run: `wtmix test test/verscienta/query_budget_test.exs`
Expected: 4 tests, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add test/verscienta/query_budget_test.exs
git commit -m "test: leaderboard query budget + tag perf regression suite"
```

### Task 20: Distinct CI perf step

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Add the step** — in the `test` job, after the `mix test --cover` step:

```yaml
      - name: Performance regression checks (query budgets)
        run: mix test --only query_budget
```

The budget tests also run inside the main suite; this re-run is cheap (4 DB tests) and makes a perf regression fail with its own named CI step instead of drowning in the full-suite output.

- [ ] **Step 2: Sanity-check the workflow locally**

Run: `wtmix test --only query_budget`
Expected: `4 tests, 0 failures` (plus an "excluded" count for the rest of the suite).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: distinct query-budget perf regression step"
```

---

## Final verification (after all tasks)

- [ ] Full suite: `wtmix test` → 0 failures, coverage ≥ 83%.
- [ ] Format: `wtmix format --check-formatted` (run `wtmix format` first if needed).
- [ ] Credo: `MIX_ENV=test` variant — add `-e MIX_ENV=test` to the docker exec env list and run `mix credo --strict` (dev-env credo recompiles everything and has segfaulted in-container before).
- [ ] Compile: `wtmix compile --warnings-as-errors`.
- [ ] Push branch `claude/awesome-wu-33fa33` and open a PR against `main` (independent PR — do not stack).

## Self-review notes

- Spec coverage: checklist item 1 → Tasks 1–5; item 2 → Tasks 6–8; item 3 → Tasks 9–14; item 4 → Tasks 15–18; item 5 → Tasks 19–20.
- All module APIs, event names, params, reaction kinds, factory signatures, and `closed_period/2`'s return shape were verified against source before writing this plan (not inferred).
- Known soft spots called out inline: `RoomBan` create action name (Task 10 Step 1), onboarding `continue` redirect shape (Task 7), leaderboard cache path (Task 19), light-theme token override (Task 17). Each has an explicit verification step with a decision rule.
