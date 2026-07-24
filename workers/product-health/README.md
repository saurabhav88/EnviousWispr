# Product-Health Worker (issue #1092)

A daily Cloudflare Worker that watches product-health metrics and posts an
advisory line to Discord. Read-only: it consumes events that already emit to
PostHog. It gates nothing.

It posts **a heartbeat block every run** (so a silent worker death or a
telemetry blackout is itself visible) and a **louder alert block** only when a
metric crosses a baseline-calibrated threshold. Every message is plain
English: no internal field names or abbreviations.

Reliability: queries run in capped waves (PostHog allows only 3 concurrent
per project) with retry on 429/502/503/504; the dev-id exclusion is resolved
once per run, not once per query; a non-essential query's exhausted retry
degrades only the metrics it feeds instead of discarding the whole run.

Plan + threshold rationale + baselines:
`docs/feature-requests/issue-1092-2026-06-20-daily-product-health-check.md`.
Reliability + plain-English rewrite:
`docs/feature-requests/issue-1589-2026-07-24-product-health-reliability-and-plain-english.md`.

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

`fallback_reason` shipped in v2.3.1. The internal state name
`dark-awaiting-release` is historical; today it means the query returned zero
eligible fallback-reason rows.

## Develop / test

```bash
cd workers/product-health
node --test                     # pure threshold/state logic + reliability machinery, no network
```

Before touching `.github/workflows/product-health-ping.yml`, verify it still has no outer `curl --retry` and its `concurrency:` block is intact (the worker's own retry/degrade machinery assumes both):

```bash
workflow=../../.github/workflows/product-health-ping.yml
if grep -nE '^[[:space:]]*curl .*--retry|^[[:space:]]*--retry([[:space:]]|$)' "$workflow"; then
  echo "outer workflow retry must be removed"; exit 1
fi
sed '/^[[:space:]]*queue: max[[:space:]]*$/d' "$workflow" | actionlint -   # actionlint v1.7.12 predates the valid `queue` key
```

Pre-deploy live-query smoke (runs the real HogQL against production PostHog,
asserts the queries resolve + denominators are non-zero + no query degraded,
prints the heartbeat, posts nothing):

```bash
~/.claude/bin/get-key launch posthog-personal-api-key POSTHOG_KEY -- \
  node workers/product-health/live-query-smoke.mjs
```

## Deploy (required after every source change)

There is no automatic deploy workflow: merging a PR to `main` does NOT ship
the code to the running worker. Run this manually after every merge that
touches `workers/product-health/`.

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
secret-gated endpoint at `17 14 * * *` (~10:17am ET - ingestion-lag buffer; the
offset minute avoids GitHub's top-of-hour high-load window where runs can be
delayed or dropped, #1131). The same secret lives as repo secret
`PRODUCT_HEALTH_TRIGGER_SECRET`:

```bash
security find-generic-password -w -a m4pro_sv -s enviouswispr.product-health-trigger-secret \
  | gh secret set PRODUCT_HEALTH_TRIGGER_SECRET --repo saurabhav88/EnviousWispr
# run on demand: gh workflow run "Product Health Check" --repo saurabhav88/EnviousWispr
```

## Rollback

Delete the GitHub workflow to stop the daily run; `npx wrangler delete
enviouswispr-product-health` removes the worker entirely. Revert the PR to remove
the code. A bad threshold is a one-line edit in `THRESHOLDS` + redeploy.
