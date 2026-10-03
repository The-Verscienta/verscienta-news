defmodule VerscientaNews.Recommendation do
  @moduledoc """
  Hybrid For You stub: RRF fusion of Meilisearch + pgvector + collaborative.
  Wire `list_for_you/2` to frontend `GET /api/for_you`.
  """

  def list_for_you(user_id, opts \\ []) when is_binary(user_id) do
    # Real: merge Meilisearch keyword hits + pgvector block embeddings (Kiln D16)
    # + collaborative (read_dwell, saves, follows) with RRF k=60.
    {:ok, []}
  end
end
