# Communities & Groups Design

> **Historical — standalone Verscienta app.** This file describes `Verscienta.*` LiveView work. It is not the Kiln overlay and it is not Slice 1. Current scope is [`docs/slice-1.md`](../../slice-1.md).


**Date:** 2026-06-03
**Status:** Approved
**Phase:** 2 (Social & Gamification) — Subsystem 5 of 7: Communities & Groups
**Depends on:** Phase 1 (Accounts, Content) + Phase 2 Media (optional). Reuses the Follow
join/toggle pattern, Article authoring + comments, the slug generator, role-in-policy patterns,
and the public/authenticated live_session split.

## Goal

User-created **groups** (public communities + private groups) with per-group roles
(owner/mod/member), join/leave + request + invite flows, group-scoped content (group-tagged
Articles, discussed via the existing comment system), and a public directory. Private-group content
is members-only; **group content is siloed to the group** (not shown in global feeds/search).

## Decisions

| Decision | Choice |
|----------|--------|
| Domain | New `Verscienta.Communities` (`Group`, `GroupMembership`) |
| Visibility | `:public` (open join, public content) / `:private` (members-only content) |
| Roles | `:owner` / `:mod` / `:member` (per-group, on `GroupMembership`) |
| Join flows | Public: open join. Private: **request → approve** AND **invite → accept** (membership `status`) |
| Membership status | `:active` / `:requested` (user-initiated, awaiting mod) / `:invited` (mod-initiated, awaiting user) |
| Content model | Group-tagged **Articles** (optional `Article.group_id`); discussions = existing comments |
| Content isolation | Group articles are **siloed**: excluded from global `/articles`, trending, following, search. Visible only on the group page (private → active members only). |
| Posting rights | **Any active member** can post to the group; owner/mod can remove content + members |
| Ownership transfer | **Included** — owner transfers ownership to an active member (old owner becomes mod), then may leave |
| Deferred | Group notifications/activity events; group avatar/cover images; per-group posting toggle; sub-groups |

## Data model

### `Verscienta.Communities.Group`
- **Attributes:** `name` (≤100), `slug` (auto, unique, collision-retry), `description` (≤1000, nullable),
  `visibility` (atom one_of `[:public, :private]`, default `:public`), timestamps. `belongs_to :owner, User`.
- **Aggregates:** `member_count` (count of active memberships).
- **Actions:**
  - `create` — accepts `name`, `description`, `visibility`; `change relate_actor(:owner)`; generate slug
    (reuse `Content.Slug.slugify` + around-transaction retry); after-action creates the creator's
    `GroupMembership` with `role: :owner, status: :active`.
  - `update` — accepts `name`, `description`, `visibility`; **owner-only**.
  - `destroy` — **owner-only** (cascades memberships + nulls article group_id; see Articles).
  - reads: `:list_public` (visibility == :public, newest/most-members), `:get_by_slug` (`get? true`),
    default `:read`.
- **Policies:** read public (anyone may read group rows — visibility gates *content*, not the group's
  existence/listing); `create` → `actor_present()`; `update`/`destroy` → owner
  (`exists(memberships, user_id == ^actor(:id) and role == :owner and status == :active)` or simpler
  `expr(owner_id == ^actor(:id))`).
- **Identity:** `identity :unique_slug, [:slug]`.

### `Verscienta.Communities.GroupMembership`
- **Attributes:** `role` (atom one_of `[:owner, :mod, :member]`, default `:member`), `status`
  (atom one_of `[:active, :requested, :invited]`, default `:active`), timestamps.
  `belongs_to :user`, `belongs_to :group`. **Identity** `[:user_id, :group_id]`.
- **Actions (generic, run-fn, mirroring the Follow toggle idiom where useful):**
  - `join` (public group only) → create `:member`/`:active`. (Reject if private or already a member.)
  - `request_join` (private) → create `:member`/`:requested`.
  - `invite` (owner/mod) — arg `user_id` → create `:member`/`:invited`.
  - `accept` (the invited user) → set `status: :active`.
  - `approve` (owner/mod) — set a `:requested` membership to `:active`.
  - `decline` / `remove` (owner/mod) → destroy a membership (can't remove the owner).
  - `leave` (member/mod) → destroy own membership. An **owner cannot leave while sole owner** — they
    must `transfer_ownership` first (becoming a mod) or delete the group.
  - `promote` / `demote` (owner) → member↔mod.
  - `transfer_ownership` (owner) — arg `user_id` of an **active member**: set that member's role to
    `:owner` and set `Group.owner_id` to them, and demote the previous owner to `:mod`. Owner-only;
    target must be an existing active member.
  - reads: `:for_group` (by group_id, optional status filter), `:for_user` (by user_id, active).
- **Policies:** all mutations require `actor_present()`; mod/owner gating uses
  `exists(group.memberships, user_id == ^actor(:id) and role in [:owner, :mod] and status == :active)`
  (or a context helper that checks role). `accept` requires the membership's `user_id == actor.id`.
  Direct create/destroy forbidden outside these actions.
- A small context module `Verscienta.Communities` exposes helpers: `role(user, group)`,
  `member?(user, group)` (active), `can_moderate?(user, group)`, `membership(user, group)`.

### `Article.group_id`
- Add `belongs_to :group, Verscienta.Communities.Group, allow_nil?: true` + accept `group_id` in the
  human `create`/`update` actions. Migration adds the nullable column + FK (on group delete → set null).
- **Posting policy:** creating/updating an Article with a `group_id` requires the actor to be an
  **active member** of that group (enforced in a change/validation: look up membership; deny otherwise).
- **New read** `:list_by_group` (arg `group_id`) → published articles in that group, newest first.

## Content isolation (critical)

Group articles must NOT leak into public surfaces (which run `authorize?: false`). Enforce by query
filter, not just policy:
- Global latest (`:list_published`), trending (`Social.Trending`), following feed
  (`Social.following_feed`), and **search indexing** filter `is_nil(group_id)` — group content never
  enters these.
- The group page lists its own articles via `:list_by_group`. For **private** groups, the group
  LiveView gates the article list (and the article reader) on active membership; non-members see a
  "request to join" wall instead of content.
- Search: the index worker skips articles with a `group_id` (and removes any that gain one). The
  document builder / enqueue path checks `is_nil(group_id)`.

## UI

### Directory — `/groups` (public live_session)
- Grid of public groups (name, description, member count, join state) + a "your groups" section for
  signed-in users (active memberships). A "create group" button (signed-in).
- Create via a `/groups/new` (authenticated) form or a modal: name + description + visibility.

### Group page — `/groups/:slug` (public live_session, optional user)
- Header: name, description, visibility badge, member count; a primary action button reflecting state:
  not-member public → **join**; not-member private → **request to join** (or "requested" if pending);
  invited → **accept invite**; active → **leave** (owner sees no leave; sees "manage").
- Tabs/sections: **articles** (the group's posts; gated for private non-members), **members** (list
  with roles).
- Active members see a "post to group" affordance (links to the editor with the group preselected).

### Manage panel — owner/mod (on the group page or `/groups/:slug/manage`, authenticated)
- Pending **requests** (approve/decline), **invite** a user (by username), **members** list with
  remove + (owner-only) promote/demote.

### Settings — owner (`/groups/:slug/settings`, authenticated)
- Edit name/description/visibility; **transfer ownership** (pick an active member); **delete group** (confirm).

### Article editor
- Add an optional "post to group" `<select>` listing the author's active groups; sets `group_id`.

### Nav
- Add a "groups" link to `nav_links/1`.

## Safety

- Per-group roles enforced in **policies** (not just UI): mod/owner actions check active mod/owner
  membership; owner-only for settings/delete/promote.
- Private-group content gated by active membership in the LiveView AND group articles excluded from all
  global/authorize?:false surfaces (defense in depth).
- Owner cannot be removed or leave; can't delete others' content except via mod/owner removal.
- Slug uniqueness via identity + retry. Self-invite / duplicate-membership prevented by the identity.

## Testing & gates

- **Group:** create makes the creator an owner/active member + a slug; owner-only update/destroy;
  `:list_public` excludes private groups.
- **Membership flows:** public join/leave; private request→approve / request→decline; invite→accept;
  promote/demote; remove member; owner can't leave while sole owner; non-mod can't approve/invite/remove.
- **Ownership transfer:** owner transfers to an active member → target becomes `:owner` + `Group.owner_id`
  updates + old owner becomes `:mod`; the ex-owner can then leave; non-owner can't transfer; target must
  be an active member.
- **Content:** an active member can post an Article with `group_id`; a non-member cannot;
  `:list_by_group` returns the group's published articles.
- **Isolation:** a group article does NOT appear in `:list_published` / trending / following /
  search index; a private-group article is unreadable by a non-member (group page wall).
- **LiveView:** directory lists public groups; group page shows the correct action button per state;
  manage panel gated to owner/mod (non-mod denied); settings gated to owner.
- All CI gates green: `mix compile --warnings-as-errors`, `mix format --check-formatted`,
  `mix credo --strict`, `MIX_ENV=test mix test`. Migrations via `mix ash.codegen`.
- Test-DB note: group seeds must not break existing `list_published`/feed count assertions (group
  articles are excluded from those by the isolation filter — verify).

## Out of scope (deferred)

- **Group notifications / activity events** (would extend the Notification `type` enum + activity
  verbs — cross-subsystem; pending requests/invites are shown in the manage panel instead).
- Ownership transfer; leaving as the sole owner.
- Group avatar / cover images (reuse Media later).
- Per-group "members can post" toggle (fixed: any active member posts).
- Nested/sub-groups; group-level roles beyond owner/mod/member; group discovery ranking/search.

## Definition of Done

- `Verscienta.Communities` domain with `Group` + `GroupMembership` (per-group roles + status flows);
  `Article.group_id`; migrations applied; domain registered.
- Public join/leave; private request→approve and invite→accept; promote/demote; ownership transfer;
  owner-protected settings/delete — all policy-enforced.
- Group-tagged Articles by active members; discussions via existing comments; `:list_by_group`.
- Group content siloed from global feeds/search; private content gated by active membership.
- `/groups` directory, `/groups/:slug` page (state-aware actions), manage panel, settings, editor
  group selector, "groups" nav link.
- All gates green; migrations via `mix ash.codegen`; work committed on `communities`.
