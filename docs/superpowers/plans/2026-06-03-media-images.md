# Media & Images Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Server-proxied Cloudflare Images uploads for user avatars, article covers, and inline editor images — behind a stubbable client, storing delivery URLs in the existing URL fields (no migration).

**Architecture:** A `Verscienta.Images.Client` behaviour (mirrors `Verscienta.Search.Client`) with `Req` (prod), `Local` (dev, offline placeholder), and `Stub` (test) impls. A `Verscienta.Images` context (`upload_image/3`, `delivery_url/2`, `consume_upload/3`) wraps LiveView `consume_uploaded_entries`. Uploads in `/settings` (avatar), the article editor (cover + inline image block) store the resulting Cloudflare delivery URL in `avatar_url` / `cover_image_url` / the image block's `url`.

**Tech Stack:** Phoenix 1.8, LiveView uploads (`allow_upload`/`live_file_input`/`consume_uploaded_entries`), `req`, Ash 3, Tailwind v4.

---

## Conventions for the executor

- **Run everything in Docker.** `docker compose run --rm -T app bash -lc "<cmd>"`. Start DB: `docker compose up -d db`. Generous timeouts. If "dependency not available", prefix `mix deps.get &&`.
- **One task at a time.** After each task run `git rev-parse --short HEAD` for the REAL sha. Never batch tasks or guess SHAs. **Re-run the FULL gate (`mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `MIX_ENV=test mix test`) after the FINAL edit of each task, BEFORE committing.**
- **Branch:** `media-images` (already checked out; spec committed `b874cca`).
- **Line endings:** `.gitattributes` eol=lf, autocrlf false — don't change. `mix format` before commit. No `.bak`.
- **Git identity:** no local override. Commit body ends with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- **No migrations** in this work (uploaded images stored as URLs in existing fields).
- **Reuse patterns (read before editing):**
  - External-service client template: `lib/verscienta/search/client.ex` (behaviour + nested `Req` + `impl/0` via `Application.get_env(:verscienta, :search_client, ...)`). Test stub: `test/support/search_client_stub.ex` (`Verscienta.Search.ClientStub`, records calls in app env, returns configurable responses). Config: `config/config.exs` default, `config/test.exs` stub, `config/runtime.exs` prod secrets.
  - HTTP via `Elixir.Req.request/1` / `Elixir.Req.post/2`.
  - `SettingsLive` (`lib/verscienta_web/live/settings_live.ex`): AshPhoenix.Form for `update_profile`; `save` handler submits the form. Avatar text field at `<.text_field field={f[:avatar_url]} label="avatar url" />`.
  - Article editor `lib/verscienta_web/live/article_editor_live.ex`: cover text field `<.text_field field={f[:cover_image_url]} label="cover image url" />`; image blocks added via `add_block`, inline-edited; `Block` data shape `%{"url"=>, "alt"=>, "caption"=>}`; block renderer at `lib/verscienta/content/block_renderer.ex` (`safe_url` https whitelist).
  - Profile avatar render: `lib/verscienta_web/live/profile_live.ex` `avatar_initials/1` + the initials box.
  - Codex tokens: `bg-canvas-2`, `border-line`, `text-ink`/`text-ink-3`, `bg-zune`, `text-politics` (error).

---

## File Structure

| File | Responsibility |
|------|----------------|
| `lib/verscienta/images/client.ex` | `Images.Client` behaviour + nested `Req` + `Local` impls + `impl/0` dispatch |
| `test/support/images_client_stub.ex` | `Verscienta.Images.ClientStub` (records calls, configurable response) |
| `lib/verscienta/images.ex` | context: `upload_image/3`, `delivery_url/2`, `consume_upload/3`, `variants/0` |
| `config/config.exs`, `config/dev.exs`, `config/test.exs`, `config/runtime.exs` | client selection + secrets |
| `lib/verscienta_web/components/media_components.ex` | `image_upload_field/1` (file input + preview + errors) |
| `lib/verscienta_web/live/settings_live.ex` | avatar upload |
| `lib/verscienta_web/live/profile_live.ex` | render uploaded avatar (img + initials fallback) |
| `lib/verscienta_web/live/article_editor_live.ex` | cover + inline image-block uploads |
| `docs/todo.md` | tick Media & Images items |
| tests | per task |

---

## Task 1: `Images.Client` behaviour + Req/Local impls + Stub + config (TDD)

**Files:**
- Create: `lib/verscienta/images/client.ex`, `test/support/images_client_stub.ex`
- Modify: `config/config.exs`, `config/dev.exs`, `config/test.exs`, `config/runtime.exs`
- Test: `test/verscienta/images/client_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/images/client_test.exs`:
```elixir
defmodule Verscienta.Images.ClientTest do
  use ExUnit.Case, async: true

  alias Verscienta.Images.Client

  setup do
    prev = Application.get_env(:verscienta, :images_client)
    on_exit(fn -> Application.put_env(:verscienta, :images_client, prev) end)
    :ok
  end

  test "dispatches to the configured implementation (Local returns an id)" do
    Application.put_env(:verscienta, :images_client, Verscienta.Images.Client.Local)
    assert {:ok, %{"id" => "local-" <> _}} = Client.upload(<<1, 2, 3>>, "pic.png", [])
  end

  test "Local delete is a no-op :ok" do
    assert :ok = Verscienta.Images.Client.Local.delete("local-abc")
  end
end
```

- [ ] **Step 2: Create the client behaviour + Req + Local impls**

Create `lib/verscienta/images/client.ex`:
```elixir
defmodule Verscienta.Images.Client do
  @moduledoc "Behaviour + implementations for the Cloudflare Images API."

  @callback upload(binary :: binary, filename :: String.t(), opts :: keyword) ::
              {:ok, %{required(String.t()) => term}} | {:error, term}
  @callback delete(id :: String.t()) :: :ok | {:error, term}

  def upload(binary, filename, opts \\ []), do: impl().upload(binary, filename, opts)
  def delete(id), do: impl().delete(id)

  defp impl, do: Application.get_env(:verscienta, :images_client, __MODULE__.Req)

  defmodule Req do
    @moduledoc false
    @behaviour Verscienta.Images.Client

    @impl true
    def upload(binary, filename, _opts) do
      url =
        "https://api.cloudflare.com/client/v4/accounts/#{account_id()}/images/v1"

      form = [file: {binary, filename: filename}]

      case Elixir.Req.post(url,
             headers: [{"authorization", "Bearer " <> api_token()}],
             form_multipart: form,
             receive_timeout: 30_000
           ) do
        {:ok, %{status: status, body: %{"result" => %{"id" => id} = result}}}
        when status in 200..299 ->
          {:ok, Map.put(result, "id", id)}

        {:ok, %{status: status, body: body}} ->
          {:error, {:http_status, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def delete(id) do
      url = "https://api.cloudflare.com/client/v4/accounts/#{account_id()}/images/v1/#{id}"

      case Elixir.Req.request(
             method: :delete,
             url: url,
             headers: [{"authorization", "Bearer " <> api_token()}],
             receive_timeout: 10_000
           ) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, %{status: status, body: body}} -> {:error, {:http_status, status, body}}
        {:error, reason} -> {:error, reason}
      end
    end

    defp account_id, do: Application.fetch_env!(:verscienta, :cloudflare_account_id)
    defp api_token, do: Application.fetch_env!(:verscienta, :cloudflare_api_token)
  end

  defmodule Local do
    @moduledoc "Dev/offline implementation: no network, returns a deterministic fake id."
    @behaviour Verscienta.Images.Client

    @impl true
    def upload(_binary, filename, _opts) do
      slug =
        filename
        |> to_string()
        |> String.replace(~r/[^a-zA-Z0-9]+/, "-")
        |> String.trim("-")
        |> String.downcase()

      {:ok, %{"id" => "local-" <> slug}}
    end

    @impl true
    def delete(_id), do: :ok
  end
end
```
NOTE: confirm the `req` version supports `form_multipart:` (Req 0.5 does). If the exact option name differs in this Req version, use the correct multipart option (e.g. `form_multipart` vs building a `Multipart`); the contract is "POST the file as multipart field `file`". The Req impl is NOT exercised by tests (Local/Stub are used) — but it must compile.

- [ ] **Step 3: Create the test stub** — Create `test/support/images_client_stub.ex`:
```elixir
defmodule Verscienta.Images.ClientStub do
  @moduledoc "Test stub for Verscienta.Images.Client — records calls, returns configurable responses."
  @behaviour Verscienta.Images.Client

  @impl true
  def upload(binary, filename, opts), do: respond(:upload, [binary, filename, opts])

  @impl true
  def delete(id), do: respond(:delete, [id])

  defp respond(fun, args) do
    record(fun, args)
    stub = Application.get_env(:verscienta, :images_stub, %{})
    Map.get(stub, fun, default(fun))
  end

  defp default(:upload), do: {:ok, %{"id" => "stub-image-id"}}
  defp default(:delete), do: :ok

  defp record(fun, args) do
    calls = Application.get_env(:verscienta, :images_stub_calls, [])
    Application.put_env(:verscienta, :images_stub_calls, calls ++ [{fun, args}])
  end
end
```

- [ ] **Step 4: Wire config**

In `config/config.exs`, in the existing `config :verscienta, ...` (where `search_client` is set), add:
```elixir
  images_client: Verscienta.Images.Client.Req,
  cloudflare_account_id: nil,
  cloudflare_api_token: nil,
  cloudflare_images_account_hash: nil
```
In `config/dev.exs`, add:
```elixir
config :verscienta, images_client: Verscienta.Images.Client.Local
```
In `config/test.exs`, add (near the `search_client` stub line):
```elixir
config :verscienta, images_client: Verscienta.Images.ClientStub
```
In `config/runtime.exs`, inside the `if config_env() == :prod do` block (near the Meilisearch secrets), add:
```elixir
  config :verscienta,
    images_client: Verscienta.Images.Client.Req,
    cloudflare_account_id:
      System.get_env("CLOUDFLARE_ACCOUNT_ID") ||
        raise("environment variable CLOUDFLARE_ACCOUNT_ID is missing."),
    cloudflare_api_token:
      System.get_env("CLOUDFLARE_API_TOKEN") ||
        raise("environment variable CLOUDFLARE_API_TOKEN is missing."),
    cloudflare_images_account_hash:
      System.get_env("CLOUDFLARE_IMAGES_ACCOUNT_HASH") ||
        raise("environment variable CLOUDFLARE_IMAGES_ACCOUNT_HASH is missing.")
```
NOTE: confirm `test/support` is compiled in the test env (it is — `search_client_stub.ex` lives there and is used). If `elixirc_paths` for `:test` doesn't already include `test/support`, the existing search stub wouldn't work, so it does.

- [ ] **Step 5: Run the test**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/images/client_test.exs"
```
Expected: 2 tests pass.

- [ ] **Step 6: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(images): Cloudflare Images client (behaviour + Req/Local/Stub) + config"
```
Then `git rev-parse --short HEAD`.

---

## Task 2: `Images` context — upload_image / delivery_url / consume_upload (TDD)

**Files:**
- Create: `lib/verscienta/images.ex`
- Test: `test/verscienta/images/context_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/images/context_test.exs`:
```elixir
defmodule Verscienta.Images.ContextTest do
  use ExUnit.Case, async: false

  alias Verscienta.Images

  setup do
    prev_hash = Application.get_env(:verscienta, :cloudflare_images_account_hash)
    on_exit(fn -> Application.put_env(:verscienta, :cloudflare_images_account_hash, prev_hash) end)
    :ok
  end

  test "delivery_url builds a Cloudflare URL when an account hash is configured" do
    Application.put_env(:verscienta, :cloudflare_images_account_hash, "accthash")
    assert Images.delivery_url("img123", :avatar) == "https://imagedelivery.net/accthash/img123/avatar"
  end

  test "delivery_url falls back to a placeholder when no account hash" do
    Application.put_env(:verscienta, :cloudflare_images_account_hash, nil)
    url = Images.delivery_url("img123", :cover)
    assert url =~ "placehold.co"
    assert url =~ "img123"
  end

  test "upload_image uploads via the client (stub) and returns a delivery URL" do
    # test env uses the Stub client → id "stub-image-id"; no account hash → placeholder URL
    assert {:ok, url} = Images.upload_image(<<1, 2, 3>>, "pic.png", :avatar)
    assert url =~ "stub-image-id"
  end
end
```

- [ ] **Step 2: Create the context**

Create `lib/verscienta/images.ex`:
```elixir
defmodule Verscienta.Images do
  @moduledoc """
  Image upload + delivery. Server-proxies uploads to Cloudflare Images via
  `Verscienta.Images.Client` and builds delivery URLs for named variants.
  """

  @variants [:avatar, :cover, :public]

  def variants, do: @variants

  @doc "Upload bytes and return the delivery URL for `variant`, or `{:error, reason}`."
  def upload_image(binary, filename, variant) do
    case Verscienta.Images.Client.upload(binary, filename, []) do
      {:ok, %{"id" => id}} -> {:ok, delivery_url(id, variant)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Build the delivery URL for an image id + variant (placeholder when no account hash)."
  def delivery_url(id, variant) do
    case Application.get_env(:verscienta, :cloudflare_images_account_hash) do
      hash when is_binary(hash) and hash != "" ->
        "https://imagedelivery.net/#{hash}/#{id}/#{variant}"

      _ ->
        "https://placehold.co/600x400?text=#{URI.encode_www_form(to_string(id))}"
    end
  end

  @doc """
  Consume a LiveView upload (max 1 entry) and return:
  `{:ok, url}` on success, `:none` if no file was selected, `{:error, reason}` on failure.
  """
  def consume_upload(socket, name, variant) do
    socket
    |> Phoenix.LiveView.consume_uploaded_entries(name, fn %{path: path}, entry ->
      {:ok, upload_image(File.read!(path), entry.client_name, variant)}
    end)
    |> case do
      [] -> :none
      [{:ok, url}] -> {:ok, url}
      [{:error, reason}] -> {:error, reason}
    end
  end
end
```
NOTE: `consume_uploaded_entries/3`'s callback must return `{:ok, term}` or `{:postpone, term}`; here it returns `{:ok, upload_image(...)}` so the consumed list contains the `{:ok, url}`/`{:error, reason}` tuple from `upload_image/3`. With `max_entries: 1` the list has 0 or 1 element.

- [ ] **Step 3: Run the test**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta/images/context_test.exs"
```
Expected: 3 tests pass.

- [ ] **Step 4: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(images): Images context (upload_image/delivery_url/consume_upload)"
```
Then `git rev-parse --short HEAD`.

---

## Task 3: `image_upload_field` component (TDD)

**Files:**
- Create: `lib/verscienta_web/components/media_components.ex`
- Test: `test/verscienta_web/components/media_components_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/components/media_components_test.exs`:
```elixir
defmodule VerscientaWeb.MediaComponentsTest do
  use VerscientaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import VerscientaWeb.MediaComponents

  test "renders a current image preview + a file input label" do
    # Build a minimal upload config via allow_upload in a throwaway socket is overkill here;
    # assert the static parts: the label and the current-image <img>.
    assigns = %{
      upload: %Phoenix.LiveView.UploadConfig{
        name: :avatar,
        ref: "ref",
        entries: [],
        errors: []
      },
      label: "avatar",
      current_url: "https://example.com/a.png"
    }

    html = render_component(&image_upload_field/1, assigns)
    assert html =~ "avatar"
    assert html =~ ~s(src="https://example.com/a.png")
  end
end
```
NOTE: if constructing a bare `%Phoenix.LiveView.UploadConfig{}` is awkward/version-specific, simplify the test to assert only what's robust (the `@label` text and the `@current_url` `<img>`), and keep the component tolerant of an empty upload. The real upload behavior is covered by the LiveView tests in Tasks 4-6.

- [ ] **Step 2: Create the component**

Create `lib/verscienta_web/components/media_components.ex`:
```elixir
defmodule VerscientaWeb.MediaComponents do
  @moduledoc "Shared media UI: an image upload field (current preview + file input + entry errors)."
  use Phoenix.Component

  @doc """
  Renders a current-image preview (if any), a `live_file_input`, selected-entry previews,
  and per-entry upload errors. `upload` is a `Phoenix.LiveView.UploadConfig` from `allow_upload`.
  """
  attr :upload, Phoenix.LiveView.UploadConfig, required: true
  attr :label, :string, required: true
  attr :current_url, :string, default: nil
  attr :class, :string, default: ""

  def image_upload_field(assigns) do
    ~H"""
    <div class={["space-y-2", @class]}>
      <span class="block text-[11px] uppercase tracking-widest text-ink-3">{@label}</span>

      <img
        :if={@current_url && @current_url != ""}
        src={@current_url}
        alt={@label}
        class="h-24 w-24 border border-line object-cover"
      />

      <div :for={entry <- @upload.entries} class="text-xs text-ink-3">
        <.live_img_preview entry={entry} class="h-24 w-24 border border-line object-cover" />
        <p :for={err <- upload_errors(@upload, entry)} class="mt-1 text-politics">
          {error_to_string(err)}
        </p>
      </div>

      <.live_file_input upload={@upload} class="block text-xs text-ink-3" />
    </div>
    """
  end

  defp error_to_string(:too_large), do: "file is too large (max 15 MB)"
  defp error_to_string(:not_accepted), do: "unsupported file type"
  defp error_to_string(:too_many_files), do: "only one file allowed"
  defp error_to_string(_), do: "upload error"
end
```
NOTE: `live_file_input/1` and `live_img_preview/1` are imported via `use Phoenix.Component`? They live in `Phoenix.Component` (yes, both are in `Phoenix.Component`). If not in scope, add `import Phoenix.Component` (already via `use`) — they are available. `upload_errors/2` is also in `Phoenix.Component`.

- [ ] **Step 3: Run the test**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/components/media_components_test.exs"
```
Expected: 1 test passes. (If the `%UploadConfig{}` literal is rejected by this LV version, simplify per the Step 1 note.)

- [ ] **Step 4: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(images): image_upload_field component"
```
Then `git rev-parse --short HEAD`.

---

## Task 4: Avatar upload in /settings + avatar render (TDD)

**Files:**
- Modify: `lib/verscienta_web/live/settings_live.ex`, `lib/verscienta_web/live/profile_live.ex`
- Test: `test/verscienta_web/live/avatar_upload_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/avatar_upload_test.exs`:
```elixir
defmodule VerscientaWeb.AvatarUploadTest do
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

  defp sign_in(conn, u), do: conn |> Plug.Test.init_test_session(%{}) |> Helpers.store_in_session(u)

  test "uploading an avatar stores a delivery URL and renders it on the profile", %{conn: conn} do
    me = user("avuser")
    {:ok, view, _html} = conn |> sign_in(me) |> live(~p"/settings")

    avatar =
      file_input(view, "#settings-form", :avatar, [
        %{name: "me.png", content: <<137, 80, 78, 71>>, type: "image/png"}
      ])

    render_upload(avatar, "me.png")

    view
    |> form("#settings-form", %{"form" => %{"username" => "avuser"}})
    |> render_submit()

    reloaded = Ash.get!(Verscienta.Accounts.User, me.id, authorize?: false)
    assert reloaded.avatar_url =~ "stub-image-id"

    {:ok, _pview, phtml} = conn |> sign_in(me) |> live(~p"/@avuser")
    assert phtml =~ ~s(<img)
    assert phtml =~ "stub-image-id"
  end
end
```

- [ ] **Step 2: Add the upload to SettingsLive**

In `lib/verscienta_web/live/settings_live.ex`:
- Add the import + `allow_upload` in `mount/3`:
```elixir
  import VerscientaWeb.MediaComponents
```
and change `mount/3` to allow the upload:
```elixir
  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "settings")
     |> allow_upload(:avatar,
       accept: ~w(.jpg .jpeg .png .webp .gif),
       max_file_size: 15_000_000,
       max_entries: 1
     )
     |> assign_form(socket.assigns.current_user)}
  end
```
- In the `save` handler, consume the avatar upload and inject the URL into the params before submit:
```elixir
  @impl true
  def handle_event("save", %{"form" => params}, socket) do
    {socket, params} =
      case Verscienta.Images.consume_upload(socket, :avatar, :avatar) do
        {:ok, url} -> {socket, Map.put(params, "avatar_url", url)}
        :none -> {socket, params}
        {:error, _} -> {put_flash(socket, :error, "Avatar upload failed"), params}
      end

    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, user} ->
        {:noreply, socket |> put_flash(:info, "Saved") |> assign_form(user)}

      {:error, form} ->
        {:noreply, assign(socket, form: form)}
    end
  end
```
- In the render, replace `<.text_field field={f[:avatar_url]} label="avatar url" />` with the upload field (keep it INSIDE the form so the upload ref is bound to `#settings-form`):
```heex
        <.image_upload_field upload={@uploads.avatar} label="avatar" current_url={@current_user.avatar_url} />
```
NOTE: `allow_upload` puts the config under `@uploads.avatar`. The `live_file_input` must be within the `<.form id="settings-form">` so `file_input(view, "#settings-form", :avatar, ...)` targets it. Keep the existing username/display_name/bio fields. (The `avatar_url` text field is removed — uploads replace manual URL entry.)

- [ ] **Step 3: Render the avatar on the profile**

In `lib/verscienta_web/live/profile_live.ex`, change the avatar block to show the uploaded image when present, else initials. Replace the initials `<div>` with:
```heex
<%= if @user.avatar_url && @user.avatar_url != "" do %>
  <img
    src={@user.avatar_url}
    alt={to_string(@user.username)}
    class="h-20 w-20 border border-line object-cover"
  />
<% else %>
  <div class="flex h-20 w-20 items-center justify-center bg-zune text-2xl font-extrabold text-black">
    {avatar_initials(@user)}
  </div>
<% end %>
```
(Keep `avatar_initials/1`.)

- [ ] **Step 4: Run the test**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/avatar_upload_test.exs"
```
Expected: 1 test passes. If `render_submit` doesn't carry the consumed upload (consume happens in the handler), confirm the `save` event consumes `@uploads.avatar`; the stub returns `stub-image-id` → `delivery_url` (no account hash in test) → placeholder URL containing `stub-image-id`, stored in `avatar_url`.

- [ ] **Step 5: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(images): avatar upload in settings + avatar render on profile"
```
Then `git rev-parse --short HEAD`.

---

## Task 5: Article cover upload in the editor (TDD)

**Files:**
- Modify: `lib/verscienta_web/live/article_editor_live.ex`
- Test: `test/verscienta_web/live/cover_upload_test.exs`

- [ ] **Step 0: Read the editor** to see its `mount/3`, the form/`save` (or `publish`/`validate`) handlers, the cover field, and how params are submitted:
```
docker compose run --rm -T app bash -lc "cat lib/verscienta_web/live/article_editor_live.ex"
```
Identify: the form id, the save/submit event name, how the article create/update form params are built, and where `cover_image_url` is set.

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/cover_upload_test.exs`:
```elixir
defmodule VerscientaWeb.CoverUploadTest do
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

  defp sign_in(conn, u), do: conn |> Plug.Test.init_test_session(%{}) |> Helpers.store_in_session(u)

  test "uploading a cover image stores its delivery URL on the article", %{conn: conn} do
    author = user("coverauthor")
    {:ok, view, _html} = conn |> sign_in(author) |> live(~p"/articles/new")

    cover =
      file_input(view, "#article-editor-form", :cover, [
        %{name: "cover.png", content: <<137, 80, 78, 71>>, type: "image/png"}
      ])

    render_upload(cover, "cover.png")

    # Fill the minimal required fields + submit (adapt field names/event to the real editor form).
    view
    |> form("#article-editor-form", %{"form" => %{"title" => "Covered", "category" => "nutrition"}})
    |> render_submit()

    art =
      Verscienta.Content.Article
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.title == "Covered"))

    assert art && art.cover_image_url =~ "stub-image-id"
  end
end
```
NOTE: this test MUST match the editor's real form id, submit event, and required fields (from Step 0). Adjust `#article-editor-form`, the param shape, and required fields (e.g. excerpt) so a save succeeds. Keep the assertion: after submit with a consumed cover upload, the article's `cover_image_url` contains `stub-image-id`.

- [ ] **Step 2: Add the cover upload**

In `lib/verscienta_web/live/article_editor_live.ex`:
- `import VerscientaWeb.MediaComponents` and add `allow_upload(:cover, accept: ~w(.jpg .jpeg .png .webp .gif), max_file_size: 15_000_000, max_entries: 1)` in `mount/3` (alongside existing assigns).
- In the save/submit handler, consume the cover upload and inject into the params before the form submit (mirror the avatar pattern):
```elixir
    {socket, params} =
      case Verscienta.Images.consume_upload(socket, :cover, :cover) do
        {:ok, url} -> {socket, Map.put(params, "cover_image_url", url)}
        :none -> {socket, params}
        {:error, _} -> {put_flash(socket, :error, "Cover upload failed"), params}
      end
```
  (Use the editor's actual params variable + form-submit call.)
- In the render, replace the `<.text_field field={f[:cover_image_url]} label="cover image url" />` with:
```heex
<.image_upload_field upload={@uploads.cover} label="cover image" current_url={f[:cover_image_url].value} />
```
  (Keep it inside the editor form so the upload ref binds to the form id.)

- [ ] **Step 3: Run the test**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/cover_upload_test.exs"
```
Expected: passes (after matching the editor's real form/fields).

- [ ] **Step 4: Gate + commit**

```powershell
docker compose run --rm -T app bash -lc "mix format && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
git add -A
git commit -m "feat(images): article cover image upload in the editor"
```
Then `git rev-parse --short HEAD`.

---

## Task 6: Inline image-block upload + todo + full verification (TDD)

**Files:**
- Modify: `lib/verscienta_web/live/article_editor_live.ex`
- Modify: `docs/todo.md`
- Test: `test/verscienta_web/live/block_image_upload_test.exs`

- [ ] **Step 0: Re-read the editor's block handling** (from Task 5 Step 0 you have the structure). Identify: how blocks are stored in assigns (`@blocks`), how an `image` block is added (`add_block` with `type: "image"`), how a block's fields are inline-edited (the event that updates a block's `url`/`alt`/`caption` by index), and how `assign_blocks/2` persists.

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/block_image_upload_test.exs`:
```elixir
defmodule VerscientaWeb.BlockImageUploadTest do
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

  defp sign_in(conn, u), do: conn |> Plug.Test.init_test_session(%{}) |> Helpers.store_in_session(u)

  test "uploading into an image block sets that block's url", %{conn: conn} do
    author = user("blockauthor")
    {:ok, view, _html} = conn |> sign_in(author) |> live(~p"/articles/new")

    # add an image block
    render_click(element(view, ~s([phx-click="add_block"][phx-value-type="image"])))

    # select the file for the block image upload, then trigger the upload-complete event
    img =
      file_input(view, "#block-image-form", :block_image, [
        %{name: "inline.png", content: <<137, 80, 78, 71>>, type: "image/png"}
      ])

    render_upload(img, "inline.png")

    # the editor consumes on a "upload_block_image" event with the block index
    render_click(element(view, ~s([phx-click="upload_block_image"][phx-value-index="0"])))

    html = render(view)
    assert html =~ "stub-image-id"
  end
end
```
NOTE: adapt the selectors/events (`add_block`, the block-image form id, `upload_block_image`, `phx-value-index`) to what you implement in Step 2. The contract: after adding an image block, selecting a file, and triggering the block-image upload, the block's `url` is set to the stub delivery URL (visible in the rendered editor, e.g. as the block's url field value / preview).

- [ ] **Step 2: Add the block-image upload**

In `lib/verscienta_web/live/article_editor_live.ex`:
- Add `allow_upload(:block_image, accept: ~w(.jpg .jpeg .png .webp .gif), max_file_size: 15_000_000, max_entries: 1)` in `mount/3`.
- Add a handler that consumes the block-image upload and writes the URL into the targeted block's `url` (preserving `alt`/`caption`):
```elixir
  @impl true
  def handle_event("upload_block_image", %{"index" => index}, socket) do
    idx = String.to_integer(index)

    case Verscienta.Images.consume_upload(socket, :block_image, :public) do
      {:ok, url} ->
        blocks =
          List.update_at(socket.assigns.blocks, idx, fn block ->
            put_in(block, ["data", "url"], url)
          end)

        {:noreply, assign_blocks(socket, blocks)}

      :none ->
        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Image upload failed")}
    end
  end
```
  NOTE: match the actual block data shape from Step 0 — blocks may be `%{"type" => "image", "data" => %{"url" => ...}}` (adjust the `put_in` path) and `assign_blocks/2` is the existing persist helper. If blocks are keyed differently (e.g. atoms), adapt.
- IMPORTANT — one upload config = ONE file input in the DOM. Do NOT render the `live_file_input` inside the per-block loop (that would duplicate the input id for the shared `:block_image` ref). Instead render the shared picker form ONCE (outside the block loop), and give each image block its own "upload image" button carrying its index. The author selects a file in the shared picker, then clicks the target block's button to consume it into that block.

  Render the shared picker ONCE (e.g. just above or below the blocks list), wrapped in a form with a stable id so `file_input(view, "#block-image-form", :block_image, ...)` targets it:
```heex
<form id="block-image-form" phx-change="validate" phx-submit="noop" class="mb-4">
  <span class="block text-[11px] uppercase tracking-widest text-ink-3">block image picker</span>
  <.live_file_input upload={@uploads.block_image} class="block text-xs text-ink-3" />
</form>
```
  Then, in the per-block loop, for `image` blocks only, add an upload button carrying the block index (keep the existing manual `url`/`alt`/`caption` fields — upload just fills `url`):
```heex
<button
  :if={block["type"] == "image"}
  type="button"
  phx-click="upload_block_image"
  phx-value-index={index}
  class="mt-1 border border-zune px-2 py-1 text-[10px] uppercase tracking-wider text-zune hover:bg-zune hover:text-black"
>
  upload selected image here
</button>
```
  NOTE: use the block's `index` as it appears in the editor's block loop (the editor likely uses `Enum.with_index`). Add a no-op handler `def handle_event("noop", _params, socket), do: {:noreply, socket}` if you use `phx-submit="noop"` on the picker form (or reuse the editor's existing `validate` event for `phx-change`). The single `:block_image` config + the index on each block's button is what routes the consumed file to the right block.

- [ ] **Step 3: Run the test**

```powershell
docker compose run --rm -T app bash -lc "MIX_ENV=test mix test test/verscienta_web/live/block_image_upload_test.exs"
```
Expected: passes (after matching the editor's real block structure/events).

- [ ] **Step 4: Tick the todo items**

In `docs/todo.md`, under "### Media & Images", read the exact lines, then flip `[ ]`→`[x]` with notes:
```markdown
- [x] Cloudflare Images integration (signed upload URLs, Transformations). *(server-proxied uploads; delivery via variants)*
- [x] Direct-to-Cloudflare upload from LiveView (`live_file_input` / external uploads). *(server-proxied via live_file_input; external/direct deferred)*
- [x] Avatar + cover image uploads.
- [x] Inline images/video embeds in the editor. *(inline images; video deferred)*
- [ ] (Optional) Cloudflare R2 for non-image file storage. *(deferred — no consumer yet)*
```

- [ ] **Step 5: Full clean-deps gate**

```powershell
docker compose up -d db
docker compose run --rm -T app bash -lc "mix deps.get && mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors && MIX_ENV=test mix test"
```
Expected: format clean, credo 0 issues, no warnings, ALL tests pass. Capture the exact `N tests, 0 failures` line.

- [ ] **Step 6: Commit**

```powershell
git add -A
git commit -m "feat(images): inline image-block upload + todo updates"
```
Then `git rev-parse --short HEAD`.

---

## Definition of Done (verify all)

- [ ] `Verscienta.Images.Client` behaviour + `Req`/`Local`/`Stub` impls; `images_client` wired per env; prod secrets in runtime.exs.
- [ ] `Verscienta.Images` context: `upload_image/3`, `delivery_url/2` (Cloudflare URL with hash, placeholder without), `consume_upload/3`.
- [ ] Avatar upload in `/settings`; profile renders uploaded avatar with initials fallback.
- [ ] Cover upload in the article editor; stores delivery URL in `cover_image_url`.
- [ ] Inline image-block upload sets the block's `url` (alt/caption preserved).
- [ ] Uploads validated (type/size); failures flash + keep prior value; dev works offline (`Local`); tests use `Stub` (no network).
- [ ] `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix test` all pass. No migrations.
- [ ] `docs/todo.md` updated; R2 deferred; work committed on `media-images`.
