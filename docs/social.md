# Social — Follows, Threads, Communities, Rooms, Feeds

Stubs under `projects/verscienta_news/social/` — activate after schema gen.

- **Follow** (polymorphic: user, expert, topic/category): `follower_id`, `followable_type`, `followable_id`.
- **Comment**: closure table `comment_paths` for threaded depth ≥3, `article_id`, `parent_id`, mentions via Portable Text annotation (`@user` → PubSub notification).
- **Reaction**, **Repost**: enum + snapshot block type `repost`.
- **Community/Membership**: public communities + private groups (`visibility`, `join_policy`), `CommunityMember` with `role`.
- **Live rooms**: `Phoenix.Channel` `room:<id>` for text + `Voice`/video via LiveKit (token at `/api/livekit/token`). Presence for "who's here".
- **Activity feeds**: global + personal fanout — write to `Activity` then PubSub → `Cachex` feed cache; frontend subscribes via `src/lib/api/realtime.ts`.

Moderation hooks: every creation runs Llama toxicity check → `ModerationFlag` if needed (see `docs/moderation.md`).
