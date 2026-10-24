# AI Writing Assistant for Authors — Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-10
**Phase:** 3 — Intelligence & Growth › Moderation & Trust
**Todo item:** `[ ] AI writing assistant for authors (draft help, tone, claim-checking).`

## Goal

Give article authors in-editor LLM help: per-block **Improve** (clarity/flow
rewrite), **Tone** rewrite (a fixed set of tones), and **Claim-check** (advisory
list of unsupported/risky health claims + how to strengthen them). Reuses the
existing Ollama `AI.Client`. Gated by the off-by-default `:writing_assistant`
flag; available to all authors editing their own draft.

## Decisions (from brainstorming)

- **Interaction:** rewrite suggestions (improve/tone) are **one-click Apply**
  (replaces the block's text in the editor) or **Dismiss**. Nothing is persisted
  until the author saves/publishes as normal.
- **Modes:** all three (Improve, Tone, Claim-check) in one slice. Claim-check is
  **advisory** (read-only list, no apply).
- **Scope:** **per-block** only (no whole-draft "check the article" button this
  slice). Only text blocks get assist controls.
- **Access:** all authors (flag-gated only — no role gate). Author-only editing
  is already enforced by the editor.
- **Tone set:** fixed — `:professional | :conversational | :concise | :accessible`
  (no freeform tone input).

## Architecture

### 1. `Verscienta.Assist` engine (new module)

`lib/verscienta/assist.ex` — mirrors the `Verscienta.AI` / `Moderation.Detector`
shape (build prompt → `AI.Client.generate/1` → parse strict JSON → best-effort;
never raises into the caller). Input text truncated to a char budget (4000).

```elixir
@type result :: {:ok, map()} | {:error, term()}

@tones [:professional, :conversational, :concise, :accessible]
def tones, do: @tones

@spec improve(String.t()) :: result()
def improve(text)            # → {:ok, %{suggestion: String}} | {:error, :invalid|:crashed|reason}

@spec retone(String.t(), atom()) :: result()
def retone(text, tone)       # tone must be in @tones, else {:error, :invalid_tone};
                             # → {:ok, %{suggestion: String}}

@spec check_claims(String.t()) :: result()
def check_claims(text)       # → {:ok, %{claims: [%{"claim"=>, "issue"=>, "suggestion"=>}]}}
```

- **Prompts** (each instructs "return ONLY JSON"):
  - `improve`: "Rewrite the PASSAGE to be clearer and better-flowing for a
    holistic-health article, keeping the same meaning, facts, and approximate
    length. Return JSON `{\"suggestion\": \"...\"}` (plain text, no markdown)."
  - `retone`: same but "rewrite in a **#{tone}** tone" with a one-line gloss per
    tone (professional/conversational/concise/accessible).
  - `check_claims`: "Identify factual/health claims in the PASSAGE that are
    unsupported, overstated, or risky. Return JSON
    `{\"claims\": [{\"claim\": \"...\", \"issue\": \"...\", \"suggestion\": \"...\"}]}`.
    Empty array if none."
- **Parse + validate** (mirror `AI.parse_enrichment` / `Detector.parse`):
  `Jason.decode/1`; on a non-map or missing key → `{:error, :invalid}`; coerce
  `suggestion` to a trimmed string (cap length, e.g. 4000) or `{:error, :invalid}`
  if blank; coerce `claims` to a list of maps with string `claim`/`issue`/
  `suggestion`, dropping malformed entries.
- **Error handling:** a top-level `rescue` → `{:error, :crashed}`; client
  transient error → `{:error, reason}`; parse failure → `{:error, :invalid}`. The
  caller (LiveView) treats any error as "couldn't generate."
- No DB, no Oban — synchronous engine called from the LiveView's async task.

### 2. Editor integration — `ArticleEditorLive`

For each **text block** — `paragraph`, `heading`, `blockquote`, `callout`,
`markdown`, `list` (NOT `image`/`embed`/`divider`/`code`) — render an assist
control row under the block's textarea **when** the flag is on:
`Improve` · `Tone ▾` (4 tone options) · `Check claims`.

- Flag check in mount: `assist_enabled? = Verscienta.Flags.enabled?(:writing_assistant, for: current_user)`.
  Render the controls `:if={@assist_enabled?}`.
- Socket assign `assist`: `nil` when closed, else
  `%{index: i, mode: :improve | {:retone, tone} | :check_claims, status: :loading | :done | :error, result: term}`.
  One assist panel open at a time (a new trigger replaces any open one).
- A helper `block_text(block)` extracts the editable text for a block
  (paragraph/heading/blockquote/callout → `data["text"]`; markdown →
  `data["source"]`; list → `data["items"]` joined by `\n`). Reuse / align with
  `Search.Document` block-text extraction where possible.

Handlers:
- `handle_event("assist", %{"index" => i, "mode" => mode_str, ...}, socket)`:
  re-check the flag (ignore if off); parse `mode_str` (`"improve"` /
  `"retone:professional"` / `"check_claims"`) into the internal mode; set
  `assist: %{index, mode, status: :loading}`; `start_async(:assist, fn ->
  run_assist(mode, text) end)` where `text = block_text(block)`.
- `handle_async(:assist, {:ok, {:ok, result}}, socket)` → `assist.status = :done`,
  `result`.
- `handle_async(:assist, {:ok, {:error, _}}, socket)` and
  `handle_async(:assist, {:exit, _}, socket)` → `status = :error`.
- `handle_event("assist_dismiss", _, socket)` → `assist: nil`.
- `handle_event("assist_apply", _, socket)` (only meaningful for improve/retone):
  re-check flag; take `assist.result.suggestion`, write it back into the block at
  `assist.index` via the editor's existing block-update path
  (`update_block_text`-style), re-render the preview, clear `assist`.

`run_assist/2` dispatches: `:improve → Assist.improve/1`,
`{:retone, tone} → Assist.retone/2`, `:check_claims → Assist.check_claims/1`.

### 3. Render (the assist panel)

Below the triggering block (`:if={@assist && @assist.index == index}`):
- `:loading` → a spinner / "thinking…".
- `:done`, improve/retone → the suggestion text (preformatted) + **Apply** +
  **Dismiss**.
- `:done`, check_claims → a list of `claim` / `issue` / `suggestion` items (or
  "no concerns found" when empty) + **Dismiss**.
- `:error` → "Couldn't generate a suggestion." + **Dismiss**.
Match the editor's existing Codex styling (small, `text-[11px]` controls,
`border-line`, `bg-canvas-2/3`).

### 4. Async strategy

Use Phoenix LiveView `start_async/3` + `handle_async/3` so the (up to 60s) LLM
call never blocks the LiveView process. A per-block `:loading` status disables
the assist controls for that block while running; a new assist trigger while one
is running replaces it (the stale async result is ignored because `assist.index`/
`mode` no longer matches — guard in `handle_async`).

### 5. Gating + config

- `:writing_assistant` flag (already in `@known_flags`, seeded OFF in
  `@phase3_off`). In-LiveView gate only — the editor route is unchanged and works
  fully with the flag off (no assist controls). The `assist`/`assist_apply`
  handlers re-check the flag (defense in depth) so a crafted event with the flag
  off is a no-op.
- All authors — no role gate (the editor already enforces author-only editing).

## Testing

- **`Verscienta.Assist` (unit, stub `AI.Client`):**
  - `improve/1` returns `{:ok, %{suggestion: "..."}}` from stubbed
    `{"suggestion": "..."}`; blank suggestion → `{:error, :invalid}`.
  - `retone/2` with a valid tone returns the suggestion; an invalid tone →
    `{:error, :invalid_tone}` (no client call).
  - `check_claims/1` parses `{"claims": [...]}` into the list; empty array →
    `{:ok, %{claims: []}}`; malformed entries dropped.
  - Non-JSON / non-map response → `{:error, :invalid}`; client `{:error, :timeout}`
    → propagated.
- **Editor LiveView (`render_async`):**
  - Flag on: the author sees the assist control on a text block; triggering
    "improve" runs async and renders the stubbed suggestion; **Apply** replaces
    the block's text (assert the editor block + preview reflect the suggestion);
    **Dismiss** closes the panel; "check claims" renders the advisory list.
  - Flag off: no assist controls; a crafted `"assist"` event is a no-op.
  - Use the existing AI client stub (`config/test.exs` already points to it) +
    `Application.put_env(:verscienta, :ai_stub, %{generate: {:ok, json}})`.

## Out of scope (later)

- Whole-draft assist (a "check the whole article" button); per-block only here.
- Streaming / token-by-token rendering.
- Assist history / persistence; usage metering.
- Non-text blocks (image/embed/divider/code).
- Freeform tone input or custom instructions beyond the fixed set.
- Reusing the result to auto-set `evidence_level` (claim-check is advisory only).

## Files touched (summary)

- New: `lib/verscienta/assist.ex` (engine).
- Modify: `lib/verscienta_web/live/article_editor_live.ex` (assist controls,
  `assist` assign, `assist`/`assist_apply`/`assist_dismiss` handlers,
  `handle_async`, `block_text` helper, flag gate).
- Tests: `test/verscienta/assist_test.exs`, editor LiveView test additions.
- No migration, no new resource, no Oban worker, no new flag.
