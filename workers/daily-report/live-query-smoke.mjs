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

// Aggregate-only summary. Deliberately does NOT dump `data.engineAndTierB` /
// `data.tierA` (per-user rows keyed by raw distinct_id) - a Codex cloud
// review catch (PR #1437): even though distinct_ids are opaque, printing the
// full per-user array to a local terminal/log is broader exposure than a
// smoke test needs. Counts/labels only, matching the same posture the
// deployed worker itself holds to (src/index.js top-of-file privacy note).
console.log("\n=== aggregate summary (counts/labels only, no per-user rows) ===");
console.log({
  freshInstalls: data.freshInstalls,
  installsDegraded: data.installsDegraded,
  onboarded: data.onboarded,
  activated: data.activated,
  onboardActivateDegraded: data.onboardActivateDegraded,
  netDictations: data.netDictations,
  totalUsers: data.totalUsers,
  engineAndTierBRowCount: data.engineAndTierB.length,
  engineAndTierBDegraded: data.engineAndTierBDegraded,
  tierARowCount: data.tierA.length,
  tierADegraded: data.tierADegraded, // true => tier-a exhausted its retry; breakdown is approximate (#1655)
  geo: data.geo,
  geoDegraded: data.geoDegraded,
  top5Counts: data.top5.map((u) => u.n), // values only, no distinct_id
  top5Degraded: data.top5Degraded,
});

// Mirrors runReport's own engineAndTierBDegraded bypass (#1720): calling
// resolveBuckets unconditionally here would throw its completeness check
// against the empty per-user rows a degraded engineAndTierB leaves behind.
const buckets = data.engineAndTierBDegraded
  ? { engineBuckets: {}, polishBuckets: {}, resolutionSource: { settings: 0, actual_dictation: 0, shipped_default: 0 } }
  : resolveBuckets(data); // throws loudly on a completeness mismatch
console.log("\n=== resolved buckets + resolution tiers (would be logged, never posted to Discord) ===");
console.log({ engineBuckets: buckets.engineBuckets, polishBuckets: buckets.polishBuckets });
console.log(buckets.resolutionSource);

const message = buildMessage(dateStr, data, buckets);
console.log("\n=== would-be Discord message ===");
console.log(message);

// A degraded section means PostHog didn't answer after 3 attempts DURING
// this smoke run - the exact thing a pre-deploy smoke check exists to prove
// didn't happen. Codex code-diff review caught that printing "Smoke OK"
// regardless would let a real degradation pass silently (#1720); fail loud
// and let the caller decide whether to retry rather than deploy on
// unproven data.
const degradedSections = [
  ["installsDegraded", "installs"],
  ["onboardActivateDegraded", "onboard_activate"],
  ["engineAndTierBDegraded", "engine_and_tier_b"],
  ["geoDegraded", "geo"],
  ["top5Degraded", "top5"],
  ["tierADegraded", "tier_a"],
].filter(([key]) => data[key]).map(([, name]) => name);

if (degradedSections.length) {
  console.error(`\nSmoke FAILED: ${degradedSections.join(", ")} degraded during this run - not a clean pass. Nothing posted; retry later, spaced out (see README verification-methodology note).`);
  process.exit(1);
}

console.log("\nSmoke OK: all queries resolved cleanly, completeness check passed, nothing posted.");
