# Daily Report Worker (issue #1433)

A daily Cloudflare Worker that posts a plain-English usage summary to Discord.
Read-only: it consumes events that already emit to PostHog. It gates nothing,
alerts on nothing — purely a digest for the founder's morning read.

Plan + full metric-definition rationale (including the two real bugs caught
during planning and the two grounded-review rounds that shaped the final
design): `docs/feature-requests/issue-1433-2026-07-09-daily-report.md`.
Reliability-hardening rationale (why every query shares one resolved-once
dev-exclusion predicate, why retries are 3 attempts with randomized backoff,
why 5 of 6 primary queries degrade instead of failing the whole report):
`docs/feature-requests/issue-1720-2026-07-20-daily-report-reliability-hardening.md`.

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

**Verification methodology — do not rapid-fire the live trigger.** PostHog's
project-level limit is 3 concurrent queries; this worker alone can fire up
to ~8 in one run (6 primary + `resolveDevIds` + conditional `tier_a`).
Manually re-triggering the live production endpoint two or three times in a
short window (each firing its own batch) was directly observed causing
429/504 failures on 2026-07-20 that a single isolated trigger did not
reproduce — the repeated triggering was itself the dominant traffic source,
not proof the underlying fix was broken. Verify a change with, in order: (1)
`node --test`, (2) one `live-query-smoke.mjs` run (posts nothing), (3) after
deploying, real unattended scheduled runs over the following days. Do not
declare a fix "proven" from repeated manual endpoint hits.

## Deploy — REQUIRED after every source change

**Merging to `main` does NOT deploy this worker.** There is no deploy workflow;
`.github/workflows/daily-report-ping.yml` only *triggers* the already-deployed
script on a schedule. A merged-but-undeployed fix looks exactly like a fix that
did not work — verified live on 2026-07-18 (#1655), where the worker had to be
deployed by hand after the PR merged and CI went green.

Deploy, then verify the LIVE worker, before calling any worker change done:

```bash
# 1. pre-deploy smoke (posts nothing) - see the section above
# 2. deploy
cd workers/daily-report
npx wrangler deploy

# 3. verify the deployed code actually runs (this DOES post a real report).
# -f is load-bearing: without it curl exits 0 on a 401/500, so a failed verify
# reads as a passed one - the exact false-success this section exists to stop.
# Matches daily-report-ping.yml, which also uses -fsS.
~/.claude/bin/get-key launch daily-report-trigger-secret TOK -- sh -c \
  'curl -fsS -H "x-trigger-secret: $TOK" "https://enviouswispr-daily-report.saurabhav.workers.dev/?date=YYYY-MM-DD"' \
  && echo "VERIFIED: live worker ran the deployed code"
```

A non-zero exit here means the deployed worker is broken even though
`wrangler deploy` succeeded — treat the deploy as incomplete, not done.

If `wrangler` reports it is not authenticated, it needs the account credentials:

```bash
CLOUDFLARE_EMAIL=saurabhav@gmail.com \
  ~/.claude/bin/get-key launch cloudflare-global-api-key CLOUDFLARE_API_KEY -- \
  ~/.claude/bin/get-key launch cloudflare-account-id CLOUDFLARE_ACCOUNT_ID -- \
  npx wrangler deploy
```

### One-time setup (secrets)

```bash
cd workers/daily-report

# secrets (never committed):
~/.claude/bin/get-key launch posthog-personal-api-key V -- sh -c 'printf "%s" "$V" | npx wrangler secret put POSTHOG_PERSONAL_API_KEY'
security find-generic-password -w -a m4pro_sv -s enviouswispr.discord-webhook-session-logs | npx wrangler secret put DISCORD_WEBHOOK_URL
# TRIGGER_SECRET gates the public trigger. Source of truth is GCP Secret
# Manager (`daily-report-trigger-secret`) + the GitHub repo secret - NOT the
# local Keychain. An earlier version of this file said Keychain; that item does
# not exist on the machine (verified 2026-07-18, #1655).
~/.claude/bin/get-key launch daily-report-trigger-secret V -- sh -c 'printf "%s" "$V" | npx wrangler secret put TRIGGER_SECRET'

# verify (posts a REAL report to EnviousNotes) - needs the token:
curl -fsS "https://enviouswispr-daily-report.saurabhav.workers.dev/?token=<TRIGGER_SECRET>"
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
~/.claude/bin/get-key launch daily-report-trigger-secret V -- sh -c \
  'printf "%s" "$V" | gh secret set DAILY_REPORT_TRIGGER_SECRET --repo saurabhav88/EnviousWispr'
# run on demand: gh workflow run "Daily Report" --repo saurabhav88/EnviousWispr
```

## Failure visibility (how you'd know if this breaks)

Two independent signals, matching `workers/product-health`'s posture:

1. **A `totals` failure, an auth failure, a malformed query/response, a
   completeness-check mismatch, or a dev-id-list overflow** posts an explicit
   "Daily report failed to generate for `<date>`: `<error>`" notice to
   Discord (EnviousNotes) AND makes the worker return a non-2xx status, which
   turns the GitHub Actions job red. You will see BOTH the Discord notice and
   a GitHub Actions failure. `totals` is deliberately the ONE primary query
   that never degrades — it anchors `resolveBuckets`' completeness check and
   supplies the report's headline numbers, so there is no safe partial
   substitute for it.

   **Six deliberate exceptions degrade instead of failing (#1655, #1716,
   #1720).** `tier_a` (the polish-provider *settings* lookup) and 5 of the 6
   primary queries — `installs`, `onboard_activate`, `engineAndTierB`, `geo`,
   `top5` — can each independently degrade on an exhausted transient PostHog
   status (429/502/503/504). `tier_a` degrading still yields a full report
   with a near-top note ("today's polish-provider breakdown is approximate
   because the settings lookup was temporarily unavailable"), because
   `resolveBuckets` already falls back per user (settings → actual dictation
   → shipped default). The other 5 have no such fallback data — a degraded
   section is OMITTED with inline "temporarily unavailable" wording in its
   normal spot (never a fabricated `0` or empty list shown as real data),
   plus a combined near-top note listing every degraded section for a fast
   skim. `engineAndTierB` degrading additionally skips `tier_a` (no active-id
   list to enrich) and `resolveBuckets` entirely (no per-user rows to check
   completeness against) — the breakdown lines are simply omitted.

   This exception is scoped tightly. Only these six, and only on an
   exhausted 429/502/503/504 — an auth failure, a malformed query, a bad
   response shape, or any ordinary programming error still fails the whole
   report loudly, because a silently "approximate" report that hides a real
   defect is worse than no report at all.
2. **If Discord itself is unreachable/erroring**, the GitHub Actions job
   still goes red (the one failure mode with no Discord-side notice —
   GitHub's own failure-run email is the signal here).
3. **A missed scheduled run entirely** (GitHub outage, workflow disabled)
   has no automatic backfill. Recover manually with the `?date=` override
   once you notice the gap:
   ```bash
   curl -fsS "https://enviouswispr-daily-report.saurabhav.workers.dev/?token=<TRIGGER_SECRET>&date=2026-07-08"
   ```

**Duplicate posts remain possible for a genuinely separate trigger, not a
bug.** A manual `workflow_dispatch` on a day the scheduled run already
posted will still post a second, real, duplicate report — same accepted
tradeoff as `workers/product-health`'s own manual-trigger runbook. No
idempotency/dedup mechanism is built (would need new stateful infrastructure
— a Workers KV namespace — for a low-stakes internal report). What #1720
DOES prevent: `daily-report-ping.yml`'s own `concurrency: {group:
daily-report, cancel-in-progress: false, queue: max}` stops the scheduled
cron and a manual dispatch from overlapping or silently cancelling each
other's pending run within GitHub Actions — GitHub's default behavior
(`queue: single`) would otherwise let a new pending run silently replace an
already-queued one, which could drop a queued manual recovery run entirely.
This does not cover a direct `curl` to the public Worker endpoint; see the
verification-methodology note above for why that path stays a manual,
deliberate, spaced-out action.

## Rollback

Delete the GitHub workflow to stop the daily run; `npx wrangler delete
enviouswispr-daily-report` removes the worker entirely. Revert the PR to
remove the code. A bad metric definition is a source-level fix + redeploy —
no data migration involved, this worker is stateless (reads PostHog,
writes only to Discord).
