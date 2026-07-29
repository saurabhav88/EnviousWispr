/**
 * EnviousWispr Daily Performance Report - Cloudflare Worker (issue #1433)
 *
 * Runs once a day via a secret-gated HTTP trigger (scheduling lives in
 * .github/workflows/daily-report-ping.yml, not a Cloudflare cron - the CF
 * account is at its 5-cron free-plan limit, see #1092). Reads PostHog events
 * over the previous COMPLETE Eastern calendar day and posts a plain-English
 * summary to Discord (EnviousNotes): installs/onboarding/activation, total
 * active users, transcription-engine choice by user, AI-polish choice by
 * user (their CONFIGURED choice, not per-dictation runtime outcome - a
 * dictation that silently skipped polish for a by-design reason still
 * counts toward whatever provider the user has selected), net dictation
 * volume, top-5 countries, and the top-5 heaviest users by volume.
 *
 * Gates nothing, alerts on nothing - purely a daily digest. Plan + full
 * metric-definition rationale: docs/feature-requests/issue-1433-2026-07-09-daily-report.md
 *
 * Privacy: output and logs are counts / rates / labels only. Never a raw
 * transcript, a PostHog response body, a Discord response body, or the
 * trigger secret.
 */

import { windowClause } from "./lib/posthog.js";
import { fetchReportData, resolveBuckets } from "./adoption.js";

export default {
  async fetch(request, env) {
    // Manual trigger is secret-gated: the workers.dev URL is public, so an
    // unauthenticated request must NOT run the report or post to Discord.
    // Fail closed. Mirrors workers/product-health/src/index.js exactly.
    const url = new URL(request.url);
    const provided = url.searchParams.get("token") || request.headers.get("x-trigger-secret");
    if (!env.TRIGGER_SECRET || provided !== env.TRIGGER_SECRET) {
      return new Response("unauthorized\n", { status: 401 });
    }
    const dateOverride = url.searchParams.get("date"); // optional YYYY-MM-DD Eastern-date recovery override
    try {
      const message = await runReport(env, dateOverride);
      return new Response(message + "\n", { status: 200 });
    } catch (err) {
      return new Response("daily report failed: " + err.message + "\n", { status: 500 });
    }
  },
};

// ----- Eastern calendar-day boundary ---------------------------------------

const EASTERN_TZ = "America/New_York";

/**
 * Returns { dateStr, startUTC, endUTC } for the target Eastern calendar day:
 * yesterday relative to `now`, or the explicit `dateOverride` (YYYY-MM-DD)
 * when provided (manual recovery after a missed scheduled run - plan §4-9
 * failure-mode table). startUTC/endUTC are the true UTC instants of that
 * day's midnight-to-midnight boundary in America/New_York, computed via the
 * Intl timezone API (handles EST/EDT correctly, no library dependency).
 */
export function easternYesterdayWindowUTC(now = new Date(), dateOverride = null) {
  const targetDateStr = dateOverride || shiftDateString(easternDateString(now), -1);
  const startUTC = findUTCForEasternMidnight(targetDateStr);
  const endUTC = findUTCForEasternMidnight(shiftDateString(targetDateStr, 1));
  return { dateStr: targetDateStr, startUTC, endUTC };
}

function easternDateString(date) {
  // en-CA formats as YYYY-MM-DD.
  return new Intl.DateTimeFormat("en-CA", { timeZone: EASTERN_TZ }).format(date);
}

function shiftDateString(dateStr, days) {
  const [y, m, d] = dateStr.split("-").map(Number);
  const noonUTC = new Date(Date.UTC(y, m - 1, d, 12)); // noon avoids any DST-edge ambiguity
  noonUTC.setUTCDate(noonUTC.getUTCDate() + days);
  return noonUTC.toISOString().slice(0, 10);
}

function findUTCForEasternMidnight(dateStr) {
  const [y, m, d] = dateStr.split("-").map(Number);
  const naiveUTCMs = Date.UTC(y, m - 1, d, 0, 0, 0);
  // Converges in one correction: the ET offset is stable across the ~4-5hr
  // window between a naive-UTC guess and the true instant, except exactly on
  // a DST-transition calendar day, where a second pass fixes it.
  // easternOffsetMinutesAt returns a SIGNED offset (negative for ET, e.g.
  // -300 for EST/-240 for EDT, standard "west of UTC" convention) -
  // SUBTRACTING it converts local midnight to the real UTC instant.
  let guessMs = naiveUTCMs;
  for (let i = 0; i < 2; i++) {
    const offsetMinutes = easternOffsetMinutesAt(new Date(guessMs));
    guessMs = naiveUTCMs - offsetMinutes * 60000;
  }
  return new Date(guessMs);
}

/** Signed UTC offset in minutes for America/New_York at `date` (EST=-300, EDT=-240). */
function easternOffsetMinutesAt(date) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: EASTERN_TZ,
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).formatToParts(date);
  const v = {};
  for (const p of parts) v[p.type] = p.value;
  const localAsUTC = Date.UTC(
    Number(v.year), Number(v.month) - 1, Number(v.day),
    Number(v.hour), Number(v.minute), Number(v.second)
  );
  return (localAsUTC - date.getTime()) / 60000;
}

// ----- Message ---------------------------------------------------------------

const ENGINE_LABELS = { parakeet: "Parakeet", whisperKit: "WhisperKit" };
const PROVIDER_LABELS = {
  appleIntelligence: "Apple Intelligence",
  egOne: "EG-1 (our own model)",
  gemini: "Gemini",
  openAI: "OpenAI",
  ollama: "Ollama",
  none: "polish turned off",
};

function pctOf(n, total) {
  return total > 0 ? `${Math.round((n / total) * 100)}%` : "0%";
}

function formatBuckets(buckets, labels, total) {
  return Object.entries(buckets)
    .filter(([, n]) => n > 0)
    .sort((a, b) => b[1] - a[1])
    .map(([key, n]) => `${labels[key] || key} ${n} (${pctOf(n, total)})`)
    .join(", ");
}

function formatWeekdayDate(dateStr) {
  const [y, m, d] = dateStr.split("-").map(Number);
  const noonUTC = new Date(Date.UTC(y, m - 1, d, 12));
  return new Intl.DateTimeFormat("en-US", {
    timeZone: "UTC",
    weekday: "long",
    month: "long",
    day: "numeric",
    year: "numeric",
  }).format(noonUTC);
}

// Names for the "some sections were unavailable" summary note, keyed to the
// same booleans fetchReportData returns. `totals` is deliberately absent -
// it never degrades (#1720).
const DEGRADED_SECTION_LABELS = [
  ["installsDegraded", "new installs"],
  ["onboardActivateDegraded", "onboarding/activation"],
  ["engineAndTierBDegraded", "transcription engine and AI-polish breakdown"],
  ["geoDegraded", "where they are"],
  ["top5Degraded", "top 5 users"],
];

export function buildMessage(dateStr, data, buckets) {
  const lines = [`EnviousWispr Daily Report, ${formatWeekdayDate(dateStr)}`, ""];

  // Near the TOP deliberately: the tail is truncated at 1990 chars below, so a
  // note appended at the end could be silently cut off on exactly the busy days
  // when the report is longest (#1655). Distinct from the per-section inline
  // "temporarily unavailable" wording below - this is a fast-skim summary,
  // never a substitute for it, and never fabricates a zero for a degraded
  // section (#1720).
  const notes = [];
  if (data.tierADegraded) {
    notes.push("the polish-provider breakdown is approximate because the settings lookup was temporarily unavailable when this report ran");
  }
  const degradedSections = DEGRADED_SECTION_LABELS.filter(([key]) => data[key]).map(([, label]) => label);
  if (degradedSections.length) {
    notes.push(`some sections were temporarily unavailable when this report ran: ${degradedSections.join(", ")}`);
  }
  if (notes.length) {
    lines.push(`Note: ${notes.join("; ")}.`, "");
  }

  const installsPart = data.installsDegraded
    ? "New installs: temporarily unavailable."
    : `New installs: ${data.freshInstalls}.`;
  const onboardPart = data.onboardActivateDegraded
    ? "Onboarding and activation: temporarily unavailable."
    : `People who finished setup that day: ${data.onboarded}. Of those, ${data.activated} also dictated that day.`;
  lines.push(`${installsPart} ${onboardPart}`, "");

  lines.push(`Total users: ${data.totalUsers} people used the app that day.`, "");

  if (data.engineAndTierBDegraded) {
    lines.push("Transcription engine and AI-polish breakdown: temporarily unavailable.", "");
  } else if (data.totalUsers > 0) {
    const engineLine = formatBuckets(buckets.engineBuckets, ENGINE_LABELS, data.totalUsers);
    if (engineLine) lines.push(`Transcription engine (by user): ${engineLine}.`, "");

    const polishLine = formatBuckets(buckets.polishBuckets, PROVIDER_LABELS, data.totalUsers);
    if (polishLine) lines.push(`AI polishing (by user, their selected choice): ${polishLine}.`, "");
  }

  lines.push(`Net total dictations: ${data.netDictations}.`, "");

  if (data.geoDegraded) {
    lines.push("Where they are: temporarily unavailable.", "");
  } else if (data.geo.length) {
    lines.push(`Where they are: ${data.geo.map((g) => `${g.country} ${g.n}`).join(", ")}.`, "");
  }

  if (data.top5Degraded) {
    lines.push("Top 5 users by dictation volume: temporarily unavailable.");
  } else if (data.top5.length) {
    lines.push(`Top 5 users by dictation volume: ${data.top5.map((u) => u.n).join(", ")}.`);
  }

  const content = lines.join("\n").trim();
  // Discord content cap is 2000 chars.
  return content.length > 1990 ? content.slice(0, 1987) + "..." : content;
}

// ----- Discord + run ---------------------------------------------------------

async function postToDiscord(webhookUrl, content) {
  const res = await fetch(webhookUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ content }),
  });
  return res.status === 204 || res.status === 200;
}

async function safePost(env, content) {
  try {
    if (env.DISCORD_WEBHOOK_URL) await postToDiscord(env.DISCORD_WEBHOOK_URL, content);
  } catch (_) {
    // best-effort failure notice; the caller's throw is what surfaces the failure in logs/CI
  }
}

// `deps` is a test-only injection seam (production passes nothing, both
// defaults apply): `deps.resolveBuckets` lets a degraded-engine test spy on
// resolveBuckets and assert it was never called (proving the skip below
// actually happened, not just that its output looks empty); `deps.hogqlOpts`
// forwards into fetchReportData so the same test can force an exhausted
// retry deterministically instead of waiting through real backoff delays
// (#1720).
export async function runReport(env, dateOverride = null, deps = {}) {
  const resolveBucketsFn = deps.resolveBuckets || resolveBuckets;
  const hogqlOpts = deps.hogqlOpts || {};
  const { dateStr, startUTC, endUTC } = easternYesterdayWindowUTC(new Date(), dateOverride);
  const win = windowClause(startUTC, endUTC);

  let data, buckets;
  try {
    data = await fetchReportData(env, win, endUTC, hogqlOpts);
    // engineAndTierB degraded => no real per-user rows to check completeness
    // against; resolveBucketsFn's completeness check would throw against
    // absent data, so it is skipped entirely rather than called with a
    // guaranteed-mismatched anchor (#1720). Empty placeholders let
    // buildMessage omit the breakdown cleanly (see its own degraded branch).
    buckets = data.engineAndTierBDegraded
      ? { engineBuckets: {}, polishBuckets: {}, resolutionSource: { settings: 0, actual_dictation: 0, shipped_default: 0 } }
      : resolveBucketsFn(data);
    // Resolution-tier logging (Cloudflare log only, never the Discord
    // message) - plan §3.3a. A spike in shipped_default's share vs
    // settings/actual_dictation is the telemetry-drift canary.
    console.log(
      `daily-report resolution tiers: settings=${buckets.resolutionSource.settings} ` +
        `actual_dictation=${buckets.resolutionSource.actual_dictation} ` +
        `shipped_default=${buckets.resolutionSource.shipped_default}`
    );
  } catch (err) {
    // Loud failure: never let a partial/failed run read as a normal report.
    await safePost(env, `Daily report failed to generate for ${dateStr}: ${err.message}`);
    throw err;
  }

  const message = buildMessage(dateStr, data, buckets);
  const ok = await postToDiscord(env.DISCORD_WEBHOOK_URL, message);
  if (!ok) throw new Error("Discord post failed");
  return message;
}
