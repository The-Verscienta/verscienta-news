defmodule VerscientaNews.Catalog.Article do
  @moduledoc """
  Core article for Verscienta News. Built on `KilnCMS.CMS.Content` so it
  inherits blocks (Portable Text), workflow (draft → in_review → published →
  archived), PaperTrail, and fired-artefact delivery.

  Wellness categories: nutrition, herbalism, mindfulness, movement,
  functional_medicine, tcm, ayurveda, environment.

  The public path is this type's alias, `/[field:category]/[slug]`.
  Workflow states are Kiln's: `draft`, `in_review`, `published`, `archived`.

  Source license and attribution are applied by
  `VerscientaNews.Ingestion.Poller.apply_license/1` from
  `VerscientaNews.Ingestion.Allowlist` before a body is stored.
  `claim_status` for Slice 1 is `unreviewed`, `flagged`, or `cleared`.
  The medical disclaimer is fired-template copy, not a stored acknowledgement.
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
