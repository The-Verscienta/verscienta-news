defmodule VerscientaNews.Catalog.Article do
  @moduledoc """
  Core article for Verscienta News. Built on `KilnCMS.CMS.Content` so it
  inherits blocks (Portable Text), workflow (draft → in_review → published →
  archived), PaperTrail, and fired-artefact delivery.

  Wellness categories map to a custom `category` field plus `tags`:
  Nutrition, Herbalism, Mindfulness, Movement, Functional Medicine, TCM,
  Ayurveda, Environment and extensible others.

  Aggregation metadata (source_url, quality_score, ai_summary) are stored as
  custom fields so they remain queryable without a separate table.
  """

  use KilnCMS.CMS.Content,
    type: :article,
    plural: :articles,
    domain: VerscientaNews.Catalog,
    excerpt?: true,
    schema_org_type: "NewsArticle",
    alias_pattern: "/[field:category]/[slug]",
    seo_title_pattern: "[title] · Verscienta News",
    seo_description_pattern: "[excerpt]"
end
