# Oban queues backed up

**Alerts:** `KilnObanQueueBacklog` / `VerscientaObanQueueBacklog` (>500 available, 10m),
`KilnObanRetryablePileup` / `VerscientaObanRetryablePileup` (>50 retryable, 15m) · **Severity:** warning

Queues and concurrency — Kiln core (`kiln_cms/config/config.exs`):
`firing: 5`, `search: 5`, `mail: 3`, `media: 3`, `webhooks: 3`,
`scheduling: 5`, `default: 10` (plus `newsletter`/`billing` if enabled).
Overlay ingestion uses `VerscientaNews.Ingestion.Poller` on the `default` or
`ingestion` queue (check `projects/verscienta_news/` for the actual queue).

## Symptoms

- **Backlog** (`available` jobs piling up): work arrives faster than the
  queue drains — feeds, digests, notifications run late.
- **Retryable pile-up** (`retryable` jobs): jobs are *failing* repeatedly and
  waiting for their next retry — something downstream is broken. For the
  `ai` queue this usually co-fires with `KilnOllamaDown` /
  `VerscientaOllamaDown`.

## Impact

Delayed background work (stale aggregated articles, late digests/notifications,
missing AI enrichment). User-facing requests are unaffected unless the DB is
also saturated.

## Diagnose

1. **Which queue, which state?**

   ```promql
   max by (queue, state) (kiln_cms_prom_ex_oban_queue_length_count) > 0
   # legacy metric name: verscienta_prom_ex_oban_queue_length_count
   ```

2. **What's failing?** From an app console
   ([how](README.md#shared-preliminaries)):

   ```elixir
   import Ecto.Query
   # Most common failing workers + last error
   KilnCMS.Repo.all(
     from j in Oban.Job,
       where: j.state == "retryable",
       group_by: j.worker, select: {j.worker, count(j.id)})

   KilnCMS.Repo.one(
     from j in Oban.Job,
       where: j.state == "retryable", order_by: [desc: j.attempted_at],
       limit: 1, select: {j.worker, j.errors})
   ```

3. Backlog without failures → throughput problem: look for one enormous batch
   (ingestion poller `*/15 * * * *`; Kiln `scheduling` triggers `* * * * *`;
   digest enqueues daily at 13:00 UTC) or a slow external dependency
   stretching every job.

## Mitigate

- **Downstream broken** (retryable pile-up): fix the dependency first
  ([ollama-down](ollama-down.md), [meilisearch-down](meilisearch-down.md),
  [postgres-issues](postgres-issues.md)). Jobs then clear themselves on their
  next retry, or force it now:

  ```elixir
  import Ecto.Query
  Oban.retry_all_jobs(from j in Oban.Job, where: j.state == "retryable")
  ```

- **Pure throughput**: temporarily raise concurrency for a queue:

  ```elixir
  Oban.scale_queue(queue: :default, limit: 25)
  ```

  (Reverts on restart; make it permanent in config.exs if it recurs.)
- **Poison jobs** (always fail, never will succeed):

  ```elixir
  Oban.cancel_all_jobs(from j in Oban.Job, where: j.state == "retryable" and j.worker == "WorkerName")
  ```

## Verify

Queue lengths trending down in the Oban Grafana dashboard / the PromQL above;
alerts resolve.

## Prevention

Workers are idempotent by convention — keep them so, or retries make things
worse. If a queue rides near its limit weekly, bump its concurrency in
config.exs rather than waiting for the next alert.
