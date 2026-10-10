// Drives the REAL selected entrypoint; only Discord delivery is intercepted.
// Do not rapid-fire live triggers: read-only smoke, then one actual backfill.
// Print rendered counts/labels, never raw vendor bodies, IDs or credentials.
import { runReport, runSentryReport } from "./src/index.js";
let report = "performance", platform = null, dateOverride = null;
for (let i = 2; i < process.argv.length; i += 1) {
  const arg = process.argv[i];
  if (arg === "--report") report = process.argv[++i];
  else if (arg === "--platform") platform = process.argv[++i];
  else if (/^\d{4}-\d{2}-\d{2}$/.test(arg) && dateOverride === null) dateOverride = arg;
  else throw new Error("unsupported smoke argument");
}
if (!["performance", "sentry"].includes(report)
    || (report === "sentry" && !["mac", "android"].includes(platform))
    || (report === "performance" && platform !== null)) throw new Error("invalid smoke mode");
const MAC_CAPTURE = "https://smoke.invalid/mac";
const ANDROID_CAPTURE = "https://smoke.invalid/android";
const env = {
  POSTHOG_PROJECT_ID: "354235", POSTHOG_PERSONAL_API_KEY: process.env.POSTHOG_KEY,
  APPCAST_URL: "https://enviouswispr.com/appcast.xml",
  DISCORD_WEBHOOK_URL: MAC_CAPTURE, DISCORD_ANDROID_WEBHOOK_URL: ANDROID_CAPTURE,
  SENTRY_ORG: "envious-labs-llc", SENTRY_PROJECT_ID: "4511097112428544", SENTRY_PROJECT_SLUG: "enviouswispr",
  SENTRY_AUTH_TOKEN: process.env.SENTRY_KEY,
};
if (report === "performance" && !env.POSTHOG_PERSONAL_API_KEY) throw new Error("POSTHOG_KEY required for performance smoke");
if (report === "sentry" && !env.SENTRY_AUTH_TOKEN) throw new Error("SENTRY_KEY required for Sentry smoke");
const realFetch = globalThis.fetch;
const requests = [], captured = [];
globalThis.fetch = async (target, init) => {
  const text = String(target), url = new URL(text);
  if (text === MAC_CAPTURE || text === ANDROID_CAPTURE) {
    requests.push("captured-discord:" + (text === MAC_CAPTURE ? "mac" : "android"));
    captured.push(JSON.parse(init.body));
    return { status: 204 };
  }
  if (url.hostname === "discord.com" || url.hostname.endsWith(".discord.com") || url.hostname === "discordapp.com") {
    throw new Error("unexpected Discord destination in read-only smoke");
  }
  requests.push(url.hostname === "us.posthog.com" ? "posthog:" + JSON.parse(init.body).name
    : url.hostname === "us.sentry.io" ? "sentry:" + url.pathname
      : text === env.APPCAST_URL ? "appcast" : "other:" + url.hostname);
  return realFetch(target, init);
};
console.log("Mode: " + report + (platform ? "/" + platform : "") + "; date: " + (dateOverride || "yesterday, Eastern"));
let failure = null, quality = null;
try {
  if (report === "performance") await runReport(env, dateOverride);
  else quality = (await runSentryReport(env, platform, dateOverride)).dataQuality;
} catch (err) { failure = err; }
finally { globalThis.fetch = realFetch; }
console.log(requests.length + " outbound requests: " + requests.join(", "));
for (const payload of captured) {
  console.log(payload.content);
  for (const embed of payload.embeds || []) console.log(embed.title + "\n" + embed.description);
}
const problems = [];
if (failure) problems.push("run failed: " + failure.message);
if (captured.length !== 1) problems.push("expected exactly one captured report");
if (quality && Object.values(quality).some((v) => v !== true)) problems.push("Sentry detail query incomplete");
for (const payload of captured) for (const embed of payload.embeds || []) {
  if (/unavailable today/.test(embed.title) || /temporarily unavailable/.test(embed.description)) problems.push("required section degraded");
}
if (report === "performance" && requests.some((r) => r.startsWith("sentry:"))) problems.push("performance unexpectedly queried Sentry");
if (report === "sentry" && requests.some((r) => r.startsWith("posthog:") || r === "appcast")) problems.push("Sentry queried a performance dependency");
if (problems.length) {
  console.error("SMOKE FAILED: " + problems.join("; ") + ". Nothing posted.");
  process.exitCode = 1;
} else console.log("Smoke OK: selected mode rendered from real data; nothing posted.");
