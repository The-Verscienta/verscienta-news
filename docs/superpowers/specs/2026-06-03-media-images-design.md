# Media & Images Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-03
**Status:** Approved
**Phase:** 2 (Social & Gamification) — Subsystem 4 of 7: Media & Images
**Depends on:** Phase 1 (Accounts, Content). Reuses the Meilisearch client/behaviour/stub pattern,
the `safe_url` render whitelist, `req`, the settings + article-editor LiveViews, and the image block.

## Goal

Real image uploads via **Cloudflare Images**, server-proxied from LiveView: user avatars, article
cover images, and inline editor images. An external-service client (behaviour + Req impl + dev
`Local` + test `Stub`) keeps it fully testable and runnable offline. No schema changes — uploaded
images are stored as Cloudflare delivery URLs in the existing URL fields.

## Decisions

| Decision | Choice |
|----------|--------|
| Provider | Cloudflare Images |
| Upload flow | **Server-proxied**: browser → LiveView (`allow_upload`) → server POSTs to Cloudflare → store URL |
| Client abstraction | `Verscienta.Images.Client` behaviour; impls `Req` (prod), `Local` (dev), `Stub` (test), selected by config |
| What we store | The full **delivery URL** for the chosen variant in the EXISTING `avatar_url` / `cover_image_url` / image-block `url` fields. No migration. |
| Variants | `avatar` (square), `cover` (wide), `public` (inline) — configured in Cloudflare; `Local`/`Stub` return placeholders |
| Targets | User avatar, article cover, inline editor image |
| Validation | `accept ~w(.jpg .jpeg .png .webp .gif)`, `max_file_size 15MB`, `max_entries 1` |
| Deferred | R2 (no consumer), direct/external uploads, orphan cleanup, video, client-side cropping |

## Architecture

### `Verscienta.Images` (context) + `Verscienta.Images.Client` (behaviour)
Mirrors `Verscienta.Search.Client`.

`Verscienta.Images.Client` behaviour:
```
@callback upload(binary :: binary, filename :: String.t(), opts :: keyword) ::
            {:ok, %{"id" => String.t()}} | {:error, term}
@callback delete(id :: String.t()) :: :ok | {:error, term}   # for future cleanup; not wired yet
```
Dispatch: `defp impl, do: Application.get_env(:verscienta, :images_client, __MODULE__.Req)`.

Impls:
- **`Verscienta.Images.Client.Req`** (prod default): multipart `POST https://api.cloudflare.com/client/v4/accounts/<account_id>/images/v1`
  with the file part, header `Authorization: Bearer <api_token>`. Returns `{:ok, %{"id" => result["id"]}}`
  on success, `{:error, ...}` otherwise. (`delete/1` → `DELETE .../images/v1/<id>`.)
- **`Verscienta.Images.Client.Local`** (dev default): no network; returns `{:ok, %{"id" => "local-<rand-from-filename>"}}`.
  Combined with `Local` delivery-URL building, yields a working placeholder image so the upload UX
  works fully offline.
- **`Verscienta.Images.Client.Stub`** (test): records calls (like `Search.ClientStub`), returns a
  configurable response (default `{:ok, %{"id" => "stub-image-id"}}`).

### `Verscienta.Images` context functions
- `upload_image(binary, filename, variant) :: {:ok, url} | {:error, term}` — calls `Client.upload/3`,
  then `delivery_url(id, variant)`; returns the full URL to store.
- `delivery_url(id, variant) :: String.t()` — builds `https://imagedelivery.net/<account_hash>/<id>/<variant>`.
  For `Local`/`Stub` (no real account hash), returns a deterministic placeholder
  (e.g. `https://placehold.co/600x400?text=<id>` or a configured dev base) so rendering works offline.
- `consume_upload(socket, upload_name, variant) :: {socket, [url]}` — wraps
  `Phoenix.LiveView.consume_uploaded_entries/3`: reads each temp file, calls `upload_image/3`,
  returns the resulting URLs (and leaves error handling to the caller via flash).

### Config
- `config/config.exs`: `config :verscienta, images_client: Verscienta.Images.Client.Req` (overridden per env below),
  plus `cloudflare_images_account_hash` placeholder for delivery URLs.
- `config/dev.exs` (or runtime dev block): `images_client: Verscienta.Images.Client.Local`.
- `config/test.exs`: `images_client: Verscienta.Images.Client.Stub`.
- `config/runtime.exs` prod block: read `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_API_TOKEN`,
  `CLOUDFLARE_IMAGES_ACCOUNT_HASH`, each `|| raise(...)`; set `images_client: Verscienta.Images.Client.Req`.
  Dev/test fallbacks set the non-secret values to harmless defaults.

## What we store (no schema changes)

The existing fields already hold arbitrary URLs and render through `safe_url` (https whitelist):
- `User.avatar_url`, `Article.cover_image_url`, and the `image` block's `url`.

On upload we obtain the Cloudflare image id, build the **delivery URL** for the appropriate variant
(`avatar`/`cover`/`public`), and store that URL string in the same field. Uploaded and external
(aggregated/manual) URLs coexist; rendering is unchanged. Trade-off (accepted): the variant is baked
into the stored URL; re-deriving other variants later isn't possible without re-storing — fine for MVP.

## UI integration

### Avatar — `/settings` (SettingsLive)
- `allow_upload(:avatar, accept: ~w(.jpg .jpeg .png .webp .gif), max_file_size: 15_000_000, max_entries: 1)`.
- Render a `live_file_input` + a live preview of the selected entry (and the current avatar if set).
- On profile save: `consume_upload(socket, :avatar, :avatar)`; if a URL results, set `avatar_url`
  in the `update_profile` params; otherwise keep the existing value.
- Profile page + nav: render `<img src={avatar_url}>` when present (object-cover square), else the
  existing initials box. (Update `profile_live.ex` avatar render + any nav avatar.)

### Cover — article editor (ArticleEditorLive)
- Replace the "cover image url" text field with `live_file_input` (`allow_upload(:cover, ...)`) + a
  preview + a "remove" action. On save: consume → set `cover_image_url`. Keep the ability to clear it.

### Inline image block — article editor
- In the `image` block's inline editor, add a per-block `live_file_input`
  (`allow_upload(:block_image, max_entries: 1)`); on upload, set that block's `url` to the delivery
  URL, preserving `alt`/`caption`. Renders through the existing block renderer unchanged.
- NOTE: one upload config can serve the block-image flow; the editor tracks which block is being
  uploaded to (via a `phx-value-index`/assign) and writes the resulting URL into that block's data.

### Shared upload affordance
A small render helper/component for the file input + preview + per-entry error display (using
`upload_errors/2`), reused across the three places to stay DRY. Errors (too big / wrong type) render
inline; a failed Cloudflare upload surfaces as a flash and leaves the prior value intact.

## Validation & safety

- Type + size enforced by `allow_upload` (client + server). Only image extensions accepted.
- Stored delivery URLs are https `imagedelivery.net` (or the dev placeholder) — pass `safe_url`.
- `alt` text is preserved/required-encouraged on inline images for accessibility.
- A Cloudflare/network failure during `consume_upload` never crashes the LiveView: it returns no URL,
  the save proceeds with the previous value, and a flash explains the failure.

## Testing & gates

- **Client stub:** `Stub` records `upload/3` calls and returns a fake id; `config/test.exs` selects it.
- **Avatar upload (LiveViewTest):** use `file_input/4` + `render_upload/2` on `/settings`, submit, and
  assert `User.avatar_url` is set to the stub delivery URL; assert the profile renders an `<img>`.
- **Cover upload:** same pattern in the editor; assert `cover_image_url` set.
- **Inline block image:** upload into an image block; assert the block's `url` is set and `alt`/`caption`
  preserved.
- **Validation:** an oversized/wrong-type entry surfaces an `upload_errors` message and does not save.
- **`delivery_url/2`:** unit test the URL shape for each variant (and the placeholder path for Local/Stub).
- **Graceful failure:** stub returns `{:error, _}` → save keeps the old value + a flash; no crash.
- Gates green: `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`,
  `MIX_ENV=test mix test`. No migrations.

## Out of scope (deferred)

- **R2** non-image file storage (no current consumer).
- **Direct-to-Cloudflare / external uploads** (server-proxy suffices at this scale).
- **Orphan cleanup** (deleting the replaced Cloudflare image) — `Client.delete/1` exists for later; not wired.
- Video uploads, client-side cropping/rotation, EXIF stripping (Cloudflare handles delivery transforms).
- Re-deriving multiple variants from a stored image (we store one variant URL).

## Definition of Done

- `Verscienta.Images` context + `Client` behaviour with `Req`/`Local`/`Stub` impls; config wires them per env.
- Avatar upload in `/settings`; cover upload in the editor; inline image upload in the image block — all
  server-proxied, storing Cloudflare delivery URLs in the existing fields (no migration).
- Profile/nav render the uploaded avatar (img) with initials fallback; covers + inline images render via
  the existing paths.
- Upload validation (type/size) + graceful failure (flash, prior value kept).
- Dev works offline (`Local`); tests never hit the network (`Stub`); all gates green.
- Work committed on `media-images`. R2 + cleanup explicitly deferred.
