# workers/reporting

Report POLICY shared by more than one digest Worker. Product judgement lives
here; transport lives in `workers/shared`.

## Consumers

- `workers/daily-report` (yesterday)
- `workers/weekly-digest` (the last seven whole days)

Keep that list accurate. It is the deploy checklist.

## THE RULE THAT BITES: editing a file here changes nothing in production

Identical to `workers/shared/README.md`, and it applies for the same reason:
each Worker is bundled separately at `wrangler deploy` time and carries its own
snapshot of this code.

- **A merged PR deploys nothing.** No CI workflow runs `wrangler deploy`.
- **A change here is live only in the Workers you have redeployed since.**
- **`git revert` does not roll back production.** Rolling back means reverting
  *and* redeploying every consumer.

After changing a file **in this directory** (two consumers — read the next
paragraph before assuming that covers you):

```bash
cd workers/daily-report  && npx wrangler deploy    # deploy the CHANGED consumer first
cd ../weekly-digest      && npx wrangler deploy
```

There are **two deployment sets, and they are not the same set**:

| Module | Consumers |
|---|---|
| `workers/reporting/sentry-section.js` | daily-report, weekly-digest |
| `workers/shared/sentry.js` | daily-report, weekly-digest, **sentry-triage** |

A digest-policy change needs the two digests redeployed. A change to the Sentry
transport underneath it needs all three, including the triage Worker, which
consumes the transport and none of the policy.

## Why this directory exists at all

`workers/shared/README.md` says, in its own words: transport and protocol only,
and "metric SQL, report windows, section failure policy, degrade wording, and
anything a reader would recognise as a product judgement" must not come here.

The Sentry section is exactly that forbidden half. It decides which releases
count, whether an `error.category` means the person lost their dictation or
merely got a worse one, and how to say so in a sentence the founder reads. Both
digests need the identical answer to all three, and duplicating it would let the
classification and the wording drift apart silently.

So the split is: `workers/shared/sentry.js` owns HTTP, auth, retry and
response-shape validation; `workers/reporting/sentry-section.js` owns the
queries, the classification and every word.

## What must NOT come here

- Anything a THIRD Worker with a different contract needs. `sentry-triage` is
  webhook-driven and deadline-bound (20s lookup, 28s operation); the digests are
  scheduled and tolerant. It imports the shared transport and keeps its own
  query, formatter and throttle, deliberately.
- Transport concerns. They belong one directory over.

## Tests

There is no test package here. `workers/daily-report/test/sentry-section.test.js`
covers this module and the transport, and both digest suites cover the
integration. All three run in CI via the `worker-tests` job feeding the required
`build-check`, so a change here that breaks either consumer blocks the PR.
