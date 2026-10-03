# Moderation & Trust

Hybrid: Llama (toxicity/claim detection) + community reports + human queue + Verified Expert.

- **Llama moderation**: same Ollama endpoint, separate system prompt (toxicity categories, medical claim hedging). Returns `toxicity: bool`, `claim_risk: low/med/high`, `reasons`. Called on `Comment`/`Article` create + ingestion bridge.
- **Flags**: `ModerationFlag` (`flaggable_type/id`, `reason`, `llm_output`, `status`). Community `Report` creates a flag.
- **Queue**: LiveView `/editor/moderation` (editor/admin only) — actions `approve`, `hide`, `request_changes`, `ban`. Policies via `Ash.Policy.Authorizer`.
- **Verified Expert**: `VerificationRequest` (credentials upload → admin review → `role: :expert` + badge). Seeded experts shown in `/` following tab.
- **Provenance**: Kiln `provenance` (off by default) exposes `/api/provenance/:type/:slug` when enabled — for editorial claims.
