defmodule VerscientaNews.Ingestion.Pipeline do
  @moduledoc """
  Broadway stub for RSS/API/HTML aggregation.

  Enable by adding `{:broadway, "~> 1.1"}` + parsers to the overlay deps and
  implementing `Broadway.handle_message/3`. Until then this module exposes the
  normalization contract and is safe to compile.
  """

  defmodule NormalizedArticle do
    defstruct [:url, :title, :html, :published_at, :source, :category_guess, :raw]
  end

  @doc "Dedupe key for a normalized article."
  def dedupe_key(%NormalizedArticle{url: url, title: title}) do
    :crypto.hash(:sha256, "#{url}::#{title}") |> Base.encode16(case: :lower)
  end

  @doc "Category guess from URL/tags — extend with Llama tagging later."
  def guess_category(%NormalizedArticle{url: url}) do
    cond do
      String.contains?(url, "herb") -> "herbalism"
      String.contains?(url, "mindfulness") -> "mindfulness"
      String.contains?(url, "tcm") -> "tcm"
      true -> "nutrition"
    end
  end
end
