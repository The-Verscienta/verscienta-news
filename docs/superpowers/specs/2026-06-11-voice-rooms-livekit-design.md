# Audio-Only Voice Rooms via LiveKit

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-11
**Phase:** 3 — Intelligence & Growth › Live Rooms & Real-time
**Todo item:** `Audio/video (LiveKit/WebRTC) (Optional)` — this slice delivers
**audio-only** voice chat in live rooms (video is explicitly deferred).

## Goal

Let members of a group's live room join a **voice channel** (Discord-voice /
Twitter-Spaces style): join/leave, mute/unmute, and see who's in the call — powered
by a LiveKit SFU. Audio only; no camera/video.

## Decisions (from brainstorming)

- **Audio-only.** No video grid, camera, or screen-share.
- **New `:voice_rooms` flag**, off by default (independent of `:live_rooms`).
- **Vendored client SDK:** the prebuilt `livekit-client` ESM bundle is committed to
  `assets/vendor/livekit-client.js` and imported like `topbar` (no npm, no CDN).
- **Hand-rolled HS256 JWT** (`:crypto`, no new dep) for LiveKit access tokens.
- **Honest boundary:** this ships behind the flag and **cannot be end-to-end verified
  in dev** (no LiveKit server). Server-side (token, gating, LiveView assigns/DOM) is
  unit-tested; the vendored SDK + JS hook + actual media are browser-only and
  verified manually against a deployed LiveKit server.

## Background (current state)

- `VerscientaWeb.RoomLive` (`lib/verscienta_web/live/room_live.ex`): the text room at
  `/groups/:slug/room`. Mount gates **auth → group membership → not banned**
  (`room_live.ex:20-46`), then `mount_room/4` subscribes PubSub `"room:#{room.id}"`,
  `Presence.track(self(), topic, user.id, %{username: …})` (`:53`), and assigns
  `present`, `can_moderate`, etc. `presence_users/1` (`:258-264`) maps presence to
  `%{id, username}`. Moderator **ban** broadcasts `{:banned, uid}`; the banned user is
  pushed out (`:221-230`).
- `Verscienta.Communities`: `member?/2`, `banned?/2`, `can_moderate?/2`,
  `room_for_group/1`. `Room` has `id`, `status` (`:open|:closed`), `group_id`.
- `:live_rooms` flag gates the room route (router `:gate_live_rooms` pipeline). Flags
  in `Verscienta.Flags.@known_flags`; seeded off in `Verscienta.Flags.Seeds.@phase3_off`
  + a `@labels` entry.
- `config/runtime.exs`: external creds via `System.get_env(... ) || raise(...)` in
  prod, with dev/test defaults (Meilisearch pattern). `Req` is available; no
  `joken`/`jose`.
- `assets/js/app.js`: `Hooks` object; libs imported from `../vendor/*` (e.g.
  `import topbar from "../vendor/topbar"`); hooks registered via
  `hooks: {...colocatedHooks, ...Hooks}`. esbuild `--bundle`, no npm/node_modules.
- `VerscientaWeb.Presence` (`Phoenix.Presence`).

## Architecture

### 1. `:voice_rooms` flag

- Add `voice_rooms` to `Verscienta.Flags.@known_flags` (`flags.ex`).
- Add `voice_rooms` to `@phase3_off` + a `@labels` entry
  (`"Voice rooms (LiveKit audio)"`) in `flags/seeds.ex` (seeded OFF).

### 2. Config (`config/runtime.exs`)

Prod (required when set up; mirror Meilisearch — but voice is optional, so DON'T
`raise` if absent — instead leave unset so `configured?/0` is false and the UI hides):
```elixir
config :verscienta,
  livekit_url: System.get_env("LIVEKIT_URL"),
  livekit_api_key: System.get_env("LIVEKIT_API_KEY"),
  livekit_api_secret: System.get_env("LIVEKIT_API_SECRET")
```
Dev/test defaults (so the suite + `configured?/0` work serverless):
```elixir
if config_env() in [:dev, :test] do
  config :verscienta,
    livekit_url: System.get_env("LIVEKIT_URL", "ws://localhost:7880"),
    livekit_api_key: System.get_env("LIVEKIT_API_KEY", "devkey"),
    livekit_api_secret: System.get_env("LIVEKIT_API_SECRET", "devsecret")
end
```

### 3. `Verscienta.LiveKit` + `Verscienta.LiveKit.Token`

**`Verscienta.LiveKit`** — config + the public token entry point:
```elixir
defmodule Verscienta.LiveKit do
  alias Verscienta.LiveKit.Token

  @ttl_seconds 6 * 3600

  @doc "True when LiveKit URL + key + secret are all configured."
  def configured?, do: present?(url()) and present?(api_key()) and present?(api_secret())

  def url, do: cfg(:livekit_url)

  @doc "A signed LiveKit access token granting `identity` (display `name`) join+publish+subscribe in `room`."
  def access_token(identity, name, room),
    do: Token.sign(api_key(), api_secret(), to_string(identity), to_string(name), room, @ttl_seconds)

  defp api_key, do: cfg(:livekit_api_key)
  defp api_secret, do: cfg(:livekit_api_secret)
  defp cfg(k), do: Application.get_env(:verscienta, k)
  defp present?(v), do: is_binary(v) and v != ""
end
```

**`Verscienta.LiveKit.Token`** — the pure HS256 JWT (no config dependency, unit-testable):
```elixir
defmodule Verscienta.LiveKit.Token do
  @moduledoc "Mints LiveKit access tokens (HS256 JWT) using :crypto — no external JWT dep."

  @doc """
  A LiveKit JWT: header `{alg: HS256, typ: JWT}`, claims `iss/sub/name/nbf/exp` + the
  `video` grant (roomJoin/room/canPublish/canSubscribe/canPublishData), signed
  HMAC-SHA256 over the API secret. `now` is injectable for tests.
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
    sig = :crypto.mac(:hmac, :sha256, secret, signing_input)
    signing_input <> "." <> b64(sig)
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
end
```
- `room_name` convention: `"room_#{room.id}"` (built by the caller).
- The **secret never leaves the server**; the client receives only the signed token +
  the `wss` URL.

### 4. `RoomLive` voice integration

In `mount_room/4`, add assigns:
```elixir
voice_enabled: Verscienta.Flags.enabled?(:voice_rooms) and Verscienta.LiveKit.configured?(),
in_voice: false,
voice_token: nil,
muted: false
```
Presence track meta gains `voice: false`:
```elixir
Presence.track(self(), topic, to_string(user.id), %{username: to_string(user.username), voice: false})
```

New events:
- **`"join_voice"`**: re-gate (`Communities.member?` + not `Communities.banned?`); if ok,
  `token = LiveKit.access_token(user.id, user.username, "room_#{room.id}")`;
  `Presence.update(self(), topic, to_string(user.id), &Map.put(&1, :voice, true))`;
  assign `in_voice: true, voice_token: token`. If not a member/banned → no-op (defense;
  mount already gated).
- **`"leave_voice"`**:
  `Presence.update(self(), topic, to_string(user.id), &Map.put(&1, :voice, false))`;
  assign `in_voice: false, voice_token: nil, muted: false`.
- **`"toggle_mute"`**: `assign(socket, muted: !socket.assigns.muted)`.
- **`"voice_error"`** (pushed by the hook on a failed connect): flash `:error`
  "Couldn't connect to voice." and leave voice (`in_voice: false, voice_token: nil`,
  presence `voice: false`). This handler is **required** — a `pushEvent` with no
  matching `handle_event` crashes the LiveView.

`presence_users/1` includes voice state:
```elixir
|> Enum.map(fn {id, %{metas: [meta | _]}} -> %{id: id, username: meta.username, voice: Map.get(meta, :voice, false)} end)
```
(All other handlers that re-run `presence_users` keep working — the extra field is additive.)

Render (gated additively on `@voice_enabled`, near the presence line):
```heex
<div :if={@voice_enabled} class="mb-4">
  <button :if={!@in_voice} type="button" phx-click="join_voice"
    class="bg-zune px-4 py-2 text-xs font-semibold uppercase text-canvas">join voice</button>

  <div :if={@in_voice}
    id="voice-room" phx-hook="VoiceRoom"
    data-url={Verscienta.LiveKit.url()} data-token={@voice_token} data-muted={to_string(@muted)}
    class="flex items-center gap-3">
    <button type="button" phx-click="toggle_mute" class="border border-line px-3 py-1.5 text-xs uppercase">
      {if @muted, do: "unmute", else: "mute"}
    </button>
    <button type="button" phx-click="leave_voice" class="text-xs uppercase tracking-wider text-politics hover:underline">
      leave voice
    </button>
  </div>
</div>
```
The participant list shows a 🔊 marker for present users whose `voice` is true (extend
the `@present` rendering).

### 5. JS hook + vendored SDK

- **Vendor:** download the prebuilt `livekit-client` ESM bundle (a pinned 2.x version)
  to `assets/vendor/livekit-client.js`. Record the exact version in a header comment.
- **`assets/js/voice_room.js`** (new), registered in `app.js`
  (`import VoiceRoom from "./voice_room"` + `Hooks.VoiceRoom = VoiceRoom`):
```js
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
    if (this.room?.localParticipant) {
      this.room.localParticipant.setMicrophoneEnabled(this.el.dataset.muted !== "true")
    }
  },
  destroyed() { this.room?.disconnect() }
},
```
  (The `"voice_error"` push is handled by RoomLive — see §4.)

### 6. Gating & security

- Voice UI behind `@voice_enabled` (`:voice_rooms` flag AND `LiveKit.configured?`).
- Token minted server-side only, after a fresh `member?` + `banned?` re-check, for the
  authenticated user; `identity = user.id`, room scoped to `room_#{room.id}`, 6h TTL.
- Secret never sent to the client. Ban flow (`{:banned, uid}`) already ejects the user
  from the room, tearing down the hook (and its `room.disconnect()`).

## Testing

- **`Verscienta.LiveKit.Token.sign/7`** (pinned `now`): split on `"."`, Base64url-decode
  + `Jason.decode` the header (`HS256`) + claims; assert `iss`/`sub`/`name`/`nbf`/`exp`
  (= now + ttl) and the `video` grant (`roomJoin`, `room`, `canPublish`, `canSubscribe`);
  recompute `:crypto.mac(:hmac, :sha256, secret, header.payload)` |> Base64url and assert
  it equals the 3rd segment (valid signature); a **wrong secret** produces a different
  signature (tamper detection).
- **`Verscienta.LiveKit`**: `configured?/0` true with all three set, false when any is
  blank/nil (use `Application.put_env`/`delete_env` with restore on_exit); `access_token/3`
  returns a 3-segment string whose claims carry the given room/identity.
- **`RoomLive`** (mirror the existing `room_live_test.exs` group+membership setup;
  `async: false` to toggle the flag): with `:voice_rooms` enabled (and dev/test LiveKit
  config making `configured?` true):
  - a member sees a **join voice** control; `render_click("join_voice")` renders the
    `#voice-room` element carrying a non-empty `data-token` + `data-url`; presence meta
    for the user flips `voice: true`.
  - `leave_voice` removes the `#voice-room` element; `toggle_mute` flips `data-muted`
    between `"false"`/`"true"`.
  - with `:voice_rooms` **disabled** (default), no voice control renders.
  - (Membership/ban gating is already covered by the existing mount tests — a non-member
    never reaches the room.)
- **Not tested here** (documented in the spec + a code comment): the vendored
  `livekit-client` bundle, the `VoiceRoom` JS hook, and the actual WebRTC audio — these
  require a deployed LiveKit server and a browser, verified manually.

## Out of scope (later)

- Video / camera / screen-share; recording; e2ee.
- Speaking indicators via presence (too chatty — a later client-only visual).
- LiveKit server REST API (room listing, server-side participant kick) — rely on token
  TTL + the existing ban for now.
- Per-room moderator voice enable/disable; max-participant limits; TURN config UI.
- Automated/browser testing of the media path.

## Files touched (summary)

- `lib/verscienta/flags.ex` + `lib/verscienta/flags/seeds.ex` — `:voice_rooms`.
- `config/runtime.exs` — LiveKit URL/key/secret (prod optional + dev/test defaults).
- `lib/verscienta/live_kit.ex` (`Verscienta.LiveKit`) + `lib/verscienta/live_kit/token.ex`
  (`Verscienta.LiveKit.Token`).
- `lib/verscienta_web/live/room_live.ex` — voice assigns, `join_voice`/`leave_voice`/
  `toggle_mute`, presence `voice` meta, render.
- `assets/vendor/livekit-client.js` (vendored), `assets/js/voice_room.js` (hook),
  `assets/js/app.js` (register the hook).
- Tests: `LiveKit.Token`, `LiveKit` config, `RoomLive` voice (server-side only).
- No migration, no new resource/attribute/action. One new flag.
