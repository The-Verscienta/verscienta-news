# Security Review — 2026-06-11

> **Historical — standalone Verscienta app.** Findings below refer to `Verscienta.*` LiveView resources (points, streaks, quests, Redis-era modules). They are not a review of the Kiln overlay. Current scope is `docs/slice-1.md`.

Scope: authorization on every Ash action, input validation, OWASP Top 10 pass,
Sobelow static analysis (now in CI).

## Authorization matrix

- 35 Ash resources audited. 22 had policies; 13 did not.
- Policy-free system-only resources (accepted, calls are worker/context-internal with
  explicit `authorize?: false` and `forbid_if always()` would be redundant churn):
  ArticleTag (join, gated by Article), ActivityEvent, Badge, UserBadge, Quest,
  QuestAssignment, PointsEntry, Streak, Redemption, RewardItem, Referral,
  GamificationEvent, GamificationAudit, LeaderboardSnapshot, Flags.Audit.
- FIXED (commits 5879e88, b99e0de): `Room`, `Message`, and `RoomBan` now carry
  resource-level policies:
  - `Message`: read and `:post` floors require `actor_present()`; the system
    actions (`:soft_delete`, `:hold`, `:unhold`) are `forbid_if always()` —
    moderation paths call them with `authorize?: false`.
  - `Room`: reads `authorize_if always()` (metadata is just topic/status);
    `:find_or_create_for_group` and `:set_status` are `forbid_if always()` —
    system-managed via `Verscienta.Communities` (`room_for_group/1`,
    `lock_room/3`) with `authorize?: false` after their own checks.
  - `RoomBan`: reads require `actor_present()`; all writes are
    `forbid_if always()`. `Verscienta.Communities.ban_user/3` gained an explicit
    `authorize?: false` — it performs its own moderator/self/mod-target checks
    before creating the ban.
  Membership/ban/closed-room rules remain in `Verscienta.Communities`; the
  resource policy is the defense-in-depth floor, and the `Message` `:post`
  action's `description` now documents `post_message/3` as the required entry
  point (commit 2f96f28).
- LiveViews consistently rebuild the actor from session via on_mount handlers and
  pass it to Ash calls. `/admin` routes are role-gated in the router AND re-checked
  in on_mount (404 on failure). `authorize?: false` usages were swept: all are
  system actions, already-authorized reloads, or admin surfaces behind role gates.

## Input validation

- Markdown/HTML rendering: article blocks render through BlockRenderer →
  Markdown.render_inline (HTML-escapes BEFORE markdown) or Markdown.to_html
  (MDEx + ammonia sanitizer strips script/style). No unsanitized `raw/1` with user
  input. `Layouts.json_ld_tag` raw-renders JSON it encodes itself and escapes `</`.
- FIXED (commit f8bf441): expert application credential URLs capped (≤ 5 URLs,
  ≤ 300 chars each; http(s) scheme was already enforced).
- FIXED (commit e2c70fc): tag names capped at 50 chars (were unbounded user
  input via `upsert_by_name`).
- Comment bodies (2000), repost quotes (500), messages (2000), group name (100)
  /description (1000), flag notes (1000) were already constrained.

## Sobelow static analysis (commit 077794a)

`mix sobelow --config` runs in CI directly after credo; config in `.sobelow-conf`
(`exit: "medium"` — medium/high-confidence findings fail the build). Full triage
of the initial scan (sobelow 0.14.1, 14 findings):

| Finding | Confidence | Decision | Justification |
| --- | --- | --- | --- |
| Config.CSP — no Content-Security-Policy on `:browser` pipeline (router.ex) | High | **OPEN — accepted for now**, check ignored in `.sobelow-conf` | Real hardening gap, not directly exploitable by itself (defense-in-depth vs XSS, which is covered by the sanitization pipeline). A correct CSP for this LiveView app (inline theme script in root layout, LiveView websockets, external image hosts) needs its own change + verification pass. Tracked in Follow-ups. |
| Config.Secrets — hardcoded `secret_key_base` (config/loadtest.exs:33) | High | Ignore file | Throwaway value for the isolated local load-test env (`server: false`, dedicated `verscienta_loadtest` DB). Production secrets come from env vars in `config/runtime.exs`. |
| Config.Secrets — hardcoded `token_signing_secret` (config/loadtest.exs:58) | High | Ignore file | Same as above. |
| Misc.BinToTerm — `binary_to_term` (lib/verscienta/cache.ex `decode/1`) | High | Ignore check | Only `binary_to_term` in `lib/`. Decodes values the same module wrote to our own Redis via `term_to_binary/2`, and already passes `[:safe]` (refuses unknown atoms / external funs). Not user input. (A per-function `@sobelow_skip` was tried first but trips `--warnings-as-errors` with "module attribute was set but never used".) |
| XSS.HTML — `html(conn, page)` ×2 (digest_controller.ex unsubscribe) | Medium | Ignore file | Both `page/2` arguments are hardcoded string literals in both branches ("You've been unsubscribed" / "Invalid link"); no user input reaches the response body. |
| DOS.BinToAtom — `:"verscienta_cache_redix_#{i}"` (cache/redis.ex:33) | Low | No action (below exit threshold) | `i` is a bounded pool index (0..pool_size-1 from app config), not user input. |
| XSS.HTML — digest email body (digests/email.ex:19) | Low | No action | Titles/excerpts go through `esc/1` (HTML escape); URLs come from verified routes. |
| Traversal.FileModule — `File.read(path)` (images.ex:38) | Low | No action | `path` is the Plug/LiveView-managed temp file from `consume_uploaded_entries/3`, not user-supplied. |
| Traversal.FileModule — `File.read` (load_test/scenarios.ex:33) | Low | No action | Manual load-test harness; path is the module's own `fixtures_path/0` constant. |
| Traversal.FileModule — `File.write!` + `File.mkdir_p!` (load_test/seeder.ex:555–556) | Low | No action | Same harness; internal constant path. |
| SQL.Query — TRUNCATE interpolation (load_test/seeder.ex:131) | Low | No action | Table list is the compile-time `@truncate_tables` constant; guarded to only run against the dedicated loadtest DB. |
| SQL.Query — `REFRESH MATERIALIZED VIEW#{modifier} #{name}` (materialized_views.ex:35) | Low | No action | `name` is guard-restricted (`when name in @views`, a compile-time allowlist); `modifier` is an internal boolean-derived constant. |

## OWASP Top 10 pass

- A01 Broken access control: see authorization matrix; fixed Room/Message/RoomBan.
- A02 Crypto failures: bcrypt for passwords; JWTs via AshAuthentication with token
  revocation table.
- A03 Injection: Ecto/Ash parameterized queries; the two string-interpolated
  fragments found are compile-time allowlists (see Sobelow table); XSS covered by
  the sanitization pipeline above.
- A04 Insecure design: rate limiting on sign-in, registration, and reporting;
  gamification award idempotency (source_ref identities) prevents replay farming;
  referral fraud controls (IP throttle, self-referral check, monthly cap).
- A05 Misconfiguration: Sobelow now runs in CI (`mix sobelow --config`); triage
  decisions in the table above — ignores are Config.CSP (open follow-up),
  Misc.BinToTerm (own-Redis decode with `[:safe]`), and two ignored files
  (config/loadtest.exs throwaway secrets; digest_controller.ex hardcoded-literal
  pages). One finding remains OPEN: no Content-Security-Policy header.
- A07 AuthN failures: email confirmation before active; sign-in rate limits per
  IP/email; deactivated users denied.
- A08 Integrity: deps locked via mix.lock; dependabot/audit out of scope here.
- A09 Logging: moderation + gamification audit resources; flag/enforcement trail.
- A10 SSRF: outbound fetches (RSS, OG images) go through admin-managed Source
  records (admin-only create), not arbitrary user URLs; expert credential URLs are
  stored, never fetched.

## Follow-ups (not blocking)

- **Add a Content-Security-Policy** to the `:browser` pipeline (the one OPEN
  Sobelow finding). Needs an inventory of inline scripts/styles (theme toggle in
  root layout), LiveView websocket origins, and external image hosts before a
  policy can be enforced without breakage; consider starting with
  `Content-Security-Policy-Report-Only`.
- Consider moving the membership/ban/closed-room checks from
  `Verscienta.Communities.post_message/3` into the `Message` `:post` action
  itself (validations/changes or policy checks), so the resource enforces them
  caller-independently instead of relying on the documented entry point.
- Consider a membership-scoped read policy floor for `Message` given private
  groups: today the resource floor is only `actor_present()` and no actor-scoped
  read surface exists in the app (RoomLive gates membership at mount), but a
  membership filter policy would make a future read surface safe by default.
- Room metadata (topic/status) is world-readable by design (`Room` read is
  `authorize_if always()`) — confirm this is acceptable for private groups, or
  scope it to members alongside the Message read follow-up.
- Consider quotas on tag minting per user.
- Consider forbid_if-always policy blocks on the remaining system-only resources
  for uniformity.
