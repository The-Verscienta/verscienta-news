defmodule VerscientaNews.Ingestion.Poller do
  @moduledoc """
  Slice 1 poller. Oban cron plus Req. No Broadway.

  `apply_license/1` truncates or drops the body before anything is stored.
  See `docs/ingestion.md` and `VerscientaNews.Ingestion.Allowlist`.
  """

  alias VerscientaNews.Ingestion.Allowlist

  defmodule NormalizedArticle do
    defstruct [
      :source_url,
      :title,
      :html,
      :published_at,
      :source,
      :source_license,
      :attribution_text,
      :robots_policy,
      :raw
    ]
  end

  @doc "Dedupe key is canonical `source_url`."
  def dedupe_key(%NormalizedArticle{source_url: url}), do: url

  @doc "True when the URL host is in `Allowlist`."
  def allowlisted?(url), do: Allowlist.allowlisted?(url)

  @doc """
  Copy license fields from the registry and shape `html` before storage.

  `full_text` keeps the body. `excerpt_link` keeps at most 280 characters of
  plain text. `link_only` keeps no body. An unknown host returns
  `{:error, :not_allowlisted}` and no body.
  """
  def apply_license(%NormalizedArticle{source_url: url} = doc) do
    case Allowlist.get_by_host(url) do
      nil ->
        {:error, :not_allowlisted}

      source ->
        {:ok,
         %{
           doc
           | html: body_for(source.license, doc.html),
             source_license: source.license,
             attribution_text: source.attribution_text,
             robots_policy: source.robots
         }}
    end
  end

  @doc "Plain-text excerpt used for `excerpt_link` sources."
  def excerpt(nil), do: nil

  def excerpt(html) when is_binary(html) do
    html
    |> String.replace(~r/<[^>]*>/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, Allowlist.excerpt_chars())
  end

  @doc "Category guess from the URL. Deterministic until tagging exists."
  def guess_category(%NormalizedArticle{source_url: url}) do
    cond do
      String.contains?(url, "herb") -> "herbalism"
      String.contains?(url, "mindfulness") -> "mindfulness"
      String.contains?(url, "tcm") -> "tcm"
      true -> "nutrition"
    end
  end

  defp body_for(:full_text, html), do: html
  defp body_for(:excerpt_link, html), do: excerpt(html)
  defp body_for(:link_only, _html), do: nil
end

defmodule VerscientaNews.Ingestion.Pipeline do
  @moduledoc "Backward-compat alias. Use `VerscientaNews.Ingestion.Poller`."
  defdelegate dedupe_key(arg), to: VerscientaNews.Ingestion.Poller
  defdelegate guess_category(arg), to: VerscientaNews.Ingestion.Poller
  defdelegate allowlisted?(url), to: VerscientaNews.Ingestion.Poller
  defdelegate apply_license(doc), to: VerscientaNews.Ingestion.Poller
end
