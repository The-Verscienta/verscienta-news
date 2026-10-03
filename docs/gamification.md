# Gamification — Vitality, Badges, Leaderboards, Quests, Rewards

Stubs under `projects/verscienta_news/gamification/` — Ash resources not yet in `ash_domains` (activate after `mix ash.codegen`).

- **VitalityPointLedger** (append-only): `user_id`, `points`, `reason` (`read_dwell`, `comment`, `publish`, `curate`, `streak`), `reference_id`.
- **Badge** + **Achievement**: category-specific (Herb Scholar, Mindfulness Master) + milestone; `awarded_at` via Oban worker.
- **Level**: thresholds unlock avatar, feature, priority queue (`levels.exs` config, e.g., Lv7 at 1400 pts as shown in `/` shell).
- **Leaderboard**: materialized views `leaderboard_weekly/monthly/global/category` refreshed by `Oban` nightly.
- **Quest**: daily/weekly (e.g., 7-Day Meditation Streak) — persisted `QuestProgress` with reset cron.
- **RewardStore**: `Reward` catalog + idempotent `Redemption` (Ash atomic debit).

Frontend shows Vitality card on `/` (mock values until ledger wired). See `docs/architecture.md` for flow.
