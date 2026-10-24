# Block Editor Completion — Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


Finishes the Gutenberg-style block editor (todo.md Content Domain, lines 79–88).
Four deferred capabilities, built as independent slices on `content-block-editor`:

1. **Slice 1 — Block ergonomics:** duplicate, "/" slash menu, keyboard nav +
   focus management, toolbar ARIA. (todo lines 82, 87)
2. **Slice 2 — Autosave + revision history.** (todo line 84)
3. **Slice 3 — Markdown round-trip:** import markdown → blocks on first edit
   of an aggregated article; export blocks → markdown. (todo line 86)
4. **Slice 4 — Per-block rich text** via a contenteditable hook. (todo line 83)

## Goal

Authors get a fast, keyboard-friendly editor that never loses work, produces
clean typed-block content from aggregated markdown, and supports inline
formatting — without adding any JS dependency or changing the block data model.

## Decisions

- **No ProseMirror.** Assets are deliberately vendored (no npm supply chain —
  see deps audit); ProseMirror is ~6 packages to vendor and maintain. The todo
  explicitly allows "contenteditable + a small command palette" instead.
- **Inline markdown is the rich-text wire format.** Block `data.text` stays a
  string; rich text is expressed as inline markdown (`**b**`, `*i*`,
  `[t](url)`). The contenteditable hook renders/edits formatted text
  client-side and serializes a constrained DOM (strong/em/a only) back to
  inline markdown pushed through the existing `block_change` event. The server
  never receives or trusts HTML; `BlockRenderer` renders inline markdown
  through the existing sanitized MDEx pipeline. Old plain-text content is
  unaffected unless it already contains markdown syntax (acceptable).
- **Autosave creates the draft on first change** in `:new` mode (once a title
  exists), then `push_patch`es to edit mode; subsequent autosaves update.
  Debounce 2s server-side via `Process.send_after` reset on every change. No
  navigation on autosave; a "saved · HH:MM" indicator in the form.
- **Revisions are snapshots, capped.** New `Content.ArticleRevision` resource
  (article_id, title, excerpt, blocks JSONB, inserted_at), system-only writes
  (`forbid_if always()` + `authorize?: false` from the editor save path),
  reads policy-scoped to the article's author. One snapshot per successful
  save (explicit or autosave) **iff blocks/title changed since the last
  revision**; keep the most recent 30 per article (prune on insert). Restore
  loads a revision into editor state only — nothing persists until save.
- **Markdown import/export is a pure module** (`Content.BlockMarkdown`):
  - `to_blocks/1`: markdown → typed blocks using the MDEx AST (heading,
    paragraph, list, blockquote, code; everything else falls back to a
    markdown block). Used on first edit of an aggregated article (its body is
    a single markdown block today — fetcher.ex).
  - `to_markdown/1`: blocks → markdown string (syndication; inverse of the
    above; image → `![](url)`, divider → `---`, callout → blockquote with
    **Note:** prefix, embed → bare URL).
- **Slash menu is LiveView-rendered.** A tiny colocated hook detects "/" typed
  into an empty block and Escape/arrows/Enter; menu state (open block index +
  filter + active item) lives in assigns; selecting converts the block's type
  (preserving id) — matching how everything else in this editor flows through
  events.
- **Keyboard nav:** Alt+ArrowUp/Down moves the focused block (reuses
  `move_block`), Ctrl/Cmd+D duplicates, Ctrl/Cmd+Shift+Backspace deletes;
  after add/duplicate/delete, focus moves to the affected block's input
  (`push_event` + a small hook listening for `editor:focus_block`). Block
  toolbar gets `role="toolbar"` + `aria-label`s; the block list gets
  `role="list"`/`listitem` and `aria-roledescription="block"`.

## Architecture

### Slice 1 — ergonomics (editor-only)
- `duplicate_block` event: copy block at index, fresh `"id"`, insert at
  index+1.
- Slash menu: `assign(:slash, %{index: i, filter: "", active: 0} | nil)`;
  hook `.SlashMenu` (colocated) pushes `slash_open`/`slash_filter`/
  `slash_pick`/`slash_close`; menu lists `Block.known_types()` filtered by
  prefix; pick replaces the empty block's type via `Block.default(type)`
  keeping the original id.
- Focus: `editor:focus_block` push_event with the block id; `BlockReorder`
  hook (already mounted on #blocks) gains a `handleEvent` for it.

### Slice 2 — autosave + revisions
- `Content.ArticleRevision` Ash resource + migration
  (`article_revisions`: id, article_id FK delete cascade, title, excerpt,
  blocks jsonb, inserted_at; index `(article_id, inserted_at DESC)`).
- Editor: every `block_change`/`validate`/structural event schedules
  `Process.send_after(self(), :autosave, 2_000)` (cancel prior ref);
  `handle_info(:autosave, ...)` runs the same `submit/2` path with
  `autosave?: true` (no navigate, no flash; assigns `last_saved_at`).
  In `:new` mode autosave only fires once the title is non-blank; on success
  `push_patch` to `/articles/:slug/edit`.
- Snapshot: after any successful editor save, `Content.snapshot_revision/1`
  (skip if identical to latest), prune to 30.
- UI: "history" disclosure listing revisions (relative time); "restore" event
  loads that revision's blocks/title into assigns (marks dirty, schedules
  autosave like any other edit).

### Slice 3 — markdown round-trip
- `Content.BlockMarkdown.to_blocks/1` + `to_markdown/1` (pure, MDEx AST via
  `MDEx.parse_document/1`).
- Editor `mount_mode` (edit): if `article.aggregated?` and blocks ==
  exactly one markdown block, replace editor state with
  `to_blocks(source)` (in-memory import; persists on first save).
- Export surface: `Content.BlockMarkdown.to_markdown/1` public for
  syndication callers; round-trip property: `to_markdown |> to_blocks`
  preserves block types/text for the core types.

### Slice 4 — rich text
- Hook `RichText` (assets/js/hooks/rich_text.js, external — it manages its own
  DOM so `phx-update="ignore"`): contenteditable div per text-ish block
  (paragraph, heading, blockquote, callout, list items NOT included — lists
  keep the textarea). Renders initial content from a `data-md` attr (server
  renders the inline markdown to HTML via the sanitized pipeline);
  `beforeinput`/`input` serializes DOM → inline markdown (strong/em/a
  whitelist; everything else flattened to text) and pushes the existing
  `block_change` payload (debounced 300ms client-side).
- Command palette: floating toolbar on selection inside the hook (Bold,
  Italic, Link); Ctrl/Cmd+B/I/K shortcuts; all formatting applied by editing
  the DOM with `document.execCommand`-free range ops constrained to the
  whitelist.
- Server: `BlockRenderer` paragraph/heading/blockquote/callout text rendered
  with `Markdown.render_inline/1` (new — MDEx with sanitize, inline-only,
  strips block elements); editor preview unchanged (it already goes through
  BlockRenderer).
- Fallback: if the hook fails to mount, the textarea remains the editing
  surface (progressive enhancement: textarea is rendered for `:noscript` /
  non-upgraded states — concretely we keep the textarea and the hook replaces
  it on mount).

## Testing

- Slice 1: LiveViewTest — duplicate produces a new id at index+1; slash pick
  converts an empty paragraph to the chosen type; menu only opens for empty
  blocks; ARIA attrs present.
- Slice 2: autosave message persists a draft (send(view.pid, :autosave) after
  render_change), creates exactly one revision per content change, prunes at
  30, restore round-trips; new-mode autosave creates draft + patches URL.
  Revision policy: non-author cannot read another's revisions.
- Slice 3: unit tests per block type both directions + round-trip test;
  editor mount of an aggregated single-markdown-block article yields typed
  blocks.
- Slice 4: server-side — render_inline sanitizes (script/img/div stripped,
  strong/em/a kept, non-http(s) hrefs dropped); block_change with inline
  markdown persists and renders. Hook DOM behavior is exercised manually
  (documented in the plan's verify step) — no JS unit harness exists in this
  repo.

## Out of scope

- Per-user editor preference / markdown-only mode (todo line 88 explicitly).
- Collaborative editing/cursors; revision diff UI (list + restore only).
- Rich text inside list items / code / embed blocks.

## Deviations from this design (as built)

- **Formatting via `document.execCommand`** (bold/italic/createLink), not
  hand-rolled range ops: far less code, and the serializer whitelist
  normalizes the output regardless, so the constraint holds at the boundary
  that matters. Revisit only if execCommand removal actually ships in
  browsers.
- **`render_inline/1` escapes input BEFORE the markdown pass** so HTML typed
  into block text renders literally instead of being silently stripped by
  the sanitizer (CommonMark decodes entities, making this round-trip safe).
- **Rich blocks push `rich_change` keyed by block id**, not the index-keyed
  `block_change`: indexes inside a `phx-update="ignore"` element go stale
  when blocks reorder around it. External rewrites (assist apply, revision
  restore) bump a `data-rev` attr; the hook resets its DOM only then, so the
  caret survives normal typing.
- **No textarea fallback for rich blocks**: a LiveView editor is inert
  without JS anyway; the contenteditable div is the only surface for
  paragraph/heading/blockquote/callout. The slash-menu key protocol is
  implemented in both the `.SlashMenu` textarea hook and the `RichText` hook.
- **`/articles/new` does push_patch to the edit URL** after the first
  autosave (an empty `handle_params` was added).

## Files touched (summary)

- `lib/verscienta_web/live/article_editor_live.ex` (all slices)
- `assets/js/hooks/block_reorder.js` (focus handling), new
  `assets/js/hooks/rich_text.js`, colocated `.SlashMenu` hook
- `lib/verscienta/content/article_revision.ex` (+ migration), `content.ex`
- `lib/verscienta/content/block_markdown.ex`
- `lib/verscienta/content/markdown.ex` (`render_inline/1`),
  `block_renderer.ex`
- `docs/todo.md` checkboxes per slice
