# Moderation & Trust — Slice 1 Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Authenticated users can report comments, articles, user profiles, and room messages; moderators review a queue and resolve each subject by dismissing, removing content, warning, or suspending — every action recorded durably.

**Architecture:** A new `Verscienta.Moderation` domain with two Ash resources — `Flag` (polymorphic via `subject_type` + `subject_id`, with snapshotted `subject_excerpt`/`subject_author_id`) and `Action` (durable audit record). A `Moderation.Subject` helper centralizes the polymorphic dispatch (snapshot + remove). A `Moderation.resolve/5` domain function orchestrates resolution: perform the side effect, mark all pending flags for the subject resolved, write an `Action`. Minimal user suspension (`User.suspended_until`) is enforced on the two highest-volume create actions. A `ReportDialog` live_component drives reporting; `AdminModerationLive` (behind a new `mod_required` plug) is the moderator queue.

**Tech Stack:** Elixir, Phoenix LiveView, Ash 3 + AshPostgres, Oban (not needed this slice), Tailwind v4 Codex components. Migrations via `mix ash.codegen <name>`.

**Conventions (verified against codebase):**
- Migrations: run `docker compose run --rm app bash -lc "mix ash.codegen <name>"` (or `mix ash.codegen <name>` if running natively). This generates the migration from resource snapshots — do NOT hand-write migrations.
- Run a single test: `mix test path/to/test.exs:LINE`.
- Resource tests use `Verscienta.DataCase`; LiveView tests use `VerscientaWeb.ConnCase` + `import Phoenix.LiveViewTest`.
- Role is set in tests via `Ash.Changeset.force_change_attribute(:role, role)` under `update_profile`.
- Commit after each task. End commit messages with the Co-Authored-By trailer used in this repo.

---

## File Structure

**Create:**
- `lib/verscienta/moderation.ex` — domain + public API (`pending_groups/0`, `resolve/5`).
- `lib/verscienta/moderation/flag.ex` — `Flag` resource.
- `lib/verscienta/moderation/action.ex` — `Action` resource.
- `lib/verscienta/moderation/subject.ex` — polymorphic snapshot + remove dispatch.
- `lib/verscienta/moderation/flag/changes/capture_subject.ex` — report-time snapshot + self-report guard.
- `lib/verscienta/moderation/changes/reject_if_suspended.ex` — suspension enforcement change.
- `lib/verscienta_web/live/admin_moderation_live.ex` — moderator queue/dashboard.
- `lib/verscienta_web/components/report_dialog.ex` — `ReportDialog` live_component + `report_button/1` function component.
- Test files mirroring each (paths given per task).

**Modify:**
- `config/config.exs` — register the `Verscienta.Moderation` domain in `ash_domains`.
- `lib/verscienta/accounts/user.ex` — add `suspended_until` + `:suspend`/`:unsuspend` actions.
- `lib/verscienta/engagement/comment.ex` — add `RejectIfSuspended` change to `:create`.
- `lib/verscienta/communities/message.ex` — add `RejectIfSuspended` change to `:post`.
- `lib/verscienta_web/router.ex` — `mod_required` plug + `:mod` pipeline + `/admin/moderation` route.
- `lib/verscienta_web/live/article_reader_live.ex` — report affordance on comments + article.
- `lib/verscienta_web/live/profile_live.ex` — report affordance on profile.
- `lib/verscienta_web/live/room_live.ex` — report affordance on room messages.
- `lib/verscienta_web/components/layouts.ex` (or nav component) — moderator nav entry.
- `docs/todo.md` — check off items 1 and 3.

---

## Task 1: Register the Moderation domain (empty)

**Files:**
- Modify: `config/config.exs`
- Create: `lib/verscienta/moderation.ex`

- [ ] **Step 1: Find the ash_domains config**

Run: `grep -n "ash_domains" config/config.exs`
Expected: a line listing existing domains (e.g. `config :verscienta, ash_domains: [Verscienta.Accounts, ...]`).

- [ ] **Step 2: Add the Moderation domain to the list**

Add `Verscienta.Moderation` to the `ash_domains` list in `config/config.exs` (alongside the existing entries).

- [ ] **Step 3: Create the domain module**

Create `lib/verscienta/moderation.ex`:

```elixir
defmodule Verscienta.Moderation do
  @moduledoc """
  Community reporting + human moderation. Polymorphic `Flag` records reference
  any reportable subject (comment/article/user/room_message); `Action` records
  form the durable moderation audit trail.
  """
  use Ash.Domain, otp_app: :verscienta

  require Ash.Query

  resources do
    resource Verscienta.Moderation.Flag
    resource Verscienta.Moderation.Action
  end
end
```

- [ ] **Step 4: Verify it compiles (resources don't exist yet — expect failure)**

Run: `mix compile`
Expected: FAIL — `Verscienta.Moderation.Flag is not a module`. This is expected; Task 2 creates it. Do NOT commit yet; proceed to Task 2 and commit them together.

---

## Task 2: `Moderation.Flag` resource + `report` action + snapshot change

**Files:**
- Create: `lib/verscienta/moderation/subject.ex`
- Create: `lib/verscienta/moderation/flag/changes/capture_subject.ex`
- Create: `lib/verscienta/moderation/flag.ex`
- Create: `lib/verscienta/moderation/action.ex` (minimal, so the domain compiles)
- Test: `test/verscienta/moderation/flag_test.exs`

- [ ] **Step 1: Create the polymorphic Subject helper**

Create `lib/verscienta/moderation/subject.ex`:

```elixir
defmodule Verscienta.Moderation.Subject do
  @moduledoc """
  Polymorphic dispatch for moderation subjects. Resolves a `{subject_type,
  subject_id}` pair to a display snapshot + offending author, and performs the
  type-appropriate content removal. Best-effort: missing records return `:error`
  (snapshot) or `:ok` (remove no-op) rather than raising.
  """
  alias Verscienta.Accounts.User
  alias Verscienta.Communities.Message
  alias Verscienta.Content.Article
  alias Verscienta.Engagement.Comment

  @excerpt_limit 200

  @type subject_type :: :comment | :article | :user | :room_message

  @doc "Return `{excerpt, author_id}` for a subject, or `:error` if it can't be loaded."
  @spec snapshot(subject_type, Ecto.UUID.t()) :: {String.t(), Ecto.UUID.t() | nil} | :error
  def snapshot(:comment, id) do
    case Ash.get(Comment, id, authorize?: false) do
      {:ok, c} -> {excerpt(c.body), c.user_id}
      _ -> :error
    end
  end

  def snapshot(:article, id) do
    case Ash.get(Article, id, authorize?: false) do
      {:ok, a} -> {excerpt(a.title), a.author_id}
      _ -> :error
    end
  end

  def snapshot(:room_message, id) do
    case Ash.get(Message, id, authorize?: false) do
      {:ok, m} -> {excerpt(m.body), m.user_id}
      _ -> :error
    end
  end

  def snapshot(:user, id) do
    case Ash.get(User, id, authorize?: false) do
      {:ok, u} -> {excerpt("@#{u.username} — #{u.bio}"), u.id}
      _ -> :error
    end
  end

  def snapshot(_, _), do: :error

  @doc "Remove/hide the subject's content. No-op for `:user` (nothing to remove). Best-effort."
  @spec remove(subject_type, Ecto.UUID.t()) :: :ok
  def remove(:comment, id), do: do_update(Comment, id, :soft_delete)
  def remove(:room_message, id), do: do_update(Message, id, :soft_delete)
  def remove(:article, id), do: do_update(Article, id, :archive)
  def remove(:user, _id), do: :ok
  def remove(_, _), do: :ok

  defp do_update(resource, id, action) do
    with {:ok, record} <- Ash.get(resource, id, authorize?: false),
         {:ok, _} <- record |> Ash.Changeset.for_update(action, %{}) |> Ash.update(authorize?: false) do
      :ok
    else
      _ -> :ok
    end
  end

  defp excerpt(nil), do: ""
  defp excerpt(text), do: text |> to_string() |> String.slice(0, @excerpt_limit)
end
```

- [ ] **Step 2: Create the CaptureSubject change**

Create `lib/verscienta/moderation/flag/changes/capture_subject.ex`:

```elixir
defmodule Verscienta.Moderation.Flag.Changes.CaptureSubject do
  @moduledoc """
  At report time: snapshot the subject's excerpt + author onto the flag, reject
  reporting a subject that can't be found, and reject reporting your own content.
  """
  use Ash.Resource.Change

  alias Verscienta.Moderation.Subject

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      type = Ash.Changeset.get_attribute(cs, :subject_type)
      id = Ash.Changeset.get_attribute(cs, :subject_id)

      case Subject.snapshot(type, id) do
        :error ->
          Ash.Changeset.add_error(cs, field: :subject_id, message: "subject not found")

        {excerpt, author_id} ->
          if author_id && context.actor && author_id == context.actor.id do
            Ash.Changeset.add_error(cs, field: :subject_id, message: "you cannot report your own content")
          else
            cs
            |> Ash.Changeset.force_change_attribute(:subject_excerpt, excerpt)
            |> Ash.Changeset.force_change_attribute(:subject_author_id, author_id)
          end
      end
    end)
  end
end
```

- [ ] **Step 3: Create a minimal Action resource (so the domain compiles)**

Create `lib/verscienta/moderation/action.ex`:

```elixir
defmodule Verscienta.Moderation.Action do
  @moduledoc "Durable record of a moderator action. Append-only; seeds the audit log."
  use Ash.Resource,
    otp_app: :verscienta,
    domain: Verscienta.Moderation,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "moderation_actions"
    repo Verscienta.Repo

    custom_indexes do
      index [:target_user_id, :occurred_at]
      index [:subject_type, :subject_id]
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:moderator_id, :action, :subject_type, :subject_id, :target_user_id, :note, :occurred_at]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :action, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:dismiss, :remove_content, :warn_user, :suspend_user]]

    attribute :subject_type, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:comment, :article, :user, :room_message]]

    attribute :subject_id, :uuid, allow_nil?: false, public?: true
    attribute :target_user_id, :uuid, allow_nil?: true, public?: true
    attribute :note, :string, allow_nil?: true, public?: true
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true

    attribute :moderator_id, :uuid, allow_nil?: false, public?: true
  end
end
```

- [ ] **Step 4: Create the Flag resource**

Create `lib/verscienta/moderation/flag.ex`:

```elixir
defmodule Verscienta.Moderation.Flag do
  @moduledoc "A community report against a polymorphic subject (comment/article/user/room_message)."
  use Ash.Resource,
    otp_app: :verscienta,
    domain: Verscienta.Moderation,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "moderation_flags"
    repo Verscienta.Repo

    custom_indexes do
      index [:status, :subject_type, :subject_id]
    end
  end

  actions do
    defaults [:read]

    create :report do
      description "File a community report against a subject."
      accept [:subject_type, :subject_id, :reason, :note]
      change relate_actor(:reporter)
      change Verscienta.Moderation.Flag.Changes.CaptureSubject
      upsert? true
      upsert_identity :unique_reporter_subject
      upsert_fields []
    end

    read :queue do
      description "Pending flags, newest first (grouped for display in the LiveView)."
      filter expr(status == :pending)
      prepare build(sort: [inserted_at: :desc])
    end

    update :mark_resolved do
      description "System action: mark a flag resolved (used by Moderation.resolve/5)."
      accept [:resolution, :resolved_by_id, :resolved_at]
      change set_attribute(:status, :resolved)
    end
  end

  policies do
    policy action(:report) do
      authorize_if actor_present()
    end

    policy action(:queue) do
      authorize_if expr(^actor(:role) in [:moderator, :admin])
    end

    policy action(:mark_resolved) do
      authorize_if expr(^actor(:role) in [:moderator, :admin])
    end

    policy action_type(:read) do
      authorize_if expr(^actor(:role) in [:moderator, :admin])
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :subject_type, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:comment, :article, :user, :room_message]]

    attribute :subject_id, :uuid, allow_nil?: false, public?: true
    attribute :subject_excerpt, :string, allow_nil?: true, public?: true
    attribute :subject_author_id, :uuid, allow_nil?: true, public?: true

    attribute :reason, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:spam, :harassment, :misinformation, :off_topic, :other]]

    attribute :note, :string, allow_nil?: true, public?: true, constraints: [max_length: 1000]

    attribute :status, :atom,
      allow_nil?: false,
      public?: true,
      default: :pending,
      constraints: [one_of: [:pending, :resolved]]

    attribute :resolution, :atom,
      allow_nil?: true,
      public?: true,
      constraints: [one_of: [:dismissed, :content_removed, :user_warned, :user_suspended]]

    attribute :resolved_at, :utc_datetime_usec, allow_nil?: true, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :reporter, Verscienta.Accounts.User, allow_nil?: false
    belongs_to :resolved_by, Verscienta.Accounts.User, allow_nil?: true
  end

  identities do
    identity :unique_reporter_subject, [:subject_type, :subject_id, :reporter_id]
  end
end
```

- [ ] **Step 5: Generate the migration**

Run: `mix ash.codegen create_moderation_tables`
Expected: creates `priv/repo/migrations/*_create_moderation_tables.exs` with `moderation_flags` + `moderation_actions` tables. Then run `mix ecto.migrate`.

- [ ] **Step 6: Write the failing tests for `report`**

Create `test/verscienta/moderation/flag_test.exs`:

```elixir
defmodule Verscienta.Moderation.FlagTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Moderation.Flag

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
      |> Ash.Changeset.for_create(:create, %{title: "Flag Me", blocks: [], category: :movement}, actor: author)
      |> Ash.create()

    {:ok, p} = a |> Ash.Changeset.for_update(:publish, %{}, actor: author) |> Ash.update()
    p
  end

  defp report(actor, type, id, attrs \\ %{}) do
    Flag
    |> Ash.Changeset.for_create(:report, Map.merge(%{subject_type: type, subject_id: id, reason: :spam}, attrs), actor: actor)
    |> Ash.create(authorize?: true)
  end

  test "report captures the subject excerpt and author" do
    author = user("author1")
    reporter = user("reporter1")
    art = article(author)

    {:ok, flag} = report(reporter, :article, art.id)

    assert flag.reporter_id == reporter.id
    assert flag.subject_excerpt == "Flag Me"
    assert flag.subject_author_id == author.id
    assert flag.status == :pending
  end

  test "report requires a signed-in actor" do
    author = user("author2")
    art = article(author)

    assert {:error, _} =
             Flag
             |> Ash.Changeset.for_create(:report, %{subject_type: :article, subject_id: art.id, reason: :spam})
             |> Ash.create(authorize?: true)
  end

  test "you cannot report your own content" do
    author = user("author3")
    art = article(author)

    assert {:error, _} = report(author, :article, art.id)
  end

  test "reporting an unknown subject fails" do
    reporter = user("reporter4")
    assert {:error, _} = report(reporter, :article, Ecto.UUID.generate())
  end

  test "the same reporter flagging the same subject twice is idempotent (upsert)" do
    author = user("author5")
    reporter = user("reporter5")
    art = article(author)

    {:ok, first} = report(reporter, :article, art.id)
    {:ok, second} = report(reporter, :article, art.id, %{reason: :harassment})

    assert first.id == second.id
  end
end
```

- [ ] **Step 7: Run the tests**

Run: `mix test test/verscienta/moderation/flag_test.exs`
Expected: PASS (all 5).

- [ ] **Step 8: Commit (Tasks 1 + 2 together)**

```bash
git add config/config.exs lib/verscienta/moderation.ex lib/verscienta/moderation/ test/verscienta/moderation/flag_test.exs priv/repo/migrations priv/resource_snapshots
git commit -m "feat(moderation): Flag + Action resources, polymorphic Subject, report action"
```

---

## Task 3: User suspension (`suspended_until` + suspend/unsuspend)

**Files:**
- Modify: `lib/verscienta/accounts/user.ex`
- Test: `test/verscienta/accounts/suspension_test.exs`

- [ ] **Step 1: Add the `suspended_until` attribute**

In `lib/verscienta/accounts/user.ex`, near the `role` / `confirmed_at` attributes, add:

```elixir
    attribute :suspended_until, :utc_datetime_usec, allow_nil?: true, public?: true, writable?: false
```

- [ ] **Step 2: Add `:suspend` and `:unsuspend` update actions**

In the `actions do` block of `user.ex`, add:

```elixir
    update :suspend do
      description "Moderator action: suspend a user until a given time."
      accept []
      argument :suspended_until, :utc_datetime_usec, allow_nil?: false
      require_atomic? false
      change set_attribute(:suspended_until, arg(:suspended_until))
    end

    update :unsuspend do
      description "Moderator action: lift a suspension."
      accept []
      require_atomic? false
      change set_attribute(:suspended_until, nil)
    end
```

- [ ] **Step 3: Add a policy authorizing suspend/unsuspend to mods/admins**

In the `policies do` block of `user.ex`, add (matching the existing policy style there):

```elixir
    policy action([:suspend, :unsuspend]) do
      authorize_if expr(^actor(:role) in [:moderator, :admin])
    end
```

> If `user.ex` does not use `Ash.Policy.Authorizer`, check how other privileged User actions are guarded and follow that pattern instead. Run `grep -n "authorizers\|policy" lib/verscienta/accounts/user.ex` first.

- [ ] **Step 4: Generate the migration**

Run: `mix ash.codegen add_user_suspended_until`
Then: `mix ecto.migrate`
Expected: adds `suspended_until` column to `users`.

- [ ] **Step 5: Write the failing tests**

Create `test/verscienta/accounts/suspension_test.exs`:

```elixir
defmodule Verscienta.Accounts.SuspensionTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Accounts.User

  defp user(name, role \\ :user) do
    u =
      User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: name <> "@example.com",
        username: name,
        password: "password123",
        password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    u
    |> Ash.Changeset.for_update(:update_profile, %{}, actor: u)
    |> Ash.Changeset.force_change_attribute(:role, role)
    |> Ash.update!(authorize?: false)
  end

  test "a moderator can suspend and unsuspend a user" do
    mod = user("mod1", :moderator)
    target = user("target1")
    until = DateTime.add(DateTime.utc_now(), 7, :day)

    {:ok, suspended} =
      target
      |> Ash.Changeset.for_update(:suspend, %{suspended_until: until}, actor: mod)
      |> Ash.update()

    assert suspended.suspended_until != nil

    {:ok, lifted} =
      suspended |> Ash.Changeset.for_update(:unsuspend, %{}, actor: mod) |> Ash.update()

    assert lifted.suspended_until == nil
  end

  test "a plain user cannot suspend another user" do
    plain = user("plain1")
    target = user("target2")
    until = DateTime.add(DateTime.utc_now(), 7, :day)

    assert {:error, _} =
             target
             |> Ash.Changeset.for_update(:suspend, %{suspended_until: until}, actor: plain)
             |> Ash.update()
  end
end
```

- [ ] **Step 6: Run the tests**

Run: `mix test test/verscienta/accounts/suspension_test.exs`
Expected: PASS (2).

- [ ] **Step 7: Commit**

```bash
git add lib/verscienta/accounts/user.ex test/verscienta/accounts/suspension_test.exs priv/repo/migrations priv/resource_snapshots
git commit -m "feat(moderation): minimal user suspension (suspended_until + suspend/unsuspend)"
```

---

## Task 4: Enforce suspension on comment + room-message create

**Files:**
- Create: `lib/verscienta/moderation/changes/reject_if_suspended.ex`
- Modify: `lib/verscienta/engagement/comment.ex`
- Modify: `lib/verscienta/communities/message.ex`
- Test: `test/verscienta/moderation/suspension_enforcement_test.exs`

- [ ] **Step 1: Create the RejectIfSuspended change**

Create `lib/verscienta/moderation/changes/reject_if_suspended.ex`:

```elixir
defmodule Verscienta.Moderation.Changes.RejectIfSuspended do
  @moduledoc """
  Rejects a create when the acting user is currently suspended. Reloads the
  actor to avoid acting on a stale `suspended_until` from the session.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      case context.actor do
        %{id: id} ->
          if suspended?(id) do
            Ash.Changeset.add_error(cs, message: "your account is suspended")
          else
            cs
          end

        _ ->
          cs
      end
    end)
  end

  defp suspended?(user_id) do
    case Ash.get(Verscienta.Accounts.User, user_id, authorize?: false) do
      {:ok, %{suspended_until: until}} when not is_nil(until) ->
        DateTime.compare(until, DateTime.utc_now()) == :gt

      _ ->
        false
    end
  end
end
```

- [ ] **Step 2: Wire it into `Comment.create`**

In `lib/verscienta/engagement/comment.ex`, add to the `create :create` action's change list (after `relate_actor(:user)`):

```elixir
    change Verscienta.Moderation.Changes.RejectIfSuspended
```

- [ ] **Step 3: Wire it into `Message.post`**

In `lib/verscienta/communities/message.ex`, add to the `create :post` action (after `relate_actor(:user)`):

```elixir
    change Verscienta.Moderation.Changes.RejectIfSuspended
```

- [ ] **Step 4: Write the failing tests**

Create `test/verscienta/moderation/suspension_enforcement_test.exs`:

```elixir
defmodule Verscienta.Moderation.SuspensionEnforcementTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Accounts.User
  alias Verscienta.Engagement.Comment

  defp user(name) do
    User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com",
      username: name,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp suspend(u, days) do
    until = DateTime.add(DateTime.utc_now(), days, :day)

    u
    |> Ash.Changeset.for_update(:suspend, %{suspended_until: until}, actor: u)
    |> Ash.update!(authorize?: false)
  end

  defp article(author) do
    {:ok, a} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: "S", blocks: [], category: :movement}, actor: author)
      |> Ash.create()

    {:ok, p} = a |> Ash.Changeset.for_update(:publish, %{}, actor: author) |> Ash.update()
    p
  end

  test "a suspended user cannot comment" do
    author = user("author_s")
    art = article(author)
    suspended = suspend(user("naughty"), 7)

    assert {:error, _} =
             Comment
             |> Ash.Changeset.for_create(:create, %{body: "hi", article_id: art.id}, actor: suspended)
             |> Ash.create(authorize?: true)
  end

  test "a non-suspended user can comment" do
    author = user("author_ns")
    art = article(author)
    ok_user = user("welcome")

    assert {:ok, _} =
             Comment
             |> Ash.Changeset.for_create(:create, %{body: "hi", article_id: art.id}, actor: ok_user)
             |> Ash.create(authorize?: true)
  end
end
```

- [ ] **Step 5: Run the tests**

Run: `mix test test/verscienta/moderation/suspension_enforcement_test.exs`
Expected: PASS (2).

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta/moderation/changes/reject_if_suspended.ex lib/verscienta/engagement/comment.ex lib/verscienta/communities/message.ex test/verscienta/moderation/suspension_enforcement_test.exs
git commit -m "feat(moderation): enforce suspension on comment + room-message create"
```

---

## Task 5: `Moderation.resolve/5` + `pending_groups/0`

**Files:**
- Modify: `lib/verscienta/moderation.ex`
- Test: `test/verscienta/moderation/resolve_test.exs`

- [ ] **Step 1: Add `resolve/5` and `pending_groups/0` to the domain**

In `lib/verscienta/moderation.ex`, inside the module (after the `resources do` block), add:

```elixir
  alias Verscienta.Moderation.{Action, Flag, Subject}

  @resolution_to_action %{
    dismissed: :dismiss,
    content_removed: :remove_content,
    user_warned: :warn_user,
    user_suspended: :suspend_user
  }

  @doc """
  Resolve every pending flag for a subject. Performs the side effect implied by
  `resolution`, marks all pending flags resolved, and records a `Moderation.Action`.

  `opts`: `:note` (moderator note), `:suspend_days` (default 7, used when
  resolution is `:user_suspended`).

  Returns `{:ok, resolved_count}` or `{:error, reason}`.
  """
  def resolve(subject_type, subject_id, resolution, moderator, opts \\ [])
      when resolution in [:dismissed, :content_removed, :user_warned, :user_suspended] do
    unless moderator.role in [:moderator, :admin], do: throw(:unauthorized)

    now = DateTime.utc_now()
    pending = pending_flags(subject_type, subject_id)
    target_user_id = pending |> List.first() |> subject_author()

    :ok = perform_side_effect(resolution, subject_type, subject_id, target_user_id, moderator, opts)

    Enum.each(pending, fn flag ->
      flag
      |> Ash.Changeset.for_update(:mark_resolved, %{
        resolution: resolution,
        resolved_by_id: moderator.id,
        resolved_at: now
      }, actor: moderator)
      |> Ash.update!()
    end)

    Action
    |> Ash.Changeset.for_create(:record, %{
      moderator_id: moderator.id,
      action: @resolution_to_action[resolution],
      subject_type: subject_type,
      subject_id: subject_id,
      target_user_id: target_user_id,
      note: Keyword.get(opts, :note),
      occurred_at: now
    })
    |> Ash.create!(authorize?: false)

    {:ok, length(pending)}
  catch
    :unauthorized -> {:error, :unauthorized}
  end

  @doc "Pending flags grouped by subject for the moderation queue."
  def pending_groups do
    Flag
    |> Ash.read!(action: :queue, authorize?: false)
    |> Enum.group_by(&{&1.subject_type, &1.subject_id})
    |> Enum.map(fn {{type, id}, flags} ->
      %{
        subject_type: type,
        subject_id: id,
        subject_excerpt: hd(flags).subject_excerpt,
        subject_author_id: hd(flags).subject_author_id,
        count: length(flags),
        reasons: flags |> Enum.map(& &1.reason) |> Enum.uniq(),
        first_reported_at: flags |> Enum.map(& &1.inserted_at) |> Enum.min(DateTime)
      }
    end)
    |> Enum.sort_by(&{&1.count, &1.first_reported_at}, :desc)
  end

  defp pending_flags(subject_type, subject_id) do
    Flag
    |> Ash.Query.filter(status == :pending and subject_type == ^subject_type and subject_id == ^subject_id)
    |> Ash.read!(authorize?: false)
  end

  defp subject_author(nil), do: nil
  defp subject_author(flag), do: flag.subject_author_id

  defp perform_side_effect(:dismissed, _t, _i, _u, _mod, _opts), do: :ok
  defp perform_side_effect(:user_warned, _t, _i, _u, _mod, _opts), do: :ok
  defp perform_side_effect(:content_removed, type, id, _u, _mod, _opts), do: Subject.remove(type, id)

  defp perform_side_effect(:user_suspended, _t, _i, nil, _mod, _opts), do: :ok

  defp perform_side_effect(:user_suspended, _type, _id, user_id, moderator, opts) do
    days = Keyword.get(opts, :suspend_days, 7)
    until = DateTime.add(DateTime.utc_now(), days, :day)

    with {:ok, user} <- Ash.get(Verscienta.Accounts.User, user_id, authorize?: false) do
      user
      |> Ash.Changeset.for_update(:suspend, %{suspended_until: until}, actor: moderator)
      |> Ash.update!()
    end

    :ok
  end
```

> Ensure `require Ash.Query` is present at the top of `moderation.ex` (it is in the Task 1 module body).

- [ ] **Step 2: Write the failing tests**

Create `test/verscienta/moderation/resolve_test.exs`:

```elixir
defmodule Verscienta.Moderation.ResolveTest do
  use Verscienta.DataCase, async: true

  require Ash.Query

  alias Verscienta.Moderation
  alias Verscienta.Moderation.{Action, Flag}

  defp user(name, role \\ :user) do
    u =
      Verscienta.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: name <> "@example.com",
        username: name,
        password: "password123",
        password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    u
    |> Ash.Changeset.for_update(:update_profile, %{}, actor: u)
    |> Ash.Changeset.force_change_attribute(:role, role)
    |> Ash.update!(authorize?: false)
  end

  defp article(author) do
    {:ok, a} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: "R", blocks: [], category: :movement}, actor: author)
      |> Ash.create()

    {:ok, p} = a |> Ash.Changeset.for_update(:publish, %{}, actor: author) |> Ash.update()
    p
  end

  defp report(actor, type, id) do
    Flag
    |> Ash.Changeset.for_create(:report, %{subject_type: type, subject_id: id, reason: :spam}, actor: actor)
    |> Ash.create!(authorize?: true)
  end

  test "resolve marks all pending flags for the subject and writes an Action" do
    author = user("auth_r1")
    art = article(author)
    r1 = user("rep_a")
    r2 = user("rep_b")
    mod = user("mod_r1", :moderator)

    report(r1, :article, art.id)
    report(r2, :article, art.id)

    {:ok, 2} = Moderation.resolve(:article, art.id, :dismissed, mod)

    flags = Flag |> Ash.Query.filter(subject_id == ^art.id) |> Ash.read!(authorize?: false)
    assert Enum.all?(flags, &(&1.status == :resolved and &1.resolution == :dismissed))

    actions = Action |> Ash.read!(authorize?: false)
    assert Enum.any?(actions, &(&1.action == :dismiss and &1.subject_id == art.id))
  end

  test "content_removed archives the article" do
    author = user("auth_r2")
    art = article(author)
    mod = user("mod_r2", :moderator)
    report(user("rep_c"), :article, art.id)

    {:ok, 1} = Moderation.resolve(:article, art.id, :content_removed, mod)

    reloaded = Ash.get!(Verscienta.Content.Article, art.id, authorize?: false)
    assert reloaded.status == :archived
  end

  test "user_suspended sets suspended_until on the author" do
    author = user("auth_r3")
    art = article(author)
    mod = user("mod_r3", :moderator)
    report(user("rep_d"), :article, art.id)

    {:ok, 1} = Moderation.resolve(:article, art.id, :user_suspended, mod, suspend_days: 3)

    reloaded = Ash.get!(Verscienta.Accounts.User, author.id, authorize?: false)
    assert reloaded.suspended_until != nil
  end

  test "a non-moderator cannot resolve" do
    author = user("auth_r4")
    art = article(author)
    plain = user("plain_r")
    report(user("rep_e"), :article, art.id)

    assert {:error, :unauthorized} = Moderation.resolve(:article, art.id, :dismissed, plain)
  end

  test "pending_groups groups by subject with a count" do
    author = user("auth_r5")
    art = article(author)
    report(user("rep_f"), :article, art.id)
    report(user("rep_g"), :article, art.id)

    group = Enum.find(Moderation.pending_groups(), &(&1.subject_id == art.id))
    assert group.count == 2
    assert group.subject_type == :article
  end
end
```

- [ ] **Step 3: Run the tests**

Run: `mix test test/verscienta/moderation/resolve_test.exs`
Expected: PASS (5).

- [ ] **Step 4: Commit**

```bash
git add lib/verscienta/moderation.ex test/verscienta/moderation/resolve_test.exs
git commit -m "feat(moderation): resolve/5 orchestration + pending_groups/0 queue grouping"
```

---

## Task 6: `mod_required` plug + `/admin/moderation` route

**Files:**
- Modify: `lib/verscienta_web/router.ex`

- [ ] **Step 1: Add the `mod_required` plug**

In `lib/verscienta_web/router.ex`, below the existing `admin_required/2` private function (around line 65), add:

```elixir
  defp mod_required(conn, _opts) do
    case conn.assigns[:current_user] do
      %{role: role} when role in [:moderator, :admin] ->
        conn

      _ ->
        conn
        |> Phoenix.Controller.put_flash(:error, "Not authorized.")
        |> Phoenix.Controller.redirect(to: "/")
        |> halt()
    end
  end
```

- [ ] **Step 2: Add the `:mod` pipeline**

Below the `pipeline :admin do ... end` block (around line 28):

```elixir
  pipeline :mod do
    plug :mod_required
  end
```

- [ ] **Step 3: Add the route**

In the `scope "/admin", VerscientaWeb do` block, add a moderation live_session that pipes through `:mod` instead of `:admin`. Since the existing scope pipes through `[:browser, :admin]`, add a SEPARATE scope below it:

```elixir
  scope "/admin", VerscientaWeb do
    pipe_through [:browser, :mod]

    live_session :admin_moderation,
      on_mount: [{VerscientaWeb.LiveUserAuth, :current_user}] do
      live "/moderation", AdminModerationLive, :index
    end
  end
```

- [ ] **Step 4: Verify the router compiles**

Run: `mix compile`
Expected: FAIL — `AdminModerationLive is not available`. Expected; Task 8 creates it. Do not commit yet — commit with Task 8.

---

## Task 7: `ReportDialog` live_component + `report_button/1`

**Files:**
- Create: `lib/verscienta_web/components/report_dialog.ex`
- Test: `test/verscienta_web/live/report_dialog_test.exs`

- [ ] **Step 1: Create the component**

Create `lib/verscienta_web/components/report_dialog.ex`:

```elixir
defmodule VerscientaWeb.ReportDialog do
  @moduledoc """
  A reusable report affordance + modal. Drop `<.report_button>` next to any
  reportable item; it renders a live_component that opens a reason/note modal
  and submits the `Moderation.Flag.report` action.
  """
  use VerscientaWeb, :live_component

  alias Verscienta.Moderation.Flag

  @reasons [
    {"Spam", :spam},
    {"Harassment", :harassment},
    {"Misinformation", :misinformation},
    {"Off-topic", :off_topic},
    {"Other", :other}
  ]

  @doc """
  Render a report button bound to a `ReportDialog` live_component.

  Assigns: `:id` (unique), `:subject_type`, `:subject_id`, `:current_user`.
  """
  attr :id, :string, required: true
  attr :subject_type, :atom, required: true
  attr :subject_id, :string, required: true
  attr :current_user, :any, required: true

  def report_button(assigns) do
    ~H"""
    <.live_component
      module={__MODULE__}
      id={@id}
      subject_type={@subject_type}
      subject_id={@subject_id}
      current_user={@current_user}
    />
    """
  end

  @impl true
  def mount(socket) do
    {:ok, assign(socket, open: false, done: false)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> assign_new(:open, fn -> false end) |> assign_new(:done, fn -> false end)}
  end

  @impl true
  def handle_event("open", _params, socket), do: {:noreply, assign(socket, open: true)}
  def handle_event("close", _params, socket), do: {:noreply, assign(socket, open: false)}

  def handle_event("submit", %{"reason" => reason} = params, socket) do
    actor = socket.assigns.current_user

    attrs = %{
      subject_type: socket.assigns.subject_type,
      subject_id: socket.assigns.subject_id,
      reason: String.to_existing_atom(reason),
      note: params["note"]
    }

    case Flag |> Ash.Changeset.for_create(:report, attrs, actor: actor) |> Ash.create(authorize?: true) do
      {:ok, _} -> {:noreply, assign(socket, open: false, done: true)}
      {:error, _} -> {:noreply, assign(socket, open: false, done: true)}
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :reasons, @reasons)

    ~H"""
    <div class="inline-block">
      <span :if={@done} class="text-[11px] uppercase tracking-wider text-ink-3">reported</span>

      <button
        :if={!@done && @current_user}
        type="button"
        phx-click="open"
        phx-target={@myself}
        class="text-[11px] uppercase tracking-wider text-ink-3 hover:text-politics"
        title="Report"
      >
        ⚐ report
      </button>

      <div :if={@open} class="fixed inset-0 z-50 flex items-center justify-center bg-black/60" phx-click="close" phx-target={@myself}>
        <div class="w-full max-w-md border border-line bg-canvas-2 p-6" phx-click-away="close" phx-target={@myself} onclick="event.stopPropagation()">
          <h3 class="mb-4 text-xs font-bold uppercase tracking-wider text-ink">Report content</h3>

          <form phx-submit="submit" phx-target={@myself} class="space-y-4">
            <fieldset class="space-y-2">
              <label :for={{label, value} <- @reasons} class="flex items-center gap-2 text-sm text-ink-2">
                <input type="radio" name="reason" value={value} required /> {label}
              </label>
            </fieldset>

            <textarea name="note" placeholder="Add a note (optional)" class="w-full border border-line bg-canvas px-3 py-2 text-sm text-ink" rows="3"></textarea>

            <div class="flex justify-end gap-3">
              <button type="button" phx-click="close" phx-target={@myself} class="text-xs uppercase tracking-wider text-ink-3">cancel</button>
              <button type="submit" class="bg-politics px-4 py-2 text-xs font-bold uppercase tracking-wider text-black">submit report</button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end
end
```

> Note: `report_button/1` must be importable where used. In each host LiveView, add `import VerscientaWeb.ReportDialog`. Verify `politics`/`canvas-2`/`line`/`ink-*` token classes exist (they're used in `admin_sources_live.ex`).

- [ ] **Step 2: Write the failing test (component within a host LV)**

Create `test/verscienta_web/live/report_dialog_test.exs` — tests the affordance through the article reader (added in Task 8). If Task 8 isn't done yet, mark this test pending and revisit. For now, write a focused unit-ish test that mounts the reader and asserts the report button + submit path:

```elixir
defmodule VerscientaWeb.ReportDialogTest do
  use VerscientaWeb.ConnCase, async: false

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

  defp article(author) do
    {:ok, a} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: "Reportable", blocks: [], category: :movement}, actor: author)
      |> Ash.create()

    {:ok, p} = a |> Ash.Changeset.for_update(:publish, %{}, actor: author) |> Ash.update()
    p
  end

  defp sign_in(conn, u), do: conn |> Plug.Test.init_test_session(%{}) |> Helpers.store_in_session(u)

  test "a signed-in non-author sees the report affordance on an article", %{conn: conn} do
    author = user("auth_rd")
    reporter = user("rep_rd")
    art = article(author)

    {:ok, lv, _html} = live(sign_in(conn, reporter), ~p"/article/#{art.slug}")
    assert render(lv) =~ "report"
  end
end
```

> Confirm the article reader route — run `grep -n "ArticleReaderLive" lib/verscienta_web/router.ex` to get the exact `~p` path (it may be `/a/:slug` or `/article/:slug`); fix the test path accordingly.

- [ ] **Step 3: Defer running this test until Task 8 wires the button in. Do not commit yet.**

---

## Task 8: Wire the report affordance into hosts + create `AdminModerationLive`

**Files:**
- Modify: `lib/verscienta_web/live/article_reader_live.ex`
- Modify: `lib/verscienta_web/live/profile_live.ex`
- Modify: `lib/verscienta_web/live/room_live.ex`
- Create: `lib/verscienta_web/live/admin_moderation_live.ex`
- Test: `test/verscienta_web/live/admin_moderation_live_test.exs`

- [ ] **Step 1: Add the report button to the article reader (article + comments)**

In `lib/verscienta_web/live/article_reader_live.ex`:
1. Add `import VerscientaWeb.ReportDialog` near the other imports.
2. In the article header area of `render/1`, add (guard on a non-author signed-in user):

```elixir
<.report_button
  :if={@current_user && @current_user.id != @article.author_id}
  id={"report-article-#{@article.id}"}
  subject_type={:article}
  subject_id={@article.id}
  current_user={@current_user}
/>
```

3. In the comment stream item markup (where each comment renders), add:

```elixir
<.report_button
  :if={@current_user && @current_user.id != comment.user_id}
  id={"report-comment-#{comment.id}"}
  subject_type={:comment}
  subject_id={comment.id}
  current_user={@current_user}
/>
```

> Run `grep -n "stream(:comments\|<div\|comment.body" lib/verscienta_web/live/article_reader_live.ex` to find the exact comment markup block and insert near the comment author/actions row.

- [ ] **Step 2: Add the report button to the profile page**

In `lib/verscienta_web/live/profile_live.ex`, add `import VerscientaWeb.ReportDialog` and, in the profile header, render (guard against reporting yourself):

```elixir
<.report_button
  :if={@current_user && @current_user.id != @user.id}
  id={"report-user-#{@user.id}"}
  subject_type={:user}
  subject_id={@user.id}
  current_user={@current_user}
/>
```

> Confirm the profile's user assign name with `grep -n "assign.*user\|@user\|@profile" lib/verscienta_web/live/profile_live.ex` and adjust `@user` accordingly.

- [ ] **Step 3: Add the report button to room messages**

In `lib/verscienta_web/live/room_live.ex`, add `import VerscientaWeb.ReportDialog` and, in each message row, render:

```elixir
<.report_button
  :if={@current_user && @current_user.id != message.user_id}
  id={"report-msg-#{message.id}"}
  subject_type={:room_message}
  subject_id={message.id}
  current_user={@current_user}
/>
```

> Confirm the message assign/variable name in the room template with `grep -n "message\|stream" lib/verscienta_web/live/room_live.ex`.

- [ ] **Step 4: Create the moderation dashboard**

Create `lib/verscienta_web/live/admin_moderation_live.ex`:

```elixir
defmodule VerscientaWeb.AdminModerationLive.NotFound do
  defexception message: "not found", plug_status: 404
end

defmodule VerscientaWeb.AdminModerationLive do
  @moduledoc "Moderator queue: review reported content and resolve each subject."
  use VerscientaWeb, :live_view

  import VerscientaWeb.CodexComponents

  alias Verscienta.Moderation
  alias VerscientaWeb.SEO

  on_mount {VerscientaWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns.current_user.role not in [:moderator, :admin] do
      raise VerscientaWeb.AdminModerationLive.NotFound
    end

    {:ok,
     socket
     |> assign(page_title: "moderation", filter_type: :all)
     |> assign(:seo, SEO.build(noindex: true))
     |> load_groups()}
  end

  defp load_groups(socket) do
    groups = Moderation.pending_groups()

    groups =
      case socket.assigns[:filter_type] || :all do
        :all -> groups
        type -> Enum.filter(groups, &(&1.subject_type == type))
      end

    assign(socket, groups: groups)
  end

  @impl true
  def handle_event("filter", %{"type" => type}, socket) do
    {:noreply, socket |> assign(filter_type: parse_type(type)) |> load_groups()}
  end

  def handle_event("resolve", %{"type" => type, "id" => id, "resolution" => resolution}, socket) do
    {:ok, _count} =
      Moderation.resolve(
        String.to_existing_atom(type),
        id,
        String.to_existing_atom(resolution),
        socket.assigns.current_user
      )

    {:noreply, socket |> put_flash(:info, "Resolved") |> load_groups()}
  end

  defp parse_type("all"), do: :all
  defp parse_type(t), do: String.to_existing_atom(t)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-6 pb-24 pt-28">
      <.headline class="mb-10 text-5xl">moderation</.headline>

      <div class="mb-8 flex gap-3 text-[11px] uppercase tracking-wider">
        <button :for={t <- ~w(all comment article user room_message)} phx-click="filter" phx-value-type={t} class={["px-3 py-1.5 border border-line", if(to_string(@filter_type) == t, do: "text-ink", else: "text-ink-3")]}>
          {t}
        </button>
      </div>

      <p :if={@groups == []} class="text-ink-3">queue is empty.</p>

      <div :for={g <- @groups} class="mb-6 border border-line bg-canvas-2 p-5">
        <div class="mb-3 flex items-start justify-between gap-4">
          <div>
            <div class="text-[11px] uppercase tracking-wider text-ink-3">{g.subject_type} · {g.count} report(s) · {Enum.join(g.reasons, ", ")}</div>
            <div class="mt-1 text-sm text-ink">{g.subject_excerpt}</div>
          </div>
        </div>

        <div class="flex flex-wrap gap-2 text-[11px] uppercase tracking-wider">
          <button phx-click="resolve" phx-value-type={g.subject_type} phx-value-id={g.subject_id} phx-value-resolution="dismissed" class="border border-line px-3 py-1.5 text-ink-2 hover:text-ink">dismiss</button>
          <button phx-click="resolve" phx-value-type={g.subject_type} phx-value-id={g.subject_id} phx-value-resolution="content_removed" class="border border-line px-3 py-1.5 text-ink-2 hover:text-ink">remove content</button>
          <button phx-click="resolve" phx-value-type={g.subject_type} phx-value-id={g.subject_id} phx-value-resolution="user_warned" class="border border-line px-3 py-1.5 text-ink-2 hover:text-ink">warn user</button>
          <button phx-click="resolve" phx-value-type={g.subject_type} phx-value-id={g.subject_id} phx-value-resolution="user_suspended" class="bg-politics px-3 py-1.5 text-black">suspend user</button>
        </div>
      </div>
    </div>
    """
  end
end
```

- [ ] **Step 5: Write the dashboard tests**

Create `test/verscienta_web/live/admin_moderation_live_test.exs`:

```elixir
defmodule VerscientaWeb.AdminModerationLiveTest do
  use VerscientaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshAuthentication.Plug.Helpers
  alias Verscienta.Moderation.Flag

  defp user(name, role \\ :user) do
    u =
      Verscienta.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: name <> "@example.com",
        username: name,
        password: "password123",
        password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    u
    |> Ash.Changeset.for_update(:update_profile, %{}, actor: u)
    |> Ash.Changeset.force_change_attribute(:role, role)
    |> Ash.update!(authorize?: false)
  end

  defp article(author) do
    {:ok, a} =
      Verscienta.Content.Article
      |> Ash.Changeset.for_create(:create, %{title: "ModMe", blocks: [], category: :movement}, actor: author)
      |> Ash.create()

    {:ok, p} = a |> Ash.Changeset.for_update(:publish, %{}, actor: author) |> Ash.update()
    p
  end

  defp report(actor, type, id) do
    Flag
    |> Ash.Changeset.for_create(:report, %{subject_type: type, subject_id: id, reason: :spam}, actor: actor)
    |> Ash.create!(authorize?: true)
  end

  defp sign_in(conn, u), do: conn |> Plug.Test.init_test_session(%{}) |> Helpers.store_in_session(u)

  defp blocked?(fun) do
    case fun.() do
      {:ok, _, _} -> false
      {:error, _} -> true
    end
  rescue
    _ -> true
  catch
    _, _ -> true
  end

  test "a plain user cannot access the queue", %{conn: conn} do
    plain = user("plain_mod")
    assert blocked?(fn -> live(sign_in(conn, plain), ~p"/admin/moderation") end)
  end

  test "a moderator sees a reported subject and can dismiss it", %{conn: conn} do
    author = user("auth_mod")
    art = article(author)
    report(user("rep_mod"), :article, art.id)
    mod = user("the_mod", :moderator)

    {:ok, lv, _html} = live(sign_in(conn, mod), ~p"/admin/moderation")
    assert render(lv) =~ "ModMe"

    lv
    |> element("button[phx-value-resolution='dismissed']")
    |> render_click()

    refute render(lv) =~ "ModMe"
  end
end
```

- [ ] **Step 6: Run the LiveView + component tests**

Run: `mix test test/verscienta_web/live/admin_moderation_live_test.exs test/verscienta_web/live/report_dialog_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit (Tasks 6 + 7 + 8 together)**

```bash
git add lib/verscienta_web/router.ex lib/verscienta_web/components/report_dialog.ex lib/verscienta_web/live/admin_moderation_live.ex lib/verscienta_web/live/article_reader_live.ex lib/verscienta_web/live/profile_live.ex lib/verscienta_web/live/room_live.ex test/verscienta_web/live/admin_moderation_live_test.exs test/verscienta_web/live/report_dialog_test.exs
git commit -m "feat(moderation): reporting UI + moderator queue at /admin/moderation"
```

---

## Task 9: Moderator nav entry

**Files:**
- Modify: `lib/verscienta_web/components/layouts.ex` (or the nav component where admin/auth links live)

- [ ] **Step 1: Find the nav**

Run: `grep -rn "admin/sources\|/admin/flags\|nav" lib/verscienta_web/components/layouts.ex lib/verscienta_web/components/*.ex | head`
Expected: the markup that renders admin/account links.

- [ ] **Step 2: Add a Moderation link gated on role**

Where current-user nav links render, add:

```elixir
<.link :if={@current_user && @current_user.role in [:moderator, :admin]} navigate={~p"/admin/moderation"} class="text-[11px] uppercase tracking-wider text-ink-3 hover:text-ink">
  moderation
</.link>
```

> Match the exact assign for the current user in that template (`@current_user` is conventional here).

- [ ] **Step 3: Verify compile + a quick smoke test**

Run: `mix compile --warnings-as-errors`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add lib/verscienta_web/components/layouts.ex
git commit -m "feat(moderation): moderator nav entry"
```

---

## Task 10: Full verification + todo check-off

**Files:**
- Modify: `docs/todo.md`

- [ ] **Step 1: Run the full moderation test suite**

Run: `mix test test/verscienta/moderation test/verscienta/accounts/suspension_test.exs test/verscienta_web/live/admin_moderation_live_test.exs test/verscienta_web/live/report_dialog_test.exs`
Expected: all PASS.

- [ ] **Step 2: Run format + credo + full suite**

Run: `mix format && mix credo --strict && mix test`
Expected: format clean, credo clean (fix any new issues), full suite green.
> If pre-existing seed contamination breaks unrelated list-count asserts, that is a known issue (see memory `verscienta-test-db-seed-contamination`) — confirm failures are unrelated to this slice before proceeding.

- [ ] **Step 3: Check off the todo items**

In `docs/todo.md`, under "### Moderation & Trust", change:

```markdown
- [x] `ModerationFlag` resource + community reporting UI. *(slice 1: polymorphic Moderation.Flag + ReportDialog on comments/articles/profiles/room messages)*
- [x] Moderation queue / dashboard for human moderators. *(slice 1: AdminModerationLive at /admin/moderation, mod+admin gated; dismiss/remove/warn/suspend; Moderation.Action audit seed)*
```

Leave the other three items (Llama detection, auto-actions, AI writing assistant) unchecked.

- [ ] **Step 4: Commit**

```bash
git add docs/todo.md
git commit -m "docs: check off Moderation & Trust slice 1 (reporting + queue)"
```

- [ ] **Step 5: Final review handoff**

Use the superpowers:requesting-code-review skill (or `/code-review`) on the branch before merging. Then use superpowers:finishing-a-development-branch to decide merge/PR.

---

## Self-Review Notes (author)

- **Spec coverage:** Item 1 (`ModerationFlag` + reporting UI) → Tasks 2, 7, 8. Item 3 (moderator queue) → Tasks 6, 8. Polymorphic model + snapshot → Task 2 (`Subject` + `CaptureSubject`). Audit seed (`Action`) → Task 2 + written in Task 5. Suspension → Tasks 3, 4. Resolve orchestration → Task 5. All spec sections map to a task.
- **Deferred per spec (no task, intentional):** AI auto-flagging (slice 3), auto-actions hold/shadow/escalate (slice 2), reporter resolution notifications, suspension enforcement beyond comments/room messages, appeals.
- **Type consistency:** resolution atoms (`:dismissed/:content_removed/:user_warned/:user_suspended`) are mapped to action atoms (`:dismiss/:remove_content/:warn_user/:suspend_user`) in `@resolution_to_action`; both enums match their resource `one_of` constraints. `subject_type` enum identical across `Flag`, `Action`, and `Subject`. `report_button/1` assigns (`id/subject_type/subject_id/current_user`) match call sites in Task 8.
- **Known follow-ups to verify during execution:** exact article-reader route (`~p` path), profile user assign name, room message variable name, and Codex token class names — each flagged inline with a `grep` to run first.
