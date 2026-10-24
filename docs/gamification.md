# Gamification — deferred past Slice 1 (fixes "rewards the wrong behavior")

Stubs under `projects/verscienta_news/gamification/` are **not** in `ash_domains` Slice 1 and carry no Slice 1 exit criterion.

Critique: points for dwell time pay lingering; leaderboards on health advice select for volume; a store that buys placement is pay-to-rank on medical-adjacent content. Nothing here is needed to read, trust, or follow a topic.

If revived after Slice 1, metrics must be non-dwell and non-volume-ranked (e.g., curator-approved reads, expert endorsements) and **never** buy featured placement. `RewardStore` is out of scope until that is specified.

- `VitalityPointLedger` (append-only): `user_id`, `points`, `reason` (proposed: `curated_read`/`expert_endorsed` — `read_dwell` removed), `reference_id`
- `Badge`/`Achievement`: category-specific — revive only with expert-curated criteria
- `Level`, `Leaderboard` matviews, `Quest`/`QuestProgress`, `Reward`/`Redemption` — all deferred; `Leaderboard` Slice 1 shell in Svelte is removed

See `docs/slice-1.md`. Gamification is step 5 after exit, and only with metrics that are not dwell time and not pay-to-rank.
