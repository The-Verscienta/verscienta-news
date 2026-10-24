defmodule VerscientaNews.AI.Llama do
  @moduledoc """
  Ollama Llama client — advisory only. `quality_score` never gates publish
  (see `docs/ingestion.md`). Separate contracts: `toxicity_flag` (bool) vs
  `claim_status` (`:unreviewed`|:flagged). Failing open = item waits in review queue.
  """

  @ollama_url System.get_env("OLLAMA_URL", "http://localhost:11434")

  def enrich(%VerscientaNews.Ingestion.Poller.NormalizedArticle{} = doc) do
    with {:ok, summary} <- summarize(doc.html),
         {:ok, tags} <- tag(doc.html),
         {:ok, advisory} <- score(doc) do
      {:ok, %{ai_summary: summary, ai_tags: tags, advisory_score: advisory.advisory_score, claim_status: :unreviewed, toxicity_flag: false}}
    end
  end

  def summarize(html) when is_binary(html) do
    # Real: Req.post!("#{@ollama_url}/api/generate", json: %{model: "llama3.1", prompt: "Summarize 2–3 sentences: ..."})
    {:ok, String.slice(html, 0, 200)}
  end

  def tag(_html), do: {:ok, ["wellness"]}

  # Advisory only — not a publish threshold. Old `{:ok, 75}` (threshold) removed.
  def score(_doc), do: {:ok, %{advisory_score: 0, reasons: ["stub — advisory only"]}}

  def toxicity(_text), do: {:ok, %{toxicity_flag: false, claim_status: :unreviewed, reasons: []}}
end
