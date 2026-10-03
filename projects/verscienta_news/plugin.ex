defmodule VerscientaNews.Plugin do
  @moduledoc """
  Verscienta News plugin — entry point for everything layered on KilnCMS core.

  Declares content domain, blocks, field types, and nav for
  `mix kiln.plugins.doctor`. Activation happens in `config/project.exs`.
  """

  use Kiln.Plugin

  @impl true
  def name, do: "verscienta_news"

  @impl true
  def domains, do: [VerscientaNews.Catalog]

  @impl true
  def blocks, do: [VerscientaNews.Blocks.WellnessCallout]

  @impl true
  def field_types, do: []
end
