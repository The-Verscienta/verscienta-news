# For You v2 Hybrid (Semantic Taste) Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a semantic content signal to the For You ranking — a recency/type-weighted taste centroid of engaged-article embeddings, scored by cosine into the (pure) Scorer.

**Architecture:** A new pure `Recommendations.Vector` (cosine/normalize/weighted-centroid); `AffinityProfile` learns a `taste_vector`; the `Scorer` gains a precomputed `:semantic` weighted term; `for_you` computes per-candidate cosine-to-taste and threads it in. Degrades to slice-1 behavior when there's no embedding signal.

**Tech Stack:** Elixir, Ash 3 (`Ash.Vector`), `Verscienta.Cache`. All `mix` runs in Docker: `docker compose exec -T app mix …`.

**Spec:** `docs/superpowers/specs/2026-06-05-for-you-hybrid-design.md`
**Branch:** `phase-3-foryou-hybrid` (spec already committed here).

---

## File Structure

**Create:**
- `lib/verscienta/recommendations/vector.ex` — pure `cosine/2`, `normalize/1`, `weighted_centroid/1`.
- `test/verscienta/recommendations/vector_test.exs`

**Modify:**
- `lib/verscienta/recommendations/affinity_profile.ex` — taste vector in `build/4` + `load_article_index` + types.
- `lib/verscienta/recommendations/scorer.ex` — `:semantic` weight + term.
- `lib/verscienta/recommendations.ex` — per-candidate semantic in `score_for`.
- Tests: `affinity_profile_test.exs`, `scorer_test.exs`, `for_you_test.exs` (update + extend).
- `docs/todo.md` — check off the hybrid-engine item.

---

## Task 1: `Recommendations.Vector` (pure math)

**Files:**
- Create: `lib/verscienta/recommendations/vector.ex`
- Test: `test/verscienta/recommendations/vector_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/recommendations/vector_test.exs`:
```elixir
defmodule Verscienta.Recommendations.VectorTest do
  use ExUnit.Case, async: true

  alias Verscienta.Recommendations.Vector

  describe "cosine/2" do
    test "identical vectors → 1.0" do
      assert_in_delta Vector.cosine([1.0, 0.0, 0.0], [1.0, 0.0, 0.0]), 1.0, 0.0001
    end

    test "orthogonal vectors → 0.0" do
      assert_in_delta Vector.cosine([1.0, 0.0], [0.0, 1.0]), 0.0, 0.0001
    end

    test "opposite vectors → -1.0" do
      assert_in_delta Vector.cosine([1.0, 0.0], [-1.0, 0.0]), -1.0, 0.0001
    end

    test "nil or empty → 0.0" do
      assert Vector.cosine(nil, [1.0]) == 0.0
      assert Vector.cosine([1.0], nil) == 0.0
      assert Vector.cosine([], [1.0]) == 0.0
    end

    test "zero-magnitude vector → 0.0" do
      assert Vector.cosine([0.0, 0.0], [1.0, 0.0]) == 0.0
    end
  end

  describe "normalize/1" do
    test "scales to unit length" do
      [a, b] = Vector.normalize([3.0, 4.0])
      assert_in_delta a, 0.6, 0.0001
      assert_in_delta b, 0.8, 0.0001
    end

    test "zero vector unchanged" do
      assert Vector.normalize([0.0, 0.0]) == [0.0, 0.0]
    end
  end

  describe "weighted_centroid/1" do
    test "empty → nil" do
      assert Vector.weighted_centroid([]) == nil
    end

    test "unit-normalizes the weighted mean (heavier weight dominates direction)" do
      # [1,0] weighted 3, [0,1] weighted 1 → sum [3,1] → normalized ≈ [0.948, 0.316]
      [a, b] = Vector.weighted_centroid([{[1.0, 0.0], 3.0}, {[0.0, 1.0], 1.0}])
      assert a > b
      assert_in_delta :math.sqrt(a * a + b * b), 1.0, 0.0001
    end
  end
end
```

- [ ] **Step 2: Run it (fails — module undefined)**

`docker compose exec -T app mix test test/verscienta/recommendations/vector_test.exs` → FAIL.

- [ ] **Step 3: Implement the module**

Create `lib/verscienta/recommendations/vector.ex`:
```elixir
defmodule Verscienta.Recommendations.Vector do
  @moduledoc """
  Pure vector math for semantic scoring: cosine similarity, unit normalization,
  and the weighted centroid used to build a user's taste vector. Operates on
  plain float lists; no DB, no deps.
  """

  @doc "Cosine similarity of two equal-length float lists; 0.0 for nil/empty/zero-magnitude."
  @spec cosine([float()] | nil, [float()] | nil) :: float()
  def cosine(a, b) when is_list(a) and is_list(b) and a != [] and b != [] do
    mag = magnitude(a) * magnitude(b)
    if mag == 0.0, do: 0.0, else: dot(a, b) / mag
  end

  def cosine(_, _), do: 0.0

  @doc "Unit-normalize a float list; a zero vector is returned unchanged."
  @spec normalize([float()]) :: [float()]
  def normalize([]), do: []

  def normalize(vec) do
    mag = magnitude(vec)
    if mag == 0.0, do: vec, else: Enum.map(vec, &(&1 / mag))
  end

  @doc "Unit-normalized weighted mean of `[{vector, weight}]`; nil when empty."
  @spec weighted_centroid([{[float()], float()}]) :: [float()] | nil
  def weighted_centroid([]), do: nil

  def weighted_centroid(pairs) do
    case Enum.reduce(pairs, nil, fn {vec, w}, acc -> add(acc, scale(vec, w)) end) do
      nil -> nil
      sum -> normalize(sum)
    end
  end

  defp dot(a, b), do: Enum.zip_reduce(a, b, 0.0, fn x, y, acc -> acc + x * y end)
  defp magnitude(vec), do: :math.sqrt(Enum.reduce(vec, 0.0, fn x, acc -> acc + x * x end))
  defp add(nil, v), do: v
  defp add(a, b), do: Enum.zip_with(a, b, &+/2)
  defp scale(vec, s), do: Enum.map(vec, &(&1 * s))
end
```

- [ ] **Step 4: Run the test (passes)**

`docker compose exec -T app mix test test/verscienta/recommendations/vector_test.exs` → PASS (8 tests).

- [ ] **Step 5: format, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix credo --strict lib/verscienta/recommendations/vector.ex 2>&1 | tail -4
git add lib/verscienta/recommendations/vector.ex test/verscienta/recommendations/vector_test.exs
git commit -m "feat(recommendations): pure Vector math (cosine, normalize, weighted_centroid)"
```

---

## Task 2: Taste vector in `AffinityProfile`

**Files:**
- Modify: `lib/verscienta/recommendations/affinity_profile.ex`
- Test: `test/verscienta/recommendations/affinity_profile_test.exs`

- [ ] **Step 1: Add the failing test**

In `test/verscienta/recommendations/affinity_profile_test.exs`, the existing `@index` entries have `%{category:, tag_ids:}` (no embedding). Add a new test (before the final `end`) that supplies embeddings and asserts the taste vector. Use a local index with embeddings:
```elixir
  test "build/4 computes a unit-normalized weighted taste centroid from engaged embeddings" do
    follows = %{user: [], category: [], source: [], tag: []}

    index = %{
      "a1" => %{category: :nutrition, tag_ids: [], embedding: [1.0, 0.0, 0.0]},
      "a2" => %{category: :herbalism, tag_ids: [], embedding: [0.0, 1.0, 0.0]}
    }

    # a bookmark (weight 1.0) on a1 dominates a reaction (weight 0.5) on a2, same day
    engagements = [eng("a1", :bookmark, @now), eng("a2", :reaction, @now)]
    p = AffinityProfile.build(engagements, follows, index, @now)

    assert [x, y, z] = p.taste_vector
    assert x > y
    assert z == 0.0
    assert_in_delta :math.sqrt(x * x + y * y + z * z), 1.0, 0.0001
  end

  test "build/4 taste_vector is nil when no engaged article has an embedding" do
    follows = %{user: [], category: [], source: [], tag: []}
    # @index entries carry no :embedding
    p = AffinityProfile.build([eng("a1", :bookmark, @now)], follows, @index, @now)
    assert p.taste_vector == nil
  end
```
(`eng/3`, `@now`, and `@index` already exist in this test file.)

- [ ] **Step 2: Run it (fails — no taste_vector)**

`docker compose exec -T app mix test test/verscienta/recommendations/affinity_profile_test.exs` → FAIL (KeyError / nil mismatch on `taste_vector`).

- [ ] **Step 3: Implement**

In `lib/verscienta/recommendations/affinity_profile.ex`:

(a) Add the alias (with the others): `alias Verscienta.Recommendations.Vector`.

(b) Extend the types:
```elixir
  @type article_meta :: %{category: atom(), tag_ids: [term()], embedding: [float()] | nil}
  @type profile :: %{
          followed_categories: MapSet.t(),
          followed_tag_ids: MapSet.t(),
          category_affinity: %{optional(atom()) => float()},
          tag_affinity: %{optional(term()) => float()},
          taste_vector: [float()] | nil
        }
```

(c) Replace `build/4` with the taste-accumulating version:
```elixir
  def build(engagements, follows, article_index, now) do
    {cat, tag, taste_pairs} =
      Enum.reduce(engagements, {%{}, %{}, []}, fn e, {ca, ta, tp} ->
        case Map.get(article_index, e.article_id) do
          nil ->
            {ca, ta, tp}

          %{category: category, tag_ids: tag_ids} = meta ->
            w = type_weight(e.type) * decay(e.at, now)
            ca = Map.update(ca, category, w, &(&1 + w))
            ta = accumulate_tags(tag_ids, ta, w)
            tp = add_taste_pair(tp, meta[:embedding], w)
            {ca, ta, tp}
        end
      end)

    %{
      followed_categories: to_category_set(follows[:category] || []),
      followed_tag_ids: MapSet.new(follows[:tag] || []),
      category_affinity: normalize(cat),
      tag_affinity: normalize(tag),
      taste_vector: Vector.weighted_centroid(taste_pairs)
    }
  end

  defp add_taste_pair(pairs, embedding, w) when is_list(embedding), do: [{embedding, w} | pairs]
  defp add_taste_pair(pairs, _embedding, _w), do: pairs
```

(d) Replace `load_article_index/1` (the non-empty clause) to load + convert embeddings:
```elixir
  defp load_article_index(ids) do
    Article
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.load(:tags)
    |> Ash.read!(authorize?: false)
    |> Map.new(fn a ->
      {a.id, %{category: a.category, tag_ids: Enum.map(a.tags, & &1.id), embedding: to_list(a.embedding)}}
    end)
  end

  defp to_list(nil), do: nil
  defp to_list(%Ash.Vector{} = v), do: Ash.Vector.to_list(v)
```
(`embedding` is a default attribute, returned by the read without an explicit `select`.)

- [ ] **Step 4: Run the test (passes)**

`docker compose exec -T app mix test test/verscienta/recommendations/affinity_profile_test.exs` → PASS (existing tests + 2 new; existing tests pass because `taste_vector` is additive and `@index` entries without `:embedding` yield `nil`).

- [ ] **Step 5: format, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix credo --strict lib/verscienta/recommendations/affinity_profile.ex 2>&1 | tail -4
git add lib/verscienta/recommendations/affinity_profile.ex test/verscienta/recommendations/affinity_profile_test.exs
git commit -m "feat(recommendations): taste vector (weighted embedding centroid) in affinity profile"
```

---

## Task 3: `:semantic` term in the `Scorer`

**Files:**
- Modify: `lib/verscienta/recommendations/scorer.ex`
- Test: `test/verscienta/recommendations/scorer_test.exs`

- [ ] **Step 1: Update the test**

In `test/verscienta/recommendations/scorer_test.exs`:

(a) Update the `default_weights/0` test to include the sixth weight:
```elixir
  test "default_weights/0 exposes the tunable weights" do
    w = Scorer.default_weights()
    assert w.explicit == 3.0
    assert w.affinity == 2.0
    assert w.social == 2.0
    assert w.freshness == 1.5
    assert w.quality == 0.5
    assert w.semantic == 2.5
  end
```

(b) Update the `candidate/1` helper to carry `:semantic` (default 0.0):
```elixir
  defp candidate(opts \\ []) do
    %{
      category: Keyword.get(opts, :category, :nutrition),
      tag_ids: Keyword.get(opts, :tag_ids, []),
      published_at: Keyword.get(opts, :published_at, @now),
      quality: Keyword.get(opts, :quality, 0.0),
      semantic: Keyword.get(opts, :semantic, 0.0)
    }
  end
```

(c) Add a test:
```elixir
  test "the semantic term raises the score and scales with its weight" do
    base = Scorer.score(candidate(semantic: 0.0), profile(), 0, Scorer.default_weights(), @now)
    high = Scorer.score(candidate(semantic: 0.9), profile(), 0, Scorer.default_weights(), @now)
    assert high > base
    assert_in_delta high - base, Scorer.default_weights().semantic * 0.9, 0.0001
  end
```

- [ ] **Step 2: Run it (fails — no :semantic weight/term)**

`docker compose exec -T app mix test test/verscienta/recommendations/scorer_test.exs` → FAIL.

- [ ] **Step 3: Implement**

In `lib/verscienta/recommendations/scorer.ex`:

(a) Add `semantic` to the weights type + defaults:
```elixir
  @type weights :: %{
          explicit: float(),
          affinity: float(),
          social: float(),
          freshness: float(),
          quality: float(),
          semantic: float()
        }

  @default_weights %{
    explicit: 3.0,
    affinity: 2.0,
    social: 2.0,
    freshness: 1.5,
    quality: 0.5,
    semantic: 2.5
  }
```

(b) Add `semantic` to the candidate typespec (the `candidate ::` map in the `@spec score(...)`): add `semantic: float() | nil` alongside `quality`.

(c) Add the term in `score/5`:
```elixir
  def score(candidate, profile, social_count, weights, now) do
    weights.explicit * explicit(candidate, profile) +
      weights.affinity * affinity(candidate, profile) +
      weights.social * social_count +
      weights.freshness * freshness(candidate, now) +
      weights.quality * (candidate.quality || 0.0) +
      weights.semantic * (candidate.semantic || 0.0)
  end
```

- [ ] **Step 4: Run the test (passes)**

`docker compose exec -T app mix test test/verscienta/recommendations/scorer_test.exs` → PASS.

- [ ] **Step 5: format, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix credo --strict lib/verscienta/recommendations/scorer.ex 2>&1 | tail -4
git add lib/verscienta/recommendations/scorer.ex test/verscienta/recommendations/scorer_test.exs
git commit -m "feat(recommendations): semantic weighted term in the For You scorer"
```

---

## Task 4: Wire per-candidate semantic into `for_you`

**Files:**
- Modify: `lib/verscienta/recommendations.ex`
- Test: `test/verscienta/recommendations/for_you_test.exs`

- [ ] **Step 1: Add the failing integration test**

In `test/verscienta/recommendations/for_you_test.exs`, add (before the final `end`). It needs an embedding helper + a `vec/1` helper; add them near the other helpers if not present:
```elixir
  defp vec(head), do: head ++ List.duplicate(0.0, 768 - length(head))

  defp with_embedding(article, embedding) do
    article
    |> Ash.Changeset.for_update(:set_embedding, %{embedding: embedding}, authorize?: false)
    |> Ash.update!()
  end
```
And the test:
```elixir
  test "ranks a candidate near the user's taste centroid above a semantically-distant one" do
    me = user("fyhybrid")
    author = user("fyhybridauthor")

    # The user engages an article → its embedding defines their taste centroid.
    liked = published(author, "Liked Topic", :nutrition) |> with_embedding(vec([1.0, 0.0, 0.0]))

    Verscienta.Engagement.Bookmark
    |> Ash.ActionInput.for_action(:toggle, %{article_id: liked.id}, actor: me)
    |> Ash.run_action!()

    near = published(author, "Near Taste", :nutrition) |> with_embedding(vec([0.97, 0.05, 0.0]))
    far = published(author, "Far Taste", :nutrition) |> with_embedding(vec([0.0, 0.0, 1.0]))

    ids = Recommendations.for_you(me, limit: 10) |> Enum.map(& &1.article.id)

    # liked is excluded (already engaged); near outranks far on the semantic term
    refute liked.id in ids
    assert Enum.find_index(ids, &(&1 == near.id)) < Enum.find_index(ids, &(&1 == far.id))
  end
```
(`published/3` and `user/1` already exist in this file.)

- [ ] **Step 2: Run it (fails — semantic not wired)**

`docker compose exec -T app mix test test/verscienta/recommendations/for_you_test.exs` → the new test FAILS (near/far tie or wrong order; without the semantic term they're otherwise equal).

- [ ] **Step 3: Implement**

In `lib/verscienta/recommendations.ex`:

(a) Add the alias (with the others): `alias Verscienta.Recommendations.Vector`.

(b) Add `:semantic` to the candidate map in `score_for/5` and a helper:
```elixir
  defp score_for(c, profile, social, quality, now) do
    cand = %{
      category: c.category,
      tag_ids: Enum.map(c.tags, & &1.id),
      published_at: c.published_at || c.inserted_at,
      quality: Map.get(quality, c.id, 0.0),
      semantic: semantic_score(c, profile)
    }

    Scorer.score(cand, profile, Map.get(social, c.id, 0), @weights, now)
  end

  defp semantic_score(_c, %{taste_vector: nil}), do: 0.0
  defp semantic_score(%{embedding: nil}, _profile), do: 0.0

  defp semantic_score(%{embedding: %Ash.Vector{} = emb}, %{taste_vector: taste}) do
    Vector.cosine(Ash.Vector.to_list(emb), taste) |> clamp01()
  end

  defp semantic_score(_c, _profile), do: 0.0

  defp clamp01(x), do: x |> max(0.0) |> min(1.0)
```

- [ ] **Step 4: Run the test (passes) + the rest of the for_you suite**

`docker compose exec -T app mix test test/verscienta/recommendations/for_you_test.exs` → PASS (the new test + all existing ones; the existing tests set no embeddings, so `taste_vector` is nil → `semantic` 0 → unchanged ordering).

- [ ] **Step 5: format, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix credo --strict lib/verscienta/recommendations.ex 2>&1 | tail -4
git add lib/verscienta/recommendations.ex test/verscienta/recommendations/for_you_test.exs
git commit -m "feat(recommendations): fold semantic taste similarity into for_you ranking"
```

---

## Task 5: Docs + full verification

**Files:** Modify `docs/todo.md`

- [ ] **Step 1: Check off the hybrid-engine todo item**

In `docs/todo.md`, under "### Recommendation & Personalization", find the line:
`- [ ] Hybrid recommendation engine (content-based + collaborative signals).`
and change it to:
`- [x] Hybrid recommendation engine (content-based + collaborative signals). *(For You v2: signal-based + semantic taste centroid; slice 4a)*`
(If the wording differs, find the hybrid-recommendation-engine bullet and check it off with that note.)

- [ ] **Step 2: Full suite + format**

```bash
docker compose exec -T app bash -lc 'mix format && mix format --check-formatted && mix test 2>&1 | tail -6'
```
Expected: format clean; suite 0 failures. (Known flake: `NotificationBellTest` passes on re-run; if it's the only failure, re-run once.)

- [ ] **Step 3: Credo + Dialyzer**

```bash
docker compose exec -T app mix credo --strict 2>&1 | tail -4
docker compose exec -T app mix dialyzer 2>&1 | tail -8
```
Expected: credo "found no issues"; dialyzer "passed successfully". If dialyzer reports NEW errors (the new `taste_vector`/`semantic` typespecs + `Vector` are the likely source), paste them and report BLOCKED rather than committing.

- [ ] **Step 4: Commit**

```bash
git add docs/todo.md
git commit -m "docs: check off hybrid recommendation engine (For You v2, slice 4a)"
```

- [ ] **Step 5:** Confirm all gates green — branch ready to merge to `main`.

---

## Notes for the implementer

- The `Scorer` stays pure: `:semantic` is a precomputed field in the candidate map (like `:quality`), computed in `for_you`'s impure `semantic_score/2`. `score/5`'s arity is unchanged.
- `Ash.Vector.to_list/1` (confirmed to exist) converts a stored `%Ash.Vector{}` to a float list. `AffinityProfile.load_article_index` and `Recommendations.semantic_score` both use it.
- Degradation is structural: `semantic_score` returns `0.0` when the profile has no `taste_vector` (no embedded engagements) or the candidate has no embedding. So all existing for_you tests (which never set embeddings) keep their slice-1 ordering — that's why they must still pass unchanged.
- The load-test `for_you` bench scenario is unaffected: the loadtest corpus has no embeddings (the embed worker isn't run during seed), so `taste_vector` is nil → `semantic` is 0 → the read path runs the (no-op) cosine branch and still returns/caches normally. No load-test change is needed for 4a. (Re-running `MIX_ENV=loadtest mix verscienta.load_test.bench` is optional and not part of the gating steps.)
- `clamp01` turns negative cosine (a candidate pointing away from the taste vector) into 0 — "not similar," not "penalized."
