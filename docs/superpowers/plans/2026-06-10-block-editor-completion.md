# Block Editor Completion — Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


Design: `docs/superpowers/specs/2026-06-10-block-editor-completion-design.md`
Branch: `content-block-editor`. Verify each task with the listed tests +
`mix compile --warnings-as-errors`; full `mix precommit` at slice boundaries.

## Slice 1 — block ergonomics

### Task 1: duplicate block
- [x] `duplicate_block` event in `ArticleEditorLive`: copy block at index with
      a fresh `"id"` (`Block.regenerate_id/1` or inline), insert at index+1;
      clear `:assist` (stale index) like move/delete do.
- [x] Toolbar button ("dup") between move and delete.
- [x] Tests: duplicating yields same type/text, different id, at index+1;
      duplicate clears an open assist panel.

### Task 2: "/" slash menu
- [x] Colocated `.SlashMenu` hook on each block textarea: "/" in an EMPTY
      field pushes `slash_open` (index); typing filters via `slash_filter`;
      ArrowUp/Down move active; Enter pushes `slash_pick`; Escape closes.
- [x] Assigns `:slash` (`%{index, filter, active}` | nil); menu renders the
      filtered `Block.known_types()`; pick swaps the block for
      `Block.default(type)` with the ORIGINAL id (reorder stability).
- [x] Tests: pick converts empty paragraph → chosen type keeping id; filter
      narrows; menu closes on pick/escape; non-empty block does not open.

### Task 3: keyboard nav + focus + ARIA
- [x] `BlockReorder` hook: keydown Alt+ArrowUp/Down → push `move_block`;
      Ctrl/Cmd+D → `duplicate_block`; handleEvent `editor:focus_block`
      focuses the block's input by block id.
- [x] Server pushes `editor:focus_block` after add/duplicate/slash-pick.
- [x] `role="toolbar"` + `aria-label` on per-block controls, `role="list"`/
      `listitem` + `aria-roledescription="block"` on the block list,
      `aria-keyshortcuts` on move buttons.
- [x] Tests: ARIA attrs present; add_block pushes focus event (assert via
      `assert_push_event`).

## Slice 2 — autosave + revisions

### Task 4: `Content.ArticleRevision`
- [x] Resource + migration `article_revisions` (article_id FK cascade, title,
      excerpt, blocks jsonb, inserted_at; index (article_id, inserted_at)).
- [x] Policies: creates forbidden (system-only), reads
      `articles.author_id == actor` via relationship filter.
- [x] `Content.snapshot_revision/1`: skip if identical (title+blocks) to
      latest; prune to newest 30.
- [x] Tests: snapshot/skip/prune; non-author read filtered.

### Task 5: editor autosave
- [x] Debounce: every content-mutating event resets a 2s
      `Process.send_after(self(), :autosave, ...)` timer (ref in assigns).
- [x] `handle_info(:autosave, ...)`: `:edit` → submit current form+blocks (no
      navigate/flash), assign `last_saved_at`, snapshot revision; `:new` with
      non-blank title → create draft, `push_patch` to edit URL; `:new` blank
      title → skip, re-arm nothing.
- [x] "saved · %H:%M" indicator near the save button.
- [x] Explicit save/publish also snapshot (single chokepoint in `submit/2`'s
      success path).
- [x] Tests: change → send :autosave → draft persisted + revision written;
      blank-title new-mode autosave persists nothing; indicator renders.

### Task 6: history + restore
- [x] "history" disclosure listing latest revisions (relative time, count).
- [x] `restore_revision` event (id): loads title/excerpt/blocks into assigns
      (form params + blocks), schedules autosave; nothing written directly.
- [x] Tests: restore swaps editor blocks; a later save persists them; another
      author's revision id is rejected (policy read returns nothing).

## Slice 3 — markdown round-trip

### Task 7: `Content.BlockMarkdown`
- [x] `to_blocks/1`: MDEx AST → typed blocks (heading 2–4 clamp, paragraph,
      list (bullet/ordered → items), blockquote, code; image-only paragraph →
      image block; thematic break → divider; anything unhandled → markdown
      block passthrough of that segment).
- [x] `to_markdown/1`: inverse for all 10 types (callout → `> **Note:** …`,
      embed → bare URL line, divider → `---`).
- [x] Tests: per-type both directions; mixed-document round-trip preserves
      types + text; pathological/empty input → [].

### Task 8: aggregated import on first edit
- [x] `mount_mode(:edit)`: if `article.aggregated?` and blocks = exactly one
      markdown block → editor state becomes `to_blocks(source)` (memory only;
      persisted by the user's first save/autosave).
- [x] Tests: editor mount of aggregated article shows typed blocks; saving
      persists them; non-aggregated articles untouched.

## Slice 4 — per-block rich text

### Task 9: inline markdown rendering server-side
- [x] `Markdown.render_inline/1`: sanitized MDEx render constrained to inline
      output (unwrap the single `<p>`; strip block-level elements).
- [x] `BlockRenderer`: paragraph/blockquote/callout/heading text goes through
      `render_inline/1` instead of plain escape.
- [x] Tests: `**b**`/`*i*`/`[t](url)` render to strong/em/a; script/img/html
      injection stripped; javascript: hrefs dropped; headings keep level
      clamp; reader + preview unchanged for plain text.

### Task 10: `RichText` hook + command palette
- [x] `assets/js/hooks/rich_text.js`: contenteditable div replacing the
      textarea for paragraph/heading/blockquote/callout blocks
      (`phx-update="ignore"`); initial HTML from `data-html` (server-rendered
      inline markdown); DOM→inline-markdown serializer (strong/b, em/i, a
      whitelist; <br>/div → newline; everything else → text); 300ms debounce
      pushing the existing `block_change` payload.
- [x] Selection toolbar (Bold/Italic/Link) + Ctrl/Cmd+B/I/K, range-based (no
      execCommand); link prompts for http(s) URL.
- [x] Wire into `app.js` hooks; textarea stays for list/code/markdown/image/
      embed blocks.
- [x] Tests (server-side): block_change payload with inline markdown
      persists + renders; manual browser verification checklist in PR/commit.

### Task 11: wrap-up
- [x] `mix precommit` clean; full suite green.
- [x] Check off todo.md lines 82, 83, 84, 86, 87 with annotations.
- [x] Update design doc with any deviations.
