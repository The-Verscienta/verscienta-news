# SEO Foundations Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-page meta description + Open Graph/Twitter tags + canonical, NewsArticle JSON-LD on articles, a dynamic sitemap.xml, and a robots.txt — all crawler-visible via the LiveView dead render.

**Architecture:** A `VerscientaWeb.SEO` struct (`build/1`, `article/1`) is assigned as `:seo` by each page; a `seo_tags/1` component in `root.html.heex` renders it into `<head>` (so it appears in the dead-render HTML crawlers see). A `SitemapController` serves cached XML; `robots.txt` points at it.

**Tech Stack:** Phoenix 1.8 / LiveView, Ash 3, `Verscienta.Cache`, verified routes (`url/1`). All `mix` runs in Docker: `docker compose exec -T app mix …`.

**Spec:** `docs/superpowers/specs/2026-06-05-seo-foundations-design.md`
**Branch:** `phase-3-seo` (spec already committed here).

**Key context:**
- Home (`/`) is `PageController.home` (a controller); all other public pages are LiveViews. The root layout wraps both, reading `assigns[:seo]` from conn assigns (controllers) or socket assigns (LiveViews). So `SEO.build/1` returns a struct the caller assigns with its own `assign/3` — uniform across conn and socket.
- The dead render (initial `GET`) is what crawlers see; per-page `:seo` set in `mount`/controller lands in the `<head>`. Tests use `Phoenix.ConnTest.get/2` to read that HTML.

---

## File Structure

**Create:**
- `lib/verscienta_web/seo.ex` — the `%SEO{}` struct + `default/0`, `build/1`, `article/1`, `news_article_json_ld/4`, absolute-URL handling.
- `test/verscienta_web/seo_test.exs`
- `lib/verscienta_web/controllers/sitemap_controller.ex` — cached `GET /sitemap.xml`.
- `test/verscienta_web/controllers/sitemap_controller_test.exs`
- `priv/static/images/og-default.svg` — placeholder default OG image.

**Modify:**
- `lib/verscienta_web/components/layouts.ex` — add the `seo_tags/1` component.
- `lib/verscienta_web/components/layouts/root.html.heex` — render `<.seo_tags …/>`.
- Per-page: `article_reader_live.ex`, `page_controller.ex` (home), `article_feed_live.ex`, `category_live.ex`, `profile_live.ex`, `settings_live.ex`, `goodbye_live.ex`, `admin_flags_live.ex`, `admin_flag_show_live.ex`, `admin_sources_live.ex`.
- `lib/verscienta_web/router.ex` — `/sitemap.xml` route.
- `priv/static/robots.txt`.
- `docs/todo.md`.

---

## Task 1: `VerscientaWeb.SEO` module

**Files:**
- Create: `lib/verscienta_web/seo.ex`, `test/verscienta_web/seo_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/seo_test.exs`:
```elixir
defmodule VerscientaWeb.SEOTest do
  use Verscienta.DataCase, async: true

  alias VerscientaWeb.SEO

  defp author do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: "seo_author@example.com",
      username: "seoauthor",
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp publish(a, attrs) do
    {:ok, art} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, Map.merge(%{blocks: [], category: :nutrition}, attrs), actor: a)
      |> Ash.create()

    {:ok, p} = art |> Ash.Changeset.for_update(:publish, %{}, actor: a) |> Ash.update()
    Ash.load!(p, :author)
  end

  test "default/0 carries site defaults" do
    d = SEO.default()
    assert d.og_type == "website"
    assert d.noindex == false
    assert d.json_ld == nil
    assert is_binary(d.description)
    assert d.og_image =~ "og-default"
  end

  test "build/1 merges overrides onto defaults" do
    s = SEO.build(title: "Hello", noindex: true)
    assert s.title == "Hello"
    assert s.noindex == true
    assert s.og_type == "website"
    assert is_binary(s.description)
  end

  test "article/1 builds full OG + NewsArticle JSON-LD" do
    a = author()
    art = publish(a, %{title: "Adaptogens 101", excerpt: "All about adaptogens.", cover_image_url: "https://cdn.example.com/c.jpg"})

    s = SEO.article(art)

    assert s.og_type == "article"
    assert s.title == "Adaptogens 101"
    assert s.description == "All about adaptogens."
    assert s.canonical =~ "/articles/" <> art.slug
    assert String.starts_with?(s.canonical, "http")
    assert s.og_image == "https://cdn.example.com/c.jpg"

    ld = s.json_ld
    assert ld["@type"] == "NewsArticle"
    assert ld["headline"] == "Adaptogens 101"
    assert String.starts_with?(ld["image"], "http")
    assert is_binary(ld["datePublished"])
    assert ld["author"]["name"] == "seoauthor"
    assert ld["publisher"]["@type"] == "Organization"
    refute Enum.any?(Map.values(ld), &is_nil/1)
  end

  test "article/1 falls back to the default OG image (absolute) when no cover" do
    a = author()
    art = publish(a, %{title: "No Cover", excerpt: "x"})
    s = SEO.article(art)
    assert String.starts_with?(s.og_image, "http")
    assert s.og_image =~ "og-default"
  end
end
```

- [ ] **Step 2: Run it (fails — module undefined)**

`docker compose exec -T app mix test test/verscienta_web/seo_test.exs` → FAIL.

- [ ] **Step 3: Implement**

Create `lib/verscienta_web/seo.ex`:
```elixir
defmodule VerscientaWeb.SEO do
  @moduledoc """
  Per-page SEO/meta data: a `%SEO{}` struct, site-wide defaults, and an article
  builder. Pages assign a `%SEO{}` as `:seo`; the `seo_tags/1` layout component
  renders it into `<head>` (visible in the dead render that crawlers see).
  """
  use VerscientaWeb, :verified_routes

  alias Verscienta.Content.Article

  @site_name "Verscienta News"
  @default_description "Evidence-aware wellness journalism — herbalism, nutrition, movement, mind, and more."
  @default_og_image "/images/og-default.svg"

  defstruct title: nil,
            description: @default_description,
            canonical: nil,
            og_image: @default_og_image,
            og_type: "website",
            noindex: false,
            json_ld: nil

  @type t :: %__MODULE__{
          title: String.t() | nil,
          description: String.t(),
          canonical: String.t() | nil,
          og_image: String.t(),
          og_type: String.t(),
          noindex: boolean(),
          json_ld: map() | nil
        }

  @doc "The site name used in og:site_name and the JSON-LD publisher."
  def site_name, do: @site_name

  @doc "Site-wide default SEO."
  @spec default() :: t()
  def default, do: %__MODULE__{og_image: abs_url(@default_og_image)}

  @doc "Build a `%SEO{}` by merging `attrs` (keyword/map) over the site defaults."
  @spec build(keyword() | map()) :: t()
  def build(attrs \\ []) do
    base = default()
    Enum.reduce(Map.new(attrs), base, fn {k, v}, acc -> Map.put(acc, k, v) end)
  end

  @doc "Full SEO for an article (must be loaded with `:author`)."
  @spec article(Article.t()) :: t()
  def article(%Article{} = a) do
    desc = description_for(a)
    image = abs_url(a.cover_image_url || @default_og_image)
    canonical = url(~p"/articles/#{a.slug}")

    %__MODULE__{
      title: a.title,
      description: desc,
      canonical: canonical,
      og_image: image,
      og_type: "article",
      json_ld: news_article_json_ld(a, desc, image, canonical)
    }
  end

  @doc "Absolute URL for an image/path (passes through already-absolute http(s) URLs)."
  @spec absolute(String.t() | nil) :: String.t()
  def absolute(path), do: abs_url(path)

  @doc "The NewsArticle JSON-LD map for an article (nil-valued keys dropped)."
  @spec news_article_json_ld(Article.t(), String.t(), String.t(), String.t()) :: map()
  def news_article_json_ld(%Article{} = a, desc, image, canonical) do
    %{
      "@context" => "https://schema.org",
      "@type" => "NewsArticle",
      "headline" => a.title,
      "description" => desc,
      "image" => image,
      "datePublished" => iso8601(a.published_at),
      "dateModified" => iso8601(a.updated_at),
      "author" => %{"@type" => "Person", "name" => author_name(a)},
      "publisher" => %{"@type" => "Organization", "name" => @site_name},
      "mainEntityOfPage" => canonical
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp description_for(%Article{excerpt: e}) when is_binary(e) and e != "", do: truncate(e, 200)
  defp description_for(_), do: @default_description

  defp truncate(s, n) when byte_size(s) <= n, do: s
  defp truncate(s, n), do: (s |> String.slice(0, n) |> String.trim()) <> "…"

  defp author_name(%{author: %{display_name: dn}}) when is_binary(dn) and dn != "", do: dn
  defp author_name(%{author: %{username: un}}) when is_binary(un), do: un
  defp author_name(_), do: @site_name

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp abs_url(nil), do: abs_url(@default_og_image)
  defp abs_url("http" <> _ = u), do: u
  defp abs_url("/" <> _ = p), do: VerscientaWeb.Endpoint.url() <> p
  defp abs_url(other), do: other
end
```

- [ ] **Step 4: Run the test (passes)**

`docker compose exec -T app mix test test/verscienta_web/seo_test.exs` → PASS (4 tests).

- [ ] **Step 5: format, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix credo --strict lib/verscienta_web/seo.ex 2>&1 | tail -4
git add lib/verscienta_web/seo.ex test/verscienta_web/seo_test.exs
git commit -m "feat(seo): SEO struct + article/NewsArticle JSON-LD builder"
```

---

## Task 2: `seo_tags/1` component + root layout wiring

**Files:**
- Modify: `lib/verscienta_web/components/layouts.ex`, `lib/verscienta_web/components/layouts/root.html.heex`
- Test: `test/verscienta_web/seo_meta_test.exs` (create)

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/seo_meta_test.exs`. This reads the dead-render HTML of a page that sets no `:seo`, so it must show the site defaults:
```elixir
defmodule VerscientaWeb.SEOMetaTest do
  use VerscientaWeb.ConnCase, async: true

  test "default OG/meta tags render in the head for an un-wired page", %{conn: conn} do
    # /search sets no :seo (until later tasks) → falls back to SEO.default()
    html = conn |> get(~p"/search") |> html_response(200)

    assert html =~ ~s(property="og:site_name")
    assert html =~ "Verscienta News"
    assert html =~ ~s(name="twitter:card")
    assert html =~ "summary_large_image"
    assert html =~ ~s(property="og:image")
  end
end
```

- [ ] **Step 2: Run it (fails — no seo_tags rendered)**

`docker compose exec -T app mix test test/verscienta_web/seo_meta_test.exs` → FAIL.

- [ ] **Step 3: Implement**

(a) In `lib/verscienta_web/components/layouts.ex`, add the component (alongside the existing functions). `VerscientaWeb.SEO` provides defaults; `safe_json_ld` escapes `</` for safe embedding in a `<script>`:
```elixir
  alias VerscientaWeb.SEO

  @doc "Renders per-page SEO/meta tags into <head>. `seo` is a %VerscientaWeb.SEO{}."
  attr :seo, VerscientaWeb.SEO, required: true

  def seo_tags(assigns) do
    ~H"""
    <meta :if={@seo.description} name="description" content={@seo.description} />
    <link :if={@seo.canonical} rel="canonical" href={@seo.canonical} />
    <meta :if={@seo.noindex} name="robots" content="noindex, nofollow" />

    <meta property="og:site_name" content={SEO.site_name()} />
    <meta property="og:title" content={@seo.title || SEO.site_name()} />
    <meta :if={@seo.description} property="og:description" content={@seo.description} />
    <meta property="og:type" content={@seo.og_type} />
    <meta :if={@seo.canonical} property="og:url" content={@seo.canonical} />
    <meta property="og:image" content={@seo.og_image} />

    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:title" content={@seo.title || SEO.site_name()} />
    <meta :if={@seo.description} name="twitter:description" content={@seo.description} />
    <meta name="twitter:image" content={@seo.og_image} />

    <script :if={@seo.json_ld} type="application/ld+json">
      {Phoenix.HTML.raw(safe_json_ld(@seo.json_ld))}
    </script>
    """
  end

  defp safe_json_ld(map) do
    map |> Jason.encode!() |> String.replace("</", "<\\/")
  end
```
(If `attr :seo, VerscientaWeb.SEO` causes a compile issue, use `attr :seo, :map, required: true`.)

(b) In `lib/verscienta_web/components/layouts/root.html.heex`, right after the closing of the existing `<.live_title>…</.live_title>`, add:
```heex
    <.seo_tags seo={assigns[:seo] || VerscientaWeb.SEO.default()} />
```

- [ ] **Step 4: Run the test (passes)**

`docker compose exec -T app mix test test/verscienta_web/seo_meta_test.exs` → PASS.

- [ ] **Step 5: format, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix credo --strict lib/verscienta_web/components/layouts.ex 2>&1 | tail -4
git add lib/verscienta_web/components/layouts.ex lib/verscienta_web/components/layouts/root.html.heex test/verscienta_web/seo_meta_test.exs
git commit -m "feat(seo): seo_tags layout component rendered from the :seo assign"
```

---

## Task 3: Per-page SEO wiring

**Files:**
- Modify: `lib/verscienta_web/live/article_reader_live.ex`, `lib/verscienta_web/controllers/page_controller.ex`, `lib/verscienta_web/live/article_feed_live.ex`, `lib/verscienta_web/live/category_live.ex`, `lib/verscienta_web/live/profile_live.ex`, `lib/verscienta_web/live/settings_live.ex`, `lib/verscienta_web/live/goodbye_live.ex`, `lib/verscienta_web/live/admin_flags_live.ex`, `lib/verscienta_web/live/admin_flag_show_live.ex`, `lib/verscienta_web/live/admin_sources_live.ex`
- Test: `test/verscienta_web/seo_pages_test.exs` (create)

**Before implementing:** READ each LiveView's `mount`/`handle_params` to place the `assign(:seo, …)` correctly (alongside the existing `page_title` assign), and check `Verscienta.Content.Category` for a `description` field (use it if present; otherwise use the templated description shown below). For `ProfileLive`, the assigned user struct exposes `display_name`/`username`/`bio` — use what exists.

- [ ] **Step 1: Write the failing tests**

Create `test/verscienta_web/seo_pages_test.exs`:
```elixir
defmodule VerscientaWeb.SEOPagesTest do
  use VerscientaWeb.ConnCase, async: false
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

  defp sign_in(conn, u), do: conn |> Plug.Test.init_test_session(%{}) |> Helpers.store_in_session(u)

  defp publish(a, title, category) do
    {:ok, art} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: title, blocks: [], category: category, excerpt: "An excerpt."}, actor: a)
      |> Ash.create()

    {:ok, p} = art |> Ash.Changeset.for_update(:publish, %{}, actor: a) |> Ash.update()
    p
  end

  test "article page exposes og:title, canonical, and NewsArticle JSON-LD", %{conn: conn} do
    a = user("seopage")
    art = publish(a, "Sleep Hygiene", :nutrition)

    html = conn |> get(~p"/articles/#{art.slug}") |> html_response(200)

    assert html =~ "Sleep Hygiene"
    assert html =~ ~s(property="og:title")
    assert html =~ ~s(rel="canonical")
    assert html =~ "application/ld+json"
    assert html =~ "NewsArticle"
  end

  test "category page has a tailored description + canonical", %{conn: conn} do
    html = conn |> get(~p"/c/nutrition") |> html_response(200)
    assert html =~ ~s(name="description")
    assert html =~ ~s(rel="canonical")
    assert html =~ "/c/nutrition"
  end

  test "settings page is noindex", %{conn: conn} do
    me = user("seosettings")
    html = conn |> sign_in(me) |> get(~p"/settings") |> html_response(200)
    assert html =~ ~s(name="robots")
    assert html =~ "noindex"
  end
end
```

- [ ] **Step 2: Run it (fails — pages don't set :seo yet)**

`docker compose exec -T app mix test test/verscienta_web/seo_pages_test.exs` → FAIL (article has no og:title/JSON-LD; settings not noindex).

- [ ] **Step 3: Implement**

Add `alias VerscientaWeb.SEO` to each module touched (or call it fully-qualified). Wire each page:

(a) **`article_reader_live.ex`** — in `mount`, where it already does `assign(... page_title: article.title ...)`, add `:seo`:
```elixir
|> assign(:seo, SEO.article(article))
```
(The article is already loaded with `:author`/`:tags`.)

(b) **`page_controller.ex`** (`home/2`) — assign on the conn before render:
```elixir
def home(conn, _params) do
  conn
  |> assign(:seo, SEO.build(title: "Verscienta News", description: SEO.default().description, canonical: url(~p"/")))
  |> render(:home, ...)   # keep the existing render args
end
```
(Keep whatever the existing `render/3` passes; only add the `assign`.)

(c) **`article_feed_live.ex`** (`mount`) — alongside `page_title: "articles"`:
```elixir
|> assign(:seo, SEO.build(title: "Articles", description: "The latest evidence-aware wellness journalism from Verscienta News.", canonical: url(~p"/articles")))
```

(d) **`category_live.ex`** — where it assigns `page_title: cat.label`:
```elixir
|> assign(:seo, SEO.build(title: cat.label, description: category_description(cat), canonical: url(~p"/c/#{cat.key}")))
```
and add a private helper (use `cat.description` if the Category struct has one, else this template):
```elixir
defp category_description(cat) do
  case Map.get(cat, :description) do
    d when is_binary(d) and d != "" -> d
    _ -> "#{cat.label} stories, guides, and research on Verscienta News."
  end
end
```

(e) **`profile_live.ex`** — in the `:show` mount/handle_params where the profile user is assigned (use the loaded user's fields):
```elixir
|> assign(:seo, SEO.build(
  title: profile_display_name(user),
  description: profile_description(user),
  canonical: url(~p"/@#{user.username}")
))
```
with helpers:
```elixir
defp profile_display_name(u), do: (is_binary(u.display_name) and u.display_name != "" && u.display_name) || u.username
defp profile_description(u) do
  case u.bio do
    b when is_binary(b) and b != "" -> b
    _ -> "#{profile_display_name(u)} on Verscienta News."
  end
end
```
(Only wire the `:show` action; the followers/following/activity sub-actions can inherit or set the same — wiring `:show` is sufficient for this slice. If those are separate `handle_params` branches, leaving them to fall back to the default is acceptable.)

(f) **Private pages** — `settings_live.ex`, `goodbye_live.ex`, `admin_flags_live.ex`, `admin_flag_show_live.ex`, `admin_sources_live.ex`: alongside their existing `page_title` assign, add:
```elixir
|> assign(:seo, SEO.build(noindex: true))
```

- [ ] **Step 4: Run the tests (pass) + the touched LiveView tests**

```bash
docker compose exec -T app mix test test/verscienta_web/seo_pages_test.exs
```
Expected: PASS. Then run the existing tests for the touched LiveViews to ensure no regression:
```bash
docker compose exec -T app mix test test/verscienta_web/live/article_reader_live_test.exs test/verscienta_web/live/category_live_test.exs 2>&1 | tail -5
```

- [ ] **Step 5: format, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix credo --strict 2>&1 | tail -4
git add lib/verscienta_web test/verscienta_web/seo_pages_test.exs
git commit -m "feat(seo): wire per-page SEO (article JSON-LD, tailored public pages, noindex private)"
```

---

## Task 4: Sitemap controller + robots.txt + default OG image

**Files:**
- Create: `lib/verscienta_web/controllers/sitemap_controller.ex`, `test/verscienta_web/controllers/sitemap_controller_test.exs`, `priv/static/images/og-default.svg`
- Modify: `lib/verscienta_web/router.ex`, `priv/static/robots.txt`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/controllers/sitemap_controller_test.exs`:
```elixir
defmodule VerscientaWeb.SitemapControllerTest do
  use VerscientaWeb.ConnCase, async: false

  alias Verscienta.Cache

  setup do
    Cache.invalidate_tag("sitemap")
    on_exit(fn -> Cache.invalidate_tag("sitemap") end)
    :ok
  end

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

  defp publish(a, title) do
    {:ok, art} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: title, blocks: [], category: :nutrition}, actor: a)
      |> Ash.create()

    {:ok, p} = art |> Ash.Changeset.for_update(:publish, %{}, actor: a) |> Ash.update()
    p
  end

  test "GET /sitemap.xml lists published articles + public routes, excludes drafts", %{conn: conn} do
    a = user("sitemapper")
    pub = publish(a, "Indexed Piece")

    {:ok, _draft} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: "Hidden Draft Piece", blocks: [], category: :nutrition}, actor: a)
      |> Ash.create()

    conn = get(conn, "/sitemap.xml")

    assert response_content_type(conn, :xml) =~ "xml"
    body = response(conn, 200)
    assert body =~ "<urlset"
    assert body =~ "/articles/" <> pub.slug
    assert body =~ "/c/nutrition"
    refute body =~ "hidden-draft-piece"
  end

  test "second request is served from cache (identical body)", %{conn: conn} do
    a = user("sitemapcache")
    _ = publish(a, "Cached Piece")

    b1 = conn |> get("/sitemap.xml") |> response(200)
    b2 = build_conn() |> get("/sitemap.xml") |> response(200)
    assert b1 == b2
  end
end
```

- [ ] **Step 2: Run it (fails — no route/controller)**

`docker compose exec -T app mix test test/verscienta_web/controllers/sitemap_controller_test.exs` → FAIL.

- [ ] **Step 3: Implement**

(a) Create `lib/verscienta_web/controllers/sitemap_controller.ex`:
```elixir
defmodule VerscientaWeb.SitemapController do
  use VerscientaWeb, :controller

  require Ash.Query

  alias Verscienta.Cache
  alias Verscienta.Content.{Article, Category}

  @ttl_ms 3_600_000

  def index(conn, _params) do
    {:ok, xml} =
      Cache.fetch("sitemap:xml", [ttl: @ttl_ms, tags: ["sitemap"]], fn -> {:ok, build_xml()} end)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, xml)
  end

  defp build_xml do
    body = (static_urls() ++ article_urls()) |> Enum.map_join("", &url_entry/1)

    ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
      ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">) <>
      body <> "</urlset>"
  end

  defp static_urls do
    ([url(~p"/"), url(~p"/articles")] ++ Enum.map(Category.all(), &url(~p"/c/#{&1.key}")))
    |> Enum.map(&{&1, nil})
  end

  defp article_urls do
    Article
    |> Ash.Query.filter(
      status == :published and is_nil(group_id) and is_nil(author.deactivated_at) and
        is_nil(author.anonymized_at)
    )
    |> Ash.Query.sort(published_at: :desc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&{url(~p"/articles/#{&1.slug}"), &1.updated_at})
  end

  defp url_entry({loc, lastmod}) do
    "<url><loc>#{escape(loc)}</loc>#{lastmod_tag(lastmod)}</url>"
  end

  defp lastmod_tag(nil), do: ""
  defp lastmod_tag(%DateTime{} = dt), do: "<lastmod>#{Date.to_iso8601(DateTime.to_date(dt))}</lastmod>"

  defp escape(s), do: s |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
```

(b) In `lib/verscienta_web/router.ex`, add the route inside the public `scope "/", VerscientaWeb do pipe_through :browser` block (the one around line 126 that has `get "/", PageController, :home`):
```elixir
    get "/sitemap.xml", SitemapController, :index
```

(c) Create `priv/static/images/og-default.svg` (1200×630 branded placeholder):
```xml
<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">
  <rect width="1200" height="630" fill="#0c0c0c"/>
  <text x="80" y="330" font-family="Helvetica, Arial, sans-serif" font-size="84" font-weight="800" fill="#ffffff">verscienta<tspan fill="#F2660A">·</tspan>news</text>
  <text x="84" y="400" font-family="Helvetica, Arial, sans-serif" font-size="32" fill="#9a9a9a">evidence-aware wellness journalism</text>
</svg>
```

(d) Replace `priv/static/robots.txt` with:
```
User-agent: *
Allow: /
Disallow: /admin

Sitemap: https://verscienta.news/sitemap.xml
```
(If the production host differs, READ any existing host reference in `config/runtime.exs`/`config/prod.exs` and use that canonical host instead of `verscienta.news`.)

- [ ] **Step 4: Run the test (passes)**

`docker compose exec -T app mix test test/verscienta_web/controllers/sitemap_controller_test.exs` → PASS.

- [ ] **Step 5: format, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix credo --strict lib/verscienta_web/controllers/sitemap_controller.ex 2>&1 | tail -4
git add lib/verscienta_web/controllers/sitemap_controller.ex test/verscienta_web/controllers/sitemap_controller_test.exs lib/verscienta_web/router.ex priv/static/robots.txt priv/static/images/og-default.svg
git commit -m "feat(seo): cached sitemap.xml controller + robots.txt + default OG image"
```

---

## Task 5: Docs + full verification

**Files:** Modify `docs/todo.md`

- [ ] **Step 1: Check off the todo item**

In `docs/todo.md`, under "### Growth", change:
`- [ ] SEO: meta tags, Open Graph, sitemap, structured data for articles.`
to:
`- [x] SEO: meta tags, Open Graph, sitemap, structured data for articles. *(per-page OG/Twitter/canonical, NewsArticle JSON-LD, cached sitemap.xml, robots.txt; Growth slice 1)*`

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
Expected: credo "found no issues"; dialyzer ends "passed successfully". If dialyzer reports NEW errors (the `SEO` struct typespec or `seo_tags` attr are likely sources), paste them exactly and report BLOCKED.

- [ ] **Step 4: Commit**

```bash
git add docs/todo.md
git commit -m "docs: check off SEO foundations (Growth slice 1)"
```

- [ ] **Step 5:** Confirm all gates green — branch ready to merge.

---

## Notes for the implementer

- The dead render is the whole point: per-page `:seo` is set in `mount` (LiveViews) or the controller action (home), so it appears in the server-rendered `<head>` that crawlers/scrapers read. The connected socket never updates `<head>` (except `live_title`), which is fine — crawlers use the dead render.
- `SEO.build/1` returns a struct; the caller assigns it (`assign(socket, :seo, …)` or `assign(conn, :seo, …)`) — uniform across LiveView and controller.
- `seo_tags/1` reads `assigns[:seo] || SEO.default()` in `root.html.heex`, so any page that sets nothing still gets valid default tags.
- All image/canonical URLs are absolute (`abs_url` prefixes `VerscientaWeb.Endpoint.url()` for `/`-paths; passes through `http(s)` values like a CDN `cover_image_url`).
- JSON-LD is embedded with `</` → `<\/` escaping so a string containing `</script>` can't break out of the script tag.
- The default OG image is an **SVG placeholder**; some social scrapers don't render SVG og:images — slice 2 introduces raster per-article cards (and can supply a raster default). Articles with a `cover_image_url` already use that raster image.
- The sitemap reuses the standard eligibility filter (published, non-group, non-deactivated/anonymized author) and is cached for an hour under the `"sitemap"` tag.
