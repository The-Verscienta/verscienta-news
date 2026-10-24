# Backend Engine Foundations — Phase 3: AshPaperTrail (audit trails) — Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add immutable audit trails (AshPaperTrail) to the five audit-sensitive resources — `Moderation.Action`, `Moderation.Flag`, `Billing.Subscription`, `Experts.ExpertApplication`, `Accounts.User` — while guaranteeing the `User` trail never records secrets.

**Architecture:** Each audited resource gets the `AshPaperTrail.Resource` extension + a `paper_trail` block (changes-only tracking, action name stored, uuid_v7 version keys). Each owning domain gets the `AshPaperTrail.Domain` extension, which auto-generates and registers the companion `<Resource>.Version` resources (one new table each). `User` additionally ignores secret/sensitive attributes; `store_action_inputs?` is left off (default) so the password supplied to the register action is never persisted.

**Tech Stack:** Elixir, Ash 3.27.8, `ash_paper_trail` v0.6 (new dep), AshPostgres, `mix ash.codegen`.

**Spec:** `docs/superpowers/specs/2026-06-13-backend-engine-foundations-design.md` (§3).

---

## Environment

Run mix inside the container (PowerShell tool for docker exec):

```
docker exec -e MIX_ENV=test -e MIX_DEPS_PATH=/workspace/deps \
  -e MIX_BUILD_ROOT=/workspace/_build/wt-fervent -e MIX_TEST_PARTITION=_wt_fervent \
  -w /workspace/.claude/worktrees/fervent-antonelli-f4448c \
  news-verscienta-app-1 mix <args>
```

`mix deps.get` adds `ash_paper_trail` to the shared `/workspace/deps` volume (a safe superset of main's lock). If a fresh partitioned DB errors on `template1` collation, run once: `docker exec news-verscienta-db-1 psql -U postgres -c "ALTER DATABASE template1 REFRESH COLLATION VERSION"`.

## Current State (verified)

- No `ash_paper_trail`, no `paper_trail` usage anywhere. All 5 resources use `uuid_v7_primary_key` (Phase 1).
- Resource headers:
  - `lib/verscienta/moderation/action.ex:3` — `use Ash.Resource, otp_app: :verscienta, domain: Verscienta.Moderation, data_layer: AshPostgres.DataLayer, authorizers: [Ash.Policy.Authorizer]` (no `extensions:`).
  - `lib/verscienta/moderation/flag.ex:3` — same shape, domain `Verscienta.Moderation`.
  - `lib/verscienta/billing/subscription.ex:9` — same shape, domain `Verscienta.Billing`.
  - `lib/verscienta/experts/expert_application.ex:3` — same shape, domain `Verscienta.Experts`.
  - `lib/verscienta/accounts/user.ex:3` — `use Ash.Resource, otp_app: :verscienta, domain: Verscienta.Accounts, data_layer: AshPostgres.DataLayer, authorizers: [Ash.Policy.Authorizer], extensions: [AshAuthentication]` (HAS an extensions list).
- Domain modules (all `use Ash.Domain, otp_app: :verscienta`, no extensions):
  - `lib/verscienta/moderation.ex` (resources: Flag, Action)
  - `lib/verscienta/billing.ex` (Subscription)
  - `lib/verscienta/experts.ex` (ExpertApplication)
  - `lib/verscienta/accounts.ex` (Token, User)
- `User` sensitive attributes to ignore: `:hashed_password` (`sensitive? true`), plus privacy-lifecycle fields `:confirmed_at`, `:deactivated_at`, `:deletion_finalizes_at`, `:anonymized_at`.

## AshPaperTrail v0.6 API (reference for this plan)

- Resource: `extensions: [AshPaperTrail.Resource]` + `paper_trail do … end`. Options used: `primary_key_type :uuid_v7` (default `:uuid`), `change_tracking_mode :changes_only` (default `:snapshot`), `store_action_name? true` (default false), `ignore_attributes [...]`. **`store_action_inputs?` defaults to `false` — leave it off** so the register action's `password` input is never stored.
- Domain: `extensions: [AshPaperTrail.Domain]` makes the domain *aware* of `<Resource>.Version` resources but does **NOT** auto-register them unless a domain-level `paper_trail do include_versions? true end` is also set (default false). Without registration, `ash.codegen` emits no version tables. **Resolution used:** register each `<Resource>.Version` explicitly in the domain's `resources do` block (cannot double-register — the transformer guards on membership).
- Version resource: module `<Resource>.Version`; source has `has_many :paper_trail_versions`; version row has `changes` (map) and `version_action_name`.

## File Structure

- **Modify:** `mix.exs`; the 5 resource files; the 4 domain files.
- **Create:** `test/verscienta/audit/paper_trail_test.exs`.
- **Generated:** 5 version-table migrations under `priv/repo/migrations/` + snapshots under `priv/resource_snapshots/`.

---

### Task 1: Add the dependency and write the failing audit test

**Files:**
- Modify: `mix.exs`
- Test: `test/verscienta/audit/paper_trail_test.exs`

- [ ] **Step 1: Add the dep**

In `mix.exs` deps/0, directly after `{:ash, "~> 3.0"},`, add:

```elixir
      {:ash_paper_trail, "~> 0.5"},
```

- [ ] **Step 2: Fetch deps**

Run: `mix deps.get`
Expected: fetches `ash_paper_trail` (v0.6.x resolves against `~> 0.5`). If it doesn't resolve against Ash 3.27, use the highest compatible version and note it.

- [ ] **Step 3: Write the failing test**

Create `test/verscienta/audit/paper_trail_test.exs`:

```elixir
defmodule Verscienta.Audit.PaperTrailTest do
  use Verscienta.DataCase, async: false

  import Verscienta.Support.Factory, only: [user: 1]

  @audited_versions [
    Verscienta.Moderation.Action.Version,
    Verscienta.Moderation.Flag.Version,
    Verscienta.Billing.Subscription.Version,
    Verscienta.Experts.ExpertApplication.Version,
    Verscienta.Accounts.User.Version
  ]

  test "every audited resource has a queryable version table" do
    for mod <- @audited_versions do
      assert is_list(Ash.read!(mod, authorize?: false)),
             "expected #{inspect(mod)} to be a queryable AshPaperTrail version resource"
    end
  end

  test "creating a user records an audit version" do
    u = user("audit_create")
    versions = Ash.read!(Verscienta.Accounts.User.Version, authorize?: false)
    mine = Enum.filter(versions, &(&1.version_source_id == u.id))
    assert mine != [], "expected at least one version row for the created user"
  end

  test "the user audit trail never contains the password hash" do
    u = user("audit_secret")
    # Reload to read the actual stored hash, then confirm it never leaked to the trail.
    full = Ash.get!(Verscienta.Accounts.User, u.id, authorize?: false)
    versions = Ash.read!(Verscienta.Accounts.User.Version, authorize?: false)
    dump = inspect(versions, limit: :infinity)

    refute dump =~ "hashed_password",
           "version trail must not contain the :hashed_password key"

    refute dump =~ full.hashed_password,
           "version trail must not contain the actual password hash value"
  end

  test "updating a tracked resource appends a version capturing the change" do
    u = user("audit_update")

    before = Ash.read!(Verscienta.Accounts.User.Version, authorize?: false)

    u
    |> Ash.Changeset.for_update(:update_profile, %{display_name: "Renamed Person"}, actor: u)
    |> Ash.update!(authorize?: false)

    after_versions = Ash.read!(Verscienta.Accounts.User.Version, authorize?: false)
    new = Enum.filter(after_versions, &(&1.version_source_id == u.id and &1 not in before))

    assert new != [], "expected a new version row after the profile update"
    assert Enum.any?(new, fn v -> match?(%{"display_name" => "Renamed Person"}, v.changes) end),
           "expected the version's :changes to capture display_name => \"Renamed Person\""
  end
end
```

- [ ] **Step 4: Run the test to verify it fails (red)**

Run: `mix test test/verscienta/audit/paper_trail_test.exs`
Expected: **compile error / failure** — the `*.Version` modules do not exist yet (`module Verscienta.Moderation.Action.Version is not available`). This confirms the test depends on the extension being wired.

- [ ] **Step 5: Commit the failing test + dep**

```bash
git add mix.exs mix.lock test/verscienta/audit/paper_trail_test.exs
git commit -m "test(audit): assert AshPaperTrail trails on audited resources (failing)"
```

---

### Task 2: Add AshPaperTrail.Resource to the four non-User resources

For EACH of the four resources below, (a) add the extension to the `use Ash.Resource` header and (b) add a `paper_trail` block as a top-level resource section (place it right after the `actions do … end` block, alongside `attributes`).

**The extension addition** — change the header's last line from:
```elixir
    authorizers: [Ash.Policy.Authorizer]
```
to:
```elixir
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource]
```

**The block** (identical for all four):
```elixir
  paper_trail do
    primary_key_type :uuid_v7
    change_tracking_mode :changes_only
    store_action_name? true
  end
```

- [ ] **Step 1:** `lib/verscienta/moderation/action.ex` — add extension + block.
- [ ] **Step 2:** `lib/verscienta/moderation/flag.ex` — add extension + block.
- [ ] **Step 3:** `lib/verscienta/billing/subscription.ex` — add extension + block.
- [ ] **Step 4:** `lib/verscienta/experts/expert_application.ex` — add extension + block.

---

### Task 3: Add AshPaperTrail.Resource to User (with secret redaction)

**Files:** `lib/verscienta/accounts/user.ex`

- [ ] **Step 1: Add the extension to User's existing list**

Change the header (line 3 block) from:
```elixir
    extensions: [AshAuthentication]
```
to:
```elixir
    extensions: [AshAuthentication, AshPaperTrail.Resource]
```

- [ ] **Step 2: Add the paper_trail block with ignore_attributes**

Add as a top-level section (after `actions do … end`):
```elixir
  paper_trail do
    primary_key_type :uuid_v7
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [
      :hashed_password,
      :confirmed_at,
      :deactivated_at,
      :deletion_finalizes_at,
      :anonymized_at
    ]
  end
```

Do NOT enable `store_action_inputs?` — its default `false` keeps the register action's plaintext `password` out of the trail.

---

### Task 4: Add AshPaperTrail.Domain to the four domains, then codegen

**Files:** `lib/verscienta/moderation.ex`, `lib/verscienta/billing.ex`, `lib/verscienta/experts.ex`, `lib/verscienta/accounts.ex`

- [ ] **Step 1: Add the domain extension to each of the four domains**

Change each domain's header from:
```elixir
  use Ash.Domain, otp_app: :verscienta
```
to:
```elixir
  use Ash.Domain, otp_app: :verscienta, extensions: [AshPaperTrail.Domain]
```

Add explicit `resource <X>.Version` entries to each domain's `resources do` block — `AshPaperTrail.Domain` does NOT auto-register them without `include_versions? true`. Explicit registration is the transparent fix and cannot double-register.

- [ ] **Step 2: Compile**

Run: `mix compile --warnings-as-errors`
Expected: clean. If the compiler reports a `*.Version` resource is not in its domain, the auto-registration didn't apply — in that case add the explicit `resource Verscienta.X.Y.Version` entries to the relevant `resources do` block and recompile.

- [ ] **Step 3: Generate the version-table migrations**

Run: `mix ash.codegen add_paper_trail`
Expected: generates ONE migration creating five tables — `action_versions`, `flag_versions`, `subscription_versions`, `expert_application_versions`, `user_versions` — each with `id` (uuid), `version_source_id`, `changes` (map/jsonb), `version_action_name`, and timestamps. Review the generated migration: confirm it only CREATEs the five `*_versions` tables and indexes (no ALTER to the source tables beyond the audit FK). Snapshots for the 5 version resources are written.

- [ ] **Step 4: Set up the DB**

Run: `mix ash.setup`
Expected: clean; the five version tables are created.

---

### Task 5: Green + regression

- [ ] **Step 1: Run the audit test**

Run: `mix test test/verscienta/audit/paper_trail_test.exs`
Expected: PASS — all four tests green (5 version tables queryable; user create + update produce versions; no password hash anywhere in the trail).

If the update test fails because `update_profile` does not accept `display_name`, change it to an attribute `update_profile` does accept (inspect the action in `user.ex`) and assert that attribute in `changes` instead — keep the assertion meaningful (a real changed value appears in `changes`).

- [ ] **Step 2: Full suite**

Run: `mix test`
Expected: passes. AshPaperTrail adds an after-action version write to each tracked create/update; if any existing test asserts an exact write/DB-row count on these resources, update that count to include the version write (do not disable auditing).

- [ ] **Step 3: Format**

Run: `mix format`

---

### Task 6: Verify migration reversibility + commit

- [ ] **Step 1: Prove the migration reverses**

Run:
```
mix ecto.rollback
mix ecto.migrate
```
Expected: rollback drops the five `*_versions` tables cleanly; re-migrate recreates them. Both succeed.

- [ ] **Step 2: Commit**

```bash
git add lib/ priv/ test/verscienta/audit/paper_trail_test.exs
git commit -m "feat(audit): AshPaperTrail trails on moderation, billing, experts, user

Immutable version history on Action, Flag, Subscription, ExpertApplication
and User. User trail ignores hashed_password and privacy-lifecycle fields;
store_action_inputs? left off so register passwords are never persisted.
uuid_v7 version keys; changes-only tracking with action name.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage (§3):** all 5 resources get `AshPaperTrail.Resource` (Tasks 2–3); the 4 domains get `AshPaperTrail.Domain` (Task 4); User ignores the secret + privacy fields and `store_action_inputs?` stays off (Task 3); existing bespoke history (`ArticleRevision`, `GamificationAudit`, `Flags.Audit`) untouched. ✅
- **Placeholder scan:** none — exact files, exact header edits, the full block, the full test, exact commands. The only conditional is the documented `update_profile`-attribute fallback (Task 5 Step 1), which is a guarded adaptation, not a placeholder. ✅
- **Type consistency:** version modules `<Resource>.Version`, relationship `paper_trail_versions`, attrs `changes`/`version_action_name`/`version_source_id` match AshPaperTrail v0.6; `primary_key_type :uuid_v7` aligns with Phase 1; factory `user/1` matches `test/support/factory.ex`. ✅
- **Secret safety:** redaction is asserted two ways (key absence AND the literal hash value absence) in the test; `store_action_inputs?` default-off documented. ✅

## Next Phase

Phase 4 (AshOban scan-based triggers for the four article async jobs) gets its own plan, read fresh against the article change modules and worker modules.
