# Docs

Slice 1 is the current scope. If a file disagrees with `slice-1.md`, `slice-1.md` wins.

## Governing

| File | What it decides |
|---|---|
| [slice-1.md](slice-1.md) | What ships first, what is out, and the exit tests |
| [project-overview.md](project-overview.md) | Product outline that points at that cut line |
| [architecture.md](architecture.md) | Kiln overlay, modules, and the one public URL |
| [source-rights.md](source-rights.md) | License rules. The registry the poller reads is `VerscientaNews.Ingestion.Allowlist` |
| [ingestion.md](ingestion.md) | Oban poll, truncation before storage, `in_review` |
| [moderation.md](moderation.md) | Review queue, approve checklist, claim status |

`social.md` and `gamification.md` describe work after Slice 1. They are not exit criteria.

## Operations (current stack)

[deploy-coolify.md](deploy-coolify.md), [observability.md](observability.md), [load-testing.md](load-testing.md), and [runbooks/](runbooks/README.md). Cache is Cachex. There is no Redis in Slice 1. `runbooks/redis-down.md` is a stub.

## Historical — do not implement

These describe the standalone `Verscienta.*` LiveView app, or an earlier review of the plan. They are kept so the old decisions stay readable.

- [superpowers/](superpowers/plans/) — specs and implementation plans. Each file is marked historical. A body that says `pending_review`, LiveView editors, `fast_rss`, or auto-publish is the old app.
- [audits/](audits/2026-06-10-project-health.md) — June 2026 audits of that app.
- [security/2026-06-11-security-review.md](security/2026-06-11-security-review.md) and [accessibility/2026-06-11-wcag-aa-audit.md](accessibility/2026-06-11-wcag-aa-audit.md) — same app.
- [plan-critique.md](plan-critique.md) — the 3 Oct 2026 critique of the first outline. The governing files above are the response.

## Design

[design/the-codex-v6.html](design/the-codex-v6.html) and [design/codex-tokens.css](design/codex-tokens.css) are the Codex (dark theme). [design/codex-notes.md](design/codex-notes.md) records that the Svelte tokens are a separate earth palette until they are mapped.
