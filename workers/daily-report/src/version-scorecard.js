/**
 * Release-selection and telemetry-comparison authority for the version
 * scorecard (issue #1838 chunk 3).
 *
 * Two separate judgements live here, and keeping them apart is the point:
 *
 * 1. WHICH releases the scorecard judges. Publication decides membership;
 *    adoption only decides ORDER and coverage. A hotfix published this morning
 *    with 1% share is the build most worth watching, so ranking purely by usage
 *    would drop exactly the wrong one.
 *
 * 2. WHETHER two releases' numbers may honestly be compared. A metric is
 *    comparable only when every displayed release declares the same telemetry
 *    contract. Comparability is NEVER inferred from which event codes happen to
 *    appear: that would make a metric change when the DISPLAYED SET changes -
 *    drop an old release off the table and previously-excluded diagnostics enter
 *    the calculation, moving a rate with no product change. That is worse than
 *    the bug it would be trying to solve, because it looks like a real movement.
 *
 * Telemetry contracts describe what an APP RELEASE emitted. The worker's own
 * calculation identity is a separate axis and is owned by chunk 4, atomically
 * with the literal SQL its freeze test must hash.
 *
 * Privacy: this module handles version strings and counts. It never logs or
 * returns a GitHub response body.
 */

import { hogql, rowsToObjects } from "../../shared/posthog.js";

/** Distinguishes an exhausted TRANSIENT failure - which the scorecard section
 * may degrade on while adoption still renders - from a contract failure
 * (missing configuration, malformed release data, an unknown metric), which must
 * stay loud. Collapsing the two would let a misconfigured worker quietly report
 * "scorecard temporarily unavailable" forever. */
export class ReleaseResolutionError extends Error {
  constructor(message, { transient }) {
    super(message);
    this.name = "ReleaseResolutionError";
    this.transient = transient === true;
  }
}

const GITHUB_API = "https://api.github.com";
const USER_AGENT = "EnviousWispr-Daily-Report";
const GITHUB_MAX_ATTEMPTS = 3;

// Approved product policy, deliberately NOT caller-overridable parameters: a
// later caller must not be able to quietly widen coverage or show more releases
// than the plan agreed.
const TARGET_COVERAGE = 0.8;
const MAX_RELEASES = 4;

/** When `fallback_reason` first shipped, verified against the tags rather than
 * remembered: `git show v2.1.4:...TelemetryService.swift | grep 'props\["fallback_reason"\]'`
 * finds nothing, and the same command on v2.2.0 finds it. The contract table
 * below carried v2.3.1, which was wrong and would have marked 2.2.x and 2.3.0
 * non-comparable on polish and dropped their weeks from historical variation. */
const POLISH_FALLBACK_REASON_FROM = "2.2.0";

/** The oldest release the scorecard will measure at all.
 *
 * Releases before 2.2.0 never emitted `fallback_reason`, so their discards
 * count as zero and their AI-polish figure reads a flat, false 100%. Measured
 * over 56 production days: 2.1.0 reports 100% where the truth is 88.7%, 2.1.3
 * 100% against 95.9%, 2.1.4 100% against 96.5%. Every release from 2.2.0
 * onward is unaffected - zero orphaned discards on all of them, so this floor
 * changes no number the founder actually reads.
 *
 * The founder's decision (2026-07-29) was to hide those builds rather than
 * print a figure known to be wrong beside a caveat, because a perfect score
 * with a footnote still reads as a perfect score. Applied in JS via
 * compareVersions, never as a SQL string comparison: '2.10.0' < '2.2.0'
 * lexically, so a string floor would silently start hiding future releases. */
const SCORECARD_MIN_VERSION = POLISH_FALLBACK_REASON_FROM;

/** True when a canonical version is at or above the measurement floor. */
export function isScorecardEligible(version) {
  return version !== null && compareVersions(version, SCORECARD_MIN_VERSION) >= 0;
}
// Constrained to GitHub's own slug charset, not merely "no slashes or spaces".
// A looser pattern let "owner/repo?per_page=1", "../repo" and "owner/.." through
// into a URL, where they mean something entirely different from a repo name.
const REPO_SLUG = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const isSafeRepoSegment = (seg) => seg !== "." && seg !== "..";
const SEMVER = /^v?(\d+)\.(\d+)\.(\d+)$/;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const GITHUB_TIMESTAMP = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/;

/** Strict UTC timestamp parser, the single owner for every publication date.
 *
 * `new Date(...)` is far too permissive to validate with: "0" becomes the year
 * 2000, "July 24, 2026" parses in local time, and "2026-02-30" silently rolls
 * forward to March 2nd. Any of those would be accepted as a publication date and
 * could reorder the displayed release set. Requires GitHub's exact wire form,
 * then re-checks the calendar components so a rolled-over date is refused rather
 * than reinterpreted. Returns null on anything else. */
function parseGitHubTimestamp(value) {
  if (typeof value !== "string") return null;
  const m = GITHUB_TIMESTAMP.exec(value);
  if (!m) return null;
  const [, y, mo, d, h, mi, sec] = m.map(Number);
  const ms = Date.UTC(y, mo - 1, d, h, mi, sec);
  if (!Number.isFinite(ms)) return null;
  const back = new Date(ms);
  // A date that normalises to a DIFFERENT calendar date was impossible.
  if (
    back.getUTCFullYear() !== y || back.getUTCMonth() !== mo - 1 || back.getUTCDate() !== d ||
    back.getUTCHours() !== h || back.getUTCMinutes() !== mi || back.getUTCSeconds() !== sec
  ) {
    return null;
  }
  return ms;
}

/** Rejects a SPARSE array. `.map`/`.some` skip holes entirely, so
 * `new Array(1)` passes a null check and then yields `undefined` downstream -
 * `decideComparability("people", new Array(1))` returned comparable:true with an
 * undefined contract. Length alone is not proof of contents. */
function assertDenseArray(value, label) {
  if (!Array.isArray(value)) {
    throw new ReleaseResolutionError(`${label} must be an array`, { transient: false });
  }
  for (let i = 0; i < value.length; i += 1) {
    // Object.hasOwn, not `in`: `in` walks the PROTOTYPE, so an array whose
    // prototype supplies index 0 reads as dense while owning no element.
    if (!Object.hasOwn(value, i)) {
      throw new ReleaseResolutionError(`${label} has a hole at index ${i}`, { transient: false });
    }
  }
}

/** GitHub tags are `v2.4.1`; telemetry `app_version` is `2.4.1`. Returns null
 * for anything that is not a plain three-part semantic version, so a malformed
 * tag is REFUSED rather than silently selected around. */
export function normalizeReleaseVersion(value) {
  // Deliberately NOT String(value): coercing an object or number here would
  // accept input the rest of the module then treats as a version string.
  if (typeof value !== "string") return null;
  const match = SEMVER.exec(value.trim());
  if (!match) return null;
  const parts = [Number(match[1]), Number(match[2]), Number(match[3])];
  if (!parts.every(Number.isSafeInteger)) return null;
  return parts.join(".");
}

/** Numeric per-component comparison. Lexicographic ordering would rank `2.4.9`
 * above `2.4.10`, which is how a stale release survives on the table and the
 * newest one falls off. Returns <0, 0, >0. */
export function compareVersions(a, b) {
  const pa = normalizeReleaseVersion(a);
  const pb = normalizeReleaseVersion(b);
  if (pa === null || pb === null) {
    throw new ReleaseResolutionError(
      `cannot compare malformed version: ${pa === null ? a : b}`,
      { transient: false }
    );
  }
  const [a1, a2, a3] = pa.split(".").map(Number);
  const [b1, b2, b3] = pb.split(".").map(Number);
  return a1 - b1 || a2 - b2 || a3 - b3;
}

/** A 403 is transient ONLY when GitHub says the rate limit is exhausted.
 * Treating every forbidden response as transient would retry a genuine
 * permission or configuration failure three times and then report it as a
 * temporary blip. */
function isTransientGitHubStatus(res) {
  const status = res.status;
  if (status === 429 || status >= 500) return true;
  if (status !== 403) return false;
  const remaining = res.headers?.get?.("x-ratelimit-remaining");
  return remaining === "0";
}

/** Fetches published, non-draft, non-prerelease releases. Newest is decided by
 * `published_at`, never by the API's array order (which is creation order and
 * can disagree after a re-publish). */
async function fetchPublishedReleases(env, { fetchFn = fetch, sleepFn = sleep } = {}) {
  // Checked BEFORE any request: configuration is not a blip, and must never
  // consume retries or look transient. Validated as a real owner/repo slug
  // rather than merely truthy - a value like "EnviousWispr" would otherwise
  // build a URL that 404s and read as a genuine API failure.
  const repo = env?.GITHUB_REPO;
  if (
    typeof repo !== "string" ||
    !REPO_SLUG.test(repo) ||
    !repo.split("/").every(isSafeRepoSegment)
  ) {
    throw new ReleaseResolutionError(
      `GITHUB_REPO must be "owner/repo", got: ${String(repo)}`,
      { transient: false }
    );
  }

  let lastStatus = null;
  for (let attempt = 1; attempt <= GITHUB_MAX_ATTEMPTS; attempt += 1) {
    let res;
    try {
      res = await fetchFn(`${GITHUB_API}/repos/${repo}/releases`, {
        headers: { "User-Agent": USER_AGENT, Accept: "application/vnd.github+json" },
      });
    } catch (_) {
      // A network-level rejection (DNS, reset, abort) never produces a response
      // to inspect, so it would otherwise escape unretried AND unclassified -
      // reaching the caller as an opaque error rather than the transient signal
      // the scorecard section degrades on. Deliberately does not surface the
      // original error: it can carry a URL or body.
      lastStatus = "network error";
      if (attempt < GITHUB_MAX_ATTEMPTS) {
        await sleepFn(0);
        continue;
      }
      break;
    }

    if (res.ok) {
      // Every branch below fails LOUD. Silently filtering a malformed release
      // is the whole hazard: a newest release with a missing publish date would
      // simply disappear and the SECOND-newest would be crowned, changing the
      // entire displayed set with nothing reporting a problem.
      let body;
      try {
        body = await res.json();
      } catch (_) {
        throw new ReleaseResolutionError("GitHub releases response was not valid JSON", {
          transient: false,
        });
      }
      assertDenseArray(body, "GitHub releases response");

      const parsed = [];
      const seen = new Set();
      for (const r of body) {
        if (r === null || typeof r !== "object" || Array.isArray(r)) {
          throw new ReleaseResolutionError("GitHub releases entry was not an object", {
            transient: false,
          });
        }
        if (typeof r.draft !== "boolean" || typeof r.prerelease !== "boolean") {
          throw new ReleaseResolutionError(
            `GitHub release ${String(r.tag_name)} has non-boolean draft/prerelease flags`,
            { transient: false }
          );
        }
        // Drafts and prereleases are legitimately EXCLUDED, not errors.
        if (r.draft || r.prerelease) continue;

        if (typeof r.tag_name !== "string" || typeof r.published_at !== "string") {
          throw new ReleaseResolutionError(
            `release tag_name and published_at must be strings: ${String(r.tag_name)}`,
            { transient: false }
          );
        }
        const version = normalizeReleaseVersion(r.tag_name);
        if (version === null) {
          throw new ReleaseResolutionError(`malformed release tag: ${r.tag_name}`, {
            transient: false,
          });
        }
        const publishedMs = parseGitHubTimestamp(r.published_at);
        if (publishedMs === null) {
          throw new ReleaseResolutionError(
            `missing or malformed published_at on release ${version}`,
            { transient: false }
          );
        }
        if (seen.has(version)) {
          // Two tags normalising to one version makes "newest" ambiguous.
          throw new ReleaseResolutionError(`duplicate release version: ${version}`, {
            transient: false,
          });
        }
        seen.add(version);
        parsed.push({ version, publishedAt: r.published_at });
      }
      return parsed;
    }

    lastStatus = res.status;
    if (res.body) {
      try {
        await res.body.cancel();
      } catch (_) {
        // Best effort. The status is the authoritative failure and a failed
        // cancel must not mask it; draining matters because a retry immediately
        // opens a new outbound request against Cloudflare's connection ceiling.
      }
    }

    if (!isTransientGitHubStatus(res)) {
      throw new ReleaseResolutionError(`GitHub releases request failed: HTTP ${lastStatus}`, {
        transient: false,
      });
    }
    if (attempt < GITHUB_MAX_ATTEMPTS) await sleepFn(0);
  }

  throw new ReleaseResolutionError(
    `GitHub releases unavailable after ${GITHUB_MAX_ATTEMPTS} attempts: HTTP ${lastStatus}`,
    { transient: true }
  );
}

/** Pure selection. Publication decides membership; usage decides order and
 * coverage only.
 *
 * `usageRows` are day-grain (chunk 4's real query groups by day AND version), so
 * repeated rows for one version are aggregated before any share is computed -
 * otherwise a version's share would be its BUSIEST DAY rather than its week.
 *
 * The coverage denominator is EVERY valid usage row, including versions that are
 * never displayed. Using only the selected versions would make coverage read
 * 100% by construction and say nothing. */
export function selectReleases(publishedReleases, usageRows) {
  assertDenseArray(usageRows, "usageRows");

  const totals = new Map();
  let totalDictations = 0;
  for (const row of usageRows) {
    if (row === null || typeof row !== "object" || Array.isArray(row)) {
      throw new ReleaseResolutionError("each usage row must be an object", { transient: false });
    }
    const version = normalizeReleaseVersion(row.app_version);
    if (version === null) {
      // Deliberately NOT skipped. Dropping an unparseable row would remove real
      // dictations from the coverage denominator while still reporting a high
      // coverage percentage - a silently better-looking number, which is the
      // exact failure mode this scorecard exists to stop.
      throw new ReleaseResolutionError(
        `malformed app_version in usage rows: ${String(row?.app_version)}`,
        { transient: false }
      );
    }
    const n = row.dictations;
    if (!Number.isInteger(n) || n < 0) {
      throw new ReleaseResolutionError(
        `malformed dictations count for ${version}: ${String(n)}`,
        { transient: false }
      );
    }
    totals.set(version, (totals.get(version) || 0) + n);
    totalDictations += n;
    if (!Number.isSafeInteger(totalDictations)) {
      throw new ReleaseResolutionError("dictation total exceeded safe integer range", {
        transient: false,
      });
    }
  }

  assertDenseArray(publishedReleases, "publishedReleases");

  // CANONICALIZE ONCE, then use only the canonical form. Validating the
  // normalized version while storing and comparing the RAW one let "v2.4.1" and
  // "2.4.1" through as two different releases: duplicate columns, and usage
  // recorded against "2.4.1" attaching to neither.
  const seenVersions = new Set();
  const canonical = [];
  for (const r of publishedReleases) {
    if (r === null || typeof r !== "object" || Array.isArray(r)) {
      throw new ReleaseResolutionError("each release must be an object", { transient: false });
    }
    const version = normalizeReleaseVersion(r.version);
    if (version === null) {
      throw new ReleaseResolutionError(`malformed release version: ${String(r.version)}`, {
        transient: false,
      });
    }
    const publishedMs = parseGitHubTimestamp(r.publishedAt);
    if (publishedMs === null) {
      throw new ReleaseResolutionError(`malformed publishedAt on ${version}`, {
        transient: false,
      });
    }
    if (seenVersions.has(version)) {
      throw new ReleaseResolutionError(`duplicate release version: ${version}`, {
        transient: false,
      });
    }
    seenVersions.add(version);
    // publishedMs is carried from the strict parse and used for ordering, so no
    // downstream code reparses a date. Stripped from the returned objects below
    // to keep the public shape exactly as the plan approved.
    // Below the measurement floor: not an error, and not a release with "no
    // production data yet" either. It is simply outside what the scorecard
    // measures, so it must not be crowned newest, displayed, or pooled for
    // historical variation.
    if (!isScorecardEligible(version)) continue;
    canonical.push({ ...r, version, publishedAt: r.publishedAt, publishedMs });
  }

  // Sorted HERE rather than trusting caller order: this function is pure and
  // exported, so "newest" must be derived from publication dates it can see,
  // never from the position a caller happened to put them in.
  const eligible = canonical.sort(
    (x, y) =>
      y.publishedMs - x.publishedMs || compareVersions(y.version, x.version)
  );
  if (eligible.length === 0) {
    throw new ReleaseResolutionError(
      `no eligible published releases to judge at or above ${SCORECARD_MIN_VERSION}`,
      { transient: false }
    );
  }

  // Newest FIRST and unconditionally. On release day the newest build may hold
  // ~1% share, so a purely share-ranked list would omit the one release most
  // worth watching.
  const newest = eligible[0];
  const rest = eligible
    .slice(1)
    .map((r) => ({ ...r, dictations: totals.get(r.version) || 0 }))
    // Descending share only. Equal shares keep the order they arrived in, which
    // the `eligible` sort above has ALREADY made deterministic (newest date
    // first, ties broken by newer version) and Array#sort is stable by spec.
    // A second version tie-break here was verified unreachable by negative
    // control - it could never change an outcome - so it is not carried as a
    // guard that nothing arms.
    .sort((a, b) => b.dictations - a.dictations);

  const strip = ({ publishedMs: _ms, ...rest }) => rest;
  const selected = [
    {
      ...strip(newest),
      dictations: totals.get(newest.version) || 0,
      // A release absent from telemetry entirely is NOT a measured zero. The
      // report must be able to say "no production data yet" rather than print a
      // zero that reads as a collapse.
      observed: totals.has(newest.version),
    },
  ];

  for (const candidate of rest) {
    const covered = selected.reduce((sum, r) => sum + r.dictations, 0);
    if (totalDictations > 0 && covered / totalDictations >= TARGET_COVERAGE) break;
    if (selected.length >= MAX_RELEASES) break;
    selected.push({ ...strip(candidate), observed: totals.has(candidate.version) });
  }

  const covered = selected.reduce((sum, r) => sum + r.dictations, 0);
  const coverage = totalDictations > 0 ? covered / totalDictations : 0;

  return {
    releases: selected,
    // Every eligible published release, not just the displayed ones. Historical
    // variation pools same-contract releases that are NOT on the table: a
    // two-release history is far too thin to describe what "normal movement"
    // looks like for a metric.
    releaseCatalog: eligible.map(strip),
    coverage,
    totalDictations,
    // True only when the cap stopped us SHORT of the target - the honest signal
    // that the displayed set is less representative than intended.
    capReached: selected.length >= MAX_RELEASES && coverage < TARGET_COVERAGE,
  };
}

/** Fetches eligible published releases and runs the pure selector over injected
 * usage rows. Never falls back to "select every observed telemetry version":
 * that would silently restore the version-blind behaviour this issue exists to
 * remove, and it would do so invisibly. */
export async function resolveReleases(env, usageRows, opts = {}) {
  // REQUIRED, not defaulted. GitHub returns every published release including
  // ones published AFTER the window being reported: a build shipped at 08:00
  // would be crowned newest in the 09:12 report covering yesterday, and a
  // backfill would crown a release that did not exist during the reported week
  // at all. Both print "0/7 days publicly available, no production data yet"
  // for the build supposedly most worth watching, and displace one that has
  // data. Defaulting this to "no filter" would let a forgotten caller silently
  // restore exactly that.
  const anchorMs = parseEasternDay(opts.windowEndExclusive);
  if (anchorMs === null) {
    throw new ReleaseResolutionError(
      `resolveReleases requires opts.windowEndExclusive as YYYY-MM-DD, got ${String(opts.windowEndExclusive)}`,
      { transient: false }
    );
  }
  const published = await fetchPublishedReleases(env, opts);
  // Published DURING the window is fine - it has partial data and its age line
  // says so. Published at or after the window end cannot have any.
  const withinWindow = published.filter((r) => {
    const ms = parseGitHubTimestamp(r.publishedAt);
    if (ms === null) return true; // malformed dates fail loudly in selectReleases
    return easternDayOf(ms).dayMs < anchorMs;
  });
  return selectReleases(withinWindow, usageRows);
}

/** Which producer schema each app release emitted, newest range first.
 *
 * This is a record of what WE shipped and when - a closed fact, verifiable
 * against git tags. It is deliberately not a prediction about anything outside
 * our own release history. */
export const METRIC_CONTRACTS = {
  people: [{ from: "0.0.0", id: "people-v1-distinct-successful-dictators" }],
  dictations: [{ from: "0.0.0", id: "dictations-v1-successful-completions" }],
  // p50 and p95 share one contract: same shipped producer field, same schema.
  speed_p50: [{ from: "0.0.0", id: "speed-v1-e2e-seconds" }],
  speed_p95: [{ from: "0.0.0", id: "speed-v1-e2e-seconds" }],
  autopaste_direct: [{ from: "0.0.0", id: "autopaste-v1-paste-tier" }],
  // Typed TerminalNoticeReason codes first ship in v2.4.0; older builds emit
  // user-facing prose as error_code, which is a different producer schema.
  transcription_failed: [
    { from: "2.4.0", id: "trans-v2-typed-codes" },
    { from: "0.0.0", id: "trans-v1-prose-codes" },
  ],
  // Before `fallback_reason` the metric is not measurable at all - null, never
  // a zero. The floor is DERIVED from this boundary, not the reverse: this row
  // records what we shipped, which is a closed fact checkable against git tags,
  // while the floor is the policy we chose because of it.
  polish_kept: [
    { from: POLISH_FALLBACK_REASON_FROM, id: "polish-v2-fallback-reason" },
    { from: "0.0.0", id: null },
  ],
};

/** Resolves the telemetry contract a given app release emitted for a metric.
 * Returns null when the metric is not measurable for that release. Throws for an
 * unknown metric key or a malformed version - both are programming errors that
 * must not degrade into a quietly non-comparable row. */
export function telemetryContractFor(metricKey, appVersion) {
  // Object.hasOwn, not truthiness: `METRIC_CONTRACTS.constructor` inherits a
  // truthy value from Object.prototype, so a plain lookup let "constructor",
  // "toString" and "__proto__" past the unknown-metric guard and then threw a
  // raw TypeError instead of our typed error - which a caller distinguishing
  // transient from contract failures would mishandle.
  if (typeof metricKey !== "string" || !Object.hasOwn(METRIC_CONTRACTS, metricKey)) {
    throw new ReleaseResolutionError(`unknown metric key: ${String(metricKey)}`, {
      transient: false,
    });
  }
  const ranges = METRIC_CONTRACTS[metricKey];
  if (normalizeReleaseVersion(appVersion) === null) {
    throw new ReleaseResolutionError(`malformed version: ${appVersion}`, { transient: false });
  }
  for (const range of ranges) {
    if (compareVersions(appVersion, range.from) >= 0) return range.id;
  }
  return null;
}

export const COMPARABILITY_REASONS = {
  definitionChanged: "definition changed between these releases",
  definitionUnavailable: "definition not available for one or more releases",
};

/** A metric may be compared across releases ONLY when every displayed release
 * declares the same non-null contract.
 *
 * Depends solely on declared contracts and the release versions themselves -
 * never on observed event codes, available rows, or which releases happen to be
 * displayed today. */
export function decideComparability(metricKey, versions) {
  // An array is required: `null` silently becoming an empty set would report
  // "definition unavailable" for a programming error, hiding it as a data state.
  assertDenseArray(versions, "versions");
  const ids = versions.map((v) => telemetryContractFor(metricKey, v));
  if (ids.length === 0 || ids.some((id) => id == null)) {
    return { comparable: false, reason: COMPARABILITY_REASONS.definitionUnavailable };
  }
  const unique = [...new Set(ids)];
  if (unique.length !== 1) {
    return { comparable: false, reason: COMPARABILITY_REASONS.definitionChanged };
  }
  return { comparable: true, contract: unique[0] };
}

// ===========================================================================
// #1838 chunk 4 — scorecard measurement engine
// ===========================================================================

/** TWO queries, deliberately, and the split is load-bearing.
 *
 * `uniqExact` and quantiles CANNOT be rolled up in JS from day-grain rows.
 * Summing daily distinct people double-counts anyone dictating on more than one
 * day; averaging daily medians is not a weekly median. Measured on production:
 * a naive rollup inflated people by 100-400% and distorted p95 in BOTH
 * directions, which would have manufactured a "worth a look" mover out of
 * nothing. So additive counts come at day grain (query 1, freely summable) and
 * non-additive values come at window grain (query 2, computed by PostHog at the
 * grain they are reported at).
 *
 * Templates keep their placeholders: `calculationId` hashes THIS text, so a
 * rendered date, dev-id list or production predicate must never change it. */
const ADDITIVE_SQL = `
SELECT
  toDate(toTimeZone(timestamp, 'America/New_York'))            AS day,
  properties.app_version                                       AS app_version,
  count() OVER ()                                              AS total_group_rows,
  countIf(event = 'dictation.completed'
          AND properties.result = 'success')                   AS dictations,
  countIf(event = 'paste.completed')                           AS paste_attempts,
  countIf(event = 'paste.completed'
          AND properties.tier LIKE 'clipboard_only%')          AS paste_fallbacks,
  countIf(event = 'llm.polish_completed'
          AND properties.provider = 'appleIntelligence')       AS afm_attempts,
  countIf(event = 'llm.polish_completed' AND properties.provider = 'appleIntelligence'
          AND properties.fallback_reason
              IN ('guard_discard','validator_discard'))        AS afm_discards,
  countIf(event = 'llm.polish_completed' AND properties.provider = 'appleIntelligence'
          AND properties.filter_tripped = 'classifier_discard') AS afm_classifier_discards,
  countIf(event = 'pipeline.failed'
          AND properties.stage = 'transcription')              AS terminal_failures
FROM events
WHERE \${prod}
  AND event IN ('dictation.completed','paste.completed',
                'llm.polish_completed','pipeline.failed')
  AND toTimeZone(timestamp,'America/New_York') >= \${historyStart}
  AND toTimeZone(timestamp,'America/New_York') <  \${windowEndExclusive}
GROUP BY day, app_version
ORDER BY day DESC, dictations DESC
LIMIT 5000`;

const NON_ADDITIVE_SQL = `
SELECT
  intDiv(dateDiff('day', toDate(toTimeZone(timestamp,'America/New_York')),
                  toDate(\${windowEndExclusive})) - 1, 7)      AS window_index,
  properties.app_version                                       AS app_version,
  count() OVER ()                                              AS total_group_rows,
  uniqExact(distinct_id)                                       AS people,
  count()                                                      AS dictations,
  countIf(isNotNull(toFloat(properties.e2e_seconds)))          AS speed_samples,
  quantileIf(0.50)(toFloat(properties.e2e_seconds),
      isNotNull(toFloat(properties.e2e_seconds)))              AS speed_p50,
  quantileIf(0.95)(toFloat(properties.e2e_seconds),
      isNotNull(toFloat(properties.e2e_seconds)))              AS speed_p95
FROM events
WHERE \${prod} AND event = 'dictation.completed' AND properties.result = 'success'
  AND toTimeZone(timestamp,'America/New_York') >= \${historyStart}
  AND toTimeZone(timestamp,'America/New_York') <  \${windowEndExclusive}
GROUP BY window_index, app_version
HAVING dictations > 0
ORDER BY window_index ASC, dictations DESC
LIMIT 5000`;

export const WINDOW_DAYS = 7;
export const WINDOW_COUNT = 8;

/** Renders a template. The anchor is the RESOLVED report window end, never the
 * clock: anchoring to `now()` made a backfilled run's window 0 span thirteen
 * days straddling the target date, including events from after it, because days
 * past the anchor produce a negative dateDiff that intDiv folds into window 0. */
export function scorecardSql(kind, { prod, historyStart, windowEndExclusive }) {
  const template = kind === "additive" ? ADDITIVE_SQL : kind === "nonAdditive" ? NON_ADDITIVE_SQL : null;
  if (template === null) {
    throw new ReleaseResolutionError(`unknown scorecard query kind: ${String(kind)}`, {
      transient: false,
    });
  }
  for (const [name, value] of [["prod", prod], ["historyStart", historyStart],
                               ["windowEndExclusive", windowEndExclusive]]) {
    if (typeof value !== "string" || value.length === 0) {
      throw new ReleaseResolutionError(`scorecardSql requires a string ${name}`, {
        transient: false,
      });
    }
  }
  // Function replacements, not strings: String#replaceAll interprets `$&`,
  // "$`" and `$'` inside a STRING replacement, so a production predicate
  // containing `$&` would render `${prod}` back into the SQL instead of the
  // predicate - a silently wrong query against a silently wrong population.
  return template
    .replaceAll("${prod}", () => prod)
    .replaceAll("${historyStart}", () => historyStart)
    .replaceAll("${windowEndExclusive}", () => windowEndExclusive);
}

export function scorecardSqlTemplate(kind) {
  if (kind === "additive") return ADDITIVE_SQL;
  if (kind === "nonAdditive") return NON_ADDITIVE_SQL;
  throw new ReleaseResolutionError(`unknown scorecard query kind: ${String(kind)}`, {
    transient: false,
  });
}

/** Rejects a truncated or inconsistent PostHog result INDEPENDENTLY per query.
 *
 * PostHog silently caps a result at 100 rows; this repo has been bitten by that
 * before, and during this issue's own planning a "56 days, every version"
 * measurement was reported as complete when it held 100 of 227 rows. A truncated
 * result renders as a perfectly healthy report with missing history, so it must
 * never be absorbed. `count() OVER ()` gives the true group count for free. */
export function assertCompleteScorecardRows(rows, label) {
  assertDenseArray(rows, `${label} rows`);
  if (rows.length === 0) {
    throw new ReleaseResolutionError(`${label} returned no rows`, { transient: false });
  }
  let expected = null;
  for (const row of rows) {
    if (row === null || typeof row !== "object" || Array.isArray(row)) {
      throw new ReleaseResolutionError(`${label} row is not an object`, { transient: false });
    }
    const total = ownField(row, "total_group_rows", `${label} row`);
    if (!Number.isSafeInteger(total) || total <= 0) {
      throw new ReleaseResolutionError(
        `${label} total_group_rows must be a positive safe integer, got ${String(total)}`,
        { transient: false }
      );
    }
    if (expected === null) expected = total;
    if (total !== expected) {
      throw new ReleaseResolutionError(
        `${label} rows disagree on total_group_rows (${expected} vs ${total})`,
        { transient: false }
      );
    }
  }
  if (rows.length !== expected) {
    throw new ReleaseResolutionError(
      `${label} truncated: received ${rows.length} of ${expected} rows`,
      { transient: false }
    );
  }
}

/** Reads an OWN property. A plain `row[field]` walks the prototype, so a row
 * whose prototype supplies every column reads as complete while owning nothing -
 * and those inherited values then flow into real measurements. */
function ownField(row, field, label) {
  if (!Object.hasOwn(row, field)) {
    throw new ReleaseResolutionError(`${label}: missing own property ${field}`, {
      transient: false,
    });
  }
  return row[field];
}

function requireCount(row, field, label) {
  const v = ownField(row, field, label);
  if (!Number.isSafeInteger(v) || v < 0) {
    throw new ReleaseResolutionError(
      `${label}: ${field} must be a non-negative safe integer, got ${String(v)}`,
      { transient: false }
    );
  }
  return v;
}

function requireOptionalSeconds(row, field, label, hasSamples) {
  const v = ownField(row, field, label);
  if (!hasSamples) return null; // no samples => missing, never a fabricated zero
  if (typeof v !== "number" || !Number.isFinite(v) || v < 0) {
    throw new ReleaseResolutionError(
      `${label}: ${field} must be a finite non-negative number when samples exist, got ${String(v)}`,
      { transient: false }
    );
  }
  return v;
}

const ADDITIVE_COUNTS = [
  "dictations", "paste_attempts", "paste_fallbacks",
  "afm_attempts", "afm_discards", "afm_classifier_discards", "terminal_failures",
];

/** Validates the additive result and buckets each day into its 7-day window.
 * The window index is derived from the RESOLVED anchor, so a backfilled run
 * measures the same shape as a live one. */
function parseAdditiveRows(rows, windowEndExclusiveMs) {
  assertCompleteScorecardRows(rows, "additive");
  const byWindow = new Map();
  const seenKeys = new Set();

  for (const row of rows) {
    const version = normalizeReleaseVersion(ownField(row, "app_version", "additive row"));
    if (version === null) {
      throw new ReleaseResolutionError(`additive: malformed app_version ${String(row.app_version)}`, {
        transient: false,
      });
    }
    if (!isScorecardEligible(version)) continue;
    const dayMs = parseEasternDay(ownField(row, "day", "additive row"));
    if (dayMs === null) {
      throw new ReleaseResolutionError(`additive: malformed day ${String(row.day)}`, {
        transient: false,
      });
    }
    const key = `${row.day}|${version}`;
    if (seenKeys.has(key)) {
      throw new ReleaseResolutionError(`additive: duplicate day/version key ${key}`, {
        transient: false,
      });
    }
    seenKeys.add(key);

    const counts = {};
    for (const f of ADDITIVE_COUNTS) counts[f] = requireCount(row, f, `additive ${key}`);
    if (counts.paste_fallbacks > counts.paste_attempts) {
      throw new ReleaseResolutionError(`additive ${key}: paste_fallbacks exceeds paste_attempts`, {
        transient: false,
      });
    }
    if (counts.afm_discards > counts.afm_attempts) {
      throw new ReleaseResolutionError(`additive ${key}: afm_discards exceeds afm_attempts`, {
        transient: false,
      });
    }
    if (counts.afm_classifier_discards > counts.afm_discards) {
      throw new ReleaseResolutionError(
        `additive ${key}: afm_classifier_discards exceeds afm_discards`, { transient: false }
      );
    }

    const daysBack = Math.round((windowEndExclusiveMs - dayMs) / 86_400_000) - 1;
    if (daysBack < 0) {
      throw new ReleaseResolutionError(
        `additive: day ${row.day} falls at or after the window anchor`, { transient: false }
      );
    }
    const windowIndex = Math.floor(daysBack / WINDOW_DAYS);
    if (windowIndex >= WINDOW_COUNT) {
      throw new ReleaseResolutionError(
        `additive: day ${row.day} predates the ${WINDOW_COUNT}-window history`, { transient: false }
      );
    }

    const bucket = byWindow.get(windowIndex) || new Map();
    const acc = bucket.get(version) || Object.fromEntries(ADDITIVE_COUNTS.map((f) => [f, 0]));
    for (const f of ADDITIVE_COUNTS) {
      acc[f] += counts[f];
      if (!Number.isSafeInteger(acc[f])) {
        throw new ReleaseResolutionError(`additive: ${f} exceeded safe integer range`, {
          transient: false,
        });
      }
    }
    bucket.set(version, acc);
    byWindow.set(windowIndex, bucket);
  }
  return byWindow;
}

const EASTERN_DAY = /^(\d{4})-(\d{2})-(\d{2})$/;

/** Strict Eastern calendar-day parser, matching parseGitHubTimestamp's rigour:
 * a permissive `new Date` would accept "2026-02-30" and roll it to March 2nd,
 * which would silently move a day into the wrong window. */
function parseEasternDay(value) {
  if (typeof value !== "string") return null;
  const m = EASTERN_DAY.exec(value);
  if (!m) return null;
  const [, y, mo, d] = m.map(Number);
  const ms = Date.UTC(y, mo - 1, d);
  if (!Number.isFinite(ms)) return null;
  const back = new Date(ms);
  if (back.getUTCFullYear() !== y || back.getUTCMonth() !== mo - 1 || back.getUTCDate() !== d) {
    return null;
  }
  return ms;
}

/** Validates the non-additive result. These values are computed by PostHog at
 * window grain precisely because they cannot be derived from daily rows. */
function parseNonAdditiveRows(rows) {
  assertCompleteScorecardRows(rows, "non-additive");
  const byWindow = new Map();
  const seenKeys = new Set();

  for (const row of rows) {
    const version = normalizeReleaseVersion(ownField(row, "app_version", "non-additive row"));
    if (version === null) {
      throw new ReleaseResolutionError(
        `non-additive: malformed app_version ${String(row.app_version)}`, { transient: false }
      );
    }
    if (!isScorecardEligible(version)) continue;
    const windowIndex = ownField(row, "window_index", "non-additive row");
    if (!Number.isSafeInteger(windowIndex) || windowIndex < 0 || windowIndex >= WINDOW_COUNT) {
      throw new ReleaseResolutionError(
        `non-additive: window_index ${String(windowIndex)} outside 0..${WINDOW_COUNT - 1}`,
        { transient: false }
      );
    }
    const key = `${windowIndex}|${version}`;
    if (seenKeys.has(key)) {
      throw new ReleaseResolutionError(`non-additive: duplicate window/version key ${key}`, {
        transient: false,
      });
    }
    seenKeys.add(key);

    const dictations = requireCount(row, "dictations", `non-additive ${key}`);
    const people = requireCount(row, "people", `non-additive ${key}`);
    const speedSamples = requireCount(row, "speed_samples", `non-additive ${key}`);
    if (people > dictations) {
      throw new ReleaseResolutionError(`non-additive ${key}: people exceeds dictations`, {
        transient: false,
      });
    }
    if (speedSamples > dictations) {
      throw new ReleaseResolutionError(`non-additive ${key}: speed_samples exceeds dictations`, {
        transient: false,
      });
    }
    const hasSamples = speedSamples > 0;
    const p50 = requireOptionalSeconds(row, "speed_p50", `non-additive ${key}`, hasSamples);
    const p95 = requireOptionalSeconds(row, "speed_p95", `non-additive ${key}`, hasSamples);
    if (hasSamples && p95 < p50) {
      throw new ReleaseResolutionError(`non-additive ${key}: p95 below p50`, { transient: false });
    }

    const bucket = byWindow.get(windowIndex) || new Map();
    bucket.set(version, { people, dictations, speedSamples, speedP50: p50, speedP95: p95 });
    byWindow.set(windowIndex, bucket);
  }
  return byWindow;
}

/** Missing data is explicit and never a fabricated number: a zero denominator
 * reads as "not enough data", never as 0%, NaN or Infinity. */
/** Every aggregate crosses this, not just per-version accumulation: an unsafe
 * total silently loses precision and then divides into shares and rates. */
function safeAdd(a, b, label) {
  const sum = a + b;
  if (!Number.isSafeInteger(sum)) {
    throw new ReleaseResolutionError(`${label} exceeded safe integer range`, { transient: false });
  }
  return sum;
}

const missing = (reason) => ({ value: null, missing: reason });
const measured = (value, extra = {}) => ({ value, missing: null, ...extra });

function rate(numerator, denominator, reason) {
  if (denominator === 0) return missing(reason);
  return measured(numerator / denominator, { numerator, denominator });
}

/** Declares HOW the worker computes each row. A separate axis from
 * METRIC_CONTRACTS, which declares what an APP RELEASE emitted - conflating the
 * two would let a worker refactor rewrite release history. */
export const METRIC_CALCULATIONS = {
  people: {
    source: "nonAdditive", population: "successful dictation.completed",
    numerator: "uniqExact(distinct_id)", denominator: "none",
    aggregation: "distinct-count at 7-day window grain", unit: "people",
    direction: null, moverEligible: false,
  },
  dictations: {
    source: "additive", population: "successful dictation.completed",
    numerator: "count()", denominator: "window total across all versions",
    aggregation: "sum of day-grain counts", unit: "dictations",
    direction: null, moverEligible: false,
  },
  speed_p50: {
    source: "nonAdditive", population: "successful dictation.completed with e2e_seconds",
    numerator: "quantile(0.50)(e2e_seconds)", denominator: "none",
    aggregation: "percentile at 7-day window grain", unit: "seconds",
    direction: "lower-is-better", moverEligible: true,
  },
  speed_p95: {
    source: "nonAdditive", population: "successful dictation.completed with e2e_seconds",
    numerator: "quantile(0.95)(e2e_seconds)", denominator: "none",
    aggregation: "percentile at 7-day window grain", unit: "seconds",
    direction: "lower-is-better", moverEligible: true,
  },
  autopaste_direct: {
    source: "additive", population: "paste.completed",
    numerator: "paste_attempts - paste_fallbacks", denominator: "paste_attempts",
    aggregation: "sum of day-grain counts", unit: "share",
    direction: "higher-is-better", moverEligible: true,
  },
  polish_kept: {
    source: "additive", population: "llm.polish_completed provider=appleIntelligence",
    numerator: "afm_attempts - afm_discards", denominator: "afm_attempts",
    aggregation: "sum of day-grain counts", unit: "share",
    direction: "higher-is-better", moverEligible: true,
  },
  transcription_failed: {
    source: "additive", population: "pipeline.failed stage=transcription plus successful dictations",
    numerator: "terminal_failures", denominator: "dictations + terminal_failures",
    aggregation: "sum of day-grain counts", unit: "share",
    direction: "lower-is-better", moverEligible: true,
  },
};

const CALC_FIELDS = ["population", "numerator", "denominator", "aggregation", "unit"];

/** Strips comments, collapses whitespace, trims. A formatting-only SQL change
 * must not churn a calculation ID; a semantic one must. */
function normalizeSqlForHash(sql) {
  return sql
    .replace(/--[^\n]*/g, " ")
    .replace(/\/\*[\s\S]*?\*\//g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/** The WORKER's calculation identity, deliberately separate from an app
 * release's telemetry contract. Hashes the canonical TEMPLATE, so a rendered
 * date, dev-id list or production predicate can never change it. */
export async function calculationId(metricKey) {
  if (typeof metricKey !== "string" || !Object.hasOwn(METRIC_CALCULATIONS, metricKey)) {
    throw new ReleaseResolutionError(`unknown metric key: ${String(metricKey)}`, {
      transient: false,
    });
  }
  const calc = METRIC_CALCULATIONS[metricKey];
  const payload = [
    normalizeSqlForHash(scorecardSqlTemplate(calc.source)),
    ...CALC_FIELDS.map((f) => `${f}=${calc[f]}`),
  ].join(" ");
  const bytes = new TextEncoder().encode(payload);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  const hex = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `sha256:${hex}`;
}

/** Pure measurement engine. Validates both responses independently, proves they
 * agree, buckets additive counts into the eight windows, and computes every row.
 * Takes the RESOLVED window anchor; never reads a clock. */
export function buildMeasurements({ additiveRows, nonAdditiveRows, windowEndExclusive }) {
  const anchorMs = parseEasternDay(windowEndExclusive);
  if (anchorMs === null) {
    throw new ReleaseResolutionError(
      `windowEndExclusive must be YYYY-MM-DD, got ${String(windowEndExclusive)}`,
      { transient: false }
    );
  }
  const additive = parseAdditiveRows(additiveRows, anchorMs);
  const nonAdditive = parseNonAdditiveRows(nonAdditiveRows);

  // Cross-query agreement over EVERY returned window, in BOTH directions. The
  // two queries count the same successful dictations, so a disagreement means
  // one measured a different population and no row built on them is trustworthy.
  // One-way checking accepted an additive window with real dictations and NO
  // window-grain row, then rendered it with missing people and speed - a version
  // silently reported as unmeasured while it was in fact being used.
  for (const [windowIndex, versions] of nonAdditive) {
    for (const [version, na] of versions) {
      if (na.dictations === 0) {
        // Query 2 carries `HAVING dictations > 0`; a zero row means the response
        // did not come from the approved query.
        throw new ReleaseResolutionError(
          `non-additive window ${windowIndex} ${version}: dictations must exceed 0`,
          { transient: false }
        );
      }
      const add = additive.get(windowIndex)?.get(version);
      const addDictations = add ? add.dictations : 0;
      if (addDictations !== na.dictations) {
        throw new ReleaseResolutionError(
          `queries disagree for window ${windowIndex} ${version}: ` +
            `additive ${addDictations} vs non-additive ${na.dictations}`,
          { transient: false }
        );
      }
    }
  }
  for (const [windowIndex, versions] of additive) {
    for (const [version, a] of versions) {
      if (a.dictations > 0 && !nonAdditive.get(windowIndex)?.has(version)) {
        throw new ReleaseResolutionError(
          `window ${windowIndex} ${version} has ${a.dictations} additive dictations ` +
            `but no non-additive row`,
          { transient: false }
        );
      }
    }
  }

  const windows = new Map();
  for (let w = 0; w < WINDOW_COUNT; w += 1) {
    const addBucket = additive.get(w) || new Map();
    const naBucket = nonAdditive.get(w) || new Map();
    const versions = new Map();
    const windowTotalDictations = [...addBucket.values()].reduce(
      (sum, a) => safeAdd(sum, a.dictations, `window ${w} total dictations`), 0);

    for (const version of new Set([...addBucket.keys(), ...naBucket.keys()])) {
      const a = addBucket.get(version) || Object.fromEntries(ADDITIVE_COUNTS.map((f) => [f, 0]));
      const n = naBucket.get(version) || null;
      versions.set(version, {
        people: n ? measured(n.people) : missing("no window-grain data"),
        dictations: measured(a.dictations, {
          shareOfWindow: windowTotalDictations > 0 ? a.dictations / windowTotalDictations : null,
        }),
        speed_p50: n && n.speedSamples > 0
          ? measured(n.speedP50, { samples: n.speedSamples })
          : missing("no timed dictations"),
        speed_p95: n && n.speedSamples > 0
          ? measured(n.speedP95, { samples: n.speedSamples })
          : missing("no timed dictations"),
        autopaste_direct: rate(a.paste_attempts - a.paste_fallbacks, a.paste_attempts,
          "no auto-paste attempts"),
        polish_kept: {
          ...rate(a.afm_attempts - a.afm_discards, a.afm_attempts, "no Apple polish attempts"),
          classifierDiscards: a.afm_classifier_discards,
          otherDiscards: a.afm_discards - a.afm_classifier_discards,
        },
        transcription_failed: rate(
          a.terminal_failures,
          safeAdd(a.dictations, a.terminal_failures, `${version} transcription denominator`),
          "no dictation attempts"),
      });
    }
    windows.set(w, { windowIndex: w, versions, totalDictations: windowTotalDictations });
  }

  // Current-window rows shaped for chunk 3's selectReleases. Selection itself
  // stays there; this chunk never duplicates that algorithm.
  const usageRows = [...(windows.get(0)?.versions ?? new Map())].map(([version, m]) => ({
    app_version: version,
    dictations: m.dictations.value,
  }));

  return { windows, usageRows, windowEndExclusive };
}


// ===========================================================================
// #1838 chunk 5 — movers
// ===========================================================================

const DAY_MS = 86_400_000;

// hourCycle "h23", NOT hour12: false. They are not synonyms: `hour12: false`
// leaves the locale free to pick h23 or h24, and under h24 exact midnight
// formats as "24:00:00" - so the midnight test below would never fire and a
// release published exactly at Eastern midnight would silently lose a complete
// window of history. It does not reproduce on this Node build, but the worker
// runs on a different engine, and `easternOffsetMinutesAt` in index.js already
// states h23 explicitly for the same job.
const EASTERN_PARTS = new Intl.DateTimeFormat("en-CA", {
  timeZone: "America/New_York",
  year: "numeric", month: "2-digit", day: "2-digit",
  hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
});

/** An instant's EASTERN calendar day, as a UTC-midnight ms value, plus whether
 * it fell exactly at Eastern midnight.
 *
 * Flooring the raw timestamp to a UTC day was wrong: a release published at
 * 22:00 Eastern is 02:00 UTC the NEXT day, so it reported zero available days
 * instead of one, and could be treated as public for a whole window it was
 * published inside. Both change the displayed set and the mover ranking. */
function easternDayOf(ms) {
  const parts = Object.fromEntries(
    EASTERN_PARTS.formatToParts(new Date(ms)).map((p) => [p.type, p.value])
  );
  const dayMs = Date.UTC(Number(parts.year), Number(parts.month) - 1, Number(parts.day));
  const atMidnight = parts.hour === "00" && parts.minute === "00" && parts.second === "00";
  return { dayMs, atMidnight };
}

/** Eastern day boundaries of a window, as inclusive [firstDay, lastDay] ms. */
function windowBounds(anchorMs, windowIndex) {
  const lastDay = anchorMs - (windowIndex * WINDOW_DAYS + 1) * DAY_MS;
  const firstDay = anchorMs - ((windowIndex + 1) * WINDOW_DAYS) * DAY_MS;
  return { firstDay, lastDay };
}

/** Eastern calendar days inside window 0 on which the release was public for any
 * part of the day, publication day counting as one, clamped to 0..7. Counted in
 * DAYS, not elapsed 24-hour periods: an evening publication still makes that
 * calendar day one available day. */
export function releaseAgeInWindow(publishedAtMs, anchorMs) {
  if (!Number.isFinite(publishedAtMs)) {
    // Never defaulted: a malformed timestamp silently becoming 0 rendered as a
    // confident "7/7 days publicly available" for a release we know nothing about.
    throw new ReleaseResolutionError("release publication timestamp is not a finite instant", {
      transient: false,
    });
  }
  const { firstDay, lastDay } = windowBounds(anchorMs, 0);
  const { dayMs: pubDay } = easternDayOf(publishedAtMs);
  if (pubDay > lastDay) return 0;
  const start = Math.max(pubDay, firstDay);
  return Math.min(WINDOW_DAYS, Math.max(0, Math.round((lastDay - start) / DAY_MS) + 1));
}

/** A release contributes a HISTORICAL observation only when it was public for
 * the ENTIRE window. Being published partway through the first day counts toward
 * displayed release age but does not make that window a complete observation -
 * a partial week's ramp is not a movement. */
function publicForWholeWindow(publishedAtMs, anchorMs, windowIndex) {
  const { firstDay } = windowBounds(anchorMs, windowIndex);
  const { dayMs, atMidnight } = easternDayOf(publishedAtMs);
  if (dayMs < firstDay) return true;
  // Published ON the window's first Eastern day counts only at exactly Eastern
  // midnight; any later time means the release missed part of that week.
  return dayMs === firstDay && atMidnight;
}

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = sorted.length >> 1;
  return sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

function metricValue(entry) {
  if (entry === undefined) return null;
  if (entry === null || typeof entry !== "object" || Array.isArray(entry)) {
    throw new ReleaseResolutionError("measurement entry must be an object", { transient: false });
  }
  if (!Object.hasOwn(entry, "value")) {
    throw new ReleaseResolutionError("measurement entry missing own property value", {
      transient: false,
    });
  }
  const v = entry.value;
  if (v === null) return null;
  if (typeof v !== "number" || !Number.isFinite(v)) {
    throw new ReleaseResolutionError(`measurement value must be finite, got ${String(v)}`, {
      transient: false,
    });
  }
  return v;
}

/** Sample disclosure: percentiles disclose their sample count, rates disclose
 * their denominator. Refused rather than defaulted - a missing count silently
 * treated as zero would present a one-sample percentile as a real movement. */
function sampleCount(entry, metricKey) {
  const calc = METRIC_CALCULATIONS[metricKey];
  const field = calc.unit === "seconds" ? "samples" : "denominator";
  if (!Object.hasOwn(entry, field)) {
    // A measured value whose disclosure is absent must not silently drop out of
    // ranking - that hides a broken measurement as an ordinary quiet week.
    throw new ReleaseResolutionError(
      `${metricKey}: measured value is missing its required ${field}`,
      { transient: false }
    );
  }
  const n = entry[field];
  if (!Number.isSafeInteger(n) || n < 0) {
    throw new ReleaseResolutionError(
      `${metricKey}: ${field} must be a non-negative safe integer, got ${String(n)}`,
      { transient: false }
    );
  }
  return n;
}

/** Sole owner of mover composition. Consumes comparability, direction and
 * eligibility from their existing authorities and never re-derives them. */
export function rankMovers({ measurements, selection }) {
  if (measurements === null || typeof measurements !== "object" || !(measurements.windows instanceof Map)) {
    throw new ReleaseResolutionError("measurements must carry a windows Map", { transient: false });
  }
  if (selection === null || typeof selection !== "object") {
    throw new ReleaseResolutionError("selection must be an object", { transient: false });
  }
  assertDenseArray(selection.releases, "selection.releases");
  assertDenseArray(selection.releaseCatalog, "selection.releaseCatalog");

  const anchorMs = parseEasternDay(measurements.windowEndExclusive);
  if (anchorMs === null) {
    throw new ReleaseResolutionError("measurements.windowEndExclusive must be YYYY-MM-DD", {
      transient: false,
    });
  }

  // Every window must exist with the expected shape; optional chaining would
  // turn a missing window into empty history and quietly change the ranking.
  for (let w = 0; w < WINDOW_COUNT; w += 1) {
    const win = measurements.windows.get(w);
    if (!win || !(win.versions instanceof Map)) {
      throw new ReleaseResolutionError(`measurements is missing window ${w}`, { transient: false });
    }
  }
  // Returns the CANONICAL version alongside the timestamp, and every caller uses
  // that form. Validating the normalized version while continuing to use the raw
  // one is the same defect that made a live release read as "no production data
  // yet" in chunk 3; duplicates on top of it multiply observations and can
  // manufacture enough history to normalise a ranking that should fall back.
  const requireRelease = (r, label) => {
    if (r === null || typeof r !== "object" || Array.isArray(r)) {
      throw new ReleaseResolutionError(`${label} entry must be an object`, { transient: false });
    }
    for (const field of ["version", "publishedAt"]) {
      if (!Object.hasOwn(r, field)) {
        throw new ReleaseResolutionError(`${label} entry missing own property ${field}`, {
          transient: false,
        });
      }
    }
    if (normalizeReleaseVersion(r.version) === null) {
      throw new ReleaseResolutionError(`${label} entry has a malformed version`, {
        transient: false,
      });
    }
    const ms = parseGitHubTimestamp(r.publishedAt);
    if (ms === null) {
      throw new ReleaseResolutionError(`${label} entry has a malformed publishedAt`, {
        transient: false,
      });
    }
    return { version: normalizeReleaseVersion(r.version), publishedAtMs: ms };
  };

  const requireUnique = (entries, label) => {
    const seen = new Set();
    return entries.map((r) => {
      const canonical = requireRelease(r, label);
      if (seen.has(canonical.version)) {
        throw new ReleaseResolutionError(
          `${label} contains duplicate release ${canonical.version}`,
          { transient: false }
        );
      }
      seen.add(canonical.version);
      return canonical;
    });
  };

  const displayedCanonical = requireUnique(selection.releases, "selection.releases");
  const catalogCanonical = requireUnique(selection.releaseCatalog, "selection.releaseCatalog");
  if (displayedCanonical.length === 0) {
    throw new ReleaseResolutionError("selection.releases must not be empty", { transient: false });
  }
  // A displayed release absent from the catalog silently changes real ranking
  // numbers: with an empty catalog a metric fell back to raw movement with a
  // score of 6, and with the release present it normalised to 12.
  const catalogByVersion = new Map(catalogCanonical.map((c) => [c.version, c]));
  for (const d of displayedCanonical) {
    const inCatalog = catalogByVersion.get(d.version);
    if (!inCatalog) {
      throw new ReleaseResolutionError(
        `displayed release ${d.version} is missing from the release catalog`,
        { transient: false }
      );
    }
    if (inCatalog.publishedAtMs !== d.publishedAtMs) {
      throw new ReleaseResolutionError(
        `displayed release ${d.version} has a different publication time in the catalog`,
        { transient: false }
      );
    }
  }
  const displayed = selection.releases.map((r, i) => ({
    ...r, version: displayedCanonical[i].version,
  }));
  const ages = new Map(
    displayedCanonical.map((c) => [c.version, releaseAgeInWindow(c.publishedAtMs, anchorMs)])
  );
  const displayedVersions = displayed.map((r) => r.version);
  const current = measurements.windows.get(0).versions;

  // Row decisions are built for EVERY case, including a single displayed
  // release: one column and no movers is a legitimate production state, and
  // returning early without rows crashed the formatter outright.
  const buildRows = () =>
    Object.entries(METRIC_CALCULATIONS).map(([metricKey, calc]) => {
      const verdict = decideComparability(metricKey, displayedVersions);
      return {
        metricKey,
        unit: calc.unit,
        comparable: verdict.comparable,
        reason: verdict.comparable ? null : verdict.reason,
        cells: displayedVersions.map((v) => {
          const entry = current.get(v)?.[metricKey];
          return {
            version: v,
            value: entry === undefined ? null : metricValue(entry),
            shareOfWindow: metricKey === "dictations" ? (entry?.shareOfWindow ?? null) : null,
            classifierDiscards:
              metricKey === "polish_kept" ? (entry?.classifierDiscards ?? null) : null,
            otherDiscards: metricKey === "polish_kept" ? (entry?.otherDiscards ?? null) : null,
          };
        }),
      };
    });

  // The ranker owns the ENTIRE displayed summary. The formatter is given only
  // this, so no raw selection field can reach the page - the previous fix
  // carried versions across but left coverage and cap status behind, and
  // changing those alone still printed a different report.
  const summary = {
    releases: displayed,
    coverage: selection.coverage,
    capReached: selection.capReached === true,
    // The floor travels WITH the displayed set, from its one definition. The
    // formatter needing it and the ranker not supplying it rendered "Builds
    // before undefined are not measured" with every test green.
    minVersion: SCORECARD_MIN_VERSION,
  };
  if (typeof summary.coverage !== "number" || !Number.isFinite(summary.coverage) ||
      summary.coverage < 0 || summary.coverage > 1) {
    throw new ReleaseResolutionError(
      `selection.coverage must be a share between 0 and 1, got ${String(selection.coverage)}`,
      { transient: false }
    );
  }

  if (displayed.length < 2) {
    // Fewer than two displayed releases: render the grid, invent no comparison.
    return { movers: [], ages, rows: buildRows(), summary, comparisonPair: null };
  }

  const [newest, previous] = displayed;
  const candidates = [];

  for (const [metricKey, calc] of Object.entries(METRIC_CALCULATIONS)) {
    if (calc.moverEligible !== true || calc.direction === null) continue;
    // Comparability of the ENTIRE displayed set, from its own authority. A third
    // release on a different contract makes the row non-comparable even though
    // the compared pair agree.
    const verdict = decideComparability(metricKey, displayedVersions);
    if (!verdict.comparable) continue;

    const newEntry = current.get(newest.version)?.[metricKey];
    const prevEntry = current.get(previous.version)?.[metricKey];
    const newValue = metricValue(newEntry);
    const prevValue = metricValue(prevEntry);
    if (newValue === null || prevValue === null) continue;
    const newSamples = sampleCount(newEntry, metricKey);
    const prevSamples = sampleCount(prevEntry, metricKey);
    if (newSamples === null || prevSamples === null) continue;

    // History pools EVERY catalog release on the same contract, across all eight
    // windows - never just the displayed pair.
    const diffs = [];
    let observations = 0;
    for (const release of catalogCanonical) {
      if (telemetryContractFor(metricKey, release.version) !== verdict.contract) continue;
      const pubMs = release.publishedAtMs;
      const series = [];
      for (let w = 0; w < WINDOW_COUNT; w += 1) {
        const entry = measurements.windows.get(w).versions.get(release.version)?.[metricKey];
        const value = metricValue(entry);
        series.push(value !== null && publicForWholeWindow(pubMs, anchorMs, w) ? value : null);
      }
      observations += series.filter((v) => v !== null).length;
      for (let w = 0; w + 1 < WINDOW_COUNT; w += 1) {
        // Adjacent, same version, both present, both fully available. Never
        // bridges a gap, a version, or a contract boundary.
        if (series[w] !== null && series[w + 1] !== null) {
          diffs.push(Math.abs(series[w] - series[w + 1]));
        }
      }
    }

    const rawMovement = Math.abs(newValue - prevValue);
    const enoughHistory = observations >= 4 && diffs.length >= 3;
    const variation = enoughHistory ? median(diffs) : null;
    // No epsilon: a zero median falls back rather than dividing by an invented
    // small constant.
    const normalized = enoughHistory && variation > 0;
    candidates.push({
      metricKey,
      newestVersion: newest.version, previousVersion: previous.version,
      newestValue: newValue, previousValue: prevValue,
      newestSamples: newSamples, previousSamples: prevSamples,
      rawMovement, signedDifference: newValue - prevValue,
      direction: calc.direction, unit: calc.unit,
      historicalVariation: normalized ? variation : null,
      score: normalized ? rawMovement / variation : rawMovement,
      basis: normalized ? "median-historical-movement" : "raw-absolute-movement",
      fallbackReason: normalized
        ? null
        : observations < 4
          ? `only ${observations} complete same-definition windows, needs 4`
          : diffs.length < 3
            ? `only ${diffs.length} adjacent comparable weeks, needs 3`
            : "this measure has not moved between weeks before",
    });
  }

  const order = Object.keys(METRIC_CALCULATIONS);
  const normalizedFirst = candidates.filter((c) => c.historicalVariation !== null);
  const rawOnly = candidates.filter((c) => c.historicalVariation === null);
  const byScore = (a, b) =>
    b.score - a.score || order.indexOf(a.metricKey) - order.indexOf(b.metricKey);
  // Normalized candidates always precede raw-fallback ones. The two scores are
  // in DIFFERENT UNITS - "3x this measure's usual weekly movement" against "5
  // percentage points" - so sorting them into one list would be meaningless
  // arithmetic. The founder approved ranking against a measure's own normal
  // movement, so a measure that HAS that history is the better-founded signal;
  // a measure without it still appears, ranked among its peers and explicitly
  // labelled with the basis used. Founder may overrule.
  const movers = [...normalizedFirst.sort(byScore), ...rawOnly.sort(byScore)].slice(0, 2);

  return { movers, ages, rows: buildRows(), summary,
           comparisonPair: [newest.version, previous.version] };
}

// ===========================================================================
// #1838 chunk 6 — section driver
// ===========================================================================

/**
 * The scorecard could not be produced.
 *
 * `wholeRun` is TRUE only for a release-resolution CONTRACT failure:
 * misconfiguration, auth, a malformed response, a duplicate release, or no
 * eligible stable release. In that state we do not know which releases the
 * report is even about, so there is no honest combined report to send.
 *
 * It is FALSE for everything the section can survive as a missing section: a
 * query failure, a truncated response, a measurement or ranking fault, or an
 * exhausted TRANSIENT GitHub failure. Collapsing the two directions would
 * either lose the adoption half to a blip, or let a misconfigured worker
 * report "scorecard temporarily unavailable" every morning for months.
 */
export class ScorecardSectionError extends Error {
  constructor(message, { wholeRun = false, cause } = {}) {
    super(message, cause === undefined ? undefined : { cause });
    this.name = "ScorecardSectionError";
    this.wholeRun = wholeRun === true;
  }
}

const SCORECARD_QUERIES = [
  { kind: "additive", name: "scorecard_additive", key: "additiveRows" },
  { kind: "nonAdditive", name: "scorecard_non_additive", key: "nonAdditiveRows" },
];

/** Classification is by TYPE, never by message text: a substring match on an
 * error message is a contract nobody declared and every reword breaks. */
function releaseFailure(reason) {
  const transient = reason instanceof ReleaseResolutionError && reason.transient === true;
  return new ScorecardSectionError(
    transient
      ? "release resolution exhausted its retries"
      : "release resolution failed its contract",
    { wholeRun: !transient, cause: reason }
  );
}

/**
 * Describes the scorecard's outbound work and interprets its results. Like the
 * adoption section it schedules NOTHING: the orchestrator owns the one limiter.
 *
 * The window anchor exists in two forms, and BOTH are derived here from the
 * single Eastern day the orchestrator resolved - the quoted SQL literal the two
 * queries interpolate, and the plain day the measurement engine buckets by.
 * Accepting either form from the caller is how the queries would come to
 * measure one window while the engine bucketed another, with every number on
 * the page looking entirely reasonable.
 */
export function createScorecardSection(env, context, opts = {}) {
  const hogqlFn = opts.hogqlFn || hogql;
  const resolveReleasesFn = opts.resolveReleasesFn || resolveReleases;
  const hogqlOpts = opts.hogqlOpts || {};
  const releaseOpts = opts.releaseOpts || {};

  const day = context.windowEndExclusiveDay;
  const sqlArgs = {
    prod: context.prod,
    historyStart: `'${context.historyStartDay} 00:00:00'`,
    windowEndExclusive: `'${day} 00:00:00'`,
  };

  const primaryTasks = SCORECARD_QUERIES.map(
    (q) => () => hogqlFn(env, scorecardSql(q.kind, sqlArgs), q.name, hogqlOpts)
  );

  let measurements = null;

  return {
    name: "scorecard",
    primaryTasks,

    followUpTasks(primary) {
      const rowsByKey = {};
      SCORECARD_QUERIES.forEach((q, i) => {
        const outcome = primary[i];
        if (outcome.status !== "fulfilled") {
          throw new ScorecardSectionError(`${q.name} failed`, { cause: outcome.reason });
        }
        // Truncation is checked by buildMeasurements below, independently per
        // query. A second check here would be a second authority on the same
        // rule, free to disagree with it after a later edit; the wiring is
        // proved by a section-level test rather than by repeating the check.
        rowsByKey[q.key] = rowsToObjects(outcome.value);
      });
      measurements = buildMeasurements({ ...rowsByKey, windowEndExclusive: day });
      // Release membership comes from what we PUBLISHED, never from what
      // telemetry happens to show. There is deliberately no all-version
      // fallback: it would silently restore the version-blind behaviour this
      // issue exists to remove.
      return [() => resolveReleasesFn(env, measurements.usageRows,
        { ...releaseOpts, windowEndExclusive: day })];
    },

    finish(_primary, followUp) {
      // The twin of adoption's guard: rankMovers would otherwise be handed a
      // null measurements object and refuse it with a confusing message, or a
      // later edit would make that null mean "no history."
      if (measurements === null) {
        throw new ScorecardSectionError("scorecard finish ran before its measurements were built");
      }
      const outcome = followUp[0];
      if (outcome.status !== "fulfilled") throw releaseFailure(outcome.reason);
      return rankMovers({ measurements, selection: outcome.value });
    },
  };
}
