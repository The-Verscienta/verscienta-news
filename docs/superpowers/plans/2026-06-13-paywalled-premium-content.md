# Paywalled Premium Content Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let authors mark an article premium; non-entitled readers get a teaser + upgrade CTA instead of the body, gated server-side behind an off-by-default `:paywall` flag.

**Architecture:** A single `Verscienta.Content.body_visible?/2` helper expresses the access rule. `ArticleReaderLive` is the security boundary — for a gated read it strips `blocks` from the article assign, skips body rendering and the reading-time heartbeat, and renders an upgrade panel. Discovery surfaces stay on the existing `card_fields` teaser projection plus a "Premium" badge. SEO emits Google-compliant paywall JSON-LD for premium articles.

**Tech Stack:** Elixir, Phoenix LiveView, Ash 3 / AshPostgres, AshPhoenix.Form, FunWithFlags.

**Spec:** [docs/superpowers/specs/2026-06-13-paywalled-premium-content-design.md](../specs/2026-06-13-paywalled-premium-content-design.md)

**Conventions for this repo:**
- Run mix inside the dev container: `docker exec news-verscienta-app-1 mix <args>` (host mix fails on bcrypt nmake). If your worktree uses parameterized build paths, prefix with the env from the worktree mix recipe memory.
- Tests use `Verscienta.Support.Factory` (`user/1`, `user/2`, `article/2`) and toggle flags with `Verscienta.Flags.enable/1`.
- Commit after every green task.

---

### Task 1: Register the `:paywall` feature flag

**Files:**
- Modify: `lib/verscienta/flags.ex:8-17` (the `@known_flags` list)
- Modify: `lib/verscienta/flags/seeds.ex:7` (`@phase3_off`) and `:9-28` (`@labels`)
- Test: `test/verscienta/flags_paywall_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/verscienta/flags_paywall_test.exs
defmodule Verscienta.FlagsPaywallTest do
  use Verscienta.DataCase, async: false

  alias Verscienta.Flags

  test ":paywall is a known flag and defaults off" do
    assert :paywall in Flags.known_flags()
    refute Flags.enabled?(:paywall)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta/flags_paywall_test.exs`
Expected: FAIL — `Flags.enabled?(:paywall)` raises `ArgumentError, "Unknown feature flag: :paywall"` (it is not yet in `@known_flags`).

- [ ] **Step 3: Add the flag to the allowlist**

In `lib/verscienta/flags.ex`, add `paywall` to the `@known_flags` list (append to the last line so it reads):

```elixir
    expert_program writing_assistant
    auto_enforcement web_push
    paywall
  )a
```

- [ ] **Step 4: Add the flag to the off-by-default seeds + a label**

In `lib/verscienta/flags/seeds.ex`, append `paywall` to `@phase3_off`:

```elixir
  @phase3_off ~w(for_you_feed live_rooms voice_rooms digest_emails auto_moderation expert_program writing_assistant auto_enforcement digest_tracking web_push paywall)a
```

and add to the `@labels` map (after the `web_push:` entry):

```elixir
    web_push: "Web push notifications",
    paywall: "Premium content paywall"
```

- [ ] **Step 5: Run test to verify it passes**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta/flags_paywall_test.exs`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta/flags.ex lib/verscienta/flags/seeds.ex test/verscienta/flags_paywall_test.exs
git commit -m "feat(paywall): register off-by-default :paywall feature flag"
```

---

### Task 2: Add the `premium?` attribute to Article

**Files:**
- Modify: `lib/verscienta/content/article.ex` — attribute block (~line 384), `:create` accept (line 27), `:update` accept (line 50), `@card_fields` (line 450)
- Create: `priv/repo/migrations/<timestamp>_add_article_premium.exs` (generated)
- Test: `test/verscienta/content/article_premium_attr_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/verscienta/content/article_premium_attr_test.exs
defmodule Verscienta.Content.ArticlePremiumAttrTest do
  use Verscienta.DataCase, async: false

  import Verscienta.Support.Factory, only: [user: 1, article: 2]

  test "premium? defaults to false and is settable through create/update" do
    author = user("prem_author")

    free = article(author, %{})
    refute free.premium?

    premium = article(author, %{premium?: true})
    assert premium.premium?

    {:ok, toggled} =
      free
      |> Ash.Changeset.for_update(:update, %{premium?: true}, actor: author)
      |> Ash.update()

    assert toggled.premium?
  end

  test "premium? is in card_fields" do
    assert :premium? in Verscienta.Content.Article.card_fields()
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta/content/article_premium_attr_test.exs`
Expected: FAIL — `premium?` is not a known attribute (create raises on the unknown input / `card_fields` lacks it).

- [ ] **Step 3: Add the attribute**

In `lib/verscienta/content/article.ex`, inside the `attributes do` block, add after the `:aggregated?` line (around line 386):

```elixir
    attribute :premium?, :boolean, allow_nil?: false, default: false, public?: true
```

- [ ] **Step 4: Accept it in `:create` and `:update`**

Change the `:create` accept list (line 27) to:

```elixir
      accept [:title, :excerpt, :cover_image_url, :category, :evidence_level, :group_id, :premium?]
```

Change the `:update` accept list (line 50) to:

```elixir
      accept [:title, :excerpt, :cover_image_url, :category, :evidence_level, :group_id, :premium?]
```

- [ ] **Step 5: Add it to `@card_fields`**

In the `@card_fields` list (line 450), add `:premium?` after `:aggregated?`:

```elixir
    :aggregated?,
    :premium?,
```

- [ ] **Step 6: Generate and run the migration**

Run:
```bash
docker exec news-verscienta-app-1 mix ash_postgres.generate_migrations add_article_premium
docker exec news-verscienta-app-1 mix ecto.migrate
```
Expected: a migration adding a non-null `premium` boolean column with default `false`; migrate succeeds. Open the generated file and confirm it adds `add :premium, :boolean, null: false, default: false` to the `articles` table.

- [ ] **Step 7: Run test to verify it passes**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta/content/article_premium_attr_test.exs`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add lib/verscienta/content/article.ex priv/repo/migrations test/verscienta/content/article_premium_attr_test.exs
git commit -m "feat(paywall): add premium? attribute to Article"
```

---

### Task 3: The `Content.body_visible?/2` entitlement helper

**Files:**
- Modify: `lib/verscienta/content.ex` (add the public function + private helpers)
- Test: `test/verscienta/content/body_visible_test.exs`

- [ ] **Step 1: Write the failing test (the full truth table)**

```elixir
# test/verscienta/content/body_visible_test.exs
defmodule Verscienta.Content.BodyVisibleTest do
  use Verscienta.DataCase, async: false

  import Verscienta.Support.Factory, only: [user: 1, user: 2, article: 2]
  alias Verscienta.{Billing, Content}

  setup do
    Verscienta.Cache.flush()
    on_exit(fn -> Verscienta.Cache.flush() end)
    :ok
  end

  defp make_premium(user) do
    {:ok, _} = Billing.start_checkout(user, :monthly, "http://x/r", "http://x/c")
    :ok = Billing.sync("I-STUB123")
    user
  end

  test "free article is always visible regardless of flag/actor" do
    author = user("bv_author")
    free = article(author, %{premium?: false})
    Verscienta.Flags.enable(:paywall)

    assert Content.body_visible?(free, nil)
    assert Content.body_visible?(free, user("bv_rando"))
  end

  test "flag off => premium body visible to everyone" do
    author = user("bv_author2")
    prem = article(author, %{premium?: true})
    refute Verscienta.Flags.enabled?(:paywall)

    assert Content.body_visible?(prem, nil)
    assert Content.body_visible?(prem, user("bv_rando2"))
  end

  test "flag on: gated for anonymous and non-subscribers; open for author, staff, subscriber" do
    author = user("bv_author3")
    prem = article(author, %{premium?: true})
    Verscienta.Flags.enable(:paywall)

    refute Content.body_visible?(prem, nil)
    refute Content.body_visible?(prem, user("bv_nonsub"))

    assert Content.body_visible?(prem, author)
    assert Content.body_visible?(prem, user("bv_mod", :moderator))
    assert Content.body_visible?(prem, user("bv_admin", :admin))
    assert Content.body_visible?(prem, make_premium(user("bv_sub")))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta/content/body_visible_test.exs`
Expected: FAIL — `Content.body_visible?/2` is undefined.

- [ ] **Step 3: Implement the helper**

In `lib/verscienta/content.ex`, add (near the other public domain helpers, after `snapshot_revision/1` is fine):

```elixir
  @doc """
  Whether `actor` may see the full body of `article`. The single access rule for
  the premium paywall — readers, badges, and SEO consult this or `premium?`.

  Visible when: the `:paywall` flag is off (kill switch / billing-not-configured
  safety), OR the article is not premium, OR the actor is the author or staff
  (moderator/admin), OR the actor is an entitled premium subscriber.
  """
  def body_visible?(%Verscienta.Content.Article{} = article, actor) do
    cond do
      not Verscienta.Flags.enabled?(:paywall) -> true
      not article.premium? -> true
      author?(article, actor) -> true
      staff?(actor) -> true
      Verscienta.Accounts.premium?(actor) -> true
      true -> false
    end
  end

  defp author?(%{author_id: aid}, %{id: uid}) when not is_nil(aid), do: aid == uid
  defp author?(_article, _actor), do: false

  defp staff?(%{role: role}), do: role in [:moderator, :admin]
  defp staff?(_actor), do: false
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta/content/body_visible_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta/content.ex test/verscienta/content/body_visible_test.exs
git commit -m "feat(paywall): add Content.body_visible?/2 entitlement helper"
```

---

### Task 4: Gate the reader (security boundary + teaser/CTA)

**Files:**
- Modify: `lib/verscienta_web/live/article_reader_live.ex` — `mount/3` assigns (lines 54-83), the body branch in `render/1` (lines 490-501), the ReadingTimer hook (line 429)
- Test: `test/verscienta_web/live/article_reader_paywall_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/verscienta_web/live/article_reader_paywall_test.exs
defmodule VerscientaWeb.ArticleReaderPaywallTest do
  use VerscientaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Verscienta.Support.Factory

  alias Verscienta.Billing

  @sentinel "SENTINELBODYTEXT"

  setup do
    Verscienta.Cache.flush()
    on_exit(fn -> Verscienta.Cache.flush() end)
    :ok
  end

  defp premium_article(author) do
    article(author, %{
      premium?: true,
      blocks: [%{"type" => "paragraph", "data" => %{"text" => @sentinel}}]
    })
  end

  test "anonymous reader of a gated premium article sees teaser + CTA, not the body", %{conn: conn} do
    Verscienta.Flags.enable(:paywall)
    a = premium_article(user("pw_author"))

    {:ok, _lv, html} = live(conn, "/articles/#{a.slug}")

    assert html =~ a.title
    refute html =~ @sentinel
    assert html =~ "Premium"
    assert html =~ "/premium"
    # heartbeat hook is suppressed on a gated view
    refute html =~ ~s(phx-hook="ReadingTimer")
  end

  test "premium subscriber sees the full body", %{conn: conn} do
    Verscienta.Flags.enable(:paywall)
    a = premium_article(user("pw_author2"))
    sub = user("pw_sub")
    {:ok, _} = Billing.start_checkout(sub, :monthly, "http://x/r", "http://x/c")
    :ok = Billing.sync("I-STUB123")

    {:ok, _lv, html} = conn |> sign_in(sub) |> live("/articles/#{a.slug}")

    assert html =~ @sentinel
    assert html =~ ~s(phx-hook="ReadingTimer")
  end

  test "author always sees the full body of their own gated article", %{conn: conn} do
    Verscienta.Flags.enable(:paywall)
    author = user("pw_author3")
    a = premium_article(author)

    {:ok, _lv, html} = conn |> sign_in(author) |> live("/articles/#{a.slug}")

    assert html =~ @sentinel
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta_web/live/article_reader_paywall_test.exs`
Expected: FAIL — the anonymous render still contains `@sentinel` and the `ReadingTimer` hook (no gating yet).

- [ ] **Step 3: Compute gating and strip blocks in `mount/3`**

In `article_reader_live.ex`, inside the `article ->` branch of `mount/3`, after the `Ash.load!(...)` that builds `article` (line 40) and before `if connected?...`, insert:

```elixir
        gated? = not Verscienta.Content.body_visible?(article, actor)
        article = if gated?, do: %{article | blocks: []}, else: article
```

Then in the `assign(...)` call, change the `body_html:` line and add `premium_gated?:`:

```elixir
           body_html: if(gated?, do: nil, else: BlockRenderer.to_html(article.blocks)),
           premium_gated?: gated?,
```

(Leave the rest of the assigns unchanged.)

- [ ] **Step 4: Suppress the reading-time heartbeat when gated**

Change the ReadingTimer div (line 429) to:

```heex
      <div
        :if={not @premium_gated?}
        id="reading-timer"
        phx-hook="ReadingTimer"
        data-article-id={@article.id}
      >
      </div>
```

- [ ] **Step 5: Render the teaser/upgrade panel in the body branch**

Replace the `<%= if @held? do %> ... <% else %> ... <% end %>` block (lines 490-501) with a three-way `cond`:

```heex
      <%= cond do %>
        <% @held? -> %>
          <div class="my-8 border border-line bg-canvas-2 p-6 text-ink-2">
            <p class="text-sm uppercase tracking-wider text-ink-3">⏸ under review</p>
            <p class="mt-2 text-sm">
              This content is under moderation review and is temporarily hidden.
            </p>
          </div>
        <% @premium_gated? -> %>
          <div class="premium-body my-8 border border-zune bg-canvas-2 p-8 text-center text-ink-2">
            <p class="text-xs font-bold uppercase tracking-wider text-zune">Premium</p>
            <p class="mx-auto mt-3 max-w-md text-base font-light">
              This article is for premium subscribers.
            </p>
            <%= if @current_user do %>
              <a
                href="/premium"
                class="mt-6 inline-block bg-zune px-6 py-3 text-xs font-bold uppercase tracking-wider text-black hover:brightness-110"
              >
                Subscribe to read
              </a>
            <% else %>
              <a
                href="/premium"
                class="mt-6 inline-block bg-zune px-6 py-3 text-xs font-bold uppercase tracking-wider text-black hover:brightness-110"
              >
                Sign in to subscribe
              </a>
            <% end %>
          </div>
        <% true -> %>
          <div class="max-w-none text-base font-light leading-relaxed text-ink-2">
            {Phoenix.HTML.raw(@body_html)}
          </div>
      <% end %>
```

- [ ] **Step 6: Run test to verify it passes**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta_web/live/article_reader_paywall_test.exs`
Expected: PASS

- [ ] **Step 7: Run the existing reader tests to confirm no regression**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta_web/live/article_reader_live_test.exs`
Expected: PASS (free articles render the body and the heartbeat exactly as before — `premium_gated?` is false for them).

- [ ] **Step 8: Commit**

```bash
git add lib/verscienta_web/live/article_reader_live.ex test/verscienta_web/live/article_reader_paywall_test.exs
git commit -m "feat(paywall): gate the article reader with teaser + upgrade CTA"
```

---

### Task 5: Editor premium toggle (flag-gated)

**Files:**
- Modify: `lib/verscienta_web/live/article_editor_live.ex` — `mount/3` assigns (after line 31), `render/1` form (after the excerpt field, ~line 658)
- Test: `test/verscienta_web/live/article_editor_premium_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/verscienta_web/live/article_editor_premium_test.exs
defmodule VerscientaWeb.ArticleEditorPremiumTest do
  use VerscientaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Verscienta.Support.Factory

  setup do
    Verscienta.Cache.flush()
    on_exit(fn -> Verscienta.Cache.flush() end)
    :ok
  end

  test "toggle is hidden when :paywall flag is off", %{conn: conn} do
    author = user("ed_author_off")
    {:ok, _lv, html} = conn |> sign_in(author) |> live("/articles/new")
    refute html =~ ~s(name="form[premium?]")
  end

  test "toggle is shown and persists premium? when :paywall is on", %{conn: conn} do
    Verscienta.Flags.enable(:paywall)
    author = user("ed_author_on")
    a = article(author, %{premium?: false})

    {:ok, lv, html} = conn |> sign_in(author) |> live("/articles/#{a.slug}/edit")
    assert html =~ ~s(name="form[premium?]")

    lv
    |> form("#article-form", form: %{"premium?" => "true"})
    |> render_change()

    lv |> element("#article-form") |> render_submit()

    updated = Ash.get!(Verscienta.Content.Article, a.id, authorize?: false)
    assert updated.premium?
  end
end
```

(Routes confirmed in `lib/verscienta_web/router.ex`: `/articles/new`, `/articles/:slug/edit`, `/articles/:slug`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta_web/live/article_editor_premium_test.exs`
Expected: FAIL — the form has no `form[premium?]` input.

- [ ] **Step 3: Assign the flag state in `mount/3`**

In `article_editor_live.ex` `mount/3`, after the `:assist_enabled?` assign (line 31), add:

```elixir
     |> assign(
       :paywall_enabled?,
       Verscienta.Flags.enabled?(:paywall, for: socket.assigns.current_user)
     )
```

- [ ] **Step 4: Render the toggle after the excerpt field**

In `render/1`, immediately after the `<.text_field field={f[:excerpt]} ... />` line (line 658), add:

```heex
            <label
              :if={@paywall_enabled?}
              class="flex items-center gap-2 text-[11px] uppercase tracking-widest text-ink-3"
            >
              <input type="hidden" name={f[:premium?].name} value="false" />
              <input
                type="checkbox"
                name={f[:premium?].name}
                value="true"
                checked={f[:premium?].value in [true, "true"]}
              />
              premium (subscribers only)
            </label>
```

- [ ] **Step 5: Run test to verify it passes**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta_web/live/article_editor_premium_test.exs`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta_web/live/article_editor_live.ex test/verscienta_web/live/article_editor_premium_test.exs
git commit -m "feat(paywall): flag-gated premium toggle in the article editor"
```

---

### Task 6: "Premium" badge on article cards

**Files:**
- Modify: `lib/verscienta_web/components/codex_components.ex` — `news_card/1` (lines 60-88)
- Modify: `lib/verscienta_web/live/article_feed_live.ex` — `article_grid/1` (lines 140-155)
- Test: `test/verscienta_web/components/news_card_premium_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/verscienta_web/components/news_card_premium_test.exs
defmodule VerscientaWeb.NewsCardPremiumTest do
  use VerscientaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import VerscientaWeb.CodexComponents

  test "news_card renders a Premium badge only when premium" do
    premium =
      render_component(&news_card/1, %{
        category: "Movement",
        accent: "zune",
        premium: true,
        inner_block: fn _, _ -> "Title" end
      })

    free =
      render_component(&news_card/1, %{
        category: "Movement",
        accent: "zune",
        premium: false,
        inner_block: fn _, _ -> "Title" end
      })

    assert premium =~ "Premium"
    refute free =~ "Premium"
  end
end
```

(If `render_component` with a function slot is awkward in this repo, use the `~H` test sigil form already used by other component tests — match the existing pattern in `test/verscienta_web/components/`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta_web/components/news_card_premium_test.exs`
Expected: FAIL — `news_card` has no `premium` attr / no badge.

- [ ] **Step 3: Add the `premium` attr + badge to `news_card`**

In `codex_components.ex`, add the attr alongside the others (after line 64):

```elixir
  attr :premium, :boolean, default: false
```

Inside `news_card`, add a badge in the image header `<div class={["relative h-[170px]", accent_bg(@accent)]}>` block, after the existing category `<span>` (after line 76):

```heex
        <span
          :if={@premium}
          class="absolute right-0 top-0 bg-zune px-2 py-1 text-[10px] font-extrabold uppercase tracking-wider text-black"
        >
          Premium
        </span>
```

- [ ] **Step 4: Pass `premium` from `article_grid`**

In `article_feed_live.ex`, update the `<.news_card>` call (lines 145-151) to pass the flag:

```heex
        <.news_card
          category={category_label(article.category)}
          accent={Category.accent(article.category)}
          premium={article.premium?}
          meta={meta(article)}
        >
          {article.title}
        </.news_card>
```

- [ ] **Step 5: Run test to verify it passes**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta_web/components/news_card_premium_test.exs`
Expected: PASS

- [ ] **Step 6: Run the feed tests for no regression**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta_web/live/article_feed_live_test.exs`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/verscienta_web/components/codex_components.ex lib/verscienta_web/live/article_feed_live.ex test/verscienta_web/components/news_card_premium_test.exs
git commit -m "feat(paywall): Premium badge on article cards"
```

---

### Task 7: Paywall-compliant SEO JSON-LD

**Files:**
- Modify: `lib/verscienta_web/seo.ex` — `news_article_json_ld/4` (lines 74-88)
- Test: `test/verscienta_web/seo_paywall_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/verscienta_web/seo_paywall_test.exs
defmodule VerscientaWeb.SEOPaywallTest do
  use Verscienta.DataCase, async: false

  import Verscienta.Support.Factory, only: [user: 1, article: 2]
  alias VerscientaWeb.SEO

  defp loaded(a), do: Ash.load!(a, [:author], authorize?: false)

  test "premium article emits isAccessibleForFree:false + a gated hasPart" do
    a = article(user("seo_author"), %{premium?: true}) |> loaded()
    json = SEO.article(a).json_ld

    assert json["isAccessibleForFree"] == false
    assert %{"@type" => "WebPageElement", "cssSelector" => ".premium-body"} = json["hasPart"]
  end

  test "free article emits no paywall keys" do
    a = article(user("seo_author2"), %{premium?: false}) |> loaded()
    json = SEO.article(a).json_ld

    refute Map.has_key?(json, "isAccessibleForFree")
    refute Map.has_key?(json, "hasPart")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta_web/seo_paywall_test.exs`
Expected: FAIL — the JSON-LD has no `isAccessibleForFree`/`hasPart`.

- [ ] **Step 3: Add the paywall structured data**

In `seo.ex`, change `news_article_json_ld/4` to pipe through a new `maybe_paywall/2` before `Map.reject` (line 74-88):

```elixir
  defp news_article_json_ld(%Article{} = a, desc, image, canonical) do
    %{
      "@context" => "https://schema.org",
      "@type" => "NewsArticle",
      "headline" => a.title,
      "description" => desc,
      "image" => image,
      "datePublished" => iso8601(a.published_at),
      "dateModified" => iso8601(a.updated_at),
      "author" => %{"@type" => "Person", "name" => author_name(a)},
      "publisher" => %{"@type" => "Organization", "name" => @site_name},
      "mainEntityOfPage" => canonical
    }
    |> maybe_paywall(a)
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  # Google's paywalled-content signal: mark the article not-free and point a
  # hasPart at the gated body container (`.premium-body` in the reader) so the
  # hard gate is read as an intentional paywall, not cloaking.
  defp maybe_paywall(json, %Article{premium?: true}) do
    json
    |> Map.put("isAccessibleForFree", false)
    |> Map.put("hasPart", %{
      "@type" => "WebPageElement",
      "isAccessibleForFree" => false,
      "cssSelector" => ".premium-body"
    })
  end

  defp maybe_paywall(json, _article), do: json
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta_web/seo_paywall_test.exs`
Expected: PASS

- [ ] **Step 5: Run existing SEO tests for no regression**

Run: `docker exec news-verscienta-app-1 mix test test/verscienta_web/seo_test.exs`
Expected: PASS (free articles' JSON-LD unchanged).

- [ ] **Step 6: Commit**

```bash
git add lib/verscienta_web/seo.ex test/verscienta_web/seo_paywall_test.exs
git commit -m "feat(paywall): emit paywall-compliant NewsArticle JSON-LD"
```

---

### Task 8: Full verification + todo update

**Files:**
- Modify: `docs/todo.md:251`

- [ ] **Step 1: Run the full verification loop**

Run:
```bash
docker exec news-verscienta-app-1 mix format --check-formatted
docker exec news-verscienta-app-1 mix credo --strict
docker exec news-verscienta-app-1 mix test
```
Expected: format clean, Credo clean, all tests PASS. Fix anything that fails before continuing.

- [ ] **Step 2: Mark the todo item done**

In `docs/todo.md`, change line 251 from:

```markdown
- [ ] Paywalled / premium content tiers.
```

to:

```markdown
- [x] Paywalled / premium content tiers. *(hard gate behind off-by-default `:paywall` flag: per-article author `premium?` toggle, `Content.body_visible?/2` entitlement rule (author/staff/active-subscriber bypass), reader strips blocks + shows teaser/upgrade CTA + suppresses the reading heartbeat, Premium badge on cards, paywall-compliant NewsArticle JSON-LD; consumes the existing `Accounts.premium?/1`. See `docs/superpowers/specs/2026-06-13-paywalled-premium-content-design.md`)*
```

- [ ] **Step 3: Commit**

```bash
git add docs/todo.md
git commit -m "docs(todo): mark paywalled premium content done"
```

---

## Notes for the implementer

- **Security invariant:** for a gated read the body must never reach the client. Task 4 enforces this two ways — `blocks` is replaced with `[]` in the assign, and `body_html` is `nil` so the body branch can't render it. The `refute html =~ @sentinel` assertion is the regression guard; do not weaken it.
- **Kill switch:** with `:paywall` off (the default and the production state until PayPal billing is configured), `body_visible?/2` returns true for everything and the editor toggle is hidden — premium articles read free. This is intentional safe behavior.
- **Moderation precedence:** `@held?` is checked before `@premium_gated?` in the body `cond`, so a held article keeps showing the "under review" placeholder, matching the spec.
- **Out of scope (do not build):** metering, tier enums, per-section splits, sponsored/affiliate/featured-challenge features. Each is a separate spec.
