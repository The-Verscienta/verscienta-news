# Search (Meilisearch) Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make published articles searchable via Meilisearch (typo-tolerant, faceted), kept in sync by Oban jobs, with a live `/search` LiveView and a Postgres fallback when Meili is down.

**Architecture:** A small `req`-based `Search.Client` (behaviour, stubbable) talks to Meili; `Search.Index` defines/sets up the `articles` index; `Search.Document` flattens an Article (incl. block→text) into a doc; an Ash after-action change enqueues `IndexArticleWorker` (upsert/delete) on article changes; `Search.search/2` queries Meili with facets and falls back to a Postgres ILIKE query; `SearchLive` renders live results + facets; boot setup + `mix verscienta.reindex` bootstrap the index.

**Tech Stack:** Phoenix 1.8, Ash 3, AshPostgres, Oban, req, Meilisearch v1.10, LiveView, Tailwind v4 + Codex components.

---

## Conventions for the executor

- **Run everything in Docker.** Mix in the app service: `docker compose run --rm -T app bash -lc "<cmd>"`. Start DB: `docker compose up -d db`. Generous timeouts. If "dependency not available", prefix `mix deps.get &&`. OOM(137) → split / `ERL_FLAGS="+S 2 +A 4"`.
- **No live Meili needed for tests** — every test stubs the client via `config :verscienta, :search_client, <stub>`. Do NOT start the meilisearch container for tests.
- **One task at a time, sequentially.** After each task run `git rev-parse --short HEAD` for the REAL sha. Never batch tasks or guess SHAs.
- **Branch:** `phase-1-search` (already checked out; spec committed as `3cd7d4c`).
- **Line endings:** `.gitattributes` eol=lf, autocrlf false — don't change. `mix format` before commit. No `.bak` files.
- **Test DB:** `config/test.exs` pins `verscienta_test` and Oban `testing: :manual`. Seeds contaminate global counts — scope new count asserts (filter by your own data), never global `Ash.read!` counts.
- **Git identity:** no local override. Commit body ends with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- **No DB migrations** in this subsystem (no new schema). Do NOT run `mix ash.codegen`.
- **Reuse patterns:** the aggregation `Verscienta.Aggregation.FeedClient` behaviour + `FeedClientStub` (in `test/support`) is the exact pattern for the search client stub; `Verscienta.Aggregation.Workers.FetchSourceWorker` is the Oban worker pattern; `Verscienta.Content.Article.Changes.*` are the change-module pattern; `Verscienta.Content.Category` (keys/select_options/accent) and CodexComponents (`kicker`, `headline`, `news_card`) for the UI; `lib/verscienta_web/live/article_feed_live.ex` `article_grid/1` is a card-grid reference.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `lib/verscienta/search.ex` | public API: `search/2` (+ Postgres fallback) |
| `lib/verscienta/search/client.ex` | behaviour + `req` impl (`Client.Req`); config dispatch |
| `lib/verscienta/search/index.ex` | `@index`, `settings/0`, `setup/0` |
| `lib/verscienta/search/document.ex` | `build/1`, `blocks_to_text/1` |
| `lib/verscienta/search/workers/index_article_worker.ex` | Oban worker (upsert/delete) |
| `lib/verscienta/search/setup.ex` | boot-time guarded `Index.setup/0` task |
| `lib/verscienta/content/article/changes/enqueue_index.ex` | after-action change → enqueue worker |
| `lib/verscienta/content/article.ex` | attach `EnqueueIndex` to actions |
| `lib/verscienta/application.ex` | add the boot setup child (skip in test) |
| `lib/mix/tasks/verscienta.reindex.ex` | `mix verscienta.reindex` |
| `config/config.exs` / `config/test.exs` | search client config + test stub |
| `lib/verscienta_web/live/search_live.ex` | `/search` LiveView |
| `lib/verscienta_web/router.ex` | `/search` route |
| `lib/verscienta_web/components/layouts/root.html.heex` | `search` nav link |
| `test/support/search_client_stub.ex` | recording/configurable stub |
| `test/verscienta/search/*_test.exs`, `test/verscienta_web/live/search_live_test.exs` | tests |

---

## Task 1: Search client behaviour + req impl + config + stub (compile gate)

**Files:**
- Create: `lib/verscienta/search/client.ex`, `test/support/search_client_stub.ex`
- Modify: `config/config.exs`, `config/test.exs`

- [ ] **Step 1: Create the client behaviour + req impl**

Create `lib/verscienta/search/client.ex`:
```elixir
defmodule Verscienta.Search.Client do
  @moduledoc "Behaviour + Req implementation for the Meilisearch HTTP API."

  @callback search(index :: String.t(), params :: map) :: {:ok, map} | {:error, term}
  @callback add_documents(index :: String.t(), docs :: [map]) :: {:ok, map} | {:error, term}
  @callback delete_document(index :: String.t(), id :: String.t()) :: {:ok, map} | {:error, term}
  @callback update_settings(index :: String.t(), settings :: map) :: {:ok, map} | {:error, term}
  @callback create_index(index :: String.t(), primary_key :: String.t()) :: {:ok, map} | {:error, term}

  def search(index, params), do: impl().search(index, params)
  def add_documents(index, docs), do: impl().add_documents(index, docs)
  def delete_document(index, id), do: impl().delete_document(index, id)
  def update_settings(index, settings), do: impl().update_settings(index, settings)
  def create_index(index, primary_key), do: impl().create_index(index, primary_key)

  defp impl, do: Application.get_env(:verscienta, :search_client, __MODULE__.Req)

  defmodule Req do
    @moduledoc false
    @behaviour Verscienta.Search.Client

    @impl true
    def search(index, params), do: post("/indexes/#{index}/search", params)

    @impl true
    def add_documents(index, docs), do: post("/indexes/#{index}/documents", docs)

    @impl true
    def delete_document(index, id), do: request(:delete, "/indexes/#{index}/documents/#{id}", nil)

    @impl true
    def update_settings(index, settings), do: patch("/indexes/#{index}/settings", settings)

    @impl true
    def create_index(index, primary_key),
      do: post("/indexes", %{"uid" => index, "primaryKey" => primary_key})

    defp post(path, body), do: request(:post, path, body)
    defp patch(path, body), do: request(:patch, path, body)

    defp request(method, path, body) do
      url = base_url() <> path

      opts =
        [method: method, url: url, headers: [{"authorization", "Bearer " <> api_key()}], receive_timeout: 5_000]
        |> maybe_put_body(body)

      case Elixir.Req.request(opts) do
        {:ok, %{status: status, body: resp}} when status in 200..299 -> {:ok, resp}
        {:ok, %{status: status, body: resp}} -> {:error, {:http_status, status, resp}}
        {:error, reason} -> {:error, reason}
      end
    end

    defp maybe_put_body(opts, nil), do: opts
    defp maybe_put_body(opts, body), do: Keyword.put(opts, :json, body)

    defp base_url, do: Application.fetch_env!(:verscienta, :meilisearch_url)
    defp api_key, do: Application.fetch_env!(:verscienta, :meilisearch_key)
  end
end
```
NOTE: `config :verscienta, meilisearch_url:/meilisearch_key:` are set in `config/runtime.exs` for dev/prod. For TEST, they may be unset → add them in Step 3 so `Client.Req` doesn't crash if ever (tests use the stub, but `fetch_env!` must not blow up at load). Verify Req's response body is auto-decoded JSON (it is, for `application/json`); if Meili returns a string body, decode with `Jason` — but tests stub this, so the Req path is exercised only in manual/dev.

- [ ] **Step 2: Create the test stub**

Create `test/support/search_client_stub.ex`:
```elixir
defmodule Verscienta.Search.ClientStub do
  @moduledoc """
  Configurable, recording test double for Verscienta.Search.Client.

  Configure responses + record calls via the application env:
    Application.put_env(:verscienta, :search_stub, %{
      search: {:ok, %{"hits" => [...], "facetDistribution" => %{...}, "estimatedTotalHits" => n}},
      add_documents: {:ok, %{}},
      delete_document: {:ok, %{}},
      update_settings: {:ok, %{}},
      create_index: {:ok, %{}}
    })
  Calls are recorded under :search_stub_calls (a list of {fun, args}).
  """
  @behaviour Verscienta.Search.Client

  @impl true
  def search(index, params), do: respond(:search, [index, params])
  @impl true
  def add_documents(index, docs), do: respond(:add_documents, [index, docs])
  @impl true
  def delete_document(index, id), do: respond(:delete_document, [index, id])
  @impl true
  def update_settings(index, settings), do: respond(:update_settings, [index, settings])
  @impl true
  def create_index(index, pk), do: respond(:create_index, [index, pk])

  defp respond(fun, args) do
    record(fun, args)
    stub = Application.get_env(:verscienta, :search_stub, %{})
    Map.get(stub, fun, {:ok, %{}})
  end

  defp record(fun, args) do
    calls = Application.get_env(:verscienta, :search_stub_calls, [])
    Application.put_env(:verscienta, :search_stub_calls, calls ++ [{fun, args}])
  end

  @doc "Test helper: recorded calls."
  def calls, do: Application.get_env(:verscienta, :search_stub_calls, [])

  @doc "Test helper: reset stub state."
  def reset do
    Application.delete_env(:verscienta, :search_stub)
    Application.put_env(:verscienta, :search_stub_calls, [])
  end
end
```

- [ ] **Step 3: Configure the client**

In `config/config.exs` (after existing config), add a base value for the meili keys so `fetch_env!` is safe at compile/boot in all envs, and default the client to the Req impl:
```elixir
config :verscienta,
  meilisearch_url: "http://localhost:7700",
  meilisearch_key: "masterKey",
  search_client: Verscienta.Search.Client.Req
```
NOTE: `config/runtime.exs` already overrides `meilisearch_url`/`meilisearch_key` from env at runtime for dev/prod — keep those. This compile-time default just prevents `fetch_env!` from raising before runtime config loads. If a `config :verscienta, ...` block already sets unrelated keys, MERGE these keys in rather than duplicating the block.

In `config/test.exs`, point the client at the stub:
```elixir
config :verscienta, search_client: Verscienta.Search.ClientStub
```

- [ ] **Step 4: Compile**

```powershell
docker compose run --rm -T app bash -lc "mix deps.get && mix compile --warnings-as-errors"
```
Expected: compiles (no new deps needed; `req` already present). `test/support` compiles in test env.

- [ ] **Step 5: Format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix credo --strict"
git add -A
git commit -m "feat(search): Meili client behaviour, req impl, and test stub"
```
Then `git rev-parse --short HEAD`.

---

## Task 2: Document builder + blocks_to_text (TDD)

**Files:**
- Create: `lib/verscienta/search/document.ex`
- Test: `test/verscienta/search/document_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/verscienta/search/document_test.exs`:
```elixir
defmodule Verscienta.Search.DocumentTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Search.Document

  defp author do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: "doc_author@example.com",
      username: "docauthor",
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp published_article do
    a = author()

    {:ok, article} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Adaptogens Explained",
          excerpt: "A short summary",
          blocks: [
            %{"type" => "heading", "data" => %{"text" => "What Are Adaptogens", "level" => 2}},
            %{"type" => "paragraph", "data" => %{"text" => "Herbs that help with stress."}},
            %{"type" => "markdown", "data" => %{"source" => "Some **markdown** prose."}},
            %{"type" => "list", "data" => %{"style" => "bullet", "items" => ["ashwagandha", "rhodiola"]}},
            %{"type" => "divider", "data" => %{}}
          ],
          category: :herbalism,
          tags: ["herbs", "stress"]
        },
        actor: a
      )
      |> Ash.create()

    {:ok, published} = article |> Ash.Changeset.for_update(:publish, %{}, actor: a) |> Ash.update()
    Ash.load!(published, [:tags], authorize?: false)
  end

  test "blocks_to_text extracts plain text from supported blocks; skips divider/image/embed" do
    blocks = [
      %{"type" => "heading", "data" => %{"text" => "Title"}},
      %{"type" => "paragraph", "data" => %{"text" => "Para."}},
      %{"type" => "blockquote", "data" => %{"text" => "Quote."}},
      %{"type" => "code", "data" => %{"text" => "x = 1"}},
      %{"type" => "markdown", "data" => %{"source" => "MD source"}},
      %{"type" => "callout", "data" => %{"variant" => "info", "text" => "Callout."}},
      %{"type" => "list", "data" => %{"style" => "bullet", "items" => ["a", "b"]}},
      %{"type" => "divider", "data" => %{}},
      %{"type" => "image", "data" => %{"url" => "x", "alt" => "ALT", "caption" => "CAP"}},
      %{"type" => "embed", "data" => %{"url" => "y", "provider" => "link"}}
    ]

    text = Document.blocks_to_text(blocks)
    assert text =~ "Title"
    assert text =~ "Para."
    assert text =~ "Quote."
    assert text =~ "x = 1"
    assert text =~ "MD source"
    assert text =~ "Callout."
    assert text =~ "a"
    assert text =~ "b"
    # image/embed/divider contribute no body text
    refute text =~ "ALT"
    refute text =~ "link"
  end

  test "blocks_to_text tolerates empty/nil" do
    assert Document.blocks_to_text([]) == ""
    assert Document.blocks_to_text(nil) == ""
  end

  test "build/1 produces a flat searchable document" do
    article = published_article()
    doc = Document.build(article)

    assert doc["id"] == article.id
    assert doc["title"] == "Adaptogens Explained"
    assert doc["excerpt"] == "A short summary"
    assert doc["body_text"] =~ "What Are Adaptogens"
    assert doc["body_text"] =~ "ashwagandha"
    assert doc["category"] == "herbalism"
    assert doc["aggregated"] == false
    assert doc["slug"] == article.slug
    assert is_integer(doc["published_at"])
    assert Enum.sort(doc["tags"]) == ["herbs", "stress"]
    assert "herbs" in doc["tag_slugs"]
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta/search/document_test.exs"
```
Expected: fails — module missing.

- [ ] **Step 3: Implement the document builder**

Create `lib/verscienta/search/document.ex`:
```elixir
defmodule Verscienta.Search.Document do
  @moduledoc "Flattens an Article into a Meilisearch document (plain-text body for indexing)."

  @doc "Build the search document for a (tags-loaded) published Article."
  def build(article) do
    tags = article.tags || []

    %{
      "id" => article.id,
      "title" => article.title,
      "excerpt" => article.excerpt || "",
      "body_text" => blocks_to_text(article.blocks),
      "tags" => Enum.map(tags, &to_string(&1.name)),
      "tag_slugs" => Enum.map(tags, & &1.slug),
      "category" => to_string(article.category),
      "aggregated" => article.aggregated?,
      "published_at" => DateTime.to_unix(article.published_at || DateTime.utc_now()),
      "slug" => article.slug
    }
  end

  @doc "Extract plain text from a block tree for indexing."
  def blocks_to_text(nil), do: ""
  def blocks_to_text([]), do: ""

  def blocks_to_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(&block_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp block_text(%{"type" => t, "data" => %{"text" => text}})
       when t in ~w(paragraph heading blockquote code callout),
       do: to_string(text)

  defp block_text(%{"type" => "markdown", "data" => %{"source" => source}}), do: to_string(source)

  defp block_text(%{"type" => "list", "data" => %{"items" => items}}) when is_list(items),
    do: Enum.join(items, "\n")

  defp block_text(_), do: ""
end
```

- [ ] **Step 4: Run to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/search/document_test.exs"
```
Expected: all pass.

- [ ] **Step 5: Format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix credo --strict"
git add -A
git commit -m "feat(search): document builder and blocks_to_text"
```
Then `git rev-parse --short HEAD`.

---

## Task 3: Index settings + setup (TDD)

**Files:**
- Create: `lib/verscienta/search/index.ex`
- Test: `test/verscienta/search/index_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/verscienta/search/index_test.exs`:
```elixir
defmodule Verscienta.Search.IndexTest do
  use ExUnit.Case, async: false

  alias Verscienta.Search.ClientStub
  alias Verscienta.Search.Index

  setup do
    ClientStub.reset()
    on_exit(&ClientStub.reset/0)
  end

  test "name/0 and settings/0 shape" do
    assert Index.name() == "articles"
    s = Index.settings()
    assert "title" in s["searchableAttributes"]
    assert "body_text" in s["searchableAttributes"]
    assert "tags" in s["searchableAttributes"]
    assert "category" in s["filterableAttributes"]
    assert "tag_slugs" in s["filterableAttributes"]
    assert "aggregated" in s["filterableAttributes"]
    assert "published_at" in s["sortableAttributes"]
  end

  test "setup/0 creates the index and applies settings (stub :ok)" do
    Application.put_env(:verscienta, :search_stub, %{
      create_index: {:ok, %{}},
      update_settings: {:ok, %{}}
    })

    assert Index.setup() == :ok

    funs = ClientStub.calls() |> Enum.map(&elem(&1, 0))
    assert :create_index in funs
    assert :update_settings in funs
  end

  test "setup/0 does not raise and returns {:error, _} when client errors" do
    Application.put_env(:verscienta, :search_stub, %{
      create_index: {:error, :boom},
      update_settings: {:error, :boom}
    })

    assert {:error, _} = Index.setup()
  end

  test "setup/0 treats an already-exists create as success and still applies settings" do
    Application.put_env(:verscienta, :search_stub, %{
      create_index: {:error, {:http_status, 409, %{}}},
      update_settings: {:ok, %{}}
    })

    assert Index.setup() == :ok
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/search/index_test.exs"
```
Expected: fails — module missing.

- [ ] **Step 3: Implement the index module**

Create `lib/verscienta/search/index.ex`:
```elixir
defmodule Verscienta.Search.Index do
  @moduledoc "Defines the Meilisearch articles index and its settings."

  alias Verscienta.Search.Client

  @index "articles"

  def name, do: @index

  def settings do
    %{
      "searchableAttributes" => ["title", "excerpt", "body_text", "tags"],
      "filterableAttributes" => ["category", "tag_slugs", "aggregated"],
      "sortableAttributes" => ["published_at"]
    }
  end

  @doc "Idempotently create the index and apply settings. Never raises."
  def setup do
    with :ok <- ensure_index(),
         {:ok, _} <- Client.update_settings(@index, settings()) do
      :ok
    end
  end

  defp ensure_index do
    case Client.create_index(@index, "id") do
      {:ok, _} -> :ok
      # 409 = already exists; treat as success.
      {:error, {:http_status, 409, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
```
NOTE: `setup/0` returns `:ok` only when settings applied (or index already existed + settings applied). When `ensure_index` errors with a non-409 the `with` short-circuits to `{:error, reason}`. The "already-exists" test relies on the 409 clause. If Meili returns a different shape for "index exists" in v1.10 (it may return `{:ok, task}` even for existing, or a different error), the boot guard (Task 7) swallows errors anyway; the stub tests are the gate here.

- [ ] **Step 4: Run to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/search/index_test.exs"
```
Expected: all pass.

- [ ] **Step 5: Format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix credo --strict"
git add -A
git commit -m "feat(search): articles index settings and idempotent setup"
```
Then `git rev-parse --short HEAD`.

---

## Task 4: Index worker + Article enqueue change (TDD)

**Files:**
- Create: `lib/verscienta/search/workers/index_article_worker.ex`
- Create: `lib/verscienta/content/article/changes/enqueue_index.ex`
- Modify: `lib/verscienta/content/article.ex`
- Test: `test/verscienta/search/index_sync_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/verscienta/search/index_sync_test.exs`:
```elixir
defmodule Verscienta.Search.IndexSyncTest do
  use Verscienta.DataCase, async: false
  use Oban.Testing, repo: Verscienta.Repo

  alias Verscienta.Search.ClientStub
  alias Verscienta.Search.Workers.IndexArticleWorker

  setup do
    ClientStub.reset()
    on_exit(&ClientStub.reset/0)
  end

  defp author do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: "sync_author@example.com",
      username: "syncauthor",
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_article(a) do
    {:ok, article} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: "Sync Me", blocks: [], category: :movement}, actor: a)
      |> Ash.create()

    article
  end

  test "publishing enqueues an upsert job" do
    a = author()
    article = create_article(a)
    {:ok, _} = article |> Ash.Changeset.for_update(:publish, %{}, actor: a) |> Ash.update()

    assert_enqueued(worker: IndexArticleWorker, args: %{"article_id" => article.id, "op" => "upsert"})
  end

  test "archiving enqueues a delete job" do
    a = author()
    article = create_article(a)
    {:ok, published} = article |> Ash.Changeset.for_update(:publish, %{}, actor: a) |> Ash.update()
    {:ok, _} = published |> Ash.Changeset.for_update(:archive, %{}, actor: a) |> Ash.update()

    assert_enqueued(worker: IndexArticleWorker, args: %{"article_id" => article.id, "op" => "delete"})
  end

  test "worker upsert calls add_documents with the built doc" do
    a = author()
    article = create_article(a)
    {:ok, _} = article |> Ash.Changeset.for_update(:publish, %{}, actor: a) |> Ash.update()

    assert :ok = perform_job(IndexArticleWorker, %{"article_id" => article.id, "op" => "upsert"})

    calls = ClientStub.calls()
    assert Enum.any?(calls, fn {fun, [index, docs]} ->
             fun == :add_documents and index == "articles" and
               match?([%{"id" => _, "title" => "Sync Me"}], docs)
           end)
  end

  test "worker delete calls delete_document" do
    a = author()
    article = create_article(a)

    assert :ok = perform_job(IndexArticleWorker, %{"article_id" => article.id, "op" => "delete"})

    calls = ClientStub.calls()
    assert Enum.any?(calls, fn {fun, [index, id]} ->
             fun == :delete_document and index == "articles" and id == article.id
           end)
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta/search/index_sync_test.exs"
```
Expected: fails — worker/change missing.

- [ ] **Step 3: Create the worker**

Create `lib/verscienta/search/workers/index_article_worker.ex`:
```elixir
defmodule Verscienta.Search.Workers.IndexArticleWorker do
  @moduledoc "Upserts or deletes an article's Meilisearch document."
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [keys: [:article_id], period: 60, states: [:available, :scheduled, :executing, :retryable]]

  require Ash.Query

  alias Verscienta.Search.Client
  alias Verscienta.Search.Document
  alias Verscienta.Search.Index

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"article_id" => id, "op" => "delete"}}) do
    case Client.delete_document(Index.name(), id) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{args: %{"article_id" => id, "op" => "upsert"}}) do
    case load_article(id) do
      nil ->
        # Gone or no longer published — ensure it's not in the index.
        _ = Client.delete_document(Index.name(), id)
        :ok

      article ->
        doc = Document.build(article)

        case Client.add_documents(Index.name(), [doc]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp load_article(id) do
    Verscienta.Content.Article
    |> Ash.Query.filter(id == ^id and status == :published)
    |> Ash.Query.load([:tags])
    |> Ash.read_one!(authorize?: false)
  end
end
```

- [ ] **Step 4: Create the enqueue change**

Create `lib/verscienta/content/article/changes/enqueue_index.ex`:
```elixir
defmodule Verscienta.Content.Article.Changes.EnqueueIndex do
  @moduledoc "After-action: enqueue a search index upsert/delete for the article."
  use Ash.Resource.Change

  alias Verscienta.Search.Workers.IndexArticleWorker

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      op = if record.status == :published, do: "upsert", else: "delete"

      %{"article_id" => record.id, "op" => op}
      |> IndexArticleWorker.new()
      |> Oban.insert!()

      {:ok, record}
    end)
  end
end
```

- [ ] **Step 5: Attach the change to Article actions**

In `lib/verscienta/content/article.ex`, add `change Verscienta.Content.Article.Changes.EnqueueIndex` to the END of the change list in each of these actions: `:create`, `:update`, `:publish`, `:archive`, `:create_aggregated`. Example for `:publish` (add the last line):
```elixir
    update :publish do
      description "Publish, stamping published_at on first publish."
      accept []
      require_atomic? false
      change set_attribute(:status, :published)

      change fn changeset, _ ->
        case Ash.Changeset.get_attribute(changeset, :published_at) do
          nil -> Ash.Changeset.force_change_attribute(changeset, :published_at, DateTime.utc_now())
          _ -> changeset
        end
      end

      change Verscienta.Content.Article.Changes.EnqueueIndex
    end
```
Do the same (append the `change ...EnqueueIndex` line) inside `:create`, `:update`, `:archive`, and `:create_aggregated`. All these actions are already `require_atomic? false` or are creates, so the after-action hook is fine.

- [ ] **Step 6: Run the tests to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/search/index_sync_test.exs"
```
Expected: all pass. NOTE: `assert_enqueued` works because Oban `testing: :manual` records jobs without running them; `perform_job` runs the worker directly with the stub client.

- [ ] **Step 7: Regression — full suite**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test"
```
Expected: everything passes (the new after-action enqueues a job in tests but Oban manual mode doesn't execute it, so existing article/editor/aggregation tests are unaffected). If any test now fails because it asserts "no jobs enqueued" or a global Oban count, scope it — but none should. Report the count.

- [ ] **Step 8: Format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix credo --strict"
git add -A
git commit -m "feat(search): index sync worker + article enqueue-on-change"
```
Then `git rev-parse --short HEAD`.

---

## Task 5: Search service + Postgres fallback (TDD)

**Files:**
- Create: `lib/verscienta/search.ex`
- Test: `test/verscienta/search/search_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/verscienta/search/search_test.exs`:
```elixir
defmodule Verscienta.SearchTest do
  use Verscienta.DataCase, async: false

  alias Verscienta.Search
  alias Verscienta.Search.ClientStub

  setup do
    ClientStub.reset()
    on_exit(&ClientStub.reset/0)
  end

  defp author do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: "search_author@example.com",
      username: "searchauthor",
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp publish(a, title, category) do
    {:ok, article} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: title, blocks: [], category: category}, actor: a)
      |> Ash.create()

    {:ok, p} = article |> Ash.Changeset.for_update(:publish, %{}, actor: a) |> Ash.update()
    p
  end

  test "meili path returns mapped hits, facets, total, source: :meili" do
    Application.put_env(:verscienta, :search_stub, %{
      search:
        {:ok,
         %{
           "hits" => [%{"id" => "1", "title" => "Hit One", "slug" => "hit-one", "category" => "herbalism"}],
           "facetDistribution" => %{"category" => %{"herbalism" => 1}, "tag_slugs" => %{}},
           "estimatedTotalHits" => 1
         }}
    })

    result = Search.search("adaptogen", category: :herbalism, tags: ["herbs"], page: 1)

    assert result.source == :meili
    assert result.total == 1
    assert [%{"title" => "Hit One"}] = result.hits
    assert result.facets["category"]["herbalism"] == 1

    # the meili params carried the filter
    [{:search, [_index, params]}] = Enum.filter(ClientStub.calls(), &(elem(&1, 0) == :search))
    assert params["q"] == "adaptogen"
    assert is_list(params["filter"]) or is_binary(params["filter"])
    assert to_string(params["filter"]) =~ "herbalism"
  end

  test "falls back to postgres on client error" do
    a = author()
    _ = publish(a, "Postgres Findable Title", :nutrition)
    Application.put_env(:verscienta, :search_stub, %{search: {:error, :down}})

    result = Search.search("Findable")

    assert result.source == :postgres
    assert Enum.any?(result.hits, &(&1["title"] =~ "Findable"))
    assert result.facets == %{}
  end

  test "postgres fallback excludes drafts" do
    a = author()

    {:ok, _draft} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: "Secret Draft Findable", blocks: [], category: :nutrition}, actor: a)
      |> Ash.create()

    Application.put_env(:verscienta, :search_stub, %{search: {:error, :down}})

    result = Search.search("Findable")
    refute Enum.any?(result.hits, &(&1["title"] =~ "Secret Draft"))
  end

  test "postgres fallback with blank query returns latest published" do
    a = author()
    _ = publish(a, "Latest Published Piece", :movement)
    Application.put_env(:verscienta, :search_stub, %{search: {:error, :down}})

    result = Search.search("")
    assert result.source == :postgres
    assert Enum.any?(result.hits, &(&1["title"] == "Latest Published Piece"))
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta/search/search_test.exs"
```
Expected: fails — module missing.

- [ ] **Step 3: Implement the search service**

Create `lib/verscienta/search.ex`:
```elixir
defmodule Verscienta.Search do
  @moduledoc "Search published articles via Meilisearch, with a Postgres fallback."

  require Ash.Query

  alias Verscienta.Search.Client
  alias Verscienta.Search.Index

  @per_page 20

  @doc """
  Search published articles. opts: :category (atom|nil), :tags (list of slugs),
  :page (1-based), :per_page. Returns
  %{hits: [map], facets: map, total: integer, page: integer, source: :meili | :postgres}.
  """
  def search(query, opts \\ []) do
    page = max(opts[:page] || 1, 1)
    per_page = opts[:per_page] || @per_page
    category = opts[:category]
    tags = opts[:tags] || []

    params = %{
      "q" => query || "",
      "filter" => build_filter(category, tags),
      "facets" => ["category", "tag_slugs"],
      "limit" => per_page,
      "offset" => (page - 1) * per_page
    }

    case Client.search(Index.name(), params) do
      {:ok, resp} ->
        %{
          hits: resp["hits"] || [],
          facets: resp["facetDistribution"] || %{},
          total: resp["estimatedTotalHits"] || length(resp["hits"] || []),
          page: page,
          source: :meili
        }

      {:error, _reason} ->
        fallback(query, category, page, per_page)
    end
  end

  defp build_filter(category, tags) do
    cat_filter = if category, do: ["category = #{to_string(category)}"], else: []
    tag_filter = Enum.map(tags, fn slug -> "tag_slugs = #{slug}" end)
    cat_filter ++ tag_filter
  end

  defp fallback(query, category, page, per_page) do
    q = String.trim(query || "")

    base =
      Verscienta.Content.Article
      |> Ash.Query.filter(status == :published)
      |> maybe_filter_category(category)
      |> maybe_filter_text(q)
      |> Ash.Query.sort(published_at: :desc)
      |> Ash.Query.limit(per_page)
      |> Ash.Query.offset((page - 1) * per_page)

    articles = Ash.read!(base, authorize?: false)

    %{
      hits: Enum.map(articles, &to_hit/1),
      facets: %{},
      total: length(articles),
      page: page,
      source: :postgres
    }
  end

  defp maybe_filter_category(query, nil), do: query
  defp maybe_filter_category(query, category), do: Ash.Query.filter(query, category == ^category)

  defp maybe_filter_text(query, ""), do: query

  defp maybe_filter_text(query, q) do
    like = "%#{q}%"
    Ash.Query.filter(query, ilike(title, ^like) or ilike(excerpt, ^like))
  end

  defp to_hit(article) do
    %{
      "id" => article.id,
      "title" => article.title,
      "excerpt" => article.excerpt || "",
      "slug" => article.slug,
      "category" => to_string(article.category)
    }
  end
end
```
NOTE on the Meili filter format: Meili accepts `filter` as either a string or an array of AND-ed conditions; an array of `"attr = value"` strings AND-es them. For OR across multiple tags you'd nest arrays, but for MVP AND-ing category + each tag is acceptable (narrowing). The test only asserts the filter mentions the category. If `ilike/2` isn't available in Ash expr for this version, use `contains(title, ^q)` or `fragment`; the gate is the fallback tests (Findable matches, drafts excluded, blank returns latest). Adjust and report.

- [ ] **Step 4: Run the tests to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/search/search_test.exs"
```
Expected: all pass. Adjust the ILIKE expression per the NOTE if needed.

- [ ] **Step 5: Format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix credo --strict"
git add -A
git commit -m "feat(search): search service with facets and Postgres fallback"
```
Then `git rev-parse --short HEAD`.

---

## Task 6: Search LiveView + nav (TDD)

**Files:**
- Create: `lib/verscienta_web/live/search_live.ex`
- Modify: `lib/verscienta_web/router.ex`, `lib/verscienta_web/components/layouts/root.html.heex`
- Test: `test/verscienta_web/live/search_live_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/search_live_test.exs`:
```elixir
defmodule VerscientaWeb.SearchLiveTest do
  use VerscientaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Verscienta.Search.ClientStub

  setup do
    ClientStub.reset()
    on_exit(&ClientStub.reset/0)
  end

  test "renders the search page", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/search")
    assert html =~ "search"
  end

  test "typing a query shows meili hits", %{conn: conn} do
    Application.put_env(:verscienta, :search_stub, %{
      search:
        {:ok,
         %{
           "hits" => [%{"id" => "1", "title" => "Adaptogen Guide", "slug" => "adaptogen-guide", "excerpt" => "x", "category" => "herbalism"}],
           "facetDistribution" => %{"category" => %{"herbalism" => 1}, "tag_slugs" => %{}},
           "estimatedTotalHits" => 1
         }}
    })

    {:ok, lv, _html} = live(conn, ~p"/search")
    html = lv |> form("#search-form", %{"q" => "adapto"}) |> render_change()
    assert html =~ "Adaptogen Guide"
  end

  test "shows fallback note when source is postgres", %{conn: conn} do
    Application.put_env(:verscienta, :search_stub, %{search: {:error, :down}})

    {:ok, lv, _html} = live(conn, ~p"/search")
    html = lv |> form("#search-form", %{"q" => "anything"}) |> render_change()
    assert html =~ "limited results" or html =~ "unavailable"
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta_web/live/search_live_test.exs"
```
Expected: fails — route + LiveView missing.

- [ ] **Step 3: Create the SearchLive**

Create `lib/verscienta_web/live/search_live.ex`:
```elixir
defmodule VerscientaWeb.SearchLive do
  @moduledoc "Live search over published articles, with category/tag facets."
  use VerscientaWeb, :live_view

  import VerscientaWeb.CodexComponents

  alias Verscienta.Content.Category
  alias Verscienta.Search

  on_mount {VerscientaWeb.LiveUserAuth, :live_user_optional}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "search", query: "", category: nil, results: empty_results())}
  end

  @impl true
  def handle_event("search", params, socket) do
    query = params["q"] || ""
    category = parse_category(params["category"] || (socket.assigns.category && to_string(socket.assigns.category)))

    results = Search.search(query, category: category, page: 1)

    {:noreply, assign(socket, query: query, category: category, results: results)}
  end

  def handle_event("toggle_category", %{"category" => cat}, socket) do
    key = parse_category(cat)
    new_cat = if socket.assigns.category == key, do: nil, else: key
    results = Search.search(socket.assigns.query, category: new_cat, page: 1)
    {:noreply, assign(socket, category: new_cat, results: results)}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, assign(socket, category: nil, results: Search.search(socket.assigns.query, page: 1))}
  end

  defp parse_category(nil), do: nil
  defp parse_category(""), do: nil

  defp parse_category(str) do
    key = String.to_existing_atom(str)
    if key in Category.keys(), do: key, else: nil
  rescue
    ArgumentError -> nil
  end

  defp empty_results, do: %{hits: [], facets: %{}, total: 0, page: 1, source: :meili}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-6 pb-24 pt-28">
      <.kicker>find</.kicker>
      <.headline class="mb-8 text-6xl">search</.headline>

      <form id="search-form" phx-change="search" phx-submit="search" class="mb-6">
        <input
          type="text"
          name="q"
          value={@query}
          placeholder="search articles…"
          phx-debounce="250"
          autocomplete="off"
          class="w-full border border-line bg-canvas-2 px-4 py-3 text-lg text-ink"
        />
      </form>

      <div class="mb-8 flex flex-wrap gap-2">
        <button
          :for={cat <- Category.all()}
          type="button"
          phx-click="toggle_category"
          phx-value-category={cat.key}
          class={[
            "border px-3 py-1.5 text-[11px] uppercase tracking-wider transition-colors",
            if(@category == cat.key,
              do: "border-zune text-zune",
              else: "border-line text-ink-3 hover:text-ink")
          ]}
        >
          {cat.label}
          <span :if={facet_count(@results, cat) > 0} class="ml-1 text-ink-3">
            {facet_count(@results, cat)}
          </span>
        </button>
        <button
          :if={@category}
          type="button"
          phx-click="clear"
          class="px-3 py-1.5 text-[11px] uppercase tracking-wider text-politics"
        >
          clear
        </button>
      </div>

      <p :if={@results.source == :postgres} class="mb-6 text-xs text-ink-3">
        limited results — search service unavailable
      </p>

      <p class="mb-4 text-[11px] uppercase tracking-widest text-ink-3">
        {@results.total} result{if @results.total == 1, do: "", else: "s"}
      </p>

      <div :if={@results.hits == []} class="text-ink-3">No results.</div>
      <div class="grid gap-7 sm:grid-cols-2 lg:grid-cols-3">
        <a :for={hit <- @results.hits} href={"/articles/" <> hit["slug"]} class="block">
          <.news_card
            category={category_label(hit["category"])}
            accent={Category.accent(safe_key(hit["category"]))}
            meta=""
          >
            {hit["title"]}
          </.news_card>
        </a>
      </div>
    </div>
    """
  end

  defp facet_count(%{facets: facets}, cat) do
    get_in(facets, ["category", to_string(cat.key)]) || 0
  end

  defp category_label(slug_or_key) do
    key = safe_key(slug_or_key)
    case Category.get(key) do
      nil -> to_string(slug_or_key)
      cat -> cat.label
    end
  end

  defp safe_key(value) do
    String.to_existing_atom(to_string(value))
  rescue
    ArgumentError -> :environment
  end
end
```
NOTE: `category` value in a Meili hit is the category KEY string (e.g. "herbalism"); `Category.accent/1` and `Category.get/1` take the atom key. `safe_key/1` converts safely. If a hit's category isn't a known key it falls back to the zune accent. The facet distribution from Meili is keyed by the category string (the doc stores `to_string(category)`), so `facet_count` looks up `to_string(cat.key)`.

- [ ] **Step 4: Add the route**

In `lib/verscienta_web/router.ex`, in the PUBLIC browser scope (with `/articles`, `/@:username`), add:
```elixir
    live "/search", SearchLive, :index
```

- [ ] **Step 5: Add the search nav link**

In `lib/verscienta_web/components/layouts/root.html.heex`, in the `<nav>` (visible to everyone, near the styleguide link), add:
```heex
        <a href="/search" class="transition-colors hover:text-ink">search</a>
```

- [ ] **Step 6: Run the test to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/search_live_test.exs"
```
Expected: all pass. If `render_change` on a `phx-change` form needs the form to have the field, the `#search-form` with `name="q"` covers it. Adjust the fallback-note assertion to match your exact copy.

- [ ] **Step 7: Format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix credo --strict"
git add -A
git commit -m "feat(search): /search LiveView with facets, fallback note, and nav link"
```
Then `git rev-parse --short HEAD`.

---

## Task 7: Boot setup + reindex task (TDD where practical)

**Files:**
- Create: `lib/verscienta/search/setup.ex`
- Create: `lib/mix/tasks/verscienta.reindex.ex`
- Modify: `lib/verscienta/application.ex`
- Test: `test/verscienta/search/setup_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/search/setup_test.exs`:
```elixir
defmodule Verscienta.Search.SetupTest do
  use ExUnit.Case, async: false

  alias Verscienta.Search.ClientStub
  alias Verscienta.Search.Setup

  setup do
    ClientStub.reset()
    on_exit(&ClientStub.reset/0)
  end

  test "run/0 returns :ok and is safe when the client errors" do
    Application.put_env(:verscienta, :search_stub, %{
      create_index: {:error, :down},
      update_settings: {:error, :down}
    })

    # Must not raise even when Meili is unreachable.
    assert Setup.run() == :ok
  end

  test "run/0 applies index setup when the client is healthy" do
    Application.put_env(:verscienta, :search_stub, %{
      create_index: {:ok, %{}},
      update_settings: {:ok, %{}}
    })

    assert Setup.run() == :ok
    funs = ClientStub.calls() |> Enum.map(&elem(&1, 0))
    assert :update_settings in funs
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/search/setup_test.exs"
```
Expected: fails — module missing.

- [ ] **Step 3: Create the setup module**

Create `lib/verscienta/search/setup.ex`:
```elixir
defmodule Verscienta.Search.Setup do
  @moduledoc "Boot-time, fault-tolerant Meilisearch index setup."
  require Logger

  alias Verscienta.Search.Index

  @doc "Ensure the index + settings exist. Never raises; logs on failure. Always returns :ok."
  def run do
    case safe_setup() do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Meilisearch index setup skipped: #{inspect(reason)}")
    end

    :ok
  end

  defp safe_setup do
    Index.setup()
  rescue
    e -> {:error, e}
  end

  @doc "Child spec: run setup once in a transient task (for the supervision tree)."
  def child_spec(_arg) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [&run/0]},
      restart: :transient
    }
  end
end
```

- [ ] **Step 4: Run the setup test to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/search/setup_test.exs"
```
Expected: pass.

- [ ] **Step 5: Add the boot child (skip in test)**

In `lib/verscienta/application.ex`, add the setup task to the children list AFTER the endpoint and Oban, guarded so it doesn't run in `:test`:
```elixir
    children =
      [
        VerscientaWeb.Telemetry,
        Verscienta.Repo,
        {DNSCluster, query: Application.get_env(:verscienta, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Verscienta.PubSub},
        {Oban, Application.fetch_env!(:verscienta, Oban)},
        VerscientaWeb.Endpoint,
        {AshAuthentication.Supervisor, [otp_app: :verscienta]}
      ] ++ search_setup_children()
```
And add a private helper at the bottom of the module:
```elixir
  defp search_setup_children do
    if Application.get_env(:verscienta, :start_search_setup, true) do
      [Verscienta.Search.Setup]
    else
      []
    end
  end
```
In `config/test.exs`, disable it:
```elixir
config :verscienta, start_search_setup: false
```
NOTE: match the EXISTING children list in `application.ex` (it currently has Telemetry, Repo, DNSCluster, PubSub, Oban, Endpoint, AshAuthentication.Supervisor — adjust to the real current contents; just append `++ search_setup_children()`). Keep the existing entries intact.

- [ ] **Step 6: Create the reindex mix task**

Create `lib/mix/tasks/verscienta.reindex.ex`:
```elixir
defmodule Mix.Tasks.Verscienta.Reindex do
  @shortdoc "Reindex all published articles into Meilisearch"
  @moduledoc "Ensures the index exists, then pushes every published article's document."
  use Mix.Task

  require Ash.Query

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    :ok = Verscienta.Search.Setup.run()

    articles =
      Verscienta.Content.Article
      |> Ash.Query.filter(status == :published)
      |> Ash.Query.load([:tags])
      |> Ash.read!(authorize?: false)

    docs = Enum.map(articles, &Verscienta.Search.Document.build/1)

    case docs do
      [] ->
        Mix.shell().info("No published articles to index.")

      _ ->
        case Verscienta.Search.Client.add_documents(Verscienta.Search.Index.name(), docs) do
          {:ok, _} -> Mix.shell().info("Reindexed #{length(docs)} article(s).")
          {:error, reason} -> Mix.shell().error("Reindex failed: #{inspect(reason)}")
        end
    end
  end
end
```

- [ ] **Step 7: Compile + full suite**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "mix compile --warnings-as-errors && MIX_ENV=test mix test"
```
Expected: compiles; full suite passes. The boot child is disabled in test so it won't interfere. Report the count.

- [ ] **Step 8: Format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix credo --strict"
git add -A
git commit -m "feat(search): fault-tolerant boot setup and reindex mix task"
```
Then `git rev-parse --short HEAD`.

---

## Task 8: Seeds reindex hook + full verification

**Files:**
- Modify: `priv/repo/seeds.exs`

- [ ] **Step 1: Trigger a reindex at the end of seeds (guarded)**

Append to `priv/repo/seeds.exs`:
```elixir
# Best-effort: push seeded published articles into the search index (no-op if Meili down).
:ok = Verscienta.Search.Setup.run()

published =
  Verscienta.Content.Article
  |> Ash.Query.filter(status == :published)
  |> Ash.Query.load([:tags])
  |> Ash.read!(authorize?: false)

case published do
  [] ->
    :ok

  articles ->
    docs = Enum.map(articles, &Verscienta.Search.Document.build/1)

    case Verscienta.Search.Client.add_documents(Verscienta.Search.Index.name(), docs) do
      {:ok, _} -> IO.puts("Indexed #{length(docs)} published article(s) for search")
      {:error, _} -> IO.puts("Search index skipped (Meilisearch unavailable)")
    end
end
```
NOTE: `require Ash.Query` is already at the top of seeds (used by earlier blocks); if not, add it.

- [ ] **Step 2: Run seeds (idempotency + no crash with Meili down)**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "mix ash.setup >/dev/null 2>&1; mix run priv/repo/seeds.exs"
```
Expected: seeds run; the search block prints either "Indexed N…" (if meili container up) or "Search index skipped…" (if down) — **must not crash** either way.

- [ ] **Step 3: Full quality-gate run**

```powershell
docker compose run --rm -T app bash -lc "mix deps.get && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
```
Expected: format clean, credo 0 issues, no warnings, ALL tests pass (every prior subsystem + search document/index/sync/service/LiveView/setup). Capture the final `N tests, 0 failures`.

- [ ] **Step 4: Manual smoke (optional, requires Meili)**

```powershell
docker compose up -d
docker compose logs app --tail 20
docker compose run --rm -T app bash -lc "mix verscienta.reindex"
```
In a browser: `/search` → type a word from a seeded article's title/body → see results; toggle a category facet; (optionally `docker compose stop meilisearch` then search again to see the "limited results" fallback note). Then `docker compose down`.

- [ ] **Step 5: Commit**

```powershell
git add -A
git commit -m "feat(search): index seeded articles; finalize search subsystem"
```
Then `git rev-parse --short HEAD`.

---

## Definition of Done (verify all)

- [ ] Publishing an article makes it findable at `/search` by title/excerpt/body/tag words; archiving removes it (via the Oban index worker).
- [ ] `/search` has a live debounced query, category facets (with counts when Meili is up), result cards linking to the reader, and a `search` nav link.
- [ ] With Meili down, `/search` returns title/excerpt matches via Postgres with a "limited results" note, and the app still boots.
- [ ] `mix verscienta.reindex` repopulates the index from all published articles.
- [ ] Index sync runs through Oban (unique per article, retried); only published articles are indexed.
- [ ] All tests pass (Meili stubbed); `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict` clean.
- [ ] No DB migrations added; work committed on `phase-1-search`.
```
