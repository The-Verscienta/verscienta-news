# Related Content Module Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface semantically-related articles on the article reader page via a cached `Recommendations.related/2` (semantic neighbors + same-category fallback) rendered as a "related reading" grid.

**Architecture:** A new `Verscienta.Recommendations.Related` module wraps `similar/2` (slice 2) with a same-category fallback to fill the slot, cached per-article; `ArticleReaderLive` loads it at mount and renders it via the shared `article_grid/1` component.

**Tech Stack:** Elixir, Phoenix LiveView, Ash 3 / AshPostgres, `Verscienta.Cache`. All `mix` runs in Docker: `docker compose exec -T app mix …`.

**Spec:** `docs/superpowers/specs/2026-06-05-related-content-design.md`
**Branch:** `phase-3-related` (spec already committed here).

---

## File Structure

**Create:**
- `lib/verscienta/recommendations/related.ex` — `related/2` (semantic + category fallback, cached).
- `test/verscienta/recommendations/related_test.exs`
- `test/verscienta_web/live/article_reader_related_test.exs`

**Modify:**
- `lib/verscienta/recommendations.ex` — `defdelegate related/2`.
- `lib/verscienta_web/live/article_reader_live.ex` — import `article_grid`, assign `related` at mount, render the section.
- `docs/todo.md` — check off the related-content item.

---

## Task 1: `Recommendations.related/2`

**Files:**
- Create: `lib/verscienta/recommendations/related.ex`
- Modify: `lib/verscienta/recommendations.ex`
- Test: `test/verscienta/recommendations/related_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/recommendations/related_test.exs`:
```elixir
defmodule Verscienta.Recommendations.RelatedTest do
  use Verscienta.DataCase, async: true

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

  defp vec(head), do: head ++ List.duplicate(0.0, 768 - length(head))

  defp published(author, title, category) do
    Article
    |> Ash.Changeset.for_create(:create, %{title: title, excerpt: "e", category: category},
      actor: author
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(:publish, %{}, actor: author)
    |> Ash.update!()
  end

  defp with_embedding(article, embedding) do
    article
    |> Ash.Changeset.for_update(:set_embedding, %{embedding: embedding}, authorize?: false)
    |> Ash.update!()
  end

  defp reload(art), do: Ash.get!(Article, art.id, authorize?: false)

  test "semantic neighbors come first, then same-category recents fill to the limit" do
    author = user("rel1")
    anchor = published(author, "Anchor", :nutrition) |> with_embedding(vec([1.0, 0.0, 0.0]))
    near = published(author, "Near (semantic)", :nutrition) |> with_embedding(vec([0.95, 0.05, 0.0]))
    f1 = published(author, "Fallback One", :nutrition)
    f2 = published(author, "Fallback Two", :nutrition)
    f3 = published(author, "Fallback Three", :nutrition)

    result = Recommendations.related(reload(anchor), limit: 4)
    ids = Enum.map(result, & &1.id)

    assert length(result) == 4
    refute anchor.id in ids
    assert hd(ids) == near.id
    assert Enum.uniq(ids) == ids
    # the fallbacks are present (3 of them fill the remaining 3 slots)
    assert Enum.all?([f1.id, f2.id, f3.id], &(&1 in ids))
  end

  test "an anchor with no embedding falls back to same-category recents" do
    author = user("rel2")
    anchor = published(author, "No-Embed Anchor", :herbalism)
    s1 = published(author, "Herb Sibling 1", :herbalism)
    s2 = published(author, "Herb Sibling 2", :herbalism)

    ids = Recommendations.related(reload(anchor), limit: 4) |> Enum.map(& &1.id)

    refute anchor.id in ids
    assert s1.id in ids
    assert s2.id in ids
  end

  test "excludes deactivated-author articles from the fallback" do
    author = user("rel3")
    deact = user("rel3deact")
    anchor = published(author, "Anchor3", :movement)
    visible = published(author, "Visible Sibling", :movement)
    hidden = published(deact, "Hidden Sibling", :movement)

    Ecto.Adapters.SQL.query!(
      Verscienta.Repo,
      "UPDATE users SET deactivated_at = NOW() WHERE id = $1",
      [Ecto.UUID.dump!(deact.id)]
    )

    ids = Recommendations.related(reload(anchor), limit: 4) |> Enum.map(& &1.id)
    assert visible.id in ids
    refute hidden.id in ids
  end

  test "caches per article until the related tag is invalidated" do
    author = user("rel4")
    anchor = published(author, "Anchor4", :tcm)
    published(author, "First TCM", :tcm)

    r1 = Recommendations.related(reload(anchor), limit: 4)
    published(author, "Second TCM", :tcm)
    assert Recommendations.related(reload(anchor), limit: 4) == r1

    Cache.invalidate_tag("related")
    titles = Recommendations.related(reload(anchor), limit: 4) |> Enum.map(& &1.title)
    assert "Second TCM" in titles
  end
end
```

- [ ] **Step 2: Run it (fails — related/2 undefined)**

Run: `docker compose exec -T app mix test test/verscienta/recommendations/related_test.exs`
Expected: FAIL.

- [ ] **Step 3: Implement the module**

Create `lib/verscienta/recommendations/related.ex`:
```elixir
defmodule Verscienta.Recommendations.Related do
  @moduledoc """
  Related articles for the article reader page: semantic neighbors (via
  `Recommendations.Similar.similar/2`) backfilled with same-category recents to
  fill the slot when the anchor has no embedding yet or too few neighbors.
  Cached per-article (high hit rate; not per-user).
  """
  require Ash.Query

  alias Verscienta.Cache
  alias Verscienta.Content.Article
  alias Verscienta.Recommendations.Similar

  @ttl_ms 600_000

  @spec related(Article.t(), keyword()) :: [Article.t()]
  def related(article, opts \\ []) do
    limit = Keyword.get(opts, :limit, 4)
    key = "related:article:#{article.id}:limit=#{limit}"

    {:ok, items} =
      Cache.fetch(key, [ttl: @ttl_ms, tags: ["related"]], fn ->
        {:ok, compute(article, limit)}
      end)

    items
  end

  defp compute(article, limit) do
    semantic = Similar.similar(article, limit: limit)
    needed = limit - length(semantic)

    if needed > 0 do
      exclude = [article.id | Enum.map(semantic, & &1.id)]
      Enum.uniq_by(semantic ++ category_fallback(article, needed, exclude), & &1.id)
    else
      semantic
    end
  end

  defp category_fallback(article, needed, exclude) do
    Article
    |> Ash.Query.filter(
      status == :published and is_nil(group_id) and
        is_nil(author.deactivated_at) and is_nil(author.anonymized_at) and
        category == ^article.category and id not in ^exclude
    )
    |> Ash.Query.sort(published_at: :desc)
    |> Ash.Query.limit(needed)
    |> Ash.Query.load(:tags)
    |> Ash.read!(authorize?: false)
  end
end
```
In `lib/verscienta/recommendations.ex`, add the alias and delegate (next to the `similar/2` delegate):
```elixir
  alias Verscienta.Recommendations.Related
```
and:
```elixir
  @spec related(Verscienta.Content.Article.t(), keyword()) :: [Verscienta.Content.Article.t()]
  defdelegate related(article, opts \\ []), to: Related
```

- [ ] **Step 4: Run the test (passes)**

Run: `docker compose exec -T app mix test test/verscienta/recommendations/related_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: format, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix credo --strict lib/verscienta/recommendations/related.ex lib/verscienta/recommendations.ex 2>&1 | tail -5
git add lib/verscienta/recommendations/related.ex lib/verscienta/recommendations.ex test/verscienta/recommendations/related_test.exs
git commit -m "feat(recommendations): related/2 (semantic + category fallback, cached per-article)"
```

---

## Task 2: Article-page integration

**Files:**
- Modify: `lib/verscienta_web/live/article_reader_live.ex`
- Test: `test/verscienta_web/live/article_reader_related_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/article_reader_related_test.exs`:
```elixir
defmodule VerscientaWeb.ArticleReaderRelatedTest do
  use VerscientaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Verscienta.Content.Article

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

  test "the article page shows a related-reading section with a same-category sibling",
       %{conn: conn} do
    author = user("readrel")
    anchor = published(author, "Anchor Reader Article", :nutrition)
    _sibling = published(author, "Sibling To Suggest", :nutrition)

    {:ok, _lv, html} = live(conn, ~p"/articles/#{anchor.slug}")

    assert html =~ "related reading"
    assert html =~ "Sibling To Suggest"
  end
end
```

- [ ] **Step 2: Run it (fails — no related section)**

Run: `docker compose exec -T app mix test test/verscienta_web/live/article_reader_related_test.exs`
Expected: FAIL (no "related reading").

- [ ] **Step 3: Add the import**

In `lib/verscienta_web/live/article_reader_live.ex`, after the existing `import VerscientaWeb.CodexComponents` line (line 10), add:
```elixir
  import VerscientaWeb.ArticleFeedLive, only: [article_grid: 1]
```

- [ ] **Step 4: Assign `related` at mount**

In the `mount/3` happy path, inside the `assign(...)` keyword list (the block starting around line 38 with `article: article,`), add a `related:` entry:
```elixir
           related: Verscienta.Recommendations.related(article, limit: 4),
```
(Place it among the other assigns, e.g. right after `article: article,`.)

- [ ] **Step 5: Render the section**

In `render/1`, locate the medical-disclaimer paragraph (the `<p class="mt-16 border-t border-line pt-6 ...">This content is for informational purposes only...</p>`). Immediately AFTER that closing `</p>` and BEFORE the `<section class="mt-12 border-t border-line pt-8">` that holds the reaction buttons, insert:
```heex
      <section :if={@related != []} class="mt-12 border-t border-line pt-8">
        <h2 class="mb-6 text-2xl font-extralight lowercase">related reading</h2>
        <.article_grid articles={@related} />
      </section>
```

- [ ] **Step 6: Run the test (passes)**

Run: `docker compose exec -T app mix test test/verscienta_web/live/article_reader_related_test.exs`
Expected: PASS (1 test).

- [ ] **Step 7: Confirm no regression in the existing reader tests**

Run: `docker compose exec -T app mix test test/verscienta_web/live/reader_social_test.exs`
Expected: PASS (the reactions/comments section still renders below the new related section).

- [ ] **Step 8: format, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix credo --strict lib/verscienta_web/live/article_reader_live.ex 2>&1 | tail -5
git add lib/verscienta_web/live/article_reader_live.ex test/verscienta_web/live/article_reader_related_test.exs
git commit -m "feat(web): related-reading section on the article page"
```

---

## Task 3: Docs + full verification

**Files:** Modify `docs/todo.md`

- [ ] **Step 1: Check off the todo item**

In `docs/todo.md` line ~201, change:
```markdown
- [ ] Related-content module on article pages.
```
to:
```markdown
- [x] Related-content module on article pages. *(Recommendations.related/2 — semantic + category fallback; slice 3)*
```

- [ ] **Step 2: Full suite + format**

```bash
docker compose exec -T app bash -lc 'mix format && mix format --check-formatted && mix test 2>&1 | tail -6'
```
Expected: format clean; suite 0 failures. (Known flake: `NotificationBellTest` passes on re-run; if it's the only failure, re-run `mix test` once.)

- [ ] **Step 3: Credo + Dialyzer**

```bash
docker compose exec -T app mix credo --strict 2>&1 | tail -4
docker compose exec -T app mix dialyzer 2>&1 | tail -6
```
Expected: credo "found no issues"; dialyzer "passed successfully". If dialyzer reports NEW errors, paste them and report BLOCKED rather than committing.

- [ ] **Step 4: Commit**

```bash
git add docs/todo.md
git commit -m "docs: check off related-content module (slice 3)"
```

- [ ] **Step 5:** Confirm all gates green — branch ready to merge to `main` (operator decides merge timing).

---

## Notes for the implementer

- `Related` calls `Verscienta.Recommendations.Similar.similar/2` directly (not the context delegate) to keep the dependency explicit.
- The category fallback runs its OWN eligibility-filtered query (published, non-group, non-deactivated/anonymized author, same category, not in the exclude set) rather than reusing the cached `Article.list_by_category/1`, so it cannot leak deactivated authors and respects the exclude set.
- The per-article cache key (`related:article:<id>:limit=<n>`) is unique per anchor, so the LiveView/related tests are `async: true`-safe (no shared-cache race like the global feeds had). `DataCase` flushes `Verscienta.Cache` between tests.
- `article.embedding` is a default attribute and is loaded by the reader's `read_article` (no explicit `select`), so `similar/2` works without extra loads. In tests, the embedding worker doesn't run (Oban `:manual`), so a freshly-published article has `embedding == nil` → exercises the category fallback, which is exactly what the reader test relies on.
