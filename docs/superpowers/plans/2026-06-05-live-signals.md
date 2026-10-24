# Live Rooms — Ephemeral Signals Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add typing indicators, ephemeral floating room reactions, and a presence count to the live room — all transient PubSub-only signals, no persistence.

**Architecture:** All changes live in `RoomLive`. Signals broadcast on the existing `"room:<id>"` topic; transient state (typing set + timers, reaction list) lives in socket assigns and self-clears via `Process.send_after`. TTLs are module attributes so tests drive the clear handlers directly.

**Tech Stack:** Elixir, Phoenix LiveView, `Phoenix.PubSub` (`Verscienta.PubSub`). All `mix` runs in Docker: `docker compose exec -T app mix …`.

**Spec:** `docs/superpowers/specs/2026-06-05-live-signals-design.md`
**Branch:** `phase-3-live-signals` (spec already committed here).

**The file:** `lib/verscienta_web/live/room_live.ex` (slice 1). Current structure: `mount/3` (assigns `group/room/topic/page_title/seo/present` + streams `:messages`), `handle_event("send", …)` (posts + broadcasts `{:new_message, …}`), `handle_info({:new_message, …})` + `handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, …)`, `presence_users/1`, `render/1` (presence line, message stream, composer form `#room-composer`). Tests in `test/verscienta_web/live/room_live_test.exs` (sets `FunWithFlags.enable(:communities)`/`:live_rooms`; helpers `user/1`, `sign_in/2`, `group/2`, `join/2`).

---

## Task 1: Typing indicators

**Files:** modify `lib/verscienta_web/live/room_live.ex`, `test/verscienta_web/live/room_live_test.exs`.

- [ ] **Step 1: Write the failing tests**

In `test/verscienta_web/live/room_live_test.exs`, add (reuse the existing helpers + setup):
```elixir
  test "a typing member shows up for OTHER members but not themselves", %{conn: conn} do
    o = user("typeowner")
    other = user("typemember")
    g = group(o, "Typing Group")
    join(g, other)

    {:ok, lv_o, _} = conn |> sign_in(o) |> live(~p"/groups/#{g.slug}/room")
    {:ok, lv_other, _} = build_conn() |> sign_in(other) |> live(~p"/groups/#{g.slug}/room")

    lv_o |> element(~s(#room-composer input[name="body"])) |> render_keyup(%{"value" => "h"})

    assert render(lv_other) =~ "typing…"
    assert render(lv_other) =~ "typeowner"
    refute render(lv_o) =~ "typing…"
  end

  test "typing clears when the typist sends, and via the clear handler", %{conn: conn} do
    o = user("typeowner2")
    other = user("typemember2")
    g = group(o, "Typing Group 2")
    join(g, other)

    {:ok, lv_o, _} = conn |> sign_in(o) |> live(~p"/groups/#{g.slug}/room")
    {:ok, lv_other, _} = build_conn() |> sign_in(other) |> live(~p"/groups/#{g.slug}/room")

    lv_o |> element(~s(#room-composer input[name="body"])) |> render_keyup(%{"value" => "h"})
    assert render(lv_other) =~ "typing…"

    # sending clears the typist's indicator on others (neutral body — no "typing…")
    lv_o |> form("#room-composer", %{"body" => "ok"}) |> render_submit()
    refute render(lv_other) =~ "typing…"

    # the clear handler also removes a name (ghost only appears in the typing line)
    send(lv_other.pid, {:typing, %{id: o.id, username: "ghost"}})
    assert render(lv_other) =~ "ghost"
    send(lv_other.pid, {:clear_typing, "ghost"})
    refute render(lv_other) =~ "ghost"
  end
```
(If `render_keyup/2` needs a different param shape, adjust — the `"typing"` handler ignores params, so any value works; the key requirement is that firing `phx-keyup` on the composer input triggers it.)

- [ ] **Step 2: Run it (fails — no typing)**

`docker compose exec -T app mix test test/verscienta_web/live/room_live_test.exs` → the new tests FAIL.

- [ ] **Step 3: Implement**

In `lib/verscienta_web/live/room_live.ex`:

(a) Add the module attribute (near the top, after the aliases):
```elixir
  @typing_ttl_ms 3_000
```

(b) In `mount/3`'s member-branch assigns, add `typing` + `typing_timers`:
```elixir
         |> assign(
           group: group,
           room: room,
           topic: topic,
           page_title: group.name,
           seo: VerscientaWeb.SEO.build(noindex: true),
           present: presence_users(topic),
           typing: MapSet.new(),
           typing_timers: %{}
         )
```

(c) Add the `"typing"` event + extend `"send"` to clear typing. Add this `handle_event` clause:
```elixir
  def handle_event("typing", _params, socket) do
    user = socket.assigns.current_user

    Phoenix.PubSub.broadcast(
      Verscienta.PubSub,
      socket.assigns.topic,
      {:typing, %{id: user.id, username: to_string(user.username)}}
    )

    {:noreply, socket}
  end
```
And in the existing `"send"` handler, after a successful post + the `{:new_message, …}` broadcast, also broadcast a stop-typing (so others clear the typist immediately):
```elixir
          Phoenix.PubSub.broadcast(
            Verscienta.PubSub,
            socket.assigns.topic,
            {:stop_typing, to_string(socket.assigns.current_user.username)}
          )
```

(d) Add the typing `handle_info` clauses (alongside the existing ones):
```elixir
  def handle_info({:typing, %{id: id, username: name}}, socket) do
    if id == socket.assigns.current_user.id do
      {:noreply, socket}
    else
      {:noreply, add_typing(socket, name)}
    end
  end

  def handle_info({:clear_typing, name}, socket), do: {:noreply, drop_typing(socket, name)}
  def handle_info({:stop_typing, name}, socket), do: {:noreply, drop_typing(socket, name)}
```

(e) Add the helpers:
```elixir
  defp add_typing(socket, name) do
    timers = socket.assigns.typing_timers
    if ref = timers[name], do: Process.cancel_timer(ref)
    ref = Process.send_after(self(), {:clear_typing, name}, @typing_ttl_ms)

    socket
    |> assign(typing: MapSet.put(socket.assigns.typing, name))
    |> assign(typing_timers: Map.put(timers, name, ref))
  end

  defp drop_typing(socket, name) do
    if ref = socket.assigns.typing_timers[name], do: Process.cancel_timer(ref)

    socket
    |> assign(typing: MapSet.delete(socket.assigns.typing, name))
    |> assign(typing_timers: Map.delete(socket.assigns.typing_timers, name))
  end
```

(f) Render: add the `phx-keyup`/`phx-debounce` to the composer input and a typing line below the message stream (before the composer form):
- on the input: add `phx-keyup="typing" phx-debounce="400"`.
- the typing line:
```heex
      <p :if={MapSet.size(@typing) > 0} class="mb-2 text-xs italic text-ink-3">
        {@typing |> Enum.sort() |> Enum.join(", ")} typing…
      </p>
```

- [ ] **Step 4: Run the test (passes) + regression**

```bash
docker compose exec -T app mix test test/verscienta_web/live/room_live_test.exs 2>&1 | tail -6
```
Expected: PASS (the slice-1 room tests + the 2 new typing tests).

- [ ] **Step 5: format, warnings, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix compile --force --warnings-as-errors 2>&1 | tail -4
docker compose exec -T app mix credo --strict lib/verscienta_web/live/room_live.ex 2>&1 | tail -4
git add lib/verscienta_web/live/room_live.ex test/verscienta_web/live/room_live_test.exs
git commit -m "feat(live-rooms): typing indicators (debounced broadcast + per-user auto-clear)"
```

---

## Task 2: Ephemeral room reactions

**Files:** modify `lib/verscienta_web/live/room_live.ex`, `test/verscienta_web/live/room_live_test.exs`.

- [ ] **Step 1: Write the failing tests**

Add to `room_live_test.exs`:
```elixir
  test "a room reaction appears for other members and clears", %{conn: conn} do
    o = user("reactowner")
    other = user("reactmember")
    g = group(o, "React Group")
    join(g, other)

    {:ok, lv_o, _} = conn |> sign_in(o) |> live(~p"/groups/#{g.slug}/room")
    {:ok, lv_other, _} = build_conn() |> sign_in(other) |> live(~p"/groups/#{g.slug}/room")

    lv_o |> element(~s(button[phx-value-emoji="🔥"])) |> render_click()
    assert render(lv_other) =~ "🔥"

    # the clear handler removes a reaction by id
    send(lv_other.pid, {:reaction, %{id: 999, emoji: "❤️"}})
    assert render(lv_other) =~ "❤️"
    send(lv_other.pid, {:clear_reaction, 999})
    refute render(lv_other) =~ "❤️"
  end

  test "an out-of-set emoji is ignored (not broadcast)", %{conn: conn} do
    o = user("reactowner2")
    other = user("reactmember2")
    g = group(o, "React Group 2")
    join(g, other)

    {:ok, lv_o, _} = conn |> sign_in(o) |> live(~p"/groups/#{g.slug}/room")
    {:ok, lv_other, _} = build_conn() |> sign_in(other) |> live(~p"/groups/#{g.slug}/room")

    render_click(lv_o, "react", %{"emoji" => "💀"})
    refute render(lv_other) =~ "💀"
  end
```

- [ ] **Step 2: Run it (fails — no reactions)**

`docker compose exec -T app mix test test/verscienta_web/live/room_live_test.exs` → the new tests FAIL.

- [ ] **Step 3: Implement**

In `lib/verscienta_web/live/room_live.ex`:

(a) Add module attributes:
```elixir
  @reaction_ttl_ms 2_500
  @reaction_emojis ~w(👏 ❤️ 😂 🔥)
```

(b) In `mount/3`'s member-branch assigns, add `reactions: []` and `reaction_emojis: @reaction_emojis`.

(c) Add the `"react"` event:
```elixir
  def handle_event("react", %{"emoji" => emoji}, socket) do
    if emoji in @reaction_emojis do
      Phoenix.PubSub.broadcast(
        Verscienta.PubSub,
        socket.assigns.topic,
        {:reaction, %{id: System.unique_integer([:positive]), emoji: emoji}}
      )
    end

    {:noreply, socket}
  end
```

(d) Add the reaction `handle_info` clauses:
```elixir
  def handle_info({:reaction, %{id: id, emoji: emoji}}, socket) do
    Process.send_after(self(), {:clear_reaction, id}, @reaction_ttl_ms)
    {:noreply, assign(socket, reactions: socket.assigns.reactions ++ [%{id: id, emoji: emoji}])}
  end

  def handle_info({:clear_reaction, id}, socket) do
    {:noreply, assign(socket, reactions: Enum.reject(socket.assigns.reactions, &(&1.id == id)))}
  end
```

(e) Render: add the emoji bar (above the composer form) and the floating reactions layer (anywhere inside the root div):
```heex
      <div class="mb-3 flex gap-2">
        <button
          :for={e <- @reaction_emojis}
          type="button"
          phx-click="react"
          phx-value-emoji={e}
          class="border border-line px-3 py-1.5 text-lg hover:border-zune"
        >
          {e}
        </button>
      </div>

      <div class="pointer-events-none fixed inset-x-0 bottom-28 flex justify-center gap-3">
        <span :for={r <- @reactions} id={"reaction-#{r.id}"} class="animate-[rise_2.5s_ease-out] text-4xl">
          {r.emoji}
        </span>
      </div>
```
(Use an existing rise/fade motion utility if one exists — grep `assets/css/app.css` for `rise`/`slidein`/`fade` keyframes/animations and use that class; if none, a simple `animate-pulse` or an inline keyframe like above is acceptable for v1. The exact animation is cosmetic; the `id={"reaction-#{r.id}"}` keying is what matters so duplicate emojis animate independently.)

- [ ] **Step 4: Run the test (passes)**

`docker compose exec -T app mix test test/verscienta_web/live/room_live_test.exs 2>&1 | tail -6` → PASS.

- [ ] **Step 5: format, warnings, credo, commit**

```bash
docker compose exec -T app mix format
docker compose exec -T app mix compile --force --warnings-as-errors 2>&1 | tail -4
docker compose exec -T app mix credo --strict lib/verscienta_web/live/room_live.ex 2>&1 | tail -4
git add lib/verscienta_web/live/room_live.ex test/verscienta_web/live/room_live_test.exs
git commit -m "feat(live-rooms): ephemeral floating room reactions"
```

---

## Task 3: Presence count + docs + verification

**Files:** modify `lib/verscienta_web/live/room_live.ex`, `test/verscienta_web/live/room_live_test.exs`, `docs/todo.md`.

- [ ] **Step 1: Add the failing test**

Add to `room_live_test.exs`:
```elixir
  test "the presence line shows a count", %{conn: conn} do
    o = user("presownr")
    g = group(o, "Presence Count Group")
    {:ok, _lv, html} = conn |> sign_in(o) |> live(~p"/groups/#{g.slug}/room")
    assert html =~ "1 here" or html =~ "here (1)"
  end
```

- [ ] **Step 2: Run it (fails — no count)**

`docker compose exec -T app mix test test/verscienta_web/live/room_live_test.exs` → the new test FAILS.

- [ ] **Step 3: Implement**

In `render/1`, change the presence line from:
```heex
      <p class="mb-6 text-[11px] uppercase tracking-widest text-ink-3">
        here now: {Enum.join(@present, ", ")}
      </p>
```
to include the count:
```heex
      <p class="mb-6 text-[11px] uppercase tracking-widest text-ink-3">
        {length(@present)} here: {Enum.join(@present, ", ")}
      </p>
```

- [ ] **Step 4: Run the test (passes)**

`docker compose exec -T app mix test test/verscienta_web/live/room_live_test.exs 2>&1 | tail -5` → PASS.

- [ ] **Step 5: Check off the todo**

In `docs/todo.md` under "### Live Rooms & Real-time", change the live-reactions/typing/presence bullet to checked:
`- [x] Live reactions / typing indicators / online presence. *(typing + ephemeral room reactions + presence count; slice 2)*`

- [ ] **Step 6: Full verification**

```bash
docker compose exec -T app bash -lc 'mix format && mix format --check-formatted && mix test 2>&1 | tail -6'
docker compose exec -T app mix compile --force --warnings-as-errors 2>&1 | tail -3
docker compose exec -T app mix credo --strict 2>&1 | tail -4
docker compose exec -T app mix dialyzer 2>&1 | tail -8
```
Expected: format clean; 0 failures (known flake `NotificationBellTest` / transient Postgrex — re-run once if it's the only one); compile no warnings; credo "found no issues"; dialyzer "passed successfully". If dialyzer reports NEW errors, paste them; do NOT commit on red.

- [ ] **Step 7: Commit**

```bash
git add lib/verscienta_web/live/room_live.ex test/verscienta_web/live/room_live_test.exs docs/todo.md
git commit -m "feat(live-rooms): presence count; check off live signals (slice 2)"
```

- [ ] **Step 8:** Confirm all gates green — branch ready to merge.

---

## Notes for the implementer

- All three signals are EPHEMERAL — no resources, no migration, no persistence. State lives in socket assigns and self-clears via `Process.send_after`.
- Typing: the typist never sees their own indicator (`handle_info({:typing, …})` ignores `id == current_user.id`); re-typing cancels the prior clear timer so the indicator stays while they keep typing; sending broadcasts `{:stop_typing, …}` so others clear immediately.
- Reactions: `"react"` validates the emoji against `@reaction_emojis` before broadcasting (a tampered `phx-value-emoji` can't inject arbitrary content); each reaction has a unique id so the clear handler and DOM keying are precise.
- The `@typing_ttl_ms` / `@reaction_ttl_ms` are module attributes; tests drive the `{:clear_typing, …}` / `{:clear_reaction, …}` handlers via direct `send/2` to the LV pid rather than sleeping on the TTL.
- The new `handle_info` clauses must coexist with the existing `{:new_message, …}` and `presence_diff` clauses (same callback group; `@impl true` on the first clause covers them).
- The reaction animation class is cosmetic — reuse an existing motion utility from `assets/css/app.css` if one fits; the functional requirement is that the emoji renders transiently and the id keys it.
