# Deploy rollback

**Alert:** — (procedure, invoked from other runbooks) · **Severity:** —

When a deploy correlates with `KilnAppDown` / `VerscientaAppDown` or
`KilnHighErrorRate` / `VerscientaHighErrorRate`, roll back **first** and
diagnose afterwards — the broken code stays available in git; your users don't
stay available.

## When to roll back

- Error rate/latency alert fires within ~15 minutes of a deploy.
- Crash loop right after deploy (boot raise: missing env var, bad migration).
- Feature-flagged change misbehaving → prefer disabling the flag over a
  rollback (`FunWithFlags.disable(:flag)` from an app console).

## Procedure (Coolify)

1. Coolify → application → **Deployments**: redeploy the previous successful
   deployment (its image is retained; this is a rebuild-free redeploy).
2. If the bad deploy included a **migration**, do NOT blindly roll the code
   back past it. Check first from an app console:

   ```elixir
   Ecto.Migrator.migrations(KilnCMS.Repo)
   ```

   - Additive migration (new table/column/index): old code runs fine on the
     new schema — roll back the code, leave the schema.
   - Destructive migration (drop/rename): rolling code back breaks. Fix
     forward instead (revert commit on `main`, redeploy), or restore from
     backup as a last resort.
3. Auto-deploy on `main` means the *git* revert is the durable rollback:

   ```sh
   git revert <bad-sha> && git push origin main
   ```

   Do this even after a Coolify-level redeploy — otherwise the next push
   re-ships the broken commit.

## Verify

Alerts resolve; error rate back to baseline; the Application Grafana
dashboard shows the expected app version/uptime reset.

## Prevention

Keep migrations additive in the deploy that ships them (drop/rename in a
later deploy after the code stops referencing the old shape). Gate risky
features behind FunWithFlags so "rollback" is a flag flip.
