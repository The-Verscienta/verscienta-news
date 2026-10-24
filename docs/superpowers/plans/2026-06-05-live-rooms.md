# Live Rooms — Core + Live Messaging Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A group-attached live chat room — members open `/groups/:slug/room`, see who's present, and exchange persisted messages that appear live for everyone.

**Architecture:** `Communities.Room` (one per group, find-or-create) + `Communities.Message` (persisted). `RoomLive` subscribes to a `"room:<id>"` PubSub topic, streams message history, broadcasts new messages, and tracks `Phoenix.Presence`. Member-gated; behind the existing `:live_rooms` flag.

**Tech Stack:** Elixir, Ash 3, Phoenix LiveView (streams), `Phoenix.PubSub` (`Verscienta.PubSub`), `Phoenix.Presence` (new), FunWithFlags `Gate`. All `mix` runs in Docker: `docker compose exec -T app mix …`.

**Spec:** `docs/superpowers/specs/2026-06-05-live-rooms-design.md`
**Branch:** `phase-3-live-rooms` (spec already committed here).

**Confirmed facts:**
- `Verscienta.Communities` domain has `membership/2`, `role/2`, `member?/2`, `can_moderate?/2`; roles `[:owner, :mod, :member]`, membership `status: :active`. Register new resources in its `resources do` block.
- `:live_rooms` is ALREADY in `Verscienta.Flags` `@known_flags` (no flag to add — just gate + enable in tests).
- PubSub server is `Verscienta.PubSub`; supervision children are in `lib/verscienta/application.ex` (the `{Phoenix.PubSub, name: Verscienta.PubSub}` child).
- Group routes are gated via a `:gate_communities` pipeline (`plug VerscientaWeb.Plugs.Gate, flag: :communities`) — mirror it for `:gate_live_rooms`. READ the router's `pipeline :gate_communities` + the `ash_authentication_live_session :gated_communities_auth_routes` block.
- Group has a slug; READ `lib/verscienta/communities/group.ex` for the by-slug read + relationships.

---

## File Structure

**Create:**
- `lib/verscienta/communities/room.ex`, `lib/verscienta/communities/message.ex`.
- `lib/verscienta_web/presence.ex`.
- `lib/verscienta_web/live/room_live.ex`.
- migration(s) for `rooms` + `messages`.
- tests: `test/verscienta/communities/room_test.exs`, `test/verscienta_web/live/room_live_test.exs`.

**Modify:**
- `lib/verscienta/communities.ex` (register resources + helpers).
- `lib/verscienta/application.ex` (Presence child).
- `lib/verscienta_web/router.ex` (`:gate_live_rooms` pipeline + room route).
- `lib/verscienta/communities/group.ex` (`has_one :room`).
- `docs/todo.md`.

---

## Task 1: `Room` + `Message` resources + Communities helpers

**Files:** create `room.ex`, `message.ex`, `test/verscienta/communities/room_test.exs`; modify `communities.ex`, `group.ex`; migration.

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/communities/room_test.exs` (READ an existing communities test e.g. `group_test.exs` for how groups + memberships are created; adapt the `group`/`member` helpers to the real create actions):
```elixir
defmodule Verscienta.Communities.RoomTest do
  use Verscienta.DataCase, async: true

  alias Verscienta.Communities

  defp user(name) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com", username: name,
      password: "password123", password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  # Create a group owned by `owner` (READ group.ex for the real create action + accepted attrs).
  defp group(owner, name) do
    {:ok, g} =
      Verscienta.Communities.Group
      |> Ash.Changeset.for_create(:create, %{name: name}, actor: owner)
      |> Ash.create()

    g
  end

  test "room_for_group is idempotent (one room per group)" do
    o = user("roomowner")
    g = group(o, "Herbalists")
    r1 = Communities.room_for_group(g)
    r2 = Communities.room_for_group(g)
    assert r1.id == r2.id
    assert r1.group_id == g.id
  end

  test "a member can post; recent_messages returns oldest→newest" do
    o = user("ro2")
    g = group(o, "Movement")
    r = Communities.room_for_group(g)

    {:ok, _} = Communities.post_message(r, o, "first")
    {:ok, _} = Communities.post_message(r, o, "second")

    bodies = Communities.recent_messages(r) |> Enum.map(& &1.body)
    assert bodies == ["first", "second"]
  end

  test "a non-member's post is rejected" do
    o = user("ro3")
    stranger = user("stranger3")
    g = group(o, "Private Topic")
    r = Communities.room_for_group(g)

    assert {:error, _} = Communities.post_message(r, stranger, "intrusion")
  end
end
```
(If the group `:create` action accepts more required attrs or auto-creates an owner membership, adjust `group/2` accordingly — READ `group.ex`. The owner MUST end up an active member so `post_message` by the owner succeeds; if creating a group does not auto-add an owner membership, create one explicitly in the helper.)

- [ ] **Step 2: Run it (fails — no resources/helpers)**

`docker compose exec -T app mix test test/verscienta/communities/room_test.exs` → FAIL.

- [ ] **Step 3: Implement**

(a) `lib/verscienta/communities/room.ex`:
```elixir
defmodule Verscienta.Communities.Room do
  @moduledoc "A group's live chat room (one per group)."
  use Ash.Resource, domain: Verscienta.Communities, data_layer: AshPostgres.DataLayer

  postgres do
    table "rooms"
    repo Verscienta.Repo
  end

  actions do
    defaults [:read]

    create :find_or_create_for_group do
      accept [:group_id]
      upsert? true
      upsert_identity :unique_group
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :topic, :string, allow_nil?: true, public?: true
    attribute :status, :atom,
      constraints: [one_of: [:open, :closed]],
      default: :open,
      allow_nil?: false,
      public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_group, [:group_id]
  end

  relationships do
    belongs_to :group, Verscienta.Communities.Group, allow_nil?: false
    has_many :messages, Verscienta.Communities.Message
  end
end
```

(b) `lib/verscienta/communities/message.ex`:
```elixir
defmodule Verscienta.Communities.Message do
  @moduledoc "A message posted in a group's live room."
  use Ash.Resource, domain: Verscienta.Communities, data_layer: AshPostgres.DataLayer

  postgres do
    table "room_messages"
    repo Verscienta.Repo
  end

  actions do
    defaults [:read]

    create :post do
      accept [:room_id, :body]
      change relate_actor(:user)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :body, :string, allow_nil?: false, public?: true, constraints: [max_length: 2000, min_length: 1]
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :room, Verscienta.Communities.Room, allow_nil?: false
    belongs_to :user, Verscienta.Accounts.User, allow_nil?: false
  end
end
```

(c) In `lib/verscienta/communities.ex`: register the resources and add the helpers:
```elixir
  resources do
    resource Verscienta.Communities.Group
    resource Verscienta.Communities.GroupMembership
    resource Verscienta.Communities.Room
    resource Verscienta.Communities.Message
  end
```
and (after the existing helpers):
```elixir
  alias Verscienta.Communities.{Message, Room}

  @doc "The group's room, creating it on first access."
  def room_for_group(group) do
    Room
    |> Ash.Changeset.for_create(:find_or_create_for_group, %{group_id: group.id})
    |> Ash.create!(authorize?: false)
  end

  @doc "Post a message to a room as `user` (members only). Returns {:ok, message} | {:error, _}."
  def post_message(room, user, body) do
    if member?(user, %{id: room.group_id}) do
      Message
      |> Ash.Changeset.for_create(:post, %{room_id: room.id, body: body}, actor: user)
      |> Ash.create()
    else
      {:error, :not_a_member}
    end
  end

  @doc "The most recent `limit` messages for a room, oldest→newest, with `:user` loaded."
  def recent_messages(room, limit \\ 50) do
    Message
    |> Ash.Query.filter(room_id == ^room.id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.load(:user)
    |> Ash.read!(authorize?: false)
    |> Enum.reverse()
  end
```
(Ensure `require Ash.Query` is present in `communities.ex` — it already is per the existing `membership/2`. `member?(user, %{id: room.group_id})` works because `member?`→`membership` only reads `group.id`.)

(d) In `lib/verscienta/communities/group.ex`, add to `relationships do`:
```elixir
    has_one :room, Verscienta.Communities.Room
```

(e) Migration:
```bash
docker compose exec -T app mix ash.codegen add_live_rooms
docker compose exec -T app mix ash.migrate
```
Confirm migrations create `rooms` (unique index on `group_id`) and `room_messages`.

- [ ] **Step 4: Run the test (passes)**

`docker compose exec -T app mix test test/verscienta/communities/room_test.exs` → PASS.

- [ ] **Step 5: format, warnings, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix compile --force --warnings-as-errors 2>&1 | tail -4
docker compose exec -T app mix credo --strict lib/verscienta/communities 2>&1 | tail -4
git add lib/verscienta/communities priv/repo/migrations priv/resource_snapshots test/verscienta/communities/room_test.exs
git commit -m "feat(live-rooms): Room + Message resources + Communities helpers"
```

---

## Task 2: `VerscientaWeb.Presence` + supervision + `:gate_live_rooms` pipeline

**Files:** create `lib/verscienta_web/presence.ex`; modify `lib/verscienta/application.ex`, `lib/verscienta_web/router.ex`.

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/presence_test.exs`:
```elixir
defmodule VerscientaWeb.PresenceTest do
  use ExUnit.Case, async: true

  alias VerscientaWeb.Presence

  test "tracks and lists a presence under a topic" do
    topic = "room:test-#{System.unique_integer([:positive])}"
    {:ok, _ref} = Presence.track(self(), topic, "user-1", %{username: "alice"})
    assert %{"user-1" => %{metas: [%{username: "alice"} | _]}} = Presence.list(topic)
  end
end
```

- [ ] **Step 2: Run it (fails — Presence undefined)**

`docker compose exec -T app mix test test/verscienta_web/presence_test.exs` → FAIL.

- [ ] **Step 3: Implement**

(a) `lib/verscienta_web/presence.ex`:
```elixir
defmodule VerscientaWeb.Presence do
  @moduledoc "Tracks who is present in a live room (and future real-time surfaces)."
  use Phoenix.Presence, otp_app: :verscienta, pubsub_server: Verscienta.PubSub
end
```

(b) In `lib/verscienta/application.ex`, add `VerscientaWeb.Presence` to the supervision `children` list, AFTER the `{Phoenix.PubSub, name: Verscienta.PubSub}` child and before/around the Endpoint (Presence needs PubSub started first):
```elixir
        {Phoenix.PubSub, name: Verscienta.PubSub},
        VerscientaWeb.Presence,
```

(c) In `lib/verscienta_web/router.ex`, add a gate pipeline mirroring `:gate_communities` (READ the existing `pipeline :gate_communities do plug VerscientaWeb.Plugs.Gate, flag: :communities end`):
```elixir
  pipeline :gate_live_rooms do
    plug VerscientaWeb.Plugs.Gate, flag: :live_rooms
  end
```
(Do not add the route yet — Task 3 adds it.)

- [ ] **Step 4: Run the test (passes) + app boots**

```bash
docker compose exec -T app mix test test/verscienta_web/presence_test.exs 2>&1 | tail -4
docker compose exec -T app mix compile --force --warnings-as-errors 2>&1 | tail -4
```
Expected: PASS; clean compile (the new pipeline is defined but unused yet — that's fine).

- [ ] **Step 5: format, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix credo --strict lib/verscienta_web/presence.ex lib/verscienta/application.ex 2>&1 | tail -4
git add lib/verscienta_web/presence.ex lib/verscienta/application.ex lib/verscienta_web/router.ex test/verscienta_web/presence_test.exs
git commit -m "feat(live-rooms): Phoenix.Presence + supervision + gate_live_rooms pipeline"
```

---

## Task 3: `RoomLive` + route + live messaging

**Files:** create `lib/verscienta_web/live/room_live.ex`, `test/verscienta_web/live/room_live_test.exs`; modify `lib/verscienta_web/router.ex`.

**Before implementing:** READ the router's `ash_authentication_live_session :gated_communities_auth_routes` (or the gated communities scope holding `/groups/:slug/manage`) to see the exact `scope`/`pipe_through`/`live_session`/`on_mount` shape; READ `group.ex` for the by-slug read; READ a streaming LiveView and `category_live.ex` for the assigns/`current_user` style.

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/room_live_test.exs`:
```elixir
defmodule VerscientaWeb.RoomLiveTest do
  use VerscientaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias AshAuthentication.Plug.Helpers
  alias Verscienta.Communities

  setup do
    FunWithFlags.enable(:communities)
    FunWithFlags.enable(:live_rooms)
    on_exit(fn ->
      FunWithFlags.disable(:communities)
      FunWithFlags.disable(:live_rooms)
    end)
    :ok
  end

  defp user(name) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: name <> "@example.com", username: name,
      password: "password123", password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp sign_in(conn, u), do: conn |> Plug.Test.init_test_session(%{}) |> Helpers.store_in_session(u)

  defp group(owner, name) do
    {:ok, g} =
      Verscienta.Communities.Group
      |> Ash.Changeset.for_create(:create, %{name: name}, actor: owner)
      |> Ash.create()
    g
  end

  # Ensure `u` is an active member of `g` (READ group_membership.ex create action).
  defp join(g, u) do
    Verscienta.Communities.GroupMembership
    |> Ash.Changeset.for_create(:create, %{group_id: g.id, user_id: u.id, role: :member, status: :active}, authorize?: false)
    |> Ash.create!()
  end

  test "a member sees the composer and posts a message that renders", %{conn: conn} do
    o = user("rlowner")
    g = group(o, "Live Herbalists")

    {:ok, lv, html} = conn |> sign_in(o) |> live(~p"/groups/#{g.slug}/room")
    assert html =~ "Live Herbalists" or html =~ "room"

    lv |> form("#room-composer", %{"body" => "hello room"}) |> render_submit()
    assert render(lv) =~ "hello room"
  end

  test "a second member receives a broadcast message live", %{conn: conn} do
    o = user("rlowner2")
    other = user("rlmember2")
    g = group(o, "Broadcast Group")
    join(g, other)

    {:ok, lv_owner, _} = conn |> sign_in(o) |> live(~p"/groups/#{g.slug}/room")
    {:ok, lv_other, _} = build_conn() |> sign_in(other) |> live(~p"/groups/#{g.slug}/room")

    lv_owner |> form("#room-composer", %{"body" => "live ping"}) |> render_submit()

    assert render(lv_other) =~ "live ping"
  end

  test "a non-member is redirected to the group page", %{conn: conn} do
    o = user("rlowner3")
    stranger = user("rlstranger3")
    g = group(o, "Members Only")

    assert {:error, {:live_redirect, %{to: path}}} =
             conn |> sign_in(stranger) |> live(~p"/groups/#{g.slug}/room")
    assert path =~ "/groups/" <> g.slug
  end
end
```
(Adjust `group/2` + `join/3` to the real create actions — the owner likely becomes an active owner-membership automatically on group create; if so, the owner needs no explicit `join`. READ `group.ex`/`group_membership.ex`.)

- [ ] **Step 2: Run it (fails — no LiveView/route)**

`docker compose exec -T app mix test test/verscienta_web/live/room_live_test.exs` → FAIL.

- [ ] **Step 3: Implement**

(a) Create `lib/verscienta_web/live/room_live.ex`:
```elixir
defmodule VerscientaWeb.RoomLive do
  @moduledoc "A group's live chat room — streamed history, live messages, presence."
  use VerscientaWeb, :live_view

  on_mount {VerscientaWeb.LiveUserAuth, :live_user_required}

  require Ash.Query

  alias Verscienta.Communities
  alias VerscientaWeb.Presence

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    user = socket.assigns.current_user
    group = load_group(slug)

    cond do
      is_nil(group) ->
        {:ok, push_navigate(socket, to: ~p"/groups")}

      not Communities.member?(user, group) ->
        {:ok,
         socket
         |> put_flash(:info, "Join the group to enter its room.")
         |> push_navigate(to: ~p"/groups/#{slug}")}

      true ->
        room = Communities.room_for_group(group)
        topic = "room:#{room.id}"

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Verscienta.PubSub, topic)
          Presence.track(self(), topic, to_string(user.id), %{username: to_string(user.username)})
        end

        {:ok,
         socket
         |> assign(
           group: group,
           room: room,
           topic: topic,
           page_title: group.name,
           seo: VerscientaWeb.SEO.build(noindex: true),
           present: presence_users(topic)
         )
         |> stream(:messages, Communities.recent_messages(room))}
    end
  end

  @impl true
  def handle_event("send", %{"body" => body}, socket) do
    body = String.trim(body || "")

    if body == "" do
      {:noreply, socket}
    else
      case Communities.post_message(socket.assigns.room, socket.assigns.current_user, body) do
        {:ok, message} ->
          message = Ash.load!(message, :user)
          Phoenix.PubSub.broadcast(Verscienta.PubSub, socket.assigns.topic, {:new_message, message})
          {:noreply, socket}

        {:error, _} ->
          {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_info({:new_message, message}, socket) do
    {:noreply, stream_insert(socket, :messages, message)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, present: presence_users(socket.assigns.topic))}
  end

  defp load_group(slug) do
    Verscienta.Communities.Group
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.read_one!(authorize?: false)
  end

  defp presence_users(topic) do
    Presence.list(topic)
    |> Enum.map(fn {_id, %{metas: [meta | _]}} -> meta.username end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-6 pb-24 pt-28">
      <.kicker>live room</.kicker>
      <.headline class="mb-2 text-4xl">{@group.name}</.headline>
      <p :if={@room.topic} class="mb-2 text-ink-3">{@room.topic}</p>

      <p class="mb-6 text-[11px] uppercase tracking-widest text-ink-3">
        here now: {Enum.join(@present, ", ")}
      </p>

      <div id="messages" phx-update="stream" class="mb-6 flex flex-col gap-2">
        <div :for={{dom_id, m} <- @streams.messages} id={dom_id} class="text-sm">
          <span class="font-semibold text-ink">{m.user.username}</span>
          <span class="text-ink">{m.body}</span>
        </div>
      </div>

      <form id="room-composer" phx-submit="send" class="flex gap-2">
        <input
          type="text"
          name="body"
          autocomplete="off"
          placeholder="message…"
          class="w-full border border-line bg-canvas-2 px-4 py-3 text-ink"
        />
        <button type="submit" class="bg-zune px-5 py-3 text-sm font-semibold uppercase text-canvas">
          send
        </button>
      </form>
    </div>
    """
  end
end
```
(If `<.kicker>`/`<.headline>` aren't auto-imported, `import VerscientaWeb.CodexComponents` — match `category_live.ex`. If `m.user.username` is a CiString, `to_string/1` it in the template or rely on `Phoenix.HTML` protocol; render `{m.user.username}` works if it implements `String.Chars` — it does. The form must reset the input after submit: add `phx-hook` or rely on `phx-submit` clearing; if the input doesn't clear, give the form `phx-submit="send"` and reset via assigning a changing `id` or use `<form ... >` with a key — simplest: leave it; the test doesn't assert clearing. If clearing matters, wrap the input value in an assign and reset it.)

(b) In `lib/verscienta_web/router.ex`, add the room route. Mirror the existing gated-communities authenticated live_session, but pipe through `:gate_live_rooms` too. The cleanest: add a new scope:
```elixir
  scope "/", VerscientaWeb do
    pipe_through [:browser, :gate_communities, :gate_live_rooms]

    ash_authentication_live_session :live_rooms_routes,
      on_mount: [{VerscientaWeb.LiveUserAuth, :live_user_required}] do
      live "/groups/:slug/room", RoomLive, :show
    end
  end
```
(READ how the existing `ash_authentication_live_session :gated_communities_auth_routes` is declared — match its `on_mount` list and structure. If that block already pipes `:gate_communities`, you can add `/groups/:slug/room` there and add `:gate_live_rooms` to its `pipe_through`. Avoid duplicate `live_session` names.)

- [ ] **Step 4: Run the test (passes) + regression**

```bash
docker compose exec -T app mix test test/verscienta_web/live/room_live_test.exs 2>&1 | tail -6
docker compose exec -T app mix test test/verscienta_web/live/ 2>&1 | tail -4
```
Expected: PASS. If the second-member broadcast test is racy (the broadcast/stream_insert is async over the LV process), `render(lv_other)` after `render_submit` on the owner should already reflect it because `render_submit` is synchronous and the broadcast is delivered before the subsequent `render/1` resolves; if flaky, add a tiny `Process.sleep(50)` before the assert or assert via `render(lv_other)` in a retry — but try without first.

- [ ] **Step 5: format, warnings, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix compile --force --warnings-as-errors 2>&1 | tail -4
docker compose exec -T app mix credo --strict lib/verscienta_web/live/room_live.ex 2>&1 | tail -4
git add lib/verscienta_web/live/room_live.ex lib/verscienta_web/router.ex test/verscienta_web/live/room_live_test.exs
git commit -m "feat(live-rooms): RoomLive — streamed history, live messages, presence"
```

---

## Task 4: Docs + full verification

**Files:** modify `docs/todo.md`.

- [ ] **Step 1: Check off the todo items**

In `docs/todo.md` under "### Live Rooms & Real-time":
- `- [ ] Live discussion rooms via Phoenix Channels + Presence.` → `- [x] Live discussion rooms via LiveView + PubSub + Phoenix.Presence. *(group-attached rooms; slice 1)*`
- `- [~] Room lifecycle (create/join/leave, moderation controls).` (mark partial — find-or-create + member join/presence done; moderation is slice 3) → `- [~] Room lifecycle (create/join/leave, moderation controls). *(find-or-create + member presence join/leave done; moderation = slice 3)*`
- `- [~] Live reactions / typing indicators / online presence.` (online presence done; reactions/typing slice 2) → `- [~] Live reactions / typing indicators / online presence. *(online presence done; reactions + typing = slice 2)*`

- [ ] **Step 2: Full suite + format**

```bash
docker compose exec -T app bash -lc 'mix format && mix format --check-formatted && mix test 2>&1 | tail -6'
```
Expected: format clean; 0 failures. (Known flake: `NotificationBellTest`; re-run once if it's the only failure.)

- [ ] **Step 3: Warnings + Credo + Dialyzer**

```bash
docker compose exec -T app mix compile --force --warnings-as-errors 2>&1 | tail -4
docker compose exec -T app mix credo --strict 2>&1 | tail -4
docker compose exec -T app mix dialyzer 2>&1 | tail -8
```
Expected: compile no warnings; credo "found no issues"; dialyzer "passed successfully". If dialyzer reports NEW errors (the Presence module / Ash resource specs are likely sources), paste them; do NOT commit on red.

- [ ] **Step 4: Commit**

```bash
git add docs/todo.md
git commit -m "docs: check off live rooms core + messaging (slice 1)"
```

- [ ] **Step 5:** Confirm all gates green — branch ready to merge.

---

## Notes for the implementer

- Rooms are **group-attached**: access is gated at the LiveView (`Communities.member?`) AND posting is guarded in `Communities.post_message/3`; non-members are redirected to `/groups/:slug`.
- `room_for_group/1` is an upsert (`find_or_create_for_group`, `upsert_identity :unique_group`) so concurrent first-access can't create two rooms.
- The message broadcast path is single: `post_message` → `broadcast {:new_message, msg}` → `handle_info` → `stream_insert` (the SENDER also receives its own broadcast, so it renders via the same path — do NOT also `stream_insert` synchronously in `handle_event`, or it double-renders).
- Presence is tracked only on `connected?(socket)`; `presence_diff` messages arrive because `Phoenix.Presence` broadcasts on the same topic the LiveView subscribed to.
- `:live_rooms` already exists as a flag; tests enable it (+ `:communities`) via `FunWithFlags.enable/1` in setup.
- Keep `body` validation server-side (`min_length: 1`, `max_length: 2000`, trim + ignore blank in the handler).
- `noindex` on the room (private real-time surface).
- Moderation (remove/kick/lock), typing indicators, and live reactions are explicitly OUT — slices 2 and 3.
