# Deploying Verscienta News to Coolify

Step-by-step guide for deploying this KilnCMS-overlay application to a server
running [Coolify](https://coolify.io) (v4). It covers the production pieces
that ship in this repo (Dockerfile PROJECT overlay, release migrator, health
endpoint, SMTP mailer), provisioning the backing services, configuring the
application resource in Coolify, and first-boot/verification steps.

## Architecture at a glance

The release is a single OTP node (`kiln_cms` release with the
`verscienta_news` overlay) that needs backing services at boot and several
optional integrations. The stack is **Cachex + Hammer + Phoenix.PubSub — no
Redis** (per Kiln D1/D2; Dragonfly deferred until multi-node measurement).

| Service | Required? | Notes |
|---|---|---|
| PostgreSQL 16 **with the `vector` extension** | Yes, to boot | `KilnCMS.Repo` registers the `vector` type, so a Postgres image without pgvector will not boot. Slice 1 does not turn semantic search on. Oban also runs here. |
| Meilisearch ≥ 1.12 | No | Slice 1 search is Kiln Postgres full text. Optional `--profile search` after Slice 1. |
| Cloudflare Images | No | Not a Slice 1 feature and not a boot check in this overlay. Kiln media uses its storage adapters. |
| SMTP relay | Yes | Prod mailer is `Swoosh.Adapters.SMTP` (`gen_smtp`); boot raises without `SMTP_HOST`. Any transactional provider's SMTP endpoint works (587/STARTTLS). |
| Ollama | No | AI enrichment (advisory only) degrades gracefully when absent. Needs significant RAM/GPU if you run it. |
| LiveKit, PayPal, PostHog, web push (VAPID), Grafana | No | Each feature stays dark when its env vars are unset. |
| Dragonfly / Redis | No | **Removed.** Cache is in-BEAM Cachex (ETS); rate limiting is Hammer (ETS); realtime is `Phoenix.PubSub` (pg adapter). Do not provision Redis/Dragonfly for Slice 1. |

Everything except Cloudflare Images (and usually SMTP) can run as Coolify
resources on the same server and talk over the internal Docker network.

> **Stack note (D1/D2):** Kiln D1 — cache tiers are ETS default, Redis optional
> behind a behaviour seam that is not activated in this overlay. D2 — Dragonfly
> is deferred until multi-node measurement shows a shared cache is needed.
> `Verscienta.Cache.Redis` / `REDIS_URL` do not exist in this codebase.

## Prerequisites

- A server with Coolify v4 installed and a DNS record
  (e.g. `news.example.com`) pointing at it. Coolify's proxy (Traefik or
  Caddy) terminates TLS via Let's Encrypt automatically.
- Sizing: the app itself is comfortable at 2 vCPU / 4 GB. The **Docker build
  compiles ~60 Elixir deps including Ash** — give the build host at least
  4 GB RAM (or add swap), or build images in CI and deploy by image tag.
  Add a lot more if you co-locate Ollama.
- GitHub access for the repo configured in Coolify (GitHub App or deploy
  key) if deploying from source.
- A Cloudflare Images account (account ID, API token with Images edit
  permission, and the account hash from the Images dashboard).
- SMTP credentials from your email provider (Mailgun, SES, Postmark, etc. —
  the submission endpoint on port 587 with STARTTLS).

---

## Step 1 — What ships in the repo (review before deploying)

These production pieces already exist; nothing needs to be written, but
know what they do:

- **[Dockerfile](../Dockerfile)** — PROJECT overlay build. Copies `kiln_cms/`
  (core), `projects/verscienta_news/` (overlay), and
  `config/project.exs` (activation) into the builder, then `mix release`
  inside `kiln_cms` with `PROJECT=verscienta_news`. Assets build with
  the standalone tailwind/esbuild binaries (no Node.js). The runtime stage
  installs `libvips` + `fonts-dejavu-core` (**required** for OG-card
  rendering) and `curl` (container health check). Runs as non-root; CMD is
  `bin/kiln_cms start` (migrations run via `KilnCMS.Release` on boot — see
  below). `PROJECT` is an `ARG`/`ENV` so the same Dockerfile builds any
  overlay.
- **[kiln_cms/lib/kiln_cms/release.ex](../kiln_cms/lib/kiln_cms/release.ex)** —
  `KilnCMS.Release.migrate/0` and `rollback/2` via `Ecto.Migrator`,
  since releases don't ship Mix. Seed tasks run against the live node with
  `bin/kiln_cms rpc` instead (Step 4).
- **[kiln_cms/lib/kiln_cms_web/plugs/health.ex](../kiln_cms/lib/kiln_cms_web/plugs/health.ex)** —
  `GET /health` returns 200 when the database answers `SELECT 1`, 503
  otherwise. Mounted first in the endpoint; `force_ssl` already excludes
  `localhost`/`127.0.0.1`, so container-internal probes aren't redirected
  to HTTPS.
- **SMTP mailer** — [kiln_cms/config/runtime.exs](../kiln_cms/config/runtime.exs)
  configures `Swoosh.Adapters.SMTP` (via `gen_smtp`) from `SMTP_HOST` /
  `SMTP_PORT` / `SMTP_USERNAME` / `SMTP_PASSWORD`, with STARTTLS and
  certificate verification. `SMTP_HOST` is required — auth emails
  (confirmation, password reset), digests, and notifications are silently
  dropped without a relay, so the release fails fast instead. Port
  587/STARTTLS is assumed; auth is `:if_available`, so an internal
  unauthenticated relay also works.
- **Cache / rate limit / realtime** — `KilnCMS.Cache` (Cachex ETS,
  `max_entries: 10_000`, evented LRW), `Hammer` (ETS) for auth rate limits,
  `Phoenix.PubSub` (pg adapter) for cache-bust broadcasts and live updates.
  No Redis client is started.

---

## Step 2 — Provision backing services in Coolify

Create a Coolify **Project** (e.g. "verscienta"), pick the server +
destination, then add the resources below. For each one, note the
**internal hostname** Coolify shows on the resource page — the app reaches
them over the internal Docker network, not via public URLs.

### 2.1 PostgreSQL with pgvector

1. **+ New → Database → PostgreSQL.**
2. Before starting it, change the **image** from the default to
   `pgvector/pgvector:pg16` (the stock Postgres image lacks the `vector`
   extension and the embeddings migrations will fail).
3. Set a strong password; database name e.g. `verscienta_prod`.
4. Start it, and record the internal connection string, e.g.
   `postgres://postgres:<password>@<internal-host>:5432/verscienta_prod`.
5. Enable **scheduled backups** on the resource (Coolify supports S3
   targets) — this is the only stateful store that matters.

Do **not** expose Postgres publicly (leave "Make it publicly available" off).

### 2.2 Meilisearch (optional — Slice 1 uses Postgres FTS)

Only if you need Meilisearch before Slice 1 exit (not required — Kiln
Postgres FTS serves `/api/search` in Slice 1):

1. **+ New → Service → Meilisearch** (or a one-off Docker image
   `getmeili/meilisearch:v1.12` to match [docker-compose.yml](../docker-compose.yml)).
2. Set environment: `MEILI_ENV=production` and a strong
   `MEILI_MASTER_KEY` (32+ random chars).
3. Make sure it has a **persistent volume** on `/meili_data`.
4. Internal URL: `http://<internal-host>:7700`. No public exposure needed.

### 2.3 Ollama (optional)

Only if you want AI enrichment/embeddings (advisory only — never gates
publish). Add a service from the `ollama/ollama` image with a volume on
`/root/.ollama`, then pull models once (`ollama pull llama3.2:3b` and
`ollama pull nomic-embed-text` via the container terminal). Skip entirely
on small servers — the app treats Ollama as best-effort. A failing Ollama
leaves drafts in `in_review`; see [ingestion](ingestion.md).

---

## Step 3 — Create the application resource

1. **+ New → Application → Private Repository (GitHub App)**, pick the repo
   and the `main` branch.
2. **Build Pack:** `Dockerfile` (path `/Dockerfile` at repo root — the
   PROJECT overlay Dockerfile, not `kiln_cms/Dockerfile`).
3. **Port:** set **Ports Exposes** to `4000`.
4. **Domain:** `https://news.example.com` (your real host). Coolify
   provisions the certificate automatically.
5. Under **Advanced**, enable **"Connect To Predefined Network"** if the
   databases live in a different stack on the same server — the app must
   share a Docker network with Postgres (and Meilisearch/Ollama if used) for
   the internal hostnames to resolve.

### 3.1 Health check

On the application's **Health Check** tab:

- Path: `/health` — Port: `4000` — Scheme: `http`
- Interval ~10s, start period ~30s (release boot + first migration run can
  take a little while on first deploy).

This uses `curl` inside the container (installed by the Dockerfile). With a
working health check, Coolify performs **rolling deployments** — the old
container keeps serving until the new one is healthy.

### 3.2 Environment variables

Generate the secrets locally first:

```sh
mix phx.gen.secret                 # SECRET_KEY_BASE
mix phx.gen.secret                 # TOKEN_SIGNING_SECRET (separate value!)
mix web_push.gen.keypair           # VAPID keys (optional, for web push)
openssl rand -hex 32               # METRICS_AUTH_TOKEN (optional)
```

All variables below are **runtime** variables (nothing is read at compile
time, so none need the "Build Variable" flag). Mark the secrets as such so
they're hidden in the UI.

**Required — the release raises at boot without these:**

| Variable | Value |
|---|---|
| `DATABASE_URL` | `ecto://postgres:<password>@<pg-internal-host>:5432/verscienta_prod` |
| `SECRET_KEY_BASE` | output of `mix phx.gen.secret` |
| `TOKEN_SIGNING_SECRET` | a second, independent secret |
| `SMTP_HOST` | your provider's SMTP submission host |

**Not required to boot.** Cloudflare Images is not a Slice 1 feature. Kiln media uses its storage adapters. Set these only if you later point media at Cloudflare Images:

| Variable | Value |
|---|---|
| `CLOUDFLARE_ACCOUNT_ID` | from the Cloudflare dashboard |
| `CLOUDFLARE_API_TOKEN` | token with Cloudflare Images permissions |
| `CLOUDFLARE_IMAGES_ACCOUNT_HASH` | from the Images delivery URL |

**Required in practice (bad defaults if unset):**

| Variable | Value |
|---|---|
| `PHX_HOST` | `news.example.com` — your public host; defaults to `example.com`, which breaks URLs and the WebSocket origin check |
| `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD` | port defaults to `587` (STARTTLS); credentials per your provider |

**Optional — feature toggles and tuning (unset = feature dark / default):**

| Variable | Default / effect |
|---|---|
| `PROJECT` | `verscienta_news` — baked as `ARG` in the Dockerfile; override only to build a different overlay |
| `POOL_SIZE` | DB pool, default `10` |
| `LOG_LEVEL` | default `info`; JSON logs on stdout |
| `MEILISEARCH_URL`, `MEILISEARCH_KEY` | only if you provisioned Meilisearch above; unset → Kiln Postgres FTS (Slice 1 default) |
| `OLLAMA_URL`, `OLLAMA_MODEL`, `OLLAMA_EMBED_MODEL` | point at your Ollama service (`http://<ollama-host>:11434`); defaults assume localhost; unset → AI enrichment skipped, drafts stay in review queue |
| `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT` | web push; unset → push features dormant |
| `POSTHOG_API_KEY`, `POSTHOG_HOST` | product analytics |
| `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` | voice rooms (deferred past Slice 1) |
| `METRICS_AUTH_TOKEN` | enables `/metrics` behind `Authorization: Bearer <token>`; unset → `/metrics` 404s in prod |
| `GRAFANA_HOST`, `GRAFANA_AUTH_TOKEN` | PromEx uploads its dashboards on boot |
| `CLOUDFLARE_IMAGES_SIGNING_KEY` | HMAC-signed image delivery URLs |
| `ECTO_IPV6`, `DNS_CLUSTER_QUERY` | leave unset on a single-node Docker deploy |

`PHX_SERVER=true` and `PORT=4000` are baked into the Dockerfile; you don't
need to set them in Coolify.

> **Removed:** `REDIS_URL`, `REDIS_*`, `Verscienta.Cache.Redis` — no Redis
> in this stack. Rate limiting is `Hammer` (ETS), cache is `KilnCMS.Cache`
> (Cachex ETS), realtime is `Phoenix.PubSub`. Setting `REDIS_URL` has no
> effect.

### 3.3 Deploy

Hit **Deploy**. The first build is the slow one (full dep compile). Watch
the runtime logs for:

1. `KilnCMS.Release.migrate()` output — all migrations run against the
   empty database (the pgvector `CREATE EXTENSION` migration must succeed
   here; if it errors, your Postgres image is wrong — see 2.1).
2. `Running KilnCMSWeb.Endpoint ... at :::4000` — Bandit is up.
3. No crash-loops from `KilnCMS.Search.Setup` (only if Meilisearch is
   enabled and `MEILISEARCH_URL` is wrong) and no `Cachex`/`Hammer`
   errors (these are in-BEAM and never crash-loop on missing infra).

Then enable **automatic deployments** on push to `main` in the app's
settings (Coolify installs the GitHub webhook for you when using the
GitHub App integration).

---

## Step 4 — First-boot tasks

Open the application container's **Terminal** in Coolify (or
`docker exec -it <container> sh` on the host). Mix tasks don't exist in a
release; call their underlying functions on the running node via `rpc`:

```sh
# Seed the feature-flag catalog if applicable (idempotent)
bin/kiln_cms rpc "KilnCMS.Flags.Seeds.seed!()"

# Seed Kiln defaults (idempotent — depends on Kiln version)
bin/kiln_cms rpc "KilnCMS.Seeds.seed!()"
```

> Do **not** run `priv/repo/seeds.exs` in production — it may create
> accounts with known passwords.

Create your admin account: register normally through the web UI, confirm
the email, then promote it from a remote shell (`bin/kiln_cms remote`):

```elixir
require Ash.Query

user =
  KilnCMS.Accounts.User
  |> Ash.Query.filter(email == "you@example.com")
  |> Ash.read_one!(authorize?: false)

user
|> Ash.Changeset.for_update(:update_profile, %{}, actor: user)
|> Ash.Changeset.force_change_attribute(:role, :admin)
|> Ash.update!(authorize?: false)
```

(Ctrl+C twice exits the remote shell without stopping the node.)

Search indexes (if Meilisearch is enabled) were already created by
`KilnCMS.Search.Setup` at boot. If you ever need a full re-provision:

```sh
bin/kiln_cms rpc ":ok = KilnCMS.Search.Setup.run()"
```

For Slice 1 (Postgres FTS) no search provisioning is needed.

---

## Step 5 — Verify

- [ ] `https://news.example.com` loads over TLS; `http://` redirects (HSTS
      comes from `force_ssl` in prod.exs).
- [ ] `https://news.example.com/health` returns `{"status":"ok"}`.
- [ ] Sign-up sends a confirmation email (proves the SMTP relay works).
- [ ] Fired article at `https://news.example.com/<category>/<slug>` renders with
      attribution, the medical disclaimer, and a claim badge.
      That path is the article alias `/[field:category]/[slug]`.
- [ ] Oban is running: in the container,
      `bin/kiln_cms rpc "Oban.check_queue(queue: :default) |> IO.inspect()"`.
- [ ] A poll leaves new articles in `in_review` (see [ingestion](ingestion.md)).
      Ollama is Compose profile `ml` and is not required for that.
- [ ] `/metrics` returns Prometheus text with
      `Authorization: Bearer $METRICS_AUTH_TOKEN` (if configured), 404
      without.
- [ ] Search works on the site (Postgres FTS in Slice 1; Meilisearch only
      if you provisioned it).

---

## Operations notes

**Deploys & rollback.** Every push to `main` builds and rolls out with the
health-check gate. To roll back, use Coolify's deployment history to
redeploy a previous image. Because the container runs `migrate()` on every
boot, write migrations to be backward-compatible with the previous release
(additive first, destructive later); for an explicit down-migration use
`bin/kiln_cms eval 'KilnCMS.Release.rollback(KilnCMS.Repo, <version>)'`.
See also [runbooks/deploy-rollback.md](runbooks/deploy-rollback.md).

**Graceful shutdown.** Docker's default stop timeout is 10 s. Give the BEAM
time to drain connections and in-flight Oban jobs: in the app's
**Advanced / Custom Docker Options**, add `--stop-timeout 60`.

**Resource limits.** If you set container limits in Coolify, set a memory
limit only (1–2 GB is plenty to start). **Do not set CPU limits** — cgroup
CPU throttling interacts badly with the BEAM scheduler.

**Log retention.** The app logs JSON to stdout. Docker's default `json-file`
driver is unbounded — set retention in `/etc/docker/daemon.json` on the
host (`"log-opts": {"max-size": "10m", "max-file": "3"}`), as described in
[observability.md](observability.md).

**Database TLS.** Postgres traffic stays on the server-local Docker
network, so `ssl` is off in [kiln_cms/config/runtime.exs](../kiln_cms/config/runtime.exs). If
you ever move to a managed/external Postgres, uncomment `ssl: true` and add
`ssl_opts: [verify: :verify_peer, cacertfile: ...]` before pointing
`DATABASE_URL` at it.

**Monitoring stack.** The compose file's Prometheus/Grafana/Alertmanager
profile is dev-only. On Coolify, deploy them as separate services (or use
Coolify's built-in monitoring), scrape
`https://news.example.com/metrics` with the Bearer token, and import the
dashboards from `monitoring/grafana/dashboards/`.

**Cache & realtime (no Redis).** `KilnCMS.Cache` (Cachex ETS,
`max_entries: 10_000`, 60m safety-net TTL, precise invalidation on writes)
and `KilnCMS.Cache.ClusterBust` (PubSub broadcast for multi-node bust) need
no external service. Rate limiting is `Hammer` (ETS). PubSub is
`Phoenix.PubSub` with the `PG2` adapter — no Redis adapter.

**Scaling out later.** Multi-node clustering is already plumbed
(`DNS_CLUSTER_QUERY` + `dns_cluster`), but Coolify's Docker deployments
don't provide a stable DNS discovery name across replicas — revisit
clustering (and Hammer/Cache assumptions) before scaling beyond one app
container. Dragonfly (shared cache) is deferred per D2 until measurement
shows it is needed.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Boot raise: `environment variable X is missing` | One of the required vars from 3.2 is unset — the raise message names it. |
| Migration fails with `type "vector" does not exist` / extension error | Postgres image is not `pgvector/pgvector:pg16` (2.1). |
| App crash-loops, logs mention Meilisearch / `Search.Setup` | `MEILISEARCH_URL`/`MEILISEARCH_KEY` wrong and Meilisearch was enabled — either fix them or unset them to use Postgres FTS (Slice 1 default). |
| Pages load but LiveView dead (no interactivity), WS 403 | `PHX_HOST` doesn't match the browser origin. |
| OG card endpoints 500, logs mention vips/font | Runtime image missing `libvips`/`fonts-dejavu-core` — don't slim down the [Dockerfile](../Dockerfile) runtime stage. |
| No emails | SMTP credentials wrong, relay rejects the sender domain, or provider requires a verified sender — check the app logs for the gen_smtp error. |
| TLS error connecting to the SMTP relay | The mailer verifies certificates (`verify_peer`); the relay's hostname must match its cert. For a non-TLS internal relay this config won't work as-is — adjust the mailer block in runtime.exs. |
| Health check never passes, deploy stuck | Wrong port/path in the health-check tab, or DB unreachable (`/health` returns 503 when `SELECT 1` fails). |
| Build OOM-kills on the server | Compile needs ~4 GB — add swap or build in CI and deploy the image. |
| References to `REDIS_URL` / `Verscienta.Cache.Redis` in old docs | Stale — removed in Slice 1 alignment; cache is Cachex (ETS), no Redis to configure. |
