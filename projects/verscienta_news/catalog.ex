defmodule VerscientaNews.Catalog do
  @moduledoc """
  Verscienta News content catalog — layered on KilnCMS core.

  Holds the wellness publishing domain. Each resource is built on
  `KilnCMS.CMS.Content` with `domain: __MODULE__`, inheriting block editor,
  workflow, versioning, search, and firing. Core stays dormant until this
  domain is registered in `config/project.exs`.
  """

  use Ash.Domain,
    validate_config_inclusion?: false,
    extensions: [AshJsonApi.Domain, AshGraphql.Domain, AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource VerscientaNews.Catalog.Article do
      define :list_articles, action: :read
      define :get_article, action: :read, get_by: [:id]
      define :get_published_article_by_slug, action: :public_by_slug, args: [:slug, :locale]
      define :search_articles, action: :search, args: [:query]
      define :create_article, action: :create
      define :update_article, action: :update
      define :submit_article_for_review, action: :submit_for_review
      define :return_article_to_draft, action: :return_to_draft
      define :publish_article, action: :publish
      define :publish_scheduled_article, action: :publish_scheduled
      define :unpublish_article, action: :unpublish
      define :archive_article, action: :archive
      define :unarchive_article, action: :unarchive
      define :restore_article_version, action: :restore_version
      define :destroy_article, action: :destroy
      define :list_trashed_articles, action: :trashed
      define :restore_article, action: :restore
      define :purge_article, action: :purge
      define :list_published_articles, action: :published
    end

    resource VerscientaNews.Catalog.Article.Version do
      define :list_article_versions, action: :read
    end
  end
end
