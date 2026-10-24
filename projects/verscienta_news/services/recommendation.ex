defmodule VerscientaNews.Recommendation do
  @moduledoc """
  Deferred past Slice 1. RRF across Meilisearch/pgvector/collaborative has no
  cold-start spec — see `docs/plan-critique.md:defer`. Wire only after `slice-1.md`
  exit: reuse Kiln D16 block embeddings, define `Recommendation` row, and spec
  what "For You" shows for a new reader (Kiln FTS fallback).
  """

  def list_for_you(_user_id, _opts \\ []), do: {:ok, []}
end
