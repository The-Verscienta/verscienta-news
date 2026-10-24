# Moderation queue — review backlog / stuck drafts

**Alert:** — (operator procedure; surfaces as a growing `in_review` count or stale fired content) · **Severity:** warning

Slice 1's trust gate: every ingested draft is Kiln state `in_review` until a human approves it. The queue is `/editor?status=in_review`. The fired page is `/[field:category]/[slug]`. Ollama is advisory and never publishes. See `docs/moderation.md`.

## Symptoms

- `in_review` count or open `ModerationFlag` count climbing.
- A reviewer approved an article whose `claim_status` was still `flagged`.
- A takedown flag is open past `takedown_sla` on the allowlist entry.
- The fired page still shows the previous attribution after a publish.

## Impact

- A backlog means new articles are not public. Firing happens on `in_review` → `published`.
- Approving a flagged article without `clear_claim` publishes it as flagged. The checklist in `docs/moderation.md` forbids that.
- A stale fired page is a cache bust, not a second publish.

## Diagnose

1. Count articles in `in_review` from `/editor?status=in_review`.
2. If Ollama was down, drafts in `in_review` without `ai_summary` are expected. Probe with `docker exec <app> curl -fsS -m 2 $OLLAMA_URL/api/version`. The Compose profile is `ml`. See [ollama-down](ollama-down.md).
3. Open a fired `/<category>/<slug>` page and confirm the disclaimer sentence is present.

## Mitigate

- Triage on `/editor?status=in_review`. Approve only after the checklist. `clear_claim` sets `claim_status` to `cleared`. There is no `verified` badge in Slice 1. `request_changes` returns the article to `draft`. `takedown` archives it and blocklists `source_url`.
- Flush delivery cache after a publish that still looks old: `bin/kiln_cms rpc "KilnCMS.Cache.flush_delivery()"`.
- Ollama down during ingest needs no repair. The drafts wait in `in_review`.

## Verify

- `in_review` count falls and `published` count rises.
- A just-approved article shows attribution, "Not medical advice — for information only. Consult a qualified professional.", and a badge of Unreviewed, Flagged for review, or Reviewed.
- A blocklisted `source_url` is not inserted again.

## Prevention

- Staff the queue before growing the allowlist. The cron is every 15 minutes.
- Do not add a score that publishes. The path is `in_review` → human → `published`.
- `claim_status` and `toxicity_flag` stay separate. Neither one publishes.
