defmodule VerscientaNews.Ingestion.Allowlist do
  @moduledoc """
  Sources the poller may fetch. `docs/source-rights.md` mirrors this list.
  A host that is not here is not polled.
  """

  @excerpt_chars 280

  @sources [
    %{
      url: "https://example.com/nutrition.rss",
      license: :excerpt_link,
      attribution_text: "Via Example Nutrition — read more at source",
      robots: :respect,
      robots_notes: "Placeholder. Do not poll a real publisher until this row is replaced.",
      owner_contact: "takedown@verscienta.example",
      takedown_sla: "2 business days"
    }
  ]

  @required [
    :url,
    :license,
    :attribution_text,
    :robots,
    :robots_notes,
    :owner_contact,
    :takedown_sla
  ]

  @licenses [:full_text, :excerpt_link, :link_only]

  def sources, do: @sources

  def excerpt_chars, do: @excerpt_chars

  def required_keys, do: @required

  def licenses, do: @licenses

  def get_by_host(url) when is_binary(url) do
    case host(url) do
      nil -> nil
      host -> Enum.find(@sources, fn source -> host(source.url) == host end)
    end
  end

  def get_by_host(_), do: nil

  def allowlisted?(url), do: match?(%{}, get_by_host(url))

  defp host(url) do
    url
    |> URI.parse()
    |> Map.get(:host)
  end
end
