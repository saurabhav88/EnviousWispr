// Pre-deploy live-query smoke (issue #1092 plan, section 11).
// Runs the REAL worker HogQL against production PostHog, asserts the queries
// resolve + known-live events have non-zero denominators, then prints the
// heartbeat WITHOUT posting to Discord. Never posts anywhere.
//
// Run (bridges the key, no stdout leak):
//   ~/.claude/bin/get-key launch posthog-personal-api-key POSTHOG_KEY -- \
//     node workers/product-health/live-query-smoke.mjs
import {
  fetchHealth,
  evaluateLatency,
  evaluatePaste,
  evaluateAFM,
  evaluateTranscription,
  evaluateVolume,
  buildMessage,
} from "./src/index.js";

const env = {
  POSTHOG_PROJECT_ID: "354235",
  POSTHOG_PERSONAL_API_KEY: (process.env.POSTHOG_KEY || "").trim(),
};
if (!env.POSTHOG_PERSONAL_API_KEY) {
  console.error("POSTHOG_KEY env not set");
  process.exit(2);
}

const data = await fetchHealth(env);

// Assertions: queries resolved with rows, known-live denominators non-zero.
const fail = (m) => {
  console.error("SMOKE FAIL:", m);
  process.exit(1);
};
if (!data.latencyDays.length) fail("latency query returned no days");
if (!data.volumeDays.length) fail("volume query returned no days");
if (!(Number(data.seven.dictations_7d) > 0)) fail("7d dictations is zero - filter or window bug");
if (!(Number(data.seven.paste_total) > 0)) fail("7d paste_total is zero - filter or window bug");
// fallback_reason is expected all-null pre-release: afm_fr_rows may be 0.
console.log("columns OK; denominators non-zero.");
console.log("7d:", JSON.stringify(data.seven));
console.log("latency days:", data.latencyDays.length, "volume days:", data.volumeDays.length);
console.log("afm_fr_rows (expect 0 pre-release):", data.seven.afm_fr_rows);

const results = {
  latency: evaluateLatency(data.latencyDays),
  paste: evaluatePaste(data.seven),
  afm: evaluateAFM(data.seven),
  transcription: evaluateTranscription(data.seven),
  volume: evaluateVolume(data.volumeDays, data.t1ref),
};
console.log("t1ref (PostHog clock):", data.t1ref);
console.log("\nstates:", Object.fromEntries(Object.entries(results).map(([k, v]) => [k, v.state])));
console.log("\n--- heartbeat preview (NOT posted) ---");
console.log(buildMessage(results, data.versions));
