# Llama Toxicity + Dubious-Claim Detection on Submit — Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a user submits a comment, room message, or publishes an article, asynchronously run a local Llama (Ollama) check for toxicity (all types) and dubious health claims (articles only), and create a system-sourced `Moderation.Flag` in the existing moderator queue when a threshold is crossed.

**Architecture:** Mirror the existing AI-enrichment pattern. An `after_action` Ash change enqueues a unique Oban `:ai` job per submitted subject (only when the `:auto_moderation` flag is on). `AutoModerateWorker` loads the subject's text, runs `Moderation.Detector` (which calls the existing pluggable `AI.Client`), and on a threshold crossing creates a `Flag` via a new system `:ai_flag` action. A human still resolves the flag — no auto-removal here (that is the next todo).

**Tech Stack:** Elixir, Phoenix, Ash 3, AshPostgres, Oban, Ollama (`llama3.2:3b` via `AI.Client`), FunWithFlags.

**Spec:** `docs/superpowers/specs/2026-06-09-llama-auto-moderation-design.md`

**Conventions:**
- All `mix` commands run inside Docker: `docker compose exec app mix ...` (host mix fails on bcrypt nmake; the compose service is `app`).
- This project autogenerates migrations from resource snapshots via `mix ash_postgres.generate_migrations` — do NOT hand-write the migration; edit the resource, then generate.
- Commit messages end with the Co-Authored-By trailer shown in the commit steps.

---

### Task 1: `Flag` resource — `source` attribute, nullable reporter, `:ai_flag` action

**Files:**
- Modify: `lib/verscienta/moderation/flag.ex`
- Generated: `priv/repo/migrations/*_add_flag_ai_source.exs` + `priv/resource_snapshots/repo/moderation_flags/*.json`

- [ ] **Step 1: Add the `:ai_flag` action**

In `lib/verscienta/moderation/flag.ex`, inside the `actions do ... end` block, after the `read :queue do ... end` block (around line 36) and before `update :mark_resolved`, add:

```elixir
    create :ai_flag do
      description "System action: file an AI-sourced flag (no human reporter). Worker-only."
      accept [:subject_type, :subject_id, :reason, :note]
      change set_attribute(:source, :ai)
      change Verscienta.Moderation.Flag.Changes.CaptureSubject
    end
```

(`CaptureSubject` runs with a `nil` actor here — it snapshots the subject's excerpt/author and only rejects self-reporting when an actor is present, so it is safe for system flags.)

- [ ] **Step 2: Add the `source` attribute**

In the same file, inside `attributes do ... end`, immediately after the `reason` attribute (around line 79), add:

```elixir
    attribute :source, :atom,
      allow_nil?: false,
      public?: true,
      default: :community,
      constraints: [one_of: [:community, :ai]]
```

- [ ] **Step 3: Make the `reporter` relationship nullable**

In the `relationships do ... end` block, change:

```elixir
    belongs_to :reporter, Verscienta.Accounts.User, allow_nil?: false
```

to:

```elixir
    belongs_to :reporter, Verscienta.Accounts.User, allow_nil?: true
```

- [ ] **Step 4: Generate the migration + snapshot**

Run:
```bash
docker compose exec app mix ash_postgres.generate_migrations --name add_flag_ai_source
```
Expected: creates a new migration in `priv/repo/migrations/` and updates the `moderation_flags` snapshot. The migration should (a) add a `source` text column with default `"community"` not-null, and (b) drop the NOT NULL on `reporter_id`. Open the generated migration and confirm it contains roughly:

```elixir
    alter table(:moderation_flags) do
      add :source, :text, null: false, default: "community"
      modify :reporter_id, :uuid, null: true
    end
```

If the `modify :reporter_id` line is missing, the relationship edit in Step 3 didn't take — re-check and regenerate.

- [ ] **Step 5: Run the migration**

Run:
```bash
docker compose exec app mix ecto.migrate
```
Expected: migration applies cleanly; `moderation_flags.source` exists and `reporter_id` is nullable.

- [ ] **Step 6: Compile to verify the resource is valid**

Run:
```bash
docker compose exec app mix compile --warnings-as-errors
```
Expected: compiles with no warnings.

- [ ] **Step 7: Commit**

```bash
docker compose exec app mix format
git add lib/verscienta/moderation/flag.ex priv/repo/migrations priv/resource_snapshots
git commit -m "$(cat <<'EOF'
feat(moderation): add Flag source + system :ai_flag action

Adds a :community|:ai source marker, makes reporter nullable (AI flags
have no human reporter), and a worker-only :ai_flag create action.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `Subject.text/2` + `Moderation.ai_flag/4` / `ai_flag_exists?/2`

**Files:**
- Modify: `lib/verscienta/moderation/subject.ex`
- Modify: `lib/verscienta/moderation.ex`
- Test: `test/verscienta/moderation/ai_flag_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/moderation/ai_flag_test.exs`:

```elixir
defmodule Verscienta.Moderation.AiFlagTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Moderation
  alias Verscienta.Moderation.Subject

  defp user(name) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com",
      username: name,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp comment(author) do
    {:ok, art} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: "A", blocks: [], category: :movement},
        actor: author
      )
      |> Ash.create()

    Verscienta.Engagement.Comment
    |> Ash.Changeset.for_create(:create, %{body: "you are an idiot", article_id: art.id},
      actor: author
    )
    |> Ash.create!()
  end

  test "Subject.text returns the comment body" do
    c = comment(user("aiflag_text"))
    assert {:ok, "you are an idiot"} = Subject.text(:comment, c.id)
  end

  test "Subject.text returns :error for a missing subject" do
    assert :error = Subject.text(:comment, Ecto.UUID.generate())
  end

  test "ai_flag creates a pending AI-sourced flag, deduped on repeat" do
    c = comment(user("aiflag_dup"))

    assert :ok = Moderation.ai_flag(:comment, c.id, :harassment, "abusive language")
    assert Moderation.ai_flag_exists?(:comment, c.id)

    flags = Ash.read!(Verscienta.Moderation.Flag, authorize?: false)
    ai = Enum.filter(flags, &(&1.source == :ai and &1.subject_id == c.id))
    assert [flag] = ai
    assert flag.reason == :harassment
    assert flag.note == "abusive language"
    assert flag.reporter_id == nil
    assert flag.subject_excerpt == "you are an idiot"

    # Repeat is a no-op (still one flag).
    assert :ok = Moderation.ai_flag(:comment, c.id, :harassment, "again")
    flags2 = Ash.read!(Verscienta.Moderation.Flag, authorize?: false)
    assert length(Enum.filter(flags2, &(&1.source == :ai and &1.subject_id == c.id))) == 1
  end
end
```

- [ ] **Step 2: Run it to confirm failure**

Run:
```bash
docker compose exec app mix test test/verscienta/moderation/ai_flag_test.exs
```
Expected: FAIL — `Subject.text/2` and `Moderation.ai_flag/4` are undefined.

- [ ] **Step 3: Add `Subject.text/2`**

In `lib/verscienta/moderation/subject.ex`, after the `snapshot(_, _)` clause (around line 52), add:

```elixir
  @doc "Return `{:ok, text}` to analyze for a subject, or `:error` if it can't be loaded."
  @spec text(subject_type, Ecto.UUID.t()) :: {:ok, String.t()} | :error
  def text(:comment, id) do
    case Ash.get(Comment, id, authorize?: false) do
      {:ok, c} -> {:ok, to_string(c.body)}
      _ -> :error
    end
  end

  def text(:room_message, id) do
    case Ash.get(Message, id, authorize?: false) do
      {:ok, m} -> {:ok, to_string(m.body)}
      _ -> :error
    end
  end

  def text(:article, id) do
    case Ash.get(Article, id, authorize?: false) do
      {:ok, a} ->
        body = Verscienta.Search.Document.blocks_to_text(a.blocks)

        {:ok,
         to_string(a.title) <> "\n" <> to_string(a.excerpt || "") <> "\n" <> to_string(body)}

      _ ->
        :error
    end
  end

  def text(_, _), do: :error
```

- [ ] **Step 4: Add `ai_flag/4` + `ai_flag_exists?/2` to the Moderation context**

In `lib/verscienta/moderation.ex`, after `pending_groups/0` (ends around line 158) and before `defp pending_flags`, add:

```elixir
  @doc """
  Create a system (AI-sourced) flag for a subject, unless a pending AI flag for
  it already exists. Best-effort: returns `:ok` regardless (never raises into the
  worker). `reason` is `:harassment` or `:misinformation`; `note` is the model's
  rationale.
  """
  def ai_flag(subject_type, subject_id, reason, note) do
    if ai_flag_exists?(subject_type, subject_id) do
      :ok
    else
      Flag
      |> Ash.Changeset.for_create(:ai_flag, %{
        subject_type: subject_type,
        subject_id: subject_id,
        reason: reason,
        note: note
      })
      |> Ash.create(authorize?: false)
      |> case do
        {:ok, _flag} -> :ok
        {:error, _reason} -> :ok
      end
    end
  end

  @doc "True if a pending AI-sourced flag already exists for the subject."
  def ai_flag_exists?(subject_type, subject_id) do
    Flag
    |> Ash.Query.filter(
      status == :pending and source == :ai and
        subject_type == ^subject_type and subject_id == ^subject_id
    )
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> Enum.any?()
  end
```

(`require Ash.Query` is already present at the top of the module, and `Flag` is already aliased.)

- [ ] **Step 5: Run the test to confirm it passes**

Run:
```bash
docker compose exec app mix test test/verscienta/moderation/ai_flag_test.exs
```
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
docker compose exec app mix format
git add lib/verscienta/moderation/subject.ex lib/verscienta/moderation.ex test/verscienta/moderation/ai_flag_test.exs
git commit -m "$(cat <<'EOF'
feat(moderation): Subject.text/2 + ai_flag context helpers

Adds polymorphic text extraction for detection and a deduped
ai_flag/4 that files a system flag into the existing queue.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `Moderation.Detector`

**Files:**
- Create: `lib/verscienta/moderation/detector.ex`
- Modify: `config/config.exs` (toxicity threshold)
- Test: `test/verscienta/moderation/detector_test.exs`

- [ ] **Step 1: Add the threshold config**

In `config/config.exs`, after the `config :verscienta, ai_client: Verscienta.AI.Client.Req` line (line 81), add:

```elixir
config :verscienta, Verscienta.Moderation, toxicity_min_severity: :high
```

- [ ] **Step 2: Write the failing test**

Create `test/verscienta/moderation/detector_test.exs`:

```elixir
defmodule Verscienta.Moderation.DetectorTest do
  # async: false — the stub is configured via global Application env.
  use ExUnit.Case, async: false

  alias Verscienta.AI.Client.Stub
  alias Verscienta.Moderation.Detector

  setup do
    prev = Application.get_env(:verscienta, :ai_client)
    Application.put_env(:verscienta, :ai_client, Stub)
    Stub.reset()
    on_exit(fn -> Application.put_env(:verscienta, :ai_client, prev) end)
    :ok
  end

  defp stub_generate(json), do: Application.put_env(:verscienta, :ai_stub, %{generate: {:ok, json}})

  test "toxic comment is flagged toxic, dubious ignored for non-article" do
    stub_generate(~s({"toxic": true, "toxicity_severity": "high", "toxicity_reason": "insult", "dubious_claim": true, "claim_reason": "x"}))

    assert {:ok, v} = Detector.analyze(:comment, "you are an idiot")
    assert v.toxic? == true
    assert v.dubious? == false
    assert v.toxicity_reason == "insult"
    assert v.claim_reason == nil
  end

  test "low-severity toxicity does not cross the :high threshold" do
    stub_generate(~s({"toxic": true, "toxicity_severity": "low", "toxicity_reason": "mild"}))
    assert {:ok, %{toxic?: false}} = Detector.analyze(:comment, "meh")
  end

  test "dubious article claim is detected" do
    stub_generate(~s({"toxic": false, "toxicity_severity": "none", "dubious_claim": true, "claim_reason": "miracle cure"}))

    assert {:ok, v} = Detector.analyze(:article, "Bleach cures everything")
    assert v.toxic? == false
    assert v.dubious? == true
    assert v.claim_reason == "miracle cure"
  end

  test "clean content yields no flags" do
    stub_generate(~s({"toxic": false, "toxicity_severity": "none", "dubious_claim": false}))
    assert {:ok, %{toxic?: false, dubious?: false}} = Detector.analyze(:article, "A balanced diet helps.")
  end

  test "invalid JSON returns an error" do
    stub_generate("not json")
    assert {:error, :invalid} = Detector.analyze(:comment, "hi")
  end

  test "client error is propagated for retry" do
    Application.put_env(:verscienta, :ai_stub, %{generate: {:error, :timeout}})
    assert {:error, :timeout} = Detector.analyze(:comment, "hi")
  end
end
```

- [ ] **Step 3: Run it to confirm failure**

Run:
```bash
docker compose exec app mix test test/verscienta/moderation/detector_test.exs
```
Expected: FAIL — `Verscienta.Moderation.Detector` is undefined.

- [ ] **Step 4: Implement the Detector**

Create `lib/verscienta/moderation/detector.ex`:

```elixir
defmodule Verscienta.Moderation.Detector do
  @moduledoc """
  Llama-based content-safety check. Asks the local LLM whether a piece of text
  is toxic (all subject types) and, for articles, whether it makes dubious
  health claims. Best-effort: a client or parse failure returns `{:error, _}`
  and never raises.
  """
  require Logger

  alias Verscienta.AI.Client

  @body_char_budget 4_000
  @severity_rank %{"none" => 0, "low" => 1, "high" => 2}
  @reason_limit 500

  @type verdict :: %{
          toxic?: boolean(),
          dubious?: boolean(),
          toxicity_reason: String.t() | nil,
          claim_reason: String.t() | nil
        }

  @doc """
  Analyze `text` for a subject. Returns `{:ok, verdict}`, `{:error, :invalid}`
  on a permanent parse failure, or `{:error, reason}` on a transient client
  failure (caller MAY retry). Dubious-claim detection only applies to articles.
  """
  @spec analyze(atom(), String.t()) :: {:ok, verdict()} | {:error, term()}
  def analyze(subject_type, text) when is_binary(text) do
    article? = subject_type == :article

    with {:ok, raw} <- Client.generate(build_prompt(article?, text)),
         {:ok, map} <- parse(raw) do
      {:ok, to_verdict(map, article?)}
    end
  rescue
    error ->
      Logger.warning("Moderation detector crashed: #{inspect(error)}")
      {:error, :crashed}
  end

  def analyze(_type, _text), do: {:error, :invalid}

  defp parse(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, :invalid}
    end
  end

  defp parse(_), do: {:error, :invalid}

  defp to_verdict(map, article?) do
    %{
      toxic?: toxic?(map),
      dubious?: article? and map["dubious_claim"] == true,
      toxicity_reason: clean(map["toxicity_reason"]),
      claim_reason: if(article?, do: clean(map["claim_reason"]), else: nil)
    }
  end

  defp toxic?(map) do
    map["toxic"] == true and severity_rank(map["toxicity_severity"]) >= min_severity_rank()
  end

  defp severity_rank(value) when is_binary(value),
    do: Map.get(@severity_rank, String.downcase(value), 0)

  defp severity_rank(_), do: 0

  defp min_severity_rank do
    min =
      :verscienta
      |> Application.get_env(Verscienta.Moderation, [])
      |> Keyword.get(:toxicity_min_severity, :high)

    Map.get(@severity_rank, Atom.to_string(min), 2)
  end

  defp clean(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      s -> String.slice(s, 0, @reason_limit)
    end
  end

  defp clean(_), do: nil

  defp build_prompt(true = _article?, text) do
    """
    You are a content-safety classifier for a holistic-health news platform.
    Read the CONTENT and return ONLY a JSON object with these keys:
      "toxic": true or false (harassment, hate, threats, or abusive language).
      "toxicity_severity": one of "none", "low", "high".
      "toxicity_reason": a short phrase explaining the toxicity, or "".
      "dubious_claim": true or false (unsupported or dangerous health/medical
        claims presented as fact, e.g. miracle cures or anti-science advice).
      "claim_reason": a short phrase naming the dubious claim, or "".
    Do not include any text outside the JSON object.

    CONTENT:
    #{String.slice(text, 0, @body_char_budget)}
    """
  end

  defp build_prompt(false = _article?, text) do
    """
    You are a content-safety classifier for a community discussion platform.
    Read the CONTENT and return ONLY a JSON object with these keys:
      "toxic": true or false (harassment, hate, threats, or abusive language).
      "toxicity_severity": one of "none", "low", "high".
      "toxicity_reason": a short phrase explaining the toxicity, or "".
    Do not include any text outside the JSON object.

    CONTENT:
    #{String.slice(text, 0, @body_char_budget)}
    """
  end
end
```

- [ ] **Step 5: Run the test to confirm it passes**

Run:
```bash
docker compose exec app mix test test/verscienta/moderation/detector_test.exs
```
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
docker compose exec app mix format
git add lib/verscienta/moderation/detector.ex config/config.exs test/verscienta/moderation/detector_test.exs
git commit -m "$(cat <<'EOF'
feat(moderation): Llama-based toxicity + dubious-claim detector

Detector.analyze/2 prompts the local LLM for toxicity (all types) and
dubious health claims (articles only); severity-gated, best-effort.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `AutoModerateWorker`

**Files:**
- Create: `lib/verscienta/moderation/workers/auto_moderate_worker.ex`
- Test: `test/verscienta/moderation/workers/auto_moderate_worker_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/moderation/workers/auto_moderate_worker_test.exs`:

```elixir
defmodule Verscienta.Moderation.Workers.AutoModerateWorkerTest do
  use Verscienta.DataCase, async: false
  use Oban.Testing, repo: Verscienta.Repo

  alias Verscienta.AI.Client.Stub
  alias Verscienta.Moderation
  alias Verscienta.Moderation.Workers.AutoModerateWorker

  setup do
    prev = Application.get_env(:verscienta, :ai_client)
    Application.put_env(:verscienta, :ai_client, Stub)
    Stub.reset()
    Verscienta.Flags.enable(:auto_moderation)
    on_exit(fn -> Application.put_env(:verscienta, :ai_client, prev) end)
    :ok
  end

  defp stub_generate(json), do: Application.put_env(:verscienta, :ai_stub, %{generate: {:ok, json}})

  defp user(name) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com",
      username: name,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp comment(author, body) do
    {:ok, art} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: "A", blocks: [], category: :movement},
        actor: author
      )
      |> Ash.create()

    Verscienta.Engagement.Comment
    |> Ash.Changeset.for_create(:create, %{body: body, article_id: art.id}, actor: author)
    |> Ash.create!()
  end

  defp run(c), do: perform_job(AutoModerateWorker, %{"subject_type" => "comment", "subject_id" => c.id})

  test "toxic comment produces a harassment AI flag" do
    stub_generate(~s({"toxic": true, "toxicity_severity": "high", "toxicity_reason": "insult"}))
    c = comment(user("automod_tox"), "you are an idiot")

    assert :ok = run(c)
    assert Moderation.ai_flag_exists?(:comment, c.id)

    [flag] =
      Verscienta.Moderation.Flag
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&(&1.source == :ai and &1.subject_id == c.id))

    assert flag.reason == :harassment
    assert flag.note == "insult"
  end

  test "clean comment produces no flag" do
    stub_generate(~s({"toxic": false, "toxicity_severity": "none"}))
    c = comment(user("automod_clean"), "great article, thanks")

    assert :ok = run(c)
    refute Moderation.ai_flag_exists?(:comment, c.id)
  end

  test "flag off: worker is a no-op" do
    Verscienta.Flags.disable(:auto_moderation)
    stub_generate(~s({"toxic": true, "toxicity_severity": "high", "toxicity_reason": "insult"}))
    c = comment(user("automod_off"), "you are an idiot")

    assert :ok = run(c)
    refute Moderation.ai_flag_exists?(:comment, c.id)
  end

  test "transient client error returns {:error, _} for retry, no flag" do
    Application.put_env(:verscienta, :ai_stub, %{generate: {:error, :timeout}})
    c = comment(user("automod_err"), "anything")

    assert {:error, :timeout} = run(c)
    refute Moderation.ai_flag_exists?(:comment, c.id)
  end

  test "invalid model output: no flag, no crash" do
    stub_generate("garbage")
    c = comment(user("automod_garbage"), "anything")

    assert :ok = run(c)
    refute Moderation.ai_flag_exists?(:comment, c.id)
  end

  test "running twice keeps a single flag" do
    stub_generate(~s({"toxic": true, "toxicity_severity": "high", "toxicity_reason": "insult"}))
    c = comment(user("automod_dup"), "you are an idiot")

    assert :ok = run(c)
    assert :ok = run(c)

    flags =
      Verscienta.Moderation.Flag
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&(&1.source == :ai and &1.subject_id == c.id))

    assert length(flags) == 1
  end
end
```

- [ ] **Step 2: Run it to confirm failure**

Run:
```bash
docker compose exec app mix test test/verscienta/moderation/workers/auto_moderate_worker_test.exs
```
Expected: FAIL — `AutoModerateWorker` is undefined.

- [ ] **Step 3: Implement the worker**

Create `lib/verscienta/moderation/workers/auto_moderate_worker.ex`:

```elixir
defmodule Verscienta.Moderation.Workers.AutoModerateWorker do
  @moduledoc """
  Llama-based toxicity + dubious-claim check for a single submitted subject.
  Best-effort, retryable on transient client errors. Creates a system flag in
  the moderation queue when content crosses a threshold; never auto-removes
  content (a human resolves the flag).
  """
  use Oban.Worker,
    queue: :ai,
    max_attempts: 3,
    unique: [
      keys: [:subject_type, :subject_id],
      period: 60,
      states: Oban.Job.unique_states(:incomplete)
    ]

  alias Verscienta.Moderation
  alias Verscienta.Moderation.{Detector, Subject}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subject_type" => type, "subject_id" => id}}) do
    if Verscienta.Flags.enabled?(:auto_moderation) do
      do_perform(String.to_existing_atom(type), id)
    else
      :ok
    end
  end

  defp do_perform(type, id) do
    with {:ok, text} <- Subject.text(type, id),
         {:ok, verdict} <- Detector.analyze(type, text) do
      maybe_flag(type, id, verdict)
    else
      # Subject gone, or permanent parse/crash failure: nothing to do.
      :error -> :ok
      {:error, :invalid} -> :ok
      {:error, :crashed} -> :ok
      # Transient client failure (Ollama down/timeout): let Oban retry.
      {:error, reason} -> {:error, reason}
    end
  end

  # One flag per subject. Toxicity (harassment) takes priority over a dubious
  # claim; both rationales are recorded in the note.
  defp maybe_flag(type, id, verdict) do
    cond do
      verdict.toxic? -> Moderation.ai_flag(type, id, :harassment, note(verdict))
      verdict.dubious? -> Moderation.ai_flag(type, id, :misinformation, note(verdict))
      true -> :ok
    end
  end

  defp note(verdict) do
    [verdict.toxicity_reason, verdict.claim_reason]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> "Flagged by automated moderation."
      s -> String.slice(s, 0, 1000)
    end
  end
end
```

- [ ] **Step 4: Run the test to confirm it passes**

Run:
```bash
docker compose exec app mix test test/verscienta/moderation/workers/auto_moderate_worker_test.exs
```
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
docker compose exec app mix format
git add lib/verscienta/moderation/workers/auto_moderate_worker.ex test/verscienta/moderation/workers/auto_moderate_worker_test.exs
git commit -m "$(cat <<'EOF'
feat(moderation): AutoModerateWorker creates AI flags on threshold

Oban :ai worker runs the Detector for a submitted subject and files a
system flag (harassment/misinformation) into the queue. Gated by the
:auto_moderation flag; degrades gracefully when Ollama is unavailable.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `EnqueueAutoModerate` change + wire into the three submit paths

**Files:**
- Create: `lib/verscienta/moderation/changes/enqueue_auto_moderate.ex`
- Modify: `lib/verscienta/engagement/comment.ex`
- Modify: `lib/verscienta/communities/message.ex`
- Modify: `lib/verscienta/content/article.ex`
- Test: `test/verscienta/moderation/enqueue_auto_moderate_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/moderation/enqueue_auto_moderate_test.exs`:

```elixir
defmodule Verscienta.Moderation.EnqueueAutoModerateTest do
  use Verscienta.DataCase, async: false
  use Oban.Testing, repo: Verscienta.Repo

  alias Verscienta.Moderation.Workers.AutoModerateWorker

  defp user(name) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com",
      username: name,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp article(author) do
    Verscienta.Content.Article
    |> Ash.Changeset.for_create(:create, %{title: "A", blocks: [], category: :movement},
      actor: author
    )
    |> Ash.create!()
  end

  defp comment(author) do
    art = article(author)

    Verscienta.Engagement.Comment
    |> Ash.Changeset.for_create(:create, %{body: "hello", article_id: art.id}, actor: author)
    |> Ash.create!()
  end

  test "creating a comment enqueues an auto-moderation job when the flag is on" do
    Verscienta.Flags.enable(:auto_moderation)
    c = comment(user("enqmod_on"))

    assert_enqueued(
      worker: AutoModerateWorker,
      args: %{"subject_type" => "comment", "subject_id" => c.id}
    )
  end

  test "publishing an article enqueues an auto-moderation job when the flag is on" do
    Verscienta.Flags.enable(:auto_moderation)
    author = user("enqmod_pub")
    art = article(author)

    art |> Ash.Changeset.for_update(:publish, %{}, actor: author) |> Ash.update!()

    assert_enqueued(
      worker: AutoModerateWorker,
      args: %{"subject_type" => "article", "subject_id" => art.id}
    )
  end

  test "no job is enqueued when the flag is off" do
    Verscienta.Flags.disable(:auto_moderation)
    comment(user("enqmod_off"))

    refute_enqueued(worker: AutoModerateWorker)
  end
end
```

- [ ] **Step 2: Run it to confirm failure**

Run:
```bash
docker compose exec app mix test test/verscienta/moderation/enqueue_auto_moderate_test.exs
```
Expected: FAIL — no job enqueued (the change isn't wired in yet).

- [ ] **Step 3: Implement the change**

Create `lib/verscienta/moderation/changes/enqueue_auto_moderate.ex`:

```elixir
defmodule Verscienta.Moderation.Changes.EnqueueAutoModerate do
  @moduledoc """
  After-action: enqueue a best-effort Llama toxicity/claim check for the created
  or published subject. No-ops unless the `:auto_moderation` flag is on. The
  subject type is supplied as the `:subject_type` option.
  """
  use Ash.Resource.Change
  require Logger

  alias Verscienta.Moderation.Workers.AutoModerateWorker

  @impl true
  def change(changeset, opts, _context) do
    subject_type = Keyword.fetch!(opts, :subject_type)

    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      enqueue(subject_type, record.id)
      {:ok, record}
    end)
  end

  # Best-effort: an enqueue failure must never roll back the content write.
  defp enqueue(subject_type, subject_id) do
    if Verscienta.Flags.enabled?(:auto_moderation) do
      %{"subject_type" => to_string(subject_type), "subject_id" => subject_id}
      |> AutoModerateWorker.new()
      |> Oban.insert!()
    end

    :ok
  rescue
    error ->
      Logger.warning(
        "Failed to enqueue auto-moderation for #{subject_type} #{subject_id}: #{inspect(error)}"
      )

      :ok
  end
end
```

- [ ] **Step 4: Wire into Comment `:create`**

In `lib/verscienta/engagement/comment.ex`, in the `create :create` action, after the `InvalidateCounts` change line (line 27), add:

```elixir
      change {Verscienta.Moderation.Changes.EnqueueAutoModerate, subject_type: :comment}
```

- [ ] **Step 5: Wire into Message `:post`**

In `lib/verscienta/communities/message.ex`, in the `create :post` action, after the `RejectIfSuspended` change line (line 20), add:

```elixir
      change {Verscienta.Moderation.Changes.EnqueueAutoModerate, subject_type: :room_message}
```

- [ ] **Step 6: Wire into Article `:publish`**

In `lib/verscienta/content/article.ex`, in the `update :publish` action, after the `TrackArticlePublished` change line (line 82), add:

```elixir
      change {Verscienta.Moderation.Changes.EnqueueAutoModerate, subject_type: :article}
```

- [ ] **Step 7: Run the test to confirm it passes**

Run:
```bash
docker compose exec app mix test test/verscienta/moderation/enqueue_auto_moderate_test.exs
```
Expected: PASS (3 tests).

- [ ] **Step 8: Commit**

```bash
docker compose exec app mix format
git add lib/verscienta/moderation/changes/enqueue_auto_moderate.ex lib/verscienta/engagement/comment.ex lib/verscienta/communities/message.ex lib/verscienta/content/article.ex test/verscienta/moderation/enqueue_auto_moderate_test.exs
git commit -m "$(cat <<'EOF'
feat(moderation): enqueue auto-moderation on submit

Wires the EnqueueAutoModerate after-action into comment create, room
message post, and article publish. Gated by :auto_moderation (off by
default), so it is inert until switched on.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Surface AI-sourced flags in the moderation queue UI

**Files:**
- Modify: `lib/verscienta/moderation.ex` (`pending_groups/0` exposes `sources`)
- Modify: `lib/verscienta_web/live/admin_moderation_live.ex` (render AI badge)
- Test: `test/verscienta/moderation/pending_groups_source_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/moderation/pending_groups_source_test.exs`:

```elixir
defmodule Verscienta.Moderation.PendingGroupsSourceTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Moderation

  defp user(name) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com",
      username: name,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp comment(author) do
    {:ok, art} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: "A", blocks: [], category: :movement},
        actor: author
      )
      |> Ash.create()

    Verscienta.Engagement.Comment
    |> Ash.Changeset.for_create(:create, %{body: "you are an idiot", article_id: art.id},
      actor: author
    )
    |> Ash.create!()
  end

  test "pending_groups exposes :ai in the group's sources" do
    c = comment(user("groupsrc"))
    Moderation.ai_flag(:comment, c.id, :harassment, "insult")

    group = Enum.find(Moderation.pending_groups(), &(&1.subject_id == c.id))
    assert group
    assert :ai in group.sources
  end
end
```

- [ ] **Step 2: Run it to confirm failure**

Run:
```bash
docker compose exec app mix test test/verscienta/moderation/pending_groups_source_test.exs
```
Expected: FAIL — `KeyError` / `:sources` not present in the group map.

- [ ] **Step 3: Add `sources` to the group map**

In `lib/verscienta/moderation.ex`, inside `pending_groups/0`, in the map built per group (around lines 146-154), add a `sources:` key after `reasons:`:

```elixir
        reasons: flags |> Enum.map(& &1.reason) |> Enum.uniq(),
        sources: flags |> Enum.map(& &1.source) |> Enum.uniq(),
        first_reported_at: flags |> Enum.map(& &1.inserted_at) |> Enum.min(DateTime)
```

- [ ] **Step 4: Run the test to confirm it passes**

Run:
```bash
docker compose exec app mix test test/verscienta/moderation/pending_groups_source_test.exs
```
Expected: PASS.

- [ ] **Step 5: Render the AI badge in the queue**

In `lib/verscienta_web/live/admin_moderation_live.ex`, in `render/1`, find the metadata line (around lines 89-91):

```elixir
            <div class="text-[11px] uppercase tracking-wider text-ink-3">
              {g.subject_type} · {g.count} report(s) · {Enum.join(g.reasons, ", ")}
            </div>
```

Replace it with (adds a 🤖 AI badge when any flag in the group is AI-sourced):

```elixir
            <div class="text-[11px] uppercase tracking-wider text-ink-3">
              {g.subject_type} · {g.count} report(s) · {Enum.join(g.reasons, ", ")}
              <span :if={:ai in g.sources} class="ml-2 text-warning">🤖 flagged by AI</span>
            </div>
```

(If `text-warning` is not a defined token, use `text-ink` — verify against `assets/css/app.css` `@theme`; the existing template uses `text-ink-3`/`text-ink-2`/`text-ink`.)

- [ ] **Step 6: Verify the LiveView still renders (compile + existing mod LiveView test)**

Run:
```bash
docker compose exec app mix compile --warnings-as-errors
docker compose exec app mix test test/verscienta_web/live/admin_moderation_live_test.exs
```
Expected: compiles clean; existing moderation LiveView tests pass (or "no such file" if none exists — in that case skip the second command).

- [ ] **Step 7: Commit**

```bash
docker compose exec app mix format
git add lib/verscienta/moderation.ex lib/verscienta_web/live/admin_moderation_live.ex test/verscienta/moderation/pending_groups_source_test.exs
git commit -m "$(cat <<'EOF'
feat(moderation): label AI-sourced flags in the queue

pending_groups exposes the set of flag sources; the queue renders a
"flagged by AI" badge when any report in a group is AI-sourced.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Full verification + todo check-off

**Files:**
- Modify: `docs/todo.md`

- [ ] **Step 1: Run the full moderation test suite**

Run:
```bash
docker compose exec app mix test test/verscienta/moderation
```
Expected: all pass.

- [ ] **Step 2: Run format check, Credo, and the full suite**

Run:
```bash
docker compose exec app mix format --check-formatted
docker compose exec app mix credo --strict
docker compose exec app mix test
```
Expected: format clean, no new Credo issues, full suite green. If Credo flags the new modules, fix inline and re-run.

- [ ] **Step 3: Check off the todo item**

In `docs/todo.md`, change line 218 from:

```markdown
- [ ] Llama-based toxicity + dubious-claim detection on submit.
```

to:

```markdown
- [x] Llama-based toxicity + dubious-claim detection on submit. *(async Oban :ai worker on comment/message/article submit → Moderation.Detector → system-sourced ModerationFlag in the queue; gated by the off-by-default `:auto_moderation` flag; toxicity for all types, dubious-claim for articles only; graceful degradation when Ollama is down)*
```

- [ ] **Step 4: Commit**

```bash
git add docs/todo.md
git commit -m "$(cat <<'EOF'
docs(moderation): check off Llama toxicity + dubious-claim detection

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Notes for the implementer

- **One flag per subject:** dedup is enforced by `Moderation.ai_flag_exists?/2` plus per-subject Oban job uniqueness (`unique: [keys: [:subject_type, :subject_id], states: incomplete]`). There is no DB partial-unique index; the existing `unique_reporter_subject` index does not constrain AI flags because their `reporter_id` is `NULL` (NULLs are distinct in Postgres unique indexes).
- **Graceful degradation:** every Llama failure path (`{:error, :timeout}`, invalid JSON, crash, Ollama unreachable) results in no flag and either a retry (transient) or a silent discard (permanent). The content write is never rolled back by enqueue/detection.
- **Out of scope (next todo):** auto-actions (hold/shadow/escalate) with audit log; AI writing assistant.
- **Stub-based tests are `async: false`** because `AI.Client.Stub` is configured through global `Application` env. Follow the existing `embed_article_worker_test.exs` pattern.
