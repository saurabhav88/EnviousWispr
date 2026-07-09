// Pre-deploy live-query smoke: runs the real HogQL queries against
// production PostHog, asserts they resolve and the §3.3a completeness check
// passes, prints the would-be Discord message, posts NOTHING.
//
// Usage:
//   ~/.claude/bin/get-key launch posthog-personal-api-key POSTHOG_KEY -- \
//     node workers/daily-report/live-query-smoke.mjs [YYYY-MM-DD]
//
// An optional date argument overrides "yesterday" (same override the
// deployed worker's ?date= param uses) for testing against a known day.

import { easternYesterdayWindowUTC, fetchReportData, resolveBuckets, buildMessage } from "./src/index.js";

const env = {
  POSTHOG_PROJECT_ID: "354235",
  POSTHOG_PERSONAL_API_KEY: process.env.POSTHOG_KEY,
};
if (!env.POSTHOG_PERSONAL_API_KEY) {
  console.error("POSTHOG_KEY not set - run via get-key launch posthog-personal-api-key POSTHOG_KEY -- ...");
  process.exit(1);
}

const dateOverride = process.argv[2] || null;
const { dateStr, startUTC, endUTC } = easternYesterdayWindowUTC(new Date(), dateOverride);
const win = `timestamp >= '${startUTC.toISOString().slice(0, 19).replace("T", " ")}' AND timestamp < '${endUTC
  .toISOString()
  .slice(0, 19)
  .replace("T", " ")}'`;

console.log(`Target Eastern day: ${dateStr} (${startUTC.toISOString()} to ${endUTC.toISOString()})`);

const data = await fetchReportData(env, win, endUTC);
console.log("\n=== raw data ===");
console.log(JSON.stringify(data, null, 2));

const buckets = resolveBuckets(data); // throws loudly on a completeness mismatch
console.log("\n=== resolution tiers (would be logged, never posted to Discord) ===");
console.log(buckets.resolutionSource);

const message = buildMessage(dateStr, data, buckets);
console.log("\n=== would-be Discord message ===");
console.log(message);

console.log("\nSmoke OK: queries resolved, completeness check passed, nothing posted.");
