# Download-Notification Counter (issue #1691)

Replaces a brittle PostHog Hog script that ran a live `SELECT count()` query
against PostHog's own Query API on every download click — a query that shared
PostHog's project-wide 3-concurrent-query ceiling with every other consumer in
the account, and intermittently rendered `Download #?!` in Discord under load
(confirmed via live Hog-function logs, 2026-07-19: 3x-retried 504s/timeouts).

This Worker owns the count instead. PostHog's "Discord: Download Notification"
CDP destination becomes a thin relay: it POSTs the event's fields here, and
this Worker decides whether it qualifies, de-duplicates rage-clicks by IP,
increments its own counter (a single Durable Object, `DownloadCounter`), and
posts to Discord itself — with retry-safe delivery so a PostHog-side retry of
the same event resumes instead of double-counting or silently dropping.

Plan (design rationale, five grounded-review rounds, every finding and fix):
`docs/feature-requests/issue-1691-2026-07-19-download-counter-worker.md`.

## Why a Durable Object, not Workers KV

Workers KV enforces a 60-second minimum write expiration and at most one
write per second per key — both of which the counter's read-increment-write
pattern would violate under the exact bursty retry traffic (PostHog's own 3x
automatic fetch retry) this fix exists to survive. A Durable Object gives
transactional, single-threaded-between-awaits storage instead.

## Develop / test

```bash
cd workers/download-counter
node --test
```

Pure-logic tests only (mocked Durable Object storage, mocked `fetch` for
Discord) — no network calls, no PostHog, no real Discord posts.

## Deploy (one-time)

Cloudflare secrets are write-only — `wrangler secret put` accepts a value but
there is no way to read it back later. `TRIGGER_SECRET` is needed again by
the smoke script and the PostHog Hog relay's `workerSecret` input, so it must
be generated into Keychain FIRST (same pattern as the existing
`enviouswispr.discord-webhook-*` items — see
`~/.claude/knowledge/secrets-management.md` RULE: webhooks-read-from-keychain),
then read from Keychain into `wrangler secret put`, never generated and
piped away in one step:

```bash
cd workers/download-counter
npx wrangler deploy

# secrets (never committed; generate into Keychain first, THEN set on Cloudflare):
security add-generic-password -U -A -a m4pro_sv -s enviouswispr.download-counter-trigger-secret -w "$(openssl rand -hex 32)"
security add-generic-password -U -A -a m4pro_sv -s enviouswispr.download-counter-ip-hash-secret -w "$(openssl rand -hex 32)"

security find-generic-password -w -a m4pro_sv -s enviouswispr.discord-webhook-downloads | npx wrangler secret put DISCORD_WEBHOOK_URL
security find-generic-password -w -a m4pro_sv -s enviouswispr.download-counter-trigger-secret | npx wrangler secret put TRIGGER_SECRET
security find-generic-password -w -a m4pro_sv -s enviouswispr.download-counter-ip-hash-secret | npx wrangler secret put IP_HASH_SECRET

# smoke environment (separate deployment, separate Durable Object namespace by
# construction — see wrangler.toml comment). Distinct secrets from
# production, so a leaked smoke secret can't authenticate against it:
npx wrangler deploy --env smoke
security add-generic-password -U -A -a m4pro_sv -s enviouswispr.download-counter-smoke-trigger-secret -w "$(openssl rand -hex 32)"
security add-generic-password -U -A -a m4pro_sv -s enviouswispr.download-counter-smoke-ip-hash-secret -w "$(openssl rand -hex 32)"

security find-generic-password -w -a m4pro_sv -s enviouswispr.discord-webhook-downloads | npx wrangler secret put DISCORD_WEBHOOK_URL --env smoke
security find-generic-password -w -a m4pro_sv -s enviouswispr.download-counter-smoke-trigger-secret | npx wrangler secret put TRIGGER_SECRET --env smoke
security find-generic-password -w -a m4pro_sv -s enviouswispr.download-counter-smoke-ip-hash-secret | npx wrangler secret put IP_HASH_SECRET --env smoke
```

## Pre-cutover smoke test

Run against the isolated `smoke` deployment ONLY — never the production
Worker, and never before the real production seed (§3/§9 of the plan explain
why touching production before seeding would corrupt the real tally and lock
out the real `/seed` call):

```bash
DOWNLOAD_COUNTER_SMOKE_URL="https://enviouswispr-download-counter-smoke.saurabhav.workers.dev" \
DOWNLOAD_COUNTER_SMOKE_SECRET="$(security find-generic-password -w -a m4pro_sv -s enviouswispr.download-counter-smoke-trigger-secret)" \
node workers/download-counter/live-endpoint-smoke.mjs
```

Confirms: a real Discord post lands (prefixed `🧪 SMOKE TEST — ignore`), a
retry of the same event resumes without re-incrementing, a duplicate same-IP
event is suppressed, and two genuinely concurrent same-event requests never
both post (the one check an in-memory mock can't reproduce).

## Production seed + cutover

**Prep first (any time before cutover — these don't touch the live counter and don't need to happen close to the cutover moment):**

- In the PostHog CDP destination editor for "Discord: Download Notification" (`019d35b0-c128-0000-30a8-5fc2570a8a88`), send a test event through the CURRENT (old) script and confirm `event.uuid` is populated in the payload — the relay's retry-safety depends on it being a stable per-event id, not assumed. If it is ever absent, use `event.properties.$insert_id` instead and update `hog-relay.hog` accordingly before proceeding. This is safe pre-cutover: the old script doesn't touch the new Worker at all.
- Save a rollback backup of the CURRENT live `hog`/`inputs`/`inputs_schema` fields: `GET /api/projects/354235/hog_functions/019d35b0-c128-0000-30a8-5fc2570a8a88/`.
- Have the exact `POST /seed` and PATCH commands ready to paste (below), so the live sequence runs with no thinking time in between.

**Then, in immediate succession — measuring and cutting over are two ends of the SAME race window** (a real download landing between "measure" and "PATCH" would be counted by the old script but never reach the new counter's seed, permanently undercounting by one). Minimizing the gap between these three steps is the actual mitigation; do not do anything else between them:

1. Measure the live true count (the exact query the old Hog script ran):
   ```bash
   ~/.claude/bin/get-key launch posthog-personal-api-key POSTHOG_KEY -- python3 -c "
   import os, json, urllib.request
   req = urllib.request.Request(
       'https://us.posthog.com/api/projects/354235/query/',
       data=json.dumps({'query': {'kind': 'HogQLQuery', 'query':
           \"SELECT count() FROM events WHERE event='download_clicked' OR (event='download_redirect' AND coalesce(properties.excluded_reason,'')='')\"
       }}).encode(),
       headers={'Authorization': f'Bearer {os.environ[\"POSTHOG_KEY\"]}', 'Content-Type': 'application/json'},
       method='POST',
   )
   print(json.loads(urllib.request.urlopen(req).read())['results'])
   "
   ```
2. `POST /seed` on the PRODUCTION deployment with that number (secret-gated, refuses any call once the counter is initialized):
   ```bash
   curl -X POST https://enviouswispr-download-counter.saurabhav.workers.dev/seed \
     -H "x-trigger-secret: $(security find-generic-password -w -a m4pro_sv -s enviouswispr.download-counter-trigger-secret)" \
     -H "Content-Type: application/json" \
     -d '{"total": <N>}'
   ```
   Verify the persisted value in the response.
3. Immediately PATCH the destination's `hog` field to the contents of `hog-relay.hog` (this file, committed) and `inputs_schema` to `[workerUrl (string, required), workerSecret (string, secret, required)]` — dropping `webhookUrl`/`phApiKey`. Set `workerUrl` to the production Worker's URL and `workerSecret` to the value in `enviouswispr.download-counter-trigger-secret`.

**Verify with a REAL download, never a synthetic PostHog test event.** Once the destination is PATCHed, PostHog's "send test event" feature would invoke the actual live relay against the production Worker — it is not a sandbox — permanently incrementing the real counter and posting an unmarked, indistinguishable-from-real message claiming someone downloaded EnviousWispr when nobody did. Instead, trigger (or wait for) one genuine download and confirm the Discord post carries `<N>+1`. This also verifies the full real pipeline end to end, not just the Worker in isolation.
