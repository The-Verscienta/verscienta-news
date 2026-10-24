# Backend Engine Foundations — Phase 1: `uuid_v7` Primary Keys — Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Switch every single-PK Ash resource from random `uuid_primary_key` (UUIDv4) to sortable `uuid_v7_primary_key` (UUIDv7).

**Architecture:** A purely app-side generator change — the Postgres column stays `:uuid`, only Ash's default ID generator changes (`Ash.UUID` → `Ash.UUIDv7`). New rows get timestamp-sortable IDs; existing rows (none in prod; dev/test reset) are unaffected. 35 resource files change one line each; composite-PK join tables are untouched.

**Tech Stack:** Elixir, Ash 3.27.8, AshPostgres 2.9.1, Ash snapshot codegen (`mix ash.codegen`).

**Spec:** `docs/superpowers/specs/2026-06-13-backend-engine-foundations-design.md` (§1).

---

## Environment

This repo runs mix inside the existing `news-verscienta-app-1` Docker container against this worktree. Every `mix ...` command below is executed via this wrapper (PowerShell tool, to avoid path mangling):

```
docker exec -e MIX_ENV=test -e MIX_DEPS_PATH=/workspace/deps \
  -e MIX_BUILD_ROOT=/workspace/_build/wt-fervent -e MIX_TEST_PARTITION=_wt_fervent \
  -w /workspace/.claude/worktrees/fervent-antonelli-f4448c \
  news-verscienta-app-1 mix <args>
```

Phase 1 adds **no new dependency**, so the shared `/workspace/deps` volume is used as-is.

## File Structure

- **Modify (35 files):** every resource listed in Task 2 — one line, `uuid_primary_key :id` → `uuid_v7_primary_key :id`.
- **Create:** `test/verscienta/uuid_v7_test.exs` — proves new IDs are version-7.
- **Generated:** a snapshot/migration update under `priv/resource_snapshots/` (and possibly an empty/near-empty migration under `priv/repo/migrations/`) from `mix ash.codegen`.

---

### Task 1: Failing test — new IDs must be UUIDv7

**Files:**
- Test: `test/verscienta/uuid_v7_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/uuid_v7_test.exs`:

```elixir
defmodule Verscienta.UuidV7Test do
  use Verscienta.DataCase, async: false

  import Verscienta.Support.Factory, only: [user: 1, article: 1]

  # The UUID version nibble is the 13th hex digit (index 12 of the 32-char,
  # dash-stripped string). v4 => "4", v7 => "7".
  defp uuid_version(uuid) do
    uuid |> String.replace("-", "") |> String.at(12)
  end

  test "User primary keys are UUIDv7" do
    u = user("v7user")
    assert uuid_version(u.id) == "7"
  end

  test "Article primary keys are UUIDv7" do
    author = user("v7author")
    art = article(author)
    assert uuid_version(art.id) == "7"
  end

  test "two ids created in order are byte-sortable by creation time" do
    a = user("v7sortA").id
    b = user("v7sortB").id
    # v7 ids embed a millisecond timestamp prefix, so later id sorts >= earlier.
    assert b >= a
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```
mix test test/verscienta/uuid_v7_test.exs
```
Expected: FAIL — the first two tests assert `"7"` but get `"4"` (current `uuid_primary_key` emits UUIDv4). This confirms the test exercises the real generator.

- [ ] **Step 3: Commit the failing test**

```bash
git add test/verscienta/uuid_v7_test.exs
git commit -m "test(ids): assert resources use UUIDv7 primary keys (failing)"
```

---

### Task 2: Switch all single-PK resources to `uuid_v7_primary_key`

**Files (Modify — 35, each one line `uuid_primary_key :id` → `uuid_v7_primary_key :id`):**

```
lib/verscienta/accounts/user.ex
lib/verscienta/billing/subscription.ex
lib/verscienta/communities/group.ex
lib/verscienta/communities/group_membership.ex
lib/verscienta/communities/message.ex
lib/verscienta/communities/room.ex
lib/verscienta/communities/room_ban.ex
lib/verscienta/content/article.ex
lib/verscienta/content/article_revision.ex
lib/verscienta/content/source.ex
lib/verscienta/content/tag.ex
lib/verscienta/engagement/bookmark.ex
lib/verscienta/engagement/comment.ex
lib/verscienta/engagement/reaction.ex
lib/verscienta/experts/expert_application.ex
lib/verscienta/flags/audit.ex
lib/verscienta/gamification/badge.ex
lib/verscienta/gamification/gamification_audit.ex
lib/verscienta/gamification/gamification_event.ex
lib/verscienta/gamification/leaderboard_snapshot.ex
lib/verscienta/gamification/points_entry.ex
lib/verscienta/gamification/quest.ex
lib/verscienta/gamification/quest_assignment.ex
lib/verscienta/gamification/redemption.ex
lib/verscienta/gamification/referral.ex
lib/verscienta/gamification/reward_item.ex
lib/verscienta/gamification/streak.ex
lib/verscienta/gamification/user_badge.ex
lib/verscienta/moderation/action.ex
lib/verscienta/moderation/flag.ex
lib/verscienta/notifications/notification.ex
lib/verscienta/notifications/push_subscription.ex
lib/verscienta/social/activity_event.ex
lib/verscienta/social/follow.ex
lib/verscienta/social/repost.ex
```

- [ ] **Step 1: Apply the one-line replacement to every file**

The exact source line is identical in all 35 files: `    uuid_primary_key :id`. Replace with `    uuid_v7_primary_key :id` (preserve the leading 4-space indent). Apply with the Edit tool per file, or run this sweep from the worktree root on the host:

```bash
grep -rl 'uuid_primary_key :id' lib | while read -r f; do
  sed -i 's/uuid_primary_key :id/uuid_v7_primary_key :id/' "$f"
done
```

- [ ] **Step 2: Verify the sweep hit all 35 and left none behind**

Run on the host from the worktree root:
```bash
echo "remaining v4:"; grep -rc 'uuid_primary_key :id' lib | grep -v ':0' | grep -v 'v7' | wc -l
echo "now v7:";       grep -rc 'uuid_v7_primary_key :id' lib | grep -v ':0' | wc -l
```
Expected: `remaining v4: 0`, `now v7: 35`.

- [ ] **Step 3: Compile to confirm the macro resolves**

Run:
```
mix compile --warnings-as-errors
```
Expected: compiles clean. (`uuid_v7_primary_key/1` is provided by Ash 3.27.8's resource DSL — no new dep.)

---

### Task 3: Regenerate Ash snapshots / migration and reset the DB

**Files:**
- Generated: `priv/resource_snapshots/...` (and possibly `priv/repo/migrations/<ts>_*.exs`)

- [ ] **Step 1: Run Ash codegen**

Run:
```
mix ash.codegen uuid_v7_primary_keys
```
Expected: updates resource snapshots. A Postgres migration may be **empty or absent** — the column type (`:uuid`) is unchanged and the ID is generated app-side, so there is no schema delta. Either outcome is correct; do not hand-write a migration.

- [ ] **Step 2: Set up / reset the test database against the new snapshots**

Run:
```
mix ash.setup
```
Expected: creates/migrates the partitioned test DB with no errors. (If a stale partitioned DB causes a collation error, run once: `docker exec news-verscienta-db-1 psql -U postgres -c "ALTER DATABASE template1 REFRESH COLLATION VERSION"`, then retry.)

---

### Task 4: Make the UUIDv7 test pass

- [ ] **Step 1: Run the Phase 1 test**

Run:
```
mix test test/verscienta/uuid_v7_test.exs
```
Expected: PASS — all three tests green (ids now version `"7"`, and the byte-sort assertion holds).

- [ ] **Step 2: Run the full suite (regression guard)**

Run:
```
mix test
```
Expected: the suite passes as before. Watch specifically for any test that hardcoded a UUID string or relied on v4-shaped ids; there are none expected, but if one fails on an id assertion, fix that test to not assume a literal id (regenerate via the factory). Do not weaken the v7 change to satisfy a brittle fixture.

- [ ] **Step 3: Format**

Run:
```
mix format
```
Expected: no diff in the 35 resource files (single-token change keeps formatting); the new test file is already formatted.

---

### Task 5: Commit

- [ ] **Step 1: Commit the sweep + generated snapshots**

```bash
git add lib/ priv/ test/verscienta/uuid_v7_test.exs
git commit -m "feat(ids): use uuid_v7_primary_key across all resources

Sortable, timestamp-ordered IDs (Ash.UUIDv7) on the 35 single-PK
resources; column type unchanged (:uuid), generator-only change.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage (§1):** Task 2 performs the 35-resource `uuid_v7_primary_key` switch; Task 3 handles the (no-op) migration + DB reset; Task 1/4 prove new IDs are v7 and sortable. Join-table exclusion is honored — the 35-file list is exactly the `uuid_primary_key :id` set; composite-PK tables (e.g. `ArticleTag`) are not in it. ✅
- **Placeholder scan:** none — every step has exact files, the literal replacement string, the test code, and exact commands. ✅
- **Type consistency:** the test helper `uuid_version/1` and factory functions `user/1`, `article/1` match `test/support/factory.ex`. ✅
- **Risk (from spec):** the `uuid_v7_primary_key` builder is confirmed available in Ash 3.27.8; the spec's fallback (`attribute :id, :uuid, default: &Ash.UUIDv7.generate/0`) is unneeded.

## Next Phase

After this merges/verifies, Phase 2 (AshStateMachine on `Content.Article` `:status`) gets its own plan, read fresh against `article.ex` at that point.
