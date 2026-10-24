# Source rights — allowlist / robots / takedown

**Alert:** — (operator procedure; surfaces as missing content, blocked feeds, or takedown requests) · **Severity:** —

Slice 1's legal gate. The registry is `VerscientaNews.Ingestion.Allowlist`.
[`docs/source-rights.md`](../source-rights.md) mirrors those rows. A markdown
row that is not in the module is not polled.

## Symptoms

- A feed that should be ingested is not — `VerscientaNews.Ingestion.Poller`
  rejects URLs whose host is not allowlisted (check poller logs).
- An article renders without attribution or with wrong truncation — license
  misapplied (`source_license` / `attribution_text`).
- A source's `robots.txt` changed to `Disallow` — `robots_policy` field flips
  to `disallow`; allowlist removal + unpublish required.
- A takedown request arrived (`takedown@verscienta.example` or `Report`
  button → `ModerationFlag` type `takedown`).

## Impact

- Unallowlisted host → silent poller rejection (no draft created).
- `disallow` robots → must stop serving that source's articles or breach the
  site's stated robots respect.
- Takedown → archive the article and blocklist `source_url`. The poller checks that blocklist before insert. Dedupe is `source_url`.

## Diagnose

1. **Is the source allowlisted?**
   ```elixir
   VerscientaNews.Ingestion.Allowlist.allowlisted?("https://<host>/feed")
   VerscientaNews.Ingestion.Allowlist.sources()
   ```
   `docs/source-rights.md` should list the same rows. `mix test test/verscienta_news/allowlist_test.exs` checks the registry shape and that an unknown host is rejected.
2. **License field on the article:**
   ```elixir
   # bin/kiln_cms remote
   VerscientaNews.Catalog.Article |> Ash.Query.filter(source_url == "https://...") |> Ash.read_one!(authorize?: false) |> Map.take([:source_license, :attribution_text, :robots_policy])
   ```
   `source_url` is unique-indexed; `source_license` is constrained.
3. **Robots:**
   ```sh
   curl -fsS https://<source-host>/robots.txt | head
   # Compare with article.robots_policy (allow/disallow/unchecked)
   ```
4. **Takedown / report queue:**
   ```elixir
   # ModerationFlag type takedown/report, status open
   KilnCMS.Moderation.Flag |> Ash.Query.filter(reason == :takedown and status == :open) |> Ash.read!(authorize?: false)
   ```

## Mitigate

- **Missing allowlist row** → add the entry to `VerscientaNews.Ingestion.Allowlist` and the matching row in `docs/source-rights.md`, then deploy. The poller reads the module, not the markdown file.
- **License change** → truncation already happened at ingest (`Poller.apply_license/1`). Updating the registry does not rewrite bodies already stored. A new poll, or a takedown plus a fresh ingest, applies the new license.
- **Robots `disallow`** → remove the source from `Allowlist` and unpublish its articles.
- **Takedown** → moderator action `takedown` on the flag:
  `unpublish + archive`, `source_rights` note, and `source_url` blocklist.
  Re-ingestion of that URL is rejected because the blocklist is checked before insert. Dedupe remains `source_url`.

## Verify

- Allowlisted host: the next poll creates an `in_review` draft. A human approve publishes it. The fired `/[field:category]/[slug]` page shows attribution, the disclaimer, and the claim badge.
- Removed blocklisted URL: second poll creates no duplicate (dedupe on
  `source_url`); `docs/source-rights.md` no longer lists it.
- Takedown article: fired page returns 404 or link card; `GET
  /api/content/article/:slug?format=json` reflects same.

## Prevention

- Never add a source URL to the poller config without first adding its
  allowlist row — the poller rejects it anyway, but the intent is the gate.
- Keep `robots_policy` accurate — `disallow` sources are removed and their
  articles unpublished; do not re-allowlist without re-checking `robots.txt`.
- Treat takedown SLA as operational — `takedown_sla` in the allowlist is the
  commitment; a slow takedown is a legal risk, not just a content bug.
