# SEO Foundations Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-05
**Status:** Approved
**Phase:** 3 — Intelligence & Growth · Growth (slice 1 of 4)
**Depends on:** the root layout (`root.html.heex`), `Verscienta.Content.Article`/`Category`, `Verscienta.Cache`, verified routes (`url/1`). No new dependency.

## Goal

Make every public page crawlable and richly shareable: per-page meta description + Open Graph / Twitter-card tags + canonical URL, JSON-LD `NewsArticle` structured data on article pages, a dynamic `sitemap.xml`, and a `robots.txt` that points to it. Private pages are marked `noindex`. The LiveView **dead render** (the initial server-rendered GET) is what crawlers and social scrapers see, so per-page SEO data is set in `mount` and rendered into `<head>` from a shared component.

## Decomposition context

Growth splits into 4 slices: **1 (this — SEO foundations)**, 2 (social card images), 3 (PostHog analytics), 4 (onboarding flow). Slice 1 is foundational — slice 2's generated images replace the OG image URL this slice wires up.

## Decisions

| Decision | Choice |
|----------|--------|
| Coverage | Comprehensive: article pages get full OG + JSON-LD; home/feed/category/profile get tailored title+description+canonical; private pages `noindex`; everything unset falls back to site defaults |
| Mechanism | A `%SEO{}` struct assigned as `:seo` in each LiveView's `mount`; a `seo_tags` component in `root.html.heex` renders it (dead render → crawler-visible) |
| JSON-LD type | `NewsArticle` |
| Article OG image | `cover_image_url \|\| site default` (slice 2 swaps in a generated card URL) |
| Sitemap | `GET /sitemap.xml` controller (published articles + key public routes), cached ~1h |
| robots.txt | static; allow crawl, `Sitemap:` line, `Disallow: /admin` |
| URLs | absolute via `url/1` |

## Section 1: `VerscientaWeb.SEO`

New module `lib/verscienta_web/seo.ex`:

```elixir
defstruct title: nil,
          description: nil,
          canonical: nil,
          og_image: nil,
          og_type: "website",
          noindex: false,
          json_ld: nil
```

- `@site_name "Verscienta News"`, `@default_description` (one-line site tagline), `@default_og_image` = `"/images/og-default.png"` (absolute-ized at render).
- `default/0` → `%SEO{}` with the site defaults.
- `assign_seo(socket_or_assigns, attrs)` → merges `attrs` (a keyword/map) onto `default/0` and assigns `:seo`. Page code calls e.g. `assign_seo(socket, title: "...", description: "...", canonical: url(~p"/c/#{cat}"))`.
- `article(article)` → a fully-built `%SEO{}` for an article:
  - `title: article.title`
  - `description:` `article.excerpt` (trimmed/truncated ~200 chars; falls back to default description if blank)
  - `canonical: url(~p"/articles/#{article.slug}")`
  - `og_image:` `article.cover_image_url || @default_og_image`
  - `og_type: "article"`
  - `json_ld: news_article_json_ld(article)`
- `news_article_json_ld(article)` → a plain map:
  ```
  %{
    "@context" => "https://schema.org",
    "@type" => "NewsArticle",
    "headline" => article.title,
    "description" => <excerpt or default>,
    "image" => <absolute og_image>,
    "datePublished" => <ISO8601 published_at>,
    "dateModified" => <ISO8601 updated_at>,
    "author" => %{"@type" => "Person", "name" => <author display_name/username>},
    "publisher" => %{"@type" => "Organization", "name" => @site_name},
    "mainEntityOfPage" => <canonical>
  }
  ```
  The article must be loaded with `:author`. `nil` dates are omitted (drop nil-valued keys).
- `site_name/0`, `default_og_image/0` exposed for the component.
- Absolute-URL helper: a private `abs_url(path)` that prefixes the endpoint URL when `path` starts with `/` (so `cover_image_url` already-absolute values pass through; the default `/images/...` becomes absolute).

The `og:image` and JSON-LD `image` must be absolute.

## Section 2: `seo_tags` component in `root.html.heex`

Add a function component (in `VerscientaWeb.Layouts` or a small `SEOComponents`) `seo_tags/1` that takes `seo` and renders into `<head>`:
- `<meta name="description" content={seo.description} />`
- `<link rel="canonical" href={seo.canonical} />` (only when set)
- `<meta name="robots" content="noindex, nofollow" />` only when `seo.noindex`
- Open Graph: `og:site_name`, `og:title` (seo.title or site name), `og:description`, `og:type`, `og:url` (canonical), `og:image` (absolute)
- Twitter: `twitter:card` = `summary_large_image`, `twitter:title`, `twitter:description`, `twitter:image`
- JSON-LD: when `seo.json_ld`, `<script type="application/ld+json">{Phoenix.HTML.raw(safe_json(seo.json_ld))}</script>` where `safe_json` is `Jason.encode!/1` with `</` escaped (e.g. `String.replace("</", "<\\/")`) to be safe inside a `<script>`.

In `root.html.heex`, compute `seo = assigns[:seo] || VerscientaWeb.SEO.default()` and render `<.seo_tags seo={seo} />` right after the existing `<.live_title>`. The `<.live_title>` (page_title) is unchanged.

## Section 3: Per-page wiring

- **`ArticleReaderLive`** (`mount`): `assign(socket, :seo, SEO.article(article))` (the article is already loaded with `:author`/`:tags`). Keep the existing `page_title`.
- **`ArticleFeedLive`** (home/feed), **`CategoryLive`**, **public profile LiveView** (`/@:username`): `SEO.assign_seo(socket, title:, description:, canonical:)` — category uses the category label + description; profile uses display name + bio; feed/home uses site tagline. Default OG image, `og_type "website"`.
- **Private pages** — `SettingsLive`, the `admin/*` LiveViews, `GoodbyeLive`: `SEO.assign_seo(socket, noindex: true)` (plus their normal title). Best-effort for AshAuthentication-generated auth pages: covered by `robots.txt` `Disallow` where not assignable.
- Any LiveView/page that sets no `:seo` → root falls back to `SEO.default/0`.

## Section 4: Sitemap + robots

- New `VerscientaWeb.SitemapController` with `index/2` → `GET "/sitemap.xml"` (added to the router's browser/public scope, outside auth). Builds, **cached** in `Verscienta.Cache` under `"sitemap:xml"`, TTL `3_600_000`, tag `"sitemap"`:
  - all published, non-group, non-deactivated/anonymized-author articles → `<url><loc>{canonical}</loc><lastmod>{updated_at date}</lastmod></url>`
  - static public routes: `/` , `/articles`, and `/c/{category}` for each `Category.all()`.
  - Valid `<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">…</urlset>`; response `content-type: application/xml`. XML-escape any interpolated text (titles are not in the sitemap, only URLs + dates, but escape defensively).
- **`priv/static/robots.txt`** (already a static path) updated:
  ```
  User-agent: *
  Allow: /
  Disallow: /admin

  Sitemap: <host>/sitemap.xml
  ```
  (Host is the production URL; use the configured endpoint host. If a literal is needed, use the prod canonical host.)
- Add the default OG image asset `priv/static/images/og-default.png` (a simple branded placeholder; a small generated/static PNG is fine).

## Section 5: Testing

- **`VerscientaWeb.SEO`** (unit): `default/0` has site name + default image + `og_type "website"` + `noindex false`; `article/1` → `og_type "article"`, canonical absolute (`https://…/articles/<slug>`), `og_image` falls back to default when `cover_image_url` is nil and passes through when present, description from excerpt, `json_ld` is a NewsArticle map with headline/image(absolute)/datePublished/author/publisher and no nil-valued keys.
- **Dead-render** tests (the crawler's view — use `Phoenix.ConnTest.get/2` on the LiveView routes so we read the rendered HTML head, not the connected socket):
  - `GET /articles/<slug>` HTML contains `property="og:title"` with the title, `property="og:image"`, `rel="canonical"`, and an `application/ld+json` script containing `"@type":"NewsArticle"`.
  - `GET /c/<category>` contains a tailored `<meta name="description">` and canonical.
  - `GET /settings` (signed in) contains `name="robots"` `noindex`.
- **`SitemapController`**: `GET /sitemap.xml` → 200, `content-type` includes `xml`, body contains a published article's canonical URL and the home/category routes, excludes a draft's URL; second call is served from cache (assert via cache presence or identical body).
- Full suite + `credo --strict` + `dialyzer` + `mix format` green.

## Out of scope (deferred)

Per-article generated card images (slice 2); PostHog/analytics (slice 3); onboarding (slice 4); hreflang/i18n alternates; AMP; the Google `<news:>` sitemap extension; image sitemaps; dynamic per-page `<title>` beyond the existing `page_title`.

## Definition of Done

- `VerscientaWeb.SEO` (`default/0`, `assign_seo/2`, `article/1`, `news_article_json_ld/1`, absolute-URL handling) + unit tests.
- `seo_tags/1` component rendered from `assigns[:seo]` in `root.html.heex` (description, canonical, OG, Twitter, robots-noindex, JSON-LD), with `</script>`-safe JSON.
- Article reader (full OG + NewsArticle JSON-LD), home/feed/category/profile (tailored), private pages (`noindex`) wired; safe default fallback.
- `GET /sitemap.xml` controller (eligibility-filtered published articles + public routes), cached ~1h; `robots.txt` updated with `Sitemap:` + `Disallow: /admin`; default OG image asset added.
- Dead-render + SEO unit + sitemap tests; full suite + credo + dialyzer + format green.
- `docs/todo.md` SEO item checked off. No new dependency.
