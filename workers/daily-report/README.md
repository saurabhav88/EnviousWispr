# Daily Report Worker (issue #1433)

A daily Cloudflare Worker that posts a plain-English usage summary to Discord.
Read-only: it consumes events that already emit to PostHog. It gates nothing,
alerts on nothing — purely a digest for the founder's morning read.

Plan + full metric-definition rationale (including the two real bugs caught
during planning and the two grounded-review rounds that shaped the final
design): `docs/feature-requests/issue-1433-2026-07-09-daily-report.md`.

## What it reports

Covers the previous **complete Eastern calendar day** (midnight to midnight
`America/New_York`, computed via the JS `Intl` API — correctly DST-aware,
never a UTC-day approximation).

| Line | Definition |
|---|---|
| New installs | Unique `distinct_id`s with `app.launched{is_fresh_install=true}` that day. |
| People who finished setup | Unique `distinct_id`s with `onboarding.completed` that day. |
| Of those, also dictated | Same-day activation: of the users who onboarded THAT day, how many ALSO had a successful dictation that same day. Deliberately same-day, not open-ended — a stated simplification, not an oversight. |
| Total users | Unique `distinct_id`s with a **successful** `dictation.completed` that day. This deliberately EXCLUDES people who launched the app, or attempted a dictation that failed (ASR/paste failure). It is not "everyone who touched the app," it is "everyone who got a working dictation." This worker does not duplicate `workers/product-health`'s separate failure-rate tracking. |
| Transcription engine, by user | Each user's LATEST dictation that day (`argMax` by timestamp) determines their engine bucket (Parakeet / WhisperKit). Grounded entirely in real per-dictation usage — `asr_backend` is a required, never-null field, so this needs no settings lookup or fallback chain. |
| AI polishing, by user | Each user's **configured** polish provider, not the runtime outcome of any single dictation. A dictation that silently skipped polish (too-short bypass, EG-1-not-ready, Apple Intelligence permanently unavailable on that Mac, etc. — all legitimate by-design behaviors, not bugs) is NOT counted as "AI off"; it's attributed to whatever the user has selected. "Polish turned off" means only a user whose actual configured setting is `none`. Resolution order: (1) latest value across the union of `settings.snapshot.llm_provider` and `settings.changed{setting='llm_provider'}` — a provider switch mid-session, without relaunching, is picked up correctly; (2) if neither was ever recorded, any non-null provider that actually appears on one of their dictations that day; (3) if neither exists (a brand-new user who dictated before their first settings event fired), the shipped default `appleIntelligence`. |
| Net total dictations | Total successful-dictation COUNT for the day (volume, not user count — reported separately from the per-user buckets above, never used as their percentage denominator). |
| Where they are | Top 5 countries by unique dictating user (`$geoip_country_name`); a dictation with no resolvable GeoIP is simply excluded from this one line, not from any other metric. |
| Top 5 users by dictation volume | The 5 heaviest dictators that day, by count. Values only, never a raw `distinct_id`, in the Discord message. |

Every percentage in the report is `round(bucket_count / total_users * 100)` —
integer, no decimals. If `total_users` is 0 that day, the whole
engine/polish section is omitted (no divide-by-zero, no misleading "0%"
noise on a genuinely empty day).

## Correctness guardrail (why this worker trusts nothing on faith)

An early planning-time bug: a naive PostHog query silently truncated at 100
rows while the real population was 110. The fix that survived into this
worker: every per-user bucket count (engine, polish) is checked against an
INDEPENDENTLY queried `total_users` aggregate before the message is built.
If the bucket counts don't sum to `total_users`, the worker throws — this
routes into the same failure path as any other error (see below), so a
silent undercount can never ship as a normal-looking report.

## Develop / test

```bash
cd workers/daily-report
node --test                     # pure query-shape/bucketing/formatting logic, no network
```

Pre-deploy live-query smoke (runs the real HogQL against production
PostHog, asserts the completeness check passes, prints the would-be
message, posts nothing):

```bash
~/.claude/bin/get-key launch posthog-personal-api-key POSTHOG_KEY -- \
  node workers/daily-report/live-query-smoke.mjs [YYYY-MM-DD]
```

The optional date argument overrides "yesterday" — useful for testing
against a known day, and mirrors the deployed worker's `?date=` recovery
parameter (see below).

## Deploy (one-time)

```bash
cd workers/daily-report
npx wrangler deploy

# secrets (never committed):
~/.claude/bin/get-key launch posthog-personal-api-key V -- sh -c 'printf "%s" "$V" | npx wrangler secret put POSTHOG_PERSONAL_API_KEY'
security find-generic-password -w -a m4pro_sv -s enviouswispr.discord-webhook-session-logs | npx wrangler secret put DISCORD_WEBHOOK_URL
# TRIGGER_SECRET gates the public trigger; stored in Keychain for the GitHub Action:
security find-generic-password -w -a m4pro_sv -s enviouswispr.daily-report-trigger-secret | npx wrangler secret put TRIGGER_SECRET

# verify (posts a REAL report to EnviousNotes) - needs the token:
curl "https://enviouswispr-daily-report.saurabhav.workers.dev/?token=<TRIGGER_SECRET>"
```

The `fetch` trigger fails closed with 401 if the token is missing or wrong,
so the public `workers.dev` URL cannot be crawled into spamming Discord.

## Endpoint contract

- Any HTTP method (unrestricted, matches `workers/product-health`).
- Auth: `x-trigger-secret` header OR `?token=` query param.
- Optional `?date=YYYY-MM-DD` — Eastern-calendar-date override, for manual
  recovery after a missed scheduled run (see Failure visibility below). The
  DATA reported is always for the literal date given, computed the same way
  as the default "yesterday" path.
- 401 body: `"unauthorized\n"`. Request body is ignored. Never logs the
  trigger secret, a PostHog response body, or a Discord response body —
  only counts, labels, and HTTP status codes.

## Scheduling (GitHub Actions, not a Cloudflare cron)

The Cloudflare account is at its 5-cron free-plan limit (#1092), so the
daily run is driven by `.github/workflows/daily-report-ping.yml`, which
curls the secret-gated endpoint. The wall-clock POSTING time drifts by up
to ~1 hour across the two DST transitions each year (GitHub Actions cron is
fixed-UTC and cannot itself DST-adjust) — the DATA is unaffected, since the
Eastern day boundary is computed from `Intl` at run time, never from the
cron trigger time. Same secret lives as repo secret
`DAILY_REPORT_TRIGGER_SECRET`:

```bash
security find-generic-password -w -a m4pro_sv -s enviouswispr.daily-report-trigger-secret \
  | gh secret set DAILY_REPORT_TRIGGER_SECRET --repo saurabhav88/EnviousWispr
# run on demand: gh workflow run "Daily Report" --repo saurabhav88/EnviousWispr
```

## Failure visibility (how you'd know if this breaks)

Two independent signals, matching `workers/product-health`'s posture:

1. **A query or completeness-check failure** posts an explicit "Daily
   report failed to generate for `<date>`: `<error>`" notice to Discord
   (EnviousNotes) AND makes the worker return a non-2xx status, which turns
   the GitHub Actions job red. You will see BOTH the Discord notice and a
   GitHub Actions failure.
2. **If Discord itself is unreachable/erroring**, the GitHub Actions job
   still goes red (the one failure mode with no Discord-side notice —
   GitHub's own failure-run email is the signal here).
3. **A missed scheduled run entirely** (GitHub outage, workflow disabled)
   has no automatic backfill. Recover manually with the `?date=` override
   once you notice the gap:
   ```bash
   curl "https://enviouswispr-daily-report.saurabhav.workers.dev/?token=<TRIGGER_SECRET>&date=2026-07-08"
   ```

**Duplicate posts are expected, not a bug.** A manual `workflow_dispatch` or
a GitHub Actions job rerun on a day the scheduled run already posted will
post a second, real, duplicate report — same accepted tradeoff as
`workers/product-health`'s own manual-trigger runbook. No idempotency/dedup
mechanism is built (would need new stateful infrastructure — a Workers KV
namespace — for a low-stakes internal report).

## Rollback

Delete the GitHub workflow to stop the daily run; `npx wrangler delete
enviouswispr-daily-report` removes the worker entirely. Revert the PR to
remove the code. A bad metric definition is a source-level fix + redeploy —
no data migration involved, this worker is stateless (reads PostHog,
writes only to Discord).
