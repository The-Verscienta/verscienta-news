# Backend Engine Foundations — Phase 2: AshStateMachine (Article lifecycle) — Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Govern the article editorial `:status` lifecycle (`draft → published → archived`) with `AshStateMachine`, so illegal transitions raise typed errors instead of silent `set_attribute`.

**Architecture:** Add the `AshStateMachine` extension to `Content.Article`, declare the state machine over the existing `:status` attribute, and replace the two `set_attribute(:status, …)` calls in `:publish`/`:archive` with `transition_state/1`. Moderation lives on the separate `:moderation_status` attribute and is untouched. No DB column changes — this is an Ash-layer validation change.

**Tech Stack:** Elixir, Ash 3.27.8, `ash_state_machine` (new dep), AshPostgres.

**Spec:** `docs/superpowers/specs/2026-06-13-backend-engine-foundations-design.md` (§2).

---

## Environment

Run mix inside the container (PowerShell tool for docker exec):

```
docker exec -e MIX_ENV=test -e MIX_DEPS_PATH=/workspace/deps \
  -e MIX_BUILD_ROOT=/workspace/_build/wt-fervent -e MIX_TEST_PARTITION=_wt_fervent \
  -w /workspace/.claude/worktrees/fervent-antonelli-f4448c \
  news-verscienta-app-1 mix <args>
```

**New dependency note:** Phase 2 adds `ash_state_machine`. Running `mix deps.get`
adds it to the shared `/workspace/deps` volume — this is a strict **superset** of
main's lock (only adds new dirs; no existing versions move), which is safe for the
shared dev container.

## Current State (read before editing)

`lib/verscienta/content/article.ex`:
- Header (lines 3–7): `use Ash.Resource, otp_app: :verscienta, domain: Verscienta.Content, data_layer: AshPostgres.DataLayer, authorizers: [Ash.Policy.Authorizer]` — **no `extensions:` key yet**.
- `:status` attribute (lines 382–387): `:atom`, `allow_nil? false`, `default :draft`, `constraints one_of: [:draft, :published, :archived]`.
- `:publish` action (line 83): `change set_attribute(:status, :published)` (line 87) + a published_at stamp change (lines 89–97).
- `:archive` action (line 110): `change set_attribute(:status, :archived)` (line 113).
- `:create_aggregated` (line 154): `change set_attribute(:status, :published)` (line 161) — a **create** that starts published.
- `:update` does NOT accept `:status`; moderation actions change `:moderation_status` only.

## File Structure

- **Modify:** `mix.exs` (add dep), `lib/verscienta/content/article.ex` (extension + state_machine block + two action changes).
- **Create:** `test/verscienta/content/article_state_machine_test.exs`.
- **Generated:** `priv/resource_snapshots/...` may update (no DB migration expected — `:status` column already exists).

---

### Task 1: Add the dependency and write the failing state-machine test

**Files:**
- Modify: `mix.exs`
- Test: `test/verscienta/content/article_state_machine_test.exs`

- [ ] **Step 1: Add `ash_state_machine` to deps**

In `mix.exs`, in the `deps/0` list, directly after the `{:ash, "~> 3.0"}` line, add:

```elixir
      {:ash_state_machine, "~> 0.2"},
```

- [ ] **Step 2: Fetch deps**

Run: `mix deps.get`
Expected: resolves and fetches `ash_state_machine` (+ any transitive deps) into `/workspace/deps`. No existing version changes. If the resolver reports an incompatible version for Ash 3.27, use the highest `0.2.x`/`~> 0.x` it offers and note it.

- [ ] **Step 3: Write the failing test**

Create `test/verscienta/content/article_state_machine_test.exs`:

```elixir
defmodule Verscienta.Content.ArticleStateMachineTest do
  use Verscienta.DataCase, async: false

  import Verscienta.Support.Factory, only: [user: 1, article: 1]

  alias Verscienta.Content.Article

  defp draft(author) do
    Article
    |> Ash.Changeset.for_create(
      :create,
      %{title: "Draft #{System.unique_integer([:positive])}", blocks: [], category: :movement},
      actor: author
    )
    |> Ash.create!()
  end

  test "create starts in :draft" do
    author = user("sm_drafter")
    assert draft(author).status == :draft
  end

  test "publish transitions draft -> published and stamps published_at" do
    author = user("sm_publisher")
    art = draft(author)

    published =
      art
      |> Ash.Changeset.for_update(:publish, %{}, actor: author)
      |> Ash.update!()

    assert published.status == :published
    assert published.published_at != nil
  end

  test "archive transitions published -> archived" do
    author = user("sm_archiver")
    art = article(author)
    assert art.status == :published

    archived =
      art
      |> Ash.Changeset.for_update(:archive, %{}, actor: author)
      |> Ash.update!()

    assert archived.status == :archived
  end

  test "archive transitions draft -> archived" do
    author = user("sm_draft_archiver")
    art = draft(author)

    archived =
      art
      |> Ash.Changeset.for_update(:archive, %{}, actor: author)
      |> Ash.update!()

    assert archived.status == :archived
  end

  test "publishing an already-published article is rejected as an illegal transition" do
    author = user("sm_double")
    art = article(author)
    assert art.status == :published

    assert {:error, %Ash.Error.Invalid{}} =
             art
             |> Ash.Changeset.for_update(:publish, %{}, actor: author)
             |> Ash.update()
  end

  test "create_aggregated starts in :published" do
    {:ok, art} =
      Article
      |> Ash.Changeset.for_create(
        :create_aggregated,
        %{
          title: "Aggregated #{System.unique_integer([:positive])}",
          excerpt: "x",
          category: :movement,
          canonical_url: "https://example.com/#{System.unique_integer([:positive])}",
          published_at: DateTime.utc_now()
        },
        authorize?: false
      )
      |> Ash.create()

    assert art.status == :published
  end
end
```

- [ ] **Step 4: Run the test to verify it fails on the right line**

Run: `mix test test/verscienta/content/article_state_machine_test.exs`
Expected: the **"already-published is rejected"** test FAILS — today `:publish` does `set_attribute(:status, :published)` unconditionally, so re-publishing returns `{:ok, ...}`, not `{:error, …}`. The other tests should pass already (they assert current behavior). This proves the new test captures the missing guard.

- [ ] **Step 5: Commit the failing test + dep**

```bash
git add mix.exs mix.lock test/verscienta/content/article_state_machine_test.exs
git commit -m "test(article): assert status lifecycle is a guarded state machine (failing)"
```

---

### Task 2: Add AshStateMachine to Article and convert the transitions

**Files:**
- Modify: `lib/verscienta/content/article.ex`

- [ ] **Step 1: Add the extension to the resource header**

Replace the `use Ash.Resource, …` block (lines 3–7) with:

```elixir
  use Ash.Resource,
    otp_app: :verscienta,
    domain: Verscienta.Content,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine]
```

- [ ] **Step 2: Declare the state machine**

Immediately after the `actions do … end` block closes (i.e. as a new top-level
section of the resource, alongside `attributes`, `relationships`, etc.), add:

```elixir
  state_machine do
    state_attribute :status
    initial_states [:draft, :published]
    default_initial_state :draft

    transitions do
      transition :publish, from: :draft, to: :published
      transition :archive, from: [:draft, :published], to: :archived
    end
  end
```

(`:published` is an allowed initial state because `:create_aggregated` is born
published; `:draft` is the default for the normal `:create`.)

- [ ] **Step 3: Convert `:publish` to a transition**

In the `:publish` action, replace this line:

```elixir
      change set_attribute(:status, :published)
```

with:

```elixir
      change transition_state(:published)
```

Leave the `published_at` stamping change and all other changes intact.

- [ ] **Step 4: Convert `:archive` to a transition**

In the `:archive` action, replace this line:

```elixir
      change set_attribute(:status, :archived)
```

with:

```elixir
      change transition_state(:archived)
```

- [ ] **Step 5: Leave `:create_aggregated` as-is**

Do **not** change `:create_aggregated`'s `change set_attribute(:status, :published)`
(line 161) — it is a create into an allowed initial state, not a transition.

- [ ] **Step 6: Compile**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean. If AshStateMachine complains that the `:status`
attribute's `one_of` must cover all declared states — it already does
(`[:draft, :published, :archived]`), so no change is needed.

---

### Task 3: Regenerate snapshots (no migration expected)

- [ ] **Step 1: Run codegen**

Run: `mix ash.codegen article_state_machine`
Expected: **no Postgres migration** (the `:status` column already exists;
AshStateMachine adds no DB columns). Snapshots may update with the new extension
metadata. If a migration *is* generated and it is non-empty / alters the
`articles` table, STOP and report — that is unexpected and must be reviewed.

- [ ] **Step 2: Set up the test DB**

Run: `mix ash.setup`
Expected: clean.

---

### Task 4: Green + regression

- [ ] **Step 1: Run the Phase 2 test**

Run: `mix test test/verscienta/content/article_state_machine_test.exs`
Expected: PASS — all six tests green, including the now-guarded
already-published rejection.

- [ ] **Step 2: Run the full suite**

Run: `mix test`
Expected: passes. **Watch item:** if a test fails because some flow re-publishes
an already-published article (now rejected), that flow relied on idempotent
re-publish. If and only if that happens, widen the publish transition to
`transition :publish, from: [:draft, :published], to: :published` (a self-loop on
`:published` preserves idempotency; `published_at` won't re-stamp because of the
existing nil-guard change), update the failing Phase 2 test's expectation
accordingly, and note the change in the report. Do **not** weaken the test without
a real re-publish caller justifying it.

- [ ] **Step 3: Format**

Run: `mix format`
Expected: formats the edited files cleanly.

---

### Task 5: Commit

- [ ] **Step 1: Commit**

```bash
git add lib/ priv/ test/verscienta/content/article_state_machine_test.exs
git commit -m "feat(article): govern status lifecycle with AshStateMachine

draft -> published -> archived as declared transitions; illegal
transitions (e.g. re-publish, unarchive) now raise typed errors.
moderation_status is unchanged.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage (§2):** state machine on `:status` only (Task 2 Step 2, `state_attribute :status`); `:moderation_status` untouched; transitions `publish`/`archive` per spec; `:create_aggregated` initial-state `:published` honored (Task 2 Step 5); `published_at` stamp preserved (Task 2 Step 3 leaves it). ✅
- **Placeholder scan:** none — exact file/lines, exact before/after code, full test, exact commands. ✅
- **Type consistency:** `transition_state/1` is the AshStateMachine change builder made available by the extension; `state_attribute :status` matches the existing attribute; factory helpers `user/1`, `article/1` match `test/support/factory.ex`; `draft/1` is defined locally in the test. ✅
- **Behavior change called out:** strict `:publish` from `:draft` makes re-publish raise; Task 4 Step 2 documents the contingency to widen if a real caller needs idempotency.

## Next Phase

Phase 3 (AshPaperTrail on Moderation.Action, Moderation.Flag, Billing.Subscription, Experts.ExpertApplication, Accounts.User with secret redaction) gets its own plan, read fresh against those resources.
