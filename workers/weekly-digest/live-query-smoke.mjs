// Pre-deploy live-query smoke: runs the REAL weekly digest against production
// PostHog, Cloudflare and GitHub, prints the exact message that would be sent,
// and posts NOTHING to Discord.
//
// Usage (secrets injected by the launcher, never inline):
//   ~/.claude/bin/get-key launch posthog-personal-api-key POSTHOG_KEY -- \
//     ~/.claude/bin/get-key launch cloudflare-global-api-key CF_KEY -- \
//     node workers/weekly-digest/live-query-smoke.mjs
//
// Deliberately drives `runDigest` rather than reassembling the digest from
// parts. A smoke script with its own copy of the orchestration proves only that
// the copy works, and that exact shape left the daily report's smoke script
// broken and unnoticed for weeks because nothing exercised it. The Discord call
// is intercepted, so the ONLY difference from a production run is that the
// payload is printed instead of delivered.
//
// FAILS LOUD when a section degrades. Printing "Smoke OK" while a section
// quietly said "temporarily unavailable" is the defect this check exists to
// catch, and it is one the daily report's smoke script actually shipped (#1720).

import { runDigest } from "./src/index.js";

const CAPTURED_WEBHOOK = "https://smoke.invalid/never-posted";

const env = {
  POSTHOG_PROJECT_ID: "354235",
  POSTHOG_PERSONAL_API_KEY: process.env.POSTHOG_KEY,
  CF_ZONE_ID: "b4416a0f0ebd699e96969a331c7ad7ff",
  CF_EMAIL: process.env.CF_EMAIL || "saurabhav@gmail.com",
  CF_API_KEY: process.env.CF_KEY,
  GITHUB_REPO: "saurabhav88/EnviousWispr",
  GITHUB_TOKEN: process.env.GITHUB_TOKEN,
  DISCORD_WEBHOOK_URL: CAPTURED_WEBHOOK,
  SENTRY_ORG: "envious-labs-llc",
  SENTRY_PROJECT_ID: "4511097112428544",
  SENTRY_PROJECT_SLUG: "enviouswispr",
  SENTRY_AUTH_TOKEN: process.env.SENTRY_KEY,
};

// SENTRY_KEY is required for the same reason the others are: a smoke that
// silently skips a section proves nothing about it.
const missing = [
  ["POSTHOG_KEY", env.POSTHOG_PERSONAL_API_KEY],
  ["CF_KEY", env.CF_API_KEY],
  ["SENTRY_KEY", env.SENTRY_AUTH_TOKEN],
].filter(([, value]) => !value).map(([name]) => name);
if (missing.length) {
  console.error(`missing ${missing.join(", ")} - see the usage header for the launcher form`);
  process.exit(1);
}

const realFetch = globalThis.fetch;
let captured = null;
const timings = [];

globalThis.fetch = async (url, init) => {
  const target = String(url);
  if (target.startsWith(CAPTURED_WEBHOOK)) {
    // The one request that must never reach the network.
    captured = JSON.parse(init.body);
    return { status: 204 };
  }
  const started = Date.now();
  const res = await realFetch(url, init);
  const name = target.includes("posthog.com")
    ? JSON.parse(init.body).name
    : new URL(target).host;
  timings.push({ name, ms: Date.now() - started, status: res.status });
  return res;
};

let failure = null;
try {
  await runDigest(env);
} catch (err) {
  // runDigest throws AFTER delivering a partial digest when a section degraded,
  // so a throw here does not mean nothing was produced.
  failure = err;
}

for (const t of timings) {
  console.log(`  ${String(t.ms).padStart(6)}ms  ${String(t.status).padStart(3)}  ${t.name}`);
}
console.log();

if (!captured) {
  console.error("FAIL: no payload was produced");
  if (failure) console.error(String(failure.message));
  process.exit(1);
}

console.log(captured.content);
for (const embed of captured.embeds || []) {
  console.log(`\n--- ${embed.title} ---`);
  console.log(embed.description);
}
console.log();

// A degraded section is a FAILURE of this check, named, not a footnote.
const degraded = (captured.embeds || [])
  .filter((e) => e.description.includes("temporarily unavailable"))
  .map((e) => e.title);
if (degraded.length) {
  console.error(`FAIL: section(s) unavailable during the smoke run: ${degraded.join(", ")}`);
  if (failure) console.error(String(failure.message));
  process.exit(1);
}
if (failure) {
  console.error(`FAIL: ${failure.message}`);
  process.exit(1);
}
console.log("Smoke OK: every section returned real data, nothing was posted to Discord.");
