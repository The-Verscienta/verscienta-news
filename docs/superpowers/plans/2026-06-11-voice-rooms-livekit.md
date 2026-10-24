# Audio-Only Voice Rooms (LiveKit) Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add audio-only voice chat to live rooms via a LiveKit SFU — join/leave/mute, presence of who's in the call — behind an off-by-default `:voice_rooms` flag.

**Architecture:** A new flag + LiveKit config gate the UI. `Verscienta.LiveKit.Token` mints a hand-rolled HS256 JWT (`:crypto`, no dep); `Verscienta.LiveKit` wraps config + the token. `RoomLive` gains join/leave/mute events, a `voice` presence meta, and renders a `VoiceRoom` JS hook that drives the vendored `livekit-client` SDK. The media path is browser-only (untested here); everything server-side is unit-tested.

**Tech Stack:** Elixir, Ash 3, Phoenix LiveView + Presence, FunWithFlags, `:crypto`/`Jason` (JWT), esbuild (vendored SDK, no npm), LiveKit.

**Spec:** `docs/superpowers/specs/2026-06-11-voice-rooms-livekit-design.md`

**Conventions:**
- All `mix` runs inside Docker: `docker compose exec app mix ...`.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Branch: `phase-3-voice-rooms`. `git checkout phase-3-voice-rooms` first; verify with `git rev-parse --abbrev-ref HEAD` (an external tool has switched branches on this checkout before — re-verify before each commit, stage only your own files).

---

### Task 1: `:voice_rooms` flag + config + `LiveKit.Token` + `LiveKit`

**Files:**
- Modify: `lib/verscienta/flags.ex`, `lib/verscienta/flags/seeds.ex`, `config/runtime.exs`
- Create: `lib/verscienta/live_kit/token.ex`, `lib/verscienta/live_kit.ex`
- Test (create): `test/verscienta/live_kit/token_test.exs`, `test/verscienta/live_kit_test.exs`

- [ ] **Step 1: Write the failing tests**

`test/verscienta/live_kit/token_test.exs`:
```elixir
defmodule Verscienta.LiveKit.TokenTest do
  use ExUnit.Case, async: true

  alias Verscienta.LiveKit.Token

  defp parts(jwt), do: String.split(jwt, ".")
  defp decode(seg), do: seg |> Base.url_decode64!(padding: false) |> Jason.decode!()

  test "signs a LiveKit JWT with the expected claims + grant" do
    jwt = Token.sign("APIkey", "secret", "user-1", "alice", "room_42", 3600, 1_700_000_000)
    [h, p, _sig] = parts(jwt)

    assert decode(h) == %{"alg" => "HS256", "typ" => "JWT"}

    claims = decode(p)
    assert claims["iss"] == "APIkey"
    assert claims["sub"] == "user-1"
    assert claims["name"] == "alice"
    assert claims["nbf"] == 1_700_000_000
    assert claims["exp"] == 1_700_003_600
    assert claims["video"]["roomJoin"] == true
    assert claims["video"]["room"] == "room_42"
    assert claims["video"]["canPublish"] == true
    assert claims["video"]["canSubscribe"] == true
  end

  test "the signature verifies with the secret and fails with a wrong secret" do
    jwt = Token.sign("APIkey", "secret", "user-1", "alice", "room_42", 3600, 1_700_000_000)
    [h, p, sig] = parts(jwt)

    expected = :crypto.mac(:hmac, :sha256, "secret", h <> "." <> p) |> Base.url_encode64(padding: false)
    assert sig == expected

    wrong = :crypto.mac(:hmac, :sha256, "WRONG", h <> "." <> p) |> Base.url_encode64(padding: false)
    refute sig == wrong
  end
end
```

`test/verscienta/live_kit_test.exs`:
```elixir
defmodule Verscienta.LiveKitTest do
  use ExUnit.Case, async: false

  alias Verscienta.LiveKit

  setup do
    prev = %{
      url: Application.get_env(:verscienta, :livekit_url),
      key: Application.get_env(:verscienta, :livekit_api_key),
      secret: Application.get_env(:verscienta, :livekit_api_secret)
    }

    on_exit(fn ->
      Application.put_env(:verscienta, :livekit_url, prev.url)
      Application.put_env(:verscienta, :livekit_api_key, prev.key)
      Application.put_env(:verscienta, :livekit_api_secret, prev.secret)
    end)

    :ok
  end

  test "configured? is true when url + key + secret are all set" do
    Application.put_env(:verscienta, :livekit_url, "ws://localhost:7880")
    Application.put_env(:verscienta, :livekit_api_key, "devkey")
    Application.put_env(:verscienta, :livekit_api_secret, "devsecret")
    assert LiveKit.configured?()
  end

  test "configured? is false when the secret is missing" do
    Application.put_env(:verscienta, :livekit_url, "ws://localhost:7880")
    Application.put_env(:verscienta, :livekit_api_key, "devkey")
    Application.put_env(:verscienta, :livekit_api_secret, nil)
    refute LiveKit.configured?()
  end

  test "access_token returns a 3-segment token carrying the room + identity" do
    Application.put_env(:verscienta, :livekit_api_key, "devkey")
    Application.put_env(:verscienta, :livekit_api_secret, "devsecret")

    jwt = LiveKit.access_token("user-9", "bob", "room_7")
    [_h, p, _sig] = String.split(jwt, ".")
    claims = p |> Base.url_decode64!(padding: false) |> Jason.decode!()

    assert claims["sub"] == "user-9"
    assert claims["video"]["room"] == "room_7"
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `docker compose exec app mix test test/verscienta/live_kit/token_test.exs test/verscienta/live_kit_test.exs`
Expected: FAIL — modules undefined.

- [ ] **Step 3: Create `lib/verscienta/live_kit/token.ex`**

```elixir
defmodule Verscienta.LiveKit.Token do
  @moduledoc "Mints LiveKit access tokens (HS256 JWT) with :crypto — no external JWT dep."

  @doc """
  A LiveKit JWT: header `{alg: HS256, typ: JWT}`, claims `iss/sub/name/nbf/exp` + the
  `video` grant, signed HMAC-SHA256 over the API secret. `now` (unix seconds) is
  injectable for tests.
  """
  def sign(api_key, secret, identity, name, room, ttl_seconds, now \\ System.system_time(:second)) do
    header = %{"alg" => "HS256", "typ" => "JWT"}

    claims = %{
      "iss" => api_key,
      "sub" => identity,
      "name" => name,
      "nbf" => now,
      "exp" => now + ttl_seconds,
      "video" => %{
        "roomJoin" => true,
        "room" => room,
        "canPublish" => true,
        "canSubscribe" => true,
        "canPublishData" => true
      }
    }

    signing_input = b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(claims))
    signing_input <> "." <> b64(:crypto.mac(:hmac, :sha256, secret, signing_input))
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
end
```

- [ ] **Step 4: Create `lib/verscienta/live_kit.ex`**

```elixir
defmodule Verscienta.LiveKit do
  @moduledoc "LiveKit config + access-token entry point for voice rooms."

  alias Verscienta.LiveKit.Token

  @ttl_seconds 6 * 3600

  @doc "True when the LiveKit URL + API key + secret are all configured."
  def configured?, do: present?(url()) and present?(api_key()) and present?(api_secret())

  @doc "The LiveKit server URL (wss/ws)."
  def url, do: cfg(:livekit_url)

  @doc "A signed access token granting `identity` (display `name`) join/publish/subscribe in `room`."
  def access_token(identity, name, room),
    do: Token.sign(api_key(), api_secret(), to_string(identity), to_string(name), room, @ttl_seconds)

  defp api_key, do: cfg(:livekit_api_key)
  defp api_secret, do: cfg(:livekit_api_secret)
  defp cfg(k), do: Application.get_env(:verscienta, k)
  defp present?(v), do: is_binary(v) and v != ""
end
```

- [ ] **Step 5: Add the flag**

`lib/verscienta/flags.ex`: add `voice_rooms` to the `@known_flags ~w(...)a` (e.g. on the `for_you_feed live_rooms` line → `for_you_feed live_rooms voice_rooms`).
`lib/verscienta/flags/seeds.ex`: add `voice_rooms` to `@phase3_off ~w(...)a` and a label: `voice_rooms: "Voice rooms (LiveKit audio)",`.

- [ ] **Step 6: Add the runtime config**

In `config/runtime.exs`: in the prod section (with the other `config :verscienta, ...` external creds) add (NOTE: voice is optional — do NOT `raise` when absent; leave unset so `configured?/0` is false):
```elixir
config :verscienta,
  livekit_url: System.get_env("LIVEKIT_URL"),
  livekit_api_key: System.get_env("LIVEKIT_API_KEY"),
  livekit_api_secret: System.get_env("LIVEKIT_API_SECRET")
```
And in the `if config_env() in [:dev, :test]` block (next to the Meilisearch defaults) add:
```elixir
config :verscienta,
  livekit_url: System.get_env("LIVEKIT_URL", "ws://localhost:7880"),
  livekit_api_key: System.get_env("LIVEKIT_API_KEY", "devkey"),
  livekit_api_secret: System.get_env("LIVEKIT_API_SECRET", "devsecret")
```
(If the prod and dev/test blocks are structured so a single `config :verscienta` accumulates, keep them as separate statements — Config merges keys. Match the file's existing structure.)

- [ ] **Step 7: Run the tests + flags suite**

Run: `docker compose exec app mix test test/verscienta/live_kit/token_test.exs test/verscienta/live_kit_test.exs test/verscienta/flags_test.exs`
Expected: PASS (flags_test may assert a flag count — bump it to include `voice_rooms`, keep the assertion).

Run: `docker compose exec app mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add lib/verscienta/flags.ex lib/verscienta/flags/seeds.ex config/runtime.exs lib/verscienta/live_kit.ex lib/verscienta/live_kit/token.ex test/verscienta/live_kit/token_test.exs test/verscienta/live_kit_test.exs
git commit -m "feat(voice): :voice_rooms flag + LiveKit config + HS256 access tokens

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `RoomLive` voice integration (server-side)

**Files:**
- Modify: `lib/verscienta_web/live/room_live.ex`
- Test (create): `test/verscienta_web/live/room_voice_test.exs`

- [ ] **Step 1: Write the failing test**

`test/verscienta_web/live/room_voice_test.exs` (mirrors `room_live_test.exs` setup):
```elixir
defmodule VerscientaWeb.RoomVoiceTest do
  use VerscientaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Verscienta.Support.Factory, only: [user: 1, sign_in: 2]

  setup do
    FunWithFlags.enable(:communities)
    FunWithFlags.enable(:live_rooms)
    FunWithFlags.enable(:voice_rooms)

    on_exit(fn ->
      FunWithFlags.disable(:communities)
      FunWithFlags.disable(:live_rooms)
      FunWithFlags.disable(:voice_rooms)
    end)

    :ok
  end

  defp group(owner, name) do
    {:ok, g} =
      Verscienta.Communities.Group
      |> Ash.Changeset.for_create(:create, %{name: name}, actor: owner)
      |> Ash.create()

    g
  end

  test "a member can join voice, which renders the hook with a token", %{conn: conn} do
    o = user("voiceowner")
    g = group(o, "Voice Herbalists")

    {:ok, lv, _} = conn |> sign_in(o) |> live(~p"/groups/#{g.slug}/room")
    assert render(lv) =~ "join voice"

    lv |> element("button", "join voice") |> render_click()
    html = render(lv)

    assert html =~ ~s(id="voice-room")
    assert html =~ ~s(phx-hook="VoiceRoom")
    assert html =~ ~s(data-token=)
    # the join button is gone once in voice
    refute html =~ "join voice"
  end

  test "toggle mute flips data-muted; leave voice removes the hook", %{conn: conn} do
    o = user("voiceowner2")
    g = group(o, "Voice Group 2")

    {:ok, lv, _} = conn |> sign_in(o) |> live(~p"/groups/#{g.slug}/room")
    lv |> element("button", "join voice") |> render_click()
    assert render(lv) =~ ~s(data-muted="false")

    lv |> element("button", "mute") |> render_click()
    assert render(lv) =~ ~s(data-muted="true")

    lv |> element("button", "leave voice") |> render_click()
    refute render(lv) =~ ~s(id="voice-room")
  end

  test "with :voice_rooms disabled, no voice control renders", %{conn: conn} do
    FunWithFlags.disable(:voice_rooms)
    o = user("voiceowner3")
    g = group(o, "No Voice Group")

    {:ok, lv, _} = conn |> sign_in(o) |> live(~p"/groups/#{g.slug}/room")
    refute render(lv) =~ "join voice"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `docker compose exec app mix test test/verscienta_web/live/room_voice_test.exs`
Expected: FAIL — no voice control / events.

- [ ] **Step 3: Add voice assigns + presence meta in `mount_room/4`**

In `lib/verscienta_web/live/room_live.ex`, in `mount_room/4`:
- Change the `Presence.track` meta to include voice:
```elixir
      Presence.track(self(), topic, to_string(user.id), %{
        username: to_string(user.username),
        voice: false
      })
```
- Add to the `assign(...)` list (alongside `present:` etc.):
```elixir
       voice_enabled: Verscienta.Flags.enabled?(:voice_rooms) and Verscienta.LiveKit.configured?(),
       in_voice: false,
       voice_token: nil,
       muted: false,
```

- [ ] **Step 4: Update `presence_users/1` to carry voice**

```elixir
  defp presence_users(topic) do
    topic
    |> Presence.list()
    |> Enum.map(fn {id, %{metas: [meta | _]}} ->
      %{id: id, username: meta.username, voice: Map.get(meta, :voice, false)}
    end)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.username)
  end
```

- [ ] **Step 5: Add the voice event handlers**

Add these `handle_event` clauses (e.g. after `"toggle_lock"`/before `"ban"`):
```elixir
  def handle_event("join_voice", _params, socket) do
    user = socket.assigns.current_user
    room = socket.assigns.room

    if Communities.member?(user, socket.assigns.group) and not Communities.banned?(room, user) do
      token = Verscienta.LiveKit.access_token(user.id, user.username, "room_#{room.id}")

      Presence.update(self(), socket.assigns.topic, to_string(user.id), fn meta ->
        Map.put(meta, :voice, true)
      end)

      {:noreply, assign(socket, in_voice: true, voice_token: token)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("leave_voice", _params, socket) do
    {:noreply, leave_voice(socket)}
  end

  def handle_event("toggle_mute", _params, socket) do
    {:noreply, assign(socket, muted: !socket.assigns.muted)}
  end

  def handle_event("voice_error", _params, socket) do
    {:noreply, socket |> put_flash(:error, "Couldn't connect to voice.") |> leave_voice()}
  end
```
And a private helper (near `add_typing`/`drop_typing`):
```elixir
  defp leave_voice(socket) do
    Presence.update(self(), socket.assigns.topic, to_string(socket.assigns.current_user.id), fn meta ->
      Map.put(meta, :voice, false)
    end)

    assign(socket, in_voice: false, voice_token: nil, muted: false)
  end
```

- [ ] **Step 6: Render the voice control**

In `render/1`, after the presence line (the `<p>...{length(@present)} here...` block), add:
```heex
      <div :if={@voice_enabled} class="mb-4">
        <button
          :if={!@in_voice}
          type="button"
          phx-click="join_voice"
          class="bg-zune px-4 py-2 text-xs font-semibold uppercase text-canvas"
        >
          join voice
        </button>

        <div
          :if={@in_voice}
          id="voice-room"
          phx-hook="VoiceRoom"
          data-url={Verscienta.LiveKit.url()}
          data-token={@voice_token}
          data-muted={to_string(@muted)}
          class="flex items-center gap-3"
        >
          <button type="button" phx-click="toggle_mute" class="border border-line px-3 py-1.5 text-xs uppercase">
            {if @muted, do: "unmute", else: "mute"}
          </button>
          <button
            type="button"
            phx-click="leave_voice"
            class="text-xs uppercase tracking-wider text-politics hover:underline"
          >
            leave voice
          </button>
        </div>
      </div>
```
(Optional polish: in the presence line, append a 🔊 next to a present user whose
`voice` is true — e.g. map `@present` to `"#{p.username}#{if p.voice, do: " 🔊", else: ""}"`.
Keep it simple; not asserted by tests.)

- [ ] **Step 7: Run the test + compile**

Run: `docker compose exec app mix test test/verscienta_web/live/room_voice_test.exs test/verscienta_web/live/room_live_test.exs`
Expected: PASS (new voice tests + the existing room tests still green).

Run: `docker compose exec app mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add lib/verscienta_web/live/room_live.ex test/verscienta_web/live/room_voice_test.exs
git commit -m "feat(voice): RoomLive join/leave/mute + voice presence

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Vendored SDK + `VoiceRoom` JS hook

**Files:**
- Create: `assets/vendor/livekit-client.js` (vendored bundle), `assets/js/voice_room.js`
- Modify: `assets/js/app.js`

> No automated test (browser-only). Verification is `mix assets.build` succeeding + the bundle committed + the hook registered.

- [ ] **Step 1: Vendor the prebuilt LiveKit client (ESM)**

Download a pinned 2.x ESM bundle into `assets/vendor/livekit-client.js`. From the host (curl is fine):
```bash
curl -L "https://cdn.jsdelivr.net/npm/livekit-client@2/dist/livekit-client.esm.mjs" -o assets/vendor/livekit-client.js
```
Then prepend a one-line comment recording the exact resolved version (check the file
header or the jsdelivr redirect; e.g. `// livekit-client@2.x.y — vendored prebuilt ESM`).
Confirm the file is a single self-contained ESM module exporting `Room`, `RoomEvent`.

- [ ] **Step 2: Create `assets/js/voice_room.js`**

```js
// LiveView hook: connects the room to LiveKit for audio-only voice.
// The media path is browser-only and not unit-tested.
import { Room, RoomEvent } from "../vendor/livekit-client"

export default {
  async mounted() {
    this.room = new Room()

    this.room.on(RoomEvent.TrackSubscribed, (track) => {
      if (track.kind === "audio") {
        const el = track.attach()
        el.dataset.lk = "1"
        this.el.appendChild(el)
      }
    })

    try {
      await this.room.connect(this.el.dataset.url, this.el.dataset.token)
      await this.room.localParticipant.setMicrophoneEnabled(this.el.dataset.muted !== "true")
    } catch (_e) {
      this.pushEvent("voice_error", {})
    }
  },

  updated() {
    if (this.room && this.room.localParticipant) {
      this.room.localParticipant.setMicrophoneEnabled(this.el.dataset.muted !== "true")
    }
  },

  destroyed() {
    if (this.room) this.room.disconnect()
  },
}
```

- [ ] **Step 3: Register the hook in `assets/js/app.js`**

Add the import near the other local-hook imports (after `import RichText from "./rich_text"`):
```js
import VoiceRoom from "./voice_room"
```
And register it (after `Hooks.RichText = RichText`):
```js
Hooks.VoiceRoom = VoiceRoom
```
(The `hooks: {...colocatedHooks, ...Hooks}` registration already picks it up.)

- [ ] **Step 4: Build the assets**

Run: `docker compose exec app mix assets.build`
Expected: esbuild bundles successfully (the vendored `livekit-client.js` resolves; `js/app.js` builds).

> **Watch out:** if esbuild fails resolving a sub-module the ESM bundle imports
> (e.g. an `*.e2ee.worker.mjs`), STOP and report it rather than hacking — we may need
> to vendor the UMD build instead or mark the worker path `--external`. Do not silently
> work around a broken bundle.

- [ ] **Step 5: Commit**

```bash
git add assets/vendor/livekit-client.js assets/js/voice_room.js assets/js/app.js
git commit -m "feat(voice): vendor livekit-client + VoiceRoom hook

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Full verification + docs

**Files:**
- Modify: `docs/todo.md`

- [ ] **Step 1: Format + compile**

Run: `docker compose exec app mix format && docker compose exec app mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 2: Credo strict**

Run: `docker compose exec app mix credo --strict`
Expected: no issues.

- [ ] **Step 3: Run the voice + room + flags suites**

Run: `docker compose exec app mix test test/verscienta/live_kit/ test/verscienta/live_kit_test.exs test/verscienta/flags_test.exs test/verscienta_web/live/room_voice_test.exs test/verscienta_web/live/room_live_test.exs`
Expected: PASS.

- [ ] **Step 4: Full suite**

Run: `docker compose exec app mix test`
Expected: PASS, 0 failures. (Transient seed-contamination → re-run; see project memory.)

- [ ] **Step 5: Update the todo item**

In `docs/todo.md`, find the live-rooms / `Audio/video (LiveKit/WebRTC) (Optional)` line
and mark the audio part done, e.g.:
```
~~Audio/video (LiveKit/WebRTC) (Optional)~~ *(done — audio-only voice rooms behind the `:voice_rooms` flag: hand-rolled HS256 LiveKit access tokens (`Verscienta.LiveKit`), RoomLive join/leave/mute + voice presence, vendored `livekit-client` SDK + `VoiceRoom` hook. Video deferred. Media path needs a deployed LiveKit server to validate.)*
```
(Match the actual todo wording; if the line bundles audio AND video, strike only the
audio scope and note video is deferred. If `docs/todo.md` shows an unrelated modified
state, stage only your todo hunk.)

- [ ] **Step 6: Commit**

```bash
git add docs/todo.md
git commit -m "docs(voice): mark audio-only voice rooms done

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review Notes

**Spec coverage:**
- `:voice_rooms` flag + config + `LiveKit`/`LiveKit.Token` → Task 1.
- RoomLive join/leave/mute/voice-error + voice presence + render → Task 2.
- Vendored SDK + `VoiceRoom` hook + registration → Task 3.
- Verification + todo → Task 4.

**Out of scope (per spec):** video/camera/screen-share/recording/e2ee; speaking-indicator via presence; LiveKit REST/server-side kick; per-room mod voice toggle; automated browser testing of the media path. No migration/resource/attribute. One new flag.

**Testability boundary:** the media path (vendored SDK, JS hook, WebRTC audio) is browser-only and needs a deployed LiveKit server — explicitly NOT unit-tested. Task 3's verification is the esbuild bundle succeeding.
