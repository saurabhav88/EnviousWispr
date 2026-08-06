# workers/shared

Infrastructure shared by more than one Cloudflare Worker in this repo.

## Consumers

Per module, because they are no longer the same set. Redeploy every consumer of
the module you changed, not every worker in this table.

| Module | Consumers |
|---|---|
| `posthog.js` | `workers/daily-report`, `workers/weekly-digest` |
| `discord.js` | `workers/daily-report`, `workers/weekly-digest` |
| `sentry.js` | `workers/daily-report`, `workers/weekly-digest`, `workers/sentry-triage` |

Keep that table accurate. It is the deploy checklist. A single flat list was
enough until `sentry.js` arrived with a third consumer that uses only it
(#1965), and a flat list would now over-report the blast radius of a
posthog.js change and under-report a sentry.js one.

## THE RULE THAT BITES: editing a file here changes nothing in production

Each worker is bundled separately at `wrangler deploy` time and carries its own
snapshot of this code. So:

- **A merged PR deploys nothing.** No CI workflow runs `wrangler deploy`.
- **A change here is live only in the workers you have redeployed since.** Until
  then production is running two different versions of the "same" module, and
  nothing anywhere reports that.
- **`git revert` does not roll back production.** It changes the repo. Rolling
  back means reverting *and* redeploying every consumer.

After changing anything in this directory:

```bash
cd workers/weekly-digest && npx wrangler deploy    # deploy the CHANGED consumer first
cd ../daily-report      && npx wrangler deploy     # then the one that should not change
```

Deploy the worker whose behaviour is meant to change **first**. If the shared
change is broken, the failure lands on the worker that was already being
modified, and the healthy one is never touched. Credentials wrapper and the
`curl -fsS` verification step: `workers/daily-report/README.md` § Deploy.

## What belongs here

Transport and protocol only:

- `posthog.js` — HTTP transport, retry policy, the concurrency limiter, dev-ID
  resolution, the production predicate, SQL literal escaping, row conversion.
- `discord.js` — Discord's transport limits and the supported subset of its
  payload protocol, plus one-attempt delivery.
- `sentry.js` — Sentry's HTTP, authentication, retryable-status set, bounded
  retry, deadline enforcement, response-shape validation and row normalization.
  Which window to ask about, which releases count, and what an error category
  MEANS are all product judgement and live in `workers/reporting/sentry-section.js`
  instead.

## What must NOT come here

Metric SQL, report windows, section failure policy, degrade wording, and
anything a reader would recognise as a product judgement. Those belong to the
worker that owns the report.

Two specific traps, both learned the hard way:

1. **Do not let one consumer's layout become everyone's protocol.** `discord.js`
   originally allowed only `title` and `description` because that was the daily
   report's chosen shape. Discord permits `color`, `footer` and `timestamp`, so
   refusing them was never a protocol limit — it just meant the weekly digest
   would have had to drop its brand colour to reuse the transport (#1589).
   A field is refused here only when this module cannot count it against
   Discord's 6000-character budget.
2. **Do not add a default that hides which worker did something.** `workerLabel`
   is required with no fallback for exactly this reason: a default would file
   one worker's PostHog queries under another's name, which reads as correct in
   every place a human would look.

## Tests

There is no test package here. The shared modules are exercised by
`workers/daily-report/test/report.test.js`, which is where they were tested
before the extraction, by `workers/daily-report/test/sentry-section.test.js`
(`sentry.js`), and by `workers/weekly-digest/test/digest.test.js`.
Both suites run in CI via the `worker-tests` job feeding the required
`build-check`, so a change here that breaks either consumer blocks the PR.
