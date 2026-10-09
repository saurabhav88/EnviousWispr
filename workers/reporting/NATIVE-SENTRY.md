# Native Sentry notifications and morning reports

Immediate notifications use Sentry's official Discord integration. A new error
group alerts once; an unresolved repeat stays quiet. A resolved or archived
issue that returns can alert again, with a 30-minute per-issue return cooldown.
Feedback has its own private notification path and is excluded from crash/error
write-ups. No SDK or customer privacy setting changes are part of this migration.

## Configuration

Organization: `envious-labs-llc`, US region. Existing Discord installation
`533382`, server `1486542033987309719`. All build environments are included.

| Platform | Project | Channel | First / return / feedback workflow IDs |
|---|---|---|---|
| Mac | `4511097112428544`, `enviouswispr` | `1486542034830495938` | `6139071` / `6139072` / `6139070` |
| Android | `4512117176795136`, `enviouswispr-android` | `1543122962792849470` | `6139068` / `6139069` / `6139067` |

First errors: `first_seen_event`, error category, level error or fatal, frequency
0. Returns: regression or reappearance, same filters, frequency 30. Feedback:
first seen, feedback category, frequency 0. Native cards include safe build,
environment, category, stage, OS and device tags plus issue links/actions.
Existing email behavior stays separate. The `enviousstaging-portal` project
retains its own email policy; it is outside these reporting/platform modes.

## Morning reporting

The existing Daily Report Worker serves independent authenticated modes:

- Default or `?report=performance`: PostHog adoption/version report, Mac channel.
- `?report=sentry&platform=mac`: Mac crash/error write-up, Mac channel.
- `?report=sentry&platform=android`: Android crash/error write-up, Android channel.

All accept `&date=YYYY-MM-DD` for a completed Eastern-day backfill. Otherwise
they report the previous `America/New_York` day, including DST. Send the existing
trigger secret in `x-trigger-secret`; do not put it in a URL. Invalid modes or
platforms refuse before external work. Android's missing destination fails,
never falls back to the Mac channel.

`.github/workflows/daily-report-ping.yml` keeps the existing `12 13 * * *` slot
and dispatches three jobs independently. GitHub can delay scheduled runs, so
that slot is not a delivery guarantee. A PostHog failure cannot prevent a
Sentry job. Reports have one delivery attempt and no outer blind retry.

Daily Sentry policy includes older and developer builds, with separate verified
customer-release, developer and unknown cohorts. It uses window occurrence
counts, genuine issue `firstSeen`, build labels and links. Sentry identity counts
are exact only when supported by complete grouping; otherwise they are lower
bounds. Missing measurements never become zero. Weekly keeps its existing
production/release recap and Monday cron.

## Verification and rollout state

Native first, quiet unresolved repeat, resolved return, archived reappearance
and private feedback were tested on both platforms with owned metadata-only
development events. The founder confirmed notifications on both phone and
desktop. Tests appear as `Owned native Sentry alert acceptance test (#3547)`,
`native_alert_acceptance` or feedback-routing acceptance tests. `Dev` alone
does not mean a synthetic test.

Completed-day Mac/Android write-ups were delivered independently. The existing
performance scorecard rejects a recorded custom build label (`2.4.7-ko1`),
tracked in #3552: adoption can be delivered with an unavailable version section
and HTTP500. This migration does not relax its measurement contract or claim a
complete performance pass.

**Deploy and source activation are separate.** A merge deploys no Worker. The
native rules and reporting service can be live before the new morning jobs are
on main. Verify the actual deployed versions, the workflow revision and the
retirement receipts; a branch, configured rule or accepted envelope alone is
not delivery proof. Source records and cutover receipts are retained locally in
`docs/audits/native-sentry-2026-10-08/` and linked from issue #3547.

## Retiring the custom relay

After native/report destination proof and the founder device check:

1. Remove only the custom action from Mac workflow `3202076`, preserving email.
   Remove the custom action and disable Android workflow `6120966`.
2. Clear exclusively owned subscriptions on `claude-triage-webhook-869aab` and
   make it unavailable for alert actions. Preserve the original integration
   installation `128433`, schema, signing source and identity for rollback.
3. Disable metric monitors `6856699`, `6856710`, `6856719`; preserve their
   historical alert/firing data. Their old names asserted categories that the
   `is:unresolved` query did not filter.
4. Disable and drain `Alerting Heartbeat` workflow `344958595` before deleting
   its Worker target. Retire only `enviouswispr-sentry-triage` in the pinned
   Cloudflare account. Keep KV `7003376387884d21b2e4ab191a37fcbf` and canonical
   credential sources. No namespace or integration deletion is required.
5. Remove relay runtime/checker sources and repair their consumer lists. TIK,
   TOK, backup prompts and Python eligibility helpers remain. Nightly reporting
   keeps the exact original Discord poster in its sole remaining caller.

Refresh ownership and preserve before-images. Review exact operation bytes
before writes, inspect uncertain outcomes before another operation, and read
back the changed identities. Verify unrelated workflows/bindings are unchanged,
native workflows enabled, KV/integration retained and relay absent.

## Rollback

First disable all six replacement native Discord workflows and pause/drain all
three morning jobs and any direct report invocations. Restore the pinned relay
source/bindings to the original account before restoring its custom consumers.
The saved source bundles and deployment/settings receipts are in the local
audit directory; canonical runtime credentials are restored through approved
`get-key launch` interfaces and the existing Mac/Android Keychain webhooks.
Never export credentials or deploy the Sentry admin/CI token as a read token.

Restore the original app events/alert-action setting and saved workflow bodies
only after the relay is reachable and a destination check passes. Restore old
metrics then, retaining history. Restore the paired old reporting service and
one-job schedule while paused, resume it, and restore heartbeat last. A git
revert alone restores no live resource. If the relay was deleted, rebuild it
from the saved original source/config and bind the preserved KV; its required
bindings are the original signing secret, both webhooks, worker read-only Sentry
token and GitHub issues read token. Preserve TIK/TOK and all canonical keys.
