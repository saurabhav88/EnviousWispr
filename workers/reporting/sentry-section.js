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
  const nums = parts.map((p) => (/^\d+$/.test(p) ? Number(p) : NaN));
  // Safe integers only. A component past 2^53 loses precision and would
  // then compare equal to its neighbours, making the ordering arbitrary.
  return nums.every(Number.isSafeInteger) ? nums : null;
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
 * KNOWN LIMIT, raised by cloud review on PR #1968 and NOT fixed here (#1970).
 * The ranking key is AFFECTED people, which is a proxy for INSTALLED people and
 * not the same quantity. They diverge when a new release is both widely adopted
 * and sharply healthier: a release that fixes a high-frequency crash earns few
 * error rows, so it cannot win the ranking, and the floor can sit on the older
 * line while a bug already fixed above it keeps the headline. That is a weaker
 * form of the very defect this function exists to prevent.
 *
 * What was measured (2026-08-06, live, driving these shipped functions rather
 * than a copy of them): ranking by Sentry affected users and ranking by PostHog
 * active users produce the SAME floor, 2.4.0, over both the 1-day and 7-day
 * windows. Affected count tracks population closely enough today because error
 * volume scales with usage.
 *
 * What that did NOT cover: any window in which a release's error RATE changes
 * sharply, which is exactly the post-fix rollout. One agreeing measurement on a
 * calm population is not evidence the rule holds through a quality cliff, and
 * this comment is not a claim that the question is settled.
 *
 * Why it was not fixed in the PR that found it: the correction needs per-version
 * ADOPTION, which lives in PostHog. `weekly-digest` has no per-version usage
 * query at all, and `daily-report`'s lives in its own version scorecard, so
 * closing this means either a new cross-vendor query in the weekly worker or
 * two different release rules in one shared section. Both contradict decisions
 * this plan made deliberately: the section degrades independently of PostHog so
 * a Sentry outage cannot cost the adoption numbers, and it prints no impact rate
 * precisely because the two identity systems join only partially. Reopening that
 * is a product call, not a review-loop patch.
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
    const people = countOrNull(row["count_unique(user)"]);
    if (people === null) continue;
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
      const people = countOrNull(row["count_unique(user)"]);
      // Each addend is a safe integer; their SUM need not be. An earlier
      // version returned a FABRICATED ZERO on overflow, which is the one answer
      // this section must never give: it reads as "nobody is on an old build".
      if (people !== null) tailPeople = addCounts(tailPeople, people, "old-build people total");
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

/** THE MAXIMUM CALL BUDGET, in one place, asserted by a test.
 *
 * FIVE fixed Sentry requests per digest run, whatever the error volume. The
 * plan's original three assumed the release line arrived free and that the
 * headline totals came from the same response as the per-problem rows; neither
 * held, because Discover returns EITHER a grouped result OR an aggregate, never
 * both (measured 2026-08-06).
 *
 * FIVE is the MAXIMUM, not a fixed toll. A run that finds no usable release
 * line stops after its two stage-one calls, because the remaining three cannot
 * be scoped honestly and an unscoped answer is worse than no answer.
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
  const { startISO, endISO, priorStartISO } = window;
  // There is no `firstSeenPeriod` any more. It was a RELATIVE lookback each
  // caller had to get right ("24h" here, "7d" there), and being caller-supplied
  // did not make it correct - it was measured against the wrong instant in both
  // workers. The badge window is now derived from the reported window itself,
  // so there is nothing left for a caller to get wrong.
  for (const [name, value] of [
    ["startISO", startISO],
    ["endISO", endISO],
    ["priorStartISO", priorStartISO],
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
    //
    // ABSOLUTE, not `firstSeen:-24h`. The relative form is measured from NOW,
    // and neither report runs at the instant its window closes: the daily one
    // runs after the Eastern day ends and can be backfilled to any historical
    // day, the weekly one runs 13 hours after its window. So the relative form
    // straddles the window in both directions - it excludes part of what is
    // being reported and includes issues from outside it. Demonstrated on live
    // data 2026-08-06: `firstSeen:-5d` returned 3 issues where the equivalent
    // absolute range returned 4, silently dropping one first seen 4 hours
    // outside the relative cutoff.
    //
    // Sentry filters this SERVER-side, which is what keeps the result small:
    // the same live check returned 3 rows for the absolute range against 45
    // for an unfiltered window query. That matters because an unfiltered form
    // would hit the 100-row page cap on any busy week and force a choice
    // between a wrong badge and a refused section.
    issueList(env, {
      queryName: "sentry_new_issues",
      query: `firstSeen:>=${startISO} firstSeen:<${endISO}`,
      environment: PROD,
      start: startISO,
      end: endISO,
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

  // Belt as well as braces: the query already filters server-side, and this
  // re-checks the boundary locally so a change in Sentry's search semantics
  // degrades to a missing badge rather than to a wrong one. `Z` is appended
  // because the window strings are naive instants that Sentry reads as UTC, and
  // Date.parse would otherwise read them as LOCAL time - a silent offset that
  // would misclassify issues near either edge.
  const startMs = windowInstant(startISO);
  const endMs = windowInstant(endISO);
  // A FULL PAGE OF NEW ISSUES MEANS THE BADGE SET IS INCOMPLETE, and that is
  // disclosed rather than thrown.
  //
  // The review prescribed throwing here, which would make the whole section
  // unavailable. That is the wrong trade: reaching 100 genuinely-new issues in
  // one window means a catastrophic release, which is precisely when the
  // ranked problem list is most worth reading. Losing it entirely to protect a
  // badge inverts the value.
  //
  // Disclosure is also what this section already does one layer up: the problem
  // list discloses its own 100-row ceiling rather than refusing to render. A
  // guard that behaves one way for problems and the opposite way for badges
  // would be two policies for one situation.
  const badgesIncomplete = newIssues.truncated;

  const newShortIds = new Set(
    newIssues.issues
      .filter((issue) => {
        const firstSeenMs = Date.parse(issue.firstSeen);
        return firstSeenMs >= startMs && firstSeenMs < endMs;
      })
      .map((issue) => issue.shortId)
  );

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
    events: rows.reduce((sum, r) => addCounts(sum, r.events, "event total"), 0),
    rows,
    // Over-reported rather than under-reported: a full page is treated as
    // "there may be more" even without a next-page header, because the only
    // consequence is the section printing its honest limited-breakdown wording.
    truncated: problems.truncated,
    // A SEPARATE truncation axis from `truncated` above, and they are not
    // interchangeable: that one bounds the PROBLEM list, this one bounds the
    // RELEASE list, and only this one can make the old-build tail understate.
    //
    // The FLOOR is safe under it and the tail is not, which is why one flag
    // cannot serve both. `sentry_releases` sorts by `-count_unique(user)`, so
    // the release with the most affected people is on the first page by
    // construction and `resolveReleaseLine` still picks the right winner. The
    // tail sums releases BELOW that line - precisely the low-count rows a cut
    // page drops - so it is the half that breaks.
    releasesTruncated: releaseResult.truncated,
    badgesIncomplete,
  };
}

/** Adds two counts and refuses a result that is no longer exact.
 *
 * Every addend here is already a validated safe integer, but their SUM need not
 * be, and past that point the number silently stops being the number. Throwing
 * costs one unavailable section; publishing costs the founder a figure he has
 * no way to tell is wrong. */
function addCounts(left, right, label) {
  const total = left + right;
  if (!Number.isSafeInteger(total)) {
    throw new TypeError(`Sentry ${label} exceeds the safe integer range`);
  }
  return total;
}

/** Parses one of the window's naive ISO instants as UTC.
 *
 * Exported ONLY so this can be tested independently of the machine's timezone.
 * A test that fed a boundary fixture through the whole section would pass
 * trivially on a UTC runner and could only ever fail on a developer's machine,
 * which is the wrong way round.
 *
 * The `Z` is the entire point. Sentry reads these strings as UTC, but
 * `Date.parse` without a zone reads them as LOCAL time - a four or five hour
 * shift on this machine - and the badge boundary would then be silently offset,
 * misclassifying every issue first seen near either edge of the window. */
export function windowInstant(naiveISO) {
  const ms = Date.parse(`${naiveISO}Z`);
  if (Number.isNaN(ms)) throw new TypeError(`window instant is not a valid ISO timestamp: ${naiveISO}`);
  return ms;
}

/** A count, or null if the value is not one.
 *
 * `Number()` is far too permissive to validate with, and every one of these is
 * a real Sentry response shape away from being a wrong number in a sentence:
 * `Number(null)`, `Number("")`, `Number(false)` and `Number([])` are all 0, and
 * `Number(["7"])` is 7. A single-element array reading as a person count is the
 * dangerous one, because it is silent and plausible.
 *
 * So the type is checked BEFORE the value, and the value must be a
 * non-negative INTEGER: Sentry counts people and events, and 1.5 people is a
 * response shape this code should refuse rather than round. */
function countOrNull(value) {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) return null;
  return value;
}

/** The throwing form, for a count the section cannot render without.
 *
 * Zero is a real and common answer here, so a `|| 0` fallback would make a
 * malformed row indistinguishable from a quiet day. */
function toCount(value) {
  const n = countOrNull(value);
  if (n === null) {
    throw new TypeError(`Sentry returned a value that is not a count: ${JSON.stringify(value) ?? String(value)}`);
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

/** Discord's own per-description cap. Duplicated as a NUMBER rather than
 * imported from workers/shared/discord.js on purpose: this module is report
 * policy and that one is transport, and reaching across the boundary for a
 * constant is how the boundary stops meaning anything. The value is asserted
 * against the transport's own DISCORD_LIMITS in the test suite, so the two
 * cannot drift apart silently. */
const DISCORD_EMBED_DESCRIPTION_LIMIT = 4096;

/**
 * The section, as LINES whose FIRST line titles its embed - the same shape every
 * other section formatter returns, so the payload assembler never authors a
 * sentence of its own.
 */
export function formatSentrySection(data, { title, budget: requestedBudget = DEFAULT_SECTION_BUDGET } = {}) {
  if (typeof title !== "string" || title.length === 0) {
    throw new TypeError("formatSentrySection requires a title");
  }
  // VALIDATED BEFORE IT IS CAPPED. `NaN` makes every `> budget` comparison
  // false, so a NaN budget disables every check silently and renders whatever
  // it likes - measured at 21,824 characters during review. `Math.min` does not
  // rescue it either, because `Math.min(NaN, 4096)` is NaN.
  if (typeof requestedBudget !== "number" || !Number.isSafeInteger(requestedBudget) || requestedBudget <= 0) {
    throw new TypeError("formatSentrySection budget must be a positive safe integer");
  }
  // Capped at Discord's own per-description limit. Without the cap a generous
  // caller could ask for more than Discord accepts and the whole payload would
  // be refused at delivery - the failure this budget exists to prevent,
  // reached through the budget itself.
  const budget = Math.min(requestedBudget, DISCORD_EMBED_DESCRIPTION_LIMIT);
  const lines = [title];

  if (data.empty && data.reason === "no-release-line") {
    // Distinct from "no errors": errors existed and could not be scoped to a
    // release line, which is a measurement failure, not good news.
    lines.push("Errors were recorded but could not be matched to a release, so they are not summarised here.");
    return finishSection(lines, budget);
  }
  if (data.empty) {
    // An EXPLICIT good-news line. An empty section reads as a broken section.
    lines.push("No errors were recorded on current versions.");
    return finishSection(lines, budget);
  }

  // THE TRUNCATED CASE IS A DIFFERENT SENTENCE, not the same one with a note.
  // `events` is summed from the returned problem rows, so on a truncated page
  // it EXCLUDES everything past the first hundred: printing it as the error
  // total understates it, and the old disclosure then said "the totals above
  // include them", which was flatly untrue. The PEOPLE figure is unaffected -
  // it comes from an ungrouped aggregate that is never paginated - so only the
  // error count and the problem count need qualifying.
  const errorText = data.truncated
    ? `at least ${data.events} ${data.events === 1 ? "error" : "errors"}`
    : `${data.events} ${data.events === 1 ? "error" : "errors"}`;
  const problemText = data.truncated
    ? "100 or more problems"
    : `${data.rows.length} ${data.rows.length === 1 ? "problem" : "problems"}`;
  lines.push(`${people(data.people)} hit ${errorText} across ${problemText}, on ${data.floor} and newer.`);

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
    //
    // A TRUNCATED RELEASE PAGE INVERTS THAT BOUND, so the wording cannot stand.
    // The sum overstates (non-additive people) and a cut-off page understates
    // (missing old releases), and the two pull opposite ways - so "up to N" is
    // no longer a claim the data supports in either direction. Say it is
    // partial instead of picking a bound that might be false.
    lines.push(
      data.releasesTruncated
        ? `Separately, at least ${people(data.tailPeople)} on builds older than ${data.floor}, from a partial release list.`
        : `Separately, up to ${people(data.tailPeople)} on builds older than ${data.floor}.`
    );
  }
  lines.push("");

  const rows = disambiguate(data.rows);
  const lost = rows.filter((r) => r.group === LOST);
  const degraded = rows.filter((r) => r.group === DEGRADED);

  // The disclosure lines are appended AFTER the rows, so their cost has to be
  // reserved BEFORE the rows are laid out. Without the reservation the section
  // spends the whole budget on rows and then overshoots it by exactly the
  // length of the sentence explaining that it ran out - measured at 24
  // characters over a 1200 budget, which is the shape that eventually pushes an
  // assembled payload past a Discord limit and sends nothing at all.
  const reserve =
    omittedLine(data.rows.length, data.truncated).length + 1 +
    TRUNCATED_LINE.length + 1 +
    BADGES_INCOMPLETE_LINE.length + 1;
  const state = { budget: budget - reserve, omitted: 0 };
  appendGroup(lines, "LOST THE DICTATION", lost, state);
  appendGroup(lines, "STILL WORKED, JUST WORSE", degraded, state);

  if (state.omitted > 0) lines.push(omittedLine(state.omitted, data.truncated));
  if (data.truncated) lines.push(TRUNCATED_LINE);
  // Stated plainly, because an absent badge is indistinguishable from a problem
  // that is not new, and the reader has no other way to tell.
  if (data.badgesIncomplete) lines.push(BADGES_INCOMPLETE_LINE);

  return finishSection(lines, budget);
}

/** ENFORCES THE ACTUAL OUTPUT, not the counter that produced it, on EVERY exit.
 *
 * If the reservation arithmetic is ever wrong again, this turns a silent
 * over-budget description into one unavailable SECTION. That is the right
 * failure direction: an over-budget assembled payload is refused whole by
 * Discord, which costs the founder the entire report rather than one part of
 * it. Both callers convert this into an unavailable section, never a whole-run
 * failure.
 *
 * Applied at all three returns. Two of them are the short empty-result paths,
 * whose output is fixed and tiny - which is exactly why it was tempting to skip
 * them, and exactly why a guard with exceptions is not a guard. */
function finishSection(lines, budget) {
  const rendered = descriptionLength(lines);
  if (rendered > budget) {
    throw new RangeError(`Sentry section rendered ${rendered} characters, over its ${budget}-character budget`);
  }
  return lines;
}

/** "MAY not be complete", not "are not".
 *
 * `hasMorePages` deliberately treats any full page as "there may be more", even
 * when exactly 100 complete rows arrived and there is no next page, because a
 * missing Link header proves nothing. That over-reporting is the right default
 * - but it means this line cannot assert incompleteness as a fact, only as a
 * possibility. Every other truncation sentence survives the same scrutiny
 * ("at least N errors", "100 or more problems", "cover the largest 100 only"
 * are all true when exactly 100 arrive); this one did not, and was swept for
 * alongside them rather than fixed alone. */
const BADGES_INCOMPLETE_LINE =
  "100 or more problems were seen for the first time in this window, so the NEW marks below may not be complete.";

const TRUNCATED_LINE =
  "100 or more problems were recorded. The affected-people total covers all of them; " +
  "the error count and the breakdown cover the largest 100 only.";

/** `truncated` changes the CLAIM, not just the wording: when the problem page
 * was cut off, the totals above genuinely do NOT include the omitted rows, so
 * the sentence that says they do must not be printed. */
const omittedLine = (n, truncated) =>
  `${n} more ${n === 1 ? "problem is" : "problems are"} not listed here.` +
  (truncated ? "" : " The totals above include them.");

/** The rendered description length, which is every line EXCEPT the title.
 *
 * Measured from the lines themselves on each check rather than tracked
 * incrementally. An incremental counter has to model every separator the join
 * will add, and the version that did drifted - which is invisible until the
 * assembled payload is refused by Discord and the whole report disappears. */
const descriptionLength = (lines) => lines.slice(1).join("\n").length;

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
 * per-group pass. */
function disambiguate(rows) {
  const counts = new Map();
  for (const row of rows) counts.set(row.label, (counts.get(row.label) || 0) + 1);

  // First pass: the issue id, which is the meaningful separator and the thing
  // the founder would search for.
  const withIds = rows.map((row) =>
    counts.get(row.label) > 1 && row.shortId
      ? { ...row, label: `${row.label} ${row.shortId}` }
      : row
  );

  // Second pass, because the first is NOT sufficient: rows sharing a shortId,
  // and rows with no shortId at all, still collide after it.
  //
  // A COUNT-THEN-NUMBER pass is not enough either, and that is the subtle part.
  // Counting duplicates first and appending an ordinal to each produces a label
  // that can collide with one already present: `["same", "same", "same (1)"]`
  // renders two identical `same (1)` lines. Demonstrated by review, not
  // theorised. So the labels are claimed one at a time against a set of what
  // has actually been used, and the ordinal advances until the result is free.
  const used = new Set();
  return withIds.map((row) => {
    const base = row.label;
    let label = base;
    let ordinal = 1;
    while (used.has(label)) {
      label = `${base} (${ordinal})`;
      ordinal += 1;
    }
    used.add(label);
    return label === base ? row : { ...row, label };
  });
}

/** Renders one group, adding rows only while the WHOLE description still fits.
 *
 * Every check re-measures the real rendered length, and any line that would not
 * fit is popped straight back off. That is slightly wasteful and it is exactly
 * what makes the budget true: there is no separate model of the output that can
 * disagree with the output.
 *
 * A group whose heading alone does not fit contributes its rows to the omitted
 * count rather than printing an empty heading. */
function appendGroup(lines, heading, rows, state) {
  if (rows.length === 0) return;

  lines.push(heading);
  if (descriptionLength(lines) > state.budget) {
    lines.pop();
    state.omitted += rows.length;
    return;
  }

  for (const row of rows) {
    // Appended for every conservative row, so a classification made on missing
    // evidence never reads as a demonstrated loss. The founder acts on this
    // list, and "lost the dictation" is a strong claim to make on a category
    // whose producers disagree.
    const suffix = row.deliveryProven ? "" : ", delivery not proven";
    lines.push(`  ${people(row.people)}   ${row.label}${suffix}${row.isNew ? "   NEW" : ""}`);
    if (descriptionLength(lines) > state.budget) {
      lines.pop();
      state.omitted += 1;
    }
  }

  lines.push("");
  if (descriptionLength(lines) > state.budget) lines.pop();
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
