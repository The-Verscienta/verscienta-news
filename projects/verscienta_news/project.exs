import Config

# Activation for Verscienta News overlay (see kiln_cms/projects/README.md).
# Restates core domains (required — config REPLACES, not merges) and appends overlays.

config :kiln_cms,
  ash_domains: [
    KilnCMS.Accounts,
    KilnCMS.CMS,
    KilnCMS.Analytics,
    KilnCMS.Firing,
    KilnCMS.History,
    KilnCMS.SearchIndex,
    KilnCMS.Mail,
    KilnCMS.Notifications,
    KilnCMS.Newsletter,
    KilnCMS.Automation,
    KilnCMS.Billing,
    KilnCMS.Federation,
    KilnCMS.Experiments,
    KilnCMS.Social,
    VerscientaNews.Catalog
  ],
  content_domains: [KilnCMS.CMS, VerscientaNews.Catalog],
  plugins: [VerscientaNews.Plugin]
