# Codex notes (gated)

`https://github.com/The-Verscienta/news-verscienta/blob/main/docs/design/the-codex-v6.html` and `project-overview.md` both return **404** (private / not yet pushed) as of this deliverable.

Frontend tokens at `frontend/src/lib/tokens/codex.css` map Kiln ember `#FF6200` palette to a wellness earth palette (paper `#fafaf7`, ember `#c45a1a`, herbal `#2f6b4a`, gold `#8b6b3a`) and satisfy `Anti-Slop` (no purple gradient, no aurora blobs, no bento-everywhere).

When the docs become readable:
1. Open `the-codex-v6.html` in a browser, extract CSS custom properties (colors, radii, `--font-*`, spacing), component specs (cards, badges, nav, hero), and motion tokens.
2. Paste verbatim into `codex.css` `@theme` block and `frontend/src/app.css` `@layer components`.
3. Visual diff `/` + `/article/[slug]` against the Codex and note deltas in this file.
