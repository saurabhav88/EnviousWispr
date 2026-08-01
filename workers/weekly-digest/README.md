# weekly-digest

Posts one Discord digest every Monday: website traffic, tracked visitor
activity, downloads, and app usage for the previous seven days.

- Endpoint: `https://enviouswispr-weekly-digest.saurabhav.workers.dev`
- Schedule: Cloudflare cron `0 13 * * 1` (Monday 13:00 UTC). This worker holds
  one of the account's five free-plan cron slots (#1092).
- Source of truth for behaviour: `src/index.js`. Shared transport and delivery:
  `../shared/`.

## The trigger needs a secret now

The workers.dev URL is public. Until #1589 any request to it posted a real
digest to Discord. It now fails closed:

```bash
curl -fsS -H "x-trigger-secret: $SECRET" https://enviouswispr-weekly-digest.saurabhav.workers.dev
```

**Header only. There is no `?token=` form**, unlike the daily report: a secret
in a URL survives in browser and shell history, proxies and request logs, and
leaking it restores the unauthenticated posting this gate closes.

An unset `TRIGGER_SECRET` refuses every request, so a half-configured deploy
cannot be triggered at all. The cron path is unaffected. `-f` is required:
plain `curl -sS` exits 0 on an HTTP 401 or 500.

## Pre-deploy smoke, which posts nothing

```bash
~/.claude/bin/get-key launch posthog-personal-api-key POSTHOG_KEY -- \
  ~/.claude/bin/get-key launch cloudflare-global-api-key CF_KEY -- \
  node workers/weekly-digest/live-query-smoke.mjs
```

Runs the real `runDigest` against production with the Discord call intercepted,
prints per-query timings and the exact message, and **fails loud naming any
section that degraded**. A smoke check that prints "OK" while a section quietly
said "temporarily unavailable" is the defect it exists to catch.

## Deploy

Merging deploys nothing. There is no `wrangler deploy` in any workflow.

```bash
cd workers/weekly-digest
CLOUDFLARE_EMAIL=saurabhav@gmail.com \
  ~/.claude/bin/get-key launch cloudflare-global-api-key CLOUDFLARE_API_KEY -- \
  ~/.claude/bin/get-key launch cloudflare-account-id CLOUDFLARE_ACCOUNT_ID -- \
  npx wrangler deploy
```

**If the change touched `workers/shared/`, deploy this worker FIRST and the
daily report second.** Each worker bundles its own snapshot, so a broken shared
change then lands on the worker already being modified rather than on the
working daily report. Full rule: `workers/shared/README.md`.

Secrets are listed in `wrangler.toml`. Set with `npx wrangler secret put <NAME>`.

## Numbers that changed in #1589, and why

Each was wrong before, so a jump is a correction rather than a trend:

| Number | Was | Now | Cause |
|---|---|---|---|
| Active installs | 212 | 179 | summed two weekly Trends buckets over an 8-day window, double-counting anyone in both |
| Page views / visitors | 214 / 110 | 201 / 105 | counted `app.enviousstaging.com` and localhost dev servers |
| All-time downloads | truncated | complete | read only GitHub's first page: 30 of 45 releases |
| Any failure | `?` or `0` | "temporarily unavailable" | a failed Cloudflare call rendered a confident zero |

Figures are from the frozen window 2026-07-25 .. 2026-08-01, each checked
against an independently written oracle query.

## Things that will bite

- **`properties.<name>`, never a bare name.** Bare event-property names do not
  resolve in PostHog HogQL. A regex test enforces this.
- **The production predicate does not belong on website queries.**
  `productionClauseFor` always begins `properties.environment = 'production'`,
  and website events carry no environment property, so applying it returns
  ZERO. Website queries use a `$host` filter instead.
- **The download queries take neither.** `download_redirect` is emitted
  server-side with no `$host`; filtering by host silently drops every off-site
  redirect. Measured, not assumed.
- **`dev_ids` is an app-usage dependency, not a whole-run gate.** Its failure
  costs that one section. It is also the slowest query in the run (9.2s in a
  live smoke) because it scans all history by design.
- **PostHog project 354235 is shared with EnviousStaging**, which is why the
  host filter exists at all.

## The app-usage funnel, and what "install" means here

Founder definition, 2026-08-01: **an install is someone who has begun
onboarding**, finishing setup is its own step, and **one successful dictation**
is what counts as really using the app. The section reports all three, matching
the daily report's per-day shape:

```
160 people used EnviousWispr this week.
43 people began setting up.
40 people finished setting up. Of those, 35 also dictated.
```

"Used" means at least one successful dictation, not a launch. Someone who opens
the app and never dictates is not counted as a user.

"Began setting up" comes from the `onboarding.started` EVENT, fired on the
"Get Started" tap (`OnboardingV2View.swift:670`). It says setup BEGAN in the
window, not that it was a first time: Diagnostics has a "Restart Onboarding"
action (`DiagnosticsSettingsView.swift:106`), so an existing user can emit it
again. The wording stays at what the event proves.

**It is NOT `is_fresh_install`, and that distinction is the whole point** (#1910).
That property is a STATE, `onboardingState != .completed`, so it stayed true on
every launch until setup finished and re-counted anyone who never finished as a
new install every single week. Measured over 30 days: 21 ids re-counted under
the flag, 2 under the event. The week 2026-07-25..08-01 reads 43 rather than 46,
and 43 is exactly the number of ids whose first-ever launch fell in that window.

The daily report counts the same thing the same way. A source-guardrail test in
`workers/daily-report/test/report.test.js` asserts BOTH files, so the two cannot
drift apart silently.
