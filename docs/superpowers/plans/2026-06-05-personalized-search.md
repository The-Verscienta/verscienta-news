# Personalized Search Ranking Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-rank search results for signed-in viewers by blending Meilisearch relevance with category interest + semantic taste; anonymous viewers keep today's order.

**Architecture:** A pure `Search.Ranking` blends `_rankingScore` with a bounded personalization bonus (`relevance + β·personal`, β 0.2). `Search.search/2` gains a `:user` opt: for personalized viewers it fetches a scored 40-hit window, loads the affinity profile + hit embeddings, re-ranks, and trims to the page size. Anonymous path is unchanged.

**Tech Stack:** Elixir, Ash 3, Meilisearch (via `Search.Client` behaviour + `ClientStub`), `Recommendations` (AffinityProfile, Vector), Phoenix LiveView. All `mix` runs in Docker: `docker compose exec -T app mix …`.

**Spec:** `docs/superpowers/specs/2026-06-05-personalized-search-design.md`
**Branch:** `phase-3-personalized-search` (spec already committed here).

---

## File Structure

**Create:**
- `lib/verscienta/search/ranking.ex` — pure `rerank/4`, `blended_score/4`, `default_beta/0`.
- `test/verscienta/search/ranking_test.exs`

**Modify:**
- `lib/verscienta/recommendations.ex` — public `affinity_profile/1` delegate.
- `lib/verscienta/search.ex` — `:user` opt, personalized window + re-rank + embeddings load.
- `lib/verscienta_web/live/search_live.ex` — pass `current_user`.
- Tests: `for_you_test.exs` (delegate), `search/search_test.exs` (personalized/anonymous/fallback), `search_live_test.exs` (logged-in reorder).
- `docs/todo.md` — check off the personalized-search item.

---

## Task 1: `Search.Ranking` (pure re-rank)

**Files:**
- Create: `lib/verscienta/search/ranking.ex`
- Test: `test/verscienta/search/ranking_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/search/ranking_test.exs`:
```elixir
defmodule Verscienta.Search.RankingTest do
  use ExUnit.Case, async: true

  alias Verscienta.Search.Ranking

  # Minimal profile shape Ranking depends on.
  defp profile(opts \\ []) do
    %{
      followed_categories: Keyword.get(opts, :followed, MapSet.new()),
      category_affinity: Keyword.get(opts, :affinity, %{}),
      taste_vector: Keyword.get(opts, :taste, nil)
    }
  end

  defp hit(id, category, score), do: %{"id" => id, "category" => category, "_rankingScore" => score}

  test "default_beta/0 is 0.2" do
    assert Ranking.default_beta() == 0.2
  end

  test "nil profile leaves order unchanged" do
    hits = [hit("a", "nutrition", 0.5), hit("b", "herbalism", 0.4)]
    assert Ranking.rerank(hits, nil, %{}) == hits
  end

  test "breaks an equal-relevance tie toward a followed category" do
    a = hit("a", "herbalism", 0.5)
    b = hit("b", "nutrition", 0.5)
    p = profile(followed: MapSet.new([:nutrition]))
    assert [%{"id" => "b"}, %{"id" => "a"}] = Ranking.rerank([a, b], p, %{})
  end

  test "breaks an equal-relevance tie toward semantic taste" do
    a = hit("a", "herbalism", 0.5)
    b = hit("b", "herbalism", 0.5)
    p = profile(taste: [1.0, 0.0, 0.0])
    embeddings = %{"a" => [0.0, 1.0, 0.0], "b" => [1.0, 0.0, 0.0]}
    assert [%{"id" => "b"}, %{"id" => "a"}] = Ranking.rerank([a, b], p, embeddings)
  end

  test "relevance dominates: a large relevance gap is not overcome by personalization" do
    weak_but_loved = hit("a", "nutrition", 0.5)
    strong = hit("b", "herbalism", 0.9)
    # a has max personal (followed category + perfect taste); still loses to b's relevance.
    p = profile(followed: MapSet.new([:nutrition]), taste: [1.0, 0.0, 0.0])
    embeddings = %{"a" => [1.0, 0.0, 0.0], "b" => [0.0, 1.0, 0.0]}
    assert [%{"id" => "b"}, %{"id" => "a"}] = Ranking.rerank([weak_but_loved, strong], p, embeddings)
  end

  test "missing embedding / nil taste contributes 0 (no crash)" do
    a = hit("a", "nutrition", 0.5)
    p = profile(taste: nil)
    assert [%{"id" => "a"}] = Ranking.rerank([a], p, %{})
  end

  test "stable among full ties (preserves input order)" do
    a = hit("a", "herbalism", 0.5)
    b = hit("b", "herbalism", 0.5)
    p = profile()
    assert [%{"id" => "a"}, %{"id" => "b"}] = Ranking.rerank([a, b], p, %{})
  end
end
```

- [ ] **Step 2: Run it (fails — module undefined)**

`docker compose exec -T app mix test test/verscienta/search/ranking_test.exs` → FAIL.

- [ ] **Step 3: Implement**

Create `lib/verscienta/search/ranking.ex`:
```elixir
defmodule Verscienta.Search.Ranking do
  @moduledoc """
  Pure personalization re-ranking for search hits. Blends Meilisearch relevance
  (`_rankingScore`) with a bounded personalization bonus from the viewer's
  category interest and semantic taste. Relevance-dominant: a relevance gap
  larger than `beta` cannot be overcome by personalization. No DB, no Meili —
  takes everything it needs as arguments.
  """

  alias Verscienta.Recommendations.Vector

  @default_beta 0.2

  @doc "The default personalization strength (relevance-dominant)."
  @spec default_beta() :: float()
  def default_beta, do: @default_beta

  @doc """
  Reorder Meili hit maps by descending blended score, stable among ties
  (preserving input order). `embeddings` is `%{id => [float]}` for the hits.
  A nil profile returns `hits` unchanged.
  """
  @spec rerank([map()], map() | nil, %{optional(String.t()) => [float()]}, keyword()) :: [map()]
  def rerank(hits, profile, embeddings, opts \\ [])
  def rerank(hits, nil, _embeddings, _opts), do: hits

  def rerank(hits, profile, embeddings, opts) do
    beta = Keyword.get(opts, :beta, @default_beta)

    hits
    |> Enum.with_index()
    |> Enum.sort_by(fn {hit, idx} -> {-blended_score(hit, profile, embeddings, beta), idx} end)
    |> Enum.map(fn {hit, _idx} -> hit end)
  end

  @doc "Blended relevance + personalization score for a single hit."
  @spec blended_score(map(), map(), %{optional(String.t()) => [float()]}, float()) :: float()
  def blended_score(hit, profile, embeddings, beta) do
    relevance = hit["_rankingScore"] || 0.0
    relevance + beta * personal(hit, profile, embeddings)
  end

  defp personal(hit, profile, embeddings) do
    (interest(hit, profile) + taste(hit, profile, embeddings)) / 2
  end

  defp interest(hit, profile) do
    cat = safe_atom(hit["category"])
    explicit = if MapSet.member?(profile.followed_categories, cat), do: 1.0, else: 0.0
    affinity = Map.get(profile.category_affinity, cat, 0.0)
    clamp01((explicit + affinity) / 2)
  end

  defp taste(hit, profile, embeddings) do
    emb = Map.get(embeddings, hit["id"])
    clamp01(Vector.cosine(emb, profile.taste_vector))
  end

  defp clamp01(x), do: x |> max(0.0) |> min(1.0)

  defp safe_atom(nil), do: nil
  defp safe_atom(v) when is_atom(v), do: v

  defp safe_atom(v) when is_binary(v) do
    String.to_existing_atom(v)
  rescue
    ArgumentError -> nil
  end
end
```

- [ ] **Step 4: Run the test (passes)**

`docker compose exec -T app mix test test/verscienta/search/ranking_test.exs` → PASS (7 tests).

- [ ] **Step 5: format, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix credo --strict lib/verscienta/search/ranking.ex 2>&1 | tail -4
git add lib/verscienta/search/ranking.ex test/verscienta/search/ranking_test.exs
git commit -m "feat(search): pure Ranking — relevance-dominant personalization blend"
```

---

## Task 2: `Recommendations.affinity_profile/1` accessor

**Files:**
- Modify: `lib/verscienta/recommendations.ex`
- Test: `test/verscienta/recommendations/for_you_test.exs`

- [ ] **Step 1: Add the failing test**

In `test/verscienta/recommendations/for_you_test.exs`, add (before the final `end`; the file has `user/1`):
```elixir
  test "affinity_profile/1 exposes the cached profile" do
    me = user("affexposed")
    p = Recommendations.affinity_profile(me)
    assert Map.has_key?(p, :taste_vector)
    assert %MapSet{} = p.followed_categories
    assert is_map(p.category_affinity)
  end
```

- [ ] **Step 2: Run it (fails — no affinity_profile/1)**

`docker compose exec -T app mix test test/verscienta/recommendations/for_you_test.exs` → FAIL (UndefinedFunctionError).

- [ ] **Step 3: Implement**

In `lib/verscienta/recommendations.ex`, add a public delegate next to the other `defdelegate`s (e.g. right after the `related/2` delegate). `AffinityProfile` is already aliased:
```elixir
  @doc "The viewer's cached affinity profile (followed/affinity categories + tags + taste vector)."
  @spec affinity_profile(map()) :: AffinityProfile.profile()
  defdelegate affinity_profile(user), to: AffinityProfile, as: :for_user
```

- [ ] **Step 4: Run the test (passes)**

`docker compose exec -T app mix test test/verscienta/recommendations/for_you_test.exs` → PASS.

- [ ] **Step 5: format, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix credo --strict lib/verscienta/recommendations.ex 2>&1 | tail -4
git add lib/verscienta/recommendations.ex test/verscienta/recommendations/for_you_test.exs
git commit -m "feat(recommendations): public affinity_profile/1 accessor"
```

---

## Task 3: `Search.search/2` personalization

**Files:**
- Modify: `lib/verscienta/search.ex`
- Test: `test/verscienta/search/search_test.exs`

- [ ] **Step 1: Add failing tests + helpers**

In `test/verscienta/search/search_test.exs`, add these helpers (near the existing `author/0`, `publish/2`):
```elixir
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

  defp vec(head), do: head ++ List.duplicate(0.0, 768 - length(head))

  defp set_embedding(article, embedding) do
    article
    |> Ash.Changeset.for_update(:set_embedding, %{embedding: embedding}, authorize?: false)
    |> Ash.update!()
  end

  defp bookmark(actor, article) do
    Verscienta.Engagement.Bookmark
    |> Ash.ActionInput.for_action(:toggle, %{article_id: article.id}, actor: actor)
    |> Ash.run_action!()
  end
```
And these tests (this file already defines `publish/3` as `(author, title, category)` and `author/0`; the calls below use that `publish/3`):
```elixir
  test "personalized user re-ranks the scored window by interest/taste; trims to per_page" do
    me = user("psearcher")
    author = user("psearchauthor")
    na = publish(author, "Nutrition Result", :nutrition) |> set_embedding(vec([1.0, 0.0, 0.0]))
    ha = publish(author, "Herbal Result", :herbalism) |> set_embedding(vec([0.0, 1.0, 0.0]))
    # signal: a nutrition bookmark → category affinity + taste centroid near na
    bookmark(me, na)

    Application.put_env(:verscienta, :search_stub, %{
      search:
        {:ok,
         %{
           "hits" => [
             %{"id" => ha.id, "title" => "Herbal Result", "slug" => "h", "category" => "herbalism", "_rankingScore" => 0.5},
             %{"id" => na.id, "title" => "Nutrition Result", "slug" => "n", "category" => "nutrition", "_rankingScore" => 0.5}
           ],
           "facetDistribution" => %{},
           "estimatedTotalHits" => 2
         }}
    })

    result = Search.search("result", user: me, per_page: 1)

    assert result.source == :meili
    # na (boosted by interest + taste) is re-ranked above ha, and trimmed to per_page (1)
    assert [%{"id" => id}] = result.hits
    assert id == na.id

    [{:search, [_idx, params]}] = Enum.filter(ClientStub.calls(), &(elem(&1, 0) == :search))
    assert params["showRankingScore"] == true
    assert params["limit"] == 40
  end

  test "anonymous user gets Meili order untouched and no scored window" do
    Application.put_env(:verscienta, :search_stub, %{
      search:
        {:ok,
         %{
           "hits" => [
             %{"id" => "h", "title" => "Herbal Result", "slug" => "h", "category" => "herbalism", "_rankingScore" => 0.5},
             %{"id" => "n", "title" => "Nutrition Result", "slug" => "n", "category" => "nutrition", "_rankingScore" => 0.9}
           ],
           "facetDistribution" => %{},
           "estimatedTotalHits" => 2
         }}
    })

    result = Search.search("result")

    assert Enum.map(result.hits, & &1["id"]) == ["h", "n"]
    [{:search, [_idx, params]}] = Enum.filter(ClientStub.calls(), &(elem(&1, 0) == :search))
    refute params["showRankingScore"] == true
    assert params["limit"] == 20
  end

  test "personalized + meili error falls back to postgres (un-personalized)" do
    me = user("pfallback")
    author = user("pfallauthor")
    _ = publish(author, "Findable Fallback Piece", :nutrition)
    bookmark(me, publish(author, "Signal Piece", :nutrition))
    Application.put_env(:verscienta, :search_stub, %{search: {:error, :down}})

    result = Search.search("Findable", user: me)
    assert result.source == :postgres
    assert Enum.any?(result.hits, &(&1["title"] =~ "Findable"))
  end
```

- [ ] **Step 2: Run it (fails — :user opt ignored)**

`docker compose exec -T app mix test test/verscienta/search/search_test.exs` → the new tests FAIL.

- [ ] **Step 3: Implement**

In `lib/verscienta/search.ex`:

(a) Add aliases (alphabetical within the group; `Article` is referenced twice after this change, so alias it to satisfy credo `AliasUsage`):
```elixir
  alias Verscienta.Content.Article
  alias Verscienta.Recommendations
  alias Verscienta.Search.Client
  alias Verscienta.Search.Index
  alias Verscienta.Search.Ranking
```
(Keep the existing `Client`/`Index` aliases — just add `Article`, `Recommendations`, `Ranking`.)

(b) Add the window attribute near `@per_page`:
```elixir
  @window 40
```

(c) Replace `search/2` and add the personalization helpers:
```elixir
  def search(query, opts \\ []) do
    page = max(opts[:page] || 1, 1)
    per_page = opts[:per_page] || @per_page
    category = opts[:category]
    tags = opts[:tags] || []
    user = opts[:user]

    if personalize?(user, page) do
      personalized_search(query, category, tags, page, per_page, user)
    else
      params = build_params(query, category, tags, page, per_page)

      case Client.search(Index.name(), params) do
        {:ok, resp} -> map_meili(resp, page)
        {:error, _reason} -> fallback(query, category, page, per_page)
      end
    end
  end

  defp personalize?(nil, _page), do: false
  defp personalize?(_user, page) when page > 1, do: false
  defp personalize?(user, _page), do: Recommendations.personalized?(user)

  defp personalized_search(query, category, tags, page, per_page, user) do
    params =
      query
      |> build_params(category, tags, page, @window)
      |> Map.put("showRankingScore", true)

    case Client.search(Index.name(), params) do
      {:ok, resp} ->
        hits = resp["hits"] || []
        profile = Recommendations.affinity_profile(user)
        embeddings = load_embeddings(Enum.map(hits, & &1["id"]))
        ranked = hits |> Ranking.rerank(profile, embeddings) |> Enum.take(per_page)
        %{map_meili(resp, page) | hits: ranked}

      {:error, _reason} ->
        fallback(query, category, page, per_page)
    end
  end

  defp load_embeddings([]), do: %{}

  defp load_embeddings(ids) do
    Article
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(authorize?: false)
    |> Map.new(fn a -> {to_string(a.id), embedding_list(a.embedding)} end)
    |> Map.reject(fn {_id, emb} -> is_nil(emb) end)
  end

  defp embedding_list(nil), do: nil
  defp embedding_list(%Ash.Vector{} = v), do: Ash.Vector.to_list(v)
```

(d) In the existing `fallback/4`, the line `Verscienta.Content.Article` becomes `Article` (now aliased):
```elixir
    base =
      Article
      |> Ash.Query.filter(status == :published and is_nil(group_id))
```

- [ ] **Step 4: Run the test (passes) + the full search test file**

`docker compose exec -T app mix test test/verscienta/search/search_test.exs` → PASS (existing 4 + 3 new; the anonymous/fallback existing tests are unaffected since `:user` defaults to nil).

- [ ] **Step 5: format, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix credo --strict lib/verscienta/search.ex 2>&1 | tail -4
git add lib/verscienta/search.ex test/verscienta/search/search_test.exs
git commit -m "feat(search): personalized re-rank of a scored Meili window for signed-in viewers"
```

---

## Task 4: `SearchLive` wiring + LiveView test

**Files:**
- Modify: `lib/verscienta_web/live/search_live.ex`
- Test: `test/verscienta_web/live/search_live_test.exs`

- [ ] **Step 1: Add the failing LiveView test + helpers**

In `test/verscienta_web/live/search_live_test.exs`, add helpers (the file currently has none; add after the `setup` block):
```elixir
  alias AshAuthentication.Plug.Helpers

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

  defp sign_in(conn, u),
    do: conn |> Plug.Test.init_test_session(%{}) |> Helpers.store_in_session(u)

  defp publish(a, title, category) do
    {:ok, article} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: title, blocks: [], category: category}, actor: a)
      |> Ash.create()

    {:ok, p} = article |> Ash.Changeset.for_update(:publish, %{}, actor: a) |> Ash.update()
    p
  end
```
And the test:
```elixir
  test "a personalized signed-in user gets re-ranked results", %{conn: conn} do
    me = user("searchfan")
    author = user("searchfanauthor")
    na = publish(author, "Nutrition Result", :nutrition)
    _ha = publish(author, "Herbal Result", :herbalism)

    # signal: bookmark a nutrition article → category affinity for :nutrition
    Verscienta.Engagement.Bookmark
    |> Ash.ActionInput.for_action(:toggle, %{article_id: na.id}, actor: me)
    |> Ash.run_action!()

    Application.put_env(:verscienta, :search_stub, %{
      search:
        {:ok,
         %{
           "hits" => [
             %{"id" => _ha.id, "title" => "Herbal Result", "slug" => "h", "excerpt" => "x", "category" => "herbalism", "_rankingScore" => 0.5},
             %{"id" => na.id, "title" => "Nutrition Result", "slug" => "n", "excerpt" => "x", "category" => "nutrition", "_rankingScore" => 0.5}
           ],
           "facetDistribution" => %{},
           "estimatedTotalHits" => 2
         }}
    })

    {:ok, lv, _html} = conn |> sign_in(me) |> live(~p"/search")
    html = lv |> form("#search-form", %{"q" => "result"}) |> render_change()

    pos_n = :binary.match(html, "Nutrition Result") |> elem(0)
    pos_h = :binary.match(html, "Herbal Result") |> elem(0)
    # personalization re-ranked the nutrition hit above the herbal one (stub returned herbal first)
    assert pos_n < pos_h
  end
```

- [ ] **Step 2: Run it (fails — user not passed → Meili order preserved → herbal first)**

`docker compose exec -T app mix test test/verscienta_web/live/search_live_test.exs` → the new test FAILS (`pos_n < pos_h` false, since without the user there's no re-rank).

- [ ] **Step 3: Implement**

In `lib/verscienta_web/live/search_live.ex`, pass `user: socket.assigns.current_user` in all three `Search.search` calls:
```elixir
  def handle_event("search", params, socket) do
    query = params["q"] || ""
    results = Search.search(query, category: socket.assigns.category, page: 1, user: socket.assigns.current_user)
    {:noreply, assign(socket, query: query, results: results)}
  end

  def handle_event("toggle_category", %{"category" => cat}, socket) do
    key = parse_category(cat)
    new_cat = if socket.assigns.category == key, do: nil, else: key
    results = Search.search(socket.assigns.query, category: new_cat, page: 1, user: socket.assigns.current_user)
    {:noreply, assign(socket, category: new_cat, results: results)}
  end

  def handle_event("clear", _params, socket) do
    results = Search.search(socket.assigns.query, category: nil, page: 1, user: socket.assigns.current_user)
    {:noreply, assign(socket, category: nil, results: results)}
  end
```
(`current_user` is assigned by the `:live_user_optional` on_mount; nil for anonymous → unchanged behavior.)

- [ ] **Step 4: Run the test (passes) + the full search_live file**

`docker compose exec -T app mix test test/verscienta_web/live/search_live_test.exs` → PASS (existing anonymous tests + the new one).

- [ ] **Step 5: format, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix credo --strict lib/verscienta_web/live/search_live.ex 2>&1 | tail -4
git add lib/verscienta_web/live/search_live.ex test/verscienta_web/live/search_live_test.exs
git commit -m "feat(search): pass the current user from SearchLive for personalized ranking"
```

---

## Task 5: Docs + full verification

**Files:** Modify `docs/todo.md`

- [ ] **Step 1: Check off the todo item**

In `docs/todo.md`, under "### Recommendation & Personalization", find:
`- [ ] Personalized search ranking.` (or the closest personalized-search bullet) and change it to:
`- [x] Personalized search ranking. *(re-rank Meili window by category interest + semantic taste; slice 4b)*`

- [ ] **Step 2: Full suite + format**

```bash
docker compose exec -T app bash -lc 'mix format && mix format --check-formatted && mix test 2>&1 | tail -6'
```
Expected: format clean; 0 failures. (Known flake: `NotificationBellTest` passes on re-run; if it's the only failure, re-run once.)

- [ ] **Step 3: Credo + Dialyzer**

```bash
docker compose exec -T app mix credo --strict 2>&1 | tail -4
docker compose exec -T app mix dialyzer 2>&1 | tail -8
```
Expected: credo "found no issues"; dialyzer ends "passed successfully". If dialyzer reports NEW errors (the `Ranking` specs or the `Search` map-update are the likely sources), paste them exactly and report BLOCKED — do NOT commit.

- [ ] **Step 4: Commit**

```bash
git add docs/todo.md
git commit -m "docs: check off personalized search ranking (slice 4b)"
```

- [ ] **Step 5:** Confirm all gates green — branch ready to merge.

---

## Notes for the implementer

- `Recommendations.personalized?/1` calls `AffinityProfile.for_user(user)` and would crash on `nil`; `Search.personalize?/2` guards `nil` (and `page > 1`) BEFORE calling it. Never call `personalized?` with a nil user.
- `Ranking` is pure: it takes the hit maps, the profile, and a `%{id => [float]}` embeddings map. `Search` does the impure work (profile fetch via the new `Recommendations.affinity_profile/1`, embeddings via `load_embeddings/1`).
- `load_embeddings/1` keys by `to_string(a.id)` to match Meili's string `hit["id"]`. In production Meili ids are article ids; in tests the stub MUST use real article ids (so the `id in ^ids` filter and the embeddings join line up). `embedding` is a default attribute (loaded without an explicit select); `Ash.Vector.to_list/1` converts it.
- Anonymous path is byte-for-byte the old code path (no window, no `showRankingScore`, no extra query) — the existing `search_test`/`search_live_test` anonymous cases must keep passing unchanged.
- `%{map_meili(resp, page) | hits: ranked}` reuses the existing mapper and only overrides `hits` (so `facets`/`total`/`source`/`page` stay correct — `total` is Meili's full estimate, not the window size).
- The Meili-error branch inside `personalized_search` falls back to the same `fallback/4` (un-personalized) as the anonymous path.
- `β = 0.2` lives in `Ranking` as `@default_beta`; `Search` does not pass `:beta`, so it uses the default.
