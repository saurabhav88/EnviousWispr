# Product-Health Worker (issue #1092)

A daily Cloudflare Worker that watches product-health metrics and posts an
advisory line to Discord. Read-only: it consumes events that already emit to
PostHog. It gates nothing.

It posts a **one-line heartbeat every run** (so a silent worker death or a
telemetry blackout is itself visible) and a **louder alert block** only when a
metric crosses a baseline-calibrated threshold.

Plan + threshold rationale + baselines:
`docs/feature-requests/issue-1092-2026-06-20-daily-product-health-check.md`.

## Metrics + thresholds (v1)

All windows are **completed** (exclude the partial current day). Production only:
`properties.environment='production'` AND any `distinct_id` with a `-dev` build
anywhere in its history excluded (founder-machine-tell).

| Metric | What | Window | Guard | Alert when | Baseline |
|---|---|---|---|---|---|
| latency | per-day p50/p95 of `dictation.completed.e2e_seconds` | per complete day | day >=50 dictations | p50>2.5s OR p95>9s, 2 qualifying days | p50 ~1.5s |
| paste fallback | clipboard fallback share (split: ax_denied vs direct-fail) | prev 7 days | >=50 pastes | share >5% | ~1.2% |
| AFM discard | genuine Apple-polish discard share (`fallback_reason`) | prev 7 days | >=50 fr-rows AND >=10 discards | share >15% | ~10% (dark until next release) |
| transcription | `pipeline.failed` stage=transcription family share (incl. legit no-speech) | prev 7 days | >=200 dictations | share >5% | ~0.9% |
| volume / integrity | T-1 dictation count + co-firing check | T-1 vs trailing 7 days | trailing avg >=20/day | T-1=0 on active baseline, OR a co-firing event=0 (schema drift) | ~200/day |

AFM discard reads `dark-awaiting-release` until `fallback_reason` ships in a
release and users update (it is null on 100% of production events as of
2026-06-20; merged in #1067 but not yet in a release).

## Develop / test

```bash
cd workers/product-health
node --test                     # pure threshold/state logic, no network
```

Pre-deploy live-query smoke (runs the real HogQL against production PostHog,
asserts the queries resolve + denominators are non-zero, prints the heartbeat,
posts nothing):

```bash
~/.claude/bin/get-key launch posthog-personal-api-key POSTHOG_KEY -- \
  node workers/product-health/live-query-smoke.mjs
```

## Deploy (one-time)

```bash
cd workers/product-health
npx wrangler deploy

# secrets (never committed):
~/.claude/bin/get-key launch posthog-personal-api-key V -- sh -c 'printf "%s" "$V" | npx wrangler secret put POSTHOG_PERSONAL_API_KEY'
security find-generic-password -w -a m4pro_sv -s enviouswispr.discord-webhook-session-logs | npx wrangler secret put DISCORD_WEBHOOK_URL
# TRIGGER_SECRET gates the public trigger; stored in Keychain for the GitHub Action:
security find-generic-password -w -a m4pro_sv -s enviouswispr.product-health-trigger-secret | npx wrangler secret put TRIGGER_SECRET

# verify (posts a real heartbeat to EnviousNotes) - needs the token:
curl "https://enviouswispr-product-health.saurabhav.workers.dev/?token=<TRIGGER_SECRET>"
```

The `fetch` trigger fails closed with 401 if the token is missing or wrong, so
the public workers.dev URL cannot be crawled into spamming Discord.

## Scheduling (GitHub Actions, not a Cloudflare cron)

The Cloudflare account is at its 5-cron free-plan limit (#1092), so the daily run
is driven by `.github/workflows/product-health-ping.yml`, which curls the
secret-gated endpoint at `0 14 * * *` (10am ET - ingestion-lag buffer). The same
secret lives as repo secret `PRODUCT_HEALTH_TRIGGER_SECRET`:

```bash
security find-generic-password -w -a m4pro_sv -s enviouswispr.product-health-trigger-secret \
  | gh secret set PRODUCT_HEALTH_TRIGGER_SECRET --repo saurabhav88/EnviousWispr
# run on demand: gh workflow run "Product Health Check" --repo saurabhav88/EnviousWispr
```

## Rollback

Delete the GitHub workflow to stop the daily run; `npx wrangler delete
enviouswispr-product-health` removes the worker entirely. Revert the PR to remove
the code. A bad threshold is a one-line edit in `THRESHOLDS` + redeploy.
