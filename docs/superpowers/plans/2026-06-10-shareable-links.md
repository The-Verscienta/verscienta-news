# Shareable Links Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the article reader a Share control (copy / native / X / Facebook / email) whose links carry the sharer's referral code, turning shares into a referral growth loop — reusing the existing `CaptureReferral` plug + referral cookie.

**Architecture:** Promote lazy referral-code generation to `Referrals.ensure_code/1`. Add `Analytics.track_share/3`. In `ArticleReaderLive`, a Share button opens a popover (built from a `share_url/2` helper that appends `?ref=<code>` for signed-in users when `:referrals` is on); a `Share` JS hook handles clipboard + Web Share API and pushes `track_share` events. No new resource, route, plug, controller, migration, or flag.

**Tech Stack:** Elixir, Ash 3, Phoenix LiveView (JS hooks, `pushEvent`), `Verscienta.Gamification.Referrals`, `Verscienta.Analytics` (PostHog, with a test stub), FunWithFlags, ExUnit + `Phoenix.LiveViewTest`, `Verscienta.Support.Factory`.

**Spec:** `docs/superpowers/specs/2026-06-10-shareable-links-design.md`

**Conventions:**
- All `mix` runs inside Docker: `docker compose exec app mix ...`.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Branch: `phase-3-shareable-links`. `git checkout phase-3-shareable-links` first; STOP if the tree is dirty with unrelated changes.
- `ArticleReaderLive` calls cross-context functions fully-qualified (e.g. `Verscienta.Social.reposted?`) — follow that; do NOT add new aliases (avoids credo alias-ordering churn).
- `analytics_id` and `current_user` are existing socket assigns in `ArticleReaderLive` (mount already calls `Analytics.distinct_id(socket.assigns[:current_user], socket.assigns[:analytics_id])`).

---

### Task 1: `Referrals.ensure_code/1` (promote + reuse)

**Files:**
- Modify: `lib/verscienta/gamification/referrals.ex`
- Modify: `lib/verscienta_web/live/settings_referrals_live.ex`
- Test: `test/verscienta/gamification/referrals_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/verscienta/gamification/referrals_test.exs` (create the file if it doesn't exist, with the header below; otherwise add the test inside the existing module and match its imports):

```elixir
defmodule Verscienta.Gamification.ReferralsTest do
  use Verscienta.DataCase, async: true

  import Verscienta.Support.Factory, only: [user: 1]

  alias Verscienta.Gamification.Referrals

  test "ensure_code generates an 8-char code when missing and is idempotent" do
    u = user("ec_user")
    assert is_nil(u.referral_code)

    coded = Referrals.ensure_code(u)
    assert is_binary(coded.referral_code)
    assert byte_size(coded.referral_code) == 8

    again = Referrals.ensure_code(coded)
    assert again.referral_code == coded.referral_code
  end
end
```

> If the file already exists, just add the single `test` (and the `alias`/`import` if missing) — do not duplicate the module.

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec app mix test test/verscienta/gamification/referrals_test.exs`
Expected: FAIL — `Referrals.ensure_code/1` is undefined.

- [ ] **Step 3: Add `ensure_code/1`**

In `lib/verscienta/gamification/referrals.ex`, add (near `generate_code/0`):

```elixir
  @doc """
  Return `user` guaranteed to have a `referral_code`, generating + persisting one
  (system action `:generate_referral_code`) when it is nil/blank.
  """
  def ensure_code(%Verscienta.Accounts.User{referral_code: code} = user)
      when is_binary(code) and code != "",
      do: user

  def ensure_code(%Verscienta.Accounts.User{} = user) do
    user
    |> Ash.Changeset.for_update(:generate_referral_code, %{})
    |> Ash.update!(authorize?: false)
  end
```

(If the module lacks `require Ash.Query`/`Ash` usage it still compiles — `Ash.Changeset`/`Ash.update!` need no `require`. Confirm the module already references `Verscienta.Accounts.User`; if not, the fully-qualified struct name in the head needs no alias.)

- [ ] **Step 4: Refactor `SettingsReferralsLive` to delegate**

In `lib/verscienta_web/live/settings_referrals_live.ex`, replace the private `ensure_code/1` (the two clauses at ~line 50-56) with a single delegating clause, and keep its one call site (`mount`) working:

```elixir
  defp ensure_code(user), do: Verscienta.Gamification.Referrals.ensure_code(user)
```

(Leave `mount` calling `ensure_code(socket.assigns.current_user)` unchanged. The behavior is identical.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `docker compose exec app mix test test/verscienta/gamification/referrals_test.exs test/verscienta_web/live/settings_referrals_live_test.exs`
Expected: PASS (the new test + the existing settings test, if present — no regression). If there is no settings test file, omit it from the command.

Run: `docker compose exec app mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta/gamification/referrals.ex lib/verscienta_web/live/settings_referrals_live.ex test/verscienta/gamification/referrals_test.exs
git commit -m "feat(growth): Referrals.ensure_code/1 (promote lazy code generation)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `Analytics.track_share/3`

**Files:**
- Modify: `lib/verscienta/analytics.ex`
- Test: `test/verscienta/analytics_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/verscienta/analytics_test.exs` (match the file's existing setup — it configures the analytics client stub + `:analytics_test_pid`; read the file first and mirror its setup. If the file's pattern differs, adapt). Add:

```elixir
  test "track_share captures article_shared with method + article_id" do
    Application.put_env(:verscienta, :analytics_test_pid, self())
    on_exit(fn -> Application.delete_env(:verscienta, :analytics_test_pid) end)

    article = %{id: "11111111-1111-1111-1111-111111111111", category: :nutrition}
    Verscienta.Analytics.track_share(article, "distinct-123", "copy")

    assert_receive {:analytics, {:capture, "article_shared", "distinct-123", props}}
    assert props["method"] == "copy"
    assert props["article_id"] == "11111111-1111-1111-1111-111111111111"
    assert props["category"] == "nutrition"
  end
```

> The analytics client is stubbed globally in `config/test.exs` (the `Stub` forwards captures to `:analytics_test_pid`). If `analytics_test.exs` already has a `setup` that sets `:analytics_test_pid`, drop the two env lines and rely on it.

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec app mix test test/verscienta/analytics_test.exs`
Expected: FAIL — `Analytics.track_share/3` is undefined.

- [ ] **Step 3: Add `track_share/3`**

In `lib/verscienta/analytics.ex`, add after `track_article_view/2`:

```elixir
  def track_share(article, distinct_id, method) do
    capture("article_shared", distinct_id, %{
      "article_id" => to_string(article.id),
      "category" => to_string(article.category),
      "method" => to_string(method)
    })
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose exec app mix test test/verscienta/analytics_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta/analytics.ex test/verscienta/analytics_test.exs
git commit -m "feat(growth): Analytics.track_share/3 (article_shared event)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Share control in `ArticleReaderLive` + `Share` JS hook

**Files:**
- Modify: `lib/verscienta_web/live/article_reader_live.ex`
- Modify: `assets/js/app.js`
- Test (create): `test/verscienta_web/live/article_reader_share_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/article_reader_share_test.exs`:

```elixir
defmodule VerscientaWeb.ArticleReaderShareTest do
  # async: false — toggles the global :referrals flag + uses the analytics stub pid.
  use VerscientaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Verscienta.Support.Factory, only: [user: 1, article: 1, sign_in: 2]

  alias Verscienta.Accounts.User
  alias Verscienta.Flags

  setup do
    Application.put_env(:verscienta, :analytics_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:verscienta, :analytics_test_pid)
      Flags.disable(:referrals)
    end)

    :ok
  end

  test "the share button is present for an anonymous viewer", %{conn: conn} do
    art = article(user("sh_author"))
    {:ok, _lv, html} = live(conn, ~p"/articles/#{art.slug}")
    assert html =~ "share"
  end

  test "opening share for a signed-in user (referrals on) tags the link with their ref code",
       %{conn: conn} do
    Flags.enable(:referrals)
    art = article(user("sh_author2"))
    sharer = user("sh_sharer")

    {:ok, lv, _html} = live(sign_in(conn, sharer), ~p"/articles/#{art.slug}")
    html = lv |> element("button", "share") |> render_click()

    coded = Ash.get!(User, sharer.id, authorize?: false)
    assert is_binary(coded.referral_code)
    assert html =~ "?ref=#{coded.referral_code}"
  end

  test "opening share for an anonymous viewer produces an unreferred link", %{conn: conn} do
    art = article(user("sh_author3"))
    {:ok, lv, _html} = live(conn, ~p"/articles/#{art.slug}")
    html = lv |> element("button", "share") |> render_click()

    refute html =~ "?ref="
    assert html =~ "data-share-url"
  end

  test "track_share records an article_shared capture for a known method", %{conn: conn} do
    art = article(user("sh_author4"))
    {:ok, lv, _html} = live(conn, ~p"/articles/#{art.slug}")

    render_hook(lv, "track_share", %{"method" => "copy"})

    assert_receive {:analytics, {:capture, "article_shared", _id, props}}
    assert props["method"] == "copy"
    assert props["article_id"] == to_string(art.id)
  end

  test "track_share ignores an unknown method", %{conn: conn} do
    art = article(user("sh_author5"))
    {:ok, lv, _html} = live(conn, ~p"/articles/#{art.slug}")

    render_hook(lv, "track_share", %{"method" => "bogus"})

    refute_receive {:analytics, {:capture, "article_shared", _, _}}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec app mix test test/verscienta_web/live/article_reader_share_test.exs`
Expected: FAIL — no share button / `open_share` / `track_share` handlers yet.

- [ ] **Step 3: Add share assigns + handlers + helper**

In `lib/verscienta_web/live/article_reader_live.ex`:

(a) In `mount/3`, add `share_open: false, share_url: nil` to the success-branch `assign(...)` keyword list (anywhere among the existing keys, e.g. after `reply_to: nil,`):

```elixir
           reply_to: nil,
           share_open: false,
           share_url: nil,
```

(b) Add the three handlers (place them with the other `handle_event` clauses, e.g. right after the `toggle_bookmark` handler):

```elixir
  def handle_event("open_share", _params, socket) do
    {url, user} = share_url(socket.assigns.article, socket.assigns[:current_user])
    {:noreply, assign(socket, share_open: true, share_url: url, current_user: user)}
  end

  def handle_event("close_share", _params, socket) do
    {:noreply, assign(socket, :share_open, false)}
  end

  def handle_event("track_share", %{"method" => method}, socket) do
    if method in ~w(copy native x facebook email) do
      Verscienta.Analytics.track_share(
        socket.assigns.article,
        Verscienta.Analytics.distinct_id(socket.assigns[:current_user], socket.assigns[:analytics_id]),
        method
      )
    end

    {:noreply, socket}
  end
```

(c) Add the private helpers (place near the other private helpers, e.g. above `comment_ids/1` or near `mention_set/1`):

```elixir
  # Build the outbound share URL. Append ?ref=<code> only for a signed-in user when
  # the :referrals program is on (ensuring they have a code); else the plain URL.
  # Returns {url, user} so the caller can re-assign the possibly-code-bearing user.
  defp share_url(article, nil), do: {canonical_article_url(article), nil}

  defp share_url(article, %{} = user) do
    if Verscienta.Flags.enabled?(:referrals, for: user) do
      user = Verscienta.Gamification.Referrals.ensure_code(user)
      {canonical_article_url(article) <> "?ref=" <> user.referral_code, user}
    else
      {canonical_article_url(article), user}
    end
  end

  defp canonical_article_url(article), do: url(~p"/articles/#{article.slug}")
```

- [ ] **Step 4: Add the Share button + popover markup**

In `render/1`, in the action-row `<div class="mb-8 flex flex-wrap items-center gap-3">` (the one with reactions/repost/bookmark), add the Share button **after** the repost button and **before** the bookmark button (so bookmark keeps its `ml-auto` right alignment):

```elixir
          <button
            type="button"
            phx-click="open_share"
            class="inline-flex items-center gap-2 border border-line px-3 py-1 text-[11px] font-bold uppercase tracking-wider text-ink-3 transition-colors hover:text-ink"
          >
            ↗ share
          </button>
```

Then add the popover **after** that action-row `</div>` (still inside the `<section>`), as a modal overlay (mirrors the report-dialog pattern — overlay closes on outside click; inner panel stops propagation and carries the hook):

```elixir
        <div
          :if={@share_open}
          class="fixed inset-0 z-50 flex items-center justify-center bg-black/60"
          phx-click="close_share"
        >
          <div
            id="share-menu"
            phx-hook="Share"
            data-share-url={@share_url}
            data-share-title={@article.title}
            class="w-full max-w-sm border border-line bg-canvas-2 p-6"
            onclick="event.stopPropagation()"
          >
            <h3 class="mb-4 text-xs font-bold uppercase tracking-wider text-ink">
              Share this article
            </h3>
            <div class="flex flex-col gap-2 text-[11px] uppercase tracking-wider">
              <button
                type="button"
                data-share-action="copy"
                class="border border-line px-3 py-2 text-left text-ink-3 hover:text-ink"
              >
                copy link
              </button>
              <button
                type="button"
                data-share-action="native"
                class="border border-line px-3 py-2 text-left text-ink-3 hover:text-ink"
              >
                share…
              </button>
              <a
                href={"https://twitter.com/intent/tweet?url=#{URI.encode_www_form(@share_url)}&text=#{URI.encode_www_form(@article.title)}"}
                target="_blank"
                rel="noopener"
                data-share-method="x"
                class="border border-line px-3 py-2 text-ink-3 hover:text-ink"
              >
                X
              </a>
              <a
                href={"https://www.facebook.com/sharer/sharer.php?u=#{URI.encode_www_form(@share_url)}"}
                target="_blank"
                rel="noopener"
                data-share-method="facebook"
                class="border border-line px-3 py-2 text-ink-3 hover:text-ink"
              >
                Facebook
              </a>
              <a
                href={"mailto:?subject=#{URI.encode_www_form(@article.title)}&body=#{URI.encode_www_form(@share_url)}"}
                data-share-method="email"
                class="border border-line px-3 py-2 text-ink-3 hover:text-ink"
              >
                email
              </a>
            </div>
          </div>
        </div>
```

> Note: `@share_url` is `nil` until `open_share` runs, but the popover only renders
> when `@share_open` is true (set together with `share_url`), so `URI.encode_www_form`
> never sees nil.

- [ ] **Step 5: Add the `Share` JS hook**

In `assets/js/app.js`, add the hook to the `Hooks` object (after `Hooks.ReadingTimer`, before `const liveSocket`):

```javascript
Hooks.Share = {
  mounted() {
    const url = this.el.dataset.shareUrl
    const title = this.el.dataset.shareTitle || ""

    const nativeBtn = this.el.querySelector('[data-share-action="native"]')
    if (nativeBtn && !navigator.share) nativeBtn.style.display = "none"

    this.el.addEventListener("click", async (e) => {
      const action = e.target.closest("[data-share-action]")?.dataset.shareAction
      const method = e.target.closest("[data-share-method]")?.dataset.shareMethod

      if (action === "copy") {
        e.preventDefault()
        try {
          await navigator.clipboard.writeText(url)
          const btn = e.target.closest("[data-share-action='copy']")
          if (btn) {
            const original = btn.textContent
            btn.textContent = "copied"
            setTimeout(() => (btn.textContent = original), 1500)
          }
          this.pushEvent("track_share", {method: "copy"})
        } catch (_) {}
      } else if (action === "native" && navigator.share) {
        e.preventDefault()
        try {
          await navigator.share({title, url})
          this.pushEvent("track_share", {method: "native"})
        } catch (_) {}
      } else if (method) {
        this.pushEvent("track_share", {method})
      }
    })
  },
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `docker compose exec app mix test test/verscienta_web/live/article_reader_share_test.exs`
Expected: PASS (5 tests).

Run: `docker compose exec app mix test test/verscienta_web/live/article_reader_live_test.exs`
Expected: PASS (no regression in the existing reader tests).

Run: `docker compose exec app mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add lib/verscienta_web/live/article_reader_live.ex assets/js/app.js test/verscienta_web/live/article_reader_share_test.exs
git commit -m "feat(growth): referral-attributed share control on the article reader

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Full verification + docs

**Files:**
- Modify: `docs/todo.md`

- [ ] **Step 1: Format + compile (warnings as errors)**

Run: `docker compose exec app mix format && docker compose exec app mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 2: Credo strict**

Run: `docker compose exec app mix credo --strict`
Expected: no issues. (The LiveView edits use fully-qualified `Verscienta.*` calls to avoid alias-ordering churn.)

- [ ] **Step 3: Assets build (the JS hook compiles)**

Run: `docker compose exec app mix assets.build`
Expected: builds without error (esbuild parses `app.js`).

- [ ] **Step 4: Run the focused suites**

Run: `docker compose exec app mix test test/verscienta/gamification/referrals_test.exs test/verscienta/analytics_test.exs test/verscienta_web/live/article_reader_share_test.exs test/verscienta_web/live/article_reader_live_test.exs test/verscienta_web/live/settings_referrals_live_test.exs`
Expected: PASS (omit the settings file from the command if it does not exist).

- [ ] **Step 5: Run the full suite**

Run: `docker compose exec app mix test`
Expected: PASS, 0 failures. (If a transient seed-contamination count failure appears, re-run; see the project memory on test DB seed contamination.)

- [ ] **Step 6: Check off the todo item**

In `docs/todo.md`, update the Growth line (currently `[~]`):

```
- [~] Shareable links + social card images. *(social cards done — libvips OG card per article, generated on publish → Cloudflare; Growth slice 2. Shareable links pending.)*
```

to:

```
- [x] Shareable links + social card images. *(social cards done — libvips OG card per article on publish → Cloudflare; shareable links done — Growth slice 2: article-reader Share control (copy/native/X/Facebook/email) whose links carry the sharer's referral code via `?ref=` (reusing the CaptureReferral plug + cookie), `Referrals.ensure_code/1`, and an `article_shared` analytics event.)*
```

- [ ] **Step 7: Commit**

```bash
git add docs/todo.md
git commit -m "docs(growth): check off shareable links

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review Notes

**Spec coverage:**
- `Referrals.ensure_code/1` + settings refactor → Task 1.
- `Analytics.track_share/3` → Task 2.
- Share-URL helper (ref tag gated on `:referrals` + signed-in), Share button + popover, open/close/track handlers, `Share` JS hook → Task 3.
- Reuse of the existing `CaptureReferral` plug + cookie for attribution → no task needed (already wired); the share URL just carries `?ref=`.
- Tests: ensure_code, track_share, share-URL ref-tagging (signed-in vs anon), track_share analytics (known + unknown method) → Tasks 1–3.
- Verification (format, warnings-as-errors, credo, assets build, full suite) + todo check-off → Task 4.

**Out of scope (per spec), intentionally absent:** a `ShareableLink` resource / `/s/:id` short URLs / per-link click counts; feed-card share affordances; share counts, QR codes, LinkedIn/WhatsApp/Reddit; registration-time referral-code backfill. No new resource, route, plug, controller, migration, or feature flag.
