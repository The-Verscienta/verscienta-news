# Moderation and trust

Slice 1 review happens before follows or vitality. The queue is Kiln's editor filter `/editor?status=in_review`. Kiln does not have an `/editor/moderation` route.

Workflow states are `draft`, `in_review`, `published`, and `archived`.

## Claim status

Slice 1 values are `unreviewed`, `flagged`, and `cleared`.

| Value | Who sets it | Badge |
|---|---|---|
| `unreviewed` | Ingest, when Ollama did not flag the draft | Unreviewed |
| `flagged` | Advisory Llama, or a moderator | Flagged for review |
| `cleared` | Moderator action `clear_claim` | Reviewed |

`verified` is not a Slice 1 value. Verified Expert, after Slice 1, is what may add it. Approve does not set `verified`.

## Approve checklist

A human may move `in_review` → `published` only when all of these are true:

1. The source host is in `VerscientaNews.Ingestion.Allowlist`, and `source_license` on the article matches that entry.
2. The stored body matches the license: full body, at most 280 characters of plain text, or no body.
3. `attribution_text` is present and will render.
4. The fired template includes the disclaimer: "Not medical advice — for information only. Consult a qualified professional." This is template copy, not a boolean stored at ingest.
5. If `claim_status` is `flagged`, the reviewer either sends it back to `draft` or runs `clear_claim` before approve.

`request_changes` returns the article to `draft`. `takedown` archives it and blocklists `source_url` (`docs/source-rights.md`).

## Flags

`ModerationFlag` fields: `flaggable_type`, `flaggable_id`, `reason` (`toxicity`, `claim`, `takedown`, `report`), `llm_output`, `status` (`open`, `cleared`, `takedown`).

Llama on ingest may open a flag. It never publishes and never auto-holds. Comments are not in Slice 1, so there is no comment hook yet.

## On the fired page

Every published article shows attribution, the disclaimer sentence above, and the claim badge for `unreviewed`, `flagged`, or `cleared`.

Provenance stays off until a later claim audit needs it.
