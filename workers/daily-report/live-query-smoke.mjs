// Pre-deploy live-query smoke: runs the REAL report against production
// PostHog and GitHub, prints the exact message that would be sent, and posts
// NOTHING to Discord.
//
// Usage (with POSTHOG_KEY already injected):
//   node workers/daily-report/live-query-smoke.mjs [YYYY-MM-DD]
// See workers/daily-report/README.md for the secret-safe launcher.
//
// An optional date argument overrides "yesterday" (the same override the
// deployed worker's ?date= param uses) for testing against a known day.
//
// Deliberately drives `runReport` rather than reassembling the report from
// parts. A smoke script with its own copy of the orchestration proves only
// that the copy works, and it was exactly that shape - importing `buildMessage`
// and `fetchReportData` directly - that left this file broken and unnoticed
// when the report gained its scorecard, because nothing exercised it. The
// Discord call is intercepted, so the ONLY difference from a production run is
// that the payload is printed instead of delivered.

import { runReport } from "./src/index.js";

const CAPTURED_WEBHOOK = "https://smoke.invalid/never-posted";

const env = {
  POSTHOG_PROJECT_ID: "354235",
  POSTHOG_PERSONAL_API_KEY: process.env.POSTHOG_KEY,
  GITHUB_REPO: "saurabhav88/EnviousWispr",
  DISCORD_WEBHOOK_URL: CAPTURED_WEBHOOK,
  SENTRY_ORG: "envious-labs-llc",
  SENTRY_PROJECT_ID: "4511097112428544",
  SENTRY_PROJECT_SLUG: "enviouswispr",
  SENTRY_AUTH_TOKEN: process.env.SENTRY_KEY,
};
if (!env.POSTHOG_PERSONAL_API_KEY) {
  console.error("POSTHOG_KEY not set - run via get-key launch posthog-personal-api-key POSTHOG_KEY -- ...");
  process.exit(1);
}
// Sentry is REQUIRED here, not optional. The whole point of a pre-deploy
// smoke is to prove the section answers against live Sentry before the
// worker is deployed; skipping it on a missing key would print "Smoke OK"
// for a run that never exercised the new section at all.
if (!env.SENTRY_AUTH_TOKEN) {
  console.error("SENTRY_KEY not set - the Sentry section would not be exercised, so this smoke proves nothing about it");
  process.exit(1);
}

const realFetch = globalThis.fetch;
const requests = [];
let captured = null;

globalThis.fetch = async (url, init) => {
  const target = String(url);
  requests.push(
    target.startsWith("https://us.posthog.com")
      ? `posthog:${JSON.parse(init.body).name}`
      : target.startsWith("https://api.github.com")
        ? "github:releases"
        : target.startsWith("https://us.sentry.io")
          ? `sentry:${new URL(target).pathname}`
          : target
  );
  if (target === CAPTURED_WEBHOOK) {
    captured = JSON.parse(init.body);
    return { status: 204 };
  }
  return realFetch(url, init);
};

const dateOverride = process.argv[2] || null;
console.log(`Target: ${dateOverride ? `${dateOverride} (override)` : "yesterday, Eastern"}`);

let failure = null;
try {
  await runReport(env, dateOverride);
} catch (err) {
  failure = err;
}

console.log(`\n=== ${requests.length} outbound requests ===`);
console.log(requests.join("\n"));

if (captured) {
  // Counts, labels and rates only - the same posture the deployed worker holds
  // to. A rendered report contains no per-user rows by construction, so
  // printing it whole is safe in a way that dumping raw query results was not
  // (a Codex cloud review catch on PR #1437).
  console.log("\n=== would-be Discord message ===");
  console.log(captured.content);
  for (const embed of captured.embeds ?? []) {
    console.log(`\n--- ${embed.title} ---\n${embed.description}`);
  }
}

// A missing or unavailable section means PostHog, GitHub or a calculation did
// not answer DURING this smoke run - the exact thing a pre-deploy check exists
// to prove did not happen. Printing "Smoke OK" regardless would let a real
// degradation pass silently, so this fails loud and lets the caller decide
// whether to retry rather than deploy on unproven data (#1720).
const problems = [];
if (failure) problems.push(`run failed: ${failure.message}`);
if (!captured) problems.push("no payload was assembled");
for (const embed of captured?.embeds ?? []) {
  if (/unavailable today/.test(embed.title)) problems.push(`section unavailable: ${embed.title}`);
  if (/temporarily unavailable/.test(embed.description)) problems.push(`degraded subsection in ${embed.title}`);
}

if (problems.length) {
  console.error(
    `\nSMOKE FAILED (${problems.length}):\n  ${problems.join("\n  ")}\n` +
      "Nothing posted; retry later, spaced out (see README verification-methodology note)."
  );
  process.exit(1);
}
console.log("\nSmoke OK: every section rendered from live data, nothing posted.");
