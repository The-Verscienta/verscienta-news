# Digest Admin Send-Now + Preview Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give admins a `/admin/digests` tool to preview any user's rendered digest (built, never sent) and to send it now on demand (admin override — bypasses the `:digest_emails` flag, records `last_digest_at`, sends nothing when empty).

**Architecture:** Extract the worker's send logic into `Digests.deliver/1` (reused by the cron worker after its flag check and by admin send-now directly). Add `Digests.preview/1` (builds the Swoosh email, no send). A new admin-gated `AdminDigestLive` looks up a user, renders the preview in a sandboxed iframe, and triggers `deliver/1`.

**Tech Stack:** Elixir, Ash 3, Phoenix LiveView, Swoosh, Oban, ExUnit + `Verscienta.Support.Factory` + Swoosh `assert_email_sent`.

**Spec:** `docs/superpowers/specs/2026-06-11-digest-admin-send-preview-design.md`

**Conventions:**
- All `mix` runs inside Docker: `docker compose exec app mix ...`.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Branch: `phase-3-digest-admin`. `git checkout phase-3-digest-admin` first; STOP if the tree is dirty with unrelated changes.
- `Digests` has `require Ash.Query`, aliases `User`, `Recommendations`; calls `Verscienta.Digests.Email.*` (alias `Email`? — it currently references the email module fully or via alias; check and match). Use fully-qualified `Verscienta.Digests.Email` if no alias exists, to avoid alias-order churn.

---

### Task 1: `Digests.deliver/1` + `Digests.preview/1` + worker refactor

**Files:**
- Modify: `lib/verscienta/digests.ex`
- Modify: `lib/verscienta/digests/workers/send_digest_worker.ex`
- Test (create): `test/verscienta/digests/deliver_test.exs`
- Test (existing, must still pass): `test/verscienta/digests/send_digest_worker_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/digests/deliver_test.exs`:

```elixir
defmodule Verscienta.Digests.DeliverTest do
  # async: false — uses the global Swoosh mailbox.
  use Verscienta.DataCase, async: false

  import Swoosh.TestAssertions

  alias Verscienta.Accounts.User
  alias Verscienta.Digests
  alias Verscienta.Notifications.Notification

  setup :set_swoosh_global

  # Register a user, drain the confirmation email, optionally set digest_frequency.
  defp mk_user(name, freq \\ :off) do
    u =
      User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: name <> "@example.com",
        username: name,
        password: "password123",
        password_confirmation: "password123"
      })
      |> Ash.create!(authorize?: false)

    assert_email_sent()

    {:ok, u} =
      u
      |> Ash.Changeset.for_update(:set_digest_frequency, %{digest_frequency: freq}, authorize?: false)
      |> Ash.update()

    u
  end

  defp followed_notif(recipient, follower) do
    Notification
    |> Ash.Changeset.for_create(:create, %{
      recipient_id: recipient.id,
      actor_id: follower.id,
      type: :followed,
      subject_type: :user,
      subject_id: Ash.UUID.generate(),
      metadata: %{"actor_username" => to_string(follower.username)}
    })
    |> Ash.create!(authorize?: false)
  end

  test "deliver sends + records last_digest_at when there is activity, ignoring the flag" do
    # NB: :digest_emails is NOT enabled here — deliver/1 must not depend on it.
    me = mk_user("dl_me", :weekly)
    followed_notif(me, mk_user("dl_follower"))

    assert {:ok, :sent} = Digests.deliver(me)

    assert_email_sent(fn email ->
      body = email.html_body || email.text_body || ""
      assert body =~ "new follower"
    end)

    assert Ash.get!(User, me.id, authorize?: false).last_digest_at != nil
  end

  test "deliver skips an empty/off user — no email, last_digest_at unchanged" do
    me = mk_user("dl_off", :off)

    assert {:ok, :skipped} = Digests.deliver(me)
    assert_no_email_sent()
    assert Ash.get!(User, me.id, authorize?: false).last_digest_at == nil
  end

  test "preview builds the email without sending" do
    me = mk_user("pv_me", :weekly)
    followed_notif(me, mk_user("pv_follower"))

    p = Digests.preview(me)

    assert p.subject == "Your Verscienta digest"
    assert p.html =~ "new follower"
    refute p.empty?
    assert_no_email_sent()
  end

  test "preview marks an off user empty" do
    me = mk_user("pv_off", :off)
    p = Digests.preview(me)
    assert p.empty?
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec app mix test test/verscienta/digests/deliver_test.exs`
Expected: FAIL — `Digests.deliver/1` / `Digests.preview/1` undefined.

- [ ] **Step 3: Add `deliver/1` + `preview/1`**

In `lib/verscienta/digests.ex`, add (after `activity_empty?/1`; use fully-qualified `Verscienta.Digests.Email` unless an `Email` alias already exists in the file — check and match):

```elixir
  @doc """
  Build and send `user`'s digest. Returns `{:ok, :sent}` (an email was delivered +
  `last_digest_at` recorded), `{:ok, :skipped}` (no highlights and no activity —
  includes `:off`), or `{:error, term}` (delivery failed). Does NOT check the
  `:digest_emails` flag — the cron worker gates on it; admin send-now bypasses it.
  """
  def deliver(%User{} = user) do
    highlights = highlights(user)
    activity = activity(user)

    if highlights == [] and activity_empty?(activity) do
      {:ok, :skipped}
    else
      case Verscienta.Digests.Email.deliver(user, highlights, activity) do
        {:ok, _} ->
          user
          |> Ash.Changeset.for_update(:record_digest_sent, %{}, authorize?: false)
          |> Ash.update!()

          {:ok, :sent}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Build `user`'s digest for preview (no send): `%{subject, html, text, empty?}`."
  def preview(%User{} = user) do
    highlights = highlights(user)
    activity = activity(user)
    email = Verscienta.Digests.Email.build(user, highlights, activity)

    %{
      subject: email.subject,
      html: email.html_body,
      text: email.text_body,
      empty?: highlights == [] and activity_empty?(activity)
    }
  end
```

- [ ] **Step 4: Refactor `SendDigestWorker` to use `deliver/1`**

Replace `send_digest/1`, `deliver_for/1`, and `send_and_record/3` in
`lib/verscienta/digests/workers/send_digest_worker.ex` with:

```elixir
  defp send_digest(id) do
    case Ash.get(User, id, authorize?: false) do
      {:ok, user} ->
        case Digests.deliver(user) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, _} ->
        :ok
    end
  end
```

Remove the now-unused `alias Verscienta.Digests.Email` if nothing else in the
worker references `Email` (it won't). Keep `perform/1` (the `:digest_emails` flag
guard) and the `alias Verscienta.Accounts.User` / `alias Verscienta.Digests`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `docker compose exec app mix test test/verscienta/digests/deliver_test.exs test/verscienta/digests/send_digest_worker_test.exs`
Expected: PASS — the new deliver/preview tests AND the existing worker regression tests (flag off → no send; flag on + non-empty → sent + recorded; `:off`/empty → no email; missing user → `:ok`).

Run: `docker compose exec app mix compile --warnings-as-errors`
Expected: clean (watch for an unused-`Email`-alias warning in the worker — remove it).

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta/digests.ex lib/verscienta/digests/workers/send_digest_worker.ex test/verscienta/digests/deliver_test.exs
git commit -m "feat(digests): Digests.deliver/1 + preview/1 (extract send path)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `AdminDigestLive` + route

**Files:**
- Create: `lib/verscienta_web/live/admin_digest_live.ex`
- Modify: `lib/verscienta_web/router.ex`
- Test (create): `test/verscienta_web/live/admin_digest_live_test.exs`

- [ ] **Step 1: Write the failing test**

First READ `test/verscienta_web/live/admin_flags_live_test.exs` to copy its
`register/1,2` + `sign_in/2` helpers and its non-admin-redirect assertion style.
Then create `test/verscienta_web/live/admin_digest_live_test.exs` mirroring those
helpers:

```elixir
defmodule VerscientaWeb.AdminDigestLiveTest do
  # async: false — uses the global Swoosh mailbox.
  use VerscientaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias AshAuthentication.Plug.Helpers
  alias Verscienta.Accounts.User
  alias Verscienta.Notifications.Notification

  setup :set_swoosh_global

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

    assert_email_sent()

    if role == :user do
      u
    else
      u
      |> Ash.Changeset.for_update(:update_profile, %{}, actor: u)
      |> Ash.Changeset.force_change_attribute(:role, role)
      |> Ash.update!(authorize?: false)
    end
  end

  defp weekly(u) do
    {:ok, u} =
      u
      |> Ash.Changeset.for_update(:set_digest_frequency, %{digest_frequency: :weekly}, authorize?: false)
      |> Ash.update()

    u
  end

  defp sign_in(conn, user),
    do: conn |> Plug.Test.init_test_session(%{}) |> Helpers.store_in_session(user)

  defp followed_notif(recipient, follower) do
    Notification
    |> Ash.Changeset.for_create(:create, %{
      recipient_id: recipient.id,
      actor_id: follower.id,
      type: :followed,
      subject_type: :user,
      subject_id: Ash.UUID.generate(),
      metadata: %{"actor_username" => to_string(follower.username)}
    })
    |> Ash.create!(authorize?: false)
  end

  test "a non-admin is redirected from the dead render", %{conn: conn} do
    conn = sign_in(conn, register("adm_nonadmin")) |> get(~p"/admin/digests")
    assert redirected_to(conn)
  end

  test "an admin can look up a user and see the preview", %{conn: conn} do
    admin = register("adm_admin", :admin)
    target = weekly(register("adm_target"))
    followed_notif(target, register("adm_follower"))

    {:ok, lv, _html} = live(sign_in(conn, admin), ~p"/admin/digests")

    html = lv |> form("#digest-lookup", %{"q" => "adm_target"}) |> render_submit()

    # the preview iframe srcdoc carries the digest html (HTML-escaped in the attr)
    assert html =~ "adm_target@example.com"
    assert has_element?(lv, "button", "send now")
  end

  test "an admin can look up by email", %{conn: conn} do
    admin = register("adm_admin2", :admin)
    _target = weekly(register("adm_target2"))

    {:ok, lv, _html} = live(sign_in(conn, admin), ~p"/admin/digests")
    html = lv |> form("#digest-lookup", %{"q" => "adm_target2@example.com"}) |> render_submit()

    assert html =~ "adm_target2@example.com"
  end

  test "a missing lookup shows a friendly error", %{conn: conn} do
    admin = register("adm_admin3", :admin)
    {:ok, lv, _html} = live(sign_in(conn, admin), ~p"/admin/digests")

    html = lv |> form("#digest-lookup", %{"q" => "nobody_here"}) |> render_submit()
    assert html =~ "No user found"
  end

  test "send now delivers a populated digest and flashes", %{conn: conn} do
    admin = register("adm_admin4", :admin)
    target = weekly(register("adm_target4"))
    followed_notif(target, register("adm_follower4"))

    {:ok, lv, _html} = live(sign_in(conn, admin), ~p"/admin/digests")
    lv |> form("#digest-lookup", %{"q" => "adm_target4"}) |> render_submit()

    html = lv |> element("button", "send now") |> render_click()

    assert html =~ "Digest sent"
    assert_email_sent(fn email -> assert email.to == [{"", "adm_target4@example.com"}] or match?([{_, "adm_target4@example.com"}], email.to) end)
    assert Ash.get!(User, target.id, authorize?: false).last_digest_at != nil
  end

  test "send now on an empty digest flashes nothing-to-send and sends no email", %{conn: conn} do
    admin = register("adm_admin5", :admin)
    _target = register("adm_target5")  # :off → empty

    {:ok, lv, _html} = live(sign_in(conn, admin), ~p"/admin/digests")
    lv |> form("#digest-lookup", %{"q" => "adm_target5"}) |> render_submit()

    html = lv |> element("button", "send now") |> render_click()
    assert html =~ "Nothing to send"
    assert_no_email_sent()
  end
end
```

> If `update_profile` rejects forcing `:role`, mirror exactly how
> `admin_flags_live_test.exs` builds an admin (`register("name", :admin)`) — reuse
> its helper verbatim. If the email-`to` assertion shape differs, relax it to
> `assert_email_sent()` (an email was sent) — the populated path is the point.

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec app mix test test/verscienta_web/live/admin_digest_live_test.exs`
Expected: FAIL — the route + LiveView don't exist (mount/route error).

- [ ] **Step 3: Add the route**

In `lib/verscienta_web/router.ex`, inside the existing
`scope "/admin", VerscientaWeb do pipe_through [:browser, :admin]` block (the one
containing `live_session :admin_flags`), add a sibling live_session:

```elixir
    live_session :admin_digests,
      on_mount: [
        {VerscientaWeb.LiveUserAuth, :current_user},
        {VerscientaWeb.LiveUserAuth, :admin_required}
      ] do
      live "/digests", AdminDigestLive, :index
    end
```

- [ ] **Step 4: Create the LiveView**

Create `lib/verscienta_web/live/admin_digest_live.ex`:

```elixir
defmodule VerscientaWeb.AdminDigestLive do
  @moduledoc "Admin tool: preview + send-now a user's digest."
  use VerscientaWeb, :live_view

  require Ash.Query

  alias Verscienta.Accounts.User
  alias Verscienta.Digests
  alias VerscientaWeb.SEO

  on_mount {VerscientaWeb.LiveUserAuth, :current_user}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "digests", seo: SEO.build(noindex: true))
     |> assign(query: "", target: nil, preview: nil, lookup_error: nil)}
  end

  @impl true
  def handle_event("lookup", %{"q" => q}, socket) do
    q = String.trim(q)

    case find_user(q) do
      %User{} = user ->
        {:noreply,
         assign(socket, query: q, target: user, preview: Digests.preview(user), lookup_error: nil)}

      nil ->
        {:noreply,
         assign(socket, query: q, target: nil, preview: nil, lookup_error: ~s(No user found for "#{q}".))}
    end
  end

  def handle_event("send_now", _params, socket) do
    case socket.assigns.target do
      %User{} = user ->
        {flash_kind, msg} =
          case Digests.deliver(user) do
            {:ok, :sent} -> {:info, "Digest sent."}
            {:ok, :skipped} -> {:info, "Nothing to send (empty digest)."}
            {:error, _} -> {:error, "Could not send the digest."}
          end

        reloaded = Ash.get!(User, user.id, authorize?: false)

        {:noreply,
         socket
         |> put_flash(flash_kind, msg)
         |> assign(target: reloaded, preview: Digests.preview(reloaded))}

      _ ->
        {:noreply, socket}
    end
  end

  defp find_user(""), do: nil

  defp find_user(q) do
    User
    |> Ash.Query.filter(username == ^q or email == ^q)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-4xl px-6 pb-24 pt-28">
      <h1 class="mb-6 text-3xl font-extralight lowercase">digest preview &amp; send</h1>

      <form id="digest-lookup" phx-submit="lookup" class="mb-6 flex gap-3">
        <input
          type="text"
          name="q"
          value={@query}
          placeholder="username or email"
          class="flex-1 border border-line bg-canvas-2 px-4 py-3 text-ink"
        />
        <button type="submit" class="bg-zune px-6 py-3 text-xs font-bold uppercase tracking-wider text-black">
          look up
        </button>
      </form>

      <p :if={@lookup_error} class="mb-6 text-sm text-politics">{@lookup_error}</p>

      <div :if={@target} class="space-y-4">
        <div class="flex flex-wrap items-center gap-4 border border-line bg-canvas-2 p-4 text-sm text-ink-2">
          <span class="text-ink">{@target.email}</span>
          <span>frequency: {@target.digest_frequency}</span>
          <span>last sent: {@target.last_digest_at || "never"}</span>
          <button
            type="button"
            phx-click="send_now"
            data-confirm={"Send a real digest email to #{@target.email} now?"}
            class="ml-auto border border-zune px-4 py-2 text-[11px] font-bold uppercase tracking-wider text-zune hover:bg-zune hover:text-black"
          >
            send now
          </button>
        </div>

        <p :if={@preview.empty?} class="text-sm text-ink-3">
          Empty digest — nothing would be sent.
        </p>

        <div>
          <p class="mb-1 text-[11px] uppercase tracking-widest text-ink-3">subject</p>
          <p class="text-ink">{@preview.subject}</p>
        </div>

        <div>
          <p class="mb-1 text-[11px] uppercase tracking-widest text-ink-3">preview</p>
          <iframe
            srcdoc={@preview.html}
            sandbox=""
            title="digest preview"
            class="h-[600px] w-full border border-line bg-white"
          >
          </iframe>
        </div>

        <details>
          <summary class="cursor-pointer text-[11px] uppercase tracking-widest text-ink-3">text version</summary>
          <pre class="mt-2 whitespace-pre-wrap border border-line bg-canvas-2 p-4 text-sm text-ink-2">{@preview.text}</pre>
        </details>
      </div>
    </div>
    """
  end
end
```

> The router `live_session :admin_digests` provides `:current_user` + `:admin_required`
> (the latter raises `LiveUserAuth.NotFound` for non-admins), so the module needs no
> in-mount role check — matching `AdminFlagsLive`. The `iframe srcdoc={@preview.html}`
> attribute is HTML-escaped by HEEx and parsed as a document by the browser — correct
> and XSS-safe; `sandbox=""` disables scripts.
>
> If `Ash.Query.filter(username == ^q or email == ^q)` errors because `email` is a
> CiString (type-mismatch on the literal), fall back to two reads in `find_user/1`:
> try `filter(username == ^q)` first, then `filter(email == ^q)` — return the first
> hit. Verify the `email-by` lookup test passes either way.

- [ ] **Step 5: Run tests to verify they pass**

Run: `docker compose exec app mix test test/verscienta_web/live/admin_digest_live_test.exs`
Expected: PASS. Also `docker compose exec app mix compile --warnings-as-errors` (clean).

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta_web/live/admin_digest_live.ex lib/verscienta_web/router.ex test/verscienta_web/live/admin_digest_live_test.exs
git commit -m "feat(digests): AdminDigestLive — preview + send-now at /admin/digests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Full verification + docs

**Files:**
- Modify: `docs/todo.md`

- [ ] **Step 1: Format + compile (warnings as errors)**

Run: `docker compose exec app mix format && docker compose exec app mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 2: Credo strict**

Run: `docker compose exec app mix credo --strict`
Expected: no issues.

- [ ] **Step 3: Run the digest + admin suites**

Run: `docker compose exec app mix test test/verscienta/digests/ test/verscienta_web/live/admin_digest_live_test.exs`
Expected: PASS.

- [ ] **Step 4: Run the full suite**

Run: `docker compose exec app mix test`
Expected: PASS, 0 failures. (If a transient seed-contamination count failure appears, re-run; see the project memory on test DB seed contamination.)

- [ ] **Step 5: Update the todo item**

In `docs/todo.md`, the digest-refinements line (currently `[~]`) — strike the
now-done admin sub-item. Change:

```
- [~] Digest refinements (deferred): per-user-timezone / optimal send-time; ~~non-article digest content (new followers, comment replies, room activity)~~ *(done — …)*; admin "send now" + digest preview; open/click analytics.
```

so `admin "send now" + digest preview` becomes struck through with a note:

```
…; ~~admin "send now" + digest preview~~ *(done — /admin/digests AdminDigestLive: look up a user by username/email, preview the rendered digest in a sandboxed iframe, and "send now" via Digests.deliver/1 (admin override — bypasses the :digest_emails flag, records last_digest_at, no-ops on an empty digest))*; open/click analytics.
```

(Keep the line `[~]` — open/click analytics + timezone remain.)

- [ ] **Step 6: Commit**

```bash
git add docs/todo.md
git commit -m "docs(digests): mark admin send-now + preview done (slice 2)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review Notes

**Spec coverage:**
- `Digests.deliver/1` (sent/skipped/error; records on send; no flag dependency) + worker refactor → Task 1.
- `Digests.preview/1` (build, never send; empty?) → Task 1.
- `AdminDigestLive` (lookup by username/email, sandboxed-iframe preview, send-now with confirm + flash, admin-gated route) → Task 2.
- Tests: deliver/preview, worker regression, admin LiveView (non-admin 404, lookup, send-now populated + empty) → Tasks 1–2.
- Verification + todo update → Task 3.

**Out of scope (per spec), intentionally absent:** scheduling future sends; bulk send; content editing; open/click instrumentation; per-user-timezone send-time. No migration, resource, attribute, action, or flag.
