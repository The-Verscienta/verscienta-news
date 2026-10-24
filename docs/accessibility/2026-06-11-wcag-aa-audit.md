# WCAG AA Audit — 2026-06-11

> **Historical — standalone Verscienta app.** This sweep covered that app's LiveViews. It is not an audit of the Kiln fired page. Current scope is `docs/slice-1.md`.

Method: full template/component sweep (root layout, layouts.ex, core/codex/social/
notification components, report dialog, all LiveViews) + automated regression floor
(test/verscienta_web/a11y_smoke_test.exs, tagged :smoke, runs in CI). The floor
checks `html[lang]`, the skip link, the `main#main-content` landmark, labelled
navs, and `img:not([alt])` across 8 representative public + authenticated pages.

## Already conformant (verified, unchanged)

- html[lang], labelled primary + mobile navs, header/main landmarks
- Menu toggle: aria-label / aria-controls / aria-expanded
- Flash region aria-live="polite", role="alert" flashes with labelled close
- Follow button aria-pressed; form inputs labelled (fieldset for checkboxes)
- :focus-visible outline (2px zune on offset 2px) — visible focus indicator
- motion-safe: prefix on spinner animations
- No alt-less `<img>` found on any audited page (the regression floor asserts
  this stays true), so no alt-text fixes were required in this pass

## Fixed in this pass

- Skip link to #main-content; `<main id="main-content" tabindex="-1">` target (2.4.1)
- Theme-toggle buttons aria-labels (4.1.2)
- Report dialog: role="dialog", aria-modal, aria-labelledby wired to the dialog
  heading id, Escape to close (2.1.1, 4.1.2)
- news_card heading h5 -> h3 (1.3.1); decorative glyphs (✦, ●, accent bars,
  initial avatars, notification icons) aria-hidden (1.1.1)
- Nav vp/streak badges: sr-only expansions ("vitality points", "day streak") (1.1.1)
- Room composer input aria-label="message" (3.3.2)
- --color-ink-3 #6d6d6d -> #8c8c8c: 3.7:1 -> 5.8:1 on the dark canvas (1.4.3).
  The daisyUI light theme block does not override --color-ink-3, so the single
  token fix covers both themes.

## Known remaining gaps (tracked, not blocking)

- Category color chips (text-black on accent colors) — spot-checked the worst
  (world #1ba1e2: ~7.8:1 with black) but a systematic pass over all 7 accents
  in both themes is future work
- Live regions: room typing indicator and streamed messages are not announced
  (no aria-live on the message stream) — needs UX decision on verbosity
- Manual screen-reader (NVDA/VoiceOver) and keyboard-only walkthrough not yet
  performed; automated floor only covers structural checks
