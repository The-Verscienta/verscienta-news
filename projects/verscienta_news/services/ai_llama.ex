defmodule VerscientaNews.AI.Llama do
  @moduledoc """
  Ollama Llama client stub. Set `OLLAMA_URL=http://ollama:11434` (or
  `http://localhost:11434` in dev). Prompts are intentionally short for
  determinism; expand with few-shot examples when quality_score needs tuning.
  """

  @ollama_url System.get_env("OLLAMA_URL", "http://localhost:11434")

  def enrich(%VerscientaNews.Ingestion.Pipeline.NormalizedArticle{} = doc) do
    with {:ok, summary} <- summarize(doc.html),
         {:ok, tags} <- tag(doc.html),
         {:ok, quality} <- score(doc) do
      {:ok, %{ai_summary: summary, ai_tags: tags, quality_score: quality}}
    end
  end

  def summarize(html) when is_binary(html) do
    # Real: Req.post!("#{@ollama_url}/api/generate", json: %{model: "llama3.1", prompt: "..."})
    {:ok, String.slice(html, 0, 200)}
  end

  def tag(_html), do: {:ok, ["wellness"]}

  def score(_doc), do: {:ok, 75}

  def toxicity(_text), do: {:ok, %{toxic: false, reasons: []}}
end
