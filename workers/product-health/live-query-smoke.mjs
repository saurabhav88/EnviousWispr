// Pre-deploy live-query smoke (issue #1092 plan, section 11; reliability +
// evaluateHealthData wiring per issue #1589).
// Runs the REAL worker HogQL against production PostHog, asserts the queries
// resolve + known-live events have non-zero denominators + no query degraded,
// then prints the heartbeat WITHOUT posting to Discord. Never posts anywhere.
//
// Calls the same evaluateHealthData() production uses (issue #1589) instead
// of duplicating the evaluate-and-degrade wiring, closing a real drift: this
// script used to omit the backendAttributionBlackout computation entirely.
//
// Run (bridges the key, no stdout leak):
//   ~/.claude/bin/get-key launch posthog-personal-api-key POSTHOG_KEY -- \
//     node workers/product-health/live-query-smoke.mjs
import { fetchHealth, evaluateHealthData, buildMessage } from "./src/index.js";

const env = {
  POSTHOG_PROJECT_ID: "354235",
  POSTHOG_PERSONAL_API_KEY: (process.env.POSTHOG_KEY || "").trim(),
};
if (!env.POSTHOG_PERSONAL_API_KEY) {
  console.error("POSTHOG_KEY env not set");
  process.exit(2);
}

const data = await fetchHealth(env);

// Assertions: queries resolved with rows, known-live denominators non-zero,
// and no query degraded. A clean-looking response shape is not proof the
// query actually succeeded end to end - it may have degraded to an empty
// fallback after exhausting retries, which a shape-only check would miss.
const fail = (m) => {
  console.error("SMOKE FAIL:", m);
  process.exit(1);
};
if (!data.latencyDays.length) fail("latency query returned no days");
if (!data.volumeDays.length) fail("volume query returned no days");
if (!(Number(data.seven.dictations_7d) > 0)) fail("7d dictations is zero - filter or window bug");
if (!(Number(data.seven.paste_total) > 0)) fail("7d paste_total is zero - filter or window bug");
if (!data.onboardingDays.length) fail("onboarding query returned no days");
if (!Object.keys(data.backendTranscriptionDays).length) fail("backend transcription query returned no backends");

const degradedQueries = [
  ["latency", data.latencyDegraded],
  ["seven-day aggregate", data.sevenDayDegraded],
  ["versions", data.versionsDegraded],
  ["onboarding", data.onboardingDegraded],
  ["backend transcription", data.backendTranscriptionDegraded],
  ["onboarding versions", data.onboardingVersionsDegraded],
  ["backend versions", data.backendVersionsDegraded],
]
  .filter(([, degraded]) => degraded)
  .map(([name]) => name);
if (degradedQueries.length) fail(`queries degraded after retries: ${degradedQueries.join(", ")}`);

// fallback_reason shipped in v2.3.1; afm_fr_rows may still be 0 on a
// genuinely quiet week for eligible fallback-reason rows.
console.log("columns OK; denominators non-zero; no query degraded.");
console.log("7d:", JSON.stringify(data.seven));
console.log("latency days:", data.latencyDays.length, "volume days:", data.volumeDays.length);
console.log("onboarding days:", data.onboardingDays.length, "backends:", Object.keys(data.backendTranscriptionDays));
console.log("afm_fr_rows:", data.seven.afm_fr_rows);
console.log("t1ref (PostHog clock):", data.t1ref);

const results = evaluateHealthData(data);
const STATE_KEYS = ["latency", "paste", "afm", "transcription", "volume", "onboardingAbandon", "onboardingBlackout"];
console.log(
  "\nstates:",
  Object.fromEntries(STATE_KEYS.map((k) => [k, results[k].state])),
  "| backendTranscription:",
  results.backendTranscription.map((row) => `${row.backend}:${row.state}`),
  "| backendAttributionBlackout:",
  results.backendAttributionBlackout
);
console.log("\n--- heartbeat preview (NOT posted) ---");
console.log(buildMessage(results));
