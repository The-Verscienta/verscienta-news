defmodule VerscientaNews.AllowlistTest do
  use ExUnit.Case, async: true

  alias VerscientaNews.Ingestion.Allowlist
  alias VerscientaNews.Ingestion.Poller
  alias VerscientaNews.Ingestion.Poller.NormalizedArticle

  test "every registry entry has the source-rights columns" do
    assert Allowlist.sources() != []

    for source <- Allowlist.sources() do
      for key <- Allowlist.required_keys() do
        assert Map.has_key?(source, key), "missing #{key} on #{source.url}"
        assert source[key] not in [nil, ""]
      end

      assert source.license in Allowlist.licenses()
      assert source.robots == :respect
    end
  end

  test "the placeholder host is allowlisted and an unknown host is not" do
    assert Poller.allowlisted?("https://example.com/nutrition.rss")
    refute Poller.allowlisted?("https://evil.example/feed.xml")
    refute Poller.allowlisted?(nil)
  end

  test "excerpt_link stores plain text no longer than 280 characters" do
    html = "<p>" <> String.duplicate("word ", 200) <> "</p>"

    doc = %NormalizedArticle{
      source_url: "https://example.com/nutrition/story",
      html: html
    }

    assert {:ok, prepared} = Poller.apply_license(doc)
    assert prepared.source_license == :excerpt_link
    assert prepared.attribution_text == "Via Example Nutrition — read more at source"
    assert prepared.robots_policy == :respect
    assert is_binary(prepared.html)
    assert String.length(prepared.html) <= Allowlist.excerpt_chars()
    refute String.contains?(prepared.html, "<")
  end

  test "an unknown host is not given a body to store" do
    doc = %NormalizedArticle{source_url: "https://evil.example/post", html: "<p>full</p>"}
    assert {:error, :not_allowlisted} = Poller.apply_license(doc)
  end

  test "excerpt strips tags and caps length at 280" do
    assert Poller.excerpt("<p>Hello <b>there</b></p>") == "Hello there"
    long = String.duplicate("a", 500)
    assert String.length(Poller.excerpt(long)) == 280
  end
end
