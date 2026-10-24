# For You v2 — Hybrid (Semantic Taste) Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-05
**Status:** Approved
**Phase:** 3 — Intelligence & Growth · Recommendation & Personalization (slice 4a of 4)
**Depends on:** slice 1 (`Recommendations` Scorer/AffinityProfile/Candidates/for_you), slice 2 (article embeddings + `Ash.Vector`). No new dependency.

## Goal

Fold a **semantic content-based signal** into the For You ranking: learn the user's "taste" as the recency/type-weighted centroid of the embeddings of articles they've engaged with, and score each candidate by its cosine similarity to that taste vector. This completes the hybrid recommender (explicit follows + inferred affinity + social proof + freshness + quality + **semantic**). The pure `Scorer` stays pure (the semantic value is precomputed in `for_you`, exactly like social proof and quality). Degrades gracefully to the slice-1 signal-based feed when there's no embedding signal.

## Decomposition context

Slice 4 splits into **4a (this — For You hybrid)** and 4b (personalized search). 4a completes the For You feed (slices 1+2+3+4a); 4b is a separate spec.

## Decisions

| Decision | Choice |
|----------|--------|
| Taste model | **Centroid** — recency/type-weighted mean of engaged-article embeddings, unit-normalized; `nil` if none |
| Semantic score | `cosine(candidate.embedding, taste_vector)`, **clamped to [0,1]** (negatives → 0) |
| Where computed | **Precomputed per-candidate in `for_you`** (impure layer); the `Scorer` stays pure |
| Weight | new `:semantic` default **2.5** (tunable, comparable to affinity/explicit) |
| Cosine helper | new tiny pure `Verscienta.Recommendations.Vector` (`cosine/2`, `normalize/1`) — unit-tested |
| Degradation | no taste vector OR unembedded candidate → `semantic = 0` → slice-1 behavior |
| Caching | taste vector lives in the existing cached affinity profile (1h TTL) |

## Section 1: `Recommendations.Vector` (pure)

New module `lib/verscienta/recommendations/vector.ex`:
- `cosine(a, b)` — cosine similarity of two equal-length float lists; returns a float in `[-1, 1]`; returns `0.0` if either is `nil`/empty or has zero magnitude.
- `normalize(vec)` — unit-normalize a float list (`vec / ‖vec‖`); returns the input unchanged if zero magnitude.
- (Optional) `weighted_centroid(pairs)` where `pairs` is `[{vec, weight}]` → the weighted mean vector, or `nil` if empty — used by `AffinityProfile` to build the taste vector. May instead be inlined in `AffinityProfile`; keep the math in `Vector` if it stays small.

Pure, no deps; the foundation for the semantic term.

## Section 2: Taste vector in `AffinityProfile`

`AffinityProfile.build/4` gains a `taste_vector` in the returned profile map:
- Extend the engagement reduce: for each engagement whose article has an embedding (now carried in `article_index` as a float list), accumulate `embedding × (type_weight × decay)` into a running weighted sum + total weight.
- `taste_vector = Vector.normalize(weighted_sum / total_weight)` (unit length), or `nil` if no engaged article had an embedding.
- `for_user/1`'s `load_article_index` is extended to load `:embedding` and convert each `%Ash.Vector{}` to a float list (verify the `Ash.Vector` → list accessor — e.g. `Ash.Vector.to_list/1`, else decode `.data`).
- The profile (now including `taste_vector`) is cached as before (1h TTL). The profile type/typespec gains `taste_vector: [float()] | nil`.

`build/4` stays pure (its `article_index` input now includes embeddings).

## Section 3: Semantic term in the `Scorer` (stays pure)

- The candidate map gains a precomputed `:semantic` field (float in `[0,1]`).
- `Scorer.score` adds `weights.semantic * (candidate.semantic || 0.0)`.
- `default_weights/0` gains `semantic: 2.5`. The `weights` and `candidate` typespecs gain the field.
- No new positional argument — `score/5`'s arity is unchanged; the semantic value rides in the candidate map (like `:quality`).

## Section 4: `for_you` computes the semantic scores

In `for_you`'s `compute` (impure):
- After loading the profile + candidates, compute per-candidate semantic:
  `semantic = if profile.taste_vector && c.embedding, do: clamp01(Vector.cosine(to_list(c.embedding), profile.taste_vector)), else: 0.0`
  where `clamp01(x) = x |> max(0.0) |> min(1.0)` and `to_list` converts the candidate's `%Ash.Vector{}` to a float list.
- Thread `semantic` into the candidate map passed to `Scorer.score` (alongside `category`, `tag_ids`, `published_at`, `quality`).
- Candidates already carry `:embedding` (default attribute, loaded by `Candidates.recent`). No extra query — the cosine is bounded in-memory work over ≤500 candidates × 768 dims.

## Section 5: Testing

- **`Vector.cosine/2`** (pure): identical → 1.0; orthogonal → 0.0; opposite → −1.0 (and the `for_you` clamp turns it into 0); `nil`/zero-magnitude → 0.0. **`Vector.normalize/1`**: unit length; zero vector unchanged.
- **`AffinityProfile.build`**: with embedded engagements, `taste_vector` is the unit-normalized weighted centroid (closer to the more-recent / stronger-type engagements); `nil` with no embedded engagements. Update the existing affinity test's `@index`/builders to carry embeddings.
- **`Scorer.score`**: the `:semantic` term raises the score and scales with `weights.semantic`; update the `default_weights` test (now six weights) and the candidate-builder helper to include `:semantic`.
- **`for_you/2`** (integration, deterministic via known embeddings + `:set_embedding`): a user whose engaged articles' centroid is near candidate A ranks A above an otherwise-equal B that's semantically far; a user with no embedded engagement gets the unchanged slice-1 ordering.
- The existing for_you load-test bench scenario still passes (warm read <50ms; the semantic cosine is bounded in-memory).
- Full suite + `credo --strict` + `dialyzer` green.

## Out of scope (deferred)

Personalized search (4b); max-similarity taste model; recomputing the taste vector on every engagement (the 1h-cached profile suffices); diversity/MMR over semantic neighbors; surfacing "why recommended".

## Definition of Done

- `Recommendations.Vector` (`cosine/2`, `normalize/1`) pure + tested.
- `AffinityProfile` taste vector (weighted centroid, unit-normalized, `nil`-safe), embeddings loaded into the article index, cached in the profile.
- `Scorer` `:semantic` term + `semantic: 2.5` default weight; pure; arity unchanged.
- `for_you` precomputes per-candidate semantic (clamped cosine to the taste vector) and feeds the `Scorer`.
- Tests across Vector / AffinityProfile / Scorer / for_you (incl. the cold-no-taste degradation); existing Scorer/AffinityProfile/for_you tests updated for the new field; load-test scenario still green; full suite + credo + dialyzer green.
- `docs/todo.md` "For You hybrid" reflected. No new dependency.
