# Featured / Promoted Challenges Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let admins promote a challenge (`Quest`) — time-boxed pin + highlight on `/quests` — and optionally attach a sponsor shown with an FTC disclosure, all managed from a new admin screen.

**Architecture:** Three inline fields on `Quest` (`featured_until`, `sponsor_name`, `sponsor_url`) + a `featured_now` calc (mirrors `Article`). An admin-only `:set_promotion` action with a `NormalizeQuestSponsor` validation. A new `/admin/challenges` LiveView (admin-route-gated, `authorize?: false` — `Quest` is a seed catalog with no authorizers) sets/clears promotion via a datetime-local picker. `/quests` sorts promoted challenges first and shows the sponsor disclosure (reusing item 1's idiom). Display-only; assignment and rewards unchanged.

**Tech Stack:** Elixir, Ash 3 + AshPostgres, Phoenix LiveView, ExUnit, Tailwind v4.

**Spec:** `docs/superpowers/specs/2026-06-15-promoted-challenges-design.md`

---

## Running mix & tests in this worktree

Host `mix` is broken; run through the container. Worktree name is `promoted-challenges`. Use this wrapper for ALL `mix` commands (substitute the trailing `mix …`):

```bash
MSYS_NO_PATHCONV=1 docker exec \
  -e MIX_DEPS_PATH=/workspace/deps \
  -e MIX_BUILD_ROOT=/workspace/_build/wt-promoted-challenges \
  -e MIX_TEST_PARTITION=_wt_promoted-challenges \
  -w /workspace/.claude/worktrees/promoted-challenges \
  news-verscienta-app-1 mix test path/to/test.exs
```

- For `MIX_ENV=test` migrations, add `-e MIX_ENV=test` before `news-verscienta-app-1`.
- This is a fresh build root + test partition — the first compile is slower, and the partitioned test DB may not exist yet. If a `mix test`/`mix ecto.migrate` fails with the DB not existing, run `MIX_ENV=test mix ecto.create` (wrapped) once first. If it fails with `template database "template1" has a collation version mismatch`, run once: `docker exec news-verscienta-db-1 psql -U postgres -c "ALTER DATABASE template1 REFRESH COLLATION VERSION"`.
- Never pipe `mix test` through `tail`. Run mix FOREGROUND.
- Run credo as `MIX_ENV=test mix credo`.

---

## File Structure

**Modify:**
- `lib/verscienta/gamification/quest.ex` — add 3 attributes + `featured_now` calc + `:set_promotion` action.
- `lib/verscienta_web/router.ex` — add the `/admin/challenges` route (admin scope).
- `lib/verscienta_web/live/quests_live.ex` — load `featured_now`, sort promoted-first.
- `lib/verscienta_web/live/quests_live.html.heex` — highlight promoted cards + sponsor tag.
- `lib/verscienta_web/components/legal_components.ex` — add a compact `sponsored_tag/1`.

**Create:**
- `priv/repo/migrations/<generated>_add_quest_promotion.exs` — via `mix ash.codegen`.
- `lib/verscienta/gamification/quest/changes/normalize_quest_sponsor.ex` — validation.
- `lib/verscienta_web/live/admin_challenges_live.ex` — the admin screen.
- `test/verscienta/gamification/quest_promotion_test.exs` — action/validation/calc tests.
- `test/verscienta_web/live/admin_challenges_live_test.exs` — admin screen tests.

**Modify (test):**
- `test/verscienta_web/live/quests_live_test.exs` — add a promoted-display test.

---

## Task 1: Data model + `featured_now` calc + migration

**Files:**
- Modify: `lib/verscienta/gamification/quest.ex`
- Create: `priv/repo/migrations/<generated>_add_quest_promotion.exs`
- Test: `test/verscienta/gamification/quest_promotion_test.exs`

- [ ] **Step 1: Write the failing calc test**

Create `test/verscienta/gamification/quest_promotion_test.exs`:

```elixir
defmodule Verscienta.Gamification.QuestPromotionTest do
  use Verscienta.DataCase, async: false

  alias Verscienta.Gamification.Quest

  require Ash.Query

  defp quest(attrs \\ %{}) do
    base = %{
      key: :"promo_#{System.unique_integer([:positive])}",
      name: "Promo Quest",
      cadence: :daily,
      goal_kind: :reading,
      goal_count: 3,
      points_reward: 10
    }

    Quest
    |> Ash.Changeset.for_create(:upsert, Map.merge(base, attrs))
    |> Ash.create!(authorize?: false)
  end

  defp load_featured_now(q) do
    Quest
    |> Ash.Query.filter(id == ^q.id)
    |> Ash.Query.load(:featured_now)
    |> Ash.read_one!(authorize?: false)
    |> Map.fetch!(:featured_now)
  end

  test "featured_now is true for a future featured_until, false for past/nil" do
    future = DateTime.add(DateTime.utc_now(), 3600, :second)
    past = DateTime.add(DateTime.utc_now(), -3600, :second)

    assert load_featured_now(quest(%{featured_until: future})) == true
    assert load_featured_now(quest(%{featured_until: past})) == false
    assert load_featured_now(quest(%{})) == false
  end
end
```

Note: `goal_kind: :reading` must be a valid value in `Verscienta.Gamification.GamificationEvent.kinds()`. Before running, confirm `:reading` is in that list (grep `def kinds`); if not, substitute a valid kind.

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/verscienta/gamification/quest_promotion_test.exs`
Expected: FAIL — `featured_until` is not an attribute / `featured_now` calc unknown.

- [ ] **Step 3: Add the three attributes**

In `lib/verscienta/gamification/quest.ex`, in the `attributes do` block, after `attribute :active?, ...`, add:

```elixir
    attribute :featured_until, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :sponsor_name, :string, allow_nil?: true, public?: true, constraints: [max_length: 120]
    attribute :sponsor_url, :string, allow_nil?: true, public?: true
```

- [ ] **Step 4: Add the `featured_now` calculation**

In `lib/verscienta/gamification/quest.ex`, add a `calculations do` block (after the `identities do` block, or anywhere at resource top-level). `require Ash.Query` is not needed for calculations; `expr/1` is available in the resource DSL:

```elixir
  calculations do
    calculate :featured_now,
              :boolean,
              expr(not is_nil(featured_until) and featured_until > now())
  end
```

- [ ] **Step 5: Generate the migration**

Run: `mix ash.codegen add_quest_promotion`
Expected: a new `priv/repo/migrations/<timestamp>_add_quest_promotion.exs` adding the three columns (`featured_until` timestamptz nullable; `sponsor_name`, `sponsor_url` nullable text) plus a resource snapshot. Inspect it — confirm only these three columns are added.

- [ ] **Step 6: Migrate the test database**

Run: `MIX_ENV=test mix ecto.migrate`
Expected: applies cleanly. (If the partition DB doesn't exist, run `MIX_ENV=test mix ecto.create` first, then migrate.)

- [ ] **Step 7: Run the calc test to verify it passes**

Run: `mix test test/verscienta/gamification/quest_promotion_test.exs`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/verscienta/gamification/quest.ex priv/repo/migrations/ priv/resource_snapshots/ test/verscienta/gamification/quest_promotion_test.exs
git commit -m "feat(gamification): add featured_until/sponsor fields + featured_now to Quest" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `:set_promotion` action + `NormalizeQuestSponsor` validation

**Files:**
- Modify: `lib/verscienta/gamification/quest.ex` (actions block)
- Create: `lib/verscienta/gamification/quest/changes/normalize_quest_sponsor.ex`
- Test: `test/verscienta/gamification/quest_promotion_test.exs` (extend)

- [ ] **Step 1: Write the failing validation tests**

Append to `test/verscienta/gamification/quest_promotion_test.exs`, inside the module:

```elixir
  defp set_promotion(q, attrs) do
    q
    |> Ash.Changeset.for_update(:set_promotion, attrs)
    |> Ash.update(authorize?: false)
  end

  test "promoting with only featured_until (no sponsor) succeeds" do
    future = DateTime.add(DateTime.utc_now(), 3600, :second)
    assert {:ok, updated} = set_promotion(quest(), %{featured_until: future})
    assert updated.featured_until == future
    assert is_nil(updated.sponsor_name)
  end

  test "a non-http(s) sponsor_url is rejected" do
    assert {:error, _} =
             set_promotion(quest(), %{sponsor_name: "Acme", sponsor_url: "javascript:alert(1)"})
  end

  test "a sponsor_url longer than 2048 chars is rejected" do
    long = "https://acme.test/" <> String.duplicate("a", 2048)
    assert {:error, _} = set_promotion(quest(), %{sponsor_name: "Acme", sponsor_url: long})
  end

  test "a sponsor_url without a sponsor_name is rejected" do
    assert {:error, _} = set_promotion(quest(), %{sponsor_url: "https://acme.test"})
  end

  test "clearing nils featured_until, sponsor_name and sponsor_url" do
    future = DateTime.add(DateTime.utc_now(), 3600, :second)

    {:ok, promoted} =
      set_promotion(quest(), %{
        featured_until: future,
        sponsor_name: "Acme",
        sponsor_url: "https://acme.test"
      })

    assert {:ok, cleared} =
             set_promotion(promoted, %{featured_until: nil, sponsor_name: nil, sponsor_url: nil})

    assert is_nil(cleared.featured_until)
    assert is_nil(cleared.sponsor_name)
    assert is_nil(cleared.sponsor_url)
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/verscienta/gamification/quest_promotion_test.exs`
Expected: the new tests FAIL — `No such action :set_promotion`.

- [ ] **Step 3: Add the `:set_promotion` action**

In `lib/verscienta/gamification/quest.ex`, in the `actions do` block (after the `update :update` action), add:

```elixir
    update :set_promotion do
      description "Admin action: promote/sponsor a challenge (or clear it)."
      accept [:featured_until, :sponsor_name, :sponsor_url]
      require_atomic? false
      change Verscienta.Gamification.Quest.Changes.NormalizeQuestSponsor
    end
```

- [ ] **Step 4: Create the validation change module**

Create `lib/verscienta/gamification/quest/changes/normalize_quest_sponsor.ex`:

```elixir
defmodule Verscienta.Gamification.Quest.Changes.NormalizeQuestSponsor do
  @moduledoc """
  Validates/normalizes the promotion fields on `:set_promotion`:

    * empty-string sponsor_name/sponsor_url normalize to nil;
    * a present sponsor_url must be an http/https URL (rejects javascript:, data:, …)
      and at most 2048 bytes;
    * if sponsor_url is present, sponsor_name must also be present (a link needs a label).

  Unlike the article variant, there is no `sponsored?` boolean here — a challenge may be
  promoted (featured_until) without a sponsor.
  """
  use Ash.Resource.Change

  @max_url_length 2048

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> nilify_blank(:sponsor_name)
    |> nilify_blank(:sponsor_url)
    |> maybe_validate_url()
    |> maybe_require_name()
  end

  defp nilify_blank(changeset, field) do
    case Ash.Changeset.get_attribute(changeset, field) do
      value when is_binary(value) ->
        if String.trim(value) == "",
          do: Ash.Changeset.force_change_attribute(changeset, field, nil),
          else: changeset

      _ ->
        changeset
    end
  end

  defp maybe_validate_url(%{valid?: false} = cs), do: cs

  defp maybe_validate_url(changeset) do
    case Ash.Changeset.get_attribute(changeset, :sponsor_url) do
      nil ->
        changeset

      url when is_binary(url) and byte_size(url) > @max_url_length ->
        Ash.Changeset.add_error(changeset, field: :sponsor_url, message: "is too long")

      url ->
        if http_url?(url) do
          changeset
        else
          Ash.Changeset.add_error(changeset,
            field: :sponsor_url,
            message: "must be an http or https URL"
          )
        end
    end
  end

  defp maybe_require_name(%{valid?: false} = cs), do: cs

  defp maybe_require_name(changeset) do
    url = Ash.Changeset.get_attribute(changeset, :sponsor_url)
    name = Ash.Changeset.get_attribute(changeset, :sponsor_name)

    if not is_nil(url) and is_nil(name) do
      Ash.Changeset.add_error(changeset,
        field: :sponsor_name,
        message: "is required when a sponsor link is set"
      )
    else
      changeset
    end
  end

  defp http_url?(url) do
    case URI.parse(to_string(url)) do
      %URI{scheme: scheme, host: host}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        String.downcase(scheme) in ["http", "https"]

      _ ->
        false
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/verscienta/gamification/quest_promotion_test.exs`
Expected: PASS (all calc + validation tests).

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta/gamification/quest.ex lib/verscienta/gamification/quest/changes/normalize_quest_sponsor.ex test/verscienta/gamification/quest_promotion_test.exs
git commit -m "feat(gamification): set_promotion action with sponsor validation" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Admin screen `/admin/challenges`

**Files:**
- Modify: `lib/verscienta_web/router.ex` (admin scope)
- Create: `lib/verscienta_web/live/admin_challenges_live.ex`
- Test: `test/verscienta_web/live/admin_challenges_live_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/admin_challenges_live_test.exs`:

```elixir
defmodule VerscientaWeb.AdminChallengesLiveTest do
  use VerscientaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Verscienta.Support.Factory, only: [sign_in: 2]

  alias Verscienta.Accounts.User
  alias Verscienta.Gamification.Quest

  require Ash.Query

  defp register(name, role \\ :user) do
    u =
      User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: name <> "@example.com",
        username: name,
        password: "password123",
        password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    if role == :user do
      u
    else
      u
      |> Ash.Changeset.for_update(:update_profile, %{}, actor: u)
      |> Ash.Changeset.force_change_attribute(:role, role)
      |> Ash.update!(authorize?: false)
    end
  end

  defp a_quest do
    Quest
    |> Ash.Changeset.for_create(:upsert, %{
      key: :"adm_#{System.unique_integer([:positive])}",
      name: "Admin Quest",
      cadence: :daily,
      goal_kind: :reading,
      goal_count: 3,
      points_reward: 10
    })
    |> Ash.create!(authorize?: false)
  end

  defp reload(id), do: Ash.get!(Quest, id, authorize?: false)

  test "non-admin is redirected from /admin/challenges", %{conn: conn} do
    conn = sign_in(conn, register("ac_plain")) |> get(~p"/admin/challenges")
    assert redirected_to(conn)
  end

  test "an admin can promote a quest with a future date and a sponsor", %{conn: conn} do
    admin = register("ac_admin", :admin)
    q = a_quest()

    {:ok, view, _html} = live(sign_in(conn, admin), ~p"/admin/challenges")

    view
    |> form(~s{form[phx-submit="set_promotion"][data-quest-id="#{q.id}"]}, %{
      "featured_until" => "2030-12-31T17:00",
      "sponsor_name" => "Acme Wellness",
      "sponsor_url" => "https://acme.test"
    })
    |> render_submit()

    reloaded = reload(q.id)
    assert reloaded.sponsor_name == "Acme Wellness"
    refute is_nil(reloaded.featured_until)
    # datetime-local value is interpreted as UTC
    assert DateTime.to_iso8601(reloaded.featured_until) =~ "2030-12-31T17:00:00"
  end

  test "an admin can clear a quest's promotion", %{conn: conn} do
    admin = register("ac_admin2", :admin)
    q = a_quest()

    {:ok, _} =
      q
      |> Ash.Changeset.for_update(:set_promotion, %{
        featured_until: DateTime.add(DateTime.utc_now(), 3600, :second),
        sponsor_name: "Acme"
      })
      |> Ash.update(authorize?: false)

    {:ok, view, _html} = live(sign_in(conn, admin), ~p"/admin/challenges")
    view |> element(~s{button[phx-click="clear_promotion"][phx-value-id="#{q.id}"]}) |> render_click()

    reloaded = reload(q.id)
    assert is_nil(reloaded.featured_until)
    assert is_nil(reloaded.sponsor_name)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/verscienta_web/live/admin_challenges_live_test.exs`
Expected: FAIL — route `/admin/challenges` doesn't exist.

- [ ] **Step 3: Add the route**

In `lib/verscienta_web/router.ex`, in the existing `scope "/admin", VerscientaWeb do pipe_through [:browser, :admin]` block (the one containing `:admin_flags` and `:admin_digests`), add a new `live_session`:

```elixir
    live_session :admin_challenges,
      on_mount: [
        {VerscientaWeb.LiveUserAuth, :current_user},
        {VerscientaWeb.LiveUserAuth, :admin_required}
      ] do
      live "/challenges", AdminChallengesLive, :index
    end
```

- [ ] **Step 4: Create `AdminChallengesLive`**

Create `lib/verscienta_web/live/admin_challenges_live.ex`:

```elixir
defmodule VerscientaWeb.AdminChallengesLive do
  @moduledoc "Admin screen to promote/sponsor challenges at /admin/challenges."
  use VerscientaWeb, :live_view

  alias Verscienta.Gamification.Quest

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "challenges", quests: load_quests())}
  end

  defp load_quests do
    Quest
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.load(:featured_now)
    |> Ash.read!(authorize?: false)
  end

  @impl true
  def handle_event("set_promotion", %{"id" => id} = params, socket) do
    attrs = %{
      featured_until: parse_dt(params["featured_until"]),
      sponsor_name: params["sponsor_name"],
      sponsor_url: params["sponsor_url"]
    }

    update_quest(socket, id, attrs)
  end

  def handle_event("clear_promotion", %{"id" => id}, socket) do
    update_quest(socket, id, %{featured_until: nil, sponsor_name: nil, sponsor_url: nil})
  end

  defp update_quest(socket, id, attrs) do
    quest = Ash.get!(Quest, id, authorize?: false)

    case quest
         |> Ash.Changeset.for_update(:set_promotion, attrs)
         |> Ash.update(authorize?: false) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(quests: load_quests())
         |> put_flash(:info, "Updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update — check the sponsor URL.")}
    end
  end

  # datetime-local sends "2030-12-31T17:00" (no seconds/zone). Interpret as UTC.
  defp parse_dt(nil), do: nil
  defp parse_dt(""), do: nil

  defp parse_dt(value) do
    iso = if String.length(value) == 16, do: value <> ":00", else: value

    case NaiveDateTime.from_iso8601(iso) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      _ -> nil
    end
  end

  # value for the <input type="datetime-local"> (UTC wall-clock, no seconds).
  defp dt_value(nil), do: ""
  defp dt_value(%DateTime{} = dt), do: dt |> DateTime.to_naive() |> NaiveDateTime.to_iso8601() |> String.slice(0, 16)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl px-6 pt-24 space-y-6">
      <h1 class="text-2xl font-light lowercase text-ink">challenges</h1>
      <p class="text-sm text-ink-3">Promote a challenge to pin it to the top of /quests, optionally with a sponsor. Times are UTC.</p>

      <div :for={q <- @quests} class={["rounded p-4 bg-canvas-2", q.featured_now && "border border-zune"]}>
        <div class="flex items-center justify-between">
          <div>
            <h3 class="font-semibold text-ink">{q.name}</h3>
            <p class="text-xs text-ink-3">{q.cadence} · {q.active? && "active" || "inactive"}<span :if={q.featured_now} class="text-zune"> · promoted</span></p>
          </div>
          <button
            :if={q.featured_now || q.sponsor_name}
            type="button"
            phx-click="clear_promotion"
            phx-value-id={q.id}
            class="text-xs text-ink-3 hover:text-ink"
          >
            clear promotion
          </button>
        </div>

        <form phx-submit="set_promotion" data-quest-id={q.id} class="mt-3 flex flex-wrap items-end gap-3">
          <input type="hidden" name="id" value={q.id} />
          <label class="text-[11px] uppercase tracking-wider text-ink-3">
            promote until (UTC)
            <input type="datetime-local" name="featured_until" value={dt_value(q.featured_until)}
              class="mt-1 block border border-line bg-canvas px-2 py-1 text-xs text-ink" />
          </label>
          <label class="text-[11px] uppercase tracking-wider text-ink-3">
            sponsor name
            <input type="text" name="sponsor_name" value={q.sponsor_name} placeholder="optional"
              class="mt-1 block border border-line bg-canvas px-2 py-1 text-xs text-ink" />
          </label>
          <label class="text-[11px] uppercase tracking-wider text-ink-3">
            sponsor url
            <input type="text" name="sponsor_url" value={q.sponsor_url} placeholder="https://…"
              class="mt-1 block border border-line bg-canvas px-2 py-1 text-xs text-ink" />
          </label>
          <button type="submit" class="border border-zune px-3 py-1.5 text-xs text-zune hover:bg-zune hover:text-black">save</button>
        </form>
      </div>
    </div>
    """
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/verscienta_web/live/admin_challenges_live_test.exs`
Expected: PASS (3 tests). If the datetime assertion fails, inspect the stored value and confirm `parse_dt/1` appends `:00` and uses `"Etc/UTC"`.

- [ ] **Step 6: Compile with warnings as errors**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add lib/verscienta_web/router.ex lib/verscienta_web/live/admin_challenges_live.ex test/verscienta_web/live/admin_challenges_live_test.exs
git commit -m "feat(web): admin /admin/challenges screen to promote/sponsor challenges" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: `/quests` display — pin promoted + sponsor disclosure

**Files:**
- Modify: `lib/verscienta_web/components/legal_components.ex` (add `sponsored_tag/1`)
- Modify: `lib/verscienta_web/live/quests_live.ex` (load `featured_now`, sort)
- Modify: `lib/verscienta_web/live/quests_live.html.heex` (highlight + tag)
- Test: `test/verscienta_web/live/quests_live_test.exs` (extend)

- [ ] **Step 1: Add a compact `sponsored_tag/1` component**

In `lib/verscienta_web/components/legal_components.ex`, add inside the module (after `sponsored_disclosure/1`):

```elixir
  @doc """
  Compact inline sponsor tag for dense surfaces (e.g. a challenge card). Renders nothing
  unless a sponsor_name is present. Shares the FTC paid-link rel of the full disclosure.
  """
  attr :sponsor_name, :string, default: nil
  attr :sponsor_url, :string, default: nil

  def sponsored_tag(assigns) do
    ~H"""
    <span
      :if={@sponsor_name not in [nil, ""]}
      class="inline-flex items-center gap-1 text-[10px] font-extrabold uppercase tracking-wider text-zune"
    >
      Sponsored by
      <a
        :if={@sponsor_url not in [nil, ""]}
        href={@sponsor_url}
        rel="sponsored nofollow noopener noreferrer"
        target="_blank"
        class="underline hover:text-ink"
      >{@sponsor_name}</a><span :if={@sponsor_url in [nil, ""]}>{@sponsor_name}</span>
    </span>
    """
  end
```

- [ ] **Step 2: Write the failing display test**

Append to `test/verscienta_web/live/quests_live_test.exs`, inside the module:

```elixir
  alias Verscienta.Gamification.Quest

  require Ash.Query

  test "a promoted, sponsored challenge shows the sponsor tag on /quests", %{conn: conn} do
    Seeds.seed_quests!()
    u = register("promo_user")
    assert :ok = perform_job(QuestAssignerWorker, %{})

    # Promote a seeded daily quest with a sponsor.
    quest =
      Quest
      |> Ash.Query.filter(cadence == :daily and active? == true)
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)
      |> List.first()

    {:ok, _} =
      quest
      |> Ash.Changeset.for_update(:set_promotion, %{
        featured_until: DateTime.add(DateTime.utc_now(), 86_400, :second),
        sponsor_name: "Acme Wellness",
        sponsor_url: "https://acme.test"
      })
      |> Ash.update(authorize?: false)

    {:ok, _view, html} = live(sign_in(conn, u), ~p"/quests")

    assert html =~ "Sponsored by"
    assert html =~ "Acme Wellness"
    assert html =~ ~s(rel="sponsored nofollow noopener noreferrer")
  end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/verscienta_web/live/quests_live_test.exs`
Expected: the new test FAILS — `/quests` doesn't render the sponsor tag yet.

- [ ] **Step 4: Load `featured_now` + sponsor fields and sort promoted-first in `QuestsLive`**

In `lib/verscienta_web/live/quests_live.ex`, replace the `quest_by_id` read so it loads the calc, and sort the returned assignments promoted-first. Update `load/1`:

```elixir
  defp load(user) do
    today = local_today(user.timezone)

    assignments =
      QuestAssignment
      |> Ash.Query.filter(
        user_id == ^user.id and period_start_date <= ^today and period_end_date >= ^today
      )
      |> Ash.read!(authorize?: false)

    quest_by_id =
      case assignments |> Enum.map(& &1.quest_id) |> Enum.uniq() do
        [] ->
          %{}

        ids ->
          Quest
          |> Ash.Query.filter(id in ^ids)
          |> Ash.Query.load(:featured_now)
          |> Ash.read!(authorize?: false)
          |> Map.new(&{&1.id, &1})
      end

    assignments
    |> Enum.map(fn a -> Map.put(a, :quest, Map.fetch!(quest_by_id, a.quest_id)) end)
    |> Enum.sort_by(fn a -> if a.quest.featured_now, do: 0, else: 1 end)
  end
```

(`Enum.sort_by/2` is stable, so within each cadence section — which the template filters out of this list — promoted challenges keep their order but sort ahead of non-promoted ones.)

- [ ] **Step 5: Highlight promoted cards + render the sponsor tag**

In `lib/verscienta_web/live/quests_live.html.heex`, update BOTH the daily (`Today`) and weekly (`This week`) `<article>` blocks. For each, change the `<article class={...}>` to add a promoted border, and add the sponsor tag under the description. Replace each article block's opening + the title/description `<div>` with:

```heex
      <article class={["rounded p-4 bg-canvas-2", a.completed_at && "opacity-70", a.quest.featured_now && "border border-zune"]}>
        <div class="flex items-center justify-between">
          <div>
            <h3 class="font-semibold text-ink">{a.quest.name}</h3>
            <p class="text-sm text-ink-3">{a.quest.description}</p>
            <VerscientaWeb.LegalComponents.sponsored_tag
              sponsor_name={a.quest.sponsor_name}
              sponsor_url={a.quest.sponsor_url}
            />
          </div>
          <div class="text-right">
            <div class="text-sm text-ink-3">{a.progress} / {a.goal_count}</div>
            <%= if a.completed_at do %>
              <span class="text-xs text-ink">+{a.points_reward} pts</span>
            <% end %>
          </div>
        </div>
        <progress class="w-full mt-2" value={a.progress} max={a.goal_count}></progress>
      </article>
```

Apply this same change in both the daily and weekly `<%= for a <- ... %>` loops (the markup is identical; only the surrounding cadence filter differs).

- [ ] **Step 6: Run the display test + existing quests tests**

Run: `mix test test/verscienta_web/live/quests_live_test.exs`
Expected: PASS (existing tests + the new promoted-display test).

- [ ] **Step 7: Compile with warnings as errors**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add lib/verscienta_web/components/legal_components.ex lib/verscienta_web/live/quests_live.ex lib/verscienta_web/live/quests_live.html.heex test/verscienta_web/live/quests_live_test.exs
git commit -m "feat(web): pin promoted challenges + sponsor tag on /quests" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Full verification + todo checkoff

**Files:**
- Modify: `docs/todo.md`

- [ ] **Step 1: Run the full feature test set**

Run: `mix test test/verscienta/gamification/quest_promotion_test.exs test/verscienta_web/live/admin_challenges_live_test.exs test/verscienta_web/live/quests_live_test.exs test/verscienta/gamification/quest_assigner_test.exs test/verscienta/gamification/quest_progress_test.exs test/verscienta/gamification/seeds_quest_test.exs`
Expected: all PASS (the existing quest tests confirm no regression to the `Quest` resource).

- [ ] **Step 2: Format check**

Run: `mix format --check-formatted`
Expected: no output. If it fails, run `mix format`, then `git add -A && git commit -m "chore(gamification): mix format promoted challenges" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"`.

- [ ] **Step 3: Credo**

Run: `MIX_ENV=test mix credo`
Expected: no new issues in the feature's files (`quest.ex`, `normalize_quest_sponsor.ex`, `admin_challenges_live.ex`, `quests_live.ex`, `legal_components.ex`). If credo flags nesting/complexity in the new code, fix it (extract a helper) and re-commit.

- [ ] **Step 4: Full compile with warnings as errors**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 5: Full test suite**

Run: `mix test`
Expected: green. Pre-existing flakes (seed contamination, postgrex type-cache race) are unrelated — re-run a failing file in isolation to confirm it's not caused by this feature.

- [ ] **Step 6: Check off the todo item**

In `docs/todo.md`, change:
```
- [ ] Featured / promoted challenges.
```
to:
```
- [x] Featured / promoted challenges. *(time-boxed `featured_until` + `featured_now` on Quest + optional sponsor (name/url, validated http(s) ≤2048, name-required-with-link); admin-only `/admin/challenges` LiveView with a datetime-local campaign picker (UTC) to promote/clear; `/quests` pins promoted challenges first + shows an FTC `sponsored_tag` (rel="sponsored nofollow noopener noreferrer"); display-only — assignment/rewards unchanged; respects the `:quests` flag. Spec/plan: `docs/superpowers/{specs,plans}/2026-06-15-promoted-challenges*`)*
```

- [ ] **Step 7: Commit**

```bash
git add docs/todo.md
git commit -m "docs: check off featured/promoted challenges (phase 4 monetization 2/3)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review notes (already reconciled)

- **Spec coverage:** data model + `featured_now` (Task 1) · `:set_promotion` action + validation incl. url scheme/length + name-required-with-link + clear-nils (Task 2) · admin-only `/admin/challenges` with datetime-local UTC parsing + clear (Task 3) · `/quests` promoted-first sort + highlight + reused-idiom sponsor tag (Task 4) · full verification + todo (Task 5). Out-of-scope items (bonus rewards, targeting, tracking, Sponsor resource, full CRUD, per-admin tz) intentionally absent.
- **Authorization deviation from spec's hedge:** spec said "if Source uses Ash policies, add a parallel admin policy to Quest." Source DOES use policies, but `Quest` has no authorizers and is read pervasively with `authorize?: false` (seeds/workers/QuestsLive); adding `Ash.Policy.Authorizer` would risk those paths. Decision: gate at the admin route (`:admin_required` on_mount) and call `:set_promotion` with `authorize?: false`. The route test (non-admin redirected) covers the gate. This is appropriate for a seed-only system catalog with no public write path.
- **Type/name consistency:** action `:set_promotion` accepts `[:featured_until, :sponsor_name, :sponsor_url]` everywhere; change module `NormalizeQuestSponsor`; calc `featured_now`; component `sponsored_tag/1` (attrs `sponsor_name`/`sponsor_url`); LiveView events `set_promotion`/`clear_promotion` (both keyed by `id`); helpers `parse_dt/1`/`dt_value/1`. Consistent across tasks.
- **Open implementation discretion (acceptable):** confirm `:reading` is a valid `goal_kind` (Task 1 Step 1 note); the exact seeded daily quest selected in the Task 4 test is whichever the filter returns first (any active daily quest works).
```
