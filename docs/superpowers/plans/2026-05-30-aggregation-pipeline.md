# Aggregation Pipeline Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pull articles from trusted RSS/Atom feeds into the existing content feed via a `Source` resource and an Oban-scheduled fetch pipeline, with an admin LiveView to manage sources.

**Architecture:** A `Source` Ash resource + extensions to `Article` (nullable author, `source` ref, unique `canonical_url`, `aggregated?`); a `Fetcher` that pulls feeds with `req`, parses with `fast_rss`, and creates de-duplicated published aggregated Articles via a system-context `:create_aggregated` action; Oban workers (per-source fetch + hourly cron scheduler); an admin-only `/admin/sources` LiveView; and a reader "via source / read original" affordance.

**Tech Stack:** Phoenix 1.8, Ash 3, AshPostgres, AshPhoenix.Form, Oban, req, fast_rss, LiveView, Tailwind v4 + Codex components.

---

## Conventions for the executor

- **Run everything in Docker.** Mix runs in the app service: `docker compose run --rm -T app bash -lc "<cmd>"`. Start DB first: `docker compose up -d db`. Generous timeouts (deps/compile take minutes). If OOM-killed (exit 137), split commands / prefix `ERL_FLAGS="+S 2 +A 4"`.
- **Deps volume:** if a fresh `app-run` container reports "dependency is not available", run `mix deps.get` first in the same `docker compose run` invocation (the deps volume may be empty for ephemeral runs).
- **One task at a time, sequentially.** After each task run `git rev-parse --short HEAD` to capture the REAL sha. Never batch tasks or reference unverified SHAs.
- **Branch:** `phase-1-aggregation` (already checked out; spec committed as `93421d2`).
- **Line endings:** `.gitattributes` eol=lf, autocrlf false — don't change. `mix format` before commit.
- **Test DB isolation:** `config/test.exs` pins the DB name to `verscienta_test` (Compose injects `DB_NAME=verscienta_dev` via env_file — don't rely on `DB_NAME` for tests). Seeds contaminate count-based asserts; content tests already account for this — keep new count asserts scoped (e.g. filter by the source you created), not global counts.
- **Git identity:** no local override. Commit body ends with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- **Migrations:** Ash resources via `mix ash.codegen <name>`; Oban via its own Ecto migration (Task 1).
- **TDD:** resources/policies/fetcher/workers/LiveViews write the failing test first. Dep/scaffold tasks gate on compile + migration applying.
- **Existing patterns to reuse:** `Verscienta.DataCase`; `AshAuthentication.Plug.Helpers.store_in_session/2` for signing a conn into a test session; the `.text_field` private component pattern in `lib/verscienta_web/live/settings_live.ex`; the `NotFound` exception + author-only mount pattern in `lib/verscienta_web/live/article_editor_live.ex`; `Verscienta.Content.Category` (keys/select_options/accent); `Verscienta.Content.Block`/`BlockRenderer`/`Markdown`.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `mix.exs` | add `:oban`, `:fast_rss` |
| `config/config.exs` | Oban config (repo, queues, cron plugin) |
| `config/test.exs` | `config :verscienta, Oban, testing: :manual` |
| `lib/verscienta/application.ex` | add `{Oban, ...}` to the supervision tree |
| `priv/repo/migrations/*_add_oban_jobs_table.exs` | Oban's table (generated) |
| `lib/verscienta/content/source.ex` | `Source` resource (attrs, actions, policies) |
| `lib/verscienta/content/article.ex` | extend: nullable author, `source` ref, `canonical_url`, `aggregated?`, validation, `:create_aggregated` |
| `lib/verscienta/content.ex` | register `Source` |
| `lib/verscienta/aggregation.ex` | thin context module (optional helpers) |
| `lib/verscienta/aggregation/feed_client.ex` | behaviour + `req` impl for fetching a URL (test-stubbable) |
| `lib/verscienta/aggregation/fetcher.ex` | parse feed + create aggregated articles + record status |
| `lib/verscienta/aggregation/html.ex` | `strip_html/1` helper |
| `lib/verscienta/aggregation/workers/fetch_source_worker.ex` | Oban worker: fetch one source |
| `lib/verscienta/aggregation/workers/schedule_fetches_worker.ex` | Oban worker: enqueue all active sources |
| `lib/verscienta_web/live/admin_sources_live.ex` | `/admin/sources` admin LiveView |
| `lib/verscienta_web/live/article_reader_live.ex` | add via-source affordance |
| `lib/verscienta_web/components/layouts/root.html.heex` | admin nav link (admins only) |
| `lib/verscienta_web/router.ex` | `/admin/sources` route |
| `test/verscienta/content/source_test.exs`, `test/verscienta/aggregation/*_test.exs`, `test/verscienta_web/live/admin_sources_live_test.exs` | tests |

---

## Task 1: Add Oban + fast_rss; configure and supervise (compile/migrate gate)

**Files:**
- Modify: `mix.exs`, `config/config.exs`, `config/test.exs`, `lib/verscienta/application.ex`
- Create (generated): Oban migration

- [ ] **Step 1: Add deps**

In `mix.exs` `defp deps`, add:
```elixir
      {:oban, "~> 2.18"},
      {:fast_rss, "~> 0.5"},
```

- [ ] **Step 2: Fetch deps**

```powershell
docker compose run --rm -T app bash -lc "mix deps.get"
```
Expected: both resolve. `fast_rss` ships a precompiled NIF. If `~> 0.5` for fast_rss is unavailable, use the latest `0.x` and NOTE it.

- [ ] **Step 3: Configure Oban**

In `config/config.exs`, after the `ash_domains` config, add:
```elixir
config :verscienta, Oban,
  engine: Oban.Engines.Basic,
  repo: Verscienta.Repo,
  queues: [default: 10, aggregation: 5],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       {"0 * * * *", Verscienta.Aggregation.Workers.ScheduleFetchesWorker}
     ]}
  ]
```

- [ ] **Step 4: Disable Oban execution in tests**

In `config/test.exs`, add:
```elixir
config :verscienta, Oban, testing: :manual
```

- [ ] **Step 5: Supervise Oban**

In `lib/verscienta/application.ex`, add to the `children` list (after `Verscienta.Repo`, before the endpoint):
```elixir
      {Oban, Application.fetch_env!(:verscienta, Oban)},
```

- [ ] **Step 6: Generate the Oban migration**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "mix ecto.gen.migration add_oban_jobs_table"
```
Then edit the generated migration file under `priv/repo/migrations/` to:
```elixir
defmodule Verscienta.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 12)
  def down, do: Oban.Migration.down(version: 1)
end
```

- [ ] **Step 7: Migrate + compile**

```powershell
docker compose run --rm -T app bash -lc "mix ecto.migrate && mix compile --warnings-as-errors"
```
Expected: `oban_jobs`/`oban_peers` tables created; compiles with no warnings. The app boots with Oban supervised.

- [ ] **Step 8: Format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format"
git add -A
git commit -m "build(aggregation): add and supervise Oban; add fast_rss"
```
Then `git rev-parse --short HEAD`.

---

## Task 2: `Source` resource (TDD)

**Files:**
- Create: `lib/verscienta/content/source.ex`
- Modify: `lib/verscienta/content.ex`
- Test: `test/verscienta/content/source_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/verscienta/content/source_test.exs`:
```elixir
defmodule Verscienta.Content.SourceTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Content.Source

  defp user(username, role) do
    u =
      Verscienta.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: username <> "@example.com",
        username: username,
        password: "password123",
        password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    u
    |> Ash.Changeset.for_update(:update_profile, %{}, actor: u)
    |> Ash.Changeset.force_change_attribute(:role, role)
    |> Ash.update!(authorize?: false)
  end

  defp admin, do: user("admin1", :admin)
  defp member, do: user("member1", :user)

  defp create_source(actor, attrs \\ %{}) do
    base = %{name: "NIH News", feed_url: "https://example.com/feed.xml", category: :nutrition}

    Source
    |> Ash.Changeset.for_create(:create, Map.merge(base, attrs), actor: actor)
    |> Ash.create(authorize?: true)
  end

  test "admin can create a source; it defaults active and never-fetched" do
    {:ok, source} = create_source(admin())
    assert source.active? == true
    assert source.last_status == :never
  end

  test "non-admin cannot create a source" do
    assert {:error, _} = create_source(member())
  end

  test "feed_url is unique" do
    a = admin()
    {:ok, _} = create_source(a)
    assert {:error, _} = create_source(a, %{name: "Dup"})
  end

  test "list_active excludes inactive sources" do
    a = admin()
    {:ok, s1} = create_source(a)
    {:ok, s2} = create_source(a, %{name: "Two", feed_url: "https://example.com/2.xml"})

    {:ok, _} = s2 |> Ash.Changeset.for_update(:deactivate, %{}, actor: a) |> Ash.update()

    active = Ash.read!(Source, action: :list_active, authorize?: false)
    ids = Enum.map(active, & &1.id)
    assert s1.id in ids
    refute s2.id in ids
  end

  test "record_fetch_result updates last_* fields (system context)" do
    a = admin()
    {:ok, source} = create_source(a)

    {:ok, updated} =
      source
      |> Ash.Changeset.for_update(:record_fetch_result, %{last_status: :error, last_error: "boom"})
      |> Ash.update(authorize?: false)

    assert updated.last_status == :error
    assert updated.last_error == "boom"
    assert updated.last_fetched_at != nil
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta/content/source_test.exs"
```
Expected: fails — resource missing.

- [ ] **Step 3: Create the Source resource**

Create `lib/verscienta/content/source.ex`:
```elixir
defmodule Verscienta.Content.Source do
  @moduledoc "An RSS/Atom feed source for content aggregation."
  use Ash.Resource,
    otp_app: :verscienta,
    domain: Verscienta.Content,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "sources"
    repo Verscienta.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [:name, :feed_url, :category, :active?]
    end

    update :update do
      accept [:name, :feed_url, :category, :active?]
    end

    update :activate do
      accept []
      change set_attribute(:active?, true)
    end

    update :deactivate do
      accept []
      change set_attribute(:active?, false)
    end

    update :record_fetch_result do
      accept [:last_status, :last_error]
      change set_attribute(:last_fetched_at, &DateTime.utc_now/0)
    end

    read :list_active do
      filter expr(active? == true)
    end
  end

  policies do
    policy action(:record_fetch_result) do
      # System-context only: invoked with authorize?: false by the fetcher.
      forbid_if always()
    end

    policy action_type([:create, :update, :read]) do
      authorize_if expr(^actor(:role) == :admin)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :feed_url, :string, allow_nil?: false, public?: true

    attribute :category, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :nutrition,
                    :herbalism,
                    :mindfulness,
                    :movement,
                    :functional_medicine,
                    :tcm,
                    :ayurveda,
                    :environment
                  ]
    end

    attribute :active?, :boolean, allow_nil?: false, default: true, public?: true
    attribute :last_fetched_at, :utc_datetime_usec, allow_nil?: true, public?: true

    attribute :last_status, :atom do
      allow_nil? false
      default :never
      public? true
      constraints one_of: [:never, :ok, :error]
    end

    attribute :last_error, :string, allow_nil?: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :articles, Verscienta.Content.Article
  end

  identities do
    identity :unique_feed_url, [:feed_url]
  end
end
```
NOTE: the `record_fetch_result` policy uses `forbid_if always()` so NO actor can call it; the fetcher calls it with `authorize?: false`, which bypasses policies. If `set_attribute(:last_fetched_at, &DateTime.utc_now/0)` (function form) is rejected by this Ash version, use a `change fn cs, _ -> Ash.Changeset.force_change_attribute(cs, :last_fetched_at, DateTime.utc_now()) end`. The category `one_of` must match `Category.keys()`.

- [ ] **Step 4: Register the resource**

In `lib/verscienta/content.ex`, add to `resources do`:
```elixir
    resource Verscienta.Content.Source
```

- [ ] **Step 5: Generate + apply migration**

```powershell
docker compose run --rm -T app bash -lc "mix ash.codegen add_source_resource && mix ash.migrate"
```
Expected: `sources` table with a unique index on `feed_url`.

- [ ] **Step 6: Run the tests to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/content/source_test.exs"
```
Expected: all pass. If the `record_fetch_result` test fails because `forbid_if always()` also blocks the `authorize?: false` call — it should NOT (authorize?: false bypasses policies entirely); if your Ash version still runs the change, keep `authorize?: false` in the test (it's there).

- [ ] **Step 7: Format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix credo --strict"
git add -A
git commit -m "feat(aggregation): Source resource with admin-only policies"
```
Then `git rev-parse --short HEAD`.

---

## Task 3: Extend `Article` for aggregation (TDD)

**Files:**
- Modify: `lib/verscienta/content/article.ex`
- Test: `test/verscienta/content/article_aggregation_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/verscienta/content/article_aggregation_test.exs`:
```elixir
defmodule Verscienta.Content.ArticleAggregationTest do
  use Verscienta.DataCase, async: true

  require Ash.Query

  alias Verscienta.Content.Article
  alias Verscienta.Content.Source

  defp admin do
    u =
      Verscienta.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: "agg_admin@example.com",
        username: "aggadmin",
        password: "password123",
        password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    u
    |> Ash.Changeset.for_update(:update_profile, %{}, actor: u)
    |> Ash.Changeset.force_change_attribute(:role, :admin)
    |> Ash.update!(authorize?: false)
  end

  defp source(admin) do
    Source
    |> Ash.Changeset.for_create(
      :create,
      %{name: "Feed", feed_url: "https://example.com/agg.xml", category: :herbalism},
      actor: admin
    )
    |> Ash.create!(authorize?: true)
  end

  defp create_aggregated(src, attrs) do
    base = %{
      title: "Aggregated Item",
      excerpt: "summary",
      blocks: [%{"type" => "markdown", "data" => %{"source" => "summary [orig](https://x.test/a)"}}],
      category: :herbalism,
      canonical_url: "https://x.test/a",
      source_id: src.id,
      published_at: DateTime.utc_now()
    }

    Article
    |> Ash.Changeset.for_create(:create_aggregated, Map.merge(base, attrs))
    |> Ash.create(authorize?: false)
  end

  test "create_aggregated makes a published, authorless, source-linked article" do
    src = source(admin())
    {:ok, article} = create_aggregated(src, %{})
    assert article.aggregated? == true
    assert article.status == :published
    assert article.author_id == nil
    assert article.source_id == src.id
    assert article.canonical_url == "https://x.test/a"
  end

  test "canonical_url is unique (dedupe guard)" do
    src = source(admin())
    {:ok, _} = create_aggregated(src, %{})
    assert {:error, _} = create_aggregated(src, %{title: "Dup"})
  end

  test "authored article still requires an author (either author or source)" do
    # Creating via the human :create action with no actor must fail the author/source rule.
    assert {:error, _} =
             Article
             |> Ash.Changeset.for_create(:create, %{
               title: "No Author",
               blocks: [],
               category: :movement
             })
             |> Ash.create(authorize?: false)
  end

  test "an authored article (with actor) has an author and is not aggregated" do
    a = admin()

    {:ok, article} =
      Article
      |> Ash.Changeset.for_create(:create, %{title: "Mine", blocks: [], category: :movement},
        actor: a
      )
      |> Ash.create(authorize?: true)

    assert article.author_id == a.id
    assert article.aggregated? == false
    assert article.canonical_url == nil
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta/content/article_aggregation_test.exs"
```
Expected: fails — new attrs/action/validation missing.

- [ ] **Step 3: Make `author` nullable and add aggregation attributes/relationship**

In `lib/verscienta/content/article.ex`, change the author relationship from `allow_nil?: false` to `allow_nil?: true`:
```elixir
    belongs_to :author, Verscienta.Accounts.User, allow_nil?: true
```
Add a source relationship in the `relationships do` block:
```elixir
    belongs_to :source, Verscienta.Content.Source, allow_nil?: true
```
In `attributes do`, add (after `published_at`):
```elixir
    attribute :canonical_url, :string, allow_nil?: true, public?: true
    attribute :aggregated?, :boolean, allow_nil?: false, default: false, public?: true
```
In `identities do`, add:
```elixir
    identity :unique_canonical_url, [:canonical_url]
```

- [ ] **Step 4: Add the author-or-source validation**

In `lib/verscienta/content/article.ex`, add a `validations do` block (top-level in the resource):
```elixir
  validations do
    validate fn changeset, _context ->
               author = Ash.Changeset.get_attribute(changeset, :author_id)
               source = Ash.Changeset.get_attribute(changeset, :source_id)

               if is_nil(author) and is_nil(source) do
                 {:error, field: :author_id, message: "an article must have an author or a source"}
               else
                 :ok
               end
             end,
             on: [:create, :update]
  end
```
NOTE: `relate_actor(:author)` in the human `:create` action sets `author_id` before validations run, so authored articles pass. If validations run before `relate_actor` in this Ash version (causing the "with actor" test to fail), move the check into a `change` with `Ash.Changeset.before_action/2` or validate in `after_action`; the gate is: no-actor create fails, with-actor create succeeds, aggregated (source set) succeeds.

- [ ] **Step 5: Add the `:create_aggregated` action**

In `lib/verscienta/content/article.ex` `actions do`, add:
```elixir
    create :create_aggregated do
      description "System action: create a published aggregated article from a feed item."
      accept [:title, :excerpt, :category, :canonical_url, :source_id, :published_at]
      argument :blocks, {:array, :map}, default: []

      change Verscienta.Content.Article.Changes.CastBlocks
      change set_attribute(:aggregated?, true)
      change set_attribute(:status, :published)
      change Verscienta.Content.Article.Changes.GenerateSlug
    end
```
(`GenerateSlug` and `CastBlocks` already exist from the Content subsystem. `:create_aggregated` does not use `relate_actor`, so `author_id` stays nil; the source_id satisfies the validation.)

- [ ] **Step 6: Generate + apply migration**

```powershell
docker compose run --rm -T app bash -lc "mix ash.codegen add_article_aggregation && mix ash.migrate"
```
Expected: migration making `articles.author_id` nullable, adding `source_id` (FK), `canonical_url` (+ unique index), `aggregated?`.

- [ ] **Step 7: Run the tests to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/content/article_aggregation_test.exs"
```
Expected: all pass.

- [ ] **Step 8: Run the EXISTING article test to ensure no regressions**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/content/article_test.exs"
```
Expected: still all pass (the author change is backward-compatible because authored actions set the author). If the existing "create defaults to draft" test broke because author is now optional, it shouldn't — `relate_actor` still runs. Fix any fallout before committing.

- [ ] **Step 9: Format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix credo --strict"
git add -A
git commit -m "feat(aggregation): extend Article (source, canonical_url, aggregated?, create_aggregated)"
```
Then `git rev-parse --short HEAD`.

---

## Task 4: HTML strip helper + feed client behaviour (TDD)

**Files:**
- Create: `lib/verscienta/aggregation/html.ex`
- Create: `lib/verscienta/aggregation/feed_client.ex`
- Modify: `config/config.exs`, `config/test.exs`
- Test: `test/verscienta/aggregation/html_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/aggregation/html_test.exs`:
```elixir
defmodule Verscienta.Aggregation.HtmlTest do
  use ExUnit.Case, async: true

  alias Verscienta.Aggregation.Html

  test "strips tags to text" do
    assert Html.strip("<p>Hello <b>world</b></p>") == "Hello world"
  end

  test "drops script content entirely" do
    out = Html.strip("safe <script>alert('x')</script> text")
    refute out =~ "alert"
    refute out =~ "<script>"
    assert out =~ "safe"
    assert out =~ "text"
  end

  test "decodes common entities" do
    assert Html.strip("a &amp; b &lt;c&gt;") == "a & b <c>"
  end

  test "collapses whitespace and trims" do
    assert Html.strip("  a\n\n  b  ") == "a b"
  end

  test "nil/empty safe" do
    assert Html.strip(nil) == ""
    assert Html.strip("") == ""
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/aggregation/html_test.exs"
```
Expected: fails — module missing.

- [ ] **Step 3: Implement the strip helper**

Create `lib/verscienta/aggregation/html.ex`:
```elixir
defmodule Verscienta.Aggregation.Html do
  @moduledoc "Reduces feed-summary HTML to plain text (for excerpts/markdown blocks)."

  @doc "Strip tags + script/style content, decode common entities, collapse whitespace."
  def strip(nil), do: ""
  def strip(""), do: ""

  def strip(html) when is_binary(html) do
    html
    |> drop_blocks(~r/<script\b[^>]*>.*?<\/script>/is)
    |> drop_blocks(~r/<style\b[^>]*>.*?<\/style>/is)
    |> String.replace(~r/<[^>]+>/, " ")
    |> decode_entities()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp drop_blocks(text, regex), do: String.replace(text, regex, " ")

  defp decode_entities(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&apos;", "'")
    |> String.replace("&nbsp;", " ")
  end
end
```
NOTE: order matters — decode entities AFTER stripping tags so `&lt;c&gt;` becomes literal `<c>` text (not re-stripped). The test "decodes common entities" is the gate.

- [ ] **Step 4: Run to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/aggregation/html_test.exs"
```
Expected: 5 tests, 0 failures.

- [ ] **Step 5: Add the feed client behaviour + req impl**

Create `lib/verscienta/aggregation/feed_client.ex`:
```elixir
defmodule Verscienta.Aggregation.FeedClient do
  @moduledoc "Fetches a feed URL's raw body. Behaviour allows stubbing in tests."

  @callback fetch(url :: String.t()) :: {:ok, String.t()} | {:error, term()}

  @doc "Fetch via the configured client (defaults to the Req implementation)."
  def fetch(url), do: impl().fetch(url)

  defp impl, do: Application.get_env(:verscienta, :feed_client, __MODULE__.Req)

  defmodule Req do
    @moduledoc false
    @behaviour Verscienta.Aggregation.FeedClient

    @impl true
    def fetch(url) do
      case Elixir.Req.get(url, max_redirects: 3, receive_timeout: 15_000) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, to_string(body)}

        {:ok, %{status: status}} ->
          {:error, {:http_status, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
```

- [ ] **Step 6: Point tests at a stub client**

In `config/test.exs`, add:
```elixir
config :verscienta, :feed_client, Verscienta.Aggregation.FeedClientStub
```
And create the stub `test/support/feed_client_stub.ex`:
```elixir
defmodule Verscienta.Aggregation.FeedClientStub do
  @moduledoc "Test feed client: returns whatever is stashed in the process dictionary or app env."
  @behaviour Verscienta.Aggregation.FeedClient

  @impl true
  def fetch(url) do
    case Application.get_env(:verscienta, :feed_client_responses, %{})[url] do
      nil -> {:error, :no_stub}
      response -> response
    end
  end
end
```
NOTE: ensure `test/support` is compiled in test env (it already is — `conn_case.ex`/`data_case.ex` live there). Tests set responses via `Application.put_env(:verscienta, :feed_client_responses, %{url => {:ok, body}})` and clean up with `on_exit`.

- [ ] **Step 7: Compile (no test yet for the client itself)**

```powershell
docker compose run --rm -T app bash -lc "mix compile --warnings-as-errors"
```
Expected: compiles.

- [ ] **Step 8: Format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix credo --strict"
git add -A
git commit -m "feat(aggregation): html strip helper and stubbable feed client"
```
Then `git rev-parse --short HEAD`.

---

## Task 5: Fetcher — parse + ingest + dedupe + status (TDD)

**Files:**
- Create: `lib/verscienta/aggregation/fetcher.ex`
- Test: `test/verscienta/aggregation/fetcher_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/verscienta/aggregation/fetcher_test.exs`:
```elixir
defmodule Verscienta.Aggregation.FetcherTest do
  use Verscienta.DataCase, async: false

  require Ash.Query

  alias Verscienta.Aggregation.Fetcher
  alias Verscienta.Content.Article
  alias Verscienta.Content.Source

  @feed """
  <?xml version="1.0"?>
  <rss version="2.0"><channel>
    <title>Test Feed</title>
    <item>
      <title>First Post</title>
      <link>https://feed.test/first</link>
      <description>A &lt;b&gt;summary&lt;/b&gt; with &lt;script&gt;alert('x')&lt;/script&gt; html</description>
      <pubDate>Wed, 01 Jan 2025 00:00:00 GMT</pubDate>
    </item>
    <item>
      <title>Second Post</title>
      <link>https://feed.test/second</link>
      <description>Second summary</description>
    </item>
  </channel></rss>
  """

  defp admin do
    u =
      Verscienta.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: "fetch_admin@example.com",
        username: "fetchadmin",
        password: "password123",
        password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    u
    |> Ash.Changeset.for_update(:update_profile, %{}, actor: u)
    |> Ash.Changeset.force_change_attribute(:role, :admin)
    |> Ash.update!(authorize?: false)
  end

  defp source(url \\ "https://feed.test/rss.xml") do
    Source
    |> Ash.Changeset.for_create(
      :create,
      %{name: "Test Feed", feed_url: url, category: :nutrition},
      actor: admin()
    )
    |> Ash.create!(authorize?: true)
  end

  defp stub(url, response) do
    existing = Application.get_env(:verscienta, :feed_client_responses, %{})
    Application.put_env(:verscienta, :feed_client_responses, Map.put(existing, url, response))
    on_exit(fn -> Application.put_env(:verscienta, :feed_client_responses, %{}) end)
  end

  defp articles_for(src) do
    Article
    |> Ash.Query.filter(source_id == ^src.id)
    |> Ash.read!(authorize?: false)
  end

  test "creates aggregated articles from a feed" do
    src = source()
    stub(src.feed_url, {:ok, @feed})

    {:ok, %{new: new}} = Fetcher.fetch_source(src)
    assert new == 2

    items = articles_for(src)
    assert length(items) == 2
    urls = items |> Enum.map(& &1.canonical_url) |> Enum.sort()
    assert urls == ["https://feed.test/first", "https://feed.test/second"]
    assert Enum.all?(items, & &1.aggregated?)
    assert Enum.all?(items, &(&1.status == :published))
    assert Enum.all?(items, &(&1.category == :nutrition))
  end

  test "summary html is stripped (no raw script/tags stored)" do
    src = source()
    stub(src.feed_url, {:ok, @feed})
    {:ok, _} = Fetcher.fetch_source(src)

    first = articles_for(src) |> Enum.find(&(&1.canonical_url == "https://feed.test/first"))
    refute first.excerpt =~ "<script>"
    refute first.excerpt =~ "alert"
    refute first.excerpt =~ "<b>"
    assert first.excerpt =~ "summary"
  end

  test "dedupes on re-fetch (no duplicates)" do
    src = source()
    stub(src.feed_url, {:ok, @feed})

    {:ok, %{new: first}} = Fetcher.fetch_source(src)
    {:ok, %{new: second, skipped: skipped}} = Fetcher.fetch_source(src)

    assert first == 2
    assert second == 0
    assert skipped == 2
    assert length(articles_for(src)) == 2
  end

  test "records ok status on success" do
    src = source()
    stub(src.feed_url, {:ok, @feed})
    {:ok, _} = Fetcher.fetch_source(src)

    reloaded = Ash.get!(Source, src.id, authorize?: false)
    assert reloaded.last_status == :ok
    assert reloaded.last_fetched_at != nil
  end

  test "records error status on fetch failure and creates nothing" do
    src = source()
    stub(src.feed_url, {:error, {:http_status, 503}})

    assert {:error, _} = Fetcher.fetch_source(src)
    assert articles_for(src) == []

    reloaded = Ash.get!(Source, src.id, authorize?: false)
    assert reloaded.last_status == :error
    assert reloaded.last_error != nil
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta/aggregation/fetcher_test.exs"
```
Expected: fails — Fetcher missing.

- [ ] **Step 3: Implement the Fetcher**

Create `lib/verscienta/aggregation/fetcher.ex`:
```elixir
defmodule Verscienta.Aggregation.Fetcher do
  @moduledoc "Fetches a source's feed, parses it, and ingests new items as aggregated articles."

  require Ash.Query

  alias Verscienta.Aggregation.FeedClient
  alias Verscienta.Aggregation.Html
  alias Verscienta.Content.Article
  alias Verscienta.Content.Source

  @doc "Fetch and ingest one source. Returns {:ok, %{new: n, skipped: m}} or {:error, reason}."
  def fetch_source(%Source{} = source) do
    with {:ok, body} <- FeedClient.fetch(source.feed_url),
         {:ok, parsed} <- parse(body) do
      result = ingest(source, entries(parsed))
      record(source, :ok, nil)
      {:ok, result}
    else
      {:error, reason} ->
        record(source, :error, format_error(reason))
        {:error, reason}
    end
  end

  defp parse(body) do
    case FastRSS.parse_rss(body) do
      {:ok, map} -> {:ok, map}
      {:error, _} -> parse_atom(body)
    end
  end

  defp parse_atom(body) do
    case FastRSS.parse_atom(body) do
      {:ok, map} -> {:ok, map}
      {:error, reason} -> {:error, {:parse, reason}}
    end
  end

  # Normalize RSS ("items") and Atom ("entries") into a common shape.
  defp entries(%{"items" => items}) when is_list(items), do: Enum.map(items, &rss_entry/1)
  defp entries(%{"entries" => entries}) when is_list(entries), do: Enum.map(entries, &atom_entry/1)
  defp entries(_), do: []

  defp rss_entry(item) do
    %{
      title: item["title"],
      link: item["link"],
      summary: item["description"],
      published: item["pub_date"]
    }
  end

  defp atom_entry(entry) do
    %{
      title: entry["title"],
      link: atom_link(entry["links"]),
      summary: entry["summary"] || entry["content"],
      published: entry["published"] || entry["updated"]
    }
  end

  defp atom_link([%{"href" => href} | _]), do: href
  defp atom_link(_), do: nil

  defp ingest(source, entries) do
    Enum.reduce(entries, %{new: 0, skipped: 0}, fn entry, acc ->
      case ingest_entry(source, entry) do
        :created -> %{acc | new: acc.new + 1}
        :skipped -> %{acc | skipped: acc.skipped + 1}
      end
    end)
  end

  defp ingest_entry(_source, %{title: t, link: l}) when is_nil(t) or is_nil(l) or t == "" or l == "",
    do: :skipped

  defp ingest_entry(source, entry) do
    if exists?(entry.link) do
      :skipped
    else
      summary = Html.strip(entry.summary)

      blocks = [
        %{
          "type" => "markdown",
          "data" => %{"source" => "#{summary}\n\n[Read the original →](#{entry.link})"}
        }
      ]

      Article
      |> Ash.Changeset.for_create(:create_aggregated, %{
        title: String.trim(entry.title),
        excerpt: String.slice(summary, 0, 300),
        blocks: blocks,
        category: source.category,
        canonical_url: entry.link,
        source_id: source.id,
        published_at: parse_date(entry.published)
      })
      |> Ash.create(authorize?: false)
      |> case do
        {:ok, _} -> :created
        # Unique-index race: another run inserted it first — treat as skipped.
        {:error, _} -> :skipped
      end
    end
  end

  defp exists?(url) do
    Article
    |> Ash.Query.filter(canonical_url == ^url)
    |> Ash.read_one!(authorize?: false)
    |> is_nil()
    |> Kernel.not()
  end

  defp parse_date(nil), do: DateTime.utc_now()

  defp parse_date(str) do
    case Timex.parse(str, "{RFC1123}") do
      {:ok, dt} -> dt
      _ -> fallback_date(str)
    end
  rescue
    _ -> DateTime.utc_now()
  end

  defp fallback_date(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp record(source, status, error) do
    source
    |> Ash.Changeset.for_update(:record_fetch_result, %{last_status: status, last_error: error})
    |> Ash.update!(authorize?: false)
  end

  defp format_error(reason), do: inspect(reason)
end
```
NOTE on date parsing: this uses `Timex` for RFC1123 (RSS `pubDate`). **Timex is not a dep.** Two options — pick one and report it: (a) add `{:timex, "~> 3.7}` to deps; or (b) drop Timex and use only `DateTime.from_iso8601/1` with `DateTime.utc_now()` fallback (Atom dates are ISO8601; RSS RFC1123 dates then fall back to "now", which is acceptable for MVP). **Prefer (b)** to avoid a dep — replace `parse_date/1` with:
```elixir
  defp parse_date(nil), do: DateTime.utc_now()

  defp parse_date(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
```
NOTE on FastRSS API: the module is `FastRSS` with `parse_rss/1` and `parse_atom/1` returning `{:ok, map}` with string keys. Verify the exact function names + the key names (`"items"`, `"description"`, `"link"`, `"pub_date"`) against the installed version: `docker compose run --rm -T app bash -lc "grep -rn 'def parse' deps/fast_rss/lib"` and adjust the `entries/1`/`rss_entry/1` keys to match. The fetcher tests (with the RSS fixture) are the gate.

- [ ] **Step 4: Run the tests; iterate to green**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/aggregation/fetcher_test.exs"
```
Expected: all pass. Adjust FastRSS key names per the NOTE until green. Do NOT weaken assertions (dedupe count, html stripped, error path creates nothing + records error).

- [ ] **Step 5: Format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix credo --strict"
git add -A
git commit -m "feat(aggregation): feed fetcher with parse, ingest, dedupe, status"
```
Then `git rev-parse --short HEAD`.

---

## Task 6: Oban workers (TDD)

**Files:**
- Create: `lib/verscienta/aggregation/workers/fetch_source_worker.ex`
- Create: `lib/verscienta/aggregation/workers/schedule_fetches_worker.ex`
- Test: `test/verscienta/aggregation/workers_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/verscienta/aggregation/workers_test.exs`:
```elixir
defmodule Verscienta.Aggregation.WorkersTest do
  use Verscienta.DataCase, async: false
  use Oban.Testing, repo: Verscienta.Repo

  alias Verscienta.Aggregation.Workers.FetchSourceWorker
  alias Verscienta.Aggregation.Workers.ScheduleFetchesWorker
  alias Verscienta.Content.Article
  alias Verscienta.Content.Source

  require Ash.Query

  @feed """
  <?xml version="1.0"?>
  <rss version="2.0"><channel><title>T</title>
  <item><title>One</title><link>https://w.test/one</link><description>sum</description></item>
  </channel></rss>
  """

  defp admin do
    u =
      Verscienta.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: "w_admin@example.com",
        username: "wadmin",
        password: "password123",
        password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    u
    |> Ash.Changeset.for_update(:update_profile, %{}, actor: u)
    |> Ash.Changeset.force_change_attribute(:role, :admin)
    |> Ash.update!(authorize?: false)
  end

  defp source(active?, url) do
    s =
      Source
      |> Ash.Changeset.for_create(:create, %{name: "S", feed_url: url, category: :tcm},
        actor: admin()
      )
      |> Ash.create!(authorize?: true)

    if active?, do: s, else: s |> Ash.Changeset.for_update(:deactivate, %{}, actor: admin()) |> Ash.update!()
  end

  test "FetchSourceWorker fetches and ingests" do
    src = source(true, "https://w.test/rss.xml")
    Application.put_env(:verscienta, :feed_client_responses, %{src.feed_url => {:ok, @feed}})
    on_exit(fn -> Application.put_env(:verscienta, :feed_client_responses, %{}) end)

    assert :ok = perform_job(FetchSourceWorker, %{"source_id" => src.id})

    items = Article |> Ash.Query.filter(source_id == ^src.id) |> Ash.read!(authorize?: false)
    assert length(items) == 1
  end

  test "ScheduleFetchesWorker enqueues a fetch per active source" do
    a = source(true, "https://w.test/a.xml")
    _b = source(false, "https://w.test/b.xml")
    c = source(true, "https://w.test/c.xml")

    assert :ok = perform_job(ScheduleFetchesWorker, %{})

    assert_enqueued(worker: FetchSourceWorker, args: %{"source_id" => a.id})
    assert_enqueued(worker: FetchSourceWorker, args: %{"source_id" => c.id})
    # inactive source b not enqueued
    refute_enqueued(worker: FetchSourceWorker, args: %{"source_id" => elem({:x}, 0)})
  end
end
```
NOTE: the last `refute_enqueued` line above is awkward — replace it with a proper check that source b was not enqueued:
```elixir
    refute_enqueued(worker: FetchSourceWorker, args: %{"source_id" => _b.id})
```
(and bind `b = source(false, ...)` instead of `_b`).

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta/aggregation/workers_test.exs"
```
Expected: fails — workers missing.

- [ ] **Step 3: Implement FetchSourceWorker**

Create `lib/verscienta/aggregation/workers/fetch_source_worker.ex`:
```elixir
defmodule Verscienta.Aggregation.Workers.FetchSourceWorker do
  @moduledoc "Fetches and ingests a single source's feed."
  use Oban.Worker,
    queue: :aggregation,
    max_attempts: 3,
    unique: [keys: [:source_id], period: 60, states: [:available, :scheduled, :executing]]

  alias Verscienta.Aggregation.Fetcher
  alias Verscienta.Content.Source

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id}}) do
    case Ash.get(Source, source_id, authorize?: false) do
      {:ok, source} ->
        case Fetcher.fetch_source(source) do
          {:ok, _result} -> :ok
          # Fetch errors are already recorded on the source; don't crash-loop the job.
          {:error, _reason} -> :ok
        end

      {:error, _} ->
        :ok
    end
  end
end
```
NOTE: returning `:ok` on fetch error (instead of `{:error, _}`) avoids Oban retrying transient feed outages aggressively while still recording `last_status: :error` on the source. If you'd rather retry, return `{:error, reason}` — but then the test "records error status" timing is unaffected (fetcher records before returning). Keep `:ok` for MVP.

- [ ] **Step 4: Implement ScheduleFetchesWorker**

Create `lib/verscienta/aggregation/workers/schedule_fetches_worker.ex`:
```elixir
defmodule Verscienta.Aggregation.Workers.ScheduleFetchesWorker do
  @moduledoc "Enqueues a FetchSourceWorker for every active source. Driven by Oban cron."
  use Oban.Worker, queue: :default, max_attempts: 1

  alias Verscienta.Aggregation.Workers.FetchSourceWorker
  alias Verscienta.Content.Source

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Source
    |> Ash.read!(action: :list_active, authorize?: false)
    |> Enum.each(fn source ->
      %{"source_id" => source.id}
      |> FetchSourceWorker.new()
      |> Oban.insert!()
    end)

    :ok
  end
end
```

- [ ] **Step 5: Run the tests to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/aggregation/workers_test.exs"
```
Expected: all pass.

- [ ] **Step 6: Format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix credo --strict"
git add -A
git commit -m "feat(aggregation): Oban fetch + schedule workers"
```
Then `git rev-parse --short HEAD`.

---

## Task 7: Admin sources LiveView (TDD)

**Files:**
- Create: `lib/verscienta_web/live/admin_sources_live.ex`
- Modify: `lib/verscienta_web/router.ex`, `lib/verscienta_web/components/layouts/root.html.heex`
- Test: `test/verscienta_web/live/admin_sources_live_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/admin_sources_live_test.exs`:
```elixir
defmodule VerscientaWeb.AdminSourcesLiveTest do
  use VerscientaWeb.ConnCase, async: false
  use Oban.Testing, repo: Verscienta.Repo

  import Phoenix.LiveViewTest

  alias AshAuthentication.Plug.Helpers
  alias Verscienta.Aggregation.Workers.FetchSourceWorker
  alias Verscienta.Content.Source

  defp user(username, role) do
    u =
      Verscienta.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: username <> "@example.com",
        username: username,
        password: "password123",
        password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    u
    |> Ash.Changeset.for_update(:update_profile, %{}, actor: u)
    |> Ash.Changeset.force_change_attribute(:role, role)
    |> Ash.update!(authorize?: false)
  end

  defp sign_in(conn, u), do: conn |> Plug.Test.init_test_session(%{}) |> Helpers.store_in_session(u)

  test "non-admin cannot access", %{conn: conn} do
    member = user("plainuser", :user)
    conn = sign_in(conn, member)
    assert {:error, {:redirect, _}} = live(conn, ~p"/admin/sources") |> wrap()
  rescue
    # If it raises NotFound instead of redirecting, that's also acceptable.
    _ -> :ok
  end

  test "admin can add a source", %{conn: conn} do
    admin = user("adminuser", :admin)
    conn = sign_in(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/admin/sources")

    lv
    |> form("#source-form", form: %{
      "name" => "My Feed",
      "feed_url" => "https://my.test/feed.xml",
      "category" => "nutrition"
    })
    |> render_submit()

    require Ash.Query
    source = Source |> Ash.Query.filter(feed_url == "https://my.test/feed.xml") |> Ash.read_one!(authorize?: false)
    assert source != nil
  end

  test "fetch now enqueues a worker", %{conn: conn} do
    admin = user("adminuser2", :admin)

    source =
      Source
      |> Ash.Changeset.for_create(:create, %{name: "F", feed_url: "https://f.test/x.xml", category: :tcm}, actor: admin)
      |> Ash.create!(authorize?: true)

    conn = sign_in(conn, admin)
    {:ok, lv, _html} = live(conn, ~p"/admin/sources")

    lv |> element("button[phx-value-id='#{source.id}'][phx-click='fetch_now']") |> render_click()

    assert_enqueued(worker: FetchSourceWorker, args: %{"source_id" => source.id})
  end

  defp wrap(result), do: result
end
```
NOTE: the non-admin test is written defensively (accepts redirect OR raise). Adjust to whatever the mount actually does (Step 3 raises `NotFound`); make the assertion match the real behavior — the REQUIREMENT is a non-admin cannot view the page.

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta_web/live/admin_sources_live_test.exs"
```
Expected: fails — route + LiveView missing.

- [ ] **Step 3: Create the admin LiveView**

Create `lib/verscienta_web/live/admin_sources_live.ex`:
```elixir
defmodule VerscientaWeb.AdminSourcesLive.NotFound do
  defexception message: "not found", plug_status: 404
end

defmodule VerscientaWeb.AdminSourcesLive do
  @moduledoc "Admin-only management of aggregation sources."
  use VerscientaWeb, :live_view
  require Ash.Query

  alias Verscienta.Aggregation.Workers.FetchSourceWorker
  alias Verscienta.Content.Category
  alias Verscienta.Content.Source

  on_mount {VerscientaWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    if user.role != :admin, do: raise(VerscientaWeb.AdminSourcesLive.NotFound)

    {:ok,
     socket
     |> assign(page_title: "sources", category_options: Category.select_options())
     |> assign_form()
     |> load_sources()}
  end

  defp load_sources(socket) do
    sources = Ash.read!(Source, actor: socket.assigns.current_user, authorize?: true)
    assign(socket, sources: Enum.sort_by(sources, & &1.name))
  end

  defp assign_form(socket) do
    form =
      Source
      |> AshPhoenix.Form.for_create(:create, as: "form", actor: socket.assigns.current_user)
      |> to_form()

    assign(socket, form: form)
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    {:noreply, assign(socket, form: AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, _source} ->
        {:noreply,
         socket
         |> put_flash(:info, "Source added")
         |> assign_form()
         |> load_sources()}

      {:error, form} ->
        {:noreply, assign(socket, form: form)}
    end
  end

  def handle_event("fetch_now", %{"id" => id}, socket) do
    %{"source_id" => id} |> FetchSourceWorker.new() |> Oban.insert!()
    {:noreply, put_flash(socket, :info, "Queued fetch")}
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    source = Ash.get!(Source, id, actor: socket.assigns.current_user, authorize?: true)
    action = if source.active?, do: :deactivate, else: :activate

    source
    |> Ash.Changeset.for_update(action, %{}, actor: socket.assigns.current_user)
    |> Ash.update!()

    {:noreply, load_sources(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-6 pb-24 pt-28">
      <.headline class="mb-10 text-5xl">sources</.headline>

      <.form
        :let={f}
        for={@form}
        id="source-form"
        phx-change="validate"
        phx-submit="save"
        class="mb-12 grid gap-4 sm:grid-cols-2 lg:grid-cols-4"
      >
        <input
          type="text"
          name={f[:name].name}
          value={Phoenix.HTML.Form.normalize_value("text", f[:name].value)}
          placeholder="name"
          class="border border-line bg-canvas-2 px-4 py-3 text-ink"
        />
        <input
          type="text"
          name={f[:feed_url].name}
          value={Phoenix.HTML.Form.normalize_value("text", f[:feed_url].value)}
          placeholder="feed url"
          class="border border-line bg-canvas-2 px-4 py-3 text-ink"
        />
        <select name={f[:category].name} class="border border-line bg-canvas-2 px-4 py-3 text-ink">
          <option :for={{label, key} <- @category_options} value={key}>{label}</option>
        </select>
        <button
          type="submit"
          class="bg-zune px-6 py-3 text-xs font-bold uppercase tracking-wider text-black hover:brightness-110"
        >
          add source
        </button>
      </.form>

      <table class="w-full border-collapse text-sm">
        <thead>
          <tr class="border-b border-line text-left text-[11px] uppercase tracking-wider text-ink-3">
            <th class="py-2">name</th>
            <th>category</th>
            <th>active</th>
            <th>last fetch</th>
            <th>status</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={source <- @sources} class="border-b border-line">
            <td class="py-3">
              <div class="text-ink">{source.name}</div>
              <div class="text-xs text-ink-3">{source.feed_url}</div>
            </td>
            <td class="text-ink-2">{source.category}</td>
            <td>
              <button
                type="button"
                phx-click="toggle_active"
                phx-value-id={source.id}
                class={[
                  "text-xs uppercase tracking-wider",
                  if(source.active?, do: "text-sport", else: "text-ink-3")
                ]}
              >
                {if source.active?, do: "active", else: "off"}
              </button>
            </td>
            <td class="text-xs text-ink-3">{format_dt(source.last_fetched_at)}</td>
            <td>
              <span class={status_class(source.last_status)}>{source.last_status}</span>
              <div :if={source.last_error} class="text-xs text-politics">{source.last_error}</div>
            </td>
            <td class="text-right">
              <button
                type="button"
                phx-click="fetch_now"
                phx-value-id={source.id}
                class="border border-line px-3 py-1.5 text-[11px] uppercase tracking-wider text-ink-2 hover:text-ink"
              >
                fetch now
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp format_dt(nil), do: "never"
  defp format_dt(dt), do: Calendar.strftime(dt, "%b %-d %H:%M")

  defp status_class(:ok), do: "text-sport text-xs uppercase tracking-wider"
  defp status_class(:error), do: "text-politics text-xs uppercase tracking-wider"
  defp status_class(_), do: "text-ink-3 text-xs uppercase tracking-wider"
end
```

- [ ] **Step 4: Add the route**

In `lib/verscienta_web/router.ex`, inside `ash_authentication_live_session :authenticated_routes`, add:
```elixir
      live "/admin/sources", AdminSourcesLive, :index
```

- [ ] **Step 5: Add the admin nav link**

In `lib/verscienta_web/components/layouts/root.html.heex`, in the signed-in branch, after the `write` link, add (admins only):
```heex
          <a
            :if={@current_user.role == :admin}
            href="/admin/sources"
            class="transition-colors hover:text-ink"
          >
            admin
          </a>
```

- [ ] **Step 6: Run the test to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/admin_sources_live_test.exs"
```
Expected: all pass. Make the non-admin assertion match observed behavior (raise vs redirect); keep the requirement (non-admin cannot view).

- [ ] **Step 7: Format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix credo --strict"
git add -A
git commit -m "feat(aggregation): admin sources LiveView with fetch-now; admin nav"
```
Then `git rev-parse --short HEAD`.

---

## Task 8: Reader via-source affordance (TDD)

**Files:**
- Modify: `lib/verscienta_web/live/article_reader_live.ex`
- Test: `test/verscienta_web/live/article_reader_live_test.exs` (extend)

- [ ] **Step 1: Add a failing test**

Append to `test/verscienta_web/live/article_reader_live_test.exs` (inside the module). First, ensure the file has the aliases/imports it needs (it already tests the reader). Add:
```elixir
  test "aggregated article shows its source and a read-original link", %{conn: conn} do
    # Build an admin + source + aggregated article directly.
    admin =
      Verscienta.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: "src_admin@example.com",
        username: "srcadmin",
        password: "password123",
        password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    admin =
      admin
      |> Ash.Changeset.for_update(:update_profile, %{}, actor: admin)
      |> Ash.Changeset.force_change_attribute(:role, :admin)
      |> Ash.update!(authorize?: false)

    source =
      Verscienta.Content.Source
      |> Ash.Changeset.for_create(:create, %{name: "Origin Daily", feed_url: "https://origin.test/f.xml", category: :herbalism}, actor: admin)
      |> Ash.create!(authorize?: true)

    {:ok, article} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create_aggregated, %{
        title: "Imported Piece",
        excerpt: "x",
        blocks: [%{"type" => "markdown", "data" => %{"source" => "body"}}],
        category: :herbalism,
        canonical_url: "https://origin.test/piece",
        source_id: source.id,
        published_at: DateTime.utc_now()
      })
      |> Ash.create(authorize?: false)

    {:ok, _lv, html} = live(conn, ~p"/articles/#{article.slug}")
    assert html =~ "Origin Daily"
    assert html =~ "https://origin.test/piece"
  end
```
NOTE: if the existing reader test file aliases `Article` etc. differently, use fully-qualified names as above to avoid collisions.

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta_web/live/article_reader_live_test.exs"
```
Expected: the new test fails (source not loaded / affordance not rendered); existing reader tests still pass.

- [ ] **Step 3: Load the source and render the affordance**

In `lib/verscienta_web/live/article_reader_live.ex`, find where the article is loaded with relationships (currently `[:author, :tags]`) and add `:source`:
```elixir
        article = Ash.load!(article, [:author, :tags, :source], actor: actor, authorize?: false)
```
In the reader's `render/1`, add a via-source line near the meta block (after the meta row, before the body):
```heex
      <div :if={@article.aggregated? && @article.source} class="mb-8 border border-line bg-canvas-2 px-4 py-3 text-xs text-ink-3">
        via {@article.source.name} ·
        <a href={@article.canonical_url} rel="noopener noreferrer" target="_blank" class="text-zune hover:text-ink">
          read the original →
        </a>
      </div>
```

- [ ] **Step 4: Run the tests to confirm pass**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/article_reader_live_test.exs"
```
Expected: all pass (new + existing).

- [ ] **Step 5: Format + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix credo --strict"
git add -A
git commit -m "feat(aggregation): show source + read-original link on aggregated articles"
```
Then `git rev-parse --short HEAD`.

---

## Task 9: Seeds + full verification

**Files:**
- Modify: `priv/repo/seeds.exs`

- [ ] **Step 1: Add a demo source (idempotent)**

Append to `priv/repo/seeds.exs`:
```elixir
# Demo aggregation source (idempotent), created by admin. Not auto-fetched in seeds.
admin =
  Verscienta.Accounts.User
  |> Ash.Query.filter(username == "admin")
  |> Ash.read_one!(authorize?: false)

if admin do
  feed_url = "https://hnrss.org/newest?q=nutrition"

  exists? =
    Verscienta.Content.Source
    |> Ash.Query.filter(feed_url == ^feed_url)
    |> Ash.read_one!(authorize?: false)

  if is_nil(exists?) do
    Verscienta.Content.Source
    |> Ash.Changeset.for_create(:create, %{name: "Demo Nutrition Feed", feed_url: feed_url, category: :nutrition}, actor: admin)
    |> Ash.create!(authorize?: true)

    IO.puts("Seeded aggregation source: Demo Nutrition Feed")
  end
end
```
NOTE: `require Ash.Query` may be needed near the top of seeds.exs (the file already uses `Ash.Query.filter` for earlier blocks — if not, add it).

- [ ] **Step 2: Run seeds twice (idempotency)**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "mix ash.setup >/dev/null 2>&1; mix run priv/repo/seeds.exs; mix run priv/repo/seeds.exs"
```
Expected: first run seeds the source; second prints nothing new for it.

- [ ] **Step 3: Full quality-gate run**

```powershell
docker compose run --rm -T app bash -lc "mix deps.get && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
```
Expected: format clean, credo 0 issues, no warnings, ALL tests pass (every prior subsystem + Source + fetcher + workers + admin LiveView + reader). Capture the final `N tests, 0 failures`.

- [ ] **Step 4: Manual smoke (optional)**

```powershell
docker compose up -d
docker compose logs app --tail 20
```
Signed in as `admin@verscienta.news` / `password123`: visit `/admin/sources` → add a real RSS feed (e.g. `https://hnrss.org/newest`) → "fetch now" → wait a few seconds → visit `/articles` to see imported items, open one (shows "via …" + read-original). Then `docker compose down`.

- [ ] **Step 5: Commit**

```powershell
git add -A
git commit -m "feat(aggregation): seed demo source; finalize aggregation pipeline"
```
Then `git rev-parse --short HEAD`.

---

## Definition of Done (verify all)

- [ ] An admin can add an RSS/Atom source at `/admin/sources`, click "fetch now", and see new aggregated articles in `/articles` and the category page, each linking to the original.
- [ ] Re-fetching a feed adds no duplicates (dedupe on `canonical_url`).
- [ ] Hourly Oban cron enqueues per-source fetches; `FetchSourceWorker` is unique per source.
- [ ] A failed fetch records `last_status: :error` + `last_error` and creates no articles.
- [ ] Sources are admin-only; aggregated articles have no author but always a source (validation enforced); authored articles still require an author.
- [ ] Aggregated articles show their source + read-original link in the reader.
- [ ] `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test` all pass.
- [ ] Migrations (Ash + Oban) + seeds committed on `phase-1-aggregation`.
```
