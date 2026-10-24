# AI Writing Assistant Implementation Plan

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give article authors in-editor LLM help — per-block Improve, Tone rewrite, and Claim-check — reusing the existing Ollama `AI.Client`, gated by the off-by-default `:writing_assistant` flag.

**Architecture:** A new best-effort `Verscienta.Assist` engine builds prompts, calls `AI.Client.generate/1`, and parses strict JSON (mirroring `Verscienta.AI` / `Moderation.Detector`). `ArticleEditorLive` renders per-text-block assist controls (flag-gated), runs the LLM call via `start_async`/`handle_async` so it never blocks the LiveView, and shows a suggestion panel with one-click Apply (rewrites) or an advisory list (claim-check). Nothing persists until the author saves/publishes normally.

**Tech Stack:** Elixir, Phoenix LiveView (`start_async`/`handle_async`), Ash 3, Jason, FunWithFlags, ExUnit + `Phoenix.LiveViewTest` (`render_async`), the existing `Verscienta.AI.Client.Stub`.

**Spec:** `docs/superpowers/specs/2026-06-10-writing-assistant-design.md`

**Conventions:**
- All `mix` runs inside Docker: `docker compose exec app mix ...`.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Branch: `phase-3-writing-assistant`. `git checkout phase-3-writing-assistant` first; STOP if the working tree is dirty with unrelated changes.

---

### Task 1: `Verscienta.Assist` — `tones/0` + `improve/1`

**Files:**
- Create: `lib/verscienta/assist.ex`
- Test: `test/verscienta/assist_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/verscienta/assist_test.exs`:

```elixir
defmodule Verscienta.AssistTest do
  # async: false — the AI client stub is configured via global Application env.
  use ExUnit.Case, async: false

  alias Verscienta.Assist
  alias Verscienta.AI.Client.Stub

  setup do
    prev = Application.get_env(:verscienta, :ai_client)
    Application.put_env(:verscienta, :ai_client, Stub)
    Stub.reset()
    on_exit(fn -> Application.put_env(:verscienta, :ai_client, prev) end)
    :ok
  end

  defp stub_generate(json),
    do: Application.put_env(:verscienta, :ai_stub, %{generate: {:ok, json}})

  describe "tones/0" do
    test "lists the fixed tone set" do
      assert Assist.tones() == [:professional, :conversational, :concise, :accessible]
    end
  end

  describe "improve/1" do
    test "returns the suggestion from the model JSON" do
      stub_generate(~s({"suggestion": "A clearer sentence."}))
      assert {:ok, %{suggestion: "A clearer sentence."}} = Assist.improve("a sentence")
    end

    test "blank suggestion is invalid" do
      stub_generate(~s({"suggestion": "   "}))
      assert {:error, :invalid} = Assist.improve("a sentence")
    end

    test "non-JSON response is invalid" do
      stub_generate("not json")
      assert {:error, :invalid} = Assist.improve("a sentence")
    end

    test "missing suggestion key is invalid" do
      stub_generate(~s({"other": "x"}))
      assert {:error, :invalid} = Assist.improve("a sentence")
    end

    test "client transient error is propagated" do
      Application.put_env(:verscienta, :ai_stub, %{generate: {:error, :timeout}})
      assert {:error, :timeout} = Assist.improve("a sentence")
    end

    test "non-binary input is invalid" do
      assert {:error, :invalid} = Assist.improve(nil)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec app mix test test/verscienta/assist_test.exs`
Expected: FAIL — `Verscienta.Assist` is undefined / `function Assist.tones/0 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/verscienta/assist.ex`:

```elixir
defmodule Verscienta.Assist do
  @moduledoc """
  Local-LLM (Ollama) writing help for article authors: rewrite a passage for
  clarity (`improve/1`), rewrite it in a given tone (`retone/2`), or list
  unsupported/risky health claims with how to strengthen them (`check_claims/1`).

  Reuses `Verscienta.AI.Client`. Best-effort: a client or parse failure returns
  `{:error, _}` and never raises into the caller (the LiveView treats any error
  as "couldn't generate").
  """
  require Logger

  alias Verscienta.AI.Client

  @tones [:professional, :conversational, :concise, :accessible]
  @input_budget 4_000
  @suggestion_limit 4_000

  @type result :: {:ok, map()} | {:error, term()}

  @doc "The fixed set of tones `retone/2` accepts."
  @spec tones() :: [atom()]
  def tones, do: @tones

  @doc "Rewrite `text` for clarity/flow. Returns `{:ok, %{suggestion: String}}`."
  @spec improve(String.t()) :: result()
  def improve(text) when is_binary(text), do: generate_suggestion(improve_prompt(text))
  def improve(_), do: {:error, :invalid}

  defp generate_suggestion(prompt) do
    with {:ok, raw} <- Client.generate(prompt),
         {:ok, suggestion} <- parse_suggestion(raw) do
      {:ok, %{suggestion: suggestion}}
    end
  rescue
    error ->
      Logger.warning("Assist suggestion crashed: #{inspect(error)}")
      {:error, :crashed}
  end

  defp parse_suggestion(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{"suggestion" => s}} when is_binary(s) ->
        case String.trim(s) do
          "" -> {:error, :invalid}
          t -> {:ok, String.slice(t, 0, @suggestion_limit)}
        end

      _ ->
        {:error, :invalid}
    end
  end

  defp parse_suggestion(_), do: {:error, :invalid}

  defp improve_prompt(text) do
    """
    You are a writing assistant for a holistic-health news platform.
    Rewrite the PASSAGE to be clearer and better-flowing, keeping the same
    meaning, facts, and approximate length. Use plain text, no markdown.
    Return ONLY a JSON object: {"suggestion": "the rewritten passage"}.
    Do not include any text outside the JSON object.

    PASSAGE:
    #{String.slice(text, 0, @input_budget)}
    """
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose exec app mix test test/verscienta/assist_test.exs`
Expected: PASS (all `tones/0` + `improve/1` tests green).

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta/assist.ex test/verscienta/assist_test.exs
git commit -m "feat(assist): Assist engine with tones + improve/1

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `Verscienta.Assist` — `retone/2`

**Files:**
- Modify: `lib/verscienta/assist.ex`
- Test: `test/verscienta/assist_test.exs`

- [ ] **Step 1: Write the failing test**

Add this `describe` block inside `test/verscienta/assist_test.exs` (after the `improve/1` block, before the final `end`):

```elixir
  describe "retone/2" do
    test "rewrites in a valid tone" do
      stub_generate(~s({"suggestion": "A professional rewrite."}))
      assert {:ok, %{suggestion: "A professional rewrite."}} =
               Assist.retone("a sentence", :professional)
    end

    test "every tone in the set is accepted" do
      stub_generate(~s({"suggestion": "ok"}))

      for tone <- Assist.tones() do
        assert {:ok, %{suggestion: "ok"}} = Assist.retone("a sentence", tone)
      end
    end

    test "an unknown tone is rejected without calling the model" do
      assert {:error, :invalid_tone} = Assist.retone("a sentence", :snarky)
      assert Stub.calls() == []
    end

    test "non-binary input is invalid" do
      assert {:error, :invalid} = Assist.retone(nil, :professional)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec app mix test test/verscienta/assist_test.exs`
Expected: FAIL — `function Verscienta.Assist.retone/2 is undefined`.

- [ ] **Step 3: Write minimal implementation**

In `lib/verscienta/assist.ex`, add after `improve/1` (and its `improve(_)` clause):

```elixir
  @doc """
  Rewrite `text` in `tone` (must be a member of `tones/0`). Returns
  `{:ok, %{suggestion: String}}`, or `{:error, :invalid_tone}` for an unknown
  tone (no model call).
  """
  @spec retone(String.t(), atom()) :: result()
  def retone(text, tone) when is_binary(text) and tone in @tones,
    do: generate_suggestion(retone_prompt(text, tone))

  def retone(text, _tone) when is_binary(text), do: {:error, :invalid_tone}
  def retone(_, _), do: {:error, :invalid}
```

And add the prompt builder (next to `improve_prompt/1`):

```elixir
  defp retone_prompt(text, tone) do
    """
    You are a writing assistant for a holistic-health news platform.
    Rewrite the PASSAGE in a #{tone} tone (#{tone_gloss(tone)}), keeping the
    same meaning and facts. Use plain text, no markdown.
    Return ONLY a JSON object: {"suggestion": "the rewritten passage"}.
    Do not include any text outside the JSON object.

    PASSAGE:
    #{String.slice(text, 0, @input_budget)}
    """
  end

  defp tone_gloss(:professional), do: "polished, authoritative, neutral"
  defp tone_gloss(:conversational), do: "warm, direct, plain-spoken"
  defp tone_gloss(:concise), do: "tighter and shorter, no filler"
  defp tone_gloss(:accessible), do: "simple words, short sentences, jargon-free"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose exec app mix test test/verscienta/assist_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta/assist.ex test/verscienta/assist_test.exs
git commit -m "feat(assist): retone/2 with a fixed tone set

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `Verscienta.Assist` — `check_claims/1`

**Files:**
- Modify: `lib/verscienta/assist.ex`
- Test: `test/verscienta/assist_test.exs`

- [ ] **Step 1: Write the failing test**

Add this `describe` block inside `test/verscienta/assist_test.exs` (after the `retone/2` block):

```elixir
  describe "check_claims/1" do
    test "parses the claims list" do
      stub_generate(~s({"claims": [
        {"claim": "Bleach cures cancer", "issue": "dangerous and false", "suggestion": "remove it"}
      ]}))

      assert {:ok, %{claims: [c]}} = Assist.check_claims("Bleach cures cancer.")
      assert c["claim"] == "Bleach cures cancer"
      assert c["issue"] == "dangerous and false"
      assert c["suggestion"] == "remove it"
    end

    test "an empty claims array yields an empty list" do
      stub_generate(~s({"claims": []}))
      assert {:ok, %{claims: []}} = Assist.check_claims("A balanced diet helps.")
    end

    test "malformed entries and blank-claim entries are dropped" do
      stub_generate(~s({"claims": [
        "garbage",
        {"issue": "no claim key"},
        {"claim": "   "},
        {"claim": "Real claim"}
      ]}))

      assert {:ok, %{claims: [c]}} = Assist.check_claims("text")
      assert c["claim"] == "Real claim"
      assert c["issue"] == ""
      assert c["suggestion"] == ""
    end

    test "missing claims key is invalid" do
      stub_generate(~s({"other": "x"}))
      assert {:error, :invalid} = Assist.check_claims("text")
    end

    test "non-JSON response is invalid" do
      stub_generate("not json")
      assert {:error, :invalid} = Assist.check_claims("text")
    end

    test "client transient error is propagated" do
      Application.put_env(:verscienta, :ai_stub, %{generate: {:error, :timeout}})
      assert {:error, :timeout} = Assist.check_claims("text")
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec app mix test test/verscienta/assist_test.exs`
Expected: FAIL — `function Verscienta.Assist.check_claims/1 is undefined`.

- [ ] **Step 3: Write minimal implementation**

In `lib/verscienta/assist.ex`, add a `@claim_field_limit 500` module attribute near the other attributes:

```elixir
  @claim_field_limit 500
```

Add the public function after `retone/2`'s clauses:

```elixir
  @doc """
  Advisory check: list unsupported/overstated/risky claims in `text` with how to
  strengthen them. Returns `{:ok, %{claims: [%{"claim"=>, "issue"=>, "suggestion"=>}]}}`
  (possibly empty). Read-only — there is no "apply".
  """
  @spec check_claims(String.t()) :: result()
  def check_claims(text) when is_binary(text) do
    with {:ok, raw} <- Client.generate(claims_prompt(text)),
         {:ok, claims} <- parse_claims(raw) do
      {:ok, %{claims: claims}}
    end
  rescue
    error ->
      Logger.warning("Assist claim-check crashed: #{inspect(error)}")
      {:error, :crashed}
  end

  def check_claims(_), do: {:error, :invalid}

  defp parse_claims(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{"claims" => list}} when is_list(list) -> {:ok, coerce_claims(list)}
      _ -> {:error, :invalid}
    end
  end

  defp parse_claims(_), do: {:error, :invalid}

  defp coerce_claims(list) do
    list
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn m ->
      %{
        "claim" => claim_str(m["claim"]),
        "issue" => claim_str(m["issue"]),
        "suggestion" => claim_str(m["suggestion"])
      }
    end)
    |> Enum.reject(&(&1["claim"] == ""))
  end

  defp claim_str(v) when is_binary(v), do: v |> String.trim() |> String.slice(0, @claim_field_limit)
  defp claim_str(_), do: ""
```

Add the prompt builder next to the other prompt builders:

```elixir
  defp claims_prompt(text) do
    """
    You are a fact-checking assistant for a holistic-health news platform.
    Read the PASSAGE and identify health or factual claims that are unsupported,
    overstated, or risky. For each, give the claim, the issue, and a short
    suggestion to strengthen or soften it.
    Return ONLY a JSON object:
    {"claims": [{"claim": "...", "issue": "...", "suggestion": "..."}]}.
    Use an empty array if there are no concerning claims.
    Do not include any text outside the JSON object.

    PASSAGE:
    #{String.slice(text, 0, @input_budget)}
    """
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose exec app mix test test/verscienta/assist_test.exs`
Expected: PASS (whole `Assist` suite green).

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta/assist.ex test/verscienta/assist_test.exs
git commit -m "feat(assist): check_claims/1 advisory claim detection

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Editor — flag gate + per-block assist controls

**Files:**
- Modify: `lib/verscienta_web/live/article_editor_live.ex`
- Test (create): `test/verscienta_web/live/article_editor_assist_test.exs`

This task adds the flag assign, the per-block control row (gated), and an empty
`assist` assign. No async yet — just that the controls render only with the flag
on and only on text blocks.

- [ ] **Step 1: Write the failing test**

Create `test/verscienta_web/live/article_editor_assist_test.exs`:

```elixir
defmodule VerscientaWeb.ArticleEditorAssistTest do
  # async: false — configures the global AI client stub and toggles a global flag.
  use VerscientaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshAuthentication.Plug.Helpers
  alias Verscienta.AI.Client.Stub
  alias Verscienta.Flags

  setup do
    prev = Application.get_env(:verscienta, :ai_client)
    Application.put_env(:verscienta, :ai_client, Stub)
    Stub.reset()

    on_exit(fn ->
      Application.put_env(:verscienta, :ai_client, prev)
      Flags.disable(:writing_assistant)
    end)

    :ok
  end

  defp author(username) do
    Verscienta.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: username <> "@example.com",
      username: username,
      password: "password123",
      password_confirmation: "password123"
    })
    |> Ash.create!(authorize?: false)
  end

  defp sign_in(conn, user),
    do: conn |> Plug.Test.init_test_session(%{}) |> Helpers.store_in_session(user)

  test "flag on: a text block shows assist controls", %{conn: conn} do
    Flags.enable(:writing_assistant)
    conn = sign_in(conn, author("alice"))
    {:ok, lv, _html} = live(conn, ~p"/articles/new")

    lv |> element("button[phx-value-type=paragraph]") |> render_click()

    assert has_element?(lv, "button[phx-click=assist][phx-value-mode=improve]")
    assert has_element?(lv, "button[phx-click=assist][phx-value-mode=check_claims]")
    assert has_element?(lv, "button[phx-click=assist][phx-value-mode='retone:professional']")
  end

  test "flag off: no assist controls", %{conn: conn} do
    conn = sign_in(conn, author("bob"))
    {:ok, lv, _html} = live(conn, ~p"/articles/new")

    lv |> element("button[phx-value-type=paragraph]") |> render_click()

    refute has_element?(lv, "button[phx-click=assist]")
  end

  test "flag on: a non-text block (divider) shows no assist controls", %{conn: conn} do
    Flags.enable(:writing_assistant)
    conn = sign_in(conn, author("carol"))
    {:ok, lv, _html} = live(conn, ~p"/articles/new")

    lv |> element("button[phx-value-type=divider]") |> render_click()

    refute has_element?(lv, "button[phx-click=assist]")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec app mix test test/verscienta_web/live/article_editor_assist_test.exs`
Expected: FAIL — no `button[phx-click=assist]` elements exist yet (first test fails).

- [ ] **Step 3: Implement the assigns + control row**

In `lib/verscienta_web/live/article_editor_live.ex`:

(a) Add an alias near the top (after `alias Verscienta.Content.Category`):

```elixir
  alias Verscienta.Assist
```

(b) In `mount/2`, add two `assign` calls to the pipeline immediately after the
`assign(:category_options, ...)` line:

```elixir
     |> assign(assist: nil, assist_seq: 0)
     |> assign(:assist_enabled?, Verscienta.Flags.enabled?(:writing_assistant, for: socket.assigns.current_user))
```

So the final `mount/2` reads:

```elixir
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:category_options, Category.select_options())
     |> assign(assist: nil, assist_seq: 0)
     |> assign(:assist_enabled?, Verscienta.Flags.enabled?(:writing_assistant, for: socket.assigns.current_user))
     |> allow_upload(:cover,
       accept: ~w(.jpg .jpeg .png .webp .gif),
       max_file_size: 15_000_000,
       max_entries: 1
     )
     |> allow_upload(:block_image,
       accept: ~w(.jpg .jpeg .png .webp .gif),
       max_file_size: 15_000_000,
       max_entries: 1
     )
     |> mount_mode(params)}
  end
```

(c) Add an `assist_block?/1` helper near `block_text/1` (after the `block_text(block)` clause, before the `text_field` attrs):

```elixir
  defp assist_block?(%{"type" => type}),
    do: type in ~w(paragraph heading blockquote callout markdown list)

  defp assist_block?(_), do: false
```

(d) In `render/1`, inside the block loop, add the control row **after** the
textarea `<div :if={block["type"] != "divider"}>...</div>` block and **before**
the `image` upload button. Insert:

```elixir
              <div
                :if={@assist_enabled? and assist_block?(block)}
                class="mt-2 flex flex-wrap items-center gap-2 text-[11px] uppercase tracking-wider text-ink-3"
              >
                <button
                  type="button"
                  phx-click="assist"
                  phx-value-index={index}
                  phx-value-mode="improve"
                  class="border border-line px-2 py-1 hover:text-ink"
                >
                  improve
                </button>
                <span class="text-ink-3/60">tone:</span>
                <button
                  :for={tone <- Assist.tones()}
                  type="button"
                  phx-click="assist"
                  phx-value-index={index}
                  phx-value-mode={"retone:#{tone}"}
                  class="border border-line px-2 py-1 hover:text-ink"
                >
                  {tone}
                </button>
                <button
                  type="button"
                  phx-click="assist"
                  phx-value-index={index}
                  phx-value-mode="check_claims"
                  class="border border-line px-2 py-1 hover:text-zune"
                >
                  check claims
                </button>
              </div>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose exec app mix test test/verscienta_web/live/article_editor_assist_test.exs`
Expected: PASS — the three render/gating tests are green.

Also run the existing editor test to confirm no regression:

Run: `docker compose exec app mix test test/verscienta_web/live/article_editor_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta_web/live/article_editor_live.ex test/verscienta_web/live/article_editor_assist_test.exs
git commit -m "feat(assist): flag-gated per-block assist controls in the editor

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Editor — trigger event, async, and suggestion panel

**Files:**
- Modify: `lib/verscienta_web/live/article_editor_live.ex`
- Test: `test/verscienta_web/live/article_editor_assist_test.exs`

This wires the `assist` event to `start_async`, handles the result, and renders
the loading/done/error panel for `improve`/`retone`.

- [ ] **Step 1: Write the failing test**

Add to `test/verscienta_web/live/article_editor_assist_test.exs` (before the final `end`):

```elixir
  defp stub_generate(json),
    do: Application.put_env(:verscienta, :ai_stub, %{generate: {:ok, json}})

  test "improve runs async and renders the suggestion", %{conn: conn} do
    Flags.enable(:writing_assistant)
    stub_generate(~s({"suggestion": "A much clearer paragraph."}))
    conn = sign_in(conn, author("dave"))
    {:ok, lv, _html} = live(conn, ~p"/articles/new")

    lv |> element("button[phx-value-type=paragraph]") |> render_click()
    render_change(lv, "block_change", %{"block" => %{"0" => "rough draft text"}})

    lv
    |> element("button[phx-click=assist][phx-value-mode=improve]")
    |> render_click()

    html = render_async(lv)
    assert html =~ "A much clearer paragraph."
    assert has_element?(lv, "button[phx-click=assist_apply]")
    assert has_element?(lv, "button[phx-click=assist_dismiss]")
  end

  test "a model error renders the error state", %{conn: conn} do
    Flags.enable(:writing_assistant)
    Application.put_env(:verscienta, :ai_stub, %{generate: {:error, :timeout}})
    conn = sign_in(conn, author("erin"))
    {:ok, lv, _html} = live(conn, ~p"/articles/new")

    lv |> element("button[phx-value-type=paragraph]") |> render_click()
    render_change(lv, "block_change", %{"block" => %{"0" => "text"}})

    lv |> element("button[phx-click=assist][phx-value-mode=improve]") |> render_click()

    html = render_async(lv)
    assert html =~ "Couldn&#39;t generate" or html =~ "Couldn't generate"
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec app mix test test/verscienta_web/live/article_editor_assist_test.exs`
Expected: FAIL — the `assist` event has no handler (LiveView raises / nothing renders the suggestion).

- [ ] **Step 3: Implement the event, async, run dispatch, and panel**

In `lib/verscienta_web/live/article_editor_live.ex`:

(a) Add the handlers. Put them after the existing `handle_event("noop", ...)`
clause (line ~209), before `defp consume_cover`:

```elixir
  def handle_event("assist", %{"index" => index, "mode" => mode_str}, socket) do
    with true <- socket.assigns.assist_enabled?,
         {:ok, i} <- parse_index(index),
         block when not is_nil(block) <- Enum.at(socket.assigns.blocks, i),
         true <- assist_block?(block),
         mode when not is_nil(mode) <- parse_mode(mode_str) do
      text = block_text(block)
      seq = socket.assigns.assist_seq + 1

      socket =
        socket
        |> assign(:assist, %{index: i, mode: mode, seq: seq, status: :loading, result: nil})
        |> assign(:assist_seq, seq)
        |> start_async(:assist, fn -> {seq, run_assist(mode, text)} end)

      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("assist_dismiss", _params, socket) do
    {:noreply, assign(socket, :assist, nil)}
  end

  @impl true
  def handle_async(:assist, {:ok, {seq, result}}, socket) do
    case socket.assigns.assist do
      %{seq: ^seq} = assist ->
        updated =
          case result do
            {:ok, payload} -> %{assist | status: :done, result: payload}
            {:error, _reason} -> %{assist | status: :error, result: nil}
          end

        {:noreply, assign(socket, :assist, updated)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_async(:assist, {:exit, _reason}, socket) do
    case socket.assigns.assist do
      %{status: :loading} = assist ->
        {:noreply, assign(socket, :assist, %{assist | status: :error, result: nil})}

      _ ->
        {:noreply, socket}
    end
  end
```

> Note: `start_async/3` and `handle_async/3` are provided by `Phoenix.LiveView`
> (imported via `use VerscientaWeb, :live_view`); no extra import is needed.

(b) Add the private helpers (near `assist_block?/1`):

```elixir
  defp parse_index(value) do
    case Integer.parse(to_string(value)) do
      {i, _} when i >= 0 -> {:ok, i}
      _ -> :error
    end
  end

  defp parse_mode("improve"), do: :improve
  defp parse_mode("check_claims"), do: :check_claims

  defp parse_mode("retone:" <> tone) do
    case Enum.find(Assist.tones(), &(Atom.to_string(&1) == tone)) do
      nil -> nil
      atom -> {:retone, atom}
    end
  end

  defp parse_mode(_), do: nil

  defp run_assist(:improve, text), do: Assist.improve(text)
  defp run_assist({:retone, tone}, text), do: Assist.retone(text, tone)
  defp run_assist(:check_claims, text), do: Assist.check_claims(text)
```

(c) Render the panel. In `render/1`, inside the block loop, **after** the
control-row `<div>` you added in Task 4 (and before the image upload button),
insert:

```elixir
              <.assist_panel :if={@assist && @assist.index == index} assist={@assist} />
```

(d) Add the `assist_panel/1` function component (near `text_field/1`):

```elixir
  attr :assist, :map, required: true

  defp assist_panel(assigns) do
    ~H"""
    <div class="mt-2 border border-line bg-canvas-3 p-3 text-sm text-ink-2">
      <p :if={@assist.status == :loading} class="text-ink-3">thinking…</p>

      <div :if={@assist.status == :error}>
        <p class="text-politics">Couldn't generate a suggestion.</p>
        <button
          type="button"
          phx-click="assist_dismiss"
          class="mt-2 border border-line px-2 py-1 text-[11px] uppercase tracking-wider hover:text-ink"
        >
          dismiss
        </button>
      </div>

      <div :if={@assist.status == :done and is_map_key(@assist.result, :suggestion)}>
        <p class="whitespace-pre-wrap">{@assist.result.suggestion}</p>
        <div class="mt-2 flex gap-2 text-[11px] uppercase tracking-wider">
          <button
            type="button"
            phx-click="assist_apply"
            class="border border-zune px-2 py-1 text-zune hover:bg-zune hover:text-black"
          >
            apply
          </button>
          <button
            type="button"
            phx-click="assist_dismiss"
            class="border border-line px-2 py-1 text-ink-3 hover:text-ink"
          >
            dismiss
          </button>
        </div>
      </div>

      <div :if={@assist.status == :done and is_map_key(@assist.result, :claims)}>
        <p :if={@assist.result.claims == []} class="text-ink-3">No concerns found.</p>
        <ul :if={@assist.result.claims != []} class="space-y-3">
          <li :for={claim <- @assist.result.claims} class="border-l-2 border-line pl-3">
            <p class="font-medium text-ink">{claim["claim"]}</p>
            <p :if={claim["issue"] != ""} class="text-ink-3">{claim["issue"]}</p>
            <p :if={claim["suggestion"] != ""} class="text-zune">{claim["suggestion"]}</p>
          </li>
        </ul>
        <button
          type="button"
          phx-click="assist_dismiss"
          class="mt-2 border border-line px-2 py-1 text-[11px] uppercase tracking-wider text-ink-3 hover:text-ink"
        >
          dismiss
        </button>
      </div>
    </div>
    """
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose exec app mix test test/verscienta_web/live/article_editor_assist_test.exs`
Expected: PASS (suggestion + error tests green).

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta_web/live/article_editor_live.ex test/verscienta_web/live/article_editor_assist_test.exs
git commit -m "feat(assist): async assist trigger + suggestion/error panel

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Editor — Apply, claim-check render, and flag-off no-op

**Files:**
- Modify: `lib/verscienta_web/live/article_editor_live.ex`
- Test: `test/verscienta_web/live/article_editor_assist_test.exs`

Adds the `assist_apply` handler (write the suggestion back into the block),
verifies the claim-check advisory render, and verifies a crafted `assist` event
is a no-op when the flag is off.

- [ ] **Step 1: Write the failing test**

Add to `test/verscienta_web/live/article_editor_assist_test.exs` (before the final `end`):

```elixir
  test "apply replaces the block text and updates the preview", %{conn: conn} do
    Flags.enable(:writing_assistant)
    stub_generate(~s({"suggestion": "Polished sentence."}))
    conn = sign_in(conn, author("frank"))
    {:ok, lv, _html} = live(conn, ~p"/articles/new")

    lv |> element("button[phx-value-type=paragraph]") |> render_click()
    render_change(lv, "block_change", %{"block" => %{"0" => "rough draft"}})

    lv |> element("button[phx-click=assist][phx-value-mode=improve]") |> render_click()
    render_async(lv)

    html = lv |> element("button[phx-click=assist_apply]") |> render_click()

    # the suggestion is now the textarea content AND in the live preview
    assert html =~ "Polished sentence."
    # the assist panel closed (no apply button anymore)
    refute has_element?(lv, "button[phx-click=assist_apply]")

    # persist and confirm the block stored the applied text
    lv
    |> form("#article-form", form: %{"title" => "Applied", "category" => "movement", "tags" => ""})
    |> render_change()

    lv |> element("button", "save draft") |> render_click()

    require Ash.Query

    article =
      Verscienta.Content.Article
      |> Ash.Query.filter(title == "Applied")
      |> Ash.read_one!(authorize?: false)

    [block] = article.blocks
    assert block["data"]["text"] == "Polished sentence."
  end

  test "check claims renders the advisory list", %{conn: conn} do
    Flags.enable(:writing_assistant)
    stub_generate(~s({"claims": [
      {"claim": "Cures everything", "issue": "overstated", "suggestion": "soften it"}
    ]}))
    conn = sign_in(conn, author("grace"))
    {:ok, lv, _html} = live(conn, ~p"/articles/new")

    lv |> element("button[phx-value-type=paragraph]") |> render_click()
    render_change(lv, "block_change", %{"block" => %{"0" => "It cures everything."}})

    lv |> element("button[phx-click=assist][phx-value-mode=check_claims]") |> render_click()

    html = render_async(lv)
    assert html =~ "Cures everything"
    assert html =~ "overstated"
    assert html =~ "soften it"
    # advisory has no apply button
    refute has_element?(lv, "button[phx-click=assist_apply]")
  end

  test "flag off: a crafted assist event is a no-op", %{conn: conn} do
    stub_generate(~s({"suggestion": "should not appear"}))
    conn = sign_in(conn, author("heidi"))
    {:ok, lv, _html} = live(conn, ~p"/articles/new")

    lv |> element("button[phx-value-type=paragraph]") |> render_click()
    render_change(lv, "block_change", %{"block" => %{"0" => "text"}})

    # craft the event directly (the UI control isn't rendered when the flag is off)
    render_hook(lv, "assist", %{"index" => "0", "mode" => "improve"})

    html = render_async(lv)
    refute html =~ "should not appear"
    assert Stub.calls() == []
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec app mix test test/verscienta_web/live/article_editor_assist_test.exs`
Expected: FAIL — `assist_apply` has no handler (apply test fails; claim render may already pass from Task 5; flag-off test should already pass).

- [ ] **Step 3: Implement `assist_apply`**

In `lib/verscienta_web/live/article_editor_live.ex`, add after the
`handle_event("assist_dismiss", ...)` clause:

```elixir
  def handle_event("assist_apply", _params, socket) do
    if socket.assigns.assist_enabled? do
      case socket.assigns.assist do
        %{status: :done, index: i, result: %{suggestion: suggestion}}
        when is_binary(suggestion) ->
          blocks = update_block_text(socket.assigns.blocks, i, suggestion)
          {:noreply, socket |> assign_blocks(blocks) |> assign(:assist, nil)}

        _ ->
          {:noreply, assign(socket, :assist, nil)}
      end
    else
      {:noreply, socket}
    end
  end
```

> `update_block_text/3` (already in this module) handles every text block:
> list-blocks split on newlines, all others write `data[primary_field]`. The
> claim-check result has no `:suggestion` key, so a stray apply on an advisory
> panel just closes it.

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose exec app mix test test/verscienta_web/live/article_editor_assist_test.exs`
Expected: PASS (all assist editor tests green).

- [ ] **Step 5: Commit**

```bash
git add lib/verscienta_web/live/article_editor_live.ex test/verscienta_web/live/article_editor_assist_test.exs
git commit -m "feat(assist): apply suggestion into block + claim-check render

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Full verification + docs

**Files:**
- Modify: `docs/todo.md`

- [ ] **Step 1: Format + compile (warnings as errors)**

Run: `docker compose exec app mix format && docker compose exec app mix compile --warnings-as-errors`
Expected: clean, no warnings.

- [ ] **Step 2: Run the focused suites**

Run: `docker compose exec app mix test test/verscienta/assist_test.exs test/verscienta_web/live/article_editor_assist_test.exs test/verscienta_web/live/article_editor_live_test.exs`
Expected: PASS, 0 failures.

- [ ] **Step 3: Run the full test suite**

Run: `docker compose exec app mix test`
Expected: PASS (no regressions). If any unrelated seed-contamination failures appear, see the project memory on test DB seed contamination.

- [ ] **Step 4: Check off the todo item**

In `docs/todo.md`, find the Moderation & Trust line:

```
- [ ] AI writing assistant for authors (draft help, tone, claim-checking).
```

Change it to:

```
- [x] AI writing assistant for authors (draft help, tone, claim-checking).
```

- [ ] **Step 5: Commit**

```bash
git add docs/todo.md
git commit -m "docs(assist): check off AI writing assistant todo item

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review Notes

**Spec coverage:**
- `Verscienta.Assist` engine (improve/retone/check_claims, JSON parse, best-effort) → Tasks 1–3.
- Fixed tone set + validation → Task 2.
- Per-block flag-gated controls, text-blocks-only → Task 4.
- `start_async`/`handle_async`, loading/done/error panel, stale-result guard (`seq`) → Task 5.
- One-click Apply writes back via `update_block_text`; claim-check advisory (no apply); Dismiss → Tasks 5–6.
- Flag re-check in handlers (defense in depth) + crafted-event no-op → Tasks 5–6.
- Tests for engine (stub) + editor (`render_async`) → every task.
- Todo check-off + verification → Task 7.

**Out of scope (per spec), intentionally absent:** whole-draft assist, streaming, assist history/persistence, non-text blocks, freeform tone, auto-setting `evidence_level`. No migration, no new resource, no Oban worker, no new flag (`:writing_assistant` already exists, seeded off).
