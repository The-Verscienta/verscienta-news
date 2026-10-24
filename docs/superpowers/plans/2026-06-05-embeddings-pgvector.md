# Embeddings + pgvector Foundation Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate a 768-dim `nomic-embed-text` embedding per published article, store it in Postgres via pgvector, keep it fresh on content changes, and expose a `Recommendations.similar/2` cosine-distance primitive.

**Architecture:** Switch the dev Postgres image to `pgvector/pgvector:pg16`; add an `:vector` column + HNSW index to `articles`; add an Ollama `/api/embeddings` client function; generate embeddings via an Oban worker triggered on publish/ingest/edit (mirroring the AI-enrichment pipeline); query neighbors with AshPostgres `vector_cosine_distance`. No new hex dependency (Ash's native `:vector` type).

**Tech Stack:** Elixir, Phoenix, Ash 3 / AshPostgres (native `:vector`), pgvector, Oban, FunWithFlags, Ollama. All `mix`/`docker compose` runs against the Dockerized stack: `docker compose exec -T app mix …`.

**Spec:** `docs/superpowers/specs/2026-06-05-embeddings-pgvector-design.md`
**Branch:** `phase-3-embeddings` (spec already committed here).

---

## File Structure

**Create:**
- `lib/verscienta/ai/workers/embed_article_worker.ex` — Oban worker that embeds one article.
- `lib/verscienta/content/article/changes/enqueue_embedding.ex` — after-action change enqueueing the worker.
- `lib/verscienta/recommendations/similar.ex` — `Verscienta.Recommendations.similar/2` neighbor query.
- `lib/mix/tasks/verscienta.embeddings.backfill.ex` — backfill task.
- `test/verscienta/ai/embed_article_test.exs`, `test/verscienta/ai/workers/embed_article_worker_test.exs`, `test/verscienta/content/article/enqueue_embedding_test.exs`, `test/verscienta/recommendations/similar_test.exs`
- `priv/repo/migrations/*_add_article_embedding_hnsw_index.exs` — manual HNSW index migration.

**Modify:**
- `docker-compose.yml` — `db` image → `pgvector/pgvector:pg16`.
- `lib/verscienta/repo.ex` — add `"vector"` to `installed_extensions/0`.
- `lib/verscienta/content/article.ex` — `:embedding` attribute, `:set_embedding` action, `embedding_distance` calc, `EnqueueEmbedding` wiring.
- `lib/verscienta/ai/client.ex` — `embed/2` callback + Req impl.
- `lib/verscienta/ai.ex` — `embed_article/1`.
- `test/support/ai_client_stub.ex` — `embed/2`.
- `lib/verscienta/flags.ex`, `lib/verscienta/flags/seeds.ex` — `:embeddings` flag.
- `config/runtime.exs` — `ollama_embed_model`.
- `README.md` / a runbook note + `docs/todo.md`.

---

## Task 1: Switch Postgres to a pgvector image

**Files:** Modify `docker-compose.yml`

- [ ] **Step 1: Edit the db image**

In `docker-compose.yml`, find the `db` service `image:` line (currently `postgres:16`) and change it to:

```yaml
    image: pgvector/pgvector:pg16
```

(Leave everything else — env, ports, volumes — unchanged. This image is the official `postgres:16` plus the `vector` extension; the existing data volume is compatible.)

- [ ] **Step 2: Recreate the db container with the new image**

Run (from the host, in the repo root):
```bash
docker compose pull db
docker compose up -d --force-recreate db
```
Wait for it to be healthy:
```bash
docker compose ps db
```
Expected: `db` shows `Up ... (healthy)`.

- [ ] **Step 3: Verify the vector extension is available**

```bash
docker compose exec -T db psql -U postgres -d verscienta_dev -c "CREATE EXTENSION IF NOT EXISTS vector; SELECT extname FROM pg_extension WHERE extname='vector';"
```
Expected: a row with `vector`. (This proves the image ships pgvector; the Ash migration in Task 2 installs it formally.)

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml
git commit -m "build(db): switch Postgres image to pgvector/pgvector:pg16"
```

---

## Task 2: Embedding column, extension, index, and `:set_embedding`

**Files:**
- Modify: `lib/verscienta/repo.ex`, `lib/verscienta/content/article.ex`
- Create: `priv/repo/migrations/*_add_article_embedding_hnsw_index.exs`
- Test: `test/verscienta/content/article/embedding_roundtrip_test.exs`

- [ ] **Step 1: Add the extension to the repo**

In `lib/verscienta/repo.ex`, change `installed_extensions/0`:
```elixir
  def installed_extensions do
    ["ash-functions", "citext", "vector"]
  end
```

- [ ] **Step 2: Add the attribute + action + calc to Article**

In `lib/verscienta/content/article.ex`:

(a) In the `attributes do` block, after the `:aggregated?` attribute and before `create_timestamp :inserted_at`, add:
```elixir
    attribute :embedding, :vector, allow_nil?: true, public?: false, constraints: [dimensions: 768]
```

(b) In the `actions do` block, add a new update action (place it after `:ai_enrich`):
```elixir
    update :set_embedding do
      description "System action: write the article's embedding vector. Worker-only."
      require_atomic? false
      accept [:embedding]
    end
```
(Deliberately has NO `EnqueueEmbedding`/`EnqueueIndex` changes, so writing the embedding can't re-trigger the worker — no loop.)

(c) Add a `calculations do` block (if the resource has none; otherwise add into it). Place it near the end of the resource body:
```elixir
  calculations do
    calculate :embedding_distance, :float, expr(vector_cosine_distance(embedding, ^arg(:to))) do
      argument :to, :vector, allow_nil?: false
    end
  end
```
(Used optionally; `similar/2` in Task 5 sorts via an inline `calc/2` — this named calc is a fallback. Ensure `import Ash.Expr` / `expr` is available in the resource — Ash resources have `expr` in scope.)

- [ ] **Step 3: Generate the column + extension migration**

```bash
docker compose exec -T app mix ash.codegen add_article_embedding
```
Then **inspect** the newest file in `priv/repo/migrations/`:
```bash
docker compose exec -T app bash -lc 'ls -t priv/repo/migrations/*.exs | head -1 | xargs cat'
```
Confirm it (a) installs the `vector` extension (`execute("CREATE EXTENSION IF NOT EXISTS \"vector\"")` — possibly in a separate `*_extensions_*` migration) and (b) adds the `embedding` column. **If the column type is bare `:vector` / `add :embedding, :vector` without a dimension**, edit it so the column is `vector(768)` — e.g.:
```elixir
    alter table(:articles) do
      add :embedding, :vector, size: 768
    end
```
(AshPostgres maps `size:` to `vector(768)`. If the generated line already encodes 768, leave it.)

- [ ] **Step 4: Add the HNSW index as a separate manual migration**

```bash
docker compose exec -T app mix ecto.gen.migration add_article_embedding_hnsw_index
```
Open the generated file and make it:
```elixir
defmodule Verscienta.Repo.Migrations.AddArticleEmbeddingHnswIndex do
  use Ecto.Migration

  # HNSW index for cosine-distance KNN. pgvector requires a fixed-dimension
  # column (vector(768)); NULL embeddings are skipped by the index.
  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS articles_embedding_hnsw_index
    ON articles USING hnsw (embedding vector_cosine_ops)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS articles_embedding_hnsw_index")
  end
end
```

- [ ] **Step 5: Migrate dev + test DBs**

```bash
docker compose exec -T app mix ash.migrate
docker compose exec -T -e MIX_ENV=test app mix ash.migrate
```
Expected: both succeed (extension + column + index created). If `ash.migrate` isn't defined, use `mix ecto.migrate` (and `MIX_ENV=test mix ecto.migrate`).

- [ ] **Step 6: Write a round-trip test**

Create `test/verscienta/content/article/embedding_roundtrip_test.exs`:
```elixir
defmodule Verscienta.Content.Article.EmbeddingRoundtripTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Content.Article

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

  test ":set_embedding stores and reads back a 768-dim vector" do
    author = user("embauthor")

    art =
      Article
      |> Ash.Changeset.for_create(:create, %{title: "T", excerpt: "e", category: :nutrition},
        actor: author
      )
      |> Ash.create!()

    vec = List.duplicate(0.1, 768)

    updated =
      art
      |> Ash.Changeset.for_update(:set_embedding, %{embedding: vec}, authorize?: false)
      |> Ash.update!()

    assert %Ash.Vector{dimensions: 768} = updated.embedding

    reloaded = Ash.get!(Article, art.id, authorize?: false)
    assert %Ash.Vector{dimensions: 768} = reloaded.embedding
  end
end
```

- [ ] **Step 7: Run the round-trip test**

```bash
docker compose exec -T app mix test test/verscienta/content/article/embedding_roundtrip_test.exs
```
Expected: PASS (1 test). If casting fails, confirm the attribute constraint `dimensions: 768` and that the list has exactly 768 elements.

- [ ] **Step 8: Commit**

```bash
git add lib/verscienta/repo.ex lib/verscienta/content/article.ex priv/repo/migrations test/verscienta/content/article/embedding_roundtrip_test.exs
git commit -m "feat(content): article embedding column (pgvector) + :set_embedding + HNSW index"
```

---

## Task 3: AI embedding client + `embed_article/1`

**Files:**
- Modify: `lib/verscienta/ai/client.ex`, `lib/verscienta/ai.ex`, `test/support/ai_client_stub.ex`, `config/runtime.exs`
- Test: `test/verscienta/ai/embed_article_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/ai/embed_article_test.exs`:
```elixir
defmodule Verscienta.AI.EmbedArticleTest do
  use ExUnit.Case, async: false

  alias Verscienta.AI
  alias Verscienta.AI.Client.Stub

  setup do
    prev = Application.get_env(:verscienta, :ai_client)
    Application.put_env(:verscienta, :ai_client, Stub)
    Stub.reset()
    on_exit(fn -> Application.put_env(:verscienta, :ai_client, prev) end)
    :ok
  end

  defp article(attrs) do
    Map.merge(
      %{title: "Magnesium Basics", excerpt: "A short primer.", blocks: []},
      attrs
    )
  end

  test "embed_article/1 sends prefixed title+excerpt+body and returns the vector" do
    Application.put_env(:verscienta, :ai_stub, %{embed: {:ok, List.duplicate(0.2, 768)}})

    blocks = [%{"type" => "paragraph", "data" => %{"text" => "Magnesium supports muscle function."}}]
    assert {:ok, vec} = AI.embed_article(article(%{blocks: blocks}))
    assert length(vec) == 768

    [{:embed, [text, _opts]}] = Stub.calls()
    assert String.starts_with?(text, "search_document: ")
    assert text =~ "Magnesium Basics"
    assert text =~ "A short primer."
    assert text =~ "Magnesium supports muscle function."
  end

  test "embed_article/1 truncates very long input" do
    Application.put_env(:verscienta, :ai_stub, %{embed: {:ok, List.duplicate(0.0, 768)}})
    long = String.duplicate("x", 20_000)
    blocks = [%{"type" => "paragraph", "data" => %{"text" => long}}]

    assert {:ok, _} = AI.embed_article(article(%{blocks: blocks}))
    [{:embed, [text, _]}] = Stub.calls()
    assert String.length(text) <= 6000
  end

  test "embed_article/1 passes client errors through" do
    Application.put_env(:verscienta, :ai_stub, %{embed: {:error, :boom}})
    assert {:error, :boom} = AI.embed_article(article(%{}))
  end
end
```

- [ ] **Step 2: Run it (fails — embed/2 undefined)**

```bash
docker compose exec -T app mix test test/verscienta/ai/embed_article_test.exs
```
Expected: FAIL.

- [ ] **Step 3: Add `embed/2` to the client**

In `lib/verscienta/ai/client.ex`, add the callback + dispatcher + Req impl. After the `generate` callback line add:
```elixir
  @callback embed(text :: String.t(), opts :: keyword) :: {:ok, [float()]} | {:error, term}
```
After `def generate(...)` add:
```elixir
  @doc "Embed `text` into a float vector via Ollama /api/embeddings."
  def embed(text, opts \\ []), do: impl().embed(text, opts)
```
Inside `defmodule Req do … end`, add:
```elixir
    @impl true
    def embed(text, opts) do
      url = base_url() <> "/api/embeddings"

      body = %{
        "model" => Keyword.get(opts, :model, embed_model()),
        "prompt" => text
      }

      case Elixir.Req.request(
             method: :post,
             url: url,
             json: body,
             receive_timeout: Keyword.get(opts, :receive_timeout, @receive_timeout)
           ) do
        {:ok, %{status: status, body: %{"embedding" => vec}}} when status in 200..299 ->
          {:ok, vec}

        {:ok, %{status: status, body: resp}} ->
          {:error, {:http_status, status, resp}}

        {:error, reason} ->
          {:error, reason}
      end
    end
```
And add near `defp model`:
```elixir
    defp embed_model, do: Application.fetch_env!(:verscienta, :ollama_embed_model)
```

- [ ] **Step 4: Add `embed/2` to the stub**

In `test/support/ai_client_stub.ex`, after the `generate/2` impl add:
```elixir
  @impl true
  def embed(text, opts), do: respond(:embed, [text, opts])
```

- [ ] **Step 5: Add the config default**

In `config/runtime.exs`, in the bottom `config :verscienta, redis_url: …, ollama_url: …, ollama_model: …` block, add a line:
```elixir
  ollama_embed_model: System.get_env("OLLAMA_EMBED_MODEL", "nomic-embed-text"),
```

- [ ] **Step 6: Implement `embed_article/1`**

In `lib/verscienta/ai.ex`, add (and ensure `alias Verscienta.Search.Document` exists — it's already used by `build_prompt`):
```elixir
  @embed_char_budget 6000

  @doc """
  Embed an article's text (title + excerpt + body) via the AI client. Prefixed
  with `search_document: ` (nomic convention) and truncated. Best-effort —
  returns `{:ok, vector}` | `{:error, reason}`, never raises.
  """
  def embed_article(article) do
    body = article.blocks |> Document.blocks_to_text() |> to_string()
    excerpt = to_string(article.excerpt || "")

    text =
      ("search_document: " <> article.title <> "\n" <> excerpt <> "\n" <> body)
      |> String.slice(0, @embed_char_budget)

    Verscienta.AI.Client.embed(text)
  end
```

- [ ] **Step 7: Run the test (passes)**

```bash
docker compose exec -T app mix test test/verscienta/ai/embed_article_test.exs
```
Expected: PASS (3 tests). Then `docker compose exec -T app mix format` and `docker compose exec -T app mix credo --strict lib/verscienta/ai/client.ex lib/verscienta/ai.ex`.

- [ ] **Step 8: Commit**

```bash
git add lib/verscienta/ai/client.ex lib/verscienta/ai.ex test/support/ai_client_stub.ex config/runtime.exs test/verscienta/ai/embed_article_test.exs
git commit -m "feat(ai): Ollama embeddings client + embed_article/1"
```

---

## Task 4: `:embeddings` flag, worker, enqueue trigger, backfill

**Files:**
- Modify: `lib/verscienta/flags.ex`, `lib/verscienta/flags/seeds.ex`, `lib/verscienta/content/article.ex`
- Create: `lib/verscienta/ai/workers/embed_article_worker.ex`, `lib/verscienta/content/article/changes/enqueue_embedding.ex`, `lib/mix/tasks/verscienta.embeddings.backfill.ex`
- Test: `test/verscienta/ai/workers/embed_article_worker_test.exs`, `test/verscienta/content/article/enqueue_embedding_test.exs`

- [ ] **Step 1: Register the `:embeddings` flag**

In `lib/verscienta/flags.ex`, add `embeddings` to the `@known_flags ~w(...)a` list. In `lib/verscienta/flags/seeds.ex`, add `embeddings` to `@retroactive_on ~w(...)a` and add `embeddings: "Article embeddings",` to the `@labels` map.

- [ ] **Step 2: Write the worker test (failing)**

Create `test/verscienta/ai/workers/embed_article_worker_test.exs`:
```elixir
defmodule Verscienta.AI.Workers.EmbedArticleWorkerTest do
  use Verscienta.DataCase, async: false

  alias Verscienta.AI.Client.Stub
  alias Verscienta.AI.Workers.EmbedArticleWorker
  alias Verscienta.Content.Article

  setup do
    prev = Application.get_env(:verscienta, :ai_client)
    Application.put_env(:verscienta, :ai_client, Stub)
    Stub.reset()
    Application.put_env(:verscienta, :ai_stub, %{embed: {:ok, List.duplicate(0.3, 768)}})
    Verscienta.Flags.enable(:embeddings)
    on_exit(fn -> Application.put_env(:verscienta, :ai_client, prev) end)
    :ok
  end

  defp published(author, title) do
    Article
    |> Ash.Changeset.for_create(:create, %{title: title, excerpt: "e", category: :nutrition},
      actor: author
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(:publish, %{}, actor: author)
    |> Ash.update!()
  end

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

  test "perform/1 stores the article's embedding" do
    art = published(user("embw1"), "Embed me")

    assert :ok = perform_job(EmbedArticleWorker, %{"article_id" => art.id})

    reloaded = Ash.get!(Article, art.id, authorize?: false)
    assert %Ash.Vector{dimensions: 768} = reloaded.embedding
  end

  test "perform/1 no-ops when the flag is disabled" do
    Verscienta.Flags.disable(:embeddings)
    art = published(user("embw2"), "No embed")

    assert :ok = perform_job(EmbedArticleWorker, %{"article_id" => art.id})
    assert is_nil(Ash.get!(Article, art.id, authorize?: false).embedding)
  end
end
```
(`perform_job/2` comes from `Oban.Testing`; the project already uses Oban testing — if `perform_job` isn't imported, add `use Oban.Testing, repo: Verscienta.Repo` to the test module.)

- [ ] **Step 3: Run it (fails — worker undefined)**

```bash
docker compose exec -T app mix test test/verscienta/ai/workers/embed_article_worker_test.exs
```
Expected: FAIL.

- [ ] **Step 4: Implement the worker**

Create `lib/verscienta/ai/workers/embed_article_worker.ex`:
```elixir
defmodule Verscienta.AI.Workers.EmbedArticleWorker do
  @moduledoc "Generates and stores an article's embedding. Best-effort, retryable."
  use Oban.Worker,
    queue: :ai,
    max_attempts: 3,
    unique: [
      keys: [:article_id],
      period: 60,
      states: Oban.Job.unique_states(:incomplete)
    ]

  alias Verscienta.AI
  alias Verscienta.Content.Article

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    if Verscienta.Flags.enabled?(:embeddings) do
      do_perform(job)
    else
      :ok
    end
  end

  defp do_perform(%Oban.Job{args: %{"article_id" => id}}) do
    case Ash.get(Article, id, authorize?: false) do
      {:ok, article} ->
        case AI.embed_article(article) do
          {:ok, vector} ->
            article
            |> Ash.Changeset.for_update(:set_embedding, %{embedding: vector}, authorize?: false)
            |> Ash.update!()

            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _} ->
        :ok
    end
  end
end
```

- [ ] **Step 5: Run the worker test (passes)**

```bash
docker compose exec -T app mix test test/verscienta/ai/workers/embed_article_worker_test.exs
```
Expected: PASS (2 tests).

- [ ] **Step 6: Write the enqueue test (failing)**

Create `test/verscienta/content/article/enqueue_embedding_test.exs`:
```elixir
defmodule Verscienta.Content.Article.EnqueueEmbeddingTest do
  use Verscienta.DataCase, async: false
  use Oban.Testing, repo: Verscienta.Repo

  alias Verscienta.AI.Workers.EmbedArticleWorker
  alias Verscienta.Content.Article

  setup do
    Verscienta.Flags.enable(:embeddings)
    :ok
  end

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

  test "publishing an article enqueues an embedding job" do
    author = user("enqemb1")

    art =
      Article
      |> Ash.Changeset.for_create(:create, %{title: "T", excerpt: "e", category: :nutrition},
        actor: author
      )
      |> Ash.create!()

    # creating a draft does NOT enqueue
    refute_enqueued(worker: EmbedArticleWorker)

    art |> Ash.Changeset.for_update(:publish, %{}, actor: author) |> Ash.update!()
    assert_enqueued(worker: EmbedArticleWorker, args: %{"article_id" => art.id})
  end
end
```

- [ ] **Step 7: Run it (fails — change not wired)**

```bash
docker compose exec -T app mix test test/verscienta/content/article/enqueue_embedding_test.exs
```
Expected: FAIL (`assert_enqueued` finds nothing).

- [ ] **Step 8: Implement the change + wire it**

Create `lib/verscienta/content/article/changes/enqueue_embedding.ex`:
```elixir
defmodule Verscienta.Content.Article.Changes.EnqueueEmbedding do
  @moduledoc "After-action: enqueue (re)embedding for a published article."
  use Ash.Resource.Change
  require Logger

  alias Verscienta.AI.Workers.EmbedArticleWorker

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      enqueue(record)
      {:ok, record}
    end)
  end

  # Only published articles get embeddings; an enqueue failure must never roll
  # back the article write.
  defp enqueue(%{status: :published} = record) do
    if Verscienta.Flags.enabled?(:embeddings) do
      %{"article_id" => record.id}
      |> EmbedArticleWorker.new()
      |> Oban.insert!()
    end

    :ok
  rescue
    error ->
      Logger.warning("Failed to enqueue embedding for article #{record.id}: #{inspect(error)}")
      :ok
  end

  defp enqueue(_record), do: :ok
end
```
In `lib/verscienta/content/article.ex`, add `change Verscienta.Content.Article.Changes.EnqueueEmbedding` to these actions: `:publish`, `:create_aggregated`, `:update`, `:ai_enrich` (alongside the existing `EnqueueEnrich`/`EnqueueIndex` changes). Do NOT add it to `:create` (drafts) or `:set_embedding`.

- [ ] **Step 9: Run the enqueue test (passes)**

```bash
docker compose exec -T app mix test test/verscienta/content/article/enqueue_embedding_test.exs
```
Expected: PASS (1 test).

- [ ] **Step 10: Backfill task**

Create `lib/mix/tasks/verscienta.embeddings.backfill.ex`:
```elixir
defmodule Mix.Tasks.Verscienta.Embeddings.Backfill do
  @shortdoc "Enqueue embedding jobs for published articles missing an embedding"
  @moduledoc """
  Enqueues `EmbedArticleWorker` for every published article whose embedding is
  nil. Run after deploying embeddings or pulling a new model.

      mix verscienta.embeddings.backfill
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    require Ash.Query

    ids =
      Verscienta.Content.Article
      |> Ash.Query.filter(status == :published and is_nil(embedding))
      |> Ash.Query.select([:id])
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.id)

    Enum.each(ids, fn id ->
      %{"article_id" => id}
      |> Verscienta.AI.Workers.EmbedArticleWorker.new()
      |> Oban.insert!()
    end)

    Mix.shell().info("Enqueued #{length(ids)} embedding job(s).")
  end
end
```

- [ ] **Step 11: format, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix credo --strict lib/verscienta/ai/workers/embed_article_worker.ex lib/verscienta/content/article/changes/enqueue_embedding.ex lib/mix/tasks/verscienta.embeddings.backfill.ex
git add lib/verscienta/flags.ex lib/verscienta/flags/seeds.ex lib/verscienta/content/article.ex lib/verscienta/ai/workers/embed_article_worker.ex lib/verscienta/content/article/changes/enqueue_embedding.ex lib/mix/tasks/verscienta.embeddings.backfill.ex test/verscienta/ai/workers/embed_article_worker_test.exs test/verscienta/content/article/enqueue_embedding_test.exs
git commit -m "feat(ai): embedding worker + enqueue trigger + backfill + :embeddings flag"
```

---

## Task 5: `Recommendations.similar/2`

**Files:**
- Create: `lib/verscienta/recommendations/similar.ex`
- Test: `test/verscienta/recommendations/similar_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/recommendations/similar_test.exs`:
```elixir
defmodule Verscienta.Recommendations.SimilarTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Content.Article
  alias Verscienta.Recommendations

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

  # 768-dim vector whose first elements are `head`, rest zeros.
  defp vec(head), do: head ++ List.duplicate(0.0, 768 - length(head))

  defp published_with_embedding(author, title, embedding) do
    Article
    |> Ash.Changeset.for_create(:create, %{title: title, excerpt: "e", category: :nutrition},
      actor: author
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(:publish, %{}, actor: author)
    |> Ash.update!()
    |> Ash.Changeset.for_update(:set_embedding, %{embedding: embedding}, authorize?: false)
    |> Ash.update!()
  end

  defp reload(art), do: Ash.get!(Article, art.id, authorize?: false)

  test "returns articles ordered by cosine similarity, nearest first, excluding self" do
    author = user("sim1")
    a = published_with_embedding(author, "Anchor", vec([1.0, 0.0, 0.0]))
    near = published_with_embedding(author, "Near", vec([0.95, 0.05, 0.0]))
    far = published_with_embedding(author, "Far", vec([0.0, 0.0, 1.0]))

    ids = Recommendations.similar(reload(a), limit: 10) |> Enum.map(& &1.id)

    refute a.id in ids
    assert near.id in ids
    assert far.id in ids
    assert Enum.find_index(ids, &(&1 == near.id)) < Enum.find_index(ids, &(&1 == far.id))
  end

  test "returns [] for an article with no embedding" do
    author = user("sim2")

    no_emb =
      Article
      |> Ash.Changeset.for_create(:create, %{title: "NoEmb", excerpt: "e", category: :nutrition},
        actor: author
      )
      |> Ash.create!()
      |> Ash.Changeset.for_update(:publish, %{}, actor: author)
      |> Ash.update!()

    assert Recommendations.similar(reload(no_emb), limit: 10) == []
  end

  test "excludes unpublished and deactivated-author articles" do
    author = user("sim3")
    deact = user("sim3deact")
    a = published_with_embedding(author, "Anchor", vec([1.0, 0.0, 0.0]))
    _hidden = published_with_embedding(deact, "Hidden", vec([0.99, 0.0, 0.0]))

    Ecto.Adapters.SQL.query!(
      Verscienta.Repo,
      "UPDATE users SET deactivated_at = NOW() WHERE id = $1",
      [Ecto.UUID.dump!(deact.id)]
    )

    ids = Recommendations.similar(reload(a), limit: 10) |> Enum.map(& &1.id)
    refute Enum.any?(ids, &(&1 == _hidden.id))
  end
end
```

- [ ] **Step 2: Run it (fails — similar/2 undefined)**

```bash
docker compose exec -T app mix test test/verscienta/recommendations/similar_test.exs
```
Expected: FAIL.

- [ ] **Step 3: Implement `similar/2`**

Create `lib/verscienta/recommendations/similar.ex`:
```elixir
defmodule Verscienta.Recommendations.Similar do
  @moduledoc """
  Semantic neighbors of an article by cosine distance over pgvector embeddings.
  Eligibility mirrors `:list_published`: published, non-group, non-deactivated /
  non-anonymized author, excluding the article itself and unembedded articles.
  """
  require Ash.Query
  import Ash.Expr

  alias Verscienta.Content.Article

  @doc "Top `opts[:limit]` (default 10) articles most similar to `article`."
  def similar(article, opts \\ [])
  def similar(%{embedding: nil}, _opts), do: []

  def similar(%{embedding: vec} = article, opts) do
    limit = Keyword.get(opts, :limit, 10)

    Article
    |> Ash.Query.filter(
      status == :published and is_nil(group_id) and
        is_nil(author.deactivated_at) and is_nil(author.anonymized_at) and
        id != ^article.id and not is_nil(embedding)
    )
    |> Ash.Query.sort([{calc(vector_cosine_distance(embedding, ^vec), type: :float), :asc}])
    |> Ash.Query.limit(limit)
    |> Ash.Query.load(:tags)
    |> Ash.read!(authorize?: false)
  end
end
```
Add a thin delegate so the public API is `Verscienta.Recommendations.similar/2` — in `lib/verscienta/recommendations.ex` add:
```elixir
  defdelegate similar(article, opts \\ []), to: Verscienta.Recommendations.Similar
```

- [ ] **Step 4: Run the test; adjust the sort syntax if needed**

```bash
docker compose exec -T app mix test test/verscienta/recommendations/similar_test.exs
```
Expected: PASS (3 tests).

**If the `Ash.Query.sort([{calc(...), :asc}])` line raises** (the inline-calc-in-sort shape can vary by Ash version), use the named calculation defined on the Article resource in Task 2 instead:
```elixir
    |> Ash.Query.sort([{:embedding_distance, {%{to: vec}, :asc}}])
```
If that also raises, fall back to a raw order: drop the `sort` line and replace `Ash.read!` with a two-step — query eligible ids via raw SQL ordered by `embedding <=> $1::vector` (pass `vec` as `"[" <> Enum.map_join(Ash.Vector.to_list(vec), ",", &to_string/1) <> "]"`), then load those ids via Ash preserving order. Pick the first form that makes the test pass; keep the others out of the committed code.

- [ ] **Step 5: format, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix credo --strict lib/verscienta/recommendations/similar.ex
git add lib/verscienta/recommendations/similar.ex lib/verscienta/recommendations.ex test/verscienta/recommendations/similar_test.exs
git commit -m "feat(recommendations): similar/2 cosine-distance neighbor query"
```

---

## Task 6: Docs + full verification

**Files:** Modify `README.md` (or a runbook), `docs/todo.md`

- [ ] **Step 1: Document the ops requirements**

In `README.md` (near the Docker/Ollama setup), add a short note:
```markdown
### Embeddings (pgvector + Ollama)

The `db` service uses `pgvector/pgvector:pg16` for vector search. Article
embeddings are generated by an Oban worker using Ollama — pull the model on the
Ollama host once:

    docker compose exec ollama ollama pull nomic-embed-text

Backfill existing articles: `mix verscienta.embeddings.backfill`. Production
Postgres must be pgvector-capable.
```

- [ ] **Step 2: Check off the todo item**

In `docs/todo.md`, under "### Recommendation & Personalization", change:
```markdown
- [ ] Embeddings via Ollama for semantic similarity (store in Postgres `pgvector`).
```
to:
```markdown
- [x] Embeddings via Ollama for semantic similarity (store in Postgres `pgvector`). *(nomic-embed-text 768d; Recommendations.similar/2; slice 2)*
```

- [ ] **Step 3: Full suite + credo + dialyzer**

```bash
docker compose exec -T app bash -lc 'mix format && mix format --check-formatted && mix test 2>&1 | tail -6'
docker compose exec -T app mix credo --strict 2>&1 | tail -4
docker compose exec -T app mix dialyzer 2>&1 | tail -8
```
Expected: full suite **0 failures**; credo "found no issues"; dialyzer "passed successfully". If any fail, fix before committing. (Dialyzer note: the new `:vector`-typed code + the `calc/2` sort are the most likely to surface a spec/typing issue — address any it reports.)

- [ ] **Step 4: Commit**

```bash
git add README.md docs/todo.md
git commit -m "docs: embeddings ops note + check off pgvector embeddings (slice 2)"
```

- [ ] **Step 5:** Confirm all gates green — branch ready to merge to `main` (operator decides merge timing).

---

## Notes for the implementer

- **Run order matters:** Task 1 (pgvector image) MUST precede Task 2 (migration uses the `vector` extension). Tasks 3-5 depend on Task 2's column.
- **Loadtest env:** Task 2's migrations should also be applied to the loadtest DB before any loadtest run (`MIX_ENV=loadtest mix ash.migrate`) — not required for the test suite, but note it if a loadtest is run.
- **No loop:** `:set_embedding` is intentionally free of `EnqueueEmbedding`/`EnqueueIndex` so the worker's write can't re-enqueue itself.
- **The one uncertain API** is the Ash inline-calc sort in Task 5 — the test is the oracle; use the first of the three forms that passes and delete the rest.
- **Stub embed default:** tests always set `:ai_stub %{embed: {:ok, <768-list>}}`; the worker/embed path is never exercised in tests without configuring it.
```
