# AI / Ollama Enrichment Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enrich articles with a local LLM (Ollama) — summary→excerpt, auto-tags, category suggestion, evidence-level scoring — written back best-effort, full enrich for aggregated articles and fill-empty for user articles.

**Architecture:** A behaviour-based `Verscienta.AI.Client` (Req impl + test Stub) talks to Ollama's `/api/generate` in JSON mode. A `Verscienta.AI` context builds the prompt, parses+validates the JSON, and writes back via a system `Article.ai_enrich` action. An `EnrichArticleWorker` (new `:ai` Oban queue) runs it; an `EnqueueEnrich` after-action change enqueues on ingest (`:create_aggregated`) and publish (`:publish`). A `mix verscienta.ai_backfill` task enqueues existing articles. Ollama being down/slow never blocks ingest, publish, or boot.

**Tech Stack:** Elixir, Ash 3.27, AshPostgres, Oban, Req, Ollama (llama3.2:3b). Tests via ExUnit + `Oban.Testing` (`testing: :manual`).

**Conventions (apply to every task):**
- Run all `mix` commands **in Docker**: `docker compose exec web mix <...>` (or the project's documented dev wrapper). Never run mix on the host.
- **Never hand-write migrations.** Use `mix ash.codegen <name>`. This subsystem adds NO new columns (the `ai_enrich` action reuses existing attributes), so `ash.codegen` should produce an empty/near-empty diff — run it to confirm.
- Before each commit: `mix format`; ensure files are LF line endings; no `.bak` files.
- Each commit body ends with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Test DB resets use `MIX_ENV=test mix ecto.drop -r Verscienta.Repo && mix ecto.create -r Verscienta.Repo && mix ash.migrate` (NOT `ash.setup` — seeding contaminates count assertions).
- Work on branch `ai-ollama` (create it before Task 1; see Task 0).
- 8 categories: `:nutrition, :herbalism, :mindfulness, :movement, :functional_medicine, :tcm, :ayurveda, :environment`. 3 evidence levels: `:anecdotal, :emerging, :established`. Excerpt max length: 300.

---

### Task 0: Branch setup

**Files:** none (git only)

- [ ] **Step 1: Create and switch to the feature branch**

Run:
```bash
git checkout main && git pull --ff-only
git checkout -b ai-ollama
```
Expected: on a clean `ai-ollama` branch off `main` (which already has the committed spec `docs/superpowers/specs/2026-06-04-ai-ollama-enrichment-design.md`).

---

### Task 1: Config — ollama_model, ai_client, :ai Oban queue

**Files:**
- Modify: `config/runtime.exs:157-159`
- Modify: `config/config.exs:74-84` (Oban queues) + add `ai_client`
- Modify: `config/test.exs` (ai_client → Stub)

- [ ] **Step 1: Add `ollama_model` to runtime config**

In `config/runtime.exs`, replace the `config :verscienta, redis_url:/ollama_url:` block (lines 157-159) with:

```elixir
config :verscienta,
  redis_url: System.get_env("REDIS_URL", "redis://localhost:6379"),
  ollama_url: System.get_env("OLLAMA_URL", "http://localhost:11434"),
  ollama_model: System.get_env("OLLAMA_MODEL", "llama3.2:3b")
```

- [ ] **Step 2: Add `ai_client` default + `:ai` Oban queue in config.exs**

In `config/config.exs`, after the existing `config :verscienta, search_client: ...` / `images_client: ...` block (near line 70), add:

```elixir
config :verscienta, ai_client: Verscienta.AI.Client.Req
```

Then in the `config :verscienta, Oban` block (lines 74-84), change the queues line to include `ai`:

```elixir
  queues: [default: 10, aggregation: 5, ai: 3],
```

- [ ] **Step 3: Point the AI client at the Stub in test**

In `config/test.exs`, alongside the existing `search_client`/`images_client` stub config, add:

```elixir
config :verscienta, ai_client: Verscienta.AI.Client.Stub
```

- [ ] **Step 4: Verify config compiles**

Run: `docker compose exec web mix compile --warnings-as-errors`
Expected: compiles clean (the referenced `Verscienta.AI.Client.Req`/`.Stub` modules don't exist yet but config values are not resolved at compile time, so this passes; if it fails on the missing module, it's only resolved at runtime — proceed to Task 2 which defines them).

- [ ] **Step 5: Commit**

```bash
git add config/runtime.exs config/config.exs config/test.exs
git commit -m "$(cat <<'EOF'
feat(ai): add ollama_model, ai_client config, and :ai Oban queue

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: AI client — behaviour + Req impl + test Stub

**Files:**
- Create: `lib/verscienta/ai/client.ex`
- Create: `test/support/ai_client_stub.ex`
- Test: `test/verscienta/ai/client_stub_test.exs`

- [ ] **Step 1: Write the failing test for the Stub**

Create `test/verscienta/ai/client_stub_test.exs`:

```elixir
defmodule Verscienta.AI.ClientStubTest do
  use ExUnit.Case, async: false

  alias Verscienta.AI.Client
  alias Verscienta.AI.ClientStub

  setup do
    ClientStub.reset()
    on_exit(&ClientStub.reset/0)
  end

  test "dispatch resolves to the configured stub and records calls" do
    Application.put_env(:verscienta, :ai_stub, %{generate: {:ok, ~s({"summary":"hi"})}})

    assert {:ok, ~s({"summary":"hi"})} = Client.generate("a prompt", [])
    assert [{:generate, ["a prompt", []]}] = ClientStub.calls()
  end

  test "defaults to an ok empty-json response when unconfigured" do
    assert {:ok, "{}"} = Client.generate("p", [])
  end
end
```

- [ ] **Step 2: Run the test, expect failure**

Run: `docker compose exec web mix test test/verscienta/ai/client_stub_test.exs`
Expected: FAIL — `Verscienta.AI.Client`/`ClientStub` undefined.

- [ ] **Step 3: Implement the client behaviour + Req impl**

Create `lib/verscienta/ai/client.ex`:

```elixir
defmodule Verscienta.AI.Client do
  @moduledoc "Behaviour + Req implementation for the Ollama generate API."

  @callback generate(prompt :: String.t(), opts :: keyword) :: {:ok, String.t()} | {:error, term}

  @doc "Generate a completion. Returns the raw response text (JSON string in our usage)."
  def generate(prompt, opts \\ []), do: impl().generate(prompt, opts)

  defp impl, do: Application.get_env(:verscienta, :ai_client, __MODULE__.Req)

  defmodule Req do
    @moduledoc false
    @behaviour Verscienta.AI.Client

    # Local inference is slow; allow a generous timeout.
    @receive_timeout 60_000

    @impl true
    def generate(prompt, opts) do
      url = base_url() <> "/api/generate"

      body = %{
        "model" => Keyword.get(opts, :model, model()),
        "prompt" => prompt,
        "stream" => false,
        "format" => "json"
      }

      case Elixir.Req.request(
             method: :post,
             url: url,
             json: body,
             receive_timeout: Keyword.get(opts, :receive_timeout, @receive_timeout)
           ) do
        {:ok, %{status: status, body: %{"response" => response}}} when status in 200..299 ->
          {:ok, response}

        {:ok, %{status: status, body: resp}} ->
          {:error, {:http_status, status, resp}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp base_url, do: Application.fetch_env!(:verscienta, :ollama_url)
    defp model, do: Application.fetch_env!(:verscienta, :ollama_model)
  end
end
```

- [ ] **Step 4: Implement the test Stub**

Create `test/support/ai_client_stub.ex`:

```elixir
defmodule Verscienta.AI.ClientStub do
  @moduledoc """
  Configurable, recording test double for Verscienta.AI.Client.
  Configure responses via Application.put_env(:verscienta, :ai_stub, %{generate: {:ok, "..."}}).
  Calls recorded under :ai_stub_calls as a list of {fun, args}.
  """
  @behaviour Verscienta.AI.Client

  @impl true
  def generate(prompt, opts), do: respond(:generate, [prompt, opts])

  defp respond(fun, args) do
    record(fun, args)
    stub = Application.get_env(:verscienta, :ai_stub, %{})
    Map.get(stub, fun, {:ok, "{}"})
  end

  defp record(fun, args) do
    calls = Application.get_env(:verscienta, :ai_stub_calls, [])
    Application.put_env(:verscienta, :ai_stub_calls, calls ++ [{fun, args}])
  end

  @doc "Test helper: recorded calls."
  def calls, do: Application.get_env(:verscienta, :ai_stub_calls, [])

  @doc "Test helper: reset stub state."
  def reset do
    Application.delete_env(:verscienta, :ai_stub)
    Application.put_env(:verscienta, :ai_stub_calls, [])
  end
end
```

- [ ] **Step 5: Run the test, expect pass**

Run: `docker compose exec web mix test test/verscienta/ai/client_stub_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 6: Format + commit**

```bash
docker compose exec web mix format
git add lib/verscienta/ai/client.ex test/support/ai_client_stub.ex test/verscienta/ai/client_stub_test.exs
git commit -m "$(cat <<'EOF'
feat(ai): add AI.Client behaviour, Req impl, and test stub

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `Article.ai_enrich` system write-back action

**Files:**
- Modify: `lib/verscienta/content/article.ex` (add action ~after line 92; add policy ~after line 121)
- Test: `test/verscienta/content/article_ai_enrich_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/content/article_ai_enrich_test.exs`:

```elixir
defmodule Verscienta.Content.ArticleAiEnrichTest do
  use Verscienta.DataCase, async: false

  alias Verscienta.Content.Article

  defp aggregated_article(attrs \\ %{}) do
    base = %{
      title: "Raw feed title",
      excerpt: "raw",
      category: :nutrition,
      canonical_url: "https://example.com/#{System.unique_integer([:positive])}",
      published_at: DateTime.utc_now()
    }

    Article
    |> Ash.Changeset.for_create(:create_aggregated, Map.merge(base, attrs))
    |> Ash.create!(authorize?: false)
  end

  test "ai_enrich writes excerpt, category, evidence_level, and appends tags" do
    article = aggregated_article()

    enriched =
      article
      |> Ash.Changeset.for_update(
        :ai_enrich,
        %{
          excerpt: "A cleaner summary.",
          category: :herbalism,
          evidence_level: :emerging,
          tags: ["turmeric", "inflammation"]
        }
      )
      |> Ash.update!(authorize?: false, load: [:tags])

    assert enriched.excerpt == "A cleaner summary."
    assert enriched.category == :herbalism
    assert enriched.evidence_level == :emerging
    assert Enum.sort(Enum.map(enriched.tags, &to_string(&1.name))) == ["inflammation", "turmeric"]
  end

  test "ai_enrich is forbidden without authorize?: false" do
    article = aggregated_article()

    assert {:error, _} =
             article
             |> Ash.Changeset.for_update(:ai_enrich, %{excerpt: "x"})
             |> Ash.update(actor: nil)
  end
end
```

- [ ] **Step 2: Run the test, expect failure**

Run: `docker compose exec web mix test test/verscienta/content/article_ai_enrich_test.exs`
Expected: FAIL — no action `ai_enrich`.

- [ ] **Step 3: Add the `ai_enrich` action**

In `lib/verscienta/content/article.ex`, immediately after the `create :create_aggregated do ... end` block (ends at line 92), add:

```elixir
    update :ai_enrich do
      description "System action: write AI-derived fields. Worker-only (authorize?: false)."
      require_atomic? false
      accept [:excerpt, :category, :evidence_level]
      argument :tags, {:array, :string}, default: []

      change manage_relationship(:tags, :tags,
               type: :append,
               value_is_key: :name,
               use_identities: [:unique_name],
               on_lookup: :relate,
               on_no_match: {:create, :upsert_by_name}
             )

      change Verscienta.Content.Article.Changes.EnqueueIndex
    end
```

- [ ] **Step 4: Add the policy (system-only)**

In the `policies do` block, immediately after the `policy action(:create_aggregated) do ... end` block (ends ~line 123), add:

```elixir
    policy action(:ai_enrich) do
      # System-context only: invoked with authorize?: false by the AI enrichment worker.
      forbid_if always()
    end
```

- [ ] **Step 5: Confirm no migration is needed**

Run: `docker compose exec web mix ash.codegen ai_enrich_action`
Expected: "No changes" / empty migration (the action reuses existing columns). If a non-empty migration is generated, STOP — it indicates an unexpected schema change; review before proceeding.

- [ ] **Step 6: Run the test, expect pass**

Run: `docker compose exec web mix test test/verscienta/content/article_ai_enrich_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 7: Format + commit**

```bash
docker compose exec web mix format
git add lib/verscienta/content/article.ex test/verscienta/content/article_ai_enrich_test.exs
git commit -m "$(cat <<'EOF'
feat(ai): add Article.ai_enrich system action (worker-only)

Writes AI-derived excerpt/category/evidence_level + appends tags, then
re-enqueues search indexing. Forbidden by policy; worker uses
authorize?: false.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `Verscienta.AI` context — parse + enrich

**Files:**
- Create: `lib/verscienta/ai.ex`
- Test: `test/verscienta/ai_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/verscienta/ai_test.exs`:

```elixir
defmodule Verscienta.AITest do
  use Verscienta.DataCase, async: false

  alias Verscienta.AI
  alias Verscienta.AI.ClientStub
  alias Verscienta.Content.Article

  setup do
    ClientStub.reset()
    on_exit(&ClientStub.reset/0)
  end

  defp stub_generate(json), do: Application.put_env(:verscienta, :ai_stub, %{generate: {:ok, json}})

  defp aggregated_article(attrs \\ %{}) do
    base = %{
      title: "Feed title",
      excerpt: "raw",
      category: :nutrition,
      canonical_url: "https://example.com/#{System.unique_integer([:positive])}",
      published_at: DateTime.utc_now()
    }

    Article
    |> Ash.Changeset.for_create(:create_aggregated, Map.merge(base, attrs))
    |> Ash.create!(authorize?: false)
  end

  defp user_article(user, attrs) do
    Article
    |> Ash.Changeset.for_create(:create, attrs, actor: user)
    |> Ash.create!(actor: user)
  end

  describe "parse_enrichment/1" do
    test "extracts and validates all fields" do
      json = ~s({"summary":"A short summary.","tags":["a","b"],"category":"herbalism","evidence_level":"emerging"})
      assert {:ok, parsed} = AI.parse_enrichment(json)
      assert parsed.summary == "A short summary."
      assert parsed.tags == ["a", "b"]
      assert parsed.category == :herbalism
      assert parsed.evidence_level == :emerging
    end

    test "drops invalid category/evidence, caps tags, drops blank summary" do
      json =
        ~s({"summary":"  ","tags":["a","b","c","d","e","f","a"],"category":"nonsense","evidence_level":"bogus"})

      assert {:ok, parsed} = AI.parse_enrichment(json)
      refute Map.has_key?(parsed, :summary)
      assert length(parsed.tags) == 5
      refute Map.has_key?(parsed, :category)
      refute Map.has_key?(parsed, :evidence_level)
    end

    test "returns :invalid on malformed json" do
      assert {:error, :invalid} = AI.parse_enrichment("not json")
      assert {:error, :invalid} = AI.parse_enrichment(~s(["a","b"]))
    end
  end

  describe "enrich_article/1 — aggregated (full)" do
    test "overwrites all four fields" do
      stub_generate(
        ~s({"summary":"Clean summary.","tags":["turmeric"],"category":"herbalism","evidence_level":"established"})
      )

      article = aggregated_article()
      assert :ok = AI.enrich_article(article)

      reloaded = Ash.get!(Article, article.id, authorize?: false, load: [:tags])
      assert reloaded.excerpt == "Clean summary."
      assert reloaded.category == :herbalism
      assert reloaded.evidence_level == :established
      assert Enum.map(reloaded.tags, &to_string(&1.name)) == ["turmeric"]
    end

    test "invalid category from model keeps existing category" do
      stub_generate(~s({"summary":"S","category":"nonsense","evidence_level":"emerging"}))
      article = aggregated_article(%{category: :nutrition})
      assert :ok = AI.enrich_article(article)

      reloaded = Ash.get!(Article, article.id, authorize?: false)
      assert reloaded.category == :nutrition
      assert reloaded.evidence_level == :emerging
    end
  end

  describe "enrich_article/1 — user article (fill-empty)" do
    setup do
      user =
        Verscienta.Accounts.User
        |> Ash.Changeset.for_create(:register_with_password, %{
          email: "ai-#{System.unique_integer([:positive])}@example.com",
          username: "ai#{System.unique_integer([:positive])}",
          password: "password1234",
          password_confirmation: "password1234"
        })
        |> Ash.create!(authorize?: false)

      %{user: user}
    end

    test "fills only blank fields; never overwrites author excerpt/category/tags", %{user: user} do
      stub_generate(
        ~s({"summary":"AI summary","tags":["ai-tag"],"category":"herbalism","evidence_level":"emerging"})
      )

      # Author set excerpt + category + a tag; left evidence_level nil.
      article =
        user_article(user, %{
          title: "My post",
          excerpt: "Author excerpt",
          category: :movement,
          blocks: [%{"type" => "markdown", "data" => %{"source" => "body"}}],
          tags: ["author-tag"]
        })

      assert :ok = AI.enrich_article(article)

      reloaded = Ash.get!(Article, article.id, authorize?: false, load: [:tags])
      assert reloaded.excerpt == "Author excerpt"
      assert reloaded.category == :movement
      assert reloaded.evidence_level == :emerging
      assert Enum.map(reloaded.tags, &to_string(&1.name)) == ["author-tag"]
    end
  end

  describe "enrich_article/1 — degradation" do
    test "client error leaves the article unchanged and returns error" do
      Application.put_env(:verscienta, :ai_stub, %{generate: {:error, :econnrefused}})
      article = aggregated_article(%{excerpt: "raw", category: :nutrition})

      assert {:error, _} = AI.enrich_article(article)
      reloaded = Ash.get!(Article, article.id, authorize?: false)
      assert reloaded.excerpt == "raw"
      assert reloaded.category == :nutrition
    end

    test "permanent parse failure returns {:error, :invalid} and leaves article unchanged" do
      stub_generate("not json")
      article = aggregated_article(%{excerpt: "raw"})

      assert {:error, :invalid} = AI.enrich_article(article)
      assert Ash.get!(Article, article.id, authorize?: false).excerpt == "raw"
    end
  end
end
```

- [ ] **Step 2: Run the tests, expect failure**

Run: `docker compose exec web mix test test/verscienta/ai_test.exs`
Expected: FAIL — `Verscienta.AI` undefined.

- [ ] **Step 3: Implement the context**

Create `lib/verscienta/ai.ex`:

```elixir
defmodule Verscienta.AI do
  @moduledoc """
  Local-LLM (Ollama) article enrichment: summary, tags, category, evidence level.

  Aggregated articles are fully enriched (all four fields overwritten).
  User-authored articles are fill-empty only (blank fields filled; author
  curation never overwritten; category never touched). Best-effort: a client
  or parse failure never raises into the caller.
  """
  require Logger

  alias Verscienta.AI.Client
  alias Verscienta.Content.Article
  alias Verscienta.Search.Document

  @categories ~w(nutrition herbalism mindfulness movement functional_medicine tcm ayurveda environment)a
  @evidence_levels ~w(anecdotal emerging established)a
  @excerpt_limit 300
  @max_tags 5
  @body_char_budget 4_000

  @doc """
  Enrich one article in place. Returns `:ok` on success, `{:error, :invalid}` on a
  permanent parse/validation failure (caller should NOT retry), or `{:error, reason}`
  on a transient client failure (caller MAY retry).
  """
  def enrich_article(%Article{} = article) do
    with {:ok, raw} <- Client.generate(build_prompt(article)),
         {:ok, parsed} <- parse_enrichment(raw) do
      write_back(article, parsed)
    end
  rescue
    error ->
      Logger.warning("AI enrichment crashed for article #{article.id}: #{inspect(error)}")
      {:error, :crashed}
  end

  @doc "Parse + validate the model's JSON response into a sparse enrichment map."
  def parse_enrichment(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = map} -> {:ok, validate(map)}
      _ -> {:error, :invalid}
    end
  end

  def parse_enrichment(_), do: {:error, :invalid}

  defp validate(map) do
    %{}
    |> put_summary(map["summary"])
    |> put_tags(map["tags"])
    |> put_category(map["category"])
    |> put_evidence(map["evidence_level"])
  end

  defp put_summary(acc, value) when is_binary(value) do
    case String.trim(value) do
      "" -> acc
      s -> Map.put(acc, :summary, String.slice(s, 0, @excerpt_limit))
    end
  end

  defp put_summary(acc, _), do: acc

  defp put_tags(acc, value) when is_list(value) do
    tags =
      value
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.take(@max_tags)

    if tags == [], do: acc, else: Map.put(acc, :tags, tags)
  end

  defp put_tags(acc, _), do: acc

  defp put_category(acc, value) when is_binary(value) do
    case safe_atom(value, @categories) do
      nil -> acc
      atom -> Map.put(acc, :category, atom)
    end
  end

  defp put_category(acc, _), do: acc

  defp put_evidence(acc, value) when is_binary(value) do
    case safe_atom(value, @evidence_levels) do
      nil -> acc
      atom -> Map.put(acc, :evidence_level, atom)
    end
  end

  defp put_evidence(acc, _), do: acc

  defp safe_atom(value, allowed) do
    Enum.find(allowed, fn a -> Atom.to_string(a) == String.downcase(String.trim(value)) end)
  end

  # Compute the field set to write based on mode, then run the system action.
  defp write_back(article, parsed) do
    attrs = if article.aggregated?, do: full_attrs(parsed), else: fill_empty_attrs(article, parsed)

    if map_size(attrs) == 0 and Map.get(attrs, :tags, []) == [] do
      :ok
    else
      article
      |> Ash.Changeset.for_update(:ai_enrich, attrs)
      |> Ash.update(authorize?: false)
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Aggregated: overwrite all available validated fields.
  defp full_attrs(parsed) do
    %{tags: Map.get(parsed, :tags, [])}
    |> maybe_put(:excerpt, Map.get(parsed, :summary))
    |> maybe_put(:category, Map.get(parsed, :category))
    |> maybe_put(:evidence_level, Map.get(parsed, :evidence_level))
  end

  # User article: only fill fields the author left blank; never category.
  defp fill_empty_attrs(article, parsed) do
    %{}
    |> fill_if_blank(:excerpt, article.excerpt, Map.get(parsed, :summary))
    |> fill_if_nil(:evidence_level, article.evidence_level, Map.get(parsed, :evidence_level))
    |> fill_tags_if_none(article, Map.get(parsed, :tags, []))
  end

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp fill_if_blank(attrs, key, current, new)
       when (is_nil(current) or current == "") and not is_nil(new),
       do: Map.put(attrs, key, new)

  defp fill_if_blank(attrs, _key, _current, _new), do: attrs

  defp fill_if_nil(attrs, key, nil, new) when not is_nil(new), do: Map.put(attrs, key, new)
  defp fill_if_nil(attrs, _key, _current, _new), do: attrs

  defp fill_tags_if_none(attrs, article, new_tags) do
    loaded = Ash.load!(article, :tags, authorize?: false)

    if loaded.tags in [nil, []] and new_tags != [] do
      Map.put(attrs, :tags, new_tags)
    else
      attrs
    end
  end

  defp build_prompt(article) do
    body = article.blocks |> Document.blocks_to_text() |> String.slice(0, @body_char_budget)

    """
    You are a metadata extractor for a holistic-health news platform.
    Read the ARTICLE and return ONLY a JSON object with these keys:
      "summary": a 1-2 sentence plain-text summary (no markdown).
      "tags": an array of 3-5 short lowercase topic tags.
      "category": EXACTLY ONE of: nutrition, herbalism, mindfulness, movement,
        functional_medicine, tcm, ayurveda, environment.
      "evidence_level": one of: anecdotal, emerging, established
        (use "anecdotal" for general/lifestyle content with no cited studies).
    Do not include any text outside the JSON object.

    TITLE: #{article.title}

    ARTICLE:
    #{body}
    """
  end
end
```

- [ ] **Step 4: Run the tests, expect pass**

Run: `docker compose exec web mix test test/verscienta/ai_test.exs`
Expected: PASS (all describe blocks).

> Note: if `register_with_password` argument names differ in this codebase, adjust the test's user factory to match the existing Accounts registration action (check `lib/verscienta/accounts/user.ex`). The context code does not depend on it.

- [ ] **Step 5: Format + commit**

```bash
docker compose exec web mix format
git add lib/verscienta/ai.ex test/verscienta/ai_test.exs
git commit -m "$(cat <<'EOF'
feat(ai): add AI context (prompt, parse+validate, enrich_article)

Full enrich for aggregated articles; fill-empty for user articles
(never overwrites author excerpt/category/tags). Best-effort; invalid
JSON or out-of-enum values are dropped.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `EnrichArticleWorker` (the `:ai` queue)

**Files:**
- Create: `lib/verscienta/ai/workers/enrich_article_worker.ex`
- Test: `test/verscienta/ai/workers/enrich_article_worker_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/ai/workers/enrich_article_worker_test.exs`:

```elixir
defmodule Verscienta.AI.Workers.EnrichArticleWorkerTest do
  use Verscienta.DataCase, async: false

  alias Verscienta.AI.ClientStub
  alias Verscienta.AI.Workers.EnrichArticleWorker
  alias Verscienta.Content.Article

  setup do
    ClientStub.reset()
    on_exit(&ClientStub.reset/0)
  end

  defp aggregated_article do
    Article
    |> Ash.Changeset.for_create(:create_aggregated, %{
      title: "T",
      excerpt: "raw",
      category: :nutrition,
      canonical_url: "https://example.com/#{System.unique_integer([:positive])}",
      published_at: DateTime.utc_now()
    })
    |> Ash.create!(authorize?: false)
  end

  test "perform enriches the article" do
    Application.put_env(:verscienta, :ai_stub, %{generate: {:ok, ~s({"summary":"Done.","category":"herbalism"})}})
    article = aggregated_article()

    assert :ok = perform_job(EnrichArticleWorker, %{"article_id" => article.id})

    reloaded = Ash.get!(Article, article.id, authorize?: false)
    assert reloaded.excerpt == "Done."
    assert reloaded.category == :herbalism
  end

  test "perform returns :ok (discard) when the article is missing" do
    assert :ok = perform_job(EnrichArticleWorker, %{"article_id" => Ash.UUID.generate()})
  end

  test "perform returns {:error, _} on transient client failure (retryable)" do
    Application.put_env(:verscienta, :ai_stub, %{generate: {:error, :timeout}})
    article = aggregated_article()
    assert {:error, _} = perform_job(EnrichArticleWorker, %{"article_id" => article.id})
  end

  test "perform returns :ok (discard) on permanent parse failure" do
    Application.put_env(:verscienta, :ai_stub, %{generate: {:ok, "not json"}})
    article = aggregated_article()
    assert :ok = perform_job(EnrichArticleWorker, %{"article_id" => article.id})
  end
end
```

(`perform_job/2` comes from `Oban.Testing`; ensure the test module uses it — `Verscienta.DataCase` should already `use Oban.Testing, repo: ...`; if not, add `use Oban.Testing, repo: Verscienta.Repo` to this test.)

- [ ] **Step 2: Run the test, expect failure**

Run: `docker compose exec web mix test test/verscienta/ai/workers/enrich_article_worker_test.exs`
Expected: FAIL — worker undefined.

- [ ] **Step 3: Implement the worker**

Create `lib/verscienta/ai/workers/enrich_article_worker.ex`:

```elixir
defmodule Verscienta.AI.Workers.EnrichArticleWorker do
  @moduledoc "Runs AI enrichment for a single article. Best-effort, retryable on transient errors."
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
  def perform(%Oban.Job{args: %{"article_id" => id}}) do
    case Ash.get(Article, id, authorize?: false) do
      {:ok, article} ->
        case AI.enrich_article(article) do
          :ok -> :ok
          # Permanent parse/validation failure: discard (don't retry-storm).
          {:error, :invalid} -> :ok
          {:error, :crashed} -> :ok
          # Transient (client) failure: let Oban retry.
          {:error, reason} -> {:error, reason}
        end

      # Article gone (deleted): nothing to do.
      {:error, _} ->
        :ok
    end
  end
end
```

- [ ] **Step 4: Run the test, expect pass**

Run: `docker compose exec web mix test test/verscienta/ai/workers/enrich_article_worker_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Format + commit**

```bash
docker compose exec web mix format
git add lib/verscienta/ai/workers/enrich_article_worker.ex test/verscienta/ai/workers/enrich_article_worker_test.exs
git commit -m "$(cat <<'EOF'
feat(ai): add EnrichArticleWorker on the :ai Oban queue

Discards on missing article / permanent parse failure; retries on
transient client errors.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `EnqueueEnrich` change + wire into ingest & publish

**Files:**
- Create: `lib/verscienta/content/article/changes/enqueue_enrich.ex`
- Modify: `lib/verscienta/content/article.ex` (add the change to `:create_aggregated` and `:publish`)
- Test: `test/verscienta/content/article_enqueue_enrich_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/content/article_enqueue_enrich_test.exs`:

```elixir
defmodule Verscienta.Content.ArticleEnqueueEnrichTest do
  use Verscienta.DataCase, async: false

  alias Verscienta.AI.Workers.EnrichArticleWorker
  alias Verscienta.Content.Article

  test "create_aggregated enqueues an enrichment job" do
    article =
      Article
      |> Ash.Changeset.for_create(:create_aggregated, %{
        title: "T",
        excerpt: "raw",
        category: :nutrition,
        canonical_url: "https://example.com/#{System.unique_integer([:positive])}",
        published_at: DateTime.utc_now()
      })
      |> Ash.create!(authorize?: false)

    assert_enqueued(worker: EnrichArticleWorker, args: %{"article_id" => article.id})
  end

  test "publish enqueues an enrichment job" do
    user =
      Verscienta.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: "enr-#{System.unique_integer([:positive])}@example.com",
        username: "enr#{System.unique_integer([:positive])}",
        password: "password1234",
        password_confirmation: "password1234"
      })
      |> Ash.create!(authorize?: false)

    article =
      Article
      |> Ash.Changeset.for_create(:create, %{
        title: "Mine",
        blocks: [%{"type" => "markdown", "data" => %{"source" => "body"}}]
      }, actor: user)
      |> Ash.create!(actor: user)

    article
    |> Ash.Changeset.for_update(:publish, %{}, actor: user)
    |> Ash.update!(actor: user)

    assert_enqueued(worker: EnrichArticleWorker, args: %{"article_id" => article.id})
  end
end
```

- [ ] **Step 2: Run the test, expect failure**

Run: `docker compose exec web mix test test/verscienta/content/article_enqueue_enrich_test.exs`
Expected: FAIL — no enrichment job enqueued.

- [ ] **Step 3: Implement the change**

Create `lib/verscienta/content/article/changes/enqueue_enrich.ex`:

```elixir
defmodule Verscienta.Content.Article.Changes.EnqueueEnrich do
  @moduledoc "After-action: enqueue best-effort AI enrichment for the article."
  use Ash.Resource.Change
  require Logger

  alias Verscienta.AI.Workers.EnrichArticleWorker

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      enqueue(record)
      {:ok, record}
    end)
  end

  # Best-effort: an enqueue failure must never roll back the article write.
  defp enqueue(record) do
    %{"article_id" => record.id}
    |> EnrichArticleWorker.new()
    |> Oban.insert!()

    :ok
  rescue
    error ->
      Logger.warning("Failed to enqueue AI enrichment for article #{record.id}: #{inspect(error)}")
      :ok
  end
end
```

- [ ] **Step 4: Wire it into the two actions**

In `lib/verscienta/content/article.ex`:

In `create :create_aggregated`, after `change Verscienta.Content.Article.Changes.EnqueueIndex` (line 91), add:

```elixir
      change Verscienta.Content.Article.Changes.EnqueueEnrich
```

In `update :publish`, after `change Verscienta.Content.Article.Changes.EmitPublishActivity` (line 72), add:

```elixir
      change Verscienta.Content.Article.Changes.EnqueueEnrich
```

- [ ] **Step 5: Run the test, expect pass**

Run: `docker compose exec web mix test test/verscienta/content/article_enqueue_enrich_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 6: Format + commit**

```bash
docker compose exec web mix format
git add lib/verscienta/content/article/changes/enqueue_enrich.ex lib/verscienta/content/article.ex test/verscienta/content/article_enqueue_enrich_test.exs
git commit -m "$(cat <<'EOF'
feat(ai): enqueue AI enrichment on ingest and publish

EnqueueEnrich after-action (best-effort) wired into create_aggregated
and publish.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `mix verscienta.ai_backfill` task

**Files:**
- Create: `lib/mix/tasks/verscienta.ai_backfill.ex`
- Test: `test/mix/tasks/verscienta_ai_backfill_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/mix/tasks/verscienta_ai_backfill_test.exs`:

```elixir
defmodule Mix.Tasks.Verscienta.AiBackfillTest do
  use Verscienta.DataCase, async: false

  alias Verscienta.AI.Workers.EnrichArticleWorker
  alias Verscienta.Content.Article

  defp aggregated_article do
    Article
    |> Ash.Changeset.for_create(:create_aggregated, %{
      title: "T",
      excerpt: "raw",
      category: :nutrition,
      canonical_url: "https://example.com/#{System.unique_integer([:positive])}",
      published_at: DateTime.utc_now()
    })
    |> Ash.create!(authorize?: false)
  end

  test "enqueues an enrichment job per aggregated article" do
    a = aggregated_article()
    b = aggregated_article()

    Mix.Tasks.Verscienta.AiBackfill.run([])

    assert_enqueued(worker: EnrichArticleWorker, args: %{"article_id" => a.id})
    assert_enqueued(worker: EnrichArticleWorker, args: %{"article_id" => b.id})
  end
end
```

- [ ] **Step 2: Run the test, expect failure**

Run: `docker compose exec web mix test test/mix/tasks/verscienta_ai_backfill_test.exs`
Expected: FAIL — task undefined.

- [ ] **Step 3: Implement the task**

Create `lib/mix/tasks/verscienta.ai_backfill.ex`:

```elixir
defmodule Mix.Tasks.Verscienta.AiBackfill do
  @shortdoc "Enqueue AI enrichment for existing articles"
  @moduledoc """
  Enqueues an EnrichArticleWorker job for existing articles.

      mix verscienta.ai_backfill            # aggregated articles (default)
      mix verscienta.ai_backfill --all      # all published articles

  Idempotent via the worker's uniqueness window.
  """
  use Mix.Task

  require Ash.Query

  alias Verscienta.AI.Workers.EnrichArticleWorker
  alias Verscienta.Content.Article

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    all? = "--all" in args

    query =
      if all? do
        Ash.Query.filter(Article, status == :published)
      else
        Ash.Query.filter(Article, aggregated? == true)
      end

    articles = Ash.read!(query, authorize?: false)

    Enum.each(articles, fn a ->
      %{"article_id" => a.id} |> EnrichArticleWorker.new() |> Oban.insert!()
    end)

    Mix.shell().info("Enqueued AI enrichment for #{length(articles)} article(s).")
  end
end
```

- [ ] **Step 4: Run the test, expect pass**

Run: `docker compose exec web mix test test/mix/tasks/verscienta_ai_backfill_test.exs`
Expected: PASS (1 test).

- [ ] **Step 5: Format + commit**

```bash
docker compose exec web mix format
git add lib/mix/tasks/verscienta.ai_backfill.ex test/mix/tasks/verscienta_ai_backfill_test.exs
git commit -m "$(cat <<'EOF'
feat(ai): add mix verscienta.ai_backfill task

Enqueues enrichment for existing aggregated (or, with --all, published)
articles. Logs the count enqueued.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Full verification, docs, merge prep

**Files:**
- Modify: `docs/todo.md` (tick AI/Ollama items)

- [ ] **Step 1: Reset the test DB without seeds (avoid contamination)**

Run:
```bash
docker compose exec web sh -c 'MIX_ENV=test mix ecto.drop -r Verscienta.Repo && MIX_ENV=test mix ecto.create -r Verscienta.Repo && MIX_ENV=test mix ash.migrate'
```
Expected: migrations apply cleanly.

- [ ] **Step 2: Run the full gate**

Run:
```bash
docker compose exec web sh -c 'mix compile --warnings-as-errors && mix format --check-formatted && mix credo --strict && MIX_ENV=test mix test'
```
Expected: all green; full suite passes (prior baseline 310/0 + the new AI tests, 0 failures).

If failures occur, fix them and re-run before proceeding. Do NOT dismiss failures as "pre-existing seed contamination" without re-running on the freshly reset DB from Step 1.

- [ ] **Step 3: Update todo.md**

In `docs/todo.md`, mark the AI/Ollama subsystem items complete (Ollama client + config; summarization; auto-tagging + category suggestion; evidence-level scoring; backfill + on-ingest hook; graceful degradation). Match the existing checkbox style used by other completed subsystems.

- [ ] **Step 4: Commit docs**

```bash
git add docs/todo.md
git commit -m "$(cat <<'EOF'
docs: mark AI/Ollama enrichment subsystem complete

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 5: Report ready for merge**

Summarize the branch (`ai-ollama`), the gate results, and stop. Merge to `main` and push happen only after the final whole-branch review and explicit user approval (use superpowers:finishing-a-development-branch).

---

## Notes for the implementer
- The `register_with_password` factory in tests is illustrative — confirm the real Accounts registration action name/arguments (`lib/verscienta/accounts/user.ex`) and adjust the test factories to match. Production code does not depend on it.
- `Verscienta.DataCase` may or may not already `use Oban.Testing`. If `perform_job`/`assert_enqueued` are undefined in a test, add `use Oban.Testing, repo: Verscienta.Repo` to that test module.
- Group articles: `ai_enrich` re-runs `EnqueueIndex`, which already skips/removes group articles from the global index — isolation is preserved automatically. No extra work needed.
- Do not rewrite article `blocks`; this subsystem only sets metadata fields.
```
