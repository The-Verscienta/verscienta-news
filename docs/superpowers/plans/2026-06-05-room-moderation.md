# Live Rooms — Moderation Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Room moderators (group owner/mod) can remove a message, lock/unlock the room (read-only), and ban a participant from the chat — all gated by `can_moderate?` and propagated live.

**Architecture:** `Message` gains soft-delete; `Room` gains a status toggle; a new `RoomBan` resource backs room-level bans. Context helpers (`remove_message/2`, `lock_room/3`, `ban_user/3`, `unban/3`, `banned?/2`) enforce `can_moderate?` + the ban/lock rules. `RoomLive` adds mod-only UI and live `{:message_removed}`/`{:room_status}`/`{:banned}` handlers (force-disconnect on ban).

**Tech Stack:** Elixir, Ash 3, Phoenix LiveView (streams), `Phoenix.PubSub`/Presence. All `mix` runs in Docker: `docker compose exec -T app mix …`.

**Spec:** `docs/superpowers/specs/2026-06-05-room-moderation-design.md`
**Branch:** `phase-3-room-moderation` (spec already committed here).

**Confirmed facts:**
- `Communities.can_moderate?(user, group)` = role in `[:owner, :mod]`; `member?/2`, `role/2`, `membership/2` exist; `member?`/`can_moderate?`/`role` only read `group.id`, so a bare `%{id: room.group_id}` works.
- `Comment.:soft_delete`: `accept []`, `require_atomic? false`, `change set_attribute(:deleted_at, &DateTime.utc_now/0)`.
- `Message` (table `room_messages`): `:read` + `:post` actions; `body`; `belongs_to :room`/`:user`; index on `[:room_id, :inserted_at]`.
- `Room` (table `rooms`): `:read` + `:find_or_create_for_group`; `status :atom` one_of `[:open, :closed]` default `:open`; `belongs_to :group`/`has_many :messages`.
- `Communities.post_message/3` guards `member?`; `recent_messages/2` filters `room_id`. `room_for_group/1` find-or-create.
- `GroupMembership.:create` accepts `[:group_id, :user_id, :role, :status]`; group create auto-adds the owner as an active `:owner` membership.
- `RoomLive` (current): `mount` cond (nil/non-member/member), assigns `group/room/topic/page_title/seo/present/typing/typing_timers/reactions`; `presence_users/1` returns sorted usernames; render presence line `"{length(@present)} here: …"`, `#messages` stream, typing line, reaction bar + float layer, `#room-composer`.

---

## File Structure

**Create:** `lib/verscienta/communities/room_ban.ex`, `test/verscienta/communities/room_moderation_test.exs`; migrations.
**Modify:** `lib/verscienta/communities/message.ex`, `lib/verscienta/communities/room.ex`, `lib/verscienta/communities.ex` (helpers + post_message gate + domain), `lib/verscienta_web/live/room_live.ex`, `test/verscienta_web/live/room_live_test.exs`, `docs/todo.md`.

---

## Task 1: Message soft-delete + Room lock (data layer)

**Files:** modify `message.ex`, `room.ex`, `communities.ex`; create `test/verscienta/communities/room_moderation_test.exs`; migration.

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/communities/room_moderation_test.exs`:
```elixir
defmodule Verscienta.Communities.RoomModerationTest do
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

  defp group(owner, name) do
    {:ok, g} =
      Verscienta.Communities.Group
      |> Ash.Changeset.for_create(:create, %{name: name}, actor: owner)
      |> Ash.create()
    g
  end

  defp join(g, u, role \\ :member) do
    Verscienta.Communities.GroupMembership
    |> Ash.Changeset.for_create(:create, %{group_id: g.id, user_id: u.id, role: role, status: :active}, authorize?: false)
    |> Ash.create!()
  end

  describe "remove_message" do
    test "a moderator soft-deletes; recent_messages excludes it; non-mod rejected" do
      owner = user("modowner")
      member = user("modmember")
      g = group(owner, "Mod Group")
      join(g, member)
      r = Communities.room_for_group(g)
      {:ok, msg} = Communities.post_message(r, member, "spam message")

      assert {:error, :unauthorized} = Communities.remove_message(msg.id, member)
      assert {:ok, _} = Communities.remove_message(msg.id, owner)
      refute Communities.recent_messages(r) |> Enum.any?(&(&1.id == msg.id))
    end
  end

  describe "lock_room" do
    test "a moderator closes the room; posting is rejected; unlock restores" do
      owner = user("lockowner")
      member = user("lockmember")
      g = group(owner, "Lock Group")
      join(g, member)
      r = Communities.room_for_group(g)

      assert {:error, :unauthorized} = Communities.lock_room(r, member, :closed)
      {:ok, r} = Communities.lock_room(r, owner, :closed)
      assert {:error, :room_closed} = Communities.post_message(r, member, "blocked")

      {:ok, r} = Communities.lock_room(r, owner, :open)
      assert {:ok, _} = Communities.post_message(r, member, "allowed")
    end
  end
end
```

- [ ] **Step 2: Run it (fails)**

`docker compose exec -T app mix test test/verscienta/communities/room_moderation_test.exs` → FAIL.

- [ ] **Step 3: Implement**

(a) `lib/verscienta/communities/message.ex` — add the attribute (in `attributes do`) and the action (in `actions do`):
```elixir
    attribute :deleted_at, :utc_datetime_usec, allow_nil?: true, public?: true
```
```elixir
    update :soft_delete do
      accept []
      require_atomic? false
      change set_attribute(:deleted_at, &DateTime.utc_now/0)
    end
```

(b) `lib/verscienta/communities/room.ex` — add the action:
```elixir
    update :set_status do
      accept [:status]
    end
```

(c) `lib/verscienta/communities.ex`:
- In `recent_messages/2`, add `and is_nil(deleted_at)` to the filter:
```elixir
    |> Ash.Query.filter(room_id == ^room.id and is_nil(deleted_at))
```
- Replace `post_message/3` to also reject closed rooms:
```elixir
  def post_message(room, user, body) do
    cond do
      room.status == :closed -> {:error, :room_closed}
      not member?(user, %{id: room.group_id}) -> {:error, :not_a_member}
      true ->
        Message
        |> Ash.Changeset.for_create(:post, %{room_id: room.id, body: body}, actor: user)
        |> Ash.create()
    end
  end
```
- Add the moderation helpers:
```elixir
  @doc "Soft-delete a message (moderators only)."
  def remove_message(message_id, mod) do
    case Ash.get(Message, message_id, load: [room: [:group]], authorize?: false) do
      {:ok, message} ->
        if can_moderate?(mod, message.room.group) do
          message |> Ash.Changeset.for_update(:soft_delete, %{}, authorize?: false) |> Ash.update()
        else
          {:error, :unauthorized}
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @doc "Set a room's status to :open or :closed (moderators only)."
  def lock_room(room, mod, status) when status in [:open, :closed] do
    if can_moderate?(mod, %{id: room.group_id}) do
      room |> Ash.Changeset.for_update(:set_status, %{status: status}, authorize?: false) |> Ash.update()
    else
      {:error, :unauthorized}
    end
  end
```

- [ ] **Step 4: Run the test (passes) + migration**

```bash
docker compose exec -T app mix ash.codegen add_message_deleted_at
docker compose exec -T app mix ash.migrate
docker compose exec -T app mix test test/verscienta/communities/room_moderation_test.exs 2>&1 | tail -5
```
Expected: migration adds `deleted_at` to `room_messages`; tests PASS.

- [ ] **Step 5: format, warnings, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix compile --force --warnings-as-errors 2>&1 | tail -4
docker compose exec -T app mix credo --strict lib/verscienta/communities 2>&1 | tail -4
git add lib/verscienta/communities priv/repo/migrations priv/resource_snapshots test/verscienta/communities/room_moderation_test.exs
git commit -m "feat(live-rooms): message soft-delete + room lock/unlock (moderator-gated)"
```

---

## Task 2: `RoomBan` resource + ban gate

**Files:** create `lib/verscienta/communities/room_ban.ex`; modify `communities.ex`; add to `room_moderation_test.exs`; migration.

- [ ] **Step 1: Add the failing tests**

In `test/verscienta/communities/room_moderation_test.exs`, add:
```elixir
  describe "bans" do
    test "a mod bans a member; banned user can't post; owner/mod/self can't be banned; unban restores" do
      owner = user("banowner")
      mod = user("banmod")
      member = user("banmember")
      g = group(owner, "Ban Group")
      join(g, mod, :mod)
      join(g, member)
      r = Communities.room_for_group(g)

      assert {:error, _} = Communities.ban_user(r, mod, owner)   # can't ban owner
      assert {:error, _} = Communities.ban_user(r, owner, mod)   # can't ban a mod
      assert {:error, _} = Communities.ban_user(r, mod, mod)     # can't ban self
      assert {:error, :unauthorized} = Communities.ban_user(r, member, owner) # non-mod can't ban

      assert {:ok, _} = Communities.ban_user(r, mod, member)
      assert Communities.banned?(r, member)
      assert {:error, :banned} = Communities.post_message(r, member, "after ban")

      assert {:ok, _} = Communities.unban(r, mod, member)
      refute Communities.banned?(r, member)
      assert {:ok, _} = Communities.post_message(r, member, "after unban")
    end
  end
```

- [ ] **Step 2: Run it (fails)**

`docker compose exec -T app mix test test/verscienta/communities/room_moderation_test.exs` → the new test FAILS.

- [ ] **Step 3: Implement**

(a) `lib/verscienta/communities/room_ban.ex`:
```elixir
defmodule Verscienta.Communities.RoomBan do
  @moduledoc "A user banned from a group's live room (still a group member)."
  use Ash.Resource, domain: Verscienta.Communities, data_layer: AshPostgres.DataLayer

  postgres do
    table "room_bans"
    repo Verscienta.Repo
  end

  actions do
    defaults [:read]

    create :ban do
      accept [:room_id, :user_id]
      upsert? true
      upsert_identity :unique_room_user
      change relate_actor(:banned_by)
    end

    destroy :unban
  end

  attributes do
    uuid_primary_key :id
    create_timestamp :inserted_at
  end

  identities do
    identity :unique_room_user, [:room_id, :user_id]
  end

  relationships do
    belongs_to :room, Verscienta.Communities.Room, allow_nil?: false
    belongs_to :user, Verscienta.Accounts.User, allow_nil?: false
    belongs_to :banned_by, Verscienta.Accounts.User
  end
end
```

(b) `lib/verscienta/communities.ex` — register `RoomBan` in `resources do`; add `RoomBan` to the alias; add helpers + the ban gate in `post_message`:
```elixir
  @doc "Ban `target` from `room` (moderators only; not the owner, another mod, or self)."
  def ban_user(room, mod, target) do
    group = %{id: room.group_id}

    cond do
      not can_moderate?(mod, group) -> {:error, :unauthorized}
      target.id == mod.id -> {:error, :cannot_ban_self}
      can_moderate?(target, group) -> {:error, :cannot_ban_moderator}
      true ->
        Verscienta.Communities.RoomBan
        |> Ash.Changeset.for_create(:ban, %{room_id: room.id, user_id: target.id}, actor: mod)
        |> Ash.create()
    end
  end

  @doc "Lift `target`'s ban from `room` (moderators only)."
  def unban(room, mod, target) do
    if can_moderate?(mod, %{id: room.group_id}) do
      case ban_record(room, target) do
        nil -> {:ok, :not_banned}
        ban -> Ash.destroy(ban, action: :unban, authorize?: false)
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc "Whether `user` is banned from `room`."
  def banned?(room, user), do: ban_record(room, user) != nil

  defp ban_record(room, user) do
    Verscienta.Communities.RoomBan
    |> Ash.Query.filter(room_id == ^room.id and user_id == ^user.id)
    |> Ash.read_one!(authorize?: false)
  end
```
And add the ban check to `post_message/3`'s `cond` (before the member check):
```elixir
      banned?(room, user) -> {:error, :banned}
```

- [ ] **Step 4: Run the test (passes) + migration**

```bash
docker compose exec -T app mix ash.codegen add_room_bans
docker compose exec -T app mix ash.migrate
docker compose exec -T app mix test test/verscienta/communities/room_moderation_test.exs 2>&1 | tail -5
```
Expected: migration creates `room_bans` (unique index on `[room_id, user_id]`); tests PASS.

- [ ] **Step 5: format, warnings, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix compile --force --warnings-as-errors 2>&1 | tail -4
docker compose exec -T app mix credo --strict lib/verscienta/communities 2>&1 | tail -4
git add lib/verscienta/communities priv/repo/migrations priv/resource_snapshots test/verscienta/communities/room_moderation_test.exs
git commit -m "feat(live-rooms): RoomBan resource + ban/unban/banned? (moderator-gated)"
```

---

## Task 3: `RoomLive` moderation UI + live

**Files:** modify `lib/verscienta_web/live/room_live.ex`, `test/verscienta_web/live/room_live_test.exs`.

- [ ] **Step 1: Add the failing tests**

In `test/verscienta_web/live/room_live_test.exs`, add (the file's setup enables `:communities`+`:live_rooms`; helpers `user/1`, `sign_in/2`, `group/2`, `join/2`):
```elixir
  test "moderator sees mod controls; a plain member does not", %{conn: conn} do
    owner = user("uimod")
    member = user("uiplain")
    g = group(owner, "UI Mod Group")
    join(g, member)

    {:ok, _lv_o, mod_html} = conn |> sign_in(owner) |> live(~p"/groups/#{g.slug}/room")
    {:ok, _lv_m, member_html} = build_conn() |> sign_in(member) |> live(~p"/groups/#{g.slug}/room")

    assert mod_html =~ "toggle_lock"
    refute member_html =~ "toggle_lock"
  end

  test "a moderator removes a message and it vanishes for others", %{conn: conn} do
    owner = user("rmmod")
    member = user("rmmember")
    g = group(owner, "Remove Group")
    join(g, member)
    r = Verscienta.Communities.room_for_group(g)
    {:ok, msg} = Verscienta.Communities.post_message(r, member, "delete me")

    {:ok, lv_o, _} = conn |> sign_in(owner) |> live(~p"/groups/#{g.slug}/room")
    {:ok, lv_m, _} = build_conn() |> sign_in(member) |> live(~p"/groups/#{g.slug}/room")
    assert render(lv_m) =~ "delete me"

    lv_o |> element(~s([phx-click="remove_message"][phx-value-id="#{msg.id}"])) |> render_click()
    refute render(lv_m) =~ "delete me"
  end

  test "a moderator banning a member force-disconnects them", %{conn: conn} do
    owner = user("banuiowner")
    member = user("banuimember")
    g = group(owner, "Ban UI Group")
    join(g, member)

    {:ok, lv_o, _} = conn |> sign_in(owner) |> live(~p"/groups/#{g.slug}/room")
    {:ok, lv_m, _} = build_conn() |> sign_in(member) |> live(~p"/groups/#{g.slug}/room")

    lv_o |> element(~s([phx-click="ban"][phx-value-user_id="#{member.id}"])) |> render_click()

    assert_redirect(lv_m, ~p"/groups/#{g.slug}")
  end

  test "a banned user cannot enter the room", %{conn: conn} do
    owner = user("banentryowner")
    member = user("banentrymember")
    g = group(owner, "Ban Entry Group")
    join(g, member)
    r = Verscienta.Communities.room_for_group(g)
    {:ok, _} = Verscienta.Communities.ban_user(r, owner, member)

    assert {:error, {:live_redirect, %{to: path}}} =
             build_conn() |> sign_in(member) |> live(~p"/groups/#{g.slug}/room")
    assert path =~ "/groups/" <> g.slug
  end
```

- [ ] **Step 2: Run it (fails)**

`docker compose exec -T app mix test test/verscienta_web/live/room_live_test.exs` → the new tests FAIL.

- [ ] **Step 3: Implement**

In `lib/verscienta_web/live/room_live.ex`:

(a) `mount/3` — in the `true ->` branch, after `room = Communities.room_for_group(group)`, add the banned gate and the `can_moderate` assign:
```elixir
      true ->
        room = Communities.room_for_group(group)

        if Communities.banned?(room, user) do
          {:ok,
           socket
           |> put_flash(:error, "You are banned from this room.")
           |> push_navigate(to: ~p"/groups/#{slug}")}
        else
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
             can_moderate: Communities.can_moderate?(user, group),
             present: presence_users(topic),
             typing: MapSet.new(),
             typing_timers: %{},
             reactions: []
           )
           |> stream(:messages, Communities.recent_messages(room))}
        end
```

(b) Change `presence_users/1` to return id + username maps (the ban button needs ids):
```elixir
  defp presence_users(topic) do
    topic
    |> Presence.list()
    |> Enum.map(fn {id, %{metas: [meta | _]}} -> %{id: id, username: meta.username} end)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.username)
  end
```

(c) Add the moderation events:
```elixir
  def handle_event("remove_message", %{"id" => id}, socket) do
    case Communities.remove_message(id, socket.assigns.current_user) do
      {:ok, _} ->
        Phoenix.PubSub.broadcast(Verscienta.PubSub, socket.assigns.topic, {:message_removed, id})
        {:noreply, socket}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_lock", _params, socket) do
    new_status = if socket.assigns.room.status == :open, do: :closed, else: :open

    case Communities.lock_room(socket.assigns.room, socket.assigns.current_user, new_status) do
      {:ok, _} ->
        Phoenix.PubSub.broadcast(Verscienta.PubSub, socket.assigns.topic, {:room_status, new_status})
        {:noreply, socket}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("ban", %{"user_id" => uid}, socket) do
    with {:ok, target} <- Ash.get(Verscienta.Accounts.User, uid, authorize?: false),
         {:ok, _} <- Communities.ban_user(socket.assigns.room, socket.assigns.current_user, target) do
      Phoenix.PubSub.broadcast(Verscienta.PubSub, socket.assigns.topic, {:banned, to_string(uid)})
    end

    {:noreply, socket}
  end
```

(d) Add the moderation handle_info clauses:
```elixir
  def handle_info({:message_removed, id}, socket) do
    {:noreply, stream_delete(socket, :messages, %Verscienta.Communities.Message{id: id})}
  end

  def handle_info({:room_status, status}, socket) do
    {:noreply, assign(socket, room: %{socket.assigns.room | status: status})}
  end

  def handle_info({:banned, uid}, socket) do
    if uid == to_string(socket.assigns.current_user.id) do
      {:noreply,
       socket
       |> put_flash(:error, "You have been banned from this room.")
       |> push_navigate(to: ~p"/groups/#{socket.assigns.group.slug}")}
    else
      {:noreply, assign(socket, present: presence_users(socket.assigns.topic))}
    end
  end
```

(e) Render changes:
- The presence line now maps `@present` (list of maps): `{length(@present)} here: {@present |> Enum.map(& &1.username) |> Enum.join(", ")}`.
- Per message, a mod remove link (inside the stream `<div>`): `<button :if={@can_moderate} type="button" phx-click="remove_message" phx-value-id={m.id} class="text-xs text-politics">remove</button>`.
- A mod lock/unlock toggle in the header: `<button :if={@can_moderate} type="button" phx-click="toggle_lock" class="...">{if @room.status == :open, do: "lock room", else: "unlock room"}</button>`.
- A mod ban list — under the presence line, for mods: `<button :for={p <- @present} :if={@can_moderate and p.id != to_string(@current_user.id)} type="button" phx-click="ban" phx-value-user_id={p.id} class="...">ban {p.username}</button>`.
- When `@room.status == :closed`: wrap the reaction bar + `#room-composer` form in `:if={@room.status == :open}` (hide for everyone) and show `<p :if={@room.status == :closed} class="...">this room is locked</p>`.

(`@current_user` is available in LiveView assigns from the on_mount.)

- [ ] **Step 4: Run the test (passes) + regression**

```bash
docker compose exec -T app mix test test/verscienta_web/live/room_live_test.exs 2>&1 | tail -8
```
Expected: PASS (slice-1/2 room tests + 4 new). The ban force-disconnect uses `assert_redirect` on the banned member's LV after the mod's ban event fires the `{:banned}` broadcast.

- [ ] **Step 5: format, warnings, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix compile --force --warnings-as-errors 2>&1 | tail -4
docker compose exec -T app mix credo --strict lib/verscienta_web/live/room_live.ex 2>&1 | tail -4
git add lib/verscienta_web/live/room_live.ex test/verscienta_web/live/room_live_test.exs
git commit -m "feat(live-rooms): RoomLive moderation UI (remove/lock/ban) + live propagation"
```

---

## Task 4: Docs + full verification

**Files:** modify `docs/todo.md`.

- [ ] **Step 1: Check off the todo**

In `docs/todo.md` under "### Live Rooms & Real-time", update the room-lifecycle bullet:
`- [~] Room lifecycle (create/join/leave, moderation controls).` → `- [x] Room lifecycle (create/join/leave, moderation controls). *(find-or-create + presence join/leave + moderation: remove message / lock / room ban; slice 3)*`

- [ ] **Step 2: Full suite + format**

```bash
docker compose exec -T app bash -lc 'mix format && mix format --check-formatted && mix test 2>&1 | tail -6'
```
Expected: format clean; 0 failures (known flake `NotificationBellTest` / transient Postgrex — re-run once if it's the only one).

- [ ] **Step 3: Warnings + Credo + Dialyzer**

```bash
docker compose exec -T app mix compile --force --warnings-as-errors 2>&1 | tail -3
docker compose exec -T app mix credo --strict 2>&1 | tail -4
docker compose exec -T app mix dialyzer 2>&1 | tail -8
```
Expected: compile no warnings; credo "found no issues"; dialyzer "passed successfully". If dialyzer reports NEW errors (the RoomBan resource / new helpers are likely sources), paste them; do NOT commit on red.

- [ ] **Step 4: Commit**

```bash
git add docs/todo.md
git commit -m "docs: check off live rooms moderation (slice 3)"
```

- [ ] **Step 5:** Confirm all gates green — branch ready to merge. (This completes the Live Rooms v1 subsystem; A/V remains deferred.)

---

## Notes for the implementer

- All mod actions are gated at the CONTEXT layer (`can_moderate?` in `remove_message`/`lock_room`/`ban_user`/`unban`) AND only shown in the UI for `@can_moderate` — so a non-mod's crafted event still no-ops (the helper returns `{:error, …}`).
- Ban rules: a mod cannot ban the owner, another mod, or themselves (the `cond` in `ban_user`); a banned user stays a group member but can't enter (`mount` redirect) or post (`post_message` `{:error, :banned}`).
- Force-disconnect: the `{:banned, uid}` broadcast redirects ONLY the banned user's session (`uid == to_string(current_user.id)`); their leaving drops them from Presence automatically.
- Message removal is a single render path: `remove_message` → broadcast `{:message_removed, id}` → `stream_delete` for everyone (the mod included). `stream_delete(socket, :messages, %Message{id: id})` deletes by the stream dom id derived from the struct id.
- Lock is read-only for ALL when `:closed`: the composer + reaction bar are hidden (`:if={@room.status == :open}`); mods unlock (the header toggle stays visible) to resume posting. `post_message` also rejects closed rooms server-side.
- `room_for_group/1` is called before the banned check in `mount` (you need the room to check the ban); a banned user still gets the room struct but is redirected before subscribing/tracking.
- `recent_messages/2` now excludes `deleted_at` so removed messages never reload on a fresh mount.
