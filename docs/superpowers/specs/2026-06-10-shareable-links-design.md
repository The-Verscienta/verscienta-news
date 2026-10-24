# Shareable Links (Referral-Attributed) — Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-10
**Phase:** 3 — Intelligence & Growth › Growth
**Todo item:** `[~] Shareable links + social card images.` — social cards are done;
this completes the **shareable links** half.

## Goal

Give readers a first-class way to share an article outward, and turn each share
into a growth loop: a shared link carries the sharer's existing referral code, so
a resulting signup credits them through the referral system already in place. The
share control offers copy-link, the native mobile share sheet, and X / Facebook /
email targets. Pasted links already render a rich preview (OG cards + SEO meta are
done).

## Decisions (from brainstorming)

- **Referral-attributed shares** (not just a bare share affordance, not a tracked
  short-link resource): the share link is the article URL plus the sharer's
  referral code.
- **Link mechanism:** `/articles/:slug?ref=CODE` — reuses the existing
  `CaptureReferral` plug + referral cookie + signup-capture. **No new resource,
  route, redirect controller, plug, or migration.**
- **Share targets:** copy link (clipboard + confirmation), native share (Web Share
  API where available), and explicit **X**, **Facebook**, **email** targets.
- **Surface:** article reader action row only (feed cards render no actions today).
- **Unflagged:** an additive UI affordance, consistent with social cards / SEO
  being unflagged. The `?ref=` tag is only appended when the `:referrals` flag is
  on for the sharer (no attribution to make otherwise).

## Background (current state)

- `VerscientaWeb.Plugs.CaptureReferral` (`lib/verscienta_web/plugs/capture_referral.ex`)
  is **already in the `:browser` pipeline** (`router.ex:16`). It reads `?ref=<code>`
  from any browser request and writes a 30-day `verscienta_ref` HttpOnly/Lax cookie
  (`put_referral_cookie/2`). The `/r/:code` controller reuses the same function.
- Signup-time `Verscienta.Gamification.Referrals.capture/4` credits the referrer
  from that cookie. So `/articles/:slug?ref=CODE` already attributes a signup with
  zero new backend.
- `User.referral_code` (`accounts/user.ex:623`, `allow_nil?: true`, unique) is
  generated **lazily** via the system action `:generate_referral_code`
  (`user.ex:391`). Today only `SettingsReferralsLive` generates it, through a
  **private** `ensure_code/1` (`settings_referrals_live.ex:50`).
- `SettingsReferralsLive.share_link/1` (`:71`) builds the `/r/:code`
  acquisition link — distinct from an article share link.
- Article reader action row (`article_reader_live.ex` ~465–507): reaction buttons,
  a **repost** toggle (internal re-share to feeds — distinct from this feature), and
  a **bookmark** toggle (right-aligned via `ml-auto`). The Share control goes in
  this row.
- `Verscienta.Analytics` (`analytics.ex`): server-side PostHog via
  `Analytics.Client` (`:analytics_client` app-env, with a test stub
  `test/support/analytics_client_stub.ex`). Pattern:
  `track_article_view(article, distinct_id)` → `capture("article_viewed", id, %{...})`.
  `Analytics.distinct_id(current_user, analytics_id)` resolves the id.
- JS hooks live in `assets/js/app.js`, registered in the `Hooks` object merged into
  the `LiveSocket` (`BlockReorder`, `ReadingTimer` are the models to follow).

## Architecture

### 1. `Referrals.ensure_code/1` (promote + reuse)

Move the lazy code-generation out of the LiveView into the context so both callers
share it.

- Add to `lib/verscienta/gamification/referrals.ex`:
  ```elixir
  @doc """
  Return `user` guaranteed to have a `referral_code`, generating + persisting one
  (system action :generate_referral_code) if it is nil.
  """
  def ensure_code(%Verscienta.Accounts.User{referral_code: code} = user)
      when is_binary(code) and code != "",
      do: user

  def ensure_code(%Verscienta.Accounts.User{} = user) do
    user
    |> Ash.Changeset.for_update(:generate_referral_code, %{})
    |> Ash.update!(authorize?: false)
  end
  ```
- Refactor `SettingsReferralsLive.ensure_code/1` to delegate to
  `Referrals.ensure_code/1` (remove the duplicated private body; keep behavior).

### 2. Share-URL helper

A small web helper that builds the outbound article URL with optional referral tag.
Place it in `ArticleReaderLive` (private) — it's the only consumer — or, if cleaner,
a tiny `VerscientaWeb.ShareLinks` module. Recommended: private in `ArticleReaderLive`.

```elixir
# Returns {url, maybe_updated_user}. Appends ?ref=<code> only for a signed-in user
# when the :referrals flag is on (ensuring the user has a code); otherwise the plain
# canonical article URL.
defp share_url(article, nil), do: {canonical_article_url(article), nil}

defp share_url(article, %User{} = user) do
  if Verscienta.Flags.enabled?(:referrals, for: user) do
    user = Verscienta.Gamification.Referrals.ensure_code(user)
    {canonical_article_url(article) <> "?ref=" <> user.referral_code, user}
  else
    {canonical_article_url(article), user}
  end
end

defp canonical_article_url(article), do: url(~p"/articles/#{article.slug}")
```

`open_share` (below) calls this, assigns `share_url`, and re-assigns
`current_user` to the (possibly code-bearing) user so a later share in the same
session doesn't regenerate.

### 3. Share control in `ArticleReaderLive`

- **State:** assigns `share_open: false`, `share_url: nil` (init in mount).
- **Button:** in the action row, after the repost button, a `Share` button:
  `phx-click="open_share"`. Always shown (even anonymous).
- **`handle_event("open_share", _, socket)`:** compute `{url, user} = share_url(@article, @current_user)`; assign `share_open: true, share_url: url, current_user: user`.
- **`handle_event("close_share", _, socket)`:** `share_open: false`.
- **`handle_event("track_share", %{"method" => method}, socket)`:** when `method`
  is one of `~w(copy native x facebook email)`, call
  `Analytics.track_share(@article, Analytics.distinct_id(@current_user, @analytics_id), method)`;
  always `{:noreply, socket}` (best-effort; ignore unknown methods).
- **Popover markup** (`:if={@share_open}`), rendered with the resolved `@share_url`
  and wired to a `Share` JS hook:
  - Root element carries `phx-hook="Share"`, `data-share-url={@share_url}`,
    `data-share-title={@article.title}`.
  - **Copy link** button (`data-share-action="copy"`) — hook copies + shows a
    transient "copied" state + pushes `track_share` `copy`.
  - **Native share** button (`data-share-action="native"`) — hook calls
    `navigator.share`; the hook hides this button when `navigator.share` is absent;
    pushes `track_share` `native`.
  - **X** / **Facebook** / **email** links — plain `<a target="_blank" rel="noopener">`
    with intent URLs (built server-side from `@share_url` + title) and
    `data-share-method` so the hook pushes the matching `track_share` on click:
    - X: `https://twitter.com/intent/tweet?url=<enc(share_url)>&text=<enc(title)>`
    - Facebook: `https://www.facebook.com/sharer/sharer.php?u=<enc(share_url)>`
    - email: `mailto:?subject=<enc(title)>&body=<enc(share_url)>`
  - Style: match the action row's Codex tokens (`text-[11px] uppercase tracking-wider`,
    `border-line`, `bg-canvas-2/3`); a click-outside / `close_share` affordance like
    the existing report-dialog modal pattern.

### 4. `Share` JS hook (`assets/js/app.js`)

Register alongside `BlockReorder`:
```javascript
Hooks.Share = {
  mounted() {
    const url = this.el.dataset.shareUrl
    const title = this.el.dataset.shareTitle || ""

    // Hide native-share button if the API is unavailable.
    const nativeBtn = this.el.querySelector('[data-share-action="native"]')
    if (nativeBtn && !navigator.share) nativeBtn.style.display = "none"

    this.el.addEventListener("click", async (e) => {
      const action = e.target.closest("[data-share-action]")?.dataset.shareAction
      const method = e.target.closest("[data-share-method]")?.dataset.shareMethod

      if (action === "copy") {
        e.preventDefault()
        try {
          await navigator.clipboard.writeText(url)
          this.pushEvent("track_share", {method: "copy"})
          // transient "copied" feedback (toggle a data attr / text)
        } catch (_) {}
      } else if (action === "native" && navigator.share) {
        e.preventDefault()
        try {
          await navigator.share({title, url})
          this.pushEvent("track_share", {method: "native"})
        } catch (_) {}
      } else if (method) {
        // social anchors: let the link open, just record the method
        this.pushEvent("track_share", {method})
      }
    })
  },
}
```
(The control is rendered directly in `ArticleReaderLive`, so `this.pushEvent(...)`
routes to its `handle_event("track_share", ...)`.)

### 5. `Analytics.track_share/3`

Add to `lib/verscienta/analytics.ex`, mirroring `track_article_view/2`:
```elixir
def track_share(article, distinct_id, method) do
  capture("article_shared", distinct_id, %{
    "article_id" => to_string(article.id),
    "category" => to_string(article.category),
    "method" => to_string(method)
  })
end
```

## Testing

- **`Referrals.ensure_code/1`:** a user with `referral_code: nil` gets a generated,
  persisted code; a user that already has one is returned unchanged (no new code).
- **`SettingsReferralsLive`** still shows a code after the delegation refactor
  (existing test should stay green; add one only if coverage is missing).
- **Share URL:** signed-in user with `:referrals` enabled → the share URL ends with
  `?ref=<that user's code>` and the user now has a code; with `:referrals` disabled,
  or anonymous → the plain `/articles/:slug` (no `?ref=`). (Unit-test the helper, or
  assert through the LiveView's rendered anchors.)
- **LiveView (`ArticleReaderLive`):**
  - The Share button renders for both a signed-in user and an anonymous conn.
  - `open_share` reveals the popover with Copy / native / X / Facebook / email
    controls; a signed-in user (referrals on) sees the X/email/Facebook hrefs
    carrying `ref=<code>`; an anonymous viewer's hrefs carry no `ref`.
  - `track_share` with a valid method records an `article_shared` capture (assert via
    the `Analytics.Client` stub — see `test/verscienta_web/live/analytics_liveview_test.exs`
    for the stub-config + recorded-call pattern); an unknown method is a no-op.
- **Attribution (light):** an article path with `?ref=<code>` sets the
  `verscienta_ref` cookie — already covered by `CaptureReferral` plug tests; add a
  single confirmation only if the existing coverage doesn't already assert it for an
  arbitrary path.

## Out of scope (later)

- A `ShareableLink` resource, `/s/:id` short URLs, and per-link click counts (the
  link-mechanism decision deferred these; referral credit is per-user-code and needs
  none of them).
- Share affordances on feed/listing cards (no action row there today).
- Visible share counts, QR codes, "copy with quote", and share-to-LinkedIn/WhatsApp/
  Reddit (native share covers the long tail on mobile).
- Backfilling `referral_code` for all users at registration (generated lazily on
  first share / settings visit).

## Files touched (summary)

- `lib/verscienta/gamification/referrals.ex` — `ensure_code/1`.
- `lib/verscienta_web/live/settings_referrals_live.ex` — delegate to it.
- `lib/verscienta/analytics.ex` — `track_share/3`.
- `lib/verscienta_web/live/article_reader_live.ex` — share assigns, `open_share` /
  `close_share` / `track_share` handlers, `share_url/2` helper, popover markup +
  Share button.
- `assets/js/app.js` — `Share` hook.
- Tests across the above (using `Verscienta.Support.Factory` + the analytics stub).
- No new resource, route, plug, controller, migration, or feature flag.
