# Backend Engine Foundations — Phase 4: AshOban Self-Healing Reconciler — Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add an AshOban periodic *reconciler* that self-heals article search-index drift, WITHOUT replacing the existing immediate after-action enqueue pipeline.

**Approach (decided):** Safety-net, not replacement. The 4 immediate `Enqueue*` after-action changes stay exactly as they are (latency, op-semantics, all 6 existing tests pass untouched). AshOban adds a periodic scan that re-enqueues work for articles whose derived artifact is missing/stale because a job was lost (crash, deploy, transient failure).

**Scope decision — index only (the high-value, unflagged artifact):**
- **index** — INCLUDED. Highest value (a lost index job = article invisible in search). Unflagged. Needs an `indexed_at` marker (added here).
- **og_card** — DEFERRED (low value: cosmetic share image; clean to add later with the same pattern, marker `og_image_url IS NULL`).
- **embed / enrich** — DEFERRED. They are gated by FunWithFlags (`:embeddings`, `:ai_enrichment`), and `Flags.enabled?/1` cannot be expressed in an Ash/SQL `where` — so when a flag is off the scan would churn (enqueue→worker-noop) over the whole backlog every tick. A scan reconciler is the wrong shape for flag-gated jobs; the immediate enqueue (already flag-guarded) remains their only path.

**Tech Stack:** Elixir, Ash 3.27.8, `ash_oban` (new dep), AshPostgres, Oban (queues default/aggregation/ai), `mix ash.codegen`.

**Spec:** `docs/superpowers/specs/2026-06-13-backend-engine-foundations-design.md` (§4) — note this realizes the spec's intent via the *reconciler* variant chosen during execution, not the full scan-based replacement.

---

## Environment

Run mix in the container (PowerShell tool for docker exec):
```
docker exec -e MIX_ENV=test -e MIX_DEPS_PATH=/workspace/deps -e MIX_BUILD_ROOT=/workspace/_build/wt-fervent -e MIX_TEST_PARTITION=_wt_fervent -w /workspace/.claude/worktrees/fervent-antonelli-f4448c news-verscienta-app-1 mix <args>
```
`mix deps.get` adds `ash_oban` to the shared `/workspace/deps` volume (safe superset).

## AshOban API — VERIFY against the installed dep before coding

The hexdocs DSL/getting-started pages are TOC-only (same gap that bit Phase 3's AshPaperTrail). After `mix deps.get`, READ `deps/ash_oban` (README + `lib/`) to confirm exact: (a) the `oban do triggers do trigger … end end end` options, (b) **how triggers register with Oban** (the cron/plugin wiring — likely `AshOban.config(domains, oban_base_config)` wrapped around the existing `config :verscienta, Oban` in `config/config.exs`, or an `{Oban.Plugins.Cron, …}` injection), and (c) the **test helper** (`AshOban.Test.schedule_and_run_triggers/1` or similar) to run a trigger synchronously in ExUnit. Do NOT assume — the config wiring is the highest-risk unknown.

Confirmed-from-docs DSL shape (Ash 3):
```elixir
use Ash.Resource, extensions: [AshOban]

oban do
  triggers do
    trigger :reconcile_index do
      scheduler_cron "*/15 * * * *"   # every 15 min — TUNE
      action :reconcile_index
      where expr(status == :published and is_nil(group_id) and
                 (is_nil(indexed_at) or indexed_at < updated_at))
      worker_module_name __MODULE__.ReconcileIndex.Worker
      scheduler_module_name __MODULE__.ReconcileIndex.Scheduler
    end
  end
end
```
AshOban runs `action` (an Ash update) on each record matching `where`, one Oban job per record. The action must flip the record OUT of `where`.

## File Structure

- **Modify:** `mix.exs` (dep); `config/config.exs` (Oban/AshOban wiring); `lib/verscienta/content/article.ex` (extension, `indexed_at` attr, `:reconcile_index` action, `oban` trigger block); `lib/verscienta/search/workers/index_article_worker.ex` (stamp `indexed_at` loop-safely).
- **Create:** `test/verscienta/search/index_reconciler_test.exs`.
- **Generated:** migration adding `articles.indexed_at`.

---

### Task 1: Dependency + the `indexed_at` marker (failing test)

- [ ] **Step 1:** In `mix.exs` deps, after `{:ash, "~> 3.0"},` add `{:ash_oban, "~> 0.8"},`. Run `mix deps.get`.
- [ ] **Step 2:** Add the attribute to `Article`'s `attributes do` block (near `published_at`):
  ```elixir
  # Set by IndexArticleWorker on every successful Meili sync (raw Repo write, so it
  # does NOT bump updated_at). Drives the reconcile_index AshOban trigger's staleness check.
  attribute :indexed_at, :utc_datetime_usec, allow_nil?: true
  ```
- [ ] **Step 3:** Write `test/verscienta/search/index_reconciler_test.exs` asserting (using the project's `Oban.Testing` + Factory): after creating a published, ungrouped article with `indexed_at = nil`, running the reconcile trigger enqueues `IndexArticleWorker` with `op: "upsert"`; and an article whose `indexed_at >= updated_at` is NOT enqueued. (Use the AshOban test helper confirmed in the API step; if unavailable, drive `AshOban.schedule_and_run_triggers/1`.)
- [ ] **Step 4:** Run it → RED (`:reconcile_index` action / trigger don't exist yet). Commit dep + marker + failing test.

### Task 2: Loop-safe `indexed_at` stamping in the worker

- [ ] **Step 1:** In `IndexArticleWorker`, after a successful upsert AND successful delete, stamp the marker via a RAW Ecto write (NOT an Ash action — avoids bumping `updated_at` and avoids re-firing the article's after-action `Enqueue*` changes, which would loop):
  ```elixir
  defp stamp_indexed(id) do
    Verscienta.Repo.update_all(
      from(a in "articles", where: a.id == type(^id, :binary_id)),
      set: [indexed_at: DateTime.utc_now()]
    )
  end
  ```
  Call `stamp_indexed(id)` on the `{:ok, _}` branches of both `perform` clauses. (For the "article not visible → deleted from index" upsert branch, also stamp — the article IS synced, just as absent.)
- [ ] **Step 2:** Run the existing search/index tests — must stay green. Compile `--warnings-as-errors`.

### Task 3: The reconcile action + AshOban trigger

- [ ] **Step 1:** Add `AshOban` to `Article`'s `use Ash.Resource, extensions: [...]` (it currently has `extensions: [AshStateMachine]` from Phase 2 → make it `[AshStateMachine, AshOban]`).
- [ ] **Step 2:** Add a thin update action `:reconcile_index` whose only effect is to enqueue the index upsert via the EXISTING `EnqueueIndex` change (its `op` logic already yields "upsert" for published+ungrouped). It must NOT accept attributes; `require_atomic? false`:
  ```elixir
  update :reconcile_index do
    description "AshOban safety-net: re-enqueue the search index sync for a stale/unindexed article."
    accept []
    require_atomic? false
    change Verscienta.Content.Article.Changes.EnqueueIndex
  end
  ```
  (Running this bumps `updated_at`, but `EnqueueIndex` → worker → `stamp_indexed` sets `indexed_at = now > updated_at`, so the record leaves `where`. Confirm ordering: the worker runs async; AshOban + the worker's `unique [article_id, op] 60s` dedup re-picks until the worker completes.)
- [ ] **Step 3:** Add the `oban do triggers do trigger :reconcile_index … end end end` block (DSL above), `where` exactly as shown.
- [ ] **Step 4:** Wire AshOban into the Oban config in `config/config.exs` (per the verified API — likely wrap `AshOban.config([Verscienta.Content], existing_oban_opts)` or inject the scheduler cron). Ensure it's a no-op / disabled in `config/test.exs` so the periodic scheduler doesn't fire during the suite (tests drive the trigger explicitly).
- [ ] **Step 5:** `mix ash.codegen add_index_reconciler` → migration adds `articles.indexed_at`. `mix ash.setup`.

### Task 4: Green + regression + reversibility

- [ ] **Step 1:** Reconciler test → GREEN.
- [ ] **Step 2:** Full suite green (the 6 existing enqueue/worker tests must be untouched and passing; watch for any that now also see `indexed_at`). Re-run at `--seed 0` and once at a random seed (the pre-existing fresh-DB disconnect flake is benign — confirm any failure is a different-random-test + disconnect, not a reconciler defect).
- [ ] **Step 3:** `mix ecto.rollback` / `mix ecto.migrate` clean (the `indexed_at` add reverses). `mix format`.

### Task 5: Commit

- [ ] Commit with a message describing the reconciler scope + the deferred (og_card/embed/enrich) artifacts and why.

---

## Self-Review

- **Scope honesty:** index reconciler only; og_card/embed/enrich deferred with documented reasons (cosmetic / flag-in-where). The immediate enqueue pipeline is UNCHANGED — zero risk to existing latency/tests. ✅
- **Loop safety:** `indexed_at` stamped via raw `Repo.update_all` (no `updated_at` bump, no after-action re-fire). The reconcile action reuses `EnqueueIndex`. ✅
- **Highest risk:** the AshOban→Oban config/scheduler wiring and the test helper — flagged to verify against `deps/ash_oban` source before coding (Phase 3 lesson). ⚠️
- **Placeholder note:** Task 1 Step 3 and Task 3 Step 4 are intentionally written to be pinned down against the verified AshOban API; the implementer confirms exact helper/config names from the dep, then fills them. This is the one area where the doc gap forces verify-then-write rather than copy-paste.

## Deferred (tracked)

- og_card reconciler (same pattern, marker `og_image_url IS NULL`, no migration).
- embed/enrich reconcilers — need a flag-aware scheduler (gate the trigger's scheduler on the flag at runtime, since the flag can't be a SQL `where`).
- Phase 5: keyset pagination + LiveView streams.
