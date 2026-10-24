# Social Card Images Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate a branded 1200×630 OG card per published article (libvips), upload it to Cloudflare Images on publish, and serve it as the article's Open Graph / Twitter image.

**Architecture:** `Content.OgCard.render/1` composes the card with `:image` (Vix/libvips). `GenerateOgCardWorker` (Oban) renders → uploads via the existing `Verscienta.Images` → stores `og_image_url` on the article via `:set_og_image`. `EnqueueOgCard` (mirrors `EnqueueEmbedding`) enqueues on publish/title/cover changes. `SEO.article/1` prefers `og_image_url`.

**Tech Stack:** Elixir, Ash 3, Oban, `:image`/Vix/libvips, Cloudflare Images (`Verscienta.Images`). All `mix` runs in Docker: `docker compose exec -T app mix …`.

**Spec:** `docs/superpowers/specs/2026-06-05-og-card-images-design.md`
**Branch:** `phase-3-og-cards` (spec already committed here).

**Patterns to mirror (read these first):**
- `lib/verscienta/content/article/changes/enqueue_embedding.ex` (after-action enqueue, published-guard, rescue/log).
- `lib/verscienta/ai/workers/embed_article_worker.ex` (Oban worker: unique by article_id, get article, do work, update via a no-hooks action).
- `lib/verscienta/content/article.ex` — the `:set_embedding` action (line ~124), and the `:publish`/`:create_aggregated`/`:ai_enrich`/`:update` actions that already carry `EnqueueEmbedding`.

---

## File Structure

**Create:**
- `lib/verscienta/content/og_card.ex` — libvips card renderer.
- `test/verscienta/content/og_card_test.exs`
- `lib/verscienta/content/workers/generate_og_card_worker.ex`
- `test/verscienta/content/workers/generate_og_card_worker_test.exs`
- `lib/verscienta/content/article/changes/enqueue_og_card.ex`
- `test/verscienta/content/article/changes/enqueue_og_card_test.exs`
- a migration for `og_image_url`.

**Modify:**
- `mix.exs` (`:image` dep), `Dockerfile.dev` (fonts/libvips).
- `lib/verscienta/content/article.ex` (`og_image_url` attr, `:set_og_image` action, wire `EnqueueOgCard`).
- `lib/verscienta_web/seo.ex` (og_image priority).
- `test/verscienta_web/seo_test.exs` (priority test).
- `docs/todo.md`.

---

## Task 1: Infrastructure — `:image` + libvips + fonts

**Files:** `mix.exs`, `Dockerfile.dev`

- [ ] **Step 1: Add the dependency**

In `mix.exs` `deps/0`, add (use the latest `:image` minor if resolution complains):
```elixir
      {:image, "~> 0.54"},
```

- [ ] **Step 2: Ensure libvips + fonts in the dev image**

READ `Dockerfile.dev`. In its `apt-get install` layer, add a font package so Pango text rendering has a family, plus libvips dev headers in case Vix compiles against the system lib (Vix usually fetches a precompiled libvips, but the fonts are required either way):
```
fonts-dejavu-core libvips
```
(Append to the existing `apt-get install -y …` list; keep `&& rm -rf /var/lib/apt/lists/*` if present. If the file uses a non-Debian base, install the equivalent libvips + a DejaVu/Liberation font package.)

- [ ] **Step 3: Rebuild the app image and fetch deps**

```bash
docker compose build app
docker compose up -d app
docker compose exec -T app mix deps.get
```
Expected: image builds; `:image` + `:vix` fetched/compiled with no error.

- [ ] **Step 4: Smoke-verify libvips text rendering produces a PNG**

```bash
docker compose exec -T app mix run -e 'png = Image.new!(200, 100, color: [12,12,12]) |> then(fn bg -> {:ok, t} = Image.Text.text("verscienta", font_size: 28, text_fill_color: "white"); Image.compose!(bg, t, x: 10, y: 30) end) |> Image.write!(:memory, suffix: ".png"); IO.inspect(binary_part(png, 0, 4), label: "png-magic")'
```
Expected: prints `png-magic: <<137, 80, 78, 71>>` (the PNG signature). If `Image.Text.text` raises about missing fonts, the font package didn't install — fix Step 2 and rebuild. If `Image`/`Vix` won't load at all, report BLOCKED with the error.

- [ ] **Step 5: Commit**

```bash
git add mix.exs mix.lock Dockerfile.dev
git commit -m "build(og-cards): add :image (libvips) + fonts for OG card rendering"
```

---

## Task 2: `Content.OgCard` renderer

**Files:**
- Create: `lib/verscienta/content/og_card.ex`, `test/verscienta/content/og_card_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/content/og_card_test.exs`:
```elixir
defmodule Verscienta.Content.OgCardTest do
  use ExUnit.Case, async: true

  alias Verscienta.Content.OgCard

  @png_magic <<0x89, 0x50, 0x4E, 0x47>>

  defp article(attrs) do
    Map.merge(%{title: "A Title", category: :nutrition, slug: "a-title"}, attrs)
  end

  test "renders a PNG for a normal article" do
    assert {:ok, png} = OgCard.render(article(%{title: "Sleep Hygiene Basics"}))
    assert binary_part(png, 0, 4) == @png_magic
    assert byte_size(png) > 1000
  end

  test "handles a very long title without raising" do
    long = String.duplicate("Adaptogens and the science of stress resilience ", 10)
    assert {:ok, png} = OgCard.render(article(%{title: long}))
    assert binary_part(png, 0, 4) == @png_magic
  end

  test "handles a 1-character title" do
    assert {:ok, png} = OgCard.render(article(%{title: "x"}))
    assert binary_part(png, 0, 4) == @png_magic
  end
end
```

- [ ] **Step 2: Run it (fails — module undefined)**

`docker compose exec -T app mix test test/verscienta/content/og_card_test.exs` → FAIL.

- [ ] **Step 3: Implement**

Create `lib/verscienta/content/og_card.ex`. NOTE: the exact `:image` API can vary by version — if a function/option differs, consult `Image`/`Image.Text` docs for the installed version and adjust (the shape below targets `:image` ~0.54). The accent color comes from the category; use a safe fallback if lookup fails.
```elixir
defmodule Verscienta.Content.OgCard do
  @moduledoc """
  Renders a branded 1200×630 social-share (Open Graph) card for an article as
  PNG bytes, using libvips via `:image`. Pure: article map in, `{:ok, png}` out.
  """

  alias Verscienta.Content.Category

  @width 1200
  @height 630
  @bg [12, 12, 12]
  @accent_default [242, 102, 10]
  @title_max_chars 110
  @font "DejaVu Sans"
  @bold "DejaVu Sans Bold"

  @spec render(%{optional(any) => any}) :: {:ok, binary()} | {:error, term()}
  def render(article) do
    accent = accent_rgb(article)

    with {:ok, canvas} <- Image.new(@width, @height, color: @bg),
         {:ok, bar} <- Image.new(@width, 14, color: accent),
         {:ok, c1} <- Image.compose(canvas, bar, x: 0, y: 0),
         {:ok, title} <- title_image(article),
         {:ok, c2} <- Image.compose(c1, title, x: 80, y: 150),
         {:ok, footer} <- footer_image(article),
         {:ok, c3} <- Image.compose(c2, footer, x: 80, y: 540),
         {:ok, png} <- Image.write(c3, :memory, suffix: ".png") do
      {:ok, png}
    end
  rescue
    e -> {:error, e}
  end

  defp title_image(article) do
    Image.Text.text(truncate(article.title),
      font: @bold,
      font_size: 64,
      text_fill_color: "white",
      width: @width - 160,
      align: :left
    )
  end

  defp footer_image(article) do
    label = article |> category_label() |> String.upcase()
    Image.Text.text("#{label}   ·   verscienta·news",
      font: @font,
      font_size: 28,
      text_fill_color: "#9a9a9a"
    )
  end

  defp truncate(title) when is_binary(title) do
    t = String.trim(title)
    if String.length(t) > @title_max_chars, do: String.slice(t, 0, @title_max_chars) <> "…", else: t
  end

  defp truncate(_), do: "Verscienta News"

  defp accent_rgb(article) do
    case category(article) do
      %{accent: _} = cat -> accent_to_rgb(cat) || @accent_default
      _ -> @accent_default
    end
  end

  # The design tokens map accents to colors; if a precise lookup isn't trivial,
  # the brand orange (@accent_default) is a safe, on-brand fallback for all.
  defp accent_to_rgb(_cat), do: @accent_default

  defp category_label(article) do
    case category(article) do
      %{label: label} -> label
      _ -> "Wellness"
    end
  end

  defp category(%{category: key}) when not is_nil(key), do: Category.get(key)
  defp category(_), do: nil
end
```
(YAGNI note: `accent_to_rgb/1` returns the brand orange for all categories in v1 — per-category accent RGB mapping is a deferred polish; keep the seam but don't over-build. If `Category` exposes a hex/RGB accent trivially, you may map it, otherwise leave the fallback.)

- [ ] **Step 4: Run the test (passes)**

`docker compose exec -T app mix test test/verscienta/content/og_card_test.exs` → PASS (3 tests).

- [ ] **Step 5: format, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix credo --strict lib/verscienta/content/og_card.ex 2>&1 | tail -4
git add lib/verscienta/content/og_card.ex test/verscienta/content/og_card_test.exs
git commit -m "feat(og-cards): libvips OG card renderer"
```

---

## Task 3: `og_image_url` attribute + `:set_og_image` action + migration

**Files:**
- Modify: `lib/verscienta/content/article.ex`
- Create: a migration (generated)
- Test: `test/verscienta/content/article_og_image_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/content/article_og_image_test.exs`:
```elixir
defmodule Verscienta.Content.ArticleOgImageTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Content.Article

  defp author do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: "ogimg@example.com", username: "ogimg",
      password: "password123", password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  test "set_og_image stores the url without firing hooks" do
    a = author()
    {:ok, art} =
      Article
      |> Ash.Changeset.for_create(:create, %{title: "Og Img", blocks: [], category: :nutrition}, actor: a)
      |> Ash.create()

    {:ok, updated} =
      art
      |> Ash.Changeset.for_update(:set_og_image, %{og_image_url: "https://cdn.example.com/og.png"}, authorize?: false)
      |> Ash.update()

    assert updated.og_image_url == "https://cdn.example.com/og.png"
  end
end
```

- [ ] **Step 2: Run it (fails — no attribute/action)**

`docker compose exec -T app mix test test/verscienta/content/article_og_image_test.exs` → FAIL.

- [ ] **Step 3: Implement**

In `lib/verscienta/content/article.ex`:

(a) Add the attribute in the `attributes do` block (near `cover_image_url`):
```elixir
    attribute :og_image_url, :string, allow_nil?: true, public?: true
```

(b) Add the action in the `actions do` block (mirror `:set_embedding` — a minimal update accepting only the field, with NO change modules):
```elixir
    update :set_og_image do
      accept [:og_image_url]
      require_atomic? false
    end
```
(Match the exact form of `:set_embedding` in this file — if it sets `require_atomic?` or other options, mirror them.)

(c) Generate the migration:
```bash
docker compose exec -T app mix ash.codegen add_article_og_image_url
docker compose exec -T app mix ash.migrate
```
(If the project hand-writes migrations instead, add a migration adding a nullable `og_image_url :text`/`:string` column to `articles` and run `mix ecto.migrate`.)

- [ ] **Step 4: Run the test (passes)**

`docker compose exec -T app mix test test/verscienta/content/article_og_image_test.exs` → PASS.

- [ ] **Step 5: format, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix credo --strict lib/verscienta/content/article.ex 2>&1 | tail -4
git add lib/verscienta/content/article.ex priv/repo/migrations test/verscienta/content/article_og_image_test.exs
git commit -m "feat(og-cards): og_image_url attribute + set_og_image action + migration"
```

---

## Task 4: Worker + enqueue change + wiring

**Files:**
- Create: `lib/verscienta/content/workers/generate_og_card_worker.ex`, `lib/verscienta/content/article/changes/enqueue_og_card.ex`, `test/verscienta/content/workers/generate_og_card_worker_test.exs`, `test/verscienta/content/article/changes/enqueue_og_card_test.exs`
- Modify: `lib/verscienta/content/article.ex` (wire the change)

**Before implementing:** confirm Oban's test mode is `:manual` (so enqueued jobs don't auto-run in the suite) — check `config/test.exs` for `Oban` `testing:`. The existing `EnqueueIndex` already enqueues on every publish, so the suite tolerates queued jobs; mirror that.

- [ ] **Step 1: Write the failing tests**

Create `test/verscienta/content/workers/generate_og_card_worker_test.exs`:
```elixir
defmodule Verscienta.Content.Workers.GenerateOgCardWorkerTest do
  use Verscienta.DataCase, async: false

  alias Verscienta.Content.Article
  alias Verscienta.Content.Workers.GenerateOgCardWorker

  setup do
    # The Images client stub returns a deterministic id; reset around the test.
    prev = Application.get_env(:verscienta, :images_client)
    Application.put_env(:verscienta, :images_client, Verscienta.Images.ClientStub)
    on_exit(fn -> Application.put_env(:verscienta, :images_client, prev) end)
    :ok
  end

  defp author do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: "ogworker@example.com", username: "ogworker",
      password: "password123", password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  test "renders, uploads, and stores og_image_url" do
    a = author()
    {:ok, art} =
      Article
      |> Ash.Changeset.for_create(:create, %{title: "Worker Card", blocks: [], category: :nutrition}, actor: a)
      |> Ash.create()

    assert :ok = GenerateOgCardWorker.perform(%Oban.Job{args: %{"article_id" => art.id}})

    reloaded = Ash.get!(Article, art.id, authorize?: false)
    assert is_binary(reloaded.og_image_url)
    assert reloaded.og_image_url =~ "http"
  end
end
```
(If no `Verscienta.Images.ClientStub` exists, create a minimal one under `test/support/` implementing the `Verscienta.Images.Client` behaviour, returning `{:ok, %{"id" => "stub-og-id"}}` for `upload/3`. Check whether the existing image tests already provide such a stub — reuse it if so. `Verscienta.Images.delivery_url/2` will build a URL from that id.)

Create `test/verscienta/content/article/changes/enqueue_og_card_test.exs`:
```elixir
defmodule Verscienta.Content.Article.Changes.EnqueueOgCardTest do
  use Verscienta.DataCase, async: false
  use Oban.Testing, repo: Verscienta.Repo

  alias Verscienta.Content.Article
  alias Verscienta.Content.Workers.GenerateOgCardWorker

  defp author do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: "ogenq@example.com", username: "ogenq",
      password: "password123", password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp draft(a, title) do
    Article
    |> Ash.Changeset.for_create(:create, %{title: title, blocks: [], category: :nutrition}, actor: a)
    |> Ash.create!()
  end

  test "publishing enqueues the OG card worker" do
    a = author()
    art = draft(a, "Enqueue On Publish")
    {:ok, _} = art |> Ash.Changeset.for_update(:publish, %{}, actor: a) |> Ash.update()
    assert_enqueued worker: GenerateOgCardWorker, args: %{"article_id" => art.id}
  end

  test "a title change on a published article enqueues; an unrelated update does not" do
    a = author()
    art = draft(a, "Original Title")
    {:ok, pub} = art |> Ash.Changeset.for_update(:publish, %{}, actor: a) |> Ash.update()

    # clear the publish-time job so the next assertions see only new jobs
    Verscienta.Repo.delete_all(Oban.Job)

    {:ok, _} = pub |> Ash.Changeset.for_update(:update, %{excerpt: "just an excerpt"}, actor: a) |> Ash.update()
    refute_enqueued worker: GenerateOgCardWorker

    {:ok, _} = pub |> Ash.Changeset.for_update(:update, %{title: "New Title"}, actor: a) |> Ash.update()
    assert_enqueued worker: GenerateOgCardWorker
  end
end
```
(If `drain_jobs/1` with `queues: false` isn't the right helper in the installed Oban, use `Oban.Testing`'s available reset, or assert with `args:` specificity instead. Adapt to the Oban version; the intent is: unrelated update → no new job, title change → new job.)

- [ ] **Step 2: Run them (fail — worker/change missing)**

`docker compose exec -T app mix test test/verscienta/content/workers/generate_og_card_worker_test.exs test/verscienta/content/article/changes/enqueue_og_card_test.exs` → FAIL.

- [ ] **Step 3: Implement**

(a) Create `lib/verscienta/content/workers/generate_og_card_worker.ex` (mirror `EmbedArticleWorker`):
```elixir
defmodule Verscienta.Content.Workers.GenerateOgCardWorker do
  @moduledoc "Renders an article's OG card, uploads it, stores the URL. Retryable."
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [keys: [:article_id], period: 60, states: Oban.Job.unique_states(:incomplete)]

  alias Verscienta.Content.Article
  alias Verscienta.Content.OgCard
  alias Verscienta.Images

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"article_id" => id}}) do
    case Ash.get(Article, id, authorize?: false) do
      {:ok, article} -> generate(article)
      {:error, _} -> :ok
    end
  end

  defp generate(article) do
    with {:ok, png} <- OgCard.render(article),
         {:ok, url} <- Images.upload_image(png, "og-#{article.slug}.png", :public) do
      article
      |> Ash.Changeset.for_update(:set_og_image, %{og_image_url: url}, authorize?: false)
      |> Ash.update!()

      :ok
    end
  end
end
```

(b) Create `lib/verscienta/content/article/changes/enqueue_og_card.ex` (mirror `EnqueueEmbedding`, but regenerate only on publish-class actions or title/cover changes):
```elixir
defmodule Verscienta.Content.Article.Changes.EnqueueOgCard do
  @moduledoc "After-action: enqueue OG card (re)generation for a published article."
  use Ash.Resource.Change
  require Logger

  alias Verscienta.Content.Workers.GenerateOgCardWorker

  @regenerate_actions [:publish, :create_aggregated, :ai_enrich]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn cs, record ->
      maybe_enqueue(cs, record)
      {:ok, record}
    end)
  end

  defp maybe_enqueue(changeset, %{status: :published} = record) do
    if regenerate?(changeset) do
      %{"article_id" => record.id}
      |> GenerateOgCardWorker.new()
      |> Oban.insert!()
    end

    :ok
  rescue
    error ->
      Logger.warning("Failed to enqueue OG card for article #{record.id}: #{inspect(error)}")
      :ok
  end

  defp maybe_enqueue(_changeset, _record), do: :ok

  defp regenerate?(changeset) do
    changeset.action.name in @regenerate_actions or
      Ash.Changeset.changing_attribute?(changeset, :title) or
      Ash.Changeset.changing_attribute?(changeset, :cover_image_url)
  end
end
```

(c) In `lib/verscienta/content/article.ex`, add `change Verscienta.Content.Article.Changes.EnqueueOgCard` to the `:publish`, `:create_aggregated`, `:ai_enrich`, and `:update` actions (right next to the existing `EnqueueEmbedding` line in each).

- [ ] **Step 4: Run the tests (pass) + no broad-suite regression**

```bash
docker compose exec -T app mix test test/verscienta/content/workers/generate_og_card_worker_test.exs test/verscienta/content/article/changes/enqueue_og_card_test.exs 2>&1 | tail -6
docker compose exec -T app mix test test/verscienta/content/ 2>&1 | tail -5
```
Expected: PASS; no regression in content tests (publishing still works; queued jobs don't auto-run under `:manual`).

- [ ] **Step 5: format, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix credo --strict 2>&1 | tail -4
git add lib/verscienta/content test/verscienta/content test/support
git commit -m "feat(og-cards): generate-on-publish worker + enqueue change wired to article actions"
```

---

## Task 5: SEO priority + docs + full verification

**Files:**
- Modify: `lib/verscienta_web/seo.ex`, `test/verscienta_web/seo_test.exs`, `docs/todo.md`

- [ ] **Step 1: Add the failing SEO priority test**

In `test/verscienta_web/seo_test.exs`, add a test (the file has the `author`/`publish` helpers):
```elixir
  test "article/1 prefers og_image_url over cover, then default" do
    a = author()
    art = publish(a, %{title: "Priority", excerpt: "x", cover_image_url: "https://cdn.example.com/cover.jpg"})

    # no og card yet → cover wins
    assert SEO.article(art).og_image == "https://cdn.example.com/cover.jpg"

    {:ok, carded} =
      art
      |> Ash.Changeset.for_update(:set_og_image, %{og_image_url: "https://cdn.example.com/og.png"}, authorize?: false)
      |> Ash.update()

    assert SEO.article(carded).og_image == "https://cdn.example.com/og.png"
  end
```

- [ ] **Step 2: Run it (fails — og_image_url not preferred)**

`docker compose exec -T app mix test test/verscienta_web/seo_test.exs` → the new test FAILS.

- [ ] **Step 3: Implement**

In `lib/verscienta_web/seo.ex`, in `article/1`, change the image line to prefer the generated card:
```elixir
    image = abs_url(a.og_image_url || a.cover_image_url || @default_og_image)
```

- [ ] **Step 4: Run the test (passes)**

`docker compose exec -T app mix test test/verscienta_web/seo_test.exs` → PASS.

- [ ] **Step 5: Check off the todo**

In `docs/todo.md` under "### Growth", the bullet is "Shareable links + social card images." Update it to reflect the card half done:
`- [~] Shareable links + social card images. *(social cards done — libvips OG card per article, generated on publish → Cloudflare; Growth slice 2. Shareable links pending.)*`

- [ ] **Step 6: Full verification**

```bash
docker compose exec -T app bash -lc 'mix format && mix format --check-formatted && mix test 2>&1 | tail -6'
docker compose exec -T app mix credo --strict 2>&1 | tail -4
docker compose exec -T app mix dialyzer 2>&1 | tail -8
```
Expected: format clean; 0 failures; credo "found no issues"; dialyzer "passed successfully". If dialyzer reports NEW errors (the `OgCard`/`:image` types are the likely source — `:image` specs can be loose; if it's an unfixable external-type issue add a narrow entry to `.dialyzer_ignore.exs` consistent with the existing postgrex entry, and note it), paste them. Do NOT commit on red.

- [ ] **Step 7: Commit**

```bash
git add lib/verscienta_web/seo.ex test/verscienta_web/seo_test.exs docs/todo.md
git commit -m "feat(og-cards): SEO prefers generated og_image_url; docs"
```

- [ ] **Step 8:** Confirm all gates green — branch ready to merge.

---

## Notes for the implementer

- **Infra first (Task 1).** Tasks 2/4 render with libvips, so the image must have `:image` + fonts before those tests run. If libvips/Vix can't load, report BLOCKED — don't stub the renderer away.
- `:image` API specifics (`Image.Text.text/2` options, `Image.compose/3`, `Image.write/3`) may differ slightly by version — adjust to the installed version; the goal (1200×630 PNG with a wrapped title + accent + wordmark) is fixed, the exact calls are not.
- The worker mirrors `EmbedArticleWorker`; the enqueue change mirrors `EnqueueEmbedding` but adds the `regenerate?/1` guard so unrelated `:update`s don't re-render. `:publish` doesn't change the title, so it must regenerate via the action-name branch (the first card).
- In dev/test without Cloudflare creds, `Verscienta.Images` falls back to a placeholder URL; the worker test stubs `Images.Client`. Real Cloudflare delivery only matters in prod.
- **Deployment note (out of scope for this branch, flag to the user):** the production image/build must also include libvips + a font, or card generation will fail in prod. Only `Dockerfile.dev` exists in-repo; prod is built elsewhere (Coolify).
- `og_image_url` is an absolute Cloudflare URL → `abs_url/1` passes it through unchanged.
