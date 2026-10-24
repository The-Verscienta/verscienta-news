# Affiliate Link Integration + Disclosure Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically append affiliate tracking params + set the paid-link `rel` on article-body links to configured partner domains, and show an FTC affiliate disclosure on any article that contains them — all at render time, behind an off-by-default flag.

**Architecture:** A pure `Verscienta.Content.Affiliate` module (regex-based, mirroring `Aggregation.Html`) rewrites the reader's already-rendered body HTML and reports whether any link matched. The reader gates it behind the `:affiliate_links` flag and assigns a `@has_affiliate?` boolean that drives a new `LegalComponents.affiliate_disclosure/1` banner above the body. Partner list comes from `config :verscienta, :affiliate_partners` (env-driven). Stored blocks are never mutated.

**Tech Stack:** Elixir, Ash 3, Phoenix LiveView, FunWithFlags, ExUnit, Jason.

**Spec:** `docs/superpowers/specs/2026-06-15-affiliate-links-design.md`

---

## Running mix & tests in this worktree

Host `mix` is broken; run through the container. Worktree name is `affiliate-links`. Wrapper for ALL `mix` commands:

```bash
MSYS_NO_PATHCONV=1 docker exec \
  -e MIX_DEPS_PATH=/workspace/deps \
  -e MIX_BUILD_ROOT=/workspace/_build/wt-affiliate-links \
  -e MIX_TEST_PARTITION=_wt_affiliate-links \
  -w /workspace/.claude/worktrees/affiliate-links \
  news-verscienta-app-1 mix test path/to/test.exs
```

- This is a FRESH build root + test partition. First compile is slow. If `mix test` fails because the partitioned test DB doesn't exist, run `MIX_ENV=test mix ecto.create` (wrapped, `-e MIX_ENV=test` before the image name) once, then retry. If you hit `template database "template1" has a collation version mismatch`, run once: `docker exec news-verscienta-db-1 psql -U postgres -c "ALTER DATABASE template1 REFRESH COLLATION VERSION"`.
- Never pipe `mix test` through `tail`. Run mix FOREGROUND.
- Credo: `MIX_ENV=test mix credo`.

---

## File Structure

**Modify:**
- `lib/verscienta/flags.ex` — add `affiliate_links` to `@known_flags`.
- `lib/verscienta_web/live/article_reader_live.ex` — flag-gated rewrite of `body_html` + `@has_affiliate?` assign.
- `lib/verscienta_web/components/legal_components.ex` — add `affiliate_disclosure/1`.
- `config/runtime.exs` — wire `:affiliate_partners` from `AFFILIATE_PARTNERS` env.
- `.env.example` (if present) / `README` — document `AFFILIATE_PARTNERS`.

**Create:**
- `lib/verscienta/content/affiliate.ex` — partner config + pure HTML rewriter.
- `test/verscienta/content/affiliate_test.exs` — rewriter unit tests.
- `test/verscienta_web/live/article_affiliate_test.exs` — reader integration test.
- `test/verscienta/affiliate_flag_test.exs` — flag-known test.

---

## Task 1: Register the `:affiliate_links` flag

**Files:**
- Modify: `lib/verscienta/flags.ex` (`@known_flags` list)
- Test: `test/verscienta/affiliate_flag_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/affiliate_flag_test.exs` (mirrors `test/verscienta/auto_enforcement_flag_test.exs`):

```elixir
defmodule Verscienta.AffiliateFlagTest do
  use Verscienta.DataCase, async: false

  test ":affiliate_links is a known flag and starts disabled" do
    assert :affiliate_links in Verscienta.Flags.known_flags()
    refute Verscienta.Flags.enabled?(:affiliate_links)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/verscienta/affiliate_flag_test.exs`
Expected: FAIL — `:affiliate_links` not in the allowlist (and `enabled?/1` raises on the unknown flag, or the membership assertion fails).

- [ ] **Step 3: Add the flag to the allowlist**

In `lib/verscienta/flags.ex`, add `affiliate_links` to the `@known_flags` sigil list (append to the last line before `)a`):

```elixir
    auto_enforcement web_push
    paywall
    affiliate_links
  )a
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/verscienta/affiliate_flag_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta/flags.ex test/verscienta/affiliate_flag_test.exs
git commit -m "feat(flags): register off-by-default :affiliate_links flag" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `Verscienta.Content.Affiliate` — partners + pure rewriter

**Files:**
- Create: `lib/verscienta/content/affiliate.ex`
- Test: `test/verscienta/content/affiliate_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/verscienta/content/affiliate_test.exs`:

```elixir
defmodule Verscienta.Content.AffiliateTest do
  use ExUnit.Case, async: false

  alias Verscienta.Content.Affiliate

  @amazon %{host: "amazon.com", param: "tag", value: "verscienta-20", label: "Amazon"}

  setup do
    prev = Application.get_env(:verscienta, :affiliate_partners)
    on_exit(fn -> Application.put_env(:verscienta, :affiliate_partners, prev) end)
    :ok
  end

  defp with_partners(parts, fun) do
    Application.put_env(:verscienta, :affiliate_partners, parts)
    fun.()
  end

  # --- parse_partners/1 ---

  test "parse_partners parses a JSON array into atom-keyed maps" do
    json = ~s([{"host":"amazon.com","param":"tag","value":"verscienta-20","label":"Amazon"}])
    assert [%{host: "amazon.com", param: "tag", value: "verscienta-20", label: "Amazon"}] =
             Affiliate.parse_partners(json)
  end

  test "parse_partners returns [] for nil/empty/invalid" do
    assert Affiliate.parse_partners(nil) == []
    assert Affiliate.parse_partners("") == []
    assert Affiliate.parse_partners("not json") == []
    assert Affiliate.parse_partners(~s([{"host":"x"}])) == []
  end

  test "parse_partners defaults label to host when omitted" do
    json = ~s([{"host":"amazon.com","param":"tag","value":"v"}])
    assert [%{label: "amazon.com"}] = Affiliate.parse_partners(json)
  end

  # --- rewrite_html/1 ---

  test "no partners configured -> unchanged, false" do
    with_partners([], fn ->
      html = ~s(<p><a href="https://amazon.com/dp/X">buy</a></p>)
      assert {^html, false} = Affiliate.rewrite_html(html)
    end)
  end

  test "a partner link gets the tracking param and sponsored nofollow rel" do
    with_partners([@amazon], fn ->
      html = ~s(<p><a href="https://amazon.com/dp/X">buy</a></p>)
      {out, true} = Affiliate.rewrite_html(html)
      assert out =~ "tag=verscienta-20"
      assert out =~ ~r/rel="[^"]*\bsponsored\b[^"]*"/
      assert out =~ ~r/rel="[^"]*\bnofollow\b[^"]*"/
    end)
  end

  test "matches subdomains of the partner host" do
    with_partners([@amazon], fn ->
      html = ~s(<a href="https://www.amazon.com/dp/X">buy</a>)
      {out, true} = Affiliate.rewrite_html(html)
      assert out =~ "tag=verscienta-20"
    end)
  end

  test "does not duplicate an already-present param" do
    with_partners([@amazon], fn ->
      html = ~s(<a href="https://amazon.com/dp/X?tag=existing">buy</a>)
      {out, true} = Affiliate.rewrite_html(html)
      refute out =~ "verscienta-20"
      assert out =~ "tag=existing"
    end)
  end

  test "appends with & when the link already has a query string" do
    with_partners([@amazon], fn ->
      html = ~s(<a href="https://amazon.com/dp/X?ref=foo">buy</a>)
      {out, true} = Affiliate.rewrite_html(html)
      assert out =~ "ref=foo&tag=verscienta-20"
    end)
  end

  test "merges and dedupes with an existing rel" do
    with_partners([@amazon], fn ->
      html = ~s(<a href="https://amazon.com/dp/X" rel="noopener noreferrer">buy</a>)
      {out, true} = Affiliate.rewrite_html(html)
      assert out =~ "noopener"
      assert out =~ "noreferrer"
      assert out =~ "sponsored"
      assert out =~ "nofollow"
      # no duplicate tokens
      [_, rel] = Regex.run(~r/rel="([^"]*)"/, out)
      assert length(Enum.uniq(String.split(rel))) == length(String.split(rel))
    end)
  end

  test "non-partner links are untouched and flagged false" do
    with_partners([@amazon], fn ->
      html = ~s(<a href="https://example.com/x">read</a>)
      assert {^html, false} = Affiliate.rewrite_html(html)
    end)
  end

  test "flag true if ANY link matches, even alongside non-partner links" do
    with_partners([@amazon], fn ->
      html =
        ~s(<a href="https://example.com/x">read</a> <a href="https://amazon.com/y">buy</a>)

      {out, true} = Affiliate.rewrite_html(html)
      assert out =~ "example.com/x"
      assert out =~ "tag=verscienta-20"
    end)
  end

  test "is idempotent" do
    with_partners([@amazon], fn ->
      html = ~s(<a href="https://amazon.com/dp/X" rel="noopener">buy</a>)
      {once, true} = Affiliate.rewrite_html(html)
      {twice, true} = Affiliate.rewrite_html(once)
      assert once == twice
    end)
  end

  test "preserves a fragment when appending the param" do
    with_partners([@amazon], fn ->
      html = ~s(<a href="https://amazon.com/dp/X#reviews">buy</a>)
      {out, true} = Affiliate.rewrite_html(html)
      assert out =~ "tag=verscienta-20#reviews"
    end)
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/verscienta/content/affiliate_test.exs`
Expected: FAIL — `Verscienta.Content.Affiliate` does not exist.

- [ ] **Step 3: Implement the module**

Create `lib/verscienta/content/affiliate.ex`:

```elixir
defmodule Verscienta.Content.Affiliate do
  @moduledoc """
  Render-time affiliate link integration. Rewrites article-body links that point
  to configured partner domains: appends the partner's tracking param and ensures
  the FTC/Google paid-link rel (`sponsored nofollow`). Pure and idempotent —
  operates on our own well-formed `BlockRenderer`/MDEx HTML (double-quoted attrs),
  regex-based to match the `Aggregation.Html` convention (no HTML parser dep).

  The `:affiliate_links` feature-flag check lives in the caller (the reader); this
  module rewrites purely from the configured partner list.
  """

  @anchor ~r/<a\b[^>]*>/i

  @doc "Configured affiliate partners (atom-keyed maps); `[]` when unset."
  def partners, do: Application.get_env(:verscienta, :affiliate_partners, [])

  @doc """
  Parse the `AFFILIATE_PARTNERS` env JSON into a partner list. Each entry needs
  `host`, `param`, `value`; `label` defaults to `host`. nil/blank/invalid -> [].
  """
  def parse_partners(nil), do: []
  def parse_partners(""), do: []

  def parse_partners(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) ->
        Enum.flat_map(list, fn
          %{"host" => h, "param" => p, "value" => v} = m ->
            [%{host: h, param: p, value: v, label: Map.get(m, "label", h)}]

          _ ->
            []
        end)

      _ ->
        []
    end
  end

  def parse_partners(_), do: []

  @doc """
  Rewrite partner links in `html`. Returns `{html, affiliate?}` where `affiliate?`
  is true iff at least one link matched a partner. No partners -> `{html, false}`.
  """
  def rewrite_html(html) when is_binary(html) do
    case partners() do
      [] -> {html, false}
      parts -> do_rewrite(html, parts)
    end
  end

  def rewrite_html(html), do: {html, false}

  defp do_rewrite(html, parts) do
    matched? =
      @anchor
      |> Regex.scan(html)
      |> Enum.any?(fn [tag] -> tag |> extract_href() |> partner_for(parts) != nil end)

    if matched? do
      rewritten =
        Regex.replace(@anchor, html, fn tag ->
          href = extract_href(tag)

          case partner_for(href, parts) do
            nil -> tag
            partner -> rewrite_anchor(tag, href, partner)
          end
        end)

      {rewritten, true}
    else
      {html, false}
    end
  end

  defp extract_href(tag) do
    case Regex.run(~r/\shref="([^"]*)"/i, tag) do
      [_, href] -> href
      _ -> nil
    end
  end

  defp partner_for(nil, _parts), do: nil

  defp partner_for(href, parts) do
    case URI.parse(href) do
      %URI{host: host} when is_binary(host) and host != "" ->
        h = String.downcase(host)
        Enum.find(parts, fn p -> host_match?(h, String.downcase(p.host)) end)

      _ ->
        nil
    end
  end

  defp host_match?(h, ph), do: h == ph or String.ends_with?(h, "." <> ph)

  defp rewrite_anchor(tag, href, partner) do
    new_href = add_param(href, partner.param, partner.value)

    tag
    |> String.replace(~s(href="#{href}"), ~s(href="#{new_href}"))
    |> merge_rel()
  end

  defp add_param(href, param, value) do
    if has_param?(href, param) do
      href
    else
      {base, frag} = split_fragment(href)
      sep = if String.contains?(base, "?"), do: "&", else: "?"
      base <> sep <> param <> "=" <> URI.encode_www_form(value) <> frag
    end
  end

  defp has_param?(href, param) do
    case URI.parse(href) do
      %URI{query: q} when is_binary(q) -> Map.has_key?(URI.decode_query(q), param)
      _ -> false
    end
  end

  defp split_fragment(href) do
    case String.split(href, "#", parts: 2) do
      [base, frag] -> {base, "#" <> frag}
      [base] -> {base, ""}
    end
  end

  defp merge_rel(tag) do
    needed = ["sponsored", "nofollow"]

    case Regex.run(~r/\srel="([^"]*)"/i, tag) do
      [full, existing] ->
        merged = (String.split(existing) ++ needed) |> Enum.uniq() |> Enum.join(" ")
        String.replace(tag, full, ~s( rel="#{merged}"))

      nil ->
        # Insert rel just before the tag's closing ">".
        String.replace_suffix(tag, ">", ~s( rel="sponsored nofollow">))
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/verscienta/content/affiliate_test.exs`
Expected: PASS (all units). If the "appends with &" test fails because `has_param?` mis-parses, inspect — the regex/URI logic must treat `?ref=foo` as an existing query (sep `&`). If the rel-dedup test fails, check `Enum.uniq` on the split tokens.

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta/content/affiliate.ex test/verscienta/content/affiliate_test.exs
git commit -m "feat(content): Affiliate partner config + pure HTML link rewriter" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Reader integration + `affiliate_disclosure/1`

**Files:**
- Modify: `lib/verscienta_web/components/legal_components.ex` (add `affiliate_disclosure/1`)
- Modify: `lib/verscienta_web/live/article_reader_live.ex` (body render + assign + template)
- Test: `test/verscienta_web/live/article_affiliate_test.exs`

- [ ] **Step 1: Write the failing reader test**

Create `test/verscienta_web/live/article_affiliate_test.exs`:

```elixir
defmodule VerscientaWeb.ArticleAffiliateTest do
  use VerscientaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Verscienta.Support.Factory, only: [user: 1, article: 2]

  @amazon %{host: "amazon.com", param: "tag", value: "verscienta-20", label: "Amazon"}

  setup do
    FunWithFlags.clear(:affiliate_links)
    prev = Application.get_env(:verscienta, :affiliate_partners)
    Application.put_env(:verscienta, :affiliate_partners, [@amazon])
    Verscienta.Cache.flush()

    on_exit(fn ->
      FunWithFlags.clear(:affiliate_links)
      Application.put_env(:verscienta, :affiliate_partners, prev)
      Verscienta.Cache.flush()
    end)

    :ok
  end

  # A published article whose body links to an affiliate partner. The block input
  # shape mirrors the project's existing "article with body text" tests; verify it
  # renders a link by reading Content.Block/CastBlocks if the link doesn't appear.
  defp article_with_amazon_link(author) do
    article(author, %{
      blocks: [
        %{
          "type" => "paragraph",
          "content" => "Try [this product](https://www.amazon.com/dp/B00TEST) today.",
          "attrs" => %{}
        }
      ]
    })
  end

  test "flag ON: affiliate disclosure + rewritten link render", %{conn: conn} do
    Verscienta.Flags.enable(:affiliate_links)
    art = article_with_amazon_link(user("aff_author"))

    {:ok, _view, html} = live(conn, ~p"/articles/#{art.slug}")

    assert html =~ "affiliate"
    assert html =~ "tag=verscienta-20"
    assert html =~ "sponsored"
  end

  test "flag OFF: no disclosure, link not rewritten", %{conn: conn} do
    refute Verscienta.Flags.enabled?(:affiliate_links)
    art = article_with_amazon_link(user("aff_author2"))

    {:ok, _view, html} = live(conn, ~p"/articles/#{art.slug}")

    refute html =~ "tag=verscienta-20"
  end

  test "flag ON but no partner links: no disclosure", %{conn: conn} do
    Verscienta.Flags.enable(:affiliate_links)

    art =
      article(user("aff_author3"), %{
        blocks: [
          %{
            "type" => "paragraph",
            "content" => "Read [more](https://example.com/x) here.",
            "attrs" => %{}
          }
        ]
      })

    {:ok, _view, html} = live(conn, ~p"/articles/#{art.slug}")
    refute html =~ "Affiliate disclosure"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/verscienta_web/live/article_affiliate_test.exs`
Expected: FAIL — no rewrite/disclosure yet (the `tag=verscienta-20` assertion fails). FIRST confirm the block input produces a link at all: if the test errors before the affiliate assertions (e.g. body empty), open `lib/verscienta/content/block.ex` / the `CastBlocks` change and match the exact create-input shape an existing "article with body" test uses, then adjust `article_with_amazon_link/1`. Do not move on until the body renders a `<a href="...amazon...">`.

- [ ] **Step 3: Add the `affiliate_disclosure/1` component**

In `lib/verscienta_web/components/legal_components.ex`, add inside the module (after `sponsored_tag/1`):

```elixir
  @doc """
  FTC affiliate disclosure, shown above the body of an article that contains
  affiliate links (detected at render time). Renders nothing otherwise.
  """
  attr :has_affiliate, :boolean, required: true

  def affiliate_disclosure(assigns) do
    ~H"""
    <aside
      :if={@has_affiliate}
      id="affiliate-disclosure"
      aria-label="Affiliate disclosure"
      class="mb-8 border border-line bg-canvas-2 px-4 py-3 text-xs leading-relaxed text-ink-2"
    >
      <p class="mb-1 text-[11px] font-bold uppercase tracking-widest text-ink-3">Affiliate disclosure</p>
      <p>
        This article contains affiliate links. We may earn a commission on qualifying
        purchases, at no extra cost to you.
      </p>
    </aside>
    """
  end
```

- [ ] **Step 4: Gate + rewrite the body in the reader mount**

In `lib/verscienta_web/live/article_reader_live.ex`, replace the `body_html:` line in the mount assign (currently `body_html: if(gated?, do: nil, else: BlockRenderer.to_html(article.blocks)),`) with a pair pulled from a helper. Change the assign to use two precomputed bindings — immediately BEFORE the `{:ok, socket |> assign(` call, add:

```elixir
        {body_html, has_affiliate?} = render_body(article, gated?)
```

and in the `assign(...)` keyword list replace the `body_html:` entry with:

```elixir
           body_html: body_html,
           has_affiliate?: has_affiliate?,
```

(Keep every other assign unchanged. `gated?` is the existing local bound earlier in mount.)

- [ ] **Step 5: Add the `render_body/2` helper**

In `lib/verscienta_web/live/article_reader_live.ex`, add a private helper (near the other private helpers, e.g. after `seo_for/1`):

```elixir
  defp render_body(_article, true), do: {nil, false}

  defp render_body(article, false) do
    html = BlockRenderer.to_html(article.blocks)

    if Verscienta.Flags.enabled?(:affiliate_links) do
      Verscienta.Content.Affiliate.rewrite_html(html)
    else
      {html, false}
    end
  end
```

- [ ] **Step 6: Render the disclosure above the body**

In `lib/verscienta_web/live/article_reader_live.ex` template, find the existing `<VerscientaWeb.LegalComponents.sponsored_disclosure ... />` (around line 577, above the body `<%= cond do %>`). Immediately AFTER that sponsored_disclosure element, add:

```heex
      <VerscientaWeb.LegalComponents.affiliate_disclosure has_affiliate={@has_affiliate?} />
```

- [ ] **Step 7: Run the reader test**

Run: `mix test test/verscienta_web/live/article_affiliate_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 8: Compile with warnings as errors**

Run: `mix compile --warnings-as-errors`
Expected: clean. (If the reader complains `@has_affiliate?` is unset on some render path, ensure the assign is added unconditionally in mount — there is a single mount path that sets `body_html`.)

- [ ] **Step 9: Commit**

```bash
git add lib/verscienta_web/components/legal_components.ex lib/verscienta_web/live/article_reader_live.ex test/verscienta_web/live/article_affiliate_test.exs
git commit -m "feat(web): affiliate disclosure + flag-gated body link rewrite in reader" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Config wiring + docs

**Files:**
- Modify: `config/runtime.exs`
- Modify: `.env.example` and/or `README.md` (whichever the repo uses for env docs)

- [ ] **Step 1: Wire the partner list in runtime.exs**

In `config/runtime.exs`, add (in the main body so it runs in all envs, near other `config :verscienta, ...` runtime settings):

```elixir
config :verscienta,
       :affiliate_partners,
       Verscienta.Content.Affiliate.parse_partners(System.get_env("AFFILIATE_PARTNERS"))
```

- [ ] **Step 2: Verify config compiles + parses**

Run: `mix compile --warnings-as-errors`
Expected: clean. (runtime.exs is evaluated at boot; a compile is enough to catch syntax errors. The `parse_partners/1` of a nil env returns `[]`, so dev/test are unaffected.)

- [ ] **Step 3: Document the env var**

If `.env.example` exists, add a documented line; otherwise add a short note to `README.md` near other env vars:

```bash
# Affiliate link integration (off unless the :affiliate_links flag is enabled).
# JSON array of partners; each needs host, param, value (label optional).
# AFFILIATE_PARTNERS=[{"host":"amazon.com","param":"tag","value":"verscienta-20","label":"Amazon"}]
```

Check which file the repo uses first: `Glob .env.example` and grep the README for an existing env-var section; match that style. If neither exists, add the note to `README.md`.

- [ ] **Step 4: Commit**

```bash
git add config/runtime.exs .env.example README.md
git commit -m "chore(config): wire AFFILIATE_PARTNERS env into :affiliate_partners" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
(Only `git add` the files that actually changed — if `.env.example` doesn't exist, omit it.)

---

## Task 5: Full verification + todo checkoff

**Files:**
- Modify: `docs/todo.md`

- [ ] **Step 1: Run the full feature test set**

Run: `mix test test/verscienta/affiliate_flag_test.exs test/verscienta/content/affiliate_test.exs test/verscienta_web/live/article_affiliate_test.exs test/verscienta_web/live/article_reader_live_test.exs`
Expected: all PASS (the reader test confirms no regression to the existing reader).

- [ ] **Step 2: Format check**

Run: `mix format --check-formatted`
Expected: no output. If it fails, run `mix format`, then `git add -A && git commit -m "chore(content): mix format affiliate links" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"`.

- [ ] **Step 3: Credo**

Run: `MIX_ENV=test mix credo`
Expected: no new issues in the feature's files (`affiliate.ex`, `flags.ex`, `legal_components.ex`, `article_reader_live.ex`). If credo flags nesting/complexity in `Affiliate`, extract a helper and re-commit.

- [ ] **Step 4: Compile with warnings as errors**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 5: Full test suite**

Run: `mix test`
Expected: green. Pre-existing flakes (seed contamination, postgrex type-cache race, FunWithFlags sandbox) are unrelated — re-run a failing file in isolation to confirm it's not caused by this feature. In particular, confirm the affiliate flag/partner mutations are cleaned up (setup + on_exit) so they don't leak into other tests.

- [ ] **Step 6: Check off the todo item**

In `docs/todo.md`, change:
```
- [ ] Affiliate link integration + disclosure.
```
to:
```
- [x] Affiliate link integration + disclosure. *(render-time rewrite of article-body links to configured partner domains — appends the tracking param + merges `rel="sponsored nofollow"`; auto FTC `affiliate_disclosure` above the body when any partner link is present; partners via `AFFILIATE_PARTNERS` env (`Content.Affiliate.parse_partners/1`), pure idempotent `rewrite_html/1` (regex, no Floki); off-by-default `:affiliate_links` flag; article body only, stored blocks never mutated. Spec/plan: `docs/superpowers/{specs,plans}/2026-06-15-affiliate-links*`)*
```

- [ ] **Step 7: Commit**

```bash
git add docs/todo.md
git commit -m "docs: check off affiliate link integration (phase 4 monetization 3/3)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review notes (already reconciled)

- **Spec coverage:** flag registration (Task 1) · config partner list + pure `parse_partners`/`rewrite_html` with param-append/rel-merge/subdomain/idempotency/no-partner (Task 2) · flag-gated reader rewrite + `@has_affiliate?` + `affiliate_disclosure` above body (Task 3) · runtime.exs env wiring + docs (Task 4) · verification + todo (Task 5). Out-of-scope items (DB/admin, tracking, comments, syndication, cloaking, per-partner copy) intentionally absent.
- **Flag check placement:** `rewrite_html/1` is pure (no flag); the reader's `render_body/2` checks `Flags.enabled?(:affiliate_links)`. Matches the spec's resolved decision. The flag-off behavior is tested at the reader level; the no-partners no-op is a `rewrite_html` unit.
- **Disclosure policy link:** omitted in v1 — no affiliate policy page exists (confirmed). The component is self-contained text.
- **Type/name consistency:** module `Verscienta.Content.Affiliate`; `partners/0`, `parse_partners/1`, `rewrite_html/1` (returns `{html, boolean}`); partner maps are atom-keyed `%{host:, param:, value:, label:}`; reader helper `render_body/2` returns `{body_html, has_affiliate?}`; assign `has_affiliate?`; component `affiliate_disclosure/1` attr `has_affiliate`. Consistent across tasks.
- **Open implementation discretion (flagged in-task):** the exact block create-input shape for the reader test (Task 3 Step 2 — verify against `Content.Block`/an existing body test); which file documents env vars (Task 4 Step 3 — `.env.example` vs README).
```
