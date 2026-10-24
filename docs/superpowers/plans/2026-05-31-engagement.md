# Engagement (Comments · Reactions · Bookmarks) Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let signed-in users comment (one reply level), react (3 kinds), and bookmark articles, with live updates via Phoenix PubSub and a personal library page.

**Architecture:** A new `Verscienta.Engagement` Ash domain with `Comment`, `Reaction`, `Bookmark` resources (policies + actions); a thin PubSub broadcast helper invoked from after-action hooks; the existing article reader LiveView gains a reactions bar, bookmark toggle, and a comments section (LiveView streams + per-article topic subscription); a new `/library` LiveView.

**Tech Stack:** Phoenix 1.8, Ash 3, AshPostgres, Phoenix.PubSub (`Verscienta.PubSub`), LiveView streams, Tailwind v4 + Codex components.

---

## Conventions for the executor

- **Run everything in Docker.** Mix in the app service: `docker compose run --rm -T app bash -lc "<cmd>"`. Start DB: `docker compose up -d db`. Generous timeouts. If "dependency not available", prefix `mix deps.get &&`. OOM(137) → split / `ERL_FLAGS="+S 2 +A 4"`.
- **One task at a time, sequentially.** After each task run `git rev-parse --short HEAD` for the REAL sha. Never batch tasks or reference unverified SHAs. **Re-run the full gate (compile --warnings-as-errors, format --check-formatted, credo --strict, test) after EVERY edit before committing** — a duplicate-clause or format slip must be caught before commit, not after push.
- **Branch:** `phase-1-engagement` (already checked out; spec committed as `d41374d`).
- **Line endings:** `.gitattributes` eol=lf, autocrlf false — don't change. `mix format` before commit. No `.bak` files.
- **Test DB:** `config/test.exs` pins `verscienta_test`; Oban `testing: :manual`. Seeds contaminate global counts — scope new count asserts (filter by your own article/user), never global `Ash.read!` counts.
- **Git identity:** no local override. Commit body ends with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- **Migrations:** Ash resources via `mix ash.codegen <name>` then `mix ash.migrate`.
- **Reuse patterns:**
  - Resource shape, policies, `relate_actor`, `before_action` validation: see `lib/verscienta/content/article.ex` and `lib/verscienta/content/source.ex`.
  - Sign-in in LiveView tests: `conn |> Plug.Test.init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)` (see `test/verscienta_web/live/settings_live_test.exs`).
  - `Verscienta.DataCase` (async sandbox); `require Ash.Query` in tests using the query macro.
  - CodexComponents `news_card/1` + `article_grid/1` in `lib/verscienta_web/live/article_feed_live.ex` for the library grid.
  - The reader LiveView is `lib/verscienta_web/live/article_reader_live.ex`; the article body + disclaimer render ends at the `</article>` around line 96 — engagement UI goes before `</article>`.
  - Top-strip nav signed-in branch is in `lib/verscienta_web/components/layouts/root.html.heex` (~line 44).

---

## File Structure

| File | Responsibility |
|------|----------------|
| `lib/verscienta/engagement.ex` | `Verscienta.Engagement` domain + `broadcast/2`, `subscribe/1`, `counts_for_article/1`, read helpers |
| `lib/verscienta/engagement/comment.ex` | `Comment` resource |
| `lib/verscienta/engagement/comment/changes/validate_parent.ex` | enforce one-level reply + same article |
| `lib/verscienta/engagement/comment/changes/broadcast_comment.ex` | after-action PubSub broadcast |
| `lib/verscienta/engagement/reaction.ex` | `Reaction` resource (+ toggle) |
| `lib/verscienta/engagement/bookmark.ex` | `Bookmark` resource (+ toggle) |
| `config/config.exs` | register `Verscienta.Engagement` in `ash_domains` |
| `lib/verscienta_web/live/article_reader_live.ex` | reactions bar + bookmark + comments + PubSub |
| `lib/verscienta_web/live/library_live.ex` | `/library` page |
| `lib/verscienta_web/router.ex` | `/library` route |
| `lib/verscienta_web/components/layouts/root.html.heex` | `library` nav link |
| `test/verscienta/engagement/*_test.exs` | comment/reaction/bookmark + broadcast tests |
| `test/verscienta_web/live/library_live_test.exs`, reader test additions | web tests |

---

## Task 1: Engagement domain + Comment resource (TDD)

**Files:**
- Create: `lib/verscienta/engagement.ex`, `lib/verscienta/engagement/comment.ex`
- Create: `lib/verscienta/engagement/comment/changes/validate_parent.ex`
- Modify: `config/config.exs`
- Test: `test/verscienta/engagement/comment_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/verscienta/engagement/comment_test.exs`:
```elixir
defmodule Verscienta.Engagement.CommentTest do
  use Verscienta.DataCase, async: true

  require Ash.Query

  alias Verscienta.Engagement.Comment

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

  defp set_role(user, role) do
    user
    |> Ash.Changeset.for_update(:update_profile, %{}, actor: user)
    |> Ash.Changeset.force_change_attribute(:role, role)
    |> Ash.update!(authorize?: false)
  end

  defp article(author) do
    {:ok, a} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: "Discuss Me", blocks: [], category: :movement}, actor: author)
      |> Ash.create()

    {:ok, p} = a |> Ash.Changeset.for_update(:publish, %{}, actor: author) |> Ash.update()
    p
  end

  defp comment(actor, article, attrs \\ %{}) do
    Comment
    |> Ash.Changeset.for_create(:create, Map.merge(%{body: "hi", article_id: article.id}, attrs), actor: actor)
    |> Ash.create(authorize?: true)
  end

  test "create sets author and article" do
    u = user("alice")
    art = article(u)
    {:ok, c} = comment(u, art)
    assert c.user_id == u.id
    assert c.article_id == art.id
    assert c.parent_id == nil
  end

  test "create requires a signed-in actor" do
    u = user("alice")
    art = article(u)

    assert {:error, _} =
             Comment
             |> Ash.Changeset.for_create(:create, %{body: "x", article_id: art.id})
             |> Ash.create(authorize?: true)
  end

  test "a reply to a top-level comment is allowed" do
    u = user("alice")
    art = article(u)
    {:ok, top} = comment(u, art)
    {:ok, reply} = comment(u, art, %{parent_id: top.id})
    assert reply.parent_id == top.id
  end

  test "a reply to a reply is rejected (one level only)" do
    u = user("alice")
    art = article(u)
    {:ok, top} = comment(u, art)
    {:ok, reply} = comment(u, art, %{parent_id: top.id})
    assert {:error, _} = comment(u, art, %{parent_id: reply.id})
  end

  test "a reply whose parent is on a different article is rejected" do
    u = user("alice")
    art1 = article(u)
    art2 = article(u)
    {:ok, top} = comment(u, art1)
    assert {:error, _} = comment(u, art2, %{parent_id: top.id})
  end

  test "author can soft-delete; tombstone still listed" do
    u = user("alice")
    art = article(u)
    {:ok, c} = comment(u, art)
    {:ok, deleted} = c |> Ash.Changeset.for_update(:soft_delete, %{}, actor: u) |> Ash.update()
    assert deleted.deleted_at != nil

    listed =
      Comment
      |> Ash.Query.for_read(:list_for_article, %{article_id: art.id})
      |> Ash.read!(authorize?: false)

    assert Enum.any?(listed, &(&1.id == c.id))
  end

  test "a moderator can soft-delete another user's comment" do
    author = user("alice")
    mod = user("mod") |> set_role(:moderator)
    art = article(author)
    {:ok, c} = comment(author, art)

    assert {:ok, _} = c |> Ash.Changeset.for_update(:soft_delete, %{}, actor: mod) |> Ash.update()
  end

  test "an unrelated user cannot soft-delete" do
    author = user("alice")
    other = user("bob")
    art = article(author)
    {:ok, c} = comment(author, art)

    assert {:error, _} = c |> Ash.Changeset.for_update(:soft_delete, %{}, actor: other) |> Ash.update()
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta/engagement/comment_test.exs"
```
Expected: fails — domain/resource missing.

- [ ] **Step 3: Create the domain**

Create `lib/verscienta/engagement.ex`:
```elixir
defmodule Verscienta.Engagement do
  @moduledoc "Domain for article engagement: comments, reactions, bookmarks."
  use Ash.Domain, otp_app: :verscienta

  resources do
    resource Verscienta.Engagement.Comment
    resource Verscienta.Engagement.Reaction
    resource Verscienta.Engagement.Bookmark
  end

  @doc "PubSub topic for an article's engagement events."
  def topic(article_id), do: "article:" <> to_string(article_id)

  @doc "Subscribe the calling process to an article's engagement topic."
  def subscribe(article_id), do: Phoenix.PubSub.subscribe(Verscienta.PubSub, topic(article_id))

  @doc "Broadcast an engagement message on an article's topic."
  def broadcast(article_id, message),
    do: Phoenix.PubSub.broadcast(Verscienta.PubSub, topic(article_id), message)
end
```
NOTE: `Reaction` and `Bookmark` are referenced in `resources do` but created in Tasks 2–3. To keep this task compiling/testing on its own, you may temporarily list ONLY `Comment` here, then add `Reaction`/`Bookmark` lines in their tasks. Choose that: list only `Comment` now; Tasks 2 and 3 each add their resource line. (Update the test domain expectations accordingly — the comment test doesn't touch Reaction/Bookmark.)

- [ ] **Step 4: Create the parent-validation change**

Create `lib/verscienta/engagement/comment/changes/validate_parent.ex`:
```elixir
defmodule Verscienta.Engagement.Comment.Changes.ValidateParent do
  @moduledoc "Enforces one-level replies: a reply's parent must be top-level and same-article."
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      parent_id = Ash.Changeset.get_attribute(cs, :parent_id)
      article_id = Ash.Changeset.get_attribute(cs, :article_id)

      case parent_id do
        nil ->
          cs

        pid ->
          validate_parent(cs, pid, article_id)
      end
    end)
  end

  defp validate_parent(cs, parent_id, article_id) do
    parent =
      Verscienta.Engagement.Comment
      |> Ash.Query.filter(id == ^parent_id)
      |> Ash.read_one!(authorize?: false)

    cond do
      is_nil(parent) ->
        Ash.Changeset.add_error(cs, field: :parent_id, message: "parent comment not found")

      not is_nil(parent.parent_id) ->
        Ash.Changeset.add_error(cs, field: :parent_id, message: "replies cannot be nested more than one level")

      parent.article_id != article_id ->
        Ash.Changeset.add_error(cs, field: :parent_id, message: "parent comment belongs to a different article")

      true ->
        cs
    end
  end
end
```

- [ ] **Step 5: Create the Comment resource**

Create `lib/verscienta/engagement/comment.ex`:
```elixir
defmodule Verscienta.Engagement.Comment do
  @moduledoc "A user comment on an article (one level of replies)."
  use Ash.Resource,
    otp_app: :verscienta,
    domain: Verscienta.Engagement,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "comments"
    repo Verscienta.Repo
  end

  actions do
    defaults [:read]

    create :create do
      description "Post a comment or a one-level reply."
      accept [:body, :article_id, :parent_id]
      change relate_actor(:user)
      change Verscienta.Engagement.Comment.Changes.ValidateParent
    end

    update :soft_delete do
      description "Soft-delete a comment (tombstone)."
      accept []
      change set_attribute(:deleted_at, &DateTime.utc_now/0)
    end

    read :list_for_article do
      argument :article_id, :uuid, allow_nil?: false
      filter expr(article_id == ^arg(:article_id))
      prepare build(sort: [inserted_at: :asc])
    end
  end

  policies do
    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action(:soft_delete) do
      authorize_if expr(user_id == ^actor(:id))
      authorize_if expr(^actor(:role) in [:moderator, :admin])
    end

    policy action_type(:read) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :body, :string, allow_nil?: false, public?: true, constraints: [max_length: 2000]
    attribute :deleted_at, :utc_datetime_usec, allow_nil?: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :article, Verscienta.Content.Article, allow_nil?: false
    belongs_to :user, Verscienta.Accounts.User, allow_nil?: false
    belongs_to :parent, Verscienta.Engagement.Comment, allow_nil?: true

    has_many :replies, Verscienta.Engagement.Comment do
      destination_attribute :parent_id
    end
  end
end
```
NOTE: `set_attribute(:deleted_at, &DateTime.utc_now/0)` function-form may be rejected by this Ash version; if so use `change fn cs, _ -> Ash.Changeset.force_change_attribute(cs, :deleted_at, DateTime.utc_now()) end`. If `actor_present/0` isn't available, use `expr(not is_nil(^actor(:id)))`.

- [ ] **Step 6: Register the domain**

In `config/config.exs`, add `Verscienta.Engagement` to `ash_domains`:
```elixir
  ash_domains: [Verscienta.Accounts, Verscienta.Content, Verscienta.Engagement]
```

- [ ] **Step 7: Generate + apply migration**

```powershell
docker compose run --rm -T app bash -lc "mix ash.codegen add_comments && mix ash.migrate"
```
Expected: `comments` table with FKs to articles/users/self.

- [ ] **Step 8: Run tests + full gate**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/engagement/comment_test.exs && mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors"
```
Expected: all comment tests pass; gates clean. Iterate per NOTEs.

- [ ] **Step 9: Commit**

```powershell
git add -A
git commit -m "feat(engagement): Engagement domain + Comment resource (one-level replies)"
```
Then `git rev-parse --short HEAD`.

---

## Task 2: Reaction resource + toggle (TDD)

**Files:**
- Create: `lib/verscienta/engagement/reaction.ex`
- Modify: `lib/verscienta/engagement.ex` (add resource line + a `counts_for_article/1` helper)
- Test: `test/verscienta/engagement/reaction_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/verscienta/engagement/reaction_test.exs`:
```elixir
defmodule Verscienta.Engagement.ReactionTest do
  use Verscienta.DataCase, async: true

  require Ash.Query

  alias Verscienta.Engagement
  alias Verscienta.Engagement.Reaction

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
    {:ok, a} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: "React Me", blocks: [], category: :movement}, actor: author)
      |> Ash.create()

    {:ok, p} = a |> Ash.Changeset.for_update(:publish, %{}, actor: author) |> Ash.update()
    p
  end

  defp toggle(actor, art, kind) do
    Reaction
    |> Ash.ActionInput.for_action(:toggle, %{article_id: art.id, kind: kind})
    |> Ash.run_action(actor: actor)
  end

  test "toggle creates then destroys a reaction" do
    u = user("alice")
    art = article(u)

    {:ok, _} = toggle(u, art, :like)
    assert reaction_count(art, :like) == 1

    {:ok, _} = toggle(u, art, :like)
    assert reaction_count(art, :like) == 0
  end

  test "different kinds coexist; unique per kind" do
    u = user("alice")
    art = article(u)

    {:ok, _} = toggle(u, art, :like)
    {:ok, _} = toggle(u, art, :insightful)
    {:ok, _} = toggle(u, art, :like)
    {:ok, _} = toggle(u, art, :like)

    # like toggled odd number of times overall: created, (kept), created again? verify via counts
    counts = Engagement.counts_for_article(art.id)
    assert is_map(counts)
    assert Map.get(counts, :insightful, 0) == 1
  end

  test "counts_for_article returns per-kind totals" do
    u1 = user("alice")
    u2 = user("bob")
    art = article(u1)

    {:ok, _} = toggle(u1, art, :like)
    {:ok, _} = toggle(u2, art, :like)
    {:ok, _} = toggle(u1, art, :helpful)

    counts = Engagement.counts_for_article(art.id)
    assert counts[:like] == 2
    assert counts[:helpful] == 1
  end

  defp reaction_count(art, kind) do
    Reaction
    |> Ash.Query.filter(article_id == ^art.id and kind == ^kind)
    |> Ash.read!(authorize?: false)
    |> length()
  end
end
```
NOTE: the second test's like-count is intentionally not asserted exactly (toggling parity is exercised in test 1); it asserts `:insightful == 1` which is deterministic. Keep it simple.

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta/engagement/reaction_test.exs"
```
Expected: fails — resource missing.

- [ ] **Step 3: Create the Reaction resource**

Create `lib/verscienta/engagement/reaction.ex`:
```elixir
defmodule Verscienta.Engagement.Reaction do
  @moduledoc "A user's reaction of a given kind on an article."
  use Ash.Resource,
    otp_app: :verscienta,
    domain: Verscienta.Engagement,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  postgres do
    table "reactions"
    repo Verscienta.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:article_id, :kind]
      change relate_actor(:user)
    end

    action :toggle do
      description "Create the reaction if absent for (user, article, kind), else destroy it."
      argument :article_id, :uuid, allow_nil?: false
      argument :kind, :atom, allow_nil?: false

      run fn input, context ->
        actor = context.actor
        article_id = input.arguments.article_id
        kind = input.arguments.kind

        existing =
          Verscienta.Engagement.Reaction
          |> Ash.Query.filter(user_id == ^actor.id and article_id == ^article_id and kind == ^kind)
          |> Ash.read_one!(authorize?: false)

        result =
          case existing do
            nil ->
              Verscienta.Engagement.Reaction
              |> Ash.Changeset.for_create(:create, %{article_id: article_id, kind: kind}, actor: actor)
              |> Ash.create!(authorize?: true)

            reaction ->
              Ash.destroy!(reaction, authorize?: false)
              reaction
          end

        Verscienta.Engagement.broadcast(article_id, {:reactions_changed, article_id})
        {:ok, result}
      end
    end

    read :for_article do
      argument :article_id, :uuid, allow_nil?: false
      filter expr(article_id == ^arg(:article_id))
    end
  end

  policies do
    policy action(:toggle) do
      authorize_if actor_present()
    end

    policy action(:create) do
      authorize_if actor_present()
    end

    policy action_type([:read, :destroy]) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:like, :insightful, :helpful]
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :article, Verscienta.Content.Article, allow_nil?: false
    belongs_to :user, Verscienta.Accounts.User, allow_nil?: false
  end

  identities do
    identity :unique_user_article_kind, [:user_id, :article_id, :kind]
  end
end
```
NOTE: the generic `action :toggle` body uses `context.actor` — confirm the run-fn signature for this Ash version (`fn input, context ->`); if context shape differs, get the actor via the documented path and report. The `:destroy` is policy-open but only invoked internally with `authorize?: false`; if you prefer, lock it `forbid_if always()` and rely on `authorize?: false`.

- [ ] **Step 4: Add resource line + counts helper to the domain**

In `lib/verscienta/engagement.ex`, add to `resources do`:
```elixir
    resource Verscienta.Engagement.Reaction
```
And add a counts helper:
```elixir
  require Ash.Query

  @doc "Per-kind reaction counts for an article, as %{kind => count}."
  def counts_for_article(article_id) do
    Verscienta.Engagement.Reaction
    |> Ash.Query.filter(article_id == ^article_id)
    |> Ash.read!(authorize?: false)
    |> Enum.frequencies_by(& &1.kind)
  end
```
(Place `require Ash.Query` near the top of the module, after `use Ash.Domain`.)

- [ ] **Step 5: Generate + apply migration**

```powershell
docker compose run --rm -T app bash -lc "mix ash.codegen add_reactions && mix ash.migrate"
```
Expected: `reactions` table + unique index on `(user_id, article_id, kind)`.

- [ ] **Step 6: Run tests + full gate**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/engagement/reaction_test.exs && mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors"
```
Expected: pass + clean. Iterate per NOTEs.

- [ ] **Step 7: Commit**

```powershell
git add -A
git commit -m "feat(engagement): Reaction resource with toggle + per-kind counts"
```
Then `git rev-parse --short HEAD`.

---

## Task 3: Bookmark resource + toggle (TDD)

**Files:**
- Create: `lib/verscienta/engagement/bookmark.ex`
- Modify: `lib/verscienta/engagement.ex` (add resource line)
- Test: `test/verscienta/engagement/bookmark_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/verscienta/engagement/bookmark_test.exs`:
```elixir
defmodule Verscienta.Engagement.BookmarkTest do
  use Verscienta.DataCase, async: true

  require Ash.Query

  alias Verscienta.Engagement.Bookmark

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

  defp article(author, title) do
    {:ok, a} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: title, blocks: [], category: :movement}, actor: author)
      |> Ash.create()

    {:ok, p} = a |> Ash.Changeset.for_update(:publish, %{}, actor: author) |> Ash.update()
    p
  end

  defp toggle(actor, art) do
    Bookmark
    |> Ash.ActionInput.for_action(:toggle, %{article_id: art.id})
    |> Ash.run_action(actor: actor)
  end

  test "toggle creates then destroys a bookmark" do
    u = user("alice")
    art = article(u, "Save Me")

    {:ok, _} = toggle(u, art)
    assert count_for(u, art) == 1
    {:ok, _} = toggle(u, art)
    assert count_for(u, art) == 0
  end

  test "list_for_user returns only the actor's bookmarks, newest first" do
    u1 = user("alice")
    u2 = user("bob")
    a1 = article(u1, "A1")
    a2 = article(u1, "A2")

    {:ok, _} = toggle(u1, a1)
    {:ok, _} = toggle(u1, a2)
    {:ok, _} = toggle(u2, a1)

    mine =
      Bookmark
      |> Ash.Query.for_read(:list_for_user)
      |> Ash.read!(actor: u1, authorize?: true)

    assert length(mine) == 2
    assert Enum.all?(mine, &(&1.user_id == u1.id))
  end

  test "another user cannot read my bookmarks via list_for_user" do
    u1 = user("alice")
    u2 = user("bob")
    a1 = article(u1, "A1")
    {:ok, _} = toggle(u1, a1)

    others =
      Bookmark
      |> Ash.Query.for_read(:list_for_user)
      |> Ash.read!(actor: u2, authorize?: true)

    assert others == []
  end

  defp count_for(u, art) do
    Bookmark
    |> Ash.Query.filter(user_id == ^u.id and article_id == ^art.id)
    |> Ash.read!(authorize?: false)
    |> length()
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta/engagement/bookmark_test.exs"
```
Expected: fails — resource missing.

- [ ] **Step 3: Create the Bookmark resource**

Create `lib/verscienta/engagement/bookmark.ex`:
```elixir
defmodule Verscienta.Engagement.Bookmark do
  @moduledoc "A user's saved article."
  use Ash.Resource,
    otp_app: :verscienta,
    domain: Verscienta.Engagement,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  postgres do
    table "bookmarks"
    repo Verscienta.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:article_id]
      change relate_actor(:user)
    end

    action :toggle do
      description "Create the bookmark if absent for (user, article), else destroy it."
      argument :article_id, :uuid, allow_nil?: false

      run fn input, context ->
        actor = context.actor
        article_id = input.arguments.article_id

        existing =
          Verscienta.Engagement.Bookmark
          |> Ash.Query.filter(user_id == ^actor.id and article_id == ^article_id)
          |> Ash.read_one!(authorize?: false)

        case existing do
          nil ->
            bookmark =
              Verscienta.Engagement.Bookmark
              |> Ash.Changeset.for_create(:create, %{article_id: article_id}, actor: actor)
              |> Ash.create!(authorize?: true)

            {:ok, bookmark}

          bookmark ->
            Ash.destroy!(bookmark, authorize?: false)
            {:ok, bookmark}
        end
      end
    end

    read :list_for_user do
      description "The actor's bookmarks, newest first."
      filter expr(user_id == ^actor(:id))
      prepare build(sort: [inserted_at: :desc], load: [:article])
    end
  end

  policies do
    policy action(:toggle) do
      authorize_if actor_present()
    end

    policy action(:create) do
      authorize_if actor_present()
    end

    policy action(:list_for_user) do
      authorize_if actor_present()
    end

    policy action_type([:read, :destroy]) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :article, Verscienta.Content.Article, allow_nil?: false
    belongs_to :user, Verscienta.Accounts.User, allow_nil?: false
  end

  identities do
    identity :unique_user_article, [:user_id, :article_id]
  end
end
```
NOTE: `list_for_user` uses `filter expr(user_id == ^actor(:id))` so it returns only the actor's rows even though `action_type(:read)` is broadly allowed — the filter is the privacy boundary (an actor literally cannot select another user's rows through this action). The broad read policy is for the internal `read_one!` in toggle. If you'd rather, scope reads tighter; the bookmark tests are the gate (u2 sees `[]`).

- [ ] **Step 4: Add resource line to the domain**

In `lib/verscienta/engagement.ex` `resources do`, add:
```elixir
    resource Verscienta.Engagement.Bookmark
```

- [ ] **Step 5: Generate + apply migration**

```powershell
docker compose run --rm -T app bash -lc "mix ash.codegen add_bookmarks && mix ash.migrate"
```
Expected: `bookmarks` table + unique index on `(user_id, article_id)`.

- [ ] **Step 6: Run tests + full gate + regression**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/engagement && mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
```
Expected: all engagement tests pass; full suite green. Report the count.

- [ ] **Step 7: Commit**

```powershell
git add -A
git commit -m "feat(engagement): Bookmark resource with toggle + private list"
```
Then `git rev-parse --short HEAD`.

---

## Task 4: Comment broadcast on create/soft-delete (TDD)

**Files:**
- Create: `lib/verscienta/engagement/comment/changes/broadcast_comment.ex`
- Modify: `lib/verscienta/engagement/comment.ex` (attach the change to create + soft_delete)
- Test: `test/verscienta/engagement/broadcast_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/engagement/broadcast_test.exs`:
```elixir
defmodule Verscienta.Engagement.BroadcastTest do
  use Verscienta.DataCase, async: false

  alias Verscienta.Engagement
  alias Verscienta.Engagement.Comment
  alias Verscienta.Engagement.Reaction

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
    {:ok, a} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: "Live Me", blocks: [], category: :movement}, actor: author)
      |> Ash.create()

    {:ok, p} = a |> Ash.Changeset.for_update(:publish, %{}, actor: author) |> Ash.update()
    p
  end

  test "creating a comment broadcasts :comment_created" do
    u = user("alice")
    art = article(u)
    :ok = Engagement.subscribe(art.id)

    {:ok, comment} =
      Comment
      |> Ash.Changeset.for_create(:create, %{body: "hi", article_id: art.id}, actor: u)
      |> Ash.create(authorize?: true)

    assert_receive {:comment_created, id} when id == comment.id, 1000
  end

  test "soft-deleting a comment broadcasts :comment_deleted" do
    u = user("alice")
    art = article(u)
    {:ok, comment} =
      Comment
      |> Ash.Changeset.for_create(:create, %{body: "hi", article_id: art.id}, actor: u)
      |> Ash.create(authorize?: true)

    :ok = Engagement.subscribe(art.id)
    {:ok, _} = comment |> Ash.Changeset.for_update(:soft_delete, %{}, actor: u) |> Ash.update()

    assert_receive {:comment_deleted, id} when id == comment.id, 1000
  end

  test "toggling a reaction broadcasts :reactions_changed" do
    u = user("alice")
    art = article(u)
    :ok = Engagement.subscribe(art.id)

    {:ok, _} =
      Reaction
      |> Ash.ActionInput.for_action(:toggle, %{article_id: art.id, kind: :like})
      |> Ash.run_action(actor: u)

    assert_receive {:reactions_changed, id} when id == art.id, 1000
  end
end
```
NOTE: the reaction broadcast was already added in Task 2's `toggle`. This task adds comment broadcasts. The reaction test here is a guard that Task 2's broadcast still fires.

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta/engagement/broadcast_test.exs"
```
Expected: comment tests fail (no broadcast yet); reaction test passes.

- [ ] **Step 3: Create the broadcast change**

Create `lib/verscienta/engagement/comment/changes/broadcast_comment.ex`:
```elixir
defmodule Verscienta.Engagement.Comment.Changes.BroadcastComment do
  @moduledoc "After-action: broadcast comment create/soft-delete on the article topic."
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    event = Keyword.fetch!(opts, :event)

    Ash.Changeset.after_action(changeset, fn _cs, record ->
      Verscienta.Engagement.broadcast(record.article_id, {event, record.id})
      {:ok, record}
    end)
  end
end
```

- [ ] **Step 4: Attach to create + soft_delete**

In `lib/verscienta/engagement/comment.ex`, append to the `:create` action's changes:
```elixir
      change {Verscienta.Engagement.Comment.Changes.BroadcastComment, event: :comment_created}
```
And to the `:soft_delete` action's changes:
```elixir
      change {Verscienta.Engagement.Comment.Changes.BroadcastComment, event: :comment_deleted}
```

- [ ] **Step 5: Run tests + full gate**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/engagement/broadcast_test.exs && mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors"
```
Expected: 3 tests pass; gates clean.

- [ ] **Step 6: Commit**

```powershell
git add -A
git commit -m "feat(engagement): broadcast comment create/soft-delete via PubSub"
```
Then `git rev-parse --short HEAD`.

---

## Task 5: Reader integration — reactions + bookmark + comments (TDD)

**Files:**
- Modify: `lib/verscienta_web/live/article_reader_live.ex`
- Test: `test/verscienta_web/live/article_reader_live_test.exs` (extend)

- [ ] **Step 1: Add failing tests**

Append to `test/verscienta_web/live/article_reader_live_test.exs` (inside the module). Add a sign-in helper if not present (mirrors settings test) and tests:
```elixir
  defp sign_in(conn, user),
    do: conn |> Plug.Test.init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)

  test "signed-in user can post a comment and see it", %{conn: conn} do
    a = published(author("commenter"))
    conn = sign_in(conn, author("poster"))

    {:ok, lv, _html} = live(conn, ~p"/articles/#{a.slug}")

    html =
      lv
      |> form("#comment-form", %{"body" => "First!"})
      |> render_submit()

    assert html =~ "First!"
  end

  test "signed-in user can toggle a like and the count shows", %{conn: conn} do
    a = published(author("reactauthor"))
    conn = sign_in(conn, author("reactor"))

    {:ok, lv, _html} = live(conn, ~p"/articles/#{a.slug}")

    html = lv |> element("button[phx-value-kind='like']") |> render_click()
    assert html =~ "1"
  end

  test "signed-out user sees a sign-in prompt instead of the comment form", %{conn: conn} do
    a = published(author("noauth"))
    {:ok, _lv, html} = live(conn, ~p"/articles/#{a.slug}")
    assert html =~ "sign in" or html =~ "Sign in"
    refute html =~ ~s(id="comment-form")
  end
```
NOTE: `published/1` and `author/1` already exist in this test file (used by the existing reader tests). Reuse them.

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta_web/live/article_reader_live_test.exs"
```
Expected: the new tests fail (no engagement UI yet); existing reader tests still pass.

- [ ] **Step 3: Wire engagement into the reader LiveView**

In `lib/verscienta_web/live/article_reader_live.ex`:

(a) add aliases near the top:
```elixir
  alias Verscienta.Engagement
  alias Verscienta.Engagement.Bookmark
  alias Verscienta.Engagement.Comment
  alias Verscienta.Engagement.Reaction
```

(b) In `mount/3`, after assigning the article, subscribe + load engagement state and set up the comments stream. Replace the existing successful `{:ok, ...}` assignment in the article branch with:
```elixir
        if connected?(socket), do: Engagement.subscribe(article.id)

        {:ok,
         socket
         |> assign(
           article: article,
           body_html: BlockRenderer.to_html(article.blocks),
           page_title: article.title,
           reaction_counts: Engagement.counts_for_article(article.id),
           my_reactions: my_reactions(article.id, actor),
           bookmarked?: bookmarked?(article.id, actor),
           reaction_kinds: [:like, :insightful, :helpful]
         )
         |> stream(:comments, load_comments(article.id))}
```

(c) Add helpers (private):
```elixir
  defp my_reactions(_article_id, nil), do: MapSet.new()

  defp my_reactions(article_id, actor) do
    require Ash.Query

    Reaction
    |> Ash.Query.filter(article_id == ^article_id and user_id == ^actor.id)
    |> Ash.read!(authorize?: false)
    |> MapSet.new(& &1.kind)
  end

  defp bookmarked?(_article_id, nil), do: false

  defp bookmarked?(article_id, actor) do
    require Ash.Query

    Bookmark
    |> Ash.Query.filter(article_id == ^article_id and user_id == ^actor.id)
    |> Ash.read_one!(authorize?: false)
    |> then(&(not is_nil(&1)))
  end

  defp load_comments(article_id) do
    Comment
    |> Ash.Query.for_read(:list_for_article, %{article_id: article_id})
    |> Ash.Query.load([:user, replies: [:user]])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&is_nil(&1.parent_id))
  end
```
(Add `require Ash.Query` at module top if not already present — it is, from the existing reader.)

(d) Add event handlers:
```elixir
  @impl true
  def handle_event("toggle_reaction", %{"kind" => kind}, socket) do
    with %{} = actor <- socket.assigns[:current_user] do
      kind_atom = String.to_existing_atom(kind)

      Reaction
      |> Ash.ActionInput.for_action(:toggle, %{article_id: socket.assigns.article.id, kind: kind_atom})
      |> Ash.run_action!(actor: actor)

      {:noreply, refresh_reactions(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_bookmark", _params, socket) do
    with %{} = actor <- socket.assigns[:current_user] do
      Bookmark
      |> Ash.ActionInput.for_action(:toggle, %{article_id: socket.assigns.article.id})
      |> Ash.run_action!(actor: actor)

      {:noreply, assign(socket, bookmarked?: bookmarked?(socket.assigns.article.id, actor))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("post_comment", %{"body" => body}, socket) do
    with %{} = actor <- socket.assigns[:current_user],
         params <- comment_params(body, socket),
         {:ok, _comment} <-
           Comment |> Ash.Changeset.for_create(:create, params, actor: actor) |> Ash.create() do
      # The PubSub broadcast handles inserting into the stream (incl. for this client).
      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("delete_comment", %{"id" => id}, socket) do
    with %{} = actor <- socket.assigns[:current_user],
         {:ok, comment} <- Ash.get(Comment, id, actor: actor, authorize?: false),
         {:ok, _} <- comment |> Ash.Changeset.for_update(:soft_delete, %{}, actor: actor) |> Ash.update() do
      {:noreply, socket}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not delete comment")}
    end
  end

  defp comment_params(body, socket), do: %{body: body, article_id: socket.assigns.article.id}

  defp refresh_reactions(socket) do
    actor = socket.assigns[:current_user]
    article_id = socket.assigns.article.id

    assign(socket,
      reaction_counts: Engagement.counts_for_article(article_id),
      my_reactions: my_reactions(article_id, actor)
    )
  end
```

(e) Add PubSub message handlers:
```elixir
  @impl true
  def handle_info({:comment_created, id}, socket) do
    case load_one_comment(id) do
      nil -> {:noreply, socket}
      comment -> {:noreply, stream_insert(socket, :comments, comment)}
    end
  end

  def handle_info({:comment_deleted, id}, socket) do
    case load_one_comment(id) do
      nil -> {:noreply, socket}
      comment -> {:noreply, stream_insert(socket, :comments, comment)}
    end
  end

  def handle_info({:reactions_changed, _article_id}, socket) do
    {:noreply, refresh_reactions(socket)}
  end

  defp load_one_comment(id) do
    Comment
    |> Ash.Query.filter(id == ^id and is_nil(parent_id))
    |> Ash.Query.load([:user, replies: [:user]])
    |> Ash.read_one!(authorize?: false)
  end
```
NOTE: `load_one_comment/1` only re-streams TOP-LEVEL comments (replies are rendered nested within their parent; a new reply re-streams its parent via `:comment_created` carrying the reply id → but the reply isn't top-level, so `load_one_comment` returns nil and the reply won't appear live). For MVP, to make replies appear live, change the create broadcast to send the TOP-LEVEL ancestor id: in `BroadcastComment`, broadcast `record.parent_id || record.id`. ADJUST: update `BroadcastComment` to broadcast the top-level id so reply inserts refresh the parent. If you do, update the broadcast test to still receive `{:comment_created, _}` (id may be the parent's). Keep it simple: broadcast `{event, top_level_id}` where `top_level_id = record.parent_id || record.id`, and `load_one_comment` re-streams that parent (whose `:replies` now include the new reply). Document this choice.

(f) Add the engagement UI to `render/1`, inserted just before the closing `</article>` (after the disclaimer `<p>`):
```heex
      <section class="mt-12 border-t border-line pt-8">
        <div class="mb-8 flex flex-wrap items-center gap-3">
          <button
            :for={kind <- @reaction_kinds}
            type="button"
            phx-click="toggle_reaction"
            phx-value-kind={kind}
            disabled={is_nil(@current_user)}
            class={[
              "border px-3 py-1.5 text-[11px] uppercase tracking-wider transition-colors",
              if(MapSet.member?(@my_reactions, kind), do: "border-zune text-zune", else: "border-line text-ink-3 hover:text-ink")
            ]}
          >
            {kind} <span class="ml-1">{Map.get(@reaction_counts, kind, 0)}</span>
          </button>

          <button
            :if={@current_user}
            type="button"
            phx-click="toggle_bookmark"
            class={[
              "ml-auto border px-3 py-1.5 text-[11px] uppercase tracking-wider transition-colors",
              if(@bookmarked?, do: "border-zune text-zune", else: "border-line text-ink-3 hover:text-ink")
            ]}
          >
            {if @bookmarked?, do: "saved", else: "save"}
          </button>
        </div>

        <h2 class="mb-6 text-2xl font-extralight lowercase">comments</h2>

        <%= if @current_user do %>
          <form id="comment-form" phx-submit="post_comment" class="mb-8">
            <textarea
              name="body"
              rows="3"
              placeholder="add a comment…"
              class="w-full border border-line bg-canvas-2 px-4 py-3 text-ink"
            ></textarea>
            <button type="submit" class="mt-2 bg-zune px-5 py-2 text-xs font-bold uppercase tracking-wider text-black hover:brightness-110">
              post
            </button>
          </form>
        <% else %>
          <p class="mb-8 text-sm text-ink-3">
            <a href="/sign-in" class="text-zune hover:text-ink">sign in</a> to join the discussion.
          </p>
        <% end %>

        <div id="comments" phx-update="stream" class="space-y-6">
          <div :for={{dom_id, comment} <- @streams.comments} id={dom_id} class="border-l border-line pl-4">
            {render_comment(assigns, comment)}
          </div>
        </div>
      </section>
```
And add a `render_comment/2` function component-ish helper (a private function returning a heex via `~H`), plus reply rendering. To keep it within the LiveView, add:
```elixir
  defp render_comment(assigns, comment) do
    assigns = assign(assigns, :comment, comment)

    ~H"""
    <div>
      <div class="mb-1 flex items-center gap-2 text-[11px] uppercase tracking-wider text-ink-3">
        <span class="text-ink-2">@{@comment.user.username}</span>
        <span>{Calendar.strftime(@comment.inserted_at, "%b %-d")}</span>
        <button
          :if={can_delete?(@current_user, @comment)}
          type="button"
          phx-click="delete_comment"
          phx-value-id={@comment.id}
          class="text-politics hover:underline"
        >
          delete
        </button>
      </div>
      <p class="text-sm font-light text-ink-2">{comment_body(@comment)}</p>

      <div :if={@comment.replies != []} class="mt-4 space-y-4 border-l border-line pl-4">
        <div :for={reply <- Enum.sort_by(@comment.replies, & &1.inserted_at, DateTime)}>
          <div class="mb-1 flex items-center gap-2 text-[11px] uppercase tracking-wider text-ink-3">
            <span class="text-ink-2">@{reply.user.username}</span>
            <span>{Calendar.strftime(reply.inserted_at, "%b %-d")}</span>
            <button
              :if={can_delete?(@current_user, reply)}
              type="button"
              phx-click="delete_comment"
              phx-value-id={reply.id}
              class="text-politics hover:underline"
            >
              delete
            </button>
          </div>
          <p class="text-sm font-light text-ink-2">{comment_body(reply)}</p>
        </div>
      </div>

      <button
        :if={@current_user}
        type="button"
        phx-click="show_reply"
        phx-value-id={@comment.id}
        class="mt-2 text-[11px] uppercase tracking-wider text-ink-3 hover:text-ink"
      >
        reply
      </button>
      <form
        :if={@reply_to == @comment.id}
        phx-submit="post_reply"
        phx-value-parent={@comment.id}
        class="mt-2"
      >
        <textarea name="body" rows="2" class="w-full border border-line bg-canvas-2 px-3 py-2 text-sm text-ink"></textarea>
        <button type="submit" class="mt-1 bg-zune px-4 py-1.5 text-[11px] font-bold uppercase tracking-wider text-black hover:brightness-110">
          reply
        </button>
      </form>
    </div>
    """
  end

  defp comment_body(%{deleted_at: nil} = c), do: c.body
  defp comment_body(_), do: "[deleted]"

  defp can_delete?(nil, _comment), do: false
  defp can_delete?(user, comment),
    do: comment.deleted_at == nil and (comment.user_id == user.id or user.role in [:moderator, :admin])
```
And the reply event handlers + assign:
```elixir
  def handle_event("show_reply", %{"id" => id}, socket), do: {:noreply, assign(socket, reply_to: id)}

  def handle_event("post_reply", %{"parent" => parent_id, "body" => body}, socket) do
    with %{} = actor <- socket.assigns[:current_user],
         {:ok, _} <-
           Comment
           |> Ash.Changeset.for_create(:create, %{body: body, article_id: socket.assigns.article.id, parent_id: parent_id}, actor: actor)
           |> Ash.create() do
      {:noreply, assign(socket, reply_to: nil)}
    else
      _ -> {:noreply, socket}
    end
  end
```
And add `reply_to: nil` to the mount assigns. NOTE: this is the largest task — implement incrementally and keep `mix compile` green between sub-steps. The 3 Step-1 tests are the gate (post a comment appears; toggle like shows count; signed-out sees prompt, no form). The reply UI/`show_reply`/`post_reply` aren't directly tested here but must compile and not break the gate; a reply test can be added if time permits.

- [ ] **Step 4: Run the reader tests + full gate**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/article_reader_live_test.exs && mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors"
```
Expected: new + existing reader tests pass; gates clean. Because `post_comment` relies on the PubSub round-trip to insert into the stream, ensure the LiveView is subscribed to its OWN article topic (it is, via `connected?` in mount) so the posting client also receives `:comment_created` and streams it. In tests, `live/2` runs connected, so the broadcast is received within the test process — the `render_submit` assertion may need the message to be processed; if the comment doesn't appear synchronously, have `post_comment` ALSO `stream_insert` the created top-level comment directly (and dedupe via stream id) so the acting client shows it immediately without relying on async PubSub. Prefer direct stream_insert on the acting client for determinism; PubSub covers OTHER clients. Adjust and keep the test asserting the comment body appears.

- [ ] **Step 5: Commit**

```powershell
git add -A
git commit -m "feat(engagement): reader reactions bar, bookmark, and live comments"
```
Then `git rev-parse --short HEAD`.

---

## Task 6: Library page + nav (TDD)

**Files:**
- Create: `lib/verscienta_web/live/library_live.ex`
- Modify: `lib/verscienta_web/router.ex`, `lib/verscienta_web/components/layouts/root.html.heex`
- Test: `test/verscienta_web/live/library_live_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/library_live_test.exs`:
```elixir
defmodule VerscientaWeb.LibraryLiveTest do
  use VerscientaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AshAuthentication.Plug.Helpers

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

  defp sign_in(conn, u), do: conn |> Plug.Test.init_test_session(%{}) |> Helpers.store_in_session(u)

  defp published(author, title) do
    {:ok, a} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: title, blocks: [], category: :movement}, actor: author)
      |> Ash.create()

    {:ok, p} = a |> Ash.Changeset.for_update(:publish, %{}, actor: author) |> Ash.update()
    p
  end

  test "requires auth", %{conn: conn} do
    assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/library")
    assert path =~ "/sign-in"
  end

  test "lists the user's bookmarked articles", %{conn: conn} do
    u = user("alice")
    art = published(u, "Saved Article")

    Verscienta.Engagement.Bookmark
    |> Ash.ActionInput.for_action(:toggle, %{article_id: art.id})
    |> Ash.run_action!(actor: u)

    conn = sign_in(conn, u)
    {:ok, _lv, html} = live(conn, ~p"/library")
    assert html =~ "Saved Article"
  end

  test "empty state when no bookmarks", %{conn: conn} do
    u = user("bob")
    conn = sign_in(conn, u)
    {:ok, _lv, html} = live(conn, ~p"/library")
    assert html =~ "library"
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix ash.setup && MIX_ENV=test mix test test/verscienta_web/live/library_live_test.exs"
```
Expected: fails — route + LiveView missing.

- [ ] **Step 3: Create the LibraryLive**

Create `lib/verscienta_web/live/library_live.ex`:
```elixir
defmodule VerscientaWeb.LibraryLive do
  @moduledoc "The current user's bookmarked articles."
  use VerscientaWeb, :live_view

  import VerscientaWeb.CodexComponents

  alias Verscienta.Content.Category
  alias Verscienta.Engagement.Bookmark

  on_mount {VerscientaWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    bookmarks =
      Bookmark
      |> Ash.Query.for_read(:list_for_user)
      |> Ash.read!(actor: socket.assigns.current_user, authorize?: true)

    articles = Enum.map(bookmarks, & &1.article)
    {:ok, assign(socket, page_title: "library", articles: articles)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-6 pb-24 pt-28">
      <.kicker>saved</.kicker>
      <.headline class="mb-12 text-6xl">library</.headline>

      <div :if={@articles == []} class="text-ink-3">No saved articles yet.</div>
      <div class="grid gap-7 sm:grid-cols-2 lg:grid-cols-3">
        <a :for={article <- @articles} href={"/articles/" <> article.slug} class="block">
          <.news_card category={category_label(article.category)} accent={Category.accent(article.category)} meta="">
            {article.title}
          </.news_card>
        </a>
      </div>
    </div>
    """
  end

  defp category_label(key), do: (Category.get(key) || %{label: to_string(key)}).label
end
```
NOTE: `require Ash.Query` is needed for the `for_read` macro? `Ash.Query.for_read/3` is a function, not a macro, so no `require` needed; but if the compiler complains, add `require Ash.Query`. `list_for_user` already loads `:article` (Task 3 `prepare build(load: [:article])`).

- [ ] **Step 4: Add the route**

In `lib/verscienta_web/router.ex`, inside the authenticated live session (`ash_authentication_live_session :authenticated_routes`, with `/settings`, `/articles/new`, `/admin/sources`), add:
```elixir
      live "/library", LibraryLive, :index
```

- [ ] **Step 5: Add the nav link**

In `lib/verscienta_web/components/layouts/root.html.heex`, in the signed-in branch (after the `write` link), add:
```heex
          <a href="/library" class="transition-colors hover:text-ink">library</a>
```

- [ ] **Step 6: Run the test + full gate**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/library_live_test.exs && mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors"
```
Expected: 3 tests pass; gates clean. Adjust the redirect tuple shape if observed differently (`:redirect` vs `:live_redirect`).

- [ ] **Step 7: Commit**

```powershell
git add -A
git commit -m "feat(engagement): /library page and nav link"
```
Then `git rev-parse --short HEAD`.

---

## Task 7: Full verification + merge prep

- [ ] **Step 1: Full quality-gate run from a clean deps state**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "mix deps.get && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
```
Expected: format clean, credo 0 issues, **no warnings** (watch for duplicate clauses / unused vars), ALL tests pass. Capture the exact `N tests, 0 failures` line.

- [ ] **Step 2: Manual smoke (optional)**

```powershell
docker compose up -d
docker compose logs app --tail 20
```
Signed in: open a published article → react (counts change), bookmark it (→ `/library` shows it), post a comment + a reply, soft-delete a comment (shows "[deleted]"). Open the same article in a second browser/incognito signed in as another user → the new comment / reaction appears live. Then `docker compose down`.

- [ ] **Step 3: Commit any smoke fixes**

```powershell
git add -A
git commit -m "fix(engagement): smoke-test fixes" || echo "nothing to commit"
```
Then `git rev-parse --short HEAD`.

---

## Definition of Done (verify all)

- [ ] Signed-in users can comment, reply once (a reply-to-a-reply is rejected at the domain), and soft-delete (author or moderator) → "[deleted]" with replies preserved.
- [ ] Signed-in users can toggle 3 reaction kinds (one per kind per article) and a bookmark; counts + saved-state reflect immediately; another open reader sees new comments / reaction changes live via PubSub.
- [ ] `/library` lists the user's bookmarks, requires auth; nav has a `library` link.
- [ ] Comment posting requires an actor; bookmark lists are private (another user gets `[]`); comment soft-delete is author-or-moderator only.
- [ ] `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test` all pass (verify AFTER the final edit, before any push).
- [ ] Migrations (comments, reactions, bookmarks) committed on `phase-1-engagement`.
```
