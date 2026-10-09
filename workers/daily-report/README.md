# Daily Report Worker (issue #1433)

A daily Cloudflare Worker with independent performance and per-platform Sentry write-ups (#3547).
Read-only: it consumes events already received by PostHog or Sentry. It gates nothing,
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
| People who began setting up | Unique `distinct_id`s with `onboarding.started` that day. NOT `app.launched{is_fresh_install}` — that is a STATE (`onboardingState != .completed`) that stays true until setup finishes, so it re-counted unfinished onboarding as a new install every day (#1910). Says setup BEGAN that day, not that it was a first time: Diagnostics can restart onboarding. |
| People who finished setup | Unique `distinct_id`s with `onboarding.completed` that day. |
| Of those, also dictated | Same-day activation: of the users who onboarded THAT day, how many ALSO had a successful dictation that same day. Deliberately same-day, not open-ended — a stated simplification, not an oversight. |
| Total users | Unique `distinct_id`s with a **successful** `dictation.completed` that day. This deliberately EXCLUDES people who launched the app, or attempted a dictation that failed (ASR/paste failure). It is not "everyone who touched the app," it is "everyone who got a working dictation." Per-version failure rates live in the version scorecard section, not here. |
| Transcription engine, by user | Each user's LATEST dictation that day (`argMax` by timestamp) determines their engine bucket (Parakeet / WhisperKit). Grounded entirely in real per-dictation usage — `asr_backend` is a required, never-null field, so this needs no settings lookup or fallback chain. |
| AI polishing, by user | Each user's **configured** polish provider, not the runtime outcome of any single dictation. A dictation that silently skipped polish (too-short bypass, EG-1-not-ready, Apple Intelligence permanently unavailable on that Mac, etc. — all legitimate by-design behaviors, not bugs) is NOT counted as "AI off"; it's attributed to whatever the user has selected. "Polish turned off" means only a user whose actual configured setting is `none`. Resolution order: (1) latest value across the union of `settings.snapshot.llm_provider` and `settings.changed{setting='llm_provider'}` — a provider switch mid-session, without relaunching, is picked up correctly; (2) if neither was ever recorded, any non-null provider that actually appears on one of their dictations that day; (3) if neither exists (a brand-new user who dictated before their first settings event fired), the shipped default `appleIntelligence`. |
| Net total dictations | Total successful-dictation COUNT for the day (volume, not user count — reported separately from the per-user buckets above, never used as their percentage denominator). |
| Where they are | Top 5 countries by unique dictating user (`$geoip_country_name`); a dictation with no resolvable GeoIP is simply excluded from this one line, not from any other metric. |
| Top 5 users by dictation volume | The 5 heaviest dictators that day, by count. Values only, never a raw `distinct_id`, in the Discord message. |

Every percentage in the report is `round(bucket_count / total_users * 100)` —
integer, no decimals. If `total_users` is 0 that day, the whole
engine/polish section is omitted (no divide-by-zero, no misleading "0%"
noise on a genuinely empty day).

## Reading the version check and the error section (#2621)

The version check prints measurements and a footnote; separate Sentry write-ups report recorded error activity. The founder read
the earlier shape ("Covering 80.7% of measured dictations across 2 releases", "People counts are
non-additive", "Ranked against this measure's median week-to-week movement") as noise he could not
decode, so the explanations live here instead.

**Version check, last 7 days.** Header: the displayed releases, newest first, each with the one fact
that changes how to read its column: `(out N days)` when it shipped inside the window, `(no data yet)`
when nothing has been measured on it. A release out the whole week is just its version.

- Which releases appear: the newest published release is ALWAYS shown, whatever its share, then
  releases are added in descending share of the week's dictations until 80% is covered or four are
  shown. The footnote `These N versions cover X% of the week's dictations` is the coverage that
  selection reached; the denominator is every measured dictation, including versions not displayed.
- Builds before 2.2.0 are never measured. They did not record every reason polished text was
  rejected, so their AI-polish figure would read a false 100%; the founder chose (2026-07-29) to hide
  them rather than print a figure known to be wrong beside a caveat.
- `People` is non-additive: one person can appear under more than one release in a week.
- `Typical speed` is the median end-to-end time; `Slowest 5%` the 95th percentile.
- `Auto-paste worked` is the share of paste attempts that landed directly rather than via the
  clipboard fallback. `Apple polish kept` is the share of Apple Intelligence polish attempts whose
  output was kept (that provider only, `METRIC_CALCULATIONS.polish_kept`); the split between the safety
  classifier and other checks is still measured (`classifierDiscards`) and no longer printed. `Failed dictations` counts dictations that ended without a completed transcript, whatever
  stage failed; it is deliberately not labelled as a transcription-engine figure because the app stamps
  no-microphone and permission failures with that stage too.
- `(not compared: …)` on a row means the displayed releases do not share one telemetry contract for
  that metric, so the numbers are printed but no shift is drawn across them.
- `Biggest shifts` names the rows whose movement between the two newest releases ranked highest,
  as "from X to Y" with no verdict. Ranking is against each measure's median week-to-week movement
  where enough history exists, otherwise by size of change; the sample counts behind each are in
  `ranking.movers`. A measure that did not move between the two releases is never a mover.

**Sentry morning write-ups.** Separate Mac and Android messages cover recorded
crash/error activity in yesterday's Eastern calendar day, including known
problems and older builds. Customer-release, developer-build and unknown-build
cohorts use environment and `app.build_type` together; debug evidence overrides
a contradictory production tag.

Complete headline aggregates provide event totals and the change from the
previous Eastern day. Problem rows show occurrences, Sentry-reported identities,
safe version labels and issue links. Identity counts are exact only under
the complete zero/one-row rule; otherwise they are explicit lower bounds.
Incomplete problem lists disclose their limits and omit unsupported changes.
No affected-person rate or crash-free claim is made.

The performance message contains only adoption and version scorecard sections.
The weekly digest retains its existing production/release-scoped Sentry recap.

## Release list source (the appcast, not GitHub)

The version scorecard needs two facts per release: the version and when it
shipped. Both come from **our own Sparkle appcast**, `APPCAST_URL` in
`wrangler.toml` (`https://enviouswispr.com/appcast.xml`): `.github/workflows/release.yml` writes
an `<item>` on every release, Cloudflare Pages serves the file, and every
installed app reads it to learn a release exists. No token, no secret, no
GitHub API quota. One request on the successful path, with up to three
attempts on a 429, a 5xx or a transport failure.

It replaced GitHub's releases API on 2026-09-03 (#2619). That API allows 60
unauthenticated requests an hour **per IP**, a Worker's outbound IP is shared
with other Cloudflare tenants, and the scorecard went missing five of nine
mornings while we made one request a day. The `GITHUB_TOKEN` remedy coded in
#2415 was never installed and would have expired within a year, after which a
401 fails the whole run.

Two consequences worth knowing: a release counts once the appcast carries it,
so a GitHub release whose `publish-appcast` job failed is absent until
`appcast-only` recovery runs (no installed app can see it either); and the
appcast `pubDate` is taken a step before the GitHub release is published, so a
build cut within a minute of midnight Eastern is attributed to the earlier day.
The test suite parses the committed `website/public/appcast.xml` end to end, so
a format drift in the release job fails at PR time rather than one morning.

## Correctness guardrail (why this worker trusts nothing on faith)

The bucket-completeness guard below belongs to performance mode. Sentry uses
its independent complete headlines, bounded problem rows and joint build-tag
projection; missing/malformed data is not a zero report.

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

Pre-deploy smokes drive the actual selected mode, intercept only Discord delivery,
and fail on unavailable/incomplete data. No report is posted:

```bash
~/.claude/bin/get-key launch posthog-personal-api-key POSTHOG_KEY -- \
  node workers/daily-report/live-query-smoke.mjs --report performance [YYYY-MM-DD]
~/.claude/bin/get-key launch sentry-workers-readonly-token SENTRY_KEY -- \
  node workers/daily-report/live-query-smoke.mjs --report sentry --platform mac [YYYY-MM-DD]
~/.claude/bin/get-key launch sentry-workers-readonly-token SENTRY_KEY -- \
  node workers/daily-report/live-query-smoke.mjs --report sentry --platform android [YYYY-MM-DD]
```

`SENTRY_KEY` is the same least-privilege token the deployed Worker holds
(`event:read` + `org:read`), so the smoke exercises exactly the access
production has. An earlier version of this file used `sentry-master-key` and
justified it with "no worker-grade credential can reach the Discover endpoint" —
true when written, false since `sentry-workers-readonly-token` was minted on
2026-08-06. Do not reintroduce the admin key here: it grants far more than a
smoke needs, and running the smoke under wider access than production has can
pass a query the deployed Worker would be refused. Never install
`sentry-master-key` as a Cloudflare Worker secret either.

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
QStash only *triggers* the already-deployed script on a schedule;
`.github/workflows/daily-report-ping.yml` is retained for deliberate manual recovery. A merged-but-undeployed fix looks exactly like a fix that
did not work — verified live on 2026-07-18 (#1655), where the worker had to be
deployed by hand after the PR merged and CI went green.

Deploy, then verify the LIVE worker, before calling any worker change done:

```bash
# 1. pre-deploy smoke (posts nothing) - see the section above
# 2. deploy
cd workers/daily-report
npx wrangler deploy

# 3. verify each deployed mode (these DO post real reports).
# The default request is performance only; also check both Sentry modes with
# ?report=sentry&platform=mac&date=YYYY-MM-DD and
# ?report=sentry&platform=android&date=YYYY-MM-DD under the same header secret.
# -f is load-bearing: without it curl exits 0 on a 401/500, so a failed verify
# reads as a passed one - the exact false-success this section exists to stop.
# Operational triggers use the header; never put the secret in a URL.
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
# Manager (`daily-report-trigger-secret`); deployed copies in QStash and the
# GitHub manual-recovery secret must follow rotations. NOT the
# local Keychain. An earlier version of this file said Keychain; that item does
# not exist on the machine (verified 2026-07-18, #1655).
~/.claude/bin/get-key launch daily-report-trigger-secret V -- sh -c 'printf "%s" "$V" | npx wrangler secret put TRIGGER_SECRET'

# SENTRY_AUTH_TOKEN goes on both surviving reporting Workers (#3547).
# Use the worker read-only credential; the retired relay is not a consumer.
for w in daily-report weekly-digest; do
  (cd "../$w" && ~/.claude/bin/get-key launch sentry-workers-readonly-token V -- \
     sh -c 'printf "%s" "$V" | npx wrangler secret put SENTRY_AUTH_TOKEN')
done

# verify (posts a REAL report to EnviousNotes) - needs the token:
curl -fsS "https://enviouswispr-daily-report.saurabhav.workers.dev/?token=<TRIGGER_SECRET>"
```

The `fetch` trigger fails closed with 401 if the token is missing or wrong,
so the public `workers.dev` URL cannot be crawled into spamming Discord.

## Endpoint contract

- Any HTTP method (unrestricted).
- Auth: `x-trigger-secret` header OR `?token=` query param.
- Optional `?date=YYYY-MM-DD` — Eastern-calendar-date override, for manual
  recovery after a missed scheduled run (see Failure visibility below). The
  DATA reported is always for the literal date given, computed the same way
  as the default "yesterday" path.
- Missing `report` selects `performance`; `report=performance` sends adoption and
  version scorecard only, without Sentry queries/credentials.
- `report=sentry&platform=mac|android` sends a separate broader crash/error
  write-up for that fixed project/channel. It has no PostHog/appcast dependency.
  Missing Android binding refuses delivery; it never falls back to Mac.
- Unsupported/empty report modes and invalid Sentry platforms return 400 before
  outbound work; `platform` is invalid for performance mode.
- QStash has independent performance and Mac/Android Sentry schedules;
  no report depends on another report succeeding.
- 401 body: `"unauthorized\n"`. Request body is ignored. Never logs the
  trigger secret, a PostHog response body, or a Discord response body —
  only counts, labels, and HTTP status codes.

## Scheduling (QStash, #3570)

Three independent schedules run daily at **09:12 America/New_York**, following
Eastern daylight saving automatically. Their IDs are:

- `enviouswispr-daily-performance`: `?report=performance`
- `enviouswispr-daily-sentry-mac`: `?report=sentry&platform=mac`
- `enviouswispr-daily-sentry-android`: `?report=sentry&platform=android`

All call `https://enviouswispr-daily-report.saurabhav.workers.dev/` using POST,
`CRON_TZ=America/New_York 12 9 * * *`, zero retries and a 15-minute timeout.
QStash EU (`https://qstash-eu-central-1.upstash.io`) authenticates with the
GCP `qstash-token`; forward the GCP `daily-report-trigger-secret` as
`Upstash-Forward-x-trigger-secret`. Never put either value in a file or URL.
Rotate the forwarded header on all three schedule IDs when rotating the secret.

The account is shared with EnviousStaging/marketing. Only edit these exact
EnviousWispr IDs; never bulk-delete schedules or change shared queues, keys,
plan or account limits. Each daily report is one request, with no outer retry.
Current account limits and usage must be read live before adding more schedules.

The old GitHub Daily Report workflow was disabled at cutover. This source
removes its cron and preserves manual recovery. Keep it disabled until the
cron removal is merged; do not re-enable a revision containing the old cron.
For recovery use an authenticated direct request with the explicit report,
platform (Sentry only) and date after inspecting QStash logs and Discord.

Validation on 2026-10-09: a one-off scheduled QStash request reached the real
daily Worker within about one second of its specified UTC minute. Its invalid
report selector returned the expected 400 after authentication, before outbound
queries or Discord delivery. This proves scheduling/authentication, not a new
full report run. All three production URLs, secrets, retry settings and next
09:12 Eastern timestamps were independently checked. First ordinary morning
execution remains separate evidence; #3552's performance-data failure is unchanged.

## Failure visibility (how you'd know if this breaks)

The section-local failure behavior below applies to performance mode.
Sentry query/render failures attempt one unavailable report and fail that
platform's job. Missing destination configuration or an invalid date fails
before queries or delivery. A rejected delivery causes no second post.
Other mode jobs remain independent.

Default recovery requests run performance only. Recover each Sentry write-up
separately with `report=sentry` and the appropriate `platform=mac` or
`platform=android`, retaining the requested date and authentication.

Three independent signals:

1. **Section-local failures still deliver a report, then fail the run.** A
   `totals` failure, an auth failure, a malformed query/response, or a
   completeness-check mismatch inside adoption loses THAT SECTION only: the
   message is still posted, with "Adoption, unavailable today" in place of the
   figures and the version scorecard intact beside it, and then the worker
   returns non-2xx so QStash records a failed delivery. The scorecard behaves
   the same way in reverse, including when the appcast (the release list;
   see § Release list source) is unreachable after its retries. If both sections fail you get one message
   with both marked unavailable — never two messages, and never silence.

   `totals` is deliberately the ONE adoption query that never degrades to
   "temporarily unavailable" — it anchors `resolveBuckets`' completeness check
   and supplies the headline numbers, so there is no safe partial substitute.
   It costs the adoption section rather than the whole report.

   **Whole-run failures post a fixed notice and no report at all.** An invalid
   `?date=` override, a dev-ID resolution failure or overflow, and a release
   -resolution CONTRACT failure (misconfigured `APPCAST_URL`, a non-2xx that is
   not an outage, a malformed appcast, no eligible stable release) all mean there is nothing honest to
   send: at most one fixed "could not be generated" notice goes to Discord,
   carrying no error text, status code or response body, and the run rejects.
   A dev-ID list that will not resolve is never treated as "no dev accounts".

   **An over-budget payload sends NOTHING**, with zero webhook requests and no
   fallback notice. The report goes whole or not at all: a silently truncated
   report reads as complete, which is worse than a missing one.

   **Six deliberate exceptions degrade instead of failing (#1655, #1716,
   #1720).** `tier_a` (the polish-provider *settings* lookup) and 5 of the 6
   primary queries — `installs`, `onboard_activate`, `engineAndTierB`, `geo`,
   `top5` — can each independently degrade on an exhausted transient PostHog
   status (429/502/503/504). `tier_a` degrading still yields a full report
   with a near-top note ("the polish-provider breakdown is approximate
   because the settings lookup was temporarily unavailable when this report
   ran"), because
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
2. **If Discord itself is unreachable/erroring**, QStash records the failed
   delivery in Logs/DLQ. GitHub failure emails are no longer the signal for
   scheduled reports. This migration adds no automatic missing-report alert.
3. **A missed scheduled run entirely** has no automatic backfill. Inspect
   QStash Logs by the exact schedule ID and inspect Discord before making one
   deliberate recovery request with the `?date=` override.

**No automatic retries:** a 500 can follow partial or complete Discord delivery.
QStash must keep `retries: 0`; do not blindly replay a failed message. The Worker
has no durable deduplication, so separately triggered or transport-duplicated
requests can still post twice. GitHub's manual-recovery concurrency group does
not serialize QStash or direct HTTP requests. Avoid overlapping recovery calls.

## Rollback

For #3547 rollback, pause the three EnviousWispr QStash morning schedules and
inspect/drain their queued messages plus recorded direct invocations. Restore
the pinned previous reporting deployment while paused, restore its matching
report mode/trigger contract, then resume exactly one scheduling owner.
Preserve the Worker, credentials and existing reporting service. A source
revert alone does not restore the deployed version.

Coordinate native-alert rollback separately: disable replacement Discord
actions before restoring old consumers, restore the relay and bindings before
enabling those consumers, and restore its heartbeat last. The approved plan's
§3.4 and the operation receipts record the complete ordering and pinned versions.

## Shared infrastructure (#1589)

The PostHog transport and Discord delivery this worker uses now live in
`workers/shared/`, because `workers/weekly-digest` became a second consumer.
That extraction preserved the performance retry policy, concurrency cap and
`daily_report_*` query names. The separate #3547 Sentry modes have their own
bounded query names and budget over the same shared transport.

**Deploy consequence.** Each worker bundles its own snapshot at deploy time, so
a change under `workers/shared/` is live only in the workers redeployed since.
When a change touches that directory, deploy **weekly-digest first** and this
worker second: a broken shared change then lands on the worker already being
modified rather than on this one, which is the higher-value report and the one
that should not have changed at all. Full rule: `workers/shared/README.md`.

Native immediate-alert configuration and rollback: [NATIVE-SENTRY.md](../reporting/NATIVE-SENTRY.md).
