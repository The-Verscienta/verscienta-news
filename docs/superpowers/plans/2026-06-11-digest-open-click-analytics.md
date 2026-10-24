# Digest Open/Click Analytics Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Track digest email opens (1×1 pixel) and link clicks (link-wrapping redirect) as PostHog events, behind an off-by-default `:digest_tracking` flag.

**Architecture:** A new flag gates everything. `Digests` mints/verifies signed tracking tokens (recipient + send-time, plus the internal destination for clicks). `Digests.Email.build/4` wraps content links through a click-redirect and appends an open pixel when tracking is on. `DigestController` serves the pixel + the redirect, firing `Analytics` events. Destinations are signed into the token → no open-redirect.

**Tech Stack:** Elixir, Ash 3, Phoenix (controller + routes + verified routes), `Phoenix.Token`, Swoosh, FunWithFlags, `Verscienta.Analytics` (PostHog, stubbed in tests), ExUnit.

**Spec:** `docs/superpowers/specs/2026-06-11-digest-open-click-analytics-design.md`

**Conventions:**
- All `mix` runs inside Docker: `docker compose exec app mix ...`.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Branch: `phase-3-digest-tracking`. `git checkout phase-3-digest-tracking` first.
- **`docs/todo.md` has an unrelated uncommitted user edit. Leave it untouched; stage only your own files in every commit.**
- The analytics client is stubbed in `config/test.exs` (`:analytics_client`); the stub forwards each capture to the pid in `:analytics_test_pid` as `{:analytics, {:capture, event, distinct_id, props}}`.

---

### Task 1: `:digest_tracking` flag + tracking tokens + analytics helpers

**Files:**
- Modify: `lib/verscienta/flags.ex`, `lib/verscienta/flags/seeds.ex`
- Modify: `lib/verscienta/digests.ex`
- Modify: `lib/verscienta/analytics.ex`
- Test: `test/verscienta/digests/tracking_token_test.exs` (create), `test/verscienta/analytics_test.exs` (add)

- [ ] **Step 1: Write the failing tests**

Create `test/verscienta/digests/tracking_token_test.exs`:

```elixir
defmodule Verscienta.Digests.TrackingTokenTest do
  use ExUnit.Case, async: true

  alias Verscienta.Digests

  test "open token round-trips" do
    token = Digests.open_token("user-1", 1_700_000_000)
    assert {:ok, %{"u" => "user-1", "s" => 1_700_000_000}} = Digests.verify_tracking_token(token)
  end

  test "click token round-trips with the destination" do
    token = Digests.click_token("user-2", 1_700_000_000, "/articles/foo")

    assert {:ok, %{"u" => "user-2", "s" => 1_700_000_000, "d" => "/articles/foo"}} =
             Digests.verify_tracking_token(token)
  end

  test "a garbage token fails verification" do
    assert {:error, _} = Digests.verify_tracking_token("not-a-real-token")
  end
end
```

Add to `test/verscienta/analytics_test.exs` (match its existing setup — it sets `:analytics_test_pid` in a `setup`; if so, drop any per-test env line). Add inside the `track_*` describe/area:

```elixir
  test "track_digest_opened captures digest_opened with sent_at" do
    Verscienta.Analytics.track_digest_opened("u-1", 1_700_000_000)
    assert_receive {:analytics, {:capture, "digest_opened", "u-1", %{"sent_at" => 1_700_000_000}}}
  end

  test "track_digest_click captures digest_link_clicked with path + sent_at" do
    Verscienta.Analytics.track_digest_click("u-2", "/articles/foo", 1_700_000_000)

    assert_receive {:analytics,
                    {:capture, "digest_link_clicked", "u-2",
                     %{"path" => "/articles/foo", "sent_at" => 1_700_000_000}}}
  end
```
(If `analytics_test.exs` has no `setup` setting `:analytics_test_pid`, add at the top of each test:
`Application.put_env(:verscienta, :analytics_test_pid, self())` + `on_exit(fn -> Application.delete_env(:verscienta, :analytics_test_pid) end)`. Read the file and mirror the existing pattern.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `docker compose exec app mix test test/verscienta/digests/tracking_token_test.exs test/verscienta/analytics_test.exs`
Expected: FAIL — `open_token`/`click_token`/`verify_tracking_token`/`track_digest_*` undefined.

- [ ] **Step 3: Add the flag**

In `lib/verscienta/flags.ex`, add `digest_tracking` to the `@known_flags` `~w(...)a` list (e.g. on the `digest_emails auto_moderation` line, append `digest_tracking`).

In `lib/verscienta/flags/seeds.ex`: add `digest_tracking` to the `@phase3_off` `~w(...)a` list, and add a label to the labels map:
```elixir
    digest_tracking: "Digest open/click tracking",
```

- [ ] **Step 4: Add the tracking tokens (Digests)**

In `lib/verscienta/digests.ex`, add near the unsubscribe-token functions:
```elixir
  @tracking_salt "digest tracking"

  @doc "Signed token for an open pixel: recipient + send time (unix)."
  def open_token(user_id, sent_at_unix),
    do:
      Phoenix.Token.sign(VerscientaWeb.Endpoint, @tracking_salt, %{
        "u" => user_id,
        "s" => sent_at_unix
      })

  @doc "Signed token for a click redirect: recipient + send time + internal dest path."
  def click_token(user_id, sent_at_unix, dest_path),
    do:
      Phoenix.Token.sign(VerscientaWeb.Endpoint, @tracking_salt, %{
        "u" => user_id,
        "s" => sent_at_unix,
        "d" => dest_path
      })

  @doc "Verify a tracking token → {:ok, map} | {:error, reason}."
  def verify_tracking_token(token),
    do: Phoenix.Token.verify(VerscientaWeb.Endpoint, @tracking_salt, token, max_age: 2_592_000)
```
(`@token_max_age 2_592_000` already exists as a module attr — you may reuse it instead of the literal; match the file.)

- [ ] **Step 5: Add the analytics helpers**

In `lib/verscienta/analytics.ex`, add after the other `track_*` functions:
```elixir
  def track_digest_opened(user_id, sent_at) do
    capture("digest_opened", to_string(user_id), %{"sent_at" => sent_at})
  end

  def track_digest_click(user_id, path, sent_at) do
    capture("digest_link_clicked", to_string(user_id), %{"path" => path, "sent_at" => sent_at})
  end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `docker compose exec app mix test test/verscienta/digests/tracking_token_test.exs test/verscienta/analytics_test.exs test/verscienta/flags_test.exs`
Expected: PASS (the new tests + the flags suite still green with the new flag).

Run: `docker compose exec app mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add lib/verscienta/flags.ex lib/verscienta/flags/seeds.ex lib/verscienta/digests.ex lib/verscienta/analytics.ex test/verscienta/digests/tracking_token_test.exs test/verscienta/analytics_test.exs
git commit -m "feat(digests): :digest_tracking flag + tracking tokens + analytics events

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Email link-wrapping + open pixel (`build/4`)

**Files:**
- Modify: `lib/verscienta/digests/email.ex`
- Modify: `lib/verscienta/digests.ex` (`preview/1` passes `track: false`)
- Test: `test/verscienta/digests/email_test.exs` (add)

- [ ] **Step 1: Write the failing tests**

Add to `test/verscienta/digests/email_test.exs` (it exists from slice 1; reuse its `populated_activity/0` + `import Verscienta.Support.Factory`). The flag toggle makes these `async: false` — if the file is `async: true`, move these into a NEW file `test/verscienta/digests/email_tracking_test.exs` with `use Verscienta.DataCase, async: false`, `import Verscienta.Support.Factory, only: [user: 1]`, and a local `populated_activity/0`. Tests:

```elixir
  alias Verscienta.Digests.Email
  alias Verscienta.Flags

  defp activity_with_room do
    %{
      followers: %{count: 1, names: ["alice"]},
      replies: 0, mentions: 0, comments: 0, reactions: 0,
      rooms: [%{name: "Herbalists", slug: "herbalists", count: 2}]
    }
  end

  test "flag on: article + activity links are wrapped and an open pixel is present" do
    Flags.enable(:digest_tracking)
    on_exit(fn -> Flags.disable(:digest_tracking) end)

    art = %{slug: "foo", title: "Foo", excerpt: "x"}
    email = Email.build(user("trk_on"), [art], activity_with_room())
    body = email.html_body

    assert body =~ "/digests/click/"
    # the bare article path is gone — it's now encoded (base64) inside the click token
    refute body =~ "/articles/foo"
    assert body =~ "/digests/open/"
    assert body =~ ~s(width="1")
    # the unsubscribe link is NOT wrapped
    assert body =~ "/digests/unsubscribe/"
  end

  test "flag off: plain links, no pixel" do
    Flags.disable(:digest_tracking)
    art = %{slug: "bar", title: "Bar", excerpt: "x"}
    body = Email.build(user("trk_off"), [art], activity_with_room()).html_body

    assert body =~ "/articles/bar"
    refute body =~ "/digests/click/"
    refute body =~ "/digests/open/"
  end

  test "track: false (preview path) never wraps even with the flag on" do
    Flags.enable(:digest_tracking)
    on_exit(fn -> Flags.disable(:digest_tracking) end)

    art = %{slug: "baz", title: "Baz", excerpt: "x"}
    body = Email.build(user("trk_prev"), [art], activity_with_room(), track: false).html_body

    assert body =~ "/articles/baz"
    refute body =~ "/digests/click/"
    refute body =~ "/digests/open/"
  end
```
(`refute body =~ "/articles/foo"` works because the destination path is base64-encoded inside the signed click token, so the literal `/articles/foo` no longer appears in the body when tracking is on. The article title "Foo"/excerpt "x" don't collide with that string.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `docker compose exec app mix test <the email test file>`
Expected: FAIL — `Email.build/4` doesn't exist; no wrapping/pixel.

- [ ] **Step 3: Implement `build/4` + link wrapping + pixel**

In `lib/verscienta/digests/email.ex`:

(a) `build/3` → `build/4` with a tracking context:
```elixir
  def deliver(user, articles, activity),
    do: user |> build(articles, activity) |> Mailer.deliver()

  def build(user, articles, activity, opts \\ []) do
    track? = Keyword.get(opts, :track, true) and Verscienta.Flags.enabled?(:digest_tracking)
    ctx = %{user_id: user.id, track?: track?, sent_at: DateTime.to_unix(DateTime.utc_now())}

    new()
    |> from({"Verscienta News", "noreply@verscienta.news"})
    |> to(to_string(user.email))
    |> subject("Your Verscienta digest")
    |> html_body(html(user, articles, activity, ctx))
    |> text_body(text(user, articles, activity))
  end
```

(b) `html/3` → `html/4` (takes `ctx`); wrap article links via `track_href/2`, thread `ctx` into `activity_html`, and append the pixel:
```elixir
  defp html(user, articles, activity, ctx) do
    unsub = unsubscribe_url(user)

    items =
      Enum.map_join(articles, "", fn a ->
        ~s(<p><a href="#{track_href(ctx, ~p"/articles/#{a.slug}")}">#{esc(a.title)}</a><br/>#{esc(a.excerpt || "")}</p>)
      end)

    """
    <h1>Your Verscienta digest</h1>
    #{items}
    #{activity_html(activity, ctx)}
    #{open_pixel(ctx)}
    <p style="color:#999;font-size:12px">You're receiving this because you opted in to digests.
    <a href="#{unsub}">Unsubscribe</a>.</p>
    """
  end
```

(c) `activity_html/1` → `activity_html/2` (takes `ctx`); wrap the notification + room links:
```elixir
  defp activity_html(activity, ctx) do
    if Digests.activity_empty?(activity) do
      ""
    else
      notif_href = track_href(ctx, ~p"/notifications")

      notif_items =
        activity
        |> activity_lines()
        |> Enum.map_join("", fn line -> ~s(<li><a href="#{notif_href}">#{esc(line)}</a></li>) end)

      room_items =
        Enum.map_join(activity.rooms, "", fn r ->
          ~s(<li><a href="#{track_href(ctx, ~p"/groups/#{r.slug}/room")}">#{esc(r.name)} — #{r.count} new #{plural(r.count, "message", "messages")}</a></li>)
        end)

      """
      <h2>Since your last digest</h2>
      <ul>#{notif_items}#{room_items}</ul>
      """
    end
  end
```

(d) Add the helpers (`track_href/2` + `open_pixel/1`):
```elixir
  # A content link: wrapped through the click-redirect when tracking, else the plain URL.
  defp track_href(%{track?: true, user_id: uid, sent_at: s}, path),
    do: url(~p"/digests/click/#{Digests.click_token(uid, s, path)}")

  defp track_href(_ctx, path), do: url(path)

  defp open_pixel(%{track?: true, user_id: uid, sent_at: s}),
    do:
      ~s(<img src="#{url(~p"/digests/open/#{Digests.open_token(uid, s)}")}" width="1" height="1" alt="" style="display:none">)

  defp open_pixel(_ctx), do: ""
```
(`text/3` stays unchanged — plain links, no pixel. `~p"/articles/#{a.slug}"` yields a path string `/articles/<slug>`, which is what the click token signs; `url(~p"...")` yields the absolute URL.)

(d) In `lib/verscienta/digests.ex`, change `preview/1` to build with `track: false`:
```elixir
    email = Verscienta.Digests.Email.build(user, highlights, activity, track: false)
```
(only that one line in `preview/1`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `docker compose exec app mix test <the email test file> test/verscienta/digests/deliver_test.exs`
Expected: PASS (new tracking tests + the slice-2 deliver/preview tests still green — note: with the flag off by default in tests, deliver-path emails are plain, unchanged).

Run: `docker compose exec app mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta/digests/email.ex lib/verscienta/digests.ex test/verscienta/digests/email_test.exs test/verscienta/digests/email_tracking_test.exs
git commit -m "feat(digests): wrap links + open pixel when :digest_tracking is on

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
(Adjust the staged test files to whichever you created/edited.)

---

### Task 3: Controller (open pixel + click redirect) + routes

**Files:**
- Modify: `lib/verscienta_web/controllers/digest_controller.ex`
- Modify: `lib/verscienta_web/router.ex`
- Test (create): `test/verscienta_web/controllers/digest_tracking_controller_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/controllers/digest_tracking_controller_test.exs`:

```elixir
defmodule VerscientaWeb.DigestTrackingControllerTest do
  use VerscientaWeb.ConnCase, async: false

  alias Verscienta.Digests

  setup do
    Application.put_env(:verscienta, :analytics_test_pid, self())
    on_exit(fn -> Application.delete_env(:verscienta, :analytics_test_pid) end)
    :ok
  end

  test "open pixel returns a gif and captures digest_opened", %{conn: conn} do
    token = Digests.open_token("u-open", 1_700_000_000)
    conn = get(conn, ~p"/digests/open/#{token}")

    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") |> Enum.any?(&String.starts_with?(&1, "image/gif"))
    assert_receive {:analytics, {:capture, "digest_opened", "u-open", %{"sent_at" => 1_700_000_000}}}
  end

  test "open pixel with a bad token still returns a gif, no capture", %{conn: conn} do
    conn = get(conn, ~p"/digests/open/garbage")
    assert response(conn, 200)
    refute_receive {:analytics, {:capture, "digest_opened", _, _}}
  end

  test "click redirects to the signed destination and captures digest_link_clicked", %{conn: conn} do
    token = Digests.click_token("u-click", 1_700_000_000, "/articles/foo")
    conn = get(conn, ~p"/digests/click/#{token}")

    assert redirected_to(conn) == "/articles/foo"
    assert_receive {:analytics,
                    {:capture, "digest_link_clicked", "u-click",
                     %{"path" => "/articles/foo", "sent_at" => 1_700_000_000}}}
  end

  test "click with a bad token redirects home with no capture", %{conn: conn} do
    conn = get(conn, ~p"/digests/click/garbage")
    assert redirected_to(conn) == "/"
    refute_receive {:analytics, {:capture, "digest_link_clicked", _, _}}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec app mix test test/verscienta_web/controllers/digest_tracking_controller_test.exs`
Expected: FAIL — routes/handlers don't exist.

- [ ] **Step 3: Add the routes**

In `lib/verscienta_web/router.ex`, in the public `:browser` scope (next to the existing `get "/digests/unsubscribe/:token", DigestController, :unsubscribe`), add:
```elixir
    get "/digests/open/:token", DigestController, :open
    get "/digests/click/:token", DigestController, :click
```

- [ ] **Step 4: Add the controller handlers**

In `lib/verscienta_web/controllers/digest_controller.ex`, add `alias Verscienta.Analytics` and the two handlers + the pixel:
```elixir
  # 1×1 transparent GIF
  @pixel Base.decode64!("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")

  def open(conn, %{"token" => token}) do
    case Digests.verify_tracking_token(token) do
      {:ok, %{"u" => uid, "s" => s}} -> Analytics.track_digest_opened(uid, s)
      _ -> :ok
    end

    conn
    |> put_resp_content_type("image/gif")
    |> put_resp_header("cache-control", "no-store, no-cache, must-revalidate, private")
    |> send_resp(200, @pixel)
  end

  def click(conn, %{"token" => token}) do
    with {:ok, %{"u" => uid, "s" => s, "d" => dest}} <- Digests.verify_tracking_token(token),
         true <- is_binary(dest) and String.starts_with?(dest, "/") do
      Analytics.track_digest_click(uid, dest, s)
      redirect(conn, to: dest)
    else
      _ -> redirect(conn, to: "/")
    end
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `docker compose exec app mix test test/verscienta_web/controllers/digest_tracking_controller_test.exs test/verscienta_web/controllers/digest_controller_test.exs`
Expected: PASS (new tracking tests + the existing unsubscribe test).

Run: `docker compose exec app mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta_web/controllers/digest_controller.ex lib/verscienta_web/router.ex test/verscienta_web/controllers/digest_tracking_controller_test.exs
git commit -m "feat(digests): open-pixel + click-redirect tracking endpoints

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Full verification + docs

**Files:**
- Modify: `docs/todo.md` (your hunk only — there is also an unrelated user edit in this file)

- [ ] **Step 1: Format + compile (warnings as errors)**

Run: `docker compose exec app mix format && docker compose exec app mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 2: Credo strict**

Run: `docker compose exec app mix credo --strict`
Expected: no issues.

- [ ] **Step 3: Run the digest + flag + analytics suites**

Run: `docker compose exec app mix test test/verscienta/digests/ test/verscienta/analytics_test.exs test/verscienta/flags_test.exs test/verscienta_web/controllers/`
Expected: PASS.

- [ ] **Step 4: Run the full suite**

Run: `docker compose exec app mix test`
Expected: PASS, 0 failures. (Transient seed-contamination → re-run; see project memory.)

- [ ] **Step 5: Update the todo item**

In `docs/todo.md`, the digest-refinements line (currently `[~]`) — strike the
last sub-item `open/click analytics` and flip the line to `[x]` (all four
sub-items done):
```
- [x] Digest refinements (deferred): ... ~~open/click analytics~~ *(done — `:digest_tracking` flag (off by default); when on, `Digests.Email` wraps content links through `/digests/click/<token>` and embeds a 1×1 open pixel `/digests/open/<token>` (HTML only; preview never tracks); `DigestController` fires `digest_opened`/`digest_link_clicked` PostHog events; destination is signed into the token (no open-redirect).)*
```
(Change the leading `[~]` to `[x]`.)

> **NOTE:** `docs/todo.md` also has an unrelated uncommitted user edit. The
> controller will handle this commit manually (stash the user edit, commit only the
> slice-4 hunk, restore) — do NOT bundle the user's edit into your commit.

- [ ] **Step 6: Commit** (handled by the controller — stash user edit, commit slice-4 hunk, restore)

```bash
git add docs/todo.md
git commit -m "docs(digests): mark open/click analytics done (slice 4) — digest refinements complete

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review Notes

**Spec coverage:**
- `:digest_tracking` flag (known + phase3-off + label) → Task 1.
- Signed open/click tokens (dest in the click token) + verify → Task 1.
- Analytics `digest_opened`/`digest_link_clicked` → Task 1.
- Email `build/4` link wrapping + open pixel (HTML only) + preview `track: false` → Task 2.
- Controller open (always GIF) + click (302 to signed dest, `/` on bad token) + routes → Task 3.
- Tests: tokens, analytics, email (flag on/off/preview), controller (open/click + bad-token) → Tasks 1–3.
- Verification + todo (flip to `[x]`) → Task 4.

**Out of scope (per spec):** text-body tracking; a local dashboard; bot-open filtering; per-link ids; per-user opt-out beyond the flag. No migration/resource/attribute/action. One new flag.
