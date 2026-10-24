# Content Domain (Block Editor) Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A block-based content layer where signed-in users compose articles from typed blocks (JSONB tree), publish/edit them, and readers browse a feed, per-category pages, and a server-rendered reading view.

**Architecture:** A `Verscienta.Content` Ash domain with `Article` (JSONB `blocks` column), `Tag`, `ArticleTag`; a `Block` module validates/normalizes every block server-side; a `BlockRenderer` produces sanitized HTML (single path for reader + editor preview); LiveViews provide a LiveView-native block editor (move buttons + one drag hook), reader, feed, and category pages reusing CodexComponents.

**Tech Stack:** Phoenix 1.8, Ash 3, AshPostgres, AshPhoenix.Form, MDEx (markdown), LiveView + a small JS hook, Tailwind v4 + Codex components.

---

## Conventions for the executor

- **Run everything in Docker.** Mix runs in the app service: `docker compose run --rm -T app bash -lc "<cmd>"`. Start the DB first: `docker compose up -d db`. Generous timeouts (compile can take minutes). If OOM-killed (exit 137), split the command and/or prefix `ERL_FLAGS="+S 2 +A 4"`.
- **One task at a time, sequentially.** After each task run `git rev-parse --short HEAD` to capture the REAL sha before any review. Never batch tasks or reference unverified SHAs.
- **Branch:** `phase-1-content` (already checked out; the block-editor spec is committed there as `985a0d4`).
- **Line endings:** `.gitattributes` (eol=lf) is set, `core.autocrlf` false — don't change. Run `mix format` before committing.
- **Git identity:** no local override. Commit message body ends with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- **Migrations:** `mix ash.codegen <name>`; never hand-write.
- **TDD:** for the Block/renderer/markdown/resource/policy/LiveView behavior, write the failing test first. Scaffold/dep tasks gate on compile + migration applying.
- **Output discipline:** use Read/Grep for file contents; when grepping command output target the one line you need (e.g. `grep -aoE "[0-9]+ tests?, [0-9]+ failures?"`).
- **Existing patterns to reuse:** `Verscienta.DataCase` (async sandbox); the `.text_field` private component pattern in `lib/verscienta_web/live/settings_live.ex`; `AshAuthentication.Plug.Helpers.store_in_session/2` to sign a conn into a test session; CodexComponents `kicker/1`, `headline/1`, `news_card/1`; the public browser scope and `ash_authentication_live_session :authenticated_routes` in `lib/verscienta_web/router.ex`.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `mix.exs` | add `:mdex` |
| `lib/verscienta/content.ex` | `Verscienta.Content` Ash domain |
| `lib/verscienta/content/markdown.ex` | `to_html/1` via MDEx (sanitized) |
| `lib/verscienta/content/slug.ex` | `slugify/1` |
| `lib/verscienta/content/category.ex` | 8 categories (key/label/slug/accent) + helpers |
| `lib/verscienta/content/block.ex` | block types, `default/1`, `cast/1`, `cast_all/1` |
| `lib/verscienta/content/block_renderer.ex` | `to_html/1` — sanitized server render of a block tree |
| `lib/verscienta/content/tag.ex` | `Tag` resource (`upsert_by_name`) |
| `lib/verscienta/content/article_tag.ex` | join resource |
| `lib/verscienta/content/article.ex` | `Article` resource (attrs incl. `blocks`, actions, policies) |
| `lib/verscienta/content/article/changes/generate_slug.ex` | slug-gen change |
| `lib/verscienta/content/article/changes/cast_blocks.ex` | runs `Block.cast_all/1` on the `blocks` argument |
| `config/config.exs` | register `Verscienta.Content` in `ash_domains` |
| `lib/verscienta_web/live/article_reader_live.ex` | `/articles/:slug` |
| `lib/verscienta_web/live/article_feed_live.ex` | `/articles` (+ shared `article_grid/1`) |
| `lib/verscienta_web/live/category_live.ex` | `/c/:category` |
| `lib/verscienta_web/live/article_editor_live.ex` | `/articles/new` + `/articles/:slug/edit` |
| `assets/js/app.js` | register the `BlockReorder` drag hook |
| `lib/verscienta_web/router.ex` | content routes |
| `lib/verscienta_web/components/layouts/root.html.heex` | `write` nav link |
| `test/verscienta/content/*_test.exs` | markdown, slug, category, block, renderer, article tests |
| `test/verscienta_web/live/article_*_test.exs`, `category_live_test.exs` | web tests |

---

## Task 1: MDEx markdown renderer (TDD)

**Files:**
- Modify: `mix.exs`
- Create: `lib/verscienta/content/markdown.ex`
- Test: `test/verscienta/content/markdown_test.exs`

- [ ] **Step 1: Add the dependency**

In `mix.exs` `defp deps`, add:
```elixir
      {:mdex, "~> 0.3"},
```

- [ ] **Step 2: Fetch deps**

```powershell
docker compose run --rm -T app bash -lc "mix deps.get"
```
Expected: `mdex` resolves (ships a precompiled NIF; no Rust toolchain needed). If `~> 0.3` is unavailable, use the latest `0.x` the resolver picks and note it.

- [ ] **Step 3: Write the failing test**

Create `test/verscienta/content/markdown_test.exs`:
```elixir
defmodule Verscienta.Content.MarkdownTest do
  use ExUnit.Case, async: true

  alias Verscienta.Content.Markdown

  test "renders basic markdown to html" do
    html = Markdown.to_html("# Hello\n\nSome **bold** text.")
    assert html =~ "<h1>"
    assert html =~ "Hello"
    assert html =~ "<strong>bold</strong>"
  end

  test "strips raw script tags from user input" do
    html = Markdown.to_html("Hi <script>alert('xss')</script> there")
    refute html =~ "<script>"
    refute html =~ "alert('xss')"
  end

  test "returns a binary for empty/nil input" do
    assert Markdown.to_html("") == ""
    assert Markdown.to_html(nil) == ""
  end
end
```

- [ ] **Step 4: Run to confirm failure**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/content/markdown_test.exs"
```
Expected: fails — module missing.

- [ ] **Step 5: Implement the renderer**

Create `lib/verscienta/content/markdown.ex`:
```elixir
defmodule Verscienta.Content.Markdown do
  @moduledoc "Renders user-authored markdown to sanitized HTML via MDEx."

  @opts [
    extension: [strikethrough: true, table: true, autolink: true, tasklist: true],
    render: [unsafe: false],
    features: [sanitize: true]
  ]

  @doc "Render markdown source to a sanitized HTML string."
  def to_html(nil), do: ""
  def to_html(""), do: ""

  def to_html(markdown) when is_binary(markdown) do
    case MDEx.to_html(markdown, @opts) do
      {:ok, html} -> html
      {:error, _} -> ""
    end
  end
end
```
NOTE: MDEx option keys vary across 0.x. The intent: GitHub extensions ON, raw HTML rendering OFF (`unsafe: false`), sanitization ON. If the option shape is rejected, consult `MDEx.to_html/2` for this version and achieve those three properties; the Step-3 tests are the gate. If `MDEx.to_html/2` returns a bare string (not `{:ok, _}`), adjust the `case`. Report the final option shape.

- [ ] **Step 6: Run to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/content/markdown_test.exs"
```
Expected: 3 tests, 0 failures.

- [ ] **Step 7: Format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format"
git add -A
git commit -m "feat(content): add MDEx markdown renderer with sanitization"
```
Then `git rev-parse --short HEAD`.

---

## Task 2: Slug + Category helpers (TDD)

**Files:**
- Create: `lib/verscienta/content/slug.ex`
- Create: `lib/verscienta/content/category.ex`
- Test: `test/verscienta/content/slug_test.exs`
- Test: `test/verscienta/content/category_test.exs`

- [ ] **Step 1: Write the slug test**

Create `test/verscienta/content/slug_test.exs`:
```elixir
defmodule Verscienta.Content.SlugTest do
  use ExUnit.Case, async: true

  alias Verscienta.Content.Slug

  test "downcases and hyphenates" do
    assert Slug.slugify("Hello World") == "hello-world"
  end

  test "strips punctuation and collapses separators" do
    assert Slug.slugify("  The Quiet!! Return  of Devices ") == "the-quiet-return-of-devices"
  end

  test "keeps digits, uses hyphens for symbols" do
    assert Slug.slugify("TCM & Qi 2.0") == "tcm-qi-2-0"
  end

  test "empty-ish input yields a non-empty fallback" do
    assert Slug.slugify("!!!") == "n-a"
    assert Slug.slugify("") == "n-a"
    assert Slug.slugify(nil) == "n-a"
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/content/slug_test.exs"
```
Expected: fails — module missing.

- [ ] **Step 3: Implement the slug helper**

Create `lib/verscienta/content/slug.ex`:
```elixir
defmodule Verscienta.Content.Slug do
  @moduledoc "Generates URL-safe slugs from arbitrary text."

  @doc "Convert text to a lowercase, hyphenated slug. Falls back to \"n-a\" if empty."
  def slugify(nil), do: "n-a"

  def slugify(text) when is_binary(text) do
    slug =
      text
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    if slug == "", do: "n-a", else: slug
  end
end
```

- [ ] **Step 4: Run slug test to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/content/slug_test.exs"
```
Expected: 4 tests, 0 failures.

- [ ] **Step 5: Write the category test**

Create `test/verscienta/content/category_test.exs`:
```elixir
defmodule Verscienta.Content.CategoryTest do
  use ExUnit.Case, async: true

  alias Verscienta.Content.Category

  test "lists all eight categories" do
    assert length(Category.all()) == 8
  end

  test "keys include first and last" do
    assert :nutrition in Category.keys()
    assert :environment in Category.keys()
  end

  test "looks up by key" do
    cat = Category.get(:tcm)
    assert cat.label == "TCM"
    assert cat.slug == "tcm"
    assert cat.accent == "politics"
  end

  test "looks up by slug" do
    assert Category.from_slug("functional-medicine").key == :functional_medicine
    assert Category.from_slug("nope") == nil
  end

  test "accent helper" do
    assert Category.accent(:environment) == "zune"
    assert Category.accent(:movement) == "tech"
    assert Category.accent(:unknown) == "zune"
  end
end
```

- [ ] **Step 6: Run to confirm failure**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/content/category_test.exs"
```
Expected: fails — module missing.

- [ ] **Step 7: Implement the Category module**

Create `lib/verscienta/content/category.ex`:
```elixir
defmodule Verscienta.Content.Category do
  @moduledoc "Source of truth for content categories and their Codex section accents."

  defstruct [:key, :label, :slug, :accent]

  @categories [
    %__MODULE__{key: :nutrition, label: "Nutrition", slug: "nutrition", accent: "sport"},
    %__MODULE__{key: :herbalism, label: "Herbalism", slug: "herbalism", accent: "business"},
    %__MODULE__{key: :mindfulness, label: "Mindfulness", slug: "mindfulness", accent: "culture"},
    %__MODULE__{key: :movement, label: "Movement", slug: "movement", accent: "tech"},
    %__MODULE__{
      key: :functional_medicine,
      label: "Functional Medicine",
      slug: "functional-medicine",
      accent: "world"
    },
    %__MODULE__{key: :tcm, label: "TCM", slug: "tcm", accent: "politics"},
    %__MODULE__{key: :ayurveda, label: "Ayurveda", slug: "ayurveda", accent: "opinion"},
    %__MODULE__{key: :environment, label: "Environment", slug: "environment", accent: "zune"}
  ]

  def all, do: @categories
  def keys, do: Enum.map(@categories, & &1.key)
  def get(key), do: Enum.find(@categories, &(&1.key == key))
  def from_slug(slug), do: Enum.find(@categories, &(&1.slug == slug))

  def accent(key) do
    case get(key) do
      nil -> "zune"
      cat -> cat.accent
    end
  end

  @doc "{label, key} tuples for a <select>."
  def select_options, do: Enum.map(@categories, &{&1.label, &1.key})
end
```

- [ ] **Step 8: Run category test to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/content/category_test.exs"
```
Expected: 5 tests, 0 failures.

- [ ] **Step 9: Format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format"
git add -A
git commit -m "feat(content): slug helper and Category source-of-truth"
```
Then `git rev-parse --short HEAD`.

---

## Task 3: `Block` validation/normalization (TDD)

**Files:**
- Create: `lib/verscienta/content/block.ex`
- Test: `test/verscienta/content/block_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/content/block_test.exs`:
```elixir
defmodule Verscienta.Content.BlockTest do
  use ExUnit.Case, async: true

  alias Verscienta.Content.Block

  test "known_types lists the in-scope blocks" do
    for t <- ~w(paragraph heading list blockquote code divider markdown callout image embed) do
      assert t in Block.known_types()
    end
  end

  test "default/1 builds a block with an id and the right type" do
    b = Block.default("paragraph")
    assert b["type"] == "paragraph"
    assert is_binary(b["id"]) and b["id"] != ""
    assert b["data"]["text"] == ""
  end

  test "cast keeps known type and whitelists data keys" do
    raw = %{"id" => "x", "type" => "heading", "data" => %{"text" => "Hi", "level" => 3, "evil" => "drop me"}}
    cast = Block.cast(raw)
    assert cast["type"] == "heading"
    assert cast["data"]["text"] == "Hi"
    assert cast["data"]["level"] == 3
    refute Map.has_key?(cast["data"], "evil")
  end

  test "cast clamps heading level into 2..4" do
    assert Block.cast(%{"type" => "heading", "data" => %{"text" => "x", "level" => 9}})["data"]["level"] == 4
    assert Block.cast(%{"type" => "heading", "data" => %{"text" => "x", "level" => 1}})["data"]["level"] == 2
  end

  test "cast supplies an id when missing" do
    assert is_binary(Block.cast(%{"type" => "paragraph", "data" => %{"text" => "x"}})["id"])
  end

  test "cast returns nil for unknown type" do
    assert Block.cast(%{"type" => "wat", "data" => %{}}) == nil
  end

  test "cast derives embed provider from the url" do
    yt = Block.cast(%{"type" => "embed", "data" => %{"url" => "https://www.youtube.com/watch?v=abc"}})
    assert yt["data"]["provider"] == "youtube"

    vimeo = Block.cast(%{"type" => "embed", "data" => %{"url" => "https://vimeo.com/12345"}})
    assert vimeo["data"]["provider"] == "vimeo"

    link = Block.cast(%{"type" => "embed", "data" => %{"url" => "https://example.com/x"}})
    assert link["data"]["provider"] == "link"
  end

  test "cast_all drops unknown blocks and keeps order" do
    raw = [
      %{"type" => "paragraph", "data" => %{"text" => "a"}},
      %{"type" => "bogus", "data" => %{}},
      %{"type" => "divider", "data" => %{}}
    ]

    result = Block.cast_all(raw)
    assert Enum.map(result, & &1["type"]) == ["paragraph", "divider"]
  end

  test "cast_all tolerates non-list input" do
    assert Block.cast_all(nil) == []
    assert Block.cast_all("nope") == []
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/content/block_test.exs"
```
Expected: fails — module missing.

- [ ] **Step 3: Implement the Block module**

Create `lib/verscienta/content/block.ex`:
```elixir
defmodule Verscienta.Content.Block do
  @moduledoc """
  Defines the known content block types and validates/normalizes untrusted
  block maps before they are persisted. Blocks are plain string-keyed maps:
  `%{"id" => uuid, "type" => type, "data" => map}`.
  """

  @types ~w(paragraph heading list blockquote code divider markdown callout image embed)

  @doc "The in-scope block type strings."
  def known_types, do: @types

  @doc "A fresh, default block map for a given type (with a generated id)."
  def default(type) when type in @types do
    %{"id" => Ash.UUID.generate(), "type" => type, "data" => default_data(type)}
  end

  defp default_data("paragraph"), do: %{"text" => ""}
  defp default_data("heading"), do: %{"text" => "", "level" => 2}
  defp default_data("list"), do: %{"style" => "bullet", "items" => [""]}
  defp default_data("blockquote"), do: %{"text" => ""}
  defp default_data("code"), do: %{"text" => "", "language" => ""}
  defp default_data("divider"), do: %{}
  defp default_data("markdown"), do: %{"source" => ""}
  defp default_data("callout"), do: %{"variant" => "info", "text" => ""}
  defp default_data("image"), do: %{"url" => "", "alt" => "", "caption" => ""}
  defp default_data("embed"), do: %{"url" => "", "provider" => "link"}

  @doc "Normalize an untrusted block map. Returns nil for unknown types."
  def cast(%{"type" => type} = raw) when type in @types do
    data = Map.get(raw, "data", %{}) || %{}

    %{
      "id" => id(raw),
      "type" => type,
      "data" => cast_data(type, data)
    }
  end

  def cast(_), do: nil

  @doc "Cast a list of raw blocks; drop unknowns; tolerate non-lists."
  def cast_all(blocks) when is_list(blocks), do: blocks |> Enum.map(&cast/1) |> Enum.reject(&is_nil/1)
  def cast_all(_), do: []

  defp id(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp id(_), do: Ash.UUID.generate()

  defp cast_data("paragraph", d), do: %{"text" => str(d, "text")}
  defp cast_data("blockquote", d), do: %{"text" => str(d, "text")}
  defp cast_data("markdown", d), do: %{"source" => str(d, "source")}
  defp cast_data("divider", _d), do: %{}

  defp cast_data("heading", d), do: %{"text" => str(d, "text"), "level" => clamp(d["level"], 2, 4)}

  defp cast_data("code", d), do: %{"text" => str(d, "text"), "language" => str(d, "language")}

  defp cast_data("list", d) do
    items = case d["items"] do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> [""]
    end

    %{"style" => one_of(d["style"], ~w(bullet number), "bullet"), "items" => items}
  end

  defp cast_data("callout", d),
    do: %{"variant" => one_of(d["variant"], ~w(info disclaimer), "info"), "text" => str(d, "text")}

  defp cast_data("image", d),
    do: %{"url" => str(d, "url"), "alt" => str(d, "alt"), "caption" => str(d, "caption")}

  defp cast_data("embed", d) do
    url = str(d, "url")
    %{"url" => url, "provider" => provider_for(url)}
  end

  defp str(map, key), do: to_string(Map.get(map, key, "") || "")

  defp one_of(value, allowed, default) do
    v = to_string(value || "")
    if v in allowed, do: v, else: default
  end

  defp clamp(value, lo, hi) do
    n =
      case value do
        i when is_integer(i) -> i
        s when is_binary(s) -> String.to_integer(s)
        _ -> lo
      end

    n |> max(lo) |> min(hi)
  rescue
    _ -> lo
  end

  defp provider_for(url) do
    cond do
      url =~ ~r/(youtube\.com|youtu\.be)/i -> "youtube"
      url =~ ~r/vimeo\.com/i -> "vimeo"
      true -> "link"
    end
  end
end
```

- [ ] **Step 4: Run to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/content/block_test.exs"
```
Expected: all pass.

- [ ] **Step 5: Format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format"
git add -A
git commit -m "feat(content): Block module with type validation/normalization"
```
Then `git rev-parse --short HEAD`.

---

## Task 4: `BlockRenderer` — sanitized server render (TDD)

**Files:**
- Create: `lib/verscienta/content/block_renderer.ex`
- Test: `test/verscienta/content/block_renderer_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/content/block_renderer_test.exs`:
```elixir
defmodule Verscienta.Content.BlockRendererTest do
  use ExUnit.Case, async: true

  alias Verscienta.Content.Block
  alias Verscienta.Content.BlockRenderer

  defp render(blocks), do: blocks |> Block.cast_all() |> BlockRenderer.to_html()

  test "renders paragraph and heading with escaped text" do
    html =
      render([
        %{"type" => "heading", "data" => %{"text" => "Title", "level" => 2}},
        %{"type" => "paragraph", "data" => %{"text" => "Hello world"}}
      ])

    assert html =~ "<h2>Title</h2>"
    assert html =~ "Hello world"
  end

  test "escapes raw html in plain-text blocks" do
    html = render([%{"type" => "paragraph", "data" => %{"text" => "<script>alert(1)</script>"}}])
    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;"
  end

  test "renders markdown block through sanitizer (script stripped)" do
    html = render([%{"type" => "markdown", "data" => %{"source" => "**hi** <script>x</script>"}}])
    assert html =~ "<strong>hi</strong>"
    refute html =~ "<script>"
  end

  test "renders a list" do
    html = render([%{"type" => "list", "data" => %{"style" => "bullet", "items" => ["a", "b"]}}])
    assert html =~ "<ul>"
    assert html =~ "<li>a</li>"
    assert html =~ "<li>b</li>"
  end

  test "divider renders hr" do
    assert render([%{"type" => "divider", "data" => %{}}]) =~ "<hr"
  end

  test "youtube embed renders a safe iframe; link embed renders an anchor" do
    yt = render([%{"type" => "embed", "data" => %{"url" => "https://www.youtube.com/watch?v=abc123"}}])
    assert yt =~ "<iframe"
    assert yt =~ "youtube.com/embed/abc123"

    link = render([%{"type" => "embed", "data" => %{"url" => "https://example.com/page"}}])
    assert link =~ "<a "
    assert link =~ "https://example.com/page"
    refute link =~ "<iframe"
  end

  test "image escapes its url/alt" do
    html = render([%{"type" => "image", "data" => %{"url" => "https://x/y.png", "alt" => "a\"b", "caption" => "cap"}}])
    assert html =~ "<figure>"
    assert html =~ "src=\"https://x/y.png\""
    refute html =~ "a\"b"
  end

  test "to_html of empty list is empty string" do
    assert BlockRenderer.to_html([]) == ""
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/content/block_renderer_test.exs"
```
Expected: fails — module missing.

- [ ] **Step 3: Implement the renderer**

Create `lib/verscienta/content/block_renderer.ex`:
```elixir
defmodule Verscienta.Content.BlockRenderer do
  @moduledoc """
  Renders a validated block tree to sanitized HTML. This is the single
  rendering path used by both the reader and the editor preview.
  """

  alias Verscienta.Content.Markdown

  @doc "Render a list of (already cast) blocks to an HTML string."
  def to_html(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(&render/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  def to_html(_), do: ""

  defp render(%{"type" => "paragraph", "data" => %{"text" => text}}),
    do: "<p>#{esc(text)}</p>"

  defp render(%{"type" => "heading", "data" => %{"text" => text, "level" => level}}),
    do: "<h#{level}>#{esc(text)}</h#{level}>"

  defp render(%{"type" => "blockquote", "data" => %{"text" => text}}),
    do: "<blockquote>#{esc(text)}</blockquote>"

  defp render(%{"type" => "code", "data" => %{"text" => text}}),
    do: "<pre><code>#{esc(text)}</code></pre>"

  defp render(%{"type" => "divider"}), do: "<hr/>"

  defp render(%{"type" => "list", "data" => %{"style" => style, "items" => items}}) do
    tag = if style == "number", do: "ol", else: "ul"
    lis = items |> Enum.map(&"<li>#{esc(&1)}</li>") |> Enum.join()
    "<#{tag}>#{lis}</#{tag}>"
  end

  defp render(%{"type" => "markdown", "data" => %{"source" => source}}),
    do: Markdown.to_html(source)

  defp render(%{"type" => "callout", "data" => %{"variant" => variant, "text" => text}}) do
    klass = if variant == "disclaimer", do: "callout callout-disclaimer", else: "callout callout-info"
    "<div class=\"#{klass}\">#{Markdown.to_html(text)}</div>"
  end

  defp render(%{"type" => "image", "data" => %{"url" => url, "alt" => alt, "caption" => caption}}) do
    cap = if caption == "", do: "", else: "<figcaption>#{esc(caption)}</figcaption>"
    "<figure><img src=\"#{esc(url)}\" alt=\"#{esc(alt)}\"/>#{cap}</figure>"
  end

  defp render(%{"type" => "embed", "data" => %{"url" => url, "provider" => provider}}),
    do: embed(provider, url)

  defp render(_), do: ""

  defp embed("youtube", url) do
    case youtube_id(url) do
      nil -> embed("link", url)
      id -> "<iframe src=\"https://www.youtube.com/embed/#{esc(id)}\" frameborder=\"0\" allowfullscreen></iframe>"
    end
  end

  defp embed("vimeo", url) do
    case vimeo_id(url) do
      nil -> embed("link", url)
      id -> "<iframe src=\"https://player.vimeo.com/video/#{esc(id)}\" frameborder=\"0\" allowfullscreen></iframe>"
    end
  end

  defp embed(_link, url), do: "<a href=\"#{esc(url)}\" rel=\"noopener noreferrer\" target=\"_blank\">#{esc(url)}</a>"

  defp youtube_id(url) do
    cond do
      m = Regex.run(~r/[?&]v=([\w-]{6,})/, url) -> Enum.at(m, 1)
      m = Regex.run(~r/youtu\.be\/([\w-]{6,})/, url) -> Enum.at(m, 1)
      true -> nil
    end
  end

  defp vimeo_id(url) do
    case Regex.run(~r/vimeo\.com\/(\d+)/, url) do
      [_, id] -> id
      _ -> nil
    end
  end

  defp esc(text), do: text |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
```

- [ ] **Step 4: Run to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/content/block_renderer_test.exs"
```
Expected: all pass.

- [ ] **Step 5: Format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format"
git add -A
git commit -m "feat(content): sanitized server-side block renderer"
```
Then `git rev-parse --short HEAD`.

---

## Task 5: Content domain + Tag + ArticleTag + Article resources (compile/migrate gate)

**Files:**
- Create: `lib/verscienta/content.ex`, `lib/verscienta/content/tag.ex`, `lib/verscienta/content/article_tag.ex`, `lib/verscienta/content/article.ex`
- Modify: `config/config.exs`

- [ ] **Step 1: Create the domain**

Create `lib/verscienta/content.ex`:
```elixir
defmodule Verscienta.Content do
  @moduledoc "Ash domain for articles, tags, and content taxonomy."
  use Ash.Domain, otp_app: :verscienta

  resources do
    resource Verscienta.Content.Article
    resource Verscienta.Content.Tag
    resource Verscienta.Content.ArticleTag
  end
end
```

- [ ] **Step 2: Create the Tag resource**

Create `lib/verscienta/content/tag.ex`:
```elixir
defmodule Verscienta.Content.Tag do
  @moduledoc "A free-form content tag."
  use Ash.Resource,
    otp_app: :verscienta,
    domain: Verscienta.Content,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "tags"
    repo Verscienta.Repo
  end

  actions do
    defaults [:read]
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :ci_string, allow_nil?: false, public?: true
    attribute :slug, :string, allow_nil?: false, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    many_to_many :articles, Verscienta.Content.Article do
      through Verscienta.Content.ArticleTag
      source_attribute_on_join_resource :tag_id
      destination_attribute_on_join_resource :article_id
    end
  end

  identities do
    identity :unique_name, [:name]
    identity :unique_tag_slug, [:slug]
  end
end
```

- [ ] **Step 3: Create the ArticleTag join resource**

Create `lib/verscienta/content/article_tag.ex`:
```elixir
defmodule Verscienta.Content.ArticleTag do
  @moduledoc "Join resource between articles and tags."
  use Ash.Resource,
    otp_app: :verscienta,
    domain: Verscienta.Content,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "article_tags"
    repo Verscienta.Repo
  end

  actions do
    defaults [:read, :create, :destroy]
  end

  relationships do
    belongs_to :article, Verscienta.Content.Article, primary_key?: true, allow_nil?: false
    belongs_to :tag, Verscienta.Content.Tag, primary_key?: true, allow_nil?: false
  end
end
```

- [ ] **Step 4: Create the Article resource skeleton**

Create `lib/verscienta/content/article.ex`:
```elixir
defmodule Verscienta.Content.Article do
  @moduledoc "A holistic-health article composed of typed content blocks."
  use Ash.Resource,
    otp_app: :verscienta,
    domain: Verscienta.Content,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "articles"
    repo Verscienta.Repo
  end

  actions do
    defaults [:read]
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true, constraints: [max_length: 200]
    attribute :slug, :string, allow_nil?: false, public?: true
    attribute :excerpt, :string, allow_nil?: true, public?: true, constraints: [max_length: 300]
    attribute :blocks, {:array, :map}, allow_nil?: false, default: [], public?: true
    attribute :cover_image_url, :string, allow_nil?: true, public?: true

    attribute :category, :atom do
      allow_nil? false
      public? true
      constraints one_of: [
                    :nutrition,
                    :herbalism,
                    :mindfulness,
                    :movement,
                    :functional_medicine,
                    :tcm,
                    :ayurveda,
                    :environment
                  ]
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :draft
      constraints one_of: [:draft, :published, :archived]
    end

    attribute :evidence_level, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:anecdotal, :emerging, :established]
    end

    attribute :published_at, :utc_datetime_usec, allow_nil?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :author, Verscienta.Accounts.User, allow_nil?: false

    many_to_many :tags, Verscienta.Content.Tag do
      through Verscienta.Content.ArticleTag
      source_attribute_on_join_resource :article_id
      destination_attribute_on_join_resource :tag_id
    end
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
```
NOTE: keep the `category` `one_of` list literally in sync with `Verscienta.Content.Category.keys()`; Task 6 adds a test asserting they match.

- [ ] **Step 5: Register the domain**

In `config/config.exs`, change `ash_domains` to:
```elixir
  ash_domains: [Verscienta.Accounts, Verscienta.Content]
```

- [ ] **Step 6: Compile**

```powershell
docker compose run --rm -T app bash -lc "mix compile"
```
Expected: compiles (warnings ok). Fix any composite-PK join complaints per the error while keeping a composite-unique join.

- [ ] **Step 7: Generate + apply migration**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "mix ash.codegen add_content_resources && mix ash.migrate"
```
Expected: creates `articles` (with `blocks jsonb` defaulting to `[]`), `tags`, `article_tags` with FKs + unique indexes (article slug, tag name, tag slug); applies cleanly.

- [ ] **Step 8: Format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format"
git add -A
git commit -m "feat(content): Content domain with Article (blocks), Tag, ArticleTag"
```
Then `git rev-parse --short HEAD`.

---

## Task 6: Article actions — create/update (slug, blocks cast, tags), publish, archive, scoped reads + policies (TDD)

**Files:**
- Modify: `lib/verscienta/content/article.ex`
- Modify: `lib/verscienta/content/tag.ex` (add `upsert_by_name`)
- Create: `lib/verscienta/content/article/changes/generate_slug.ex`
- Create: `lib/verscienta/content/article/changes/cast_blocks.ex`
- Test: `test/verscienta/content/article_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/verscienta/content/article_test.exs`:
```elixir
defmodule Verscienta.Content.ArticleTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Content.Article
  alias Verscienta.Content.Category

  defp user(username) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: username <> "@example.com",
      username: username,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_article(author, attrs \\ %{}) do
    base = %{
      title: "The Quiet Return of Devices",
      blocks: [%{"type" => "paragraph", "data" => %{"text" => "Body text."}}],
      category: :movement,
      tags: ["focus", "habits"]
    }

    Article
    |> Ash.Changeset.for_create(:create, Map.merge(base, attrs), actor: author)
    |> Ash.create(authorize?: true)
  end

  test "category enum matches the Category source of truth" do
    enum =
      Article
      |> Ash.Resource.Info.attribute(:category)
      |> Map.get(:constraints)
      |> Keyword.get(:one_of)
      |> Enum.sort()

    assert enum == Enum.sort(Category.keys())
  end

  test "create generates a slug, casts blocks, defaults to draft" do
    {:ok, article} = create_article(user("alice"))
    assert article.slug == "the-quiet-return-of-devices"
    assert article.status == :draft
    assert [%{"type" => "paragraph", "id" => id}] = article.blocks
    assert is_binary(id) and id != ""
  end

  test "create drops unknown block types via cast" do
    {:ok, article} =
      create_article(user("alice"), %{
        blocks: [
          %{"type" => "paragraph", "data" => %{"text" => "ok"}},
          %{"type" => "bogus", "data" => %{}}
        ]
      })

    assert Enum.map(article.blocks, & &1["type"]) == ["paragraph"]
  end

  test "create attaches tags (find-or-create)" do
    {:ok, article} = create_article(user("alice"))
    loaded = Ash.load!(article, :tags, authorize?: false)
    names = loaded.tags |> Enum.map(&to_string(&1.name)) |> Enum.sort()
    assert names == ["focus", "habits"]
  end

  test "duplicate title yields a distinct slug" do
    author = user("alice")
    {:ok, a1} = create_article(author)
    {:ok, a2} = create_article(author)
    assert a1.slug != a2.slug
  end

  test "publish stamps published_at; re-publish keeps original" do
    author = user("alice")
    {:ok, article} = create_article(author)
    {:ok, p} = article |> Ash.Changeset.for_update(:publish, %{}, actor: author) |> Ash.update()
    assert p.status == :published
    assert p.published_at != nil
    t = p.published_at
    {:ok, again} = p |> Ash.Changeset.for_update(:publish, %{}, actor: author) |> Ash.update()
    assert again.published_at == t
  end

  test "only the author can publish" do
    author = user("alice")
    other = user("bob")
    {:ok, article} = create_article(author)

    assert {:error, _} =
             article |> Ash.Changeset.for_update(:publish, %{}, actor: other) |> Ash.update()
  end

  test "list_published excludes drafts; drafts author-only" do
    author = user("alice")
    other = user("bob")
    {:ok, draft} = create_article(author)

    {:ok, _} =
      create_article(author, %{title: "Published One"})
      |> elem(1)
      |> Ash.Changeset.for_update(:publish, %{}, actor: author)
      |> Ash.update()

    published = Ash.read!(Article, action: :list_published, authorize?: false)
    assert length(published) == 1

    assert {:ok, _} = Ash.get(Article, draft.id, actor: author, authorize?: true)
    assert {:error, _} = Ash.get(Article, draft.id, actor: other, authorize?: true)
  end

  test "list_by_category returns only that category's published articles" do
    author = user("alice")

    {:ok, _} =
      create_article(author, %{title: "Move", category: :movement})
      |> elem(1)
      |> Ash.Changeset.for_update(:publish, %{}, actor: author)
      |> Ash.update()

    {:ok, _} =
      create_article(author, %{title: "Eat", category: :nutrition})
      |> elem(1)
      |> Ash.Changeset.for_update(:publish, %{}, actor: author)
      |> Ash.update()

    movement =
      Article
      |> Ash.Query.for_read(:list_by_category, %{category: :movement})
      |> Ash.read!(authorize?: false)

    assert length(movement) == 1
    assert hd(movement).category == :movement
  end
end
```
NOTE: `require Ash.Query` is provided by DataCase's `import Ecto.Query`? No — add `require Ash.Query` at the top of the test if `Ash.Query.for_read/3` macro errors. (DataCase imports Ecto, not Ash.Query.) Add the line if needed.

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta/content/article_test.exs"
```
Expected: failures — actions/policies/changes missing.

- [ ] **Step 3: Add `upsert_by_name` to Tag**

In `lib/verscienta/content/tag.ex`, replace `actions` and `policies`:
```elixir
  actions do
    defaults [:read]

    create :upsert_by_name do
      description "Find or create a tag by name."
      accept [:name]
      upsert? true
      upsert_identity :unique_name

      change fn changeset, _ ->
        name = Ash.Changeset.get_attribute(changeset, :name)
        slug = Verscienta.Content.Slug.slugify(to_string(name || ""))
        Ash.Changeset.force_change_attribute(changeset, :slug, slug)
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:upsert_by_name) do
      authorize_if actor_present()
    end
  end
```

- [ ] **Step 4: Add the slug + cast-blocks change modules**

Create `lib/verscienta/content/article/changes/generate_slug.ex`:
```elixir
defmodule Verscienta.Content.Article.Changes.GenerateSlug do
  @moduledoc "Sets a unique slug from the title on create."
  use Ash.Resource.Change
  require Ash.Query

  alias Verscienta.Content.Slug

  @impl true
  def change(changeset, _opts, _context) do
    base = Slug.slugify(Ash.Changeset.get_attribute(changeset, :title) || "")
    Ash.Changeset.force_change_attribute(changeset, :slug, unique_slug(base))
  end

  defp unique_slug(base) do
    if taken?(base), do: "#{base}-#{:erlang.unique_integer([:positive])}", else: base
  end

  defp taken?(slug) do
    Verscienta.Content.Article
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.read_one!(authorize?: false)
    |> is_nil()
    |> Kernel.not()
  end
end
```

Create `lib/verscienta/content/article/changes/cast_blocks.ex`:
```elixir
defmodule Verscienta.Content.Article.Changes.CastBlocks do
  @moduledoc "Normalizes the :blocks argument through Block.cast_all/1 and sets the attribute."
  use Ash.Resource.Change

  alias Verscienta.Content.Block

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_argument(changeset, :blocks) do
      {:ok, raw} -> Ash.Changeset.force_change_attribute(changeset, :blocks, Block.cast_all(raw))
      :error -> changeset
    end
  end
end
```

- [ ] **Step 5: Add Article actions**

In `lib/verscienta/content/article.ex`, replace the `actions` block:
```elixir
  actions do
    defaults [:read]

    create :create do
      description "Create a draft article owned by the actor."
      accept [:title, :excerpt, :cover_image_url, :category, :evidence_level]
      argument :blocks, {:array, :map}, default: []
      argument :tags, {:array, :string}, default: []

      change relate_actor(:author)
      change Verscienta.Content.Article.Changes.GenerateSlug
      change Verscienta.Content.Article.Changes.CastBlocks

      change manage_relationship(:tags, :tags,
               type: :direct_control,
               value_is_key: :name,
               on_lookup: :relate,
               on_no_match: {:create, :upsert_by_name}
             )
    end

    update :update do
      description "Update an article's editable fields, blocks, and tags."
      require_atomic? false
      accept [:title, :excerpt, :cover_image_url, :category, :evidence_level]
      argument :blocks, {:array, :map}, default: []
      argument :tags, {:array, :string}, default: []

      change Verscienta.Content.Article.Changes.CastBlocks

      change manage_relationship(:tags, :tags,
               type: :direct_control,
               value_is_key: :name,
               on_lookup: :relate,
               on_no_match: {:create, :upsert_by_name},
               on_missing: :unrelate
             )
    end

    update :publish do
      description "Publish, stamping published_at on first publish."
      accept []
      require_atomic? false
      change set_attribute(:status, :published)

      change fn changeset, _ ->
        case Ash.Changeset.get_attribute(changeset, :published_at) do
          nil -> Ash.Changeset.force_change_attribute(changeset, :published_at, DateTime.utc_now())
          _ -> changeset
        end
      end
    end

    update :archive do
      accept []
      change set_attribute(:status, :archived)
    end

    read :list_published do
      description "Published articles, newest first."
      filter expr(status == :published)
      prepare build(sort: [published_at: :desc])
    end

    read :get_published_by_slug do
      argument :slug, :string, allow_nil?: false
      get? true
      filter expr(status == :published and slug == ^arg(:slug))
    end

    read :list_by_category do
      argument :category, :atom, allow_nil?: false
      filter expr(status == :published and category == ^arg(:category))
      prepare build(sort: [published_at: :desc])
    end
  end
```
NOTE on `manage_relationship`: exact option shape for find-or-create-by-name varies by Ash version. Intent: given a list of tag-name strings, relate existing by name and create missing via Tag `:upsert_by_name`; on update remove de-listed tags. If `value_is_key`/`on_no_match` are rejected, consult the Ash `manage_relationship` docs for this version and achieve that behavior; the tag tests are the gate. Report the final shape.

- [ ] **Step 6: Add Article policies**

In `lib/verscienta/content/article.ex`, replace the `policies` block:
```elixir
  policies do
    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action(:update) do
      authorize_if expr(author_id == ^actor(:id))
    end

    policy action(:publish) do
      authorize_if expr(author_id == ^actor(:id))
    end

    policy action(:archive) do
      authorize_if expr(author_id == ^actor(:id))
    end

    # Published is public; drafts/archived only to their author.
    policy action_type(:read) do
      authorize_if expr(status == :published)
      authorize_if expr(author_id == ^actor(:id))
    end
  end
```

- [ ] **Step 7: Run the tests to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/content/article_test.exs"
```
Expected: all pass. Iterate on `manage_relationship` shape per the NOTE; do NOT weaken assertions (slug uniqueness, block-cast drop, author-only, draft privacy, category filter). If `actor_present/0` isn't available in the policy DSL, use `expr(not is_nil(^actor(:id)))`.

- [ ] **Step 8: Codegen (snapshot parity) + format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix ash.codegen content_actions || true; mix ash.migrate"
docker compose run --rm -T app bash -lc "mix format"
git add -A
git commit -m "feat(content): article actions (slug, block cast, tag sync), publish, policies"
```
Then `git rev-parse --short HEAD`.

---

## Task 7: Domain verification + quality gates

- [ ] **Step 1: Run the content domain suite + gates**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
```
Expected: format clean, credo 0 issues, no warnings, all tests pass (Accounts + Content + Phase-0 web). If `mix format` changes files run it and re-commit; fix/justify any credo finding in the new modules.

- [ ] **Step 2: Commit any fixes**

```powershell
git add -A
git commit -m "chore(content): satisfy format/credo/compile gates" || echo "nothing to commit"
```
Then `git rev-parse --short HEAD`.

---

## Task 8: Article reader `/articles/:slug` (TDD)

**Files:**
- Create: `lib/verscienta_web/live/article_reader_live.ex`
- Modify: `lib/verscienta_web/router.ex`
- Test: `test/verscienta_web/live/article_reader_live_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/article_reader_live_test.exs`:
```elixir
defmodule VerscientaWeb.ArticleReaderLiveTest do
  use VerscientaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Verscienta.Content.Article

  defp author(username) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: username <> "@example.com",
      username: username,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp published(author) do
    {:ok, a} =
      Article
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Adaptogens 101",
          blocks: [%{"type" => "markdown", "data" => %{"source" => "**Bold** body."}}],
          category: :herbalism
        },
        actor: author
      )
      |> Ash.create()

    {:ok, p} = a |> Ash.Changeset.for_update(:publish, %{}, actor: author) |> Ash.update()
    p
  end

  test "renders a published article with rendered blocks and disclaimer", %{conn: conn} do
    a = published(author("alice"))
    {:ok, _lv, html} = live(conn, ~p"/articles/#{a.slug}")
    assert html =~ "Adaptogens 101"
    assert html =~ "<strong>Bold</strong>"
    assert html =~ "not medical advice"
  end

  test "unknown slug does not render an article", %{conn: conn} do
    assert {:error, _} = live(conn, ~p"/articles/nope-nope")
  end
end
```
NOTE: if the unknown case raises rather than returning `{:error, _}`, switch to `assert_raise <Exception>, fn -> live(...) end`. Requirement: unknown/unpublished does not render a normal article.

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta_web/live/article_reader_live_test.exs"
```
Expected: fails — route + LiveView missing.

- [ ] **Step 3: Create the reader LiveView**

Create `lib/verscienta_web/live/article_reader_live.ex`:
```elixir
defmodule VerscientaWeb.ArticleReaderLive.NotFound do
  defexception message: "article not found", plug_status: 404
end

defmodule VerscientaWeb.ArticleReaderLive do
  @moduledoc "Public reading view for a published article at /articles/:slug."
  use VerscientaWeb, :live_view
  require Ash.Query

  import VerscientaWeb.CodexComponents

  alias Verscienta.Content.Article
  alias Verscienta.Content.BlockRenderer
  alias Verscienta.Content.Category

  on_mount {VerscientaWeb.LiveUserAuth, :live_user_optional}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    actor = socket.assigns[:current_user]

    case read_article(slug, actor) do
      nil ->
        raise VerscientaWeb.ArticleReaderLive.NotFound

      article ->
        article = Ash.load!(article, [:author, :tags], actor: actor, authorize?: false)

        {:ok,
         assign(socket,
           article: article,
           body_html: BlockRenderer.to_html(article.blocks),
           page_title: article.title
         )}
    end
  end

  defp read_article(slug, actor) do
    case Article
         |> Ash.Query.filter(slug == ^slug)
         |> Ash.read_one(actor: actor, authorize?: true) do
      {:ok, article} -> article
      {:error, _} -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <article class="mx-auto max-w-2xl px-6 pb-24 pt-28">
      <.kicker style={"color: var(--color-#{Category.accent(@article.category)})"}>
        {category_label(@article.category)}
      </.kicker>

      <h1 class="mt-3 mb-6 text-4xl font-extralight leading-tight sm:text-5xl">{@article.title}</h1>

      <div class="mb-10 flex flex-wrap gap-x-4 gap-y-1 text-[11px] uppercase tracking-wider text-ink-3">
        <a href={"/@" <> to_string(@article.author.username)} class="hover:text-ink">
          {"@" <> to_string(@article.author.username)}
        </a>
        <span :if={@article.published_at}>{Calendar.strftime(@article.published_at, "%b %-d, %Y")}</span>
        <span :if={@article.evidence_level}>evidence: {@article.evidence_level}</span>
        <span :if={@article.status != :published} class="text-zune">{@article.status}</span>
      </div>

      <div class="max-w-none text-base font-light leading-relaxed text-ink-2">
        {Phoenix.HTML.raw(@body_html)}
      </div>

      <p class="mt-16 border-t border-line pt-6 text-xs leading-relaxed text-ink-3">
        This content is for informational purposes only and is not medical advice. Always consult
        a qualified health professional before making changes to your health regimen.
      </p>
    </article>
    """
  end

  defp category_label(key), do: (Category.get(key) || %{label: to_string(key)}).label
end
```
NOTE: `Phoenix.HTML.raw/1` is safe because `BlockRenderer` sanitizes. `<.kicker>` accepts `:rest` global so `style=` works.

- [ ] **Step 4: Add the route**

In `lib/verscienta_web/router.ex`, in the PUBLIC browser scope (with `get "/", PageController, :home` and `live "/@:username"`), add before the `/@:username` line:
```elixir
    live "/articles/:slug", ArticleReaderLive, :show
```

- [ ] **Step 5: Run to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/article_reader_live_test.exs"
```
Expected: 2 tests pass. Adjust the unknown-slug assertion to observed behavior if needed.

- [ ] **Step 6: Format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format"
git add -A
git commit -m "feat(content): article reading view at /articles/:slug"
```
Then `git rev-parse --short HEAD`.

---

## Task 9: Feed `/articles` + category `/c/:category` (TDD)

**Files:**
- Create: `lib/verscienta_web/live/article_feed_live.ex`, `lib/verscienta_web/live/category_live.ex`
- Modify: `lib/verscienta_web/router.ex`
- Test: `test/verscienta_web/live/article_feed_live_test.exs`, `test/verscienta_web/live/category_live_test.exs`

- [ ] **Step 1: Write the feed test**

Create `test/verscienta_web/live/article_feed_live_test.exs`:
```elixir
defmodule VerscientaWeb.ArticleFeedLiveTest do
  use VerscientaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Verscienta.Content.Article

  defp author(username) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: username <> "@example.com",
      username: username,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp publish(author, title, category) do
    {:ok, a} =
      Article
      |> Ash.Changeset.for_create(:create, %{title: title, blocks: [], category: category}, actor: author)
      |> Ash.create()

    a |> Ash.Changeset.for_update(:publish, %{}, actor: author) |> Ash.update!()
  end

  test "lists published articles, not drafts", %{conn: conn} do
    a = author("alice")
    publish(a, "Published Piece", :movement)

    {:ok, _draft} =
      Article
      |> Ash.Changeset.for_create(:create, %{title: "Secret Draft", blocks: [], category: :movement}, actor: a)
      |> Ash.create()

    {:ok, _lv, html} = live(conn, ~p"/articles")
    assert html =~ "Published Piece"
    refute html =~ "Secret Draft"
  end
end
```

- [ ] **Step 2: Write the category test**

Create `test/verscienta_web/live/category_live_test.exs`:
```elixir
defmodule VerscientaWeb.CategoryLiveTest do
  use VerscientaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Verscienta.Content.Article

  defp author(username) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: username <> "@example.com",
      username: username,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp publish(author, title, category) do
    {:ok, a} =
      Article
      |> Ash.Changeset.for_create(:create, %{title: title, blocks: [], category: category}, actor: author)
      |> Ash.create()

    a |> Ash.Changeset.for_update(:publish, %{}, actor: author) |> Ash.update!()
  end

  test "shows only the category's published articles", %{conn: conn} do
    a = author("alice")
    publish(a, "Move Piece", :movement)
    publish(a, "Eat Piece", :nutrition)

    {:ok, _lv, html} = live(conn, ~p"/c/movement")
    assert html =~ "Move Piece"
    refute html =~ "Eat Piece"
  end

  test "unknown category does not render a category page", %{conn: conn} do
    assert {:error, _} = live(conn, ~p"/c/not-a-category")
  end
end
```

- [ ] **Step 3: Run both to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta_web/live/article_feed_live_test.exs test/verscienta_web/live/category_live_test.exs"
```
Expected: fail — routes + LiveViews missing.

- [ ] **Step 4: Create the feed LiveView (with shared grid)**

Create `lib/verscienta_web/live/article_feed_live.ex`:
```elixir
defmodule VerscientaWeb.ArticleFeedLive do
  @moduledoc "Front feed of published articles at /articles."
  use VerscientaWeb, :live_view

  import VerscientaWeb.CodexComponents

  alias Verscienta.Content.Article
  alias Verscienta.Content.Category

  on_mount {VerscientaWeb.LiveUserAuth, :live_user_optional}

  @impl true
  def mount(_params, _session, socket) do
    articles = Ash.read!(Article, action: :list_published, authorize?: false)
    {:ok, assign(socket, articles: articles, page_title: "articles")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-6 pb-24 pt-28">
      <.kicker>the codex</.kicker>
      <.headline class="mb-12 text-6xl">articles</.headline>
      <.article_grid articles={@articles} />
    </div>
    """
  end

  attr :articles, :list, required: true

  def article_grid(assigns) do
    ~H"""
    <div :if={@articles == []} class="text-ink-3">No articles yet.</div>
    <div :if={@articles != []} class="grid gap-7 sm:grid-cols-2 lg:grid-cols-3">
      <a :for={article <- @articles} href={"/articles/" <> article.slug} class="block">
        <.news_card
          category={category_label(article.category)}
          accent={Category.accent(article.category)}
          meta={meta(article)}
        >
          {article.title}
        </.news_card>
      </a>
    </div>
    """
  end

  defp category_label(key), do: (Category.get(key) || %{label: to_string(key)}).label
  defp meta(%{published_at: nil}), do: ""
  defp meta(%{published_at: dt}), do: Calendar.strftime(dt, "%b %-d")
end
```

- [ ] **Step 5: Create the category LiveView**

Create `lib/verscienta_web/live/category_live.ex`:
```elixir
defmodule VerscientaWeb.CategoryLive.NotFound do
  defexception message: "category not found", plug_status: 404
end

defmodule VerscientaWeb.CategoryLive do
  @moduledoc "Published articles for one category at /c/:category."
  use VerscientaWeb, :live_view
  require Ash.Query

  import VerscientaWeb.CodexComponents
  import VerscientaWeb.ArticleFeedLive, only: [article_grid: 1]

  alias Verscienta.Content.Article
  alias Verscienta.Content.Category

  on_mount {VerscientaWeb.LiveUserAuth, :live_user_optional}

  @impl true
  def mount(%{"category" => slug}, _session, socket) do
    case Category.from_slug(slug) do
      nil ->
        raise VerscientaWeb.CategoryLive.NotFound

      cat ->
        articles =
          Article
          |> Ash.Query.for_read(:list_by_category, %{category: cat.key})
          |> Ash.read!(authorize?: false)

        {:ok, assign(socket, category: cat, articles: articles, page_title: cat.label)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-6 pb-24 pt-28">
      <.kicker style={"color: var(--color-#{@category.accent})"}>category</.kicker>
      <.headline class="mb-12 text-6xl">{String.downcase(@category.label)}</.headline>
      <.article_grid articles={@articles} />
    </div>
    """
  end
end
```

- [ ] **Step 6: Add routes**

In `lib/verscienta_web/router.ex` public browser scope, add:
```elixir
    live "/articles", ArticleFeedLive, :index
    live "/c/:category", CategoryLive, :show
```
(Keep `live "/articles/:slug"` from Task 8 — `/articles` and `/articles/:slug` are distinct routes.)

- [ ] **Step 7: Run both tests to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/article_feed_live_test.exs test/verscienta_web/live/category_live_test.exs"
```
Expected: all pass. Adjust unknown-category assertion to observed behavior if needed.

- [ ] **Step 8: Format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format"
git add -A
git commit -m "feat(content): article feed and per-category pages"
```
Then `git rev-parse --short HEAD`.

---

## Task 10: Block editor `/articles/new` + `/articles/:slug/edit` (TDD)

This is the largest task. The editor holds the block list in assigns and mutates via events; metadata (title/category/tags/excerpt/cover) uses `AshPhoenix.Form`. Block fields post their values via a single `validate`/`save` form so block edits flow through `phx-change`.

**Files:**
- Create: `lib/verscienta_web/live/article_editor_live.ex`
- Modify: `assets/js/app.js` (register `BlockReorder` hook)
- Modify: `lib/verscienta_web/router.ex`
- Modify: `lib/verscienta_web/components/layouts/root.html.heex` (write nav link)
- Test: `test/verscienta_web/live/article_editor_live_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/article_editor_live_test.exs`:
```elixir
defmodule VerscientaWeb.ArticleEditorLiveTest do
  use VerscientaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AshAuthentication.Plug.Helpers
  alias Verscienta.Content.Article

  defp author(username) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: username <> "@example.com",
      username: username,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp sign_in(conn, user), do: conn |> Plug.Test.init_test_session(%{}) |> Helpers.store_in_session(user)

  test "requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/articles/new")
    assert path =~ "/sign-in"
  end

  test "add block then save draft persists an authored article with a block", %{conn: conn} do
    user = author("alice")
    conn = sign_in(conn, user)

    {:ok, lv, _html} = live(conn, ~p"/articles/new")

    # add a paragraph block
    lv |> element("button", "paragraph") |> render_click()

    # fill metadata + the paragraph text, then save draft
    lv
    |> form("#article-form",
      form: %{
        "title" => "My First Article",
        "category" => "movement",
        "excerpt" => "",
        "cover_image_url" => "",
        "tags" => "focus, habits"
      },
      blocks: %{}
    )
    |> render_change()

    lv
    |> form("#article-form", %{})
    |> render_submit()

    require Ash.Query

    article =
      Article
      |> Ash.Query.filter(title == "My First Article")
      |> Ash.read_one!(authorize?: false)

    assert article != nil
    assert article.author_id == user.id
    assert article.status == :draft
    assert length(article.blocks) >= 1
  end

  test "live preview renders typed markdown block", %{conn: conn} do
    user = author("alice")
    conn = sign_in(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/articles/new")

    lv |> element("button", "markdown") |> render_click()

    html =
      lv
      |> form("#article-form")
      |> render_change(%{"_target" => ["block", "0"], "block" => %{"0" => "# Preview Heading"}})

    assert html =~ "Preview Heading"
  end
end
```
NOTE: the exact event wiring for block fields + the "add block" button label depends on the editor markup you build in Step 3. The REQUIREMENTS the tests encode: (a) `/articles/new` redirects when signed out; (b) after adding a block and submitting, an article with ≥1 block is persisted as a draft owned by the author; (c) typing into a block updates the preview. If your markup uses different selectors/event params, **adjust the test selectors to match your real markup** (keep the three requirements; don't weaken them — e.g. still assert the article persists with a block and the preview shows typed content). Document the final event contract you implemented.

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta_web/live/article_editor_live_test.exs"
```
Expected: fails — route + LiveView missing.

- [ ] **Step 3: Create the editor LiveView**

Create `lib/verscienta_web/live/article_editor_live.ex`. The design: metadata via `AshPhoenix.Form`; blocks held as a list in assigns; block text fields are named `block[<index>]` and a `phx-change="block_change"` on the form updates the indexed block; add/move/delete/duplicate are button events; preview re-renders from the in-memory block list each change.

```elixir
defmodule VerscientaWeb.ArticleEditorLive.NotFound do
  defexception message: "article not found", plug_status: 404
end

defmodule VerscientaWeb.ArticleEditorLive do
  @moduledoc "Authenticated block editor: /articles/new and /articles/:slug/edit."
  use VerscientaWeb, :live_view
  require Ash.Query

  import VerscientaWeb.CodexComponents

  alias Verscienta.Content.Article
  alias Verscienta.Content.Block
  alias Verscienta.Content.BlockRenderer
  alias Verscienta.Content.Category

  on_mount {VerscientaWeb.LiveUserAuth, :live_user_required}

  @addable ~w(paragraph heading list blockquote code markdown callout image embed divider)

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user
    {article, mode} = load_target(params, user)
    blocks = (article && article.blocks) || []

    {:ok,
     socket
     |> assign(
       article: article,
       mode: mode,
       blocks: blocks,
       addable: @addable,
       page_title: if(mode == :new, do: "new article", else: "edit article")
     )
     |> assign(preview_html: BlockRenderer.to_html(blocks))
     |> assign_meta_form(article, mode, user)}
  end

  defp load_target(%{"slug" => slug}, user) do
    article =
      Article
      |> Ash.Query.filter(slug == ^slug)
      |> Ash.read_one!(authorize?: false)

    cond do
      is_nil(article) -> raise VerscientaWeb.ArticleEditorLive.NotFound
      article.author_id != user.id -> raise VerscientaWeb.ArticleEditorLive.NotFound
      true -> {Ash.load!(article, :tags, authorize?: false), :edit}
    end
  end

  defp load_target(_params, _user), do: {nil, :new}

  defp assign_meta_form(socket, nil, :new, user) do
    form = Article |> AshPhoenix.Form.for_create(:create, as: "form", actor: user) |> to_form()
    assign(socket, form: form)
  end

  defp assign_meta_form(socket, article, :edit, user) do
    form = article |> AshPhoenix.Form.for_update(:update, as: "form", actor: user) |> to_form()
    assign(socket, form: form)
  end

  # ---- block events ----

  @impl true
  def handle_event("add_block", %{"type" => type}, socket) when type in @addable do
    blocks = socket.assigns.blocks ++ [Block.default(type)]
    {:noreply, set_blocks(socket, blocks)}
  end

  def handle_event("block_change", %{"block" => params}, socket) do
    blocks =
      socket.assigns.blocks
      |> Enum.with_index()
      |> Enum.map(fn {block, i} ->
        case Map.get(params, to_string(i)) do
          nil -> block
          text -> put_in(block, ["data", primary_field(block["type"])], text)
        end
      end)

    {:noreply, set_blocks(socket, blocks)}
  end

  def handle_event("delete_block", %{"index" => i}, socket) do
    i = String.to_integer(i)
    {:noreply, set_blocks(socket, List.delete_at(socket.assigns.blocks, i))}
  end

  def handle_event("move_block", %{"index" => i, "dir" => dir}, socket) do
    i = String.to_integer(i)
    j = if dir == "up", do: i - 1, else: i + 1
    {:noreply, set_blocks(socket, swap(socket.assigns.blocks, i, j))}
  end

  def handle_event("reorder", %{"order" => order}, socket) do
    by_id = Map.new(socket.assigns.blocks, &{&1["id"], &1})
    blocks = order |> Enum.map(&Map.get(by_id, &1)) |> Enum.reject(&is_nil/1)
    {:noreply, set_blocks(socket, blocks)}
  end

  # ---- save / publish ----

  def handle_event("validate", %{"form" => params}, socket) do
    {:noreply, assign(socket, form: AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  def handle_event("save", %{"form" => params}, socket) do
    persist(socket, params, fn a -> ~p"/articles/#{a.slug}/edit" end, false)
  end

  def handle_event("publish", %{"form" => params}, socket) do
    persist(socket, params, fn a -> ~p"/articles/#{a.slug}" end, true)
  end

  defp persist(socket, params, redirect_fun, publish?) do
    params =
      params
      |> Map.put("blocks", socket.assigns.blocks)
      |> Map.put("tags", split_tags(params["tags"]))

    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, article} ->
        article = maybe_publish(article, publish?, socket.assigns.current_user)

        {:noreply,
         socket
         |> put_flash(:info, if(publish?, do: "Published", else: "Saved"))
         |> push_navigate(to: redirect_fun.(article))}

      {:error, form} ->
        {:noreply, assign(socket, form: form)}
    end
  end

  defp maybe_publish(article, false, _user), do: article

  defp maybe_publish(article, true, user) do
    {:ok, published} = article |> Ash.Changeset.for_update(:publish, %{}, actor: user) |> Ash.update()
    published
  end

  # ---- helpers ----

  defp set_blocks(socket, blocks),
    do: assign(socket, blocks: blocks, preview_html: BlockRenderer.to_html(Block.cast_all(blocks)))

  defp swap(list, i, j) when i >= 0 and j >= 0 and i < length(list) and j < length(list) do
    a = Enum.at(list, i)
    b = Enum.at(list, j)
    list |> List.replace_at(i, b) |> List.replace_at(j, a)
  end

  defp swap(list, _i, _j), do: list

  defp primary_field("heading"), do: "text"
  defp primary_field("paragraph"), do: "text"
  defp primary_field("blockquote"), do: "text"
  defp primary_field("callout"), do: "text"
  defp primary_field("code"), do: "text"
  defp primary_field("markdown"), do: "source"
  defp primary_field("image"), do: "url"
  defp primary_field("embed"), do: "url"
  defp primary_field(_), do: "text"

  defp split_tags(nil), do: []

  defp split_tags(str) do
    str |> String.split(~r/[,\n]/) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-6 pb-24 pt-28">
      <.headline class="mb-10 text-5xl">{@page_title}</.headline>

      <div class="grid gap-10 lg:grid-cols-2">
        <div>
          <.form
            :let={f}
            for={@form}
            id="article-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-5"
          >
            <.text_field field={f[:title]} label="title" />

            <div>
              <label class="mb-1 block text-[11px] uppercase tracking-widest text-ink-3">category</label>
              <select name={f[:category].name} class="w-full border border-line bg-canvas-2 px-4 py-3 text-ink">
                <option
                  :for={{label, key} <- Category.select_options()}
                  value={key}
                  selected={to_string(key) == to_string(f[:category].value)}
                >{label}</option>
              </select>
            </div>

            <.text_field field={f[:excerpt]} label="excerpt" />
            <.text_field field={f[:cover_image_url]} label="cover image url" />

            <div>
              <label class="mb-1 block text-[11px] uppercase tracking-widest text-ink-3">tags (comma separated)</label>
              <input type="text" name="form[tags]" value={tags_value(@article)} class="w-full border border-line bg-canvas-2 px-4 py-3 text-ink" />
            </div>

            <div class="flex gap-4 pt-2">
              <button type="submit" class="bg-canvas-3 px-6 py-3 text-xs font-bold uppercase tracking-wider text-ink hover:brightness-110">save draft</button>
              <button type="submit" phx-click="publish" class="bg-zune px-6 py-3 text-xs font-bold uppercase tracking-wider text-black hover:brightness-110">publish</button>
            </div>
          </.form>

          <div class="mt-8">
            <p class="mb-2 text-[11px] uppercase tracking-widest text-ink-3">add block</p>
            <div class="flex flex-wrap gap-2">
              <button
                :for={type <- @addable}
                type="button"
                phx-click="add_block"
                phx-value-type={type}
                class="border border-line px-3 py-1.5 text-xs lowercase text-ink-2 hover:text-ink"
              >{type}</button>
            </div>
          </div>

          <form phx-change="block_change" id="blocks-form" class="mt-6 space-y-4" phx-hook="BlockReorder">
            <div :for={{block, i} <- Enum.with_index(@blocks)} data-block-id={block["id"]} class="border border-line bg-canvas-2 p-4">
              <div class="mb-2 flex items-center justify-between text-[11px] uppercase tracking-widest text-ink-3">
                <span>{block["type"]}</span>
                <span class="flex gap-2">
                  <button type="button" phx-click="move_block" phx-value-index={i} phx-value-dir="up" class="hover:text-ink">↑</button>
                  <button type="button" phx-click="move_block" phx-value-index={i} phx-value-dir="down" class="hover:text-ink">↓</button>
                  <button type="button" phx-click="delete_block" phx-value-index={i} class="hover:text-politics">✕</button>
                </span>
              </div>
              <textarea
                :if={block["type"] != "divider"}
                name={"block[#{i}]"}
                rows="3"
                class="w-full border border-line bg-canvas-3 px-3 py-2 text-sm text-ink"
              >{block_text(block)}</textarea>
              <p :if={block["type"] == "divider"} class="text-xs text-ink-3">— divider —</p>
            </div>
          </form>
        </div>

        <div>
          <p class="mb-3 text-[11px] uppercase tracking-widest text-ink-3">preview</p>
          <div class="border border-line bg-canvas-2 p-6 text-base font-light leading-relaxed text-ink-2">
            {Phoenix.HTML.raw(@preview_html)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp block_text(block), do: get_in(block, ["data", primary_field(block["type"])]) || ""

  defp tags_value(%{tags: tags}) when is_list(tags),
    do: tags |> Enum.map(&to_string(&1.name)) |> Enum.join(", ")

  defp tags_value(_), do: ""

  # reuse the settings text_field component pattern
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true

  defp text_field(assigns) do
    ~H"""
    <div>
      <label class="mb-1 block text-[11px] uppercase tracking-widest text-ink-3">{@label}</label>
      <input
        type="text"
        name={@field.name}
        value={Phoenix.HTML.Form.normalize_value("text", @field.value)}
        class="w-full border border-line bg-canvas-2 px-4 py-3 text-ink"
      />
    </div>
    """
  end
end
```
NOTE: This editor only edits each block's *primary* text field via the textarea (heading text, list joined later, etc.) to keep the first cut tractable; richer per-field editing (heading level, list items, image alt/caption, callout variant) is a follow-up. The block data is cast server-side on every save (`CastBlocks`) and the preview casts too, so persisted data is always valid. The publish button is a submit with `phx-click="publish"`; if the dual submit/click is flaky in tests, make publish a `type="button"` that first saves then publishes. Adjust the test in Task 10 Step 1 to your actual selectors/markup; keep the three requirements.

- [ ] **Step 4: Register the drag hook**

In `assets/js/app.js`, add a `BlockReorder` hook and include it in the LiveSocket hooks. Find where `liveSocket` is created and add:
```javascript
const Hooks = {}
Hooks.BlockReorder = {
  mounted() {
    // Minimal pointer-based reorder: dragging is enhancement; move buttons are the baseline.
    // Emits a "reorder" event with the new order of data-block-id values.
    this.el.addEventListener("dragend", () => {
      const ids = Array.from(this.el.querySelectorAll("[data-block-id]")).map(
        (n) => n.dataset.blockId
      )
      this.pushEvent("reorder", { order: ids })
    })
  },
}
```
And ensure the `LiveSocket` is constructed with `hooks: Hooks` (merge into any existing hooks object). If `app.js` already has a `Hooks` object, add `BlockReorder` to it instead of redeclaring.

- [ ] **Step 5: Add routes (authenticated live session)**

In `lib/verscienta_web/router.ex`, inside `ash_authentication_live_session :authenticated_routes` (where `live "/settings"` is), add:
```elixir
      live "/articles/new", ArticleEditorLive, :new
      live "/articles/:slug/edit", ArticleEditorLive, :edit
```

- [ ] **Step 6: Add the write nav link**

In `lib/verscienta_web/components/layouts/root.html.heex`, in the signed-in branch (`<%= if assigns[:current_user] do %>`), add before the `@username` link:
```heex
          <a href="/articles/new" class="transition-colors hover:text-ink">write</a>
```

- [ ] **Step 7: Run the editor test; iterate to green**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/article_editor_live_test.exs"
```
Expected: 3 tests pass (auth redirect, add-block+save persists a draft with ≥1 block, preview reflects typed content). Adjust selectors/markup as noted; do not weaken the three requirements. Adjust redirect tuple shape if observed differently.

- [ ] **Step 8: Verify route resolution**

```powershell
docker compose run --rm -T app bash -lc "mix phx.routes | grep -iE 'articles|/c/'"
```
Expected: `/articles` → feed, `/articles/new` → editor, `/articles/:slug` → reader, `/articles/:slug/edit` → editor, `/c/:category` → category. Confirm `/articles/new` resolves to the editor (static segment beats dynamic `:slug`).

- [ ] **Step 9: Format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format"
git add -A
git commit -m "feat(content): block editor with live preview, reorder, and write nav"
```
Then `git rev-parse --short HEAD`.

---

## Task 11: Seeds + full verification

**Files:**
- Modify: `priv/repo/seeds.exs`

- [ ] **Step 1: Add demo published block articles (idempotent)**

Append to `priv/repo/seeds.exs` (after the admin block):
```elixir
# Demo published articles (idempotent), authored by admin.
admin =
  Verscienta.Accounts.User
  |> Ash.Query.filter(username == "admin")
  |> Ash.read_one!(authorize?: false)

demo_articles = [
  %{
    title: "A Field Guide to Adaptogens",
    category: :herbalism,
    blocks: [
      %{"type" => "heading", "data" => %{"text" => "Adaptogens", "level" => 2}},
      %{"type" => "markdown", "data" => %{"source" => "An **evidence-aware** look at common adaptogenic herbs."}}
    ],
    tags: ["herbs", "stress"]
  },
  %{
    title: "What a Daily Breathing Practice Changes",
    category: :mindfulness,
    blocks: [
      %{"type" => "paragraph", "data" => %{"text" => "Short daily practice, measurable effects."}}
    ],
    tags: ["breathwork"]
  }
]

if admin do
  for attrs <- demo_articles do
    exists? =
      Verscienta.Content.Article
      |> Ash.Query.filter(title == ^attrs.title)
      |> Ash.read_one!(authorize?: false)

    if is_nil(exists?) do
      {:ok, article} =
        Verscienta.Content.Article
        |> Ash.Changeset.for_create(:create, attrs, actor: admin)
        |> Ash.create()

      article |> Ash.Changeset.for_update(:publish, %{}, actor: admin) |> Ash.update!()
      IO.puts("Seeded article: #{attrs.title}")
    end
  end
end
```
NOTE: `priv/repo/seeds.exs` already aliases/uses `Ash.Query` for the admin block; if `require Ash.Query` is needed for the `filter` macro, add it near the top.

- [ ] **Step 2: Run seeds twice (idempotency)**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "mix ash.setup >/dev/null 2>&1; mix run priv/repo/seeds.exs; mix run priv/repo/seeds.exs"
```
Expected: first run seeds admin (if needed) + 2 articles; second prints nothing new for them.

- [ ] **Step 3: Full quality-gate run**

```powershell
docker compose run --rm -T app bash -lc "mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
```
Expected: format clean, credo 0 issues, no warnings, ALL tests pass (Accounts + Content domain + Block/renderer + content LiveViews + Phase-0). Capture the final `N tests, 0 failures`.

- [ ] **Step 4: Manual smoke (optional)**

```powershell
docker compose up -d
docker compose logs app --tail 20
```
Signed in as `admin@verscienta.news` / `password123`: `/articles` (demo articles) → open one (blocks render + disclaimer) → `/c/herbalism` → `/articles/new` (add blocks, watch preview, save draft, publish). Then `docker compose down`.

- [ ] **Step 5: Commit**

```powershell
git add -A
git commit -m "feat(content): seed demo block articles; finalize content domain"
```
Then `git rev-parse --short HEAD`.

---

## Definition of Done (verify all)

- [ ] A signed-in user can compose an article from typed blocks at `/articles/new`, see a live `BlockRenderer` preview, reorder (move buttons) and delete blocks, save a draft, publish, and edit at `/articles/:slug/edit`.
- [ ] Block data is server-validated (`Block.cast_all/1`) on every save; rendering is sanitized (a `<script>` payload is stripped); embeds use a provider allowlist (YouTube/Vimeo → safe iframe, else link).
- [ ] Drafts are private to the author; `/articles/:slug` shows published articles with the medical disclaimer and 404s drafts for non-authors.
- [ ] `/articles` lists published (no drafts); `/c/:category` lists a category's articles with the correct accent and 404s unknown categories.
- [ ] Categories resolve through `Content.Category`; the `Article.category` enum matches `Category.keys()`; tags are reused via find-or-create.
- [ ] `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test` all pass.
- [ ] Migrations + seeds committed on `phase-1-content`.
