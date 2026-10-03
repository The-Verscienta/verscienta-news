defmodule VerscientaNews.Blocks.WellnessCallout do
  @moduledoc """
  Wellness callout block — Codex-gated visual for TCM/Ayurveda tips, herbal
  cautions, and mindfulness prompts. Renders as a token-driven card with
  ember accent, stays accessible in light/dark.
  """

  use Kiln.Block,
    type: :wellness_callout,
    version: 1

  field :variant, :string, default: "tip", constraints: [one_of: ~w[tip caution recipe practice]]
  field :title, :string, allow_nil?: true
  field :body, :string, allow_nil?: false
  field :category, :string, allow_nil?: true

  @impl Kiln.Block.Renderer
  def render(%{variant: variant, title: title, body: body}, :web) do
    variant_class =
      case variant do
        "caution" -> "border-warning/30 bg-warning/10"
        "recipe" -> "border-success/20 bg-success/5"
        "practice" -> "border-primary/20 bg-primary/5"
        _ -> "border-base-content/10 bg-base-200/50"
      end

    title_html =
      if title do
        "<strong class=\"block text-sm font-semibold\">#{title}</strong>"
      else
        ""
      end

    """
    <aside class="card p-4 #{variant_class} border my-4">
      #{title_html}
      <p class="text-sm leading-relaxed text-base-content/80">#{body}</p>
    </aside>
    """
    |> Phoenix.HTML.raw()
  end

  def render(data, :json), do: Map.from_struct(data)
  def render(_data, :json_ld), do: nil
  def render(_data, _surface), do: nil
end
