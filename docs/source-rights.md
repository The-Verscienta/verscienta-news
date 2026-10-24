# Source rights, attribution, and takedown

The registry the poller reads is `VerscientaNews.Ingestion.Allowlist` (`projects/verscienta_news/services/allowlist.ex`). This page lists the same rows. A source that is only in this markdown file is not polled.

## Rule

No source is polled unless `Allowlist.sources/0` has an entry with:

| Column | Meaning |
|---|---|
| `url` | Feed or page URL. The poller matches on host. |
| `license` | `full_text`, `excerpt_link`, or `link_only` |
| `attribution_text` | Rendered on the fired page |
| `robots` | `:respect` means the poller honors `robots.txt` for that host |
| `robots_notes` | What was checked, or why this row is still a placeholder |
| `owner_contact` | Who receives a takedown |
| `takedown_sla` | Response time the operator commits to |

## License behavior

Truncation happens in `VerscientaNews.Ingestion.Poller.apply_license/1` before the body is stored.

- `full_text` — store and render the body (Portable Text) with `attribution_text`.
- `excerpt_link` — store at most 280 characters of plain text, plus the link. Tags are stripped first. The full HTML is not stored.
- `link_only` — store no body. The fired page is a link card with the title, link, and attribution.

`source_license` and `attribution_text` are copied from the registry onto the draft. Changing the registry entry does not rewrite articles already stored; a takedown or a new poll does.

## Robots

When `robots` is `:respect`, the poller checks `robots.txt` before an HTML fetch of that host. `robots_policy` on the draft records `allow`, `disallow`, or `unchecked`. A `disallow` result skips the fetch. The operator removes that source from `Allowlist` and unpublishes its articles.

## Takedown

1. Mail `owner_contact` or use a report, which opens a `ModerationFlag` with reason `takedown`.
2. Moderator action `takedown` moves the article to `archived` (unpublished) and records the URL on the blocklist.
3. The poller checks the blocklist before insert. Dedupe is the unique `source_url`, not a title hash.

## Allowlist (Slice 1 seed — replace before launch)

| url | license | attribution_text | robots | robots_notes | owner_contact | takedown_sla |
|---|---|---|---|---|---|---|
| `https://example.com/nutrition.rss` | `excerpt_link` | Via Example Nutrition — read more at source | respect | Placeholder. Do not poll a real publisher until this row is replaced. | `takedown@verscienta.example` | 2 business days |

This table must match `Allowlist.sources/0`. `test/verscienta_news/allowlist_test.exs` fails if a registry entry is missing a column, and if an unknown host is treated as allowed.

## Enforcement

- `Poller.allowlisted?/1` is true only when the host is in `Allowlist`.
- `Poller.apply_license/1` returns `{:error, :not_allowlisted}` otherwise, and does not return a body to store.
- The fired page renders `attribution_text` and the disclaimer in `docs/moderation.md`.
