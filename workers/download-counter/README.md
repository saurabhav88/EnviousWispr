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

```bash
cd workers/download-counter
npx wrangler deploy

# secrets (never committed):
security find-generic-password -w -a m4pro_sv -s enviouswispr.discord-webhook-downloads | npx wrangler secret put DISCORD_WEBHOOK_URL
openssl rand -hex 32 | npx wrangler secret put TRIGGER_SECRET
openssl rand -hex 32 | npx wrangler secret put IP_HASH_SECRET

# smoke environment (separate deployment, separate Durable Object namespace by
# construction — see wrangler.toml comment):
npx wrangler deploy --env smoke
security find-generic-password -w -a m4pro_sv -s enviouswispr.discord-webhook-downloads | npx wrangler secret put DISCORD_WEBHOOK_URL --env smoke
openssl rand -hex 32 | npx wrangler secret put TRIGGER_SECRET --env smoke
openssl rand -hex 32 | npx wrangler secret put IP_HASH_SECRET --env smoke
```

## Pre-cutover smoke test

Run against the isolated `smoke` deployment ONLY — never the production
Worker, and never before the real production seed (§3/§9 of the plan explain
why touching production before seeding would corrupt the real tally and lock
out the real `/seed` call):

```bash
DOWNLOAD_COUNTER_SMOKE_URL="https://enviouswispr-download-counter-smoke.saurabhav.workers.dev" \
DOWNLOAD_COUNTER_SMOKE_SECRET="<the smoke env's TRIGGER_SECRET>" \
node workers/download-counter/live-endpoint-smoke.mjs
```

Confirms: a real Discord post lands (prefixed `🧪 SMOKE TEST — ignore`), a
retry of the same event resumes without re-incrementing, a duplicate same-IP
event is suppressed, and two genuinely concurrent same-event requests never
both post (the one check an in-memory mock can't reproduce).

## Production seed + cutover (one time, in this exact order)

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
     -H "x-trigger-secret: <production TRIGGER_SECRET>" -H "Content-Type: application/json" \
     -d '{"total": <N>}'
   ```
3. Verify the persisted value in the response.
4. PATCH the PostHog Hog relay script (see plan §3/§10) to the new thin relay, saving a rollback backup first.
5. Send one real PostHog destination test event; confirm the Discord post carries `<N>+1`.
