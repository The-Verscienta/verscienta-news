# Social — after Slice 1

Nothing in this file is a Slice 1 exit. Stubs under `projects/verscienta_news/social/` stay out of `ash_domains`.

`KilnCMS.Social` means outbound Bluesky and Mastodon when an article is published. The follow graph, when it is built, is `VerscientaNews.FollowGraph`.

Order matches `docs/slice-1.md`:

1. Verified Expert and richer moderation. Not this file.
2. Follow graph: follows, mentions, comments, reactions, reposts, activity fanout on `Phoenix.PubSub` and Cachex.
3. A Svelte reader, which is the first place those features would be subscribed to.
4. Recommendations.
5. Gamification.

Communities and live rooms come after the follow graph. LiveKit stays behind `livekit_enabled`. Presence uses `Phoenix.PubSub`.
