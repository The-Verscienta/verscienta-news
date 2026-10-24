# Social Card Images Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-05
**Status:** Approved
**Phase:** 3 — Intelligence & Growth · Growth (slice 2 of 4)
**Depends on:** slice 1 (SEO — `VerscientaWeb.SEO.article/1` wires `og_image`), `Verscienta.Images` (Cloudflare Images upload + delivery), Oban, `Verscienta.Content.Article`.
**New dependency:** `:image` (Vix/libvips) + the `libvips` system package + a TTF font in the Docker image.

## Goal

Generate a branded 1200×630 social-share card per published article and serve it as the Open Graph / Twitter image. Replaces slice 1's placeholder default for articles: a titled, branded card previews far better on social platforms than a bare cover photo or a generic site image. Rendered server-side with libvips (no browser), generated on publish by an Oban worker, uploaded to Cloudflare Images, and the CDN URL stored on the article.

## Decomposition context

Growth slices: 1 (SEO — shipped), **2 (this — social card images)**, 3 (PostHog), 4 (onboarding). This slice fills in the OG image that slice 1's tags reference.

## Decisions

| Decision | Choice |
|----------|--------|
| Engine | **libvips via `:image`** (server-side compose; no browser) |
| Pipeline | **Generate on publish** via an Oban worker → upload to Cloudflare Images → store URL on the article |
| Storage | new nullable `og_image_url` on `Article`, set by an internal no-hooks `:set_og_image` action |
| Cloudflare variant | reuse the existing **`:public`** variant (card is pre-sized 1200×630) |
| OG image priority | **generated card → `cover_image_url` → site default** |
| Regeneration | enqueue on `:publish`, `:create_aggregated`, `:ai_enrich`; on `:update` only when `title` or `cover_image_url` changed |
| Font | an installed **system sans** (e.g. DejaVu/Liberation) in v1 |
| Failure | render/upload error → worker retries; `og_image_url` stays nil → SEO falls back |

## Section 1: Renderer — `Verscienta.Content.OgCard`

New module `lib/verscienta/content/og_card.ex`:
- `render(article) :: {:ok, binary} | {:error, term}` — produces PNG bytes for a 1200×630 card via `:image` (Vix/libvips):
  - background: dark canvas `#0c0c0c` (full 1200×630);
  - a thin category-accent bar (use the category's accent color via `Category`/the design tokens; a simple solid rectangle along the top or left);
  - **title**: `article.title`, rendered as a Pango text image (large bold, white, wrapped to a max width ~1040px, capped at ~3 lines with an ellipsis if longer), composited with padding;
  - footer row: the category label (uppercase, small, accent-tinted) + the `verscienta·news` wordmark (the `·` tinted `#F2660A`);
  - flatten/compose to a single sRGB image, export to PNG (`Image.write/3` to `:memory` with `suffix: ".png"`).
- Pure given the article (no DB, no Cloudflare) — returns bytes. Robust to long titles (wrap+truncate) and empty/odd titles (render something non-crashing).
- Layout constants (size, padding, font sizes, max lines) as module attributes.

Use `:image` (`Image.Text.text/2` for Pango-wrapped title, `Image.new/3` for the canvas, `Image.compose/3` for layering). The exact API is pinned in the plan against the installed `:image` version.

## Section 2: Storage — `og_image_url` + `:set_og_image`

In `lib/verscienta/content/article.ex`:
- attribute `og_image_url, :string` (nullable, public read).
- action `:set_og_image` (update; accepts `:og_image_url`; **no change modules / no enqueue** — loop-safe, exactly like the existing `:set_embedding`).
- Migration adding the `og_image_url` column (`mix ash.codegen` or a hand-written migration matching the project's convention).

## Section 3: Pipeline — worker + enqueue

- `lib/verscienta/content/workers/generate_og_card_worker.ex` (`Verscienta.Content.Workers.GenerateOgCardWorker`, Oban, queue `:default` or the project's media queue):
  1. load the article (with `:author` if the card needs it — title/category suffice);
  2. `{:ok, png} = OgCard.render(article)`;
  3. `{:ok, url} = Verscienta.Images.upload_image(png, "og-#{article.slug}.png", :public)`;
  4. update via `:set_og_image` with `url`.
  - On `{:error, _}` from render/upload → return the error so Oban retries; leave `og_image_url` unchanged.
- `lib/verscienta/content/article/changes/enqueue_og_card.ex` (`EnqueueOgCard`, mirrors `EnqueueEmbedding`): on `after_action`, enqueue `GenerateOgCardWorker` with the article id.
- Wire `EnqueueOgCard` into the Article actions: `:publish`, `:create_aggregated`, `:ai_enrich` (always), and `:update` **guarded** — only enqueue when `title` or `cover_image_url` changed (use `Ash.Changeset.changing_attribute?/2` in the change). This avoids re-rendering on unrelated edits.

## Section 4: SEO wiring

In `lib/verscienta_web/seo.ex`, change `article/1`'s image resolution to prefer the generated card:
```elixir
image = abs_url(a.og_image_url || a.cover_image_url || @default_og_image)
```
(`og_image_url` is an absolute Cloudflare URL → passes through `abs_url`.) The JSON-LD `image` uses the same value (already wired). No other SEO change.

## Section 5: Infrastructure

- `mix.exs`: add `{:image, "~> 0.x"}` (pin the current version at plan time); `mix deps.get`.
- Dockerfile (dev + prod stages as applicable): install `libvips` (e.g. `apt-get install -y libvips` / `libvips42`) and a TTF font package (e.g. `fonts-dejavu-core` or `fonts-liberation`) so Pango has a usable family; rebuild the app image (`docker compose build app`).
- Smoke-verify after rebuild: `:image` loads and renders a trivial PNG inside the container.
- This infra lands **first** (renderer/worker tests need libvips present).

## Section 6: Testing

- **`OgCard.render/1`**: returns `{:ok, png}` whose first bytes are the PNG signature (`<<0x89, 0x50, 0x4E, 0x47>>`); handles a very long title and a 1-char title without raising; output is non-trivial in size.
- **`GenerateOgCardWorker`**: with the `Images.Client` stub returning a fake id/url, processing the job sets `article.og_image_url` to the delivered URL. (Render runs for real → needs libvips.)
- **`EnqueueOgCard`**: publishing an article `assert_enqueued`s `GenerateOgCardWorker` with the id; an unrelated `:update` (e.g. excerpt only) does NOT enqueue; a title change does.
- **`SEO.article/1`**: og_image priority — returns `og_image_url` when set, else `cover_image_url`, else the default (extend the slice-1 SEO test).
- Migration applies cleanly; full suite + `credo --strict` + `dialyzer` + format green.

## Out of scope (deferred)

Using the cover image as the card background; the brand font (Hanken Grotesk) in the card; deleting orphaned Cloudflare cards on regeneration; cards for non-article pages (home/category); on-the-fly card variants/AB; localized cards.

## Definition of Done

- `Verscienta.Content.OgCard.render/1` (libvips, 1200×630 branded card, wrapped title, accent + wordmark) → PNG bytes; tested.
- `Article.og_image_url` + `:set_og_image` action + migration.
- `GenerateOgCardWorker` (render → Cloudflare upload → set URL, retry-safe) + `EnqueueOgCard` wired to publish/create_aggregated/ai_enrich and title/cover-changed updates.
- `SEO.article/1` prefers `og_image_url` (→ cover → default).
- `:image` dep + libvips + font in the Docker image; smoke-verified.
- Tests across renderer / worker / enqueue / SEO priority; migration applies; full suite + credo + dialyzer green.
- `docs/todo.md` social-card item checked off.
