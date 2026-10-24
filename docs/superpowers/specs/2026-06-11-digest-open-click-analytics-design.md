# Digest Refinements — Slice 4: Open/Click Analytics

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-11
**Phase:** 3 — Intelligence & Growth › Notifications & Digests
**Todo item:** `Digest refinements (deferred): … open/click analytics.` — the final
digest-refinements sub-item.

## Goal

Measure digest engagement: an email **open** (1×1 tracking pixel) and a **link
click** (link-wrapping redirect) each fire a server-side PostHog event. Both are
behind a new off-by-default `:digest_tracking` flag, so a privacy-conscious
deployment collects nothing until it opts in.

## Decisions (from brainstorming)

- **Both open + click**, behind a new **`:digest_tracking` flag, off by default**
  (seeded in `@phase3_off`). Flag off → the email uses today's plain links + no
  pixel; zero data collected.
- **Destination lives inside the signed token** for clicks → the redirect can't be
  tampered into an open-redirect; no untrusted query param.
- **HTML-only:** the text body stays plain (pixels don't work in text; we don't
  uglify text links with redirect URLs).
- **Preview never tracks:** `Digests.preview/1` builds with `track: false`.

## Background (current state)

- `Verscienta.Digests.Email` (`lib/verscienta/digests/email.ex`): `build/3` →
  `html/3` + `text/3`. HTML links: article (`/articles/:slug`), activity
  notification (`/notifications`) + room (`/groups/:slug/room`), and an unsubscribe
  link. `deliver/3` sends; `Digests.preview/1` calls `Email.build/3`.
- Token pattern: `Digests.unsubscribe_token/1` =
  `Phoenix.Token.sign(VerscientaWeb.Endpoint, "digest unsubscribe", user.id)`;
  `verify_unsubscribe_token/1` with `max_age: 2_592_000` (30d). Route
  `GET /digests/unsubscribe/:token` → `DigestController.unsubscribe`.
- `Verscienta.Analytics.capture(event, distinct_id, props)` (PostHog server-side,
  stubbed in tests via `:analytics_client`). `distinct_id/2` resolves a user/anon.
  Existing `track_*` helpers.
- `Verscienta.Flags`: `@known_flags` (`flags.ex`), `@phase3_off` + labels
  (`flags/seeds.ex`). Flags seeded off here.
- Router: public scope has `get "/digests/unsubscribe/:token", DigestController, :unsubscribe`.

## Architecture

### 1. `:digest_tracking` flag

- Add `digest_tracking` to `Verscienta.Flags.@known_flags` (`flags.ex`).
- Add `digest_tracking` to `@phase3_off` and a label
  (`"Digest open/click tracking"`) in `flags/seeds.ex` (seeded OFF).
- Read via `Verscienta.Flags.enabled?(:digest_tracking)` (global; no actor needed).

### 2. Signed tracking tokens (`Verscienta.Digests`)

Mirror the unsubscribe-token pattern (same 30-day max age):
```elixir
@tracking_salt "digest tracking"

@doc "Signed token for an open pixel: encodes the recipient + send time."
def open_token(user_id, sent_at_unix),
  do: Phoenix.Token.sign(VerscientaWeb.Endpoint, @tracking_salt, %{"u" => user_id, "s" => sent_at_unix})

@doc "Signed token for a click redirect: recipient + send time + internal destination path."
def click_token(user_id, sent_at_unix, dest_path),
  do: Phoenix.Token.sign(VerscientaWeb.Endpoint, @tracking_salt, %{"u" => user_id, "s" => sent_at_unix, "d" => dest_path})

@doc "Verify a tracking token → {:ok, map} | {:error, reason}."
def verify_tracking_token(token),
  do: Phoenix.Token.verify(VerscientaWeb.Endpoint, @tracking_salt, token, max_age: 2_592_000)
```
(`sent_at_unix` = `DateTime.to_unix(sent_at)`; the token carries it so events can be
grouped by send.)

### 3. Email rendering (`Digests.Email`)

- `build/3` → `build/4` with `opts \\ []`. Compute once:
  ```elixir
  track? = Keyword.get(opts, :track, true) and Verscienta.Flags.enabled?(:digest_tracking)
  sent_at = DateTime.to_unix(DateTime.utc_now())
  ```
  Thread `user.id`, `track?`, `sent_at` into `html/_`.
- **Link wrapping (HTML only):** a private `link/4` (or `track_url/3`) builds the
  href for a content link: when `track?`, returns
  `url(~p"/digests/click/#{click_token(user_id, sent_at, dest_path)}")`; else the
  plain `dest_path` URL. Apply to:
  - article links (`dest_path = ~p"/articles/#{a.slug}"`),
  - activity notification links (`dest_path = ~p"/notifications"`),
  - activity room links (`dest_path = ~p"/groups/#{r.slug}/room"`).
  The **unsubscribe** link is never wrapped.
- **Open pixel:** when `track?`, append before the unsubscribe footer:
  ```elixir
  ~s(<img src="#{url(~p"/digests/open/#{open_token(user_id, sent_at)}")}" width="1" height="1" alt="" style="display:none">)
  ```
- `text/_` is unchanged (plain links, no pixel).
- `deliver/3` calls `build/4` with default opts (so the flag decides). **`Digests.preview/1`
  calls `Email.build(user, highlights, activity, track: false)`** — the admin preview
  never wraps links or emits a pixel.

> `dest_path` passed into the token must be the path-only form (e.g.
> `~p"/articles/#{slug}"` yields `/articles/slug`). The token signs it; the click
> endpoint redirects to it after a `String.starts_with?(dest, "/")` guard.

### 4. Routes + controller (`DigestController`)

Add to the public scope (next to the unsubscribe route):
```elixir
get "/digests/open/:token", DigestController, :open
get "/digests/click/:token", DigestController, :click
```

- **`open/2`:** `verify_tracking_token` → on `{:ok, %{"u" => uid, "s" => s}}`,
  `Analytics.track_digest_opened(uid, s)` (best-effort, wrapped so it never breaks
  the response). **Always** respond with a 1×1 transparent GIF:
  ```elixir
  conn
  |> put_resp_content_type("image/gif")
  |> put_resp_header("cache-control", "no-store, no-cache, must-revalidate, private")
  |> send_resp(200, @pixel)
  ```
  where `@pixel` is the 43-byte transparent GIF binary. A bad/expired token → still
  return the pixel, no capture (never leak validity or break rendering).
- **`click/2`:** `verify_tracking_token` → on `{:ok, %{"u" => uid, "s" => s, "d" => dest}}`
  with `String.starts_with?(dest, "/")`: `Analytics.track_digest_click(uid, dest, s)`
  (best-effort) then `redirect(conn, to: dest)`. Any failure (bad token, non-`/`
  dest) → `redirect(conn, to: "/")` with no capture (no open-redirect).

### 5. Analytics (`Verscienta.Analytics`)

```elixir
def track_digest_opened(user_id, sent_at) do
  capture("digest_opened", to_string(user_id), %{"sent_at" => sent_at})
end

def track_digest_click(user_id, path, sent_at) do
  capture("digest_link_clicked", to_string(user_id), %{"path" => path, "sent_at" => sent_at})
end
```
`distinct_id` = the recipient user id. No PII beyond the recipient id + the internal
path + the send timestamp — consistent with existing server-side capture.

### 6. Privacy / safety summary

- Off by default (`:digest_tracking` seeded off); flag off ⇒ no pixel, no wrapped
  links, no events.
- Tokens are `Phoenix.Token`-signed (tamper-proof), 30-day TTL.
- No open-redirect: the click destination is signed into the token and must start
  with `/`.
- The pixel returns the GIF regardless of token validity (no enumeration signal, no
  broken rendering).
- Preview (admin) never tracks.

## Testing

- **Tokens:** `open_token`/`click_token` round-trip via `verify_tracking_token`;
  a tampered/garbage token → `{:error, _}`.
- **Email (`build/4`):**
  - Flag **on**: article + activity links point at `/digests/click/` (not the bare
    `/articles/...`); an open-pixel `<img ... /digests/open/...` is present; the
    unsubscribe link is NOT wrapped.
  - Flag **off**: plain `/articles/...` links, no `/digests/click/`, no pixel
    (today's output).
  - `build(..., track: false)` (preview path): plain links, no pixel, even with the
    flag on.
- **Controller:**
  - `GET /digests/open/:token` (valid) → 200, `image/gif` content-type, and a
    `digest_opened` capture for the user (assert via the analytics stub). Bad token
    → 200 GIF, **no** capture.
  - `GET /digests/click/:token` (valid) → 302 to the dest path, a
    `digest_link_clicked` capture with that path. A tampered token / non-`/` dest →
    302 to `/`, no capture.
- **Flag gating:** with `:digest_tracking` off, the controller endpoints still work
  if hit directly (tokens are independent of the flag), but the email contains no
  tracking links/pixel — covered by the email tests.

## Out of scope (later)

- Text-body tracking (HTML only).
- A local opens/clicks dashboard or aggregation (events live in PostHog).
- Bot/proxy open filtering (Apple Mail Privacy Protection etc.); per-link unique
  ids; open/click A-B testing.
- Per-user tracking opt-out beyond the global flag.

## Files touched (summary)

- `lib/verscienta/flags.ex` + `lib/verscienta/flags/seeds.ex` — `:digest_tracking`
  (known + phase3-off + label).
- `lib/verscienta/digests.ex` — `open_token/2`, `click_token/3`,
  `verify_tracking_token/1`; `preview/1` passes `track: false`.
- `lib/verscienta/digests/email.ex` — `build/4` (+ `track?`/`sent_at`), link
  wrapping + open pixel (HTML only).
- `lib/verscienta/analytics.ex` — `track_digest_opened/2`, `track_digest_click/3`.
- `lib/verscienta_web/controllers/digest_controller.ex` — `open/2`, `click/2` + the
  transparent-GIF binary.
- `lib/verscienta_web/router.ex` — `/digests/open/:token` + `/digests/click/:token`.
- Tests across the above (tokens, email build, controller, analytics stub).
- No migration, no new resource/attribute/action. One new flag.
