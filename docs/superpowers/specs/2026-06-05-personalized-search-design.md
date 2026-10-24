# Personalized Search Ranking Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-05
**Status:** Approved
**Phase:** 3 — Intelligence & Growth · Recommendation & Personalization (slice 4b of 4 — final slice of the subsystem)
**Depends on:** `Verscienta.Search` (Meili + Postgres fallback), `Recommendations.AffinityProfile` (followed/affinity categories + `taste_vector`), `Recommendations.personalized?/1`, `Recommendations.Vector.cosine/2` (slices 1, 2, 4a). No new dependency.

## Goal

Re-rank search results for the signed-in viewer: blend Meilisearch relevance with a personalization bonus drawn from the viewer's category interests and semantic taste. Anonymous or no-signal viewers get today's plain-relevance order, unchanged. Relevance stays dominant — personalization reorders near-ties, never buries a strong textual match. Completes the hybrid recommender across search.

## Decomposition context

Slice 4 split into 4a (For You hybrid — shipped) and **4b (this — personalized search)**. This is the final slice of Recommendation & Personalization.

## Decisions

| Decision | Choice |
|----------|--------|
| Strategy | **Elixir re-rank layer** over a Meili window (Meili stays the relevance engine) |
| Signals | category interest (explicit follow + affinity) **+ semantic taste** (cosine to `taste_vector`) |
| Tags | **Delivered via the semantic term**, not literal tag-id matching (hits carry tag *slugs*; profile affinity is keyed by tag *ids* — impedance mismatch; embeddings capture topical match better) |
| Blend | `blended = relevance + β · personal`, **β = 0.2** (relevance-dominant; a relevance gap > β can't be overcome) |
| `personal` | `(interest + taste) / 2`, each in `[0,1]` → `personal ∈ [0,1]` |
| Relevance | Meili `_rankingScore` (request `showRankingScore: true`) |
| Window | fetch **40** hits when personalizing, re-rank, return top `per_page` (20) |
| Anonymous / cold | `personalized?(user) == false` → today's plain Meili path, no window, no extra query |
| Fallback (Meili down) | **un-personalized** for v1 (rare degraded path; no relevance scores) |
| Caching | **none** for personalized results (per-user × per-query → low hit rate; re-rank is cheap in-memory) |

## Section 1: `Verscienta.Search.Ranking` (pure)

New module `lib/verscienta/search/ranking.ex`. Pure — no DB, no Meili; takes the data it needs as arguments.

- `rerank(hits, profile, embeddings, opts \\ [])` — reorder a list of Meili hit maps by descending `blended_score`; stable for equal scores (preserves Meili order among ties). `embeddings` is `%{id => [float()]}` for the hits. Returns the reordered list.
- `blended_score(hit, profile, embeddings, beta)`:
  - `relevance = hit["_rankingScore"] || 0.0`
  - `interest`: `cat = safe_atom(hit["category"])`; `explicit = if MapSet.member?(profile.followed_categories, cat), do: 1.0, else: 0.0`; `affinity = Map.get(profile.category_affinity, cat, 0.0)`; `interest = clamp01((explicit + affinity) / 2)` (both already ≤ 1; mean keeps it in `[0,1]`).
  - `taste`: `emb = embeddings[hit["id"]]`; `clamp01(Vector.cosine(emb, profile.taste_vector))` (Vector.cosine already returns 0.0 for nil inputs, so a nil `taste_vector` or missing embedding → 0).
  - `personal = (interest + taste) / 2`
  - `relevance + beta * personal`
- `@default_beta 0.2`, exposed as `default_beta/0`.
- A profile of `nil` (defensive) → `rerank` returns `hits` unchanged.

`safe_atom/1` mirrors the existing pattern (e.g. `SearchLive.safe_key/1`): `String.to_existing_atom` rescued to a harmless default so an unknown category string can't crash or match.

## Section 2: `Search.search/2` orchestration

In `lib/verscienta/search.ex`:
- `search(query, opts)` gains a `:user` opt (a `%{id}`-bearing struct or `nil`).
- `personalize? = Recommendations.personalized?(user)` (false for nil user). Behavior:
  - **Not personalized:** unchanged from today — `build_params` with the normal `per_page` limit, map Meili (or fall back), return.
  - **Personalized (Meili path):** request a **window** (`limit = @window`, default 40) **with `"showRankingScore" => true`**; on a successful Meili response:
    1. `profile = AffinityProfile.for_user(user)` (cached).
    2. `embeddings = load_embeddings(hit_ids)` — one `Ash` query: `Article` where `id in ^ids`, returning `%{id => Ash.Vector.to_list(embedding)}` (skip nil embeddings).
    3. `hits = Ranking.rerank(window_hits, profile, embeddings) |> Enum.take(per_page)`.
    4. Return the same result map shape (`%{hits:, facets:, total:, page:, source: :meili}`) with the re-ranked, trimmed hits. `facets`/`total` come from the same Meili response (unchanged semantics).
  - **Personalized but Meili errors:** fall back to the existing Postgres path, **un-personalized** (v1).
- `AffinityProfile.for_user/1` is currently private-domain to `Recommendations`; expose what's needed via the `Recommendations` context (e.g. `Recommendations.affinity_profile(user)`) rather than reaching into the submodule — confirm/extend the public surface. (`personalized?/1` is already public.)
- Pagination note: personalization applies to the page-1 window only (the UI has no pagination today). If `:page > 1` is ever requested with a user, v1 may simply personalize page 1 and serve later pages un-personalized, or skip personalization for `page > 1` — pick the simpler and document it; **the current UI only ever requests page 1.**

`@window 40` module attribute. `load_embeddings/1` is a private `Search` helper (impure); `Ranking` stays pure.

## Section 3: `SearchLive` wiring

In `lib/verscienta_web/live/search_live.ex` (already `:live_user_optional`, so `current_user` is assigned):
- Pass `user: socket.assigns.current_user` in all three `Search.search(...)` calls (`search`, `toggle_category`, `clear`).
- No template change. (`current_user` is nil for anonymous → unchanged behavior.)

## Section 4: Testing

- **`Search.Ranking`** (pure, `async: true`):
  - equal `_rankingScore`: a hit in a followed category, or with higher `category_affinity`, ranks above one without → personalization breaks the tie;
  - equal `_rankingScore`: a hit whose embedding is near `taste_vector` ranks above a distant one;
  - **relevance dominates**: a hit with much higher `_rankingScore` (gap > β) stays on top despite the other having max `personal`;
  - `nil` profile → input order unchanged; missing embedding / nil `taste_vector` → `taste` contributes 0;
  - `default_beta/0 == 0.2`.
- **`Search.search/2`** (DataCase + the existing Mox `search_client`, `async: false` if the Mox is global):
  - create real articles, `:set_embedding` on them, stub the Meili client to return those ids with `_rankingScore`s + categories; a **personalized** user reorders by the blend and the result is trimmed to `per_page`; an **anonymous** user gets the Meili order untouched and no `showRankingScore`/window;
  - personalized + Meili error → Postgres fallback (un-personalized) still returns.
- **`SearchLive`** (LiveView test): a personalized session's rendered results reflect the re-rank (or at least that `search` is invoked with the user); keep it light if the integration test already covers ordering.
- Full suite + `credo --strict` + `dialyzer` green; format clean.

## Out of scope (deferred)

Pagination-aware personalization (no pagination UI exists); Meili-native vector / hybrid search; personalizing the Postgres fallback; caching personalized results; literal tag-id boosting; "why ranked" explanations; per-query learning-to-rank.

## Definition of Done

- `Verscienta.Search.Ranking` (`rerank/4`, `blended_score/4`, `default_beta/0`) pure + unit-tested; relevance-dominant blend (β 0.2); identity for nil profile.
- `Search.search/2` takes `:user`, requests scored window + re-ranks (profile + embeddings) for personalized viewers, trims to `per_page`; anonymous path byte-for-byte unchanged; Meili-error fallback un-personalized.
- `Recommendations` exposes the affinity profile accessor used by `Search` (no reaching into submodules).
- `SearchLive` passes `current_user` to all `Search.search` calls.
- Tests across `Ranking` (interest + taste + relevance-dominance + identity), `Search.search` (personalized reorder, anonymous untouched, fallback), and `SearchLive`; full suite + credo + dialyzer green.
- `docs/todo.md` "Personalized search ranking" checked off. No new dependency.
