/**
 * The Sentry digest section (issue #1965).
 *
 * CONSUMERS: workers/daily-report (yesterday), workers/weekly-digest (7 days).
 *
 * DEPLOY RULE: each worker bundles its own copy at deploy time, so editing this
 * file changes nothing in production until BOTH consumers are redeployed. See
 * workers/reporting/README.md.
 *
 * WHY THIS IS NOT IN workers/shared/: that directory is transport and protocol
 * only, and everything below is product judgement - which releases count, what
 * an error category MEANS for the person who was dictating, and how to say it.
 * The Sentry HTTP transport those judgements sit on top of IS in
 * workers/shared/sentry.js, which is the correct half to share.
 *
 * WHY THE SPIKE CARD DOES NOT IMPORT THIS: workers/sentry-triage renders a
 * different thing from a different query - dev AND production rather than
 * production only, a trailing hour rather than a day or a week, and no
 * lost/degraded grouping at all. It shares the transport and nothing else.
 *
 * REPORTS, NEVER ALERTS. No thresholds, no colours, no healthy/unhealthy verdict.
 * The digest that this section joins replaced a threshold-alarm worker, and that
 * shape is exactly what made the old health check useless to its one reader
 * (workers/daily-report/src/index.js header). Spike alerting is owned by
 * sentry-triage, which is a different contract with a different deadline.
 *
 * Privacy: counts, category labels and version numbers only. Never a stack
 * trace, a user id, a message body or anything a user dictated.
 */

import { discoverAggregate, issueList } from "../shared/sentry.js";

// ── Classification ──────────────────────────────────────────────────────────

export const LOST = "lost";
export const DEGRADED = "degraded";

/**
 * Every `SentryBreadcrumb.ErrorCategory` raw value, classified by what the
 * PERSON experienced, per CLAUDE.md § Principles: the heart (audio, ASR, paste)
 * failing loses the dictation; a limb failing still delivers the last
 * successful text.
 *
 * THE RULE THIS TABLE ENCODES. `lost` means either a producer proves text was
 * not delivered, OR the indexed fields cannot prove that it was. `degraded`
 * requires that EVERY current producer proves text remained available, or that
 * no dictation was in flight at all. Unknown categories default to `lost` and
 * render their raw name, so a category added to the app and not added here is
 * conspicuous rather than silently dropped.
 *
 * `deliveryProven: false` marks a row where the classification is the
 * conservative choice rather than a demonstrated fact. Those render as
 * "delivery not proven" and MUST NOT be worded as proof a user lost words:
 * overstating is its own defect, because the founder acts on this list.
 *
 * `emitted: false` marks a case that exists in the enum and has NO producer
 * anywhere in Sources/ or Tests/ (measured 2026-08-06; positive control:
 * modelLoadFailed returns 30 hits). It cannot appear in live data. It is kept
 * here rather than omitted so the completeness test can enumerate the Swift enum
 * against this table and fail on a genuine gap.
 */
export const ERROR_CATEGORIES = Object.freeze({
  // Declared in the enum, never emitted. Conservative-lost is unreachable here
  // rather than wrong; if a producer is ever added, the classification is
  // already the safe one.
  availability_check_failed: { group: LOST, deliveryProven: false, emitted: false, label: "AI availability check failed" },
  fallback_failed: { group: LOST, deliveryProven: false, emitted: false, label: "polish fallback failed" },
  state_mismatch: { group: LOST, deliveryProven: false, emitted: false, label: "recording state mismatch" },

  // Polish limbs. Every one of these leaves the previously-produced text intact
  // (CLAUDE.md § Principles; ITN runs BEFORE polish, so number and date
  // formatting survives a polish failure too).
  provider_init_failed: { group: DEGRADED, deliveryProven: true, emitted: true, label: "polish provider could not start" },
  generation_failed: { group: DEGRADED, deliveryProven: true, emitted: true, label: "polish generation failed" },
  polish_provider_failed: { group: DEGRADED, deliveryProven: true, emitted: true, label: "polish provider failed" },
  output_classifier_load_failed: { group: DEGRADED, deliveryProven: true, emitted: true, label: "polish safety check could not load" },
  emoji_restore_incomplete: { group: DEGRADED, deliveryProven: true, emitted: true, label: "emoji restoration incomplete" },
  inverse_normalization_timeout: { group: DEGRADED, deliveryProven: true, emitted: true, label: "number and date formatting timed out" },
  legacy_key_cleanup_failed: { group: DEGRADED, deliveryProven: true, emitted: true, label: "old key cleanup failed" },

  // The clipboard IS the paste cascade's floor, so the text reached the user
  // even when auto-paste did not (PasteCascadeExecutor.swift:533-565, error
  // emitted at :672-735). The founder said this outright: "paste failing is not
  // actually an error."
  paste_failed: { group: DEGRADED, deliveryProven: true, emitted: true, label: "paste fell back to the clipboard" },

  // Fires at ARM time and only disables the crash-safety copy for that take;
  // the recording continues (RecoveryCoordinator.swift:242-258, "fail-open: a
  // store failure disables recovery for this take"). The first draft of the
  // plan had this as lost; grounded review corrected it.
  recovery_key_store_failed: { group: DEGRADED, deliveryProven: true, emitted: true, label: "crash-safety copy could not be armed" },

  // The shortcut will not fire, but the event does not prove a dictation was
  // ever attempted, so it cannot be counted as one that was lost.
  hotkey_registration_failed: { group: DEGRADED, deliveryProven: true, emitted: true, label: "dictation shortcut could not be registered" },

  // Heart failures. Terminal: no text reached the user.
  audio_capture_failed: { group: LOST, deliveryProven: true, emitted: true, label: "microphone capture failed" },
  audio_capture_stalled: { group: LOST, deliveryProven: true, emitted: true, label: "microphone capture stalled" },
  asr_failed: { group: LOST, deliveryProven: true, emitted: true, label: "transcription failed" },
  model_load_failed: { group: LOST, deliveryProven: true, emitted: true, label: "speech model failed to load" },
  heart_path_finalization: { group: LOST, deliveryProven: true, emitted: true, label: "dictation finished with no text" },
  pipeline_post_condition_failed: { group: LOST, deliveryProven: true, emitted: true, label: "recording start ended in an invalid state" },

  // No longer emitted by any shipping build (SentryBreadcrumb.swift:405-409),
  // but historical events are still inside Sentry's retention window, so it can
  // appear on an old release and must classify rather than fall through to the
  // unknown path.
  asr_empty_result: { group: LOST, deliveryProven: true, emitted: false, label: "transcription returned nothing" },

  // Conservative. Producers DISAGREE and the indexed fields cannot separate
  // them: KernelLifecycleTelemetrySink.swift:476-503 can be an interrupted
  // recording while KernelDictationDriver.swift:912-934 emits was_recording
  // false, and BOTH send Sentry stage "asr". A `pipeline.stage` split was
  // proposed in an earlier draft and disproved against the producers.
  xpc_service_error: { group: LOST, deliveryProven: false, emitted: true, label: "transcription helper failed" },

  // Conservative, same shape. Both producers send stage "asr"
  // (KernelDictationDriver.swift:221-235); the distinguishing "sessionless"
  // marker is an unindexed EXTRA, so no aggregate field can split them.
  model_load_wedged: { group: LOST, deliveryProven: false, emitted: true, label: "speech model load got stuck" },

  // Conservative: covers both a failed dispatch and a nil collaborator, and
  // delivery is not decidable from the category alone.
  pipeline_dispatch_failed: { group: LOST, deliveryProven: false, emitted: true, label: "dictation could not start processing" },

  // Recovery paths. Each of these is the RESCUE of an already-undelivered
  // recording failing, so the dictation was lost in every case.
  recovery_decrypt_failed: { group: LOST, deliveryProven: true, emitted: true, label: "saved recording could not be unlocked" },
  recovery_transcribe_failed: { group: LOST, deliveryProven: true, emitted: true, label: "saved recording could not be transcribed" },
  recovery_empty_text: { group: LOST, deliveryProven: true, emitted: true, label: "saved recording produced no text" },
  recovery_abandoned_after_attempt: { group: LOST, deliveryProven: true, emitted: true, label: "saved recording was abandoned" },
});

/** An unhandled crash carries NO `error.category` at all - measured 2026-08-06,
 * 3 of 9 rows blank on a live pull, every one of them a crash. A
 * category-driven classifier without this branch drops the single most
 * important row into "uncategorised".
 *
 * The exception TYPE is included because a live smoke run printed two different
 * crashes as two identical "app crash" rows, which reads as a rendering bug
 * rather than as two distinct problems. `EXC_BAD_ACCESS` and
 * `NSInternalInconsistencyException` are very different things to see twice in
 * a row.
 *
 * ONLY the type, never the message. A Sentry title is `<type>: <message>`, and
 * the message half is the one place in this whole section where user-derived
 * text could appear. Splitting at the first colon and discarding the remainder
 * keeps the privacy boundary intact by construction rather than by trusting
 * Sentry's own redaction. */
const CRASH_TYPE_MAX = 48;

function crashLabel(title) {
  if (typeof title !== "string") return "app crash";
  const type = title.split(":", 1)[0].trim();
  // A type must look like an identifier. Anything else is a title shape this
  // code does not recognise, and printing it unexamined is how the message half
  // would eventually leak through some future format.
  if (type.length === 0 || type.length > CRASH_TYPE_MAX || !/^[A-Za-z_][A-Za-z0-9_.]*$/.test(type)) {
    return "app crash";
  }
  return `app crash (${type})`;
}

/**
 * Classifies one aggregate row.
 *
 * Returns `{ group, label, deliveryProven }`. Never throws and never returns
 * null: an unrecognised category is a real thing that happened to a real
 * person, so it is reported conservatively under its raw name rather than
 * discarded. `rawCategory` is preserved in the label precisely so a category
 * added to the app and not added to this table is visible in Discord.
 */
export function classifyProblem({ category, level, title }) {
  const raw = typeof category === "string" ? category.trim() : "";
  if (raw.length === 0) {
    // A blank category on a fatal is a crash. A blank category on a NON-fatal
    // is something this table does not know about, and guessing "crash" for it
    // would put a wrong sentence in front of the founder.
    if (typeof level === "string" && level.toLowerCase() === "fatal") {
      return { group: LOST, deliveryProven: false, label: crashLabel(title) };
    }
    return { group: LOST, deliveryProven: false, label: "uncategorised failure" };
  }
  const known = Object.hasOwn(ERROR_CATEGORIES, raw) ? ERROR_CATEGORIES[raw] : null;
  if (known) return { group: known.group, label: known.label, deliveryProven: known.deliveryProven };
  return { group: LOST, deliveryProven: false, label: raw };
}

// ── Release line ────────────────────────────────────────────────────────────

/** `com.enviouswispr.app@2.4.3` -> [2,4,3]. Returns null for anything that is
 * not a plain three-part version, so a malformed release is REFUSED rather than
 * ordered by accident. */
export function parseReleaseVersion(release) {
  if (typeof release !== "string") return null;
  const at = release.lastIndexOf("@");
  const version = at === -1 ? release : release.slice(at + 1);
  const parts = version.split(".");
  if (parts.length !== 3) return null;
  const nums = parts.map((p) => (/^\d+$/.test(p) ? Number(p) : null));
  return nums.some((n) => n === null) ? null : nums;
}

/**
 * Resolves the release line: the MINOR line of the single release with the most
 * affected people in the window, and everything at or above it.
 *
 * WHY THIS RULE AND NOT THE OBVIOUS ALTERNATIVES. It has to keep working
 * without maintenance, because the failure it prevents is exactly the one the
 * founder named: a bug fixed in a later version headlining the digest forever
 * ("the speech detector was actually solved in a later version").
 *
 *  - NOT a constant like the scorecard's SCORECARD_MIN_VERSION. A constant goes
 *    stale silently, which reproduces the defect a few months later.
 *  - NOT "the newest published release". That cliffs on release day, when
 *    almost nobody is on it yet, and would empty the section exactly when a new
 *    build most needs watching.
 *  - NOT a summed share across releases. Sentry user counts are NOT additive -
 *    one person appears under several releases - so summing them to rank would
 *    be arithmetic on numbers that do not add.
 *
 * A single release's user count is used ONLY as a ranking key and is never
 * displayed. Ties break toward the NEWER version, so the rule is deterministic
 * rather than dependent on Sentry's row order.
 *
 * Measured 2026-08-05 production: 2.4.3 (8 people), 2.4.1 (3), 2.4.0 (2),
 * 2.3.1 (2) resolves to 2.4.0, which over 7 days drops 6 of 21 problems - every
 * one a single-user tail on an old build, including the vad prepare failure the
 * founder named and `asr_empty_result`, which no shipping build emits.
 *
 * Returns `{ floor, tailPeople }` or null when no row carries a usable version.
 */
export function resolveReleaseLine(rows) {
  let best = null;
  let bestKey = null;
  for (const row of rows) {
    const version = parseReleaseVersion(row?.release);
    if (version === null) continue;
    const people = Number(row["count_unique(user)"]);
    if (!Number.isFinite(people)) continue;
    // Compare people first, then the version itself, so an exact tie resolves
    // to the newer release rather than to whichever Sentry happened to sort up.
    const key = [people, ...version];
    if (bestKey === null || compareKeys(key, bestKey) > 0) {
      bestKey = key;
      best = version;
    }
  }
  if (best === null) return null;

  const floor = `${best[0]}.${best[1]}.0`;
  // The tail is people on releases BELOW the line. Reported as a single
  // summary line: it sizes upgrade pressure without polluting the ranked list.
  // Deliberately a SUM even though user counts are non-additive across
  // releases, so it is worded as an upper bound ("up to N people") rather than
  // as a distinct-person count this data cannot produce.
  let tailPeople = 0;
  for (const row of rows) {
    const version = parseReleaseVersion(row?.release);
    if (version === null) continue;
    if (compareKeys(version, [best[0], best[1], 0]) < 0) {
      const people = Number(row["count_unique(user)"]);
      if (Number.isFinite(people)) tailPeople += people;
    }
  }
  return { floor, tailPeople };
}

function compareKeys(a, b) {
  for (let i = 0; i < Math.max(a.length, b.length); i += 1) {
    const x = a[i] ?? 0;
    const y = b[i] ?? 0;
    if (x !== y) return x < y ? -1 : 1;
  }
  return 0;
}

// ── Queries ─────────────────────────────────────────────────────────────────

/** THE CALL BUDGET, in one place, asserted by a test.
 *
 * FIVE fixed Sentry requests per digest run, whatever the error volume. The
 * plan's original three assumed the release line arrived free and that the
 * headline totals came from the same response as the per-problem rows; neither
 * held, because Discover returns EITHER a grouped result OR an aggregate, never
 * both (measured 2026-08-06).
 *
 * The constraint that actually matters is unchanged: NO CALL FANS OUT PER
 * ISSUE, so the count does not move with volume. Measured cost of all five:
 * ~1.8s and ~4.5KB, against a limit of 30 requests per window and 15 concurrent.
 *
 * Total EVENTS is deliberately derived from the per-issue rows rather than
 * bought with a sixth call - event counts are additive and were verified to sum
 * exactly to the aggregate (19+4+2+1+1+9+1+1 = 38). Distinct PEOPLE is not
 * derivable (13 distinct against per-problem counts summing to 15), which is
 * why calls 4 and 5 exist. */
export const SENTRY_CALLS_PER_DIGEST = 5;

const ISSUE_FIELDS = ["issue", "title", "error.category", "level", "count()", "count_unique(user)"];
// Read from meta.fields, which is present on an EMPTY response too. `issue` is
// deliberately absent from this list: Sentry echoes it back as `issue.id`, so
// requiring the requested name would fail on a perfectly good response and the
// obvious repair (deleting the check) is how an empty malformed body gets
// through. See workers/shared/sentry.js discoverAggregate.
const ISSUE_REQUIRED_META = ["error.category", "level", "count()", "count_unique(user)"];
const RELEASE_FIELDS = ["release", "count()", "count_unique(user)"];
const HEADLINE_FIELDS = ["count()", "count_unique(user)"];

const PROD = "production";

/**
 * Runs the whole section against Sentry and returns its data, or throws.
 *
 * `window` is CALLER-SUPPLIED and this module never reads the clock: the daily
 * report resolves an Eastern calendar day and the weekly digest resolves a
 * complete week, and a second window derived here could silently disagree with
 * the one the rest of the report is about.
 *
 * Runs OUTSIDE each worker's PostHog limiter, deliberately. Sentry has its own
 * ceiling (30 per window, 15 concurrent) and a Sentry read that waited for a
 * PostHog slot would block a PostHog query for ~1.8s while doing no PostHog
 * work at all.
 */
export async function fetchSentrySection(env, window, opts = {}) {
  const { startISO, endISO, priorStartISO, firstSeenPeriod } = window;
  // firstSeenPeriod is REQUIRED, never defaulted. A default of "24h" would be
  // correct for the daily report and silently wrong for the weekly digest,
  // which would then badge only the last day of a seven-day window - an answer
  // that looks right everywhere a human would look.
  for (const [name, value] of [
    ["startISO", startISO],
    ["endISO", endISO],
    ["priorStartISO", priorStartISO],
    ["firstSeenPeriod", firstSeenPeriod],
  ]) {
    if (typeof value !== "string" || value.length === 0) {
      throw new TypeError(`fetchSentrySection requires window.${name}`);
    }
  }

  // Stage 1. Independent of each other, so both go at once.
  //   call 1: which releases are live, and how the people split across them.
  //   call 3: the genuinely-new issue set (see the badge note below).
  const [releaseResult, newIssues] = await Promise.all([
    discoverAggregate(env, {
      queryName: "sentry_releases",
      fields: RELEASE_FIELDS,
      requiredFields: ["release", "count_unique(user)"],
      environment: PROD,
      start: startISO,
      end: endISO,
      sort: "-count_unique(user)",
      perPage: 100,
    }, opts),
    // The badge comes from firstSeen, NEVER from a min(timestamp) over the
    // window. That was the original design and it was measured wrong: min()
    // is scoped to events MATCHING the query, not to the issue's lifetime, so
    // every still-active problem read as new. ENVIOUSWISPR-24, first seen
    // 2026-07-02, returned a min(timestamp) of today.
    issueList(env, {
      queryName: "sentry_new_issues",
      query: `firstSeen:-${firstSeenPeriod}`,
      environment: PROD,
      limit: 100,
    }, opts),
  ]);

  const line = resolveReleaseLine(releaseResult.rows);
  // No usable release in the window means no honest scope for the numbers
  // below. Reported as unavailable rather than as an unscoped total that would
  // silently re-admit every fixed bug on every old build.
  if (line === null) {
    return {
      empty: true,
      reason: releaseResult.rows.length === 0 ? "no-errors" : "no-release-line",
      truncated: false,
    };
  }

  const releaseFilter = `release.version:>=${line.floor}`;

  // Stage 2. All three need the release line, and nothing needs the others.
  const [problems, current, prior] = await Promise.all([
    discoverAggregate(env, {
      queryName: "sentry_problems",
      fields: ISSUE_FIELDS,
      requiredFields: ISSUE_REQUIRED_META,
      query: releaseFilter,
      environment: PROD,
      start: startISO,
      end: endISO,
      sort: "-count_unique(user)",
      perPage: 100,
    }, opts),
    discoverAggregate(env, {
      queryName: "sentry_headline",
      fields: HEADLINE_FIELDS,
      requiredFields: HEADLINE_FIELDS,
      query: releaseFilter,
      environment: PROD,
      start: startISO,
      end: endISO,
      perPage: 1,
    }, opts),
    discoverAggregate(env, {
      queryName: "sentry_prior",
      fields: HEADLINE_FIELDS,
      requiredFields: HEADLINE_FIELDS,
      query: releaseFilter,
      environment: PROD,
      start: priorStartISO,
      end: startISO,
      perPage: 1,
    }, opts),
  ]);

  const newShortIds = new Set(newIssues.issues.map((i) => i.shortId));

  const rows = problems.rows.map((row) => {
    const classified = classifyProblem({
      category: row["error.category"],
      level: row.level,
      title: row.title,
    });
    return {
      shortId: typeof row.issue === "string" ? row.issue : null,
      people: toCount(row["count_unique(user)"]),
      events: toCount(row["count()"]),
      group: classified.group,
      label: classified.label,
      deliveryProven: classified.deliveryProven,
      isNew: typeof row.issue === "string" && newShortIds.has(row.issue),
    };
  });

  return {
    empty: rows.length === 0,
    reason: rows.length === 0 ? "no-errors" : null,
    floor: line.floor,
    tailPeople: line.tailPeople,
    people: headlineValue(current.rows, "count_unique(user)"),
    priorPeople: headlineValue(prior.rows, "count_unique(user)"),
    // Derived, not bought: event counts ARE additive and were verified to sum
    // exactly to the aggregate. The people total above cannot be derived the
    // same way, because one person can hit several problems.
    events: rows.reduce((sum, r) => sum + r.events, 0),
    rows,
    // Over-reported rather than under-reported: a full page is treated as
    // "there may be more" even without a next-page header, because the only
    // consequence is the section printing its honest limited-breakdown wording.
    truncated: problems.truncated,
  };
}

/** A count that is not a finite number is a defect in the response, not a zero.
 * Zero is a real and common answer here, so a `|| 0` fallback would make a
 * malformed row indistinguishable from a quiet day. */
function toCount(value) {
  const n = Number(value);
  if (!Number.isFinite(n) || n < 0) {
    throw new TypeError(`Sentry returned a non-numeric count: ${String(value)}`);
  }
  return n;
}

/** An aggregate with no grouping returns exactly one row. Zero rows means
 * Sentry had nothing to aggregate, which is a real zero; anything else is a
 * shape this code should not be interpreting. */
function headlineValue(rows, field) {
  if (rows.length === 0) return 0;
  if (rows.length !== 1) {
    throw new TypeError(`Sentry aggregate returned ${rows.length} rows where one was expected`);
  }
  return toCount(rows[0][field]);
}

// ── Presentation ────────────────────────────────────────────────────────────

const people = (n) => `${n} ${n === 1 ? "person" : "people"}`;

/** Character budget for this section's description.
 *
 * Discord caps one description at 4096 and ALL embeds together at 6000, and
 * exceeding either sends NOTHING - the whole report would disappear on exactly
 * the day Sentry has most to say. A fixed conservative budget per section keeps
 * that arithmetic true without this module having to know what the other
 * sections are doing. Rows are rendered while they fit and the remainder is
 * DISCLOSED, never silently dropped. */
export const DEFAULT_SECTION_BUDGET = 1200;

/**
 * The section, as LINES whose FIRST line titles its embed - the same shape every
 * other section formatter returns, so the payload assembler never authors a
 * sentence of its own.
 */
export function formatSentrySection(data, { title, budget = DEFAULT_SECTION_BUDGET } = {}) {
  if (typeof title !== "string" || title.length === 0) {
    throw new TypeError("formatSentrySection requires a title");
  }
  const lines = [title];

  if (data.empty && data.reason === "no-release-line") {
    // Distinct from "no errors": errors existed and could not be scoped to a
    // release line, which is a measurement failure, not good news.
    lines.push("Errors were recorded but could not be matched to a release, so they are not summarised here.");
    return lines;
  }
  if (data.empty) {
    // An EXPLICIT good-news line. An empty section reads as a broken section.
    lines.push("No errors were recorded on current versions.");
    return lines;
  }

  lines.push(
    `${people(data.people)} hit ${data.events} ${data.events === 1 ? "error" : "errors"} ` +
      `across ${data.rows.length} ${data.rows.length === 1 ? "problem" : "problems"}, on ${data.floor} and newer.`
  );

  // The action metric. An absolute count rises with usage, so it cannot answer
  // "is this spreading", which is the entire reason this section exists.
  const delta = data.people - data.priorPeople;
  const direction = delta === 0 ? "the same as" : delta > 0 ? `${delta} more than` : `${-delta} fewer than`;
  lines.push(`That is ${direction} the previous period (${people(data.priorPeople)}).`);
  // Never a rate. Sentry and PostHog join only per INSTALL and only partially
  // (sentry-operations.md RULE: join-sentry-to-posthog-by-install), so dividing
  // one system's distinct-user count by the other's would be arithmetic across
  // two identity systems. Saying so is better than inventing a denominator.
  lines.push("Impact rate unavailable: error counts and usage counts come from different identity systems.");

  if (data.tailPeople > 0) {
    // "Up to", because these are per-release counts summed across releases and
    // one person can appear under more than one.
    lines.push(`Separately, up to ${people(data.tailPeople)} on builds older than ${data.floor}.`);
  }
  lines.push("");

  const rows = disambiguate(data.rows);
  const lost = rows.filter((r) => r.group === LOST);
  const degraded = rows.filter((r) => r.group === DEGRADED);

  const budgetState = { used: lines.join("\n").length, budget, omitted: 0 };
  appendGroup(lines, "LOST THE DICTATION", lost, budgetState);
  appendGroup(lines, "STILL WORKED, JUST WORSE", degraded, budgetState);

  if (budgetState.omitted > 0) {
    lines.push(
      `${budgetState.omitted} more ${budgetState.omitted === 1 ? "problem is" : "problems are"} ` +
        "not listed here. The totals above include them."
    );
  }
  if (data.truncated) {
    lines.push("100 or more problems were recorded; the breakdown covers the largest 100 only.");
  }
  return lines;
}

/** Appends the Sentry issue id to rows whose labels would otherwise be
 * identical.
 *
 * Two DIFFERENT problems rendering as two identical lines reads as a rendering
 * bug rather than as two real problems, and a live smoke run produced exactly
 * that: two distinct `NSInternalInconsistencyException` fingerprints, one
 * person each. The exception type alone does not separate them.
 *
 * Merging them instead was rejected. Event counts would add correctly, but
 * people counts are NOT additive across issues - the same person can hit both -
 * so a merged row would have to either overstate the people or invent a number
 * this data cannot produce. The id is the honest separator, and it is also the
 * thing the founder would search for.
 *
 * Applied across the WHOLE row set before the groups are split, because a
 * collision can straddle the lost/degraded boundary and would be invisible to a
 * per-group pass. Rows with no id are left alone: an id-less row cannot be
 * disambiguated and a bare "(unknown)" would say nothing. */
function disambiguate(rows) {
  const counts = new Map();
  for (const row of rows) counts.set(row.label, (counts.get(row.label) || 0) + 1);
  return rows.map((row) =>
    counts.get(row.label) > 1 && row.shortId
      ? { ...row, label: `${row.label} ${row.shortId}` }
      : row
  );
}

function appendGroup(lines, heading, rows, state) {
  if (rows.length === 0) return;
  const headingCost = heading.length + 2;
  if (state.used + headingCost > state.budget) {
    state.omitted += rows.length;
    return;
  }
  lines.push(heading);
  state.used += headingCost;
  for (const row of rows) {
    // Appended for every conservative row, so a classification made on missing
    // evidence never reads as a demonstrated loss. The founder acts on this
    // list, and "lost the dictation" is a strong claim to make on a category
    // whose producers disagree.
    const suffix = row.deliveryProven ? "" : ", delivery not proven";
    const text = `  ${people(row.people)}   ${row.label}${suffix}${row.isNew ? "   NEW" : ""}`;
    if (state.used + text.length + 1 > state.budget) {
      state.omitted += 1;
      continue;
    }
    lines.push(text);
    state.used += text.length + 1;
  }
  lines.push("");
  state.used += 1;
}

/** Plain-language unavailable copy, owned here so no integration ever authors
 * new failure wording. Discloses nothing technical: no error text, URL, status
 * code or response body. Says nothing was measured, rather than letting a
 * missing section read as a quiet zero. */
export function formatSentryUnavailable(title) {
  if (typeof title !== "string" || title.length === 0) {
    throw new TypeError("formatSentryUnavailable requires a title");
  }
  return [
    `${title}, unavailable today.`,
    "Error figures could not be measured, so this is not a report of zero.",
  ];
}
