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
    throw new ReleaseResolutionError("no eligible published releases to judge", {
      transient: false,
    });
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
  const published = await fetchPublishedReleases(env, opts);
  return selectReleases(published, usageRows);
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
  // `fallback_reason` first ships in v2.3.1. Before that the metric is not
  // measurable at all - null, never a zero.
  polish_kept: [
    { from: "2.3.1", id: "polish-v2-fallback-reason" },
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
