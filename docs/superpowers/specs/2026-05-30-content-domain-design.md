# Content Domain (Block Editor) Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-05-30
**Status:** Approved
**Phase:** 1 (MVP) — Subsystem 2 of 6
**Depends on:** Phase 0 foundation; Subsystem 1 (Auth & Profiles — `User`, roles, owner-only policy pattern, CodexComponents, `.text_field` form helper)
**Supersedes:** the earlier markdown-textarea content design (same date) — replaced after `docs/todo.md` mandated a Gutenberg-style block editor as the only Phase 1 editor.

## Goal

Add the core content layer: authors compose long-form articles in a **block editor** (an
ordered tree of typed blocks stored as JSONB), classify them by a fixed wellness category
plus free-form tags, move them through a draft→published workflow, and readers browse a feed,
per-category pages, and a styled reading view rendered server-side from the block tree.
RSS/API aggregation is a separate later subsystem.

## Decisions

| Decision | Choice |
|----------|--------|
| Content model | Single `Article` resource; body is a **JSONB block tree** (`blocks :: {:array, :map}`) |
| Block validation | Every incoming block runs through `Block.cast_all/1` (drops unknown types/keys, coerces fields) — server never trusts client shapes |
| Rendering | Server-side `BlockRenderer.to_html/1`, single path for reader + editor preview; sanitized |
| Editing | LiveView-native (inputs/textareas per block); only JS is one drag-reorder hook mirrored by move buttons |
| Block types (in scope) | paragraph, heading, list, blockquote, code, divider, markdown, callout (info/disclaimer), image (URL), embed (URL + provider allowlist) |
| Embeds | URL + detected provider (youtube/vimeo/link) → safe iframe for known providers, plain link otherwise. **No live oEmbed HTTP fetch** |
| Taxonomy | Fixed `category` atom enum + free-form `Tag` many-to-many |
| Publishing | Any signed-in user; `status` draft → published (+ archived); author-owned |
| UI scope | Block editor + reader + feed + category pages |
| Markdown | MDEx (Rust CommonMark) for the markdown block + callout text, sanitized |
| Images | URL only (uploads are Phase 2 — Cloudflare Images) |
| Deferred | autosave, revision history, markdown→blocks import (export only), per-block rich-text WYSIWYG (ProseMirror/contenteditable), live oEmbed |
| Routes | `/articles`, `/articles/:slug`, `/articles/new`, `/articles/:slug/edit`, `/c/:category` |

## Section 1: Data model — `Article` with a JSONB block tree

New Ash domain `Verscienta.Content` registered in `config :verscienta, ash_domains`.

### `Article` resource (`articles` table)
- `title` — `:string`, `allow_nil? false`, public, `max_length` 200.
- `slug` — `:string`, `allow_nil? false`, public; auto-derived from title on create; unique identity `unique_slug`.
- `excerpt` — `:string`, nullable, public, `max_length` 300.
- `blocks` — `{:array, :map}`, `allow_nil? false`, default `[]`, public. The ordered block tree (JSONB column).
- `cover_image_url` — `:string`, nullable, public.
- `category` — `:atom`, `allow_nil? false`, public, `one_of` the 8 category keys (see Section 5).
- `status` — `:atom`, `allow_nil? false`, default `:draft`, public, `one_of [:draft, :published, :archived]`.
- `evidence_level` — `:atom`, nullable, public, `one_of [:anecdotal, :emerging, :established]`.
- `published_at` — `:utc_datetime_usec`, nullable (stamped on first publish).
- `create_timestamp :inserted_at`, `update_timestamp :updated_at`.
- Relationships: `belongs_to :author, User` (`allow_nil? false`); `many_to_many :tags, Tag` through `ArticleTag`.
- Identity: `unique_slug` on `[:slug]`.

### `Tag` resource (`tags` table)
- `name` — `:ci_string`, unique (`unique_name`); `slug` — `:string`, unique (`unique_tag_slug`).
- `many_to_many :articles` through `ArticleTag`.
- Action `upsert_by_name` (find-or-create by name, generates slug).

### `ArticleTag` join (`article_tags` table)
- `belongs_to :article`, `belongs_to :tag`; composite PK / uniqueness on `[:article_id, :tag_id]`.

### Block shape
Each block is a map with string keys: `%{"id" => uuid, "type" => string, "data" => map}`.

| type | data keys |
|------|-----------|
| `paragraph` | `text` |
| `heading` | `text`, `level` (2–4) |
| `list` | `style` ("bullet"\|"number"), `items` ([string]) |
| `blockquote` | `text` |
| `code` | `text`, `language` (string, optional) |
| `divider` | — |
| `markdown` | `source` |
| `callout` | `variant` ("info"\|"disclaimer"), `text` |
| `image` | `url`, `alt`, `caption` |
| `embed` | `url`, `provider` ("youtube"\|"vimeo"\|"link") |

## Section 2: `Block` module — validation & normalization

`Verscienta.Content.Block` is the source of truth for block types.
- `known_types/0` → the in-scope type strings.
- `default(type)` → a fresh block map (with a generated `id`) for a given type, used when the editor inserts a block.
- `cast/1` → takes a raw (untrusted) block map, returns a normalized block: keeps only known `type`; coerces/whitelists `data` keys for that type; supplies safe defaults for missing fields; ensures an `id`. Unknown types return `nil` (dropped).
- `cast_all/1` → maps `cast/1` over a list and rejects `nil`. The `Article` create/update actions pipe incoming `blocks` through this so persisted data is always well-formed.
- For `embed`, `cast/1` derives `provider` from the URL (youtube/vimeo host detection → that provider; otherwise `"link"`).

`id` generation uses `Ash.UUID.generate/0` (app code; allowed).

## Section 3: Server-side block renderer

`Verscienta.Content.BlockRenderer.to_html(blocks)` (and `to_iodata/1`) walks the tree and renders each block to **sanitized** HTML:
- `paragraph`/`heading`/`blockquote`/`list`/`code` → escaped text in semantic tags (no raw HTML injection).
- `markdown`/`callout` text → `Verscienta.Content.Markdown.to_html/1` (MDEx, `unsafe: false`, sanitize on).
- `image` → `<figure><img src alt><figcaption></figure>` with the URL attribute-escaped.
- `embed` → for `youtube`/`vimeo`, a safe `<iframe>` built from a normalized embed URL (provider allowlist; no arbitrary src); for `link`, a plain anchor.
- `divider` → `<hr>`.
Unknown/malformed blocks are skipped. This is the **only** rendering path; the editor preview calls the same function so preview == published output.

`Verscienta.Content.Markdown.to_html/1` wraps MDEx with GitHub extensions on, raw HTML off, sanitize on. `Verscienta.Content.Slug.slugify/1` and `Verscienta.Content.Category` (8 categories → Codex accents) are shared helpers.

## Section 4: Actions & authorization

**Article actions**
- `create` — accepts `title, excerpt, cover_image_url, category, evidence_level`, an argument `blocks` (list of raw maps) piped through `Block.cast_all/1`, and an argument `tags` (list of names); sets `author_id` from actor; generates a unique `slug`; status defaults `:draft`.
- `update` — same editable fields + `blocks` (re-cast) + `tags` (re-synced).
- `publish` — `status: :published`, stamps `published_at` if nil.
- `archive` — `status: :archived`.
- Reads: default `read`; `list_published` (status=published, newest first); `get_published_by_slug` (published only); `list_by_category` (published in one category, newest first).

**Tag actions** — `upsert_by_name` (find-or-create, slug-gen).

**Policies (Article)**
- `create` → `authorize_if actor_present()`.
- `update`/`publish`/`archive` → `authorize_if expr(author_id == ^actor(:id))`.
- reads → `authorize_if expr(status == :published)` OR `authorize_if expr(author_id == ^actor(:id))` (anonymous actor → only published, since the author check can't match a nil actor).

**Policies (Tag)** — read public; `upsert_by_name` requires a signed-in actor.

## Section 5: Categories, accents & slugs

Single source of truth `Verscienta.Content.Category`: `{key, label, slug, accent}` + helpers (`all/0`, `keys/0`, `get/1`, `from_slug/1`, `accent/1`, `select_options/0`).

| Key | Label | Slug | Accent |
|-----|-------|------|--------|
| `:nutrition` | Nutrition | nutrition | sport |
| `:herbalism` | Herbalism | herbalism | business |
| `:mindfulness` | Mindfulness | mindfulness | culture |
| `:movement` | Movement | movement | tech |
| `:functional_medicine` | Functional Medicine | functional-medicine | world |
| `:tcm` | TCM | tcm | politics |
| `:ayurveda` | Ayurveda | ayurveda | opinion |
| `:environment` | Environment | environment | zune |

Article slug generated from title (downcase, non-alphanumeric→hyphen, trim); collision appends a short unique suffix; DB unique index is the final guard.

## Section 6: The block editor LiveView

`/articles/new` and `/articles/:slug/edit` (`on_mount :live_user_required`; edit is author-only else 404). The LiveView holds the block list in socket assigns and mutates it via events — **no client-side store**:
- **Metadata fields** (above the canvas): title, category `<select>`, tags input (comma-separated), excerpt, cover-image URL — bound via `AshPhoenix.Form` for create/update.
- **Add block** — a block-type menu (the "slash"/"+" menu); selecting a type calls `Block.default/1` and inserts it (append, or after a focused block).
- **Edit block** — each block renders LiveView-native inputs (textarea for paragraph/markdown/code/blockquote/callout text; text input for heading; repeating inputs for list items; selects for heading level, list style, callout variant; URL/alt/caption inputs for image; URL input for embed). `phx-change` events update that block in the assigns tree.
- **Reorder** — move-up / move-down buttons (server-side, fully testable) **plus** one small JS hook (`assets/js`) for drag-to-reorder that emits the same `reorder` event.
- **Delete / duplicate** per block.
- **Live preview** pane renders the current tree via `BlockRenderer`.
- **save draft** / **publish** buttons. Save persists `blocks` (cast again server-side) + metadata + tags; publish then flips status.

## Section 7: Reader, feed, category pages, nav

- **Reader** `/articles/:slug` (`:live_user_optional`) — light reading canvas: category-accent kicker, title, author (`@username` link) + relative date + evidence meta, `BlockRenderer` output, then the medical-disclaimer block. Unknown/unpublished → 404 (author may view own draft).
- **Feed** `/articles` (`:live_user_optional`) — published articles as Codex `news_card`s, newest first.
- **Category** `/c/:category` (`:live_user_optional`) — one category's published articles, themed with its accent; unknown category → 404.
- **Nav** — add a `write` link (→ `/articles/new`) in the signed-in branch of the top strip.

## Section 8: Testing

**Domain (DataCase)**
- Slug auto-generated + collision yields distinct slug.
- `publish` stamps `published_at`; re-publish keeps the original time.
- Author-only: non-author cannot update/publish/archive.
- Draft privacy: `list_published` excludes drafts; author reads own draft; non-author cannot.
- `list_by_category` filters to published in that category.
- Tag find-or-create reuses existing, creates new; join is correct.

**Block layer**
- `Block.cast_all/1` drops unknown types and strips non-whitelisted keys; supplies defaults; assigns ids; derives embed provider from URL.
- `BlockRenderer.to_html/1` renders each in-scope type, and **strips a `<script>` payload** in markdown/text/embed/image fields.

**Web (ConnCase / LiveView)**
- Editor requires auth; add a block; edit its text (preview updates); reorder via the move event; delete a block; save draft persists the block tree; publish.
- Reader renders a published article (title + a rendered block + disclaimer); 404s a draft for a non-author.
- Feed renders published; a category page renders its published articles and 404s unknown categories.

**Quality gates:** existing CI — `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test`. Migrations via `mix ash.codegen`.

## Out of Scope (deferred)

- RSS/API aggregation + `Source` resource (next subsystem).
- Cover/inline image uploads (Phase 2 — Cloudflare Images).
- Autosave, revision history, markdown→blocks import (blocks→markdown export is allowed/simpler).
- Per-block rich-text WYSIWYG (ProseMirror/contenteditable) and slash-menu polish beyond a basic type picker.
- Live oEmbed resolution (embeds use a provider allowlist + safe iframe).
- Comments, reactions, bookmarks (Engagement subsystem); search indexing (Meilisearch subsystem); AI summarization/auto-tagging (Phase 2); moderation/expert gating (later).

## Definition of Done

- A signed-in user can compose an article from typed blocks at `/articles/new`, see a live preview rendered by `BlockRenderer`, reorder/delete blocks, save a draft, publish, and edit it later.
- Block data is always server-validated (`Block.cast_all/1`); rendering is sanitized (a `<script>` payload is stripped); embeds use a provider allowlist.
- Drafts are private to the author; `/articles/:slug` shows published articles with the medical disclaimer and 404s drafts for non-authors.
- `/articles` lists published; `/c/:category` lists a category's articles with the correct accent; unknown slugs/categories 404.
- Categories resolve through `Content.Category`; tags are reused via find-or-create.
- All tests pass; CI green; migrations + seeds committed on `phase-1-content`.
