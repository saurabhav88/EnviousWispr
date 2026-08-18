/**
 * EnviousWispr Daily Report - Cloudflare Worker (issues #1433, #1838)
 *
 * Runs once a day via a secret-gated HTTP trigger (scheduling lives in
 * .github/workflows/daily-report-ping.yml, not a Cloudflare cron - the CF
 * account is at its 5-cron free-plan limit, see #1092) and posts ONE Discord
 * message with two sections:
 *
 *   Adoption          - yesterday's installs, onboarding, activation, engine
 *                       and polish choice, volume, geography, heaviest users.
 *   Version scorecard - the last complete Eastern week, per release, with the
 *                       two largest ranked changes against each measure's own
 *                       normal week-to-week movement (#1838).
 *   Sentry            - yesterday's errors on the current release line, split
 *                       into dictations LOST and dictations that still worked
 *                       but worse, with the change in affected people against
 *                       the day before (#1965).
 *
 * Gates nothing and alerts on nothing. Defect detection belongs to the Sentry
 * triage routines; this is a digest, and the threshold-alarm shape it replaced
 * is exactly what made the old separate health check useless to its one reader.
 *
 * ORCHESTRATION OWNERSHIP. This file resolves the report window ONCE, resolves
 * the dev-ID exclusion ONCE, builds ONE production predicate, schedules every
 * outbound query itself, assembles ONE payload, and decides whether the run was
 * clean. The two section modules own their own SQL, calculations and results,
 * and cannot reach the clock, the raw dev IDs, or a scheduler of their own.
 *
 * Plan: docs/feature-requests/issue-1838-2026-07-29-daily-report-version-scorecard.md
 *
 * Privacy: output and logs are counts / rates / labels only. Never a raw
 * transcript, a PostHog or Discord response body, a distinct id, or the
 * trigger secret.
 */

import { productionClauseFor, resolveDevIds, runLimited, windowClause } from "../../shared/posthog.js";
import { deliverReport } from "../../shared/discord.js";
import { createAdoptionSection } from "./adoption.js";
import {
  ScorecardSectionError,
  WINDOW_COUNT,
  WINDOW_DAYS,
  createScorecardSection,
} from "./version-scorecard.js";
import {
  formatAdoptionUnavailable,
  formatScorecard,
  formatScorecardUnavailable,
} from "./report-format.js";
import {
  fetchSentrySection,
  formatSentrySection,
  formatSentryUnavailable,
} from "../../reporting/sentry-section.js";

export default {
  async fetch(request, env) {
    // Manual trigger is secret-gated: the workers.dev URL is public, so an
    // unauthenticated request must NOT run the report or post to Discord.
    // Fail closed, before any outbound work.
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
      // Deliberately does NOT post here. runReport owns every Discord request;
      // a second post from this layer is how a failed run ends up telling the
      // founder twice, or telling him after he already has the report.
      return new Response("daily report failed: " + err.message + "\n", { status: 500 });
    }
  },
};

// ----- Eastern calendar-day boundary ---------------------------------------

const EASTERN_TZ = "America/New_York";
const EASTERN_DAY = /^\d{4}-\d{2}-\d{2}$/;

/**
 * Returns { dateStr, startUTC, endUTC } for the target Eastern calendar day:
 * yesterday relative to `now`, or the explicit `dateOverride` (YYYY-MM-DD)
 * when provided (manual recovery after a missed scheduled run). startUTC and
 * endUTC are the true UTC instants of that day's midnight-to-midnight boundary
 * in America/New_York, computed via the Intl timezone API (handles EST/EDT
 * correctly, no library dependency).
 */
export function easternYesterdayWindowUTC(now = new Date(), dateOverride = null) {
  const targetDateStr = dateOverride || shiftDateString(easternDateString(now), -1);
  const startUTC = findUTCForEasternMidnight(targetDateStr);
  const endUTC = findUTCForEasternMidnight(shiftDateString(targetDateStr, 1));
  return { dateStr: targetDateStr, startUTC, endUTC };
}

/**
 * The ONE resolved report context. Both sections read their window from this
 * object and nothing else: neither may call the clock, re-read the override, or
 * derive a second window. Anchoring the scorecard to `now()` instead of the
 * resolved end made a backfilled run's newest window thirteen days long and let
 * it absorb events from AFTER the day being reported.
 *
 * The scorecard anchor exists in two forms - a plain Eastern day and a quoted
 * SQL literal - and BOTH are derived from `windowEndExclusiveDay` inside the
 * scorecard module, so the queries can never measure a different window from
 * the one the measurement engine buckets.
 */
export function resolveReportWindow(now = new Date(), dateOverride = null) {
  if (dateOverride !== null && dateOverride !== undefined) {
    // A malformed override is shared-fatal, never a silent fall-through to
    // yesterday: a recovery run that quietly reports the wrong day is worse
    // than one that reports nothing, because nobody re-runs it.
    if (typeof dateOverride !== "string" || !EASTERN_DAY.test(dateOverride)) {
      throw new Error("date override must be YYYY-MM-DD");
    }
    const [y, m, d] = dateOverride.split("-").map(Number);
    // Date.UTC rolls an impossible date forward (2026-02-30 becomes March 2),
    // so the round-trip is what refuses it rather than reporting a day nobody
    // asked for.
    if (new Date(Date.UTC(y, m - 1, d, 12)).toISOString().slice(0, 10) !== dateOverride) {
      throw new Error("date override is not a real calendar date");
    }
  }
  const { dateStr, startUTC, endUTC } = easternYesterdayWindowUTC(now, dateOverride || null);
  const windowEndExclusiveDay = shiftDateString(dateStr, 1);
  return Object.freeze({
    dateStr,
    startUTC,
    endUTC,
    win: windowClause(startUTC, endUTC),
    windowEndExclusiveDay,
    // Eight 7-day windows back from the exclusive end. Window 7's first day is
    // exactly this date, so a day earlier would fall outside the grid entirely.
    historyStartDay: shiftDateString(windowEndExclusiveDay, -(WINDOW_DAYS * WINDOW_COUNT)),
  });
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

// ----- Adoption presentation -------------------------------------------------

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

/** The one line above both embeds. Sole producer of the report's own title. */
export function reportHeader(dateStr) {
  return `EnviousWispr Daily Report, ${formatWeekdayDate(dateStr)}`;
}

// Names for the "some sections were unavailable" summary note, keyed to the
// same booleans the adoption section returns. `totals` is deliberately absent -
// it never degrades (#1720).
const DEGRADED_SECTION_LABELS = [
  ["installsDegraded", "people who began setting up"],
  ["onboardActivateDegraded", "onboarding/activation"],
  ["engineAndTierBDegraded", "transcription engine and AI-polish breakdown"],
  ["geoDegraded", "where they are"],
  ["top5Degraded", "top 5 users"],
];

/**
 * The adoption section, as LINES whose FIRST line titles its embed - the same
 * shape every section formatter returns, so the payload assembler never
 * authors a sentence of its own.
 *
 * The unavailable counterpart lives in report-format.js beside the scorecard's,
 * because that file is the single home for failure wording.
 */
export function formatAdoption(data, buckets) {
  // Just "Adoption": the day is on the message's content line, and a backfilled
  // run is not reporting yesterday.
  const lines = ["Adoption"];

  // Near the TOP deliberately: a fast-skim summary of which sections could not
  // be measured. Distinct from the per-section inline "temporarily unavailable"
  // wording below, never a substitute for it, and never a fabricated zero for a
  // degraded section (#1720).
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
    ? "People who began setting up: temporarily unavailable."
    : `People who began setting up: ${data.freshInstalls}.`;
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

  // Escape Recovery (#2087). Built from INDEPENDENT clauses, each gated on its
  // own count, because the counts are windowed independently and no one of them
  // can stand for the others. A held row lives 24 hours by design, so a recovery
  // saved yesterday and undone today lands in this window as a restore with no
  // attempt beside it. Gating the whole line on attempts hid that day entirely,
  // and gating the middle clause on it would have printed "0 saved for 0 people"
  // on a day something really happened.
  //
  // Omitted entirely only when NOTHING happened, rather than printing a row of
  // zeroes: this is opt-in, and an all-zero line every day is how a reader
  // learns to skip a section.
  {
    const er = data.escapeRecovery || {};
    const attempts = er.attempts ?? 0;
    const kept = er.kept ?? 0;
    const people = er.keptUsers ?? 0;
    const restored = er.restored ?? 0;
    const clipboardOnly = er.clipboardOnly ?? 0;
    const failedTranscription = er.failedTranscription ?? 0;
    const failedSave = er.failedSave ?? 0;

    const clauses = [];
    if (attempts > 0) {
      clauses.push(
        `${attempts} cancelled dictation${attempts === 1 ? " was" : "s were"} held, ` +
          `${kept} saved for ${people} ${people === 1 ? "person" : "people"}.`
      );
    }
    if (restored > 0) {
      clauses.push(
        `${restored} ${restored === 1 ? "was" : "were"} taken back with Undo.`
      );
    }
    // Named apart, because they are different defects and one is worse. A save
    // failure lost text we already had.
    if (failedSave > 0) {
      clauses.push(
        `${failedSave} ${failedSave === 1 ? "was" : "were"} transcribed and then lost ` +
          `when the save failed, which is a defect rather than a user choice.`
      );
    }
    if (failedTranscription > 0) {
      clauses.push(
        `${failedTranscription} could not be transcribed at all, so there was never ` +
          `anything to save.`
      );
    }
    if (clipboardOnly > 0) {
      clauses.push(
        `${clipboardOnly} restore${clipboardOnly === 1 ? "" : "s"} could not reach the ` +
          `original app and went to the clipboard instead.`
      );
    }
    if (clauses.length) {
      lines.push("", `Escape Recovery: ${clauses.join(" ")}`);
    }
  }

  return lines;
}

// ----- Orchestration ---------------------------------------------------------

/** PostHog allows only 3 concurrent queries per project (#1588). Two in flight
 * leaves a slot of headroom for the shared project's other traffic
 * (EnviousStaging). This is the GLOBAL ceiling across both sections, which is
 * why the sections cannot own limiters of their own: two limiters of 2 is a
 * limiter of 4. */
const CONCURRENCY_LIMIT = 2;

/**
 * Runs `tasks` through the ONE limiter, converting every outcome into a settled
 * record so a rejection can never cancel queued work belonging to the other
 * section. Without this, one adoption query failing early would strand the
 * scorecard's queries behind it and both halves of the report would be lost to
 * a single blip.
 */
function settleAll(tasks, limit) {
  return runLimited(
    tasks.map((task) => async () => {
      try {
        return { status: "fulfilled", value: await task() };
      } catch (reason) {
        return { status: "rejected", reason: asError(reason, "outbound task") };
      }
    }),
    limit
  );
}

/** `throw undefined` is legal JavaScript, and a falsy rejection value used as a
 * failure flag reads as success - a lost section reported as a healthy one.
 * Deliberately does NOT interpolate the thrown value: it reaches the trigger's
 * response body, and an arbitrary thrown value is not known to be content-free. */
function asError(reason, label) {
  return reason instanceof Error ? reason : new Error(`${label} rejected without an Error`);
}

/**
 * Drives both sections through two dependency-ordered stages under one shared
 * ceiling. The sections DESCRIBE their outbound work; they never schedule it.
 *
 * Exported so section tests drive the REAL orchestrator rather than a
 * hand-rolled stand-in: a test harness that re-implements the staging is a
 * second authority, and it passes happily while production takes another path.
 *
 * Stage 1 is every query that needs nothing but the shared context. Stage 2 is
 * the work that depends on stage 1 (adoption's settings lookup, the scorecard's
 * release resolution). Because the stages are sequential and each is a single
 * limiter call, the global in-flight count is exactly `limit` throughout.
 */
export async function driveSections(sections, limit) {
  // `failure` is null, or a real Error - never a raw thrown value. `throw
  // undefined` is legal JavaScript, and a falsy rejection used as the sentinel
  // reports a LOST section as a healthy one. `asError` is the single mechanism
  // that closes that: a separate boolean flag beside it could not be armed by
  // any input, so it is not carried.
  const state = sections.map(() => ({ failure: null, primary: [], follow: [] }));

  const stage1 = [];
  const spans1 = sections.map((s) => {
    const start = stage1.length;
    stage1.push(...s.driver.primaryTasks);
    return [start, stage1.length];
  });
  const settled1 = await settleAll(stage1, limit);
  spans1.forEach(([from, to], i) => {
    state[i].primary = settled1.slice(from, to);
  });

  const stage2 = [];
  const spans2 = sections.map((s, i) => {
    const start = stage2.length;
    try {
      stage2.push(...s.driver.followUpTasks(state[i].primary));
    } catch (reason) {
      // This section is finished, and failed. The other one still gets its
      // stage-2 slot: one section's failure must never shorten the other's run.
      state[i].failure = asError(reason, `${s.driver.name} follow-up preparation`);
    }
    return [start, stage2.length];
  });
  const settled2 = await settleAll(stage2, limit);
  spans2.forEach(([from, to], i) => {
    state[i].follow = settled2.slice(from, to);
  });

  return Promise.allSettled(
    sections.map(async (s, i) => {
      try {
        if (state[i].failure) throw state[i].failure;
        // Rendering AND its shape check both sit inside the settled outcome. A
        // section that computes cleanly but renders badly is an unavailable
        // section; validated later, at delivery, it would fail the whole
        // payload and cost the OTHER section its place in the report too.
        return toEmbed(s.describe(s.driver.finish(state[i].primary, state[i].follow)));
      } catch (reason) {
        throw asError(reason, `${s.driver.name} section`);
      }
    })
  );
}

/** One embed per section. Every formatter returns lines whose first line is the
 * title, so this function chooses no words of its own - but it does REFUSE a
 * shape Discord would reject, because that refusal has to happen while the
 * failure still belongs to one section. */
function toEmbed(lines) {
  if (!Array.isArray(lines)) {
    throw new TypeError("section formatter must return a title and body as string lines");
  }
  const lineCount = lines.length;
  if (lineCount < 2) {
    throw new TypeError("section formatter must return a title and body as string lines");
  }
  // Indexed, not `every`: Array#every SKIPS holes and visits inherited indices,
  // so a sparse ["Title", <hole>, "Body"] passes it and then joins into a
  // description with a silently blank line where a section should have been.
  //
  // EACH LINE IS READ EXACTLY ONCE and the embed is built from that copy. Two
  // reads of the same index let an accessor answer "Body" to the check and
  // 9,000 characters to the consumer; destructuring `lines` again would re-read
  // through Symbol.iterator, which an own iterator can redefine. Same defect,
  // three different mechanisms - so the rule is one observation per value.
  const checked = [];
  for (let i = 0; i < lineCount; i += 1) {
    if (!Object.hasOwn(lines, i)) {
      throw new TypeError("section formatter must return a title and body as string lines");
    }
    const line = lines[i];
    if (typeof line !== "string") {
      throw new TypeError("section formatter must return a title and body as string lines");
    }
    checked.push(line);
  }
  const [title, ...body] = checked;
  const description = body.join("\n");
  if (title.length === 0 || description.length === 0) {
    throw new TypeError("section formatter must return a non-empty title and description");
  }
  return { title, description };
}

/** Best-effort fixed notice for a run that produced no report at all. Carries
 * no error text, status code or response body: it goes to a Discord channel,
 * and the exception itself surfaces through the trigger's non-2xx status. */
async function postFailureNotice(env, dateStr) {
  if (!env.DISCORD_WEBHOOK_URL) return;
  try {
    await deliverReport(env.DISCORD_WEBHOOK_URL, {
      content:
        `EnviousWispr Daily Report for ${dateStr} could not be generated. ` +
        `Nothing was measured, so this is not a report of zero.`,
    });
  } catch (_) {
    // The caller's rethrow is what surfaces the failure.
  }
}

/** Just "Sentry, yesterday": the day is on the message's content line, and this
 * section always reports the day the rest of the report is about. */
const SENTRY_TITLE = "Sentry, yesterday";

/** Sentry's window, derived from the ONE resolved report context and nothing
 * else - this file's orchestration rule, applied to a third vendor. Sentry's
 * `start`/`end` are naive ISO instants interpreted as UTC, so the Eastern day
 * boundary already computed in `context` converts directly with no second
 * timezone calculation.
 *
 * `statsPeriod` is deliberately NOT used. It cannot express "the day before
 * yesterday", which the people delta needs, and mixing the two forms across
 * five calls is how a report ends up comparing windows that do not abut. */
export function sentryWindowFor(context) {
  const naiveISO = (date) => date.toISOString().slice(0, 19);
  // The prior window is the PREVIOUS EASTERN CALENDAR DAY, resolved through the
  // same midnight machinery as the reported one. Subtracting the reported day's
  // DURATION instead looks equivalent and is wrong twice a year: on 2026-11-01
  // the reported day is 25 hours long, so a duration subtraction would compare
  // it against a 25-hour "yesterday" that reaches an hour back into Oct 30; on
  // 2026-03-08 the day is 23 hours and the comparison would MISS an hour of
  // Mar 7. Either way the founder reads "1 fewer than yesterday" against a
  // window that is not yesterday, and nothing in the output would say so.
  const priorStart = findUTCForEasternMidnight(shiftDateString(context.dateStr, -1));
  return {
    startISO: naiveISO(context.startUTC),
    endISO: naiveISO(context.endUTC),
    priorStartISO: naiveISO(priorStart),
  };
}

/** Runs the Sentry section and converts every failure into a settled record.
 *
 * NEVER whole-run fatal, deliberately. A Sentry outage must not cost the
 * founder the adoption numbers, which are measured from an entirely different
 * vendor and are perfectly good. The trigger still fails afterwards, so a
 * section that quietly stopped working cannot look healthy forever.
 */
async function settleSentrySection(env, context, deps) {
  try {
    const opts = { ...(deps.sentryOpts || {}), workerLabel: "daily_report" };
    const data = await fetchSentrySection(env, sentryWindowFor(context), opts);
    // Rendering AND its shape check both sit inside the settled outcome, for
    // the same reason driveSections puts them there: a section that computes
    // cleanly and renders badly is an unavailable section, and validating it
    // later at delivery would fail the whole payload and cost the OTHER
    // sections their place in the report.
    return { status: "fulfilled", value: toEmbed(formatSentrySection(data, { title: SENTRY_TITLE })) };
  } catch (reason) {
    return { status: "rejected", reason: asError(reason, "sentry section") };
  }
}

// `deps` is a test-only injection seam (production passes nothing, every
// default applies): `deps.resolveBuckets` lets a degraded-engine test prove
// resolveBuckets was never CALLED rather than that its output merely looks
// empty; `deps.hogqlOpts` and `deps.releaseOpts` drive retry paths without
// sitting through real backoff delays.
export async function runReport(env, dateOverride = null, deps = {}) {
  // workerLabel is REQUIRED by the shared transport and is set exactly once
  // here, then forwarded verbatim to every call site. The spread keeps a test
  // seam able to inject fetch/sleep/random without having to know about it.
  const hogqlOpts = { ...(deps.hogqlOpts || {}), workerLabel: "daily_report" };
  const releaseOpts = deps.releaseOpts || {};

  // ---- Shared preflight. Anything failing here is fatal to BOTH sections:
  // there is no window to measure, or no honest production population to
  // measure it over. An unresolved dev-ID list is never "no dev accounts."
  let context;
  let noticeDate = "the requested day";
  try {
    const window = resolveReportWindow(new Date(), dateOverride);
    noticeDate = window.dateStr;
    const devIds = await resolveDevIds(env, hogqlOpts);
    // The raw ids stop here. Both sections receive only the predicate, so
    // neither can rebuild the exclusion differently or leak an id into a log.
    context = Object.freeze({ ...window, prod: productionClauseFor(devIds) });
  } catch (err) {
    await postFailureNotice(env, noticeDate);
    throw err;
  }

  const sections = [
    {
      driver: createAdoptionSection(env, context, {
        hogqlOpts,
        resolveBucketsFn: deps.resolveBuckets,
      }),
      describe: ({ data, buckets }) => formatAdoption(data, buckets),
      unavailable: formatAdoptionUnavailable,
    },
    {
      driver: createScorecardSection(env, context, { hogqlOpts, releaseOpts }),
      describe: (ranking) => formatScorecard({ ranking }),
      unavailable: formatScorecardUnavailable,
    },
  ];

  // Sentry runs ALONGSIDE the PostHog work, not inside its limiter. The limiter
  // exists for PostHog's 3-query project ceiling; Sentry is a different vendor
  // with its own limits (30 per window, 15 concurrent), so a Sentry read that
  // waited for a PostHog slot would block a PostHog query for ~1.8s while doing
  // no PostHog work at all.
  const [outcomes, sentryOutcome] = await Promise.all([
    driveSections(sections, CONCURRENCY_LIMIT),
    settleSentrySection(env, context, deps),
  ]);

  // A release-resolution CONTRACT failure - misconfiguration, a malformed
  // response, no eligible release - means we cannot know which releases this
  // report is even about. There is no honest combined report to send, so it is
  // fail-loud for the whole run rather than a quietly unavailable section that
  // could persist for months.
  const fatal = outcomes.find(
    (outcome) =>
      outcome.status === "rejected" &&
      // The declared TYPE, not a `wholeRun` property any error could carry: an
      // adoption failure that happened to own that field would discard a
      // perfectly good scorecard and post only the fatal notice.
      outcome.reason instanceof ScorecardSectionError &&
      outcome.reason.wholeRun === true
  );
  if (fatal) {
    await postFailureNotice(env, context.dateStr);
    throw fatal.reason;
  }

  const payload = {
    content: reportHeader(context.dateStr),
    // A fulfilled outcome is ALREADY an embed, validated inside its own
    // section. Only the fixed unavailable copy is rendered here.
    embeds: [
      ...sections.map((s, i) =>
        outcomes[i].status === "fulfilled" ? outcomes[i].value : toEmbed(s.unavailable())
      ),
      sentryOutcome.status === "fulfilled"
        ? sentryOutcome.value
        : toEmbed(formatSentryUnavailable(SENTRY_TITLE)),
    ],
  };

  // Validated and sent as ONE object inside deliverReport. An over-budget
  // payload throws here with zero requests made: the report is sent whole or
  // not at all, and no fallback notice follows it.
  await deliverReport(env.DISCORD_WEBHOOK_URL, payload);

  // The founder has the report; the trigger still has to fail, or a section
  // that silently stopped working would look like a healthy run forever. The
  // Sentry outcome is checked with the others, not separately: it is exactly as
  // capable of failing quietly, and a missing Sentry section for months is the
  // shape this whole issue exists to prevent.
  const failed = [...outcomes, sentryOutcome].find((o) => o.status === "rejected");
  if (failed) throw failed.reason;
  return payload.content;
}
