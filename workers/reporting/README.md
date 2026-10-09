# workers/reporting

Reporting policy lives here; HTTP and protocol live in `workers/shared`.

| Module | Runtime consumers |
|---|---|
| `sentry-writeup.js` | daily-report, independent Mac/Android Sentry modes |
| `sentry-section.js` | weekly-digest recap; daily-report uses its shared category labels and window/version helpers |
| `workers/shared/sentry.js` | daily-report, weekly-digest |

The daily performance mode reads PostHog only. The daily Sentry modes cover all
recorded builds and separate customer releases, developer builds and unknown
builds. They include occurrence trends, build labels, genuine first-seen status
and issue links. Identity counts are exact or explicitly lower bounds;
feedback correspondence is excluded. Weekly retains its production/release
recap policy. Those scopes differ by purpose, not by duplicated transport.

Native Sentry owns immediate first/return/feedback notifications. The custom
relay retired in #3547. Configuration, verification and rollback:
[NATIVE-SENTRY.md](NATIVE-SENTRY.md).

## Deployment

Each Worker bundles its own snapshot. A merge or git revert changes no live
Worker. Redeploy all consumers of the module changed, using the pinned-account
credential wrapper in `workers/daily-report/README.md`.

For `sentry-writeup.js`, deploy daily-report. For `sentry-section.js` or the
shared Sentry transport, deploy both reporting consumers:

```bash
cd workers/daily-report && npx wrangler deploy
cd ../weekly-digest     && npx wrangler deploy
```

The Daily Report cron workflow only invokes the deployed service. It must use
modes supported by that service. The default request remains performance.

## Tests

Daily `test/sentry-writeup.test.js` covers broader daily policy and cursor
contracts; `test/sentry-section.test.js` covers the weekly recap/shared helpers;
`test/report-modes.test.js` covers strict mode routing and vendor independence. Daily
and weekly suites cover their real entrypoints, and `worker-tests` runs them in
CI. A valid empty result differs from a missing/degraded measurement.
