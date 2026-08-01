// Unit tests for the pure date-boundary / bucketing / message-formatting
// logic (no network). Run: node --test (from workers/daily-report/)
import { test } from "node:test";
import assert from "node:assert/strict";
import worker, {
  easternYesterdayWindowUTC,
  resolveReportWindow,
  formatAdoption,
  reportHeader,
  driveSections,
  runReport,
} from "../src/index.js";
// #1838 chunk 2: the adoption domain has its own owner. Tests import from it
// directly - a re-export from index.js would be a forwarding shim.
import { createAdoptionSection as rawCreateAdoptionSection, resolveBuckets } from "../src/adoption.js";
import { DISCORD_LIMITS, DiscordPayloadError, deliverReport } from "../../shared/discord.js";
import {
  normalizeReleaseVersion,
  compareVersions,
  selectReleases,
  resolveReleases,
  telemetryContractFor,
  decideComparability,
  COMPARABILITY_REASONS,
  ReleaseResolutionError,
  scorecardSql,
  scorecardSqlTemplate,
  assertCompleteScorecardRows,
  buildMeasurements,
  calculationId,
  METRIC_CALCULATIONS,
  WINDOW_COUNT,
  rankMovers,
  createScorecardSection as rawCreateScorecardSection,
  isScorecardEligible,
  ScorecardSectionError,
  releaseAgeInWindow,
} from "../src/version-scorecard.js";
import { formatScorecard, formatScorecardUnavailable } from "../src/report-format.js";
// #1838 chunk 1: the PostHog transport/concurrency/production-filter
// infrastructure now has ONE owner. Tests import it from there directly - a
// re-export from index.js would be a forwarding shim kept alive solely for
// tests, which this REFACTOR-tier change forbids.
import {
  hogql as rawHogql,
  runLimited,
  resolveDevIds as rawResolveDevIds,
  productionClauseFor,
  querySection as rawQuerySection,
  rowsToObjects,
  sqlIdList,
  sqlTimestamp,
  windowClause,
  PostHogQueryError,
} from "../../shared/posthog.js";

// #1589: the shared transport REQUIRES `workerLabel`, deliberately with no
// default - a default would file this worker's queries under another worker's
// name in PostHog's query log, which reads as correct everywhere it is seen.
// Production sets it once in runReport and forwards the bag; these wrappers do
// the same one thing for tests that call the transport directly, so ~20 call
// sites do not each restate it and a new one cannot silently forget it.
//
// The raw imports above stay reachable so the "label is required" tests can
// call the unwrapped functions - a wrapper that always supplies the label could
// never prove the requirement exists.
const WORKER_LABEL = "daily_report";
const withLabel = (opts = {}) => ({ ...opts, workerLabel: WORKER_LABEL });
const hogql = (env, sql, name, opts = {}) => rawHogql(env, sql, name, withLabel(opts));
const querySection = (env, sql, name, opts = {}) => rawQuerySection(env, sql, name, withLabel(opts));
const resolveDevIds = (env, opts = {}) => rawResolveDevIds(env, withLabel(opts));

// Section factories take the bag as `opts.hogqlOpts`, so they need the same
// one-place treatment: production supplies the label in runReport, and a test
// driving a section directly must not have to remember it.
const sectionOptsWithLabel = (opts = {}) => ({ ...opts, hogqlOpts: withLabel(opts.hogqlOpts) });
const createAdoptionSection = (env, ctx, opts = {}) =>
  rawCreateAdoptionSection(env, ctx, sectionOptsWithLabel(opts));
const createScorecardSection = (env, ctx, opts = {}) =>
  rawCreateScorecardSection(env, ctx, sectionOptsWithLabel(opts));

// ---- easternYesterdayWindowUTC ----

test("EDT case: 'now' inside Eastern Daylight Time (UTC-4)", () => {
  // 2026-07-09 13:12 UTC = 2026-07-09 09:12 EDT -> yesterday = 2026-07-08
  const now = new Date("2026-07-09T13:12:00Z");
  const { dateStr, startUTC, endUTC } = easternYesterdayWindowUTC(now);
  assert.equal(dateStr, "2026-07-08");
  // Midnight ET on 2026-07-08 during EDT (UTC-4) is 2026-07-08T04:00:00Z.
  assert.equal(startUTC.toISOString(), "2026-07-08T04:00:00.000Z");
  assert.equal(endUTC.toISOString(), "2026-07-09T04:00:00.000Z");
});

test("EST case: 'now' inside Eastern Standard Time (UTC-5)", () => {
  // 2026-01-15 13:12 UTC = 2026-01-15 08:12 EST -> yesterday = 2026-01-14
  const now = new Date("2026-01-15T13:12:00Z");
  const { dateStr, startUTC, endUTC } = easternYesterdayWindowUTC(now);
  assert.equal(dateStr, "2026-01-14");
  // Midnight ET on 2026-01-14 during EST (UTC-5) is 2026-01-14T05:00:00Z.
  assert.equal(startUTC.toISOString(), "2026-01-14T05:00:00.000Z");
  assert.equal(endUTC.toISOString(), "2026-01-15T05:00:00.000Z");
});

test("DST-transition-adjacent date (spring forward, 2026-03-08 2am ET)", () => {
  // The day BEFORE the US spring-forward transition (2026-03-08) is still EST.
  const now = new Date("2026-03-08T12:00:00Z");
  const { dateStr, startUTC } = easternYesterdayWindowUTC(now);
  assert.equal(dateStr, "2026-03-07");
  assert.equal(startUTC.toISOString(), "2026-03-07T05:00:00.000Z"); // EST offset
});

test("DST-transition-adjacent date (fall back happens DURING 2026-11-01, at 2am local)", () => {
  // 2026-11-01 is the fall-back Sunday itself (US clocks set back at 2am
  // local). Midnight local on that calendar day precedes the transition, so
  // it is still EDT (UTC-4) -- confirmed against real Intl data (2026-11-01
  // 00:00Z resolves to Saturday 20:00 ET, i.e. EDT). The transition to EST
  // happens later the same day; a date-boundary computed from calendar-day
  // midnight is unaffected by an intraday transition.
  const now = new Date("2026-11-02T12:00:00Z");
  const { dateStr, startUTC } = easternYesterdayWindowUTC(now);
  assert.equal(dateStr, "2026-11-01");
  assert.equal(startUTC.toISOString(), "2026-11-01T04:00:00.000Z"); // EDT offset (pre-transition)
});

test("DST-transition-adjacent date (the day AFTER fall-back, 2026-11-02, is EST)", () => {
  const now = new Date("2026-11-03T12:00:00Z");
  const { dateStr, startUTC } = easternYesterdayWindowUTC(now);
  assert.equal(dateStr, "2026-11-02");
  assert.equal(startUTC.toISOString(), "2026-11-02T05:00:00.000Z"); // EST offset
});

test("explicit ?date= override replaces the yesterday computation", () => {
  const now = new Date("2026-07-09T13:12:00Z");
  const { dateStr, startUTC, endUTC } = easternYesterdayWindowUTC(now, "2026-06-01");
  assert.equal(dateStr, "2026-06-01");
  assert.equal(startUTC.toISOString(), "2026-06-01T04:00:00.000Z"); // EDT offset
  assert.equal(endUTC.toISOString(), "2026-06-02T04:00:00.000Z");
});

// ---- resolveBuckets ----

function makeData(overrides = {}) {
  return {
    totalUsers: 3,
    engineAndTierB: [
      { distinct_id: "u1", engine: "parakeet", tier_b_provider: "egOne" },
      { distinct_id: "u2", engine: "parakeet", tier_b_provider: null },
      { distinct_id: "u3", engine: "whisperKit", tier_b_provider: null },
    ],
    tierA: [{ distinct_id: "u2", provider: "gemini" }],
    ...overrides,
  };
}

test("resolveBuckets: tier-a (settings) wins when present", () => {
  const { polishBuckets, resolutionSource } = resolveBuckets(makeData());
  assert.equal(polishBuckets.gemini, 1); // u2 resolved via tier-a
  assert.equal(resolutionSource.settings, 1);
});

test("resolveBuckets: tier-b (actual dictation) used when no tier-a", () => {
  const { polishBuckets, resolutionSource } = resolveBuckets(makeData());
  assert.equal(polishBuckets.egOne, 1); // u1 resolved via tier-b
  assert.equal(resolutionSource.actual_dictation, 1);
});

test("resolveBuckets: shipped default used when neither tier resolves", () => {
  const { polishBuckets, resolutionSource } = resolveBuckets(makeData());
  assert.equal(polishBuckets.appleIntelligence, 1); // u3 falls all the way through
  assert.equal(resolutionSource.shipped_default, 1);
});

test("resolveBuckets: engine buckets partition totalUsers exactly", () => {
  const { engineBuckets } = resolveBuckets(makeData());
  assert.equal(engineBuckets.parakeet, 2);
  assert.equal(engineBuckets.whisperKit, 1);
});

test("resolveBuckets: throws on completeness mismatch (the 100-row-truncation class of bug)", () => {
  const data = makeData({ totalUsers: 999 }); // independently-queried total disagrees with the per-user rows
  assert.throws(() => resolveBuckets(data), /completeness check failed/);
});

test("resolveBuckets: zero active users is not a divide-by-zero / throw case", () => {
  const { engineBuckets, polishBuckets } = resolveBuckets({
    totalUsers: 0,
    engineAndTierB: [],
    tierA: [],
  });
  assert.deepEqual(engineBuckets, {});
  assert.deepEqual(polishBuckets, {});
});

// ---- productionClauseFor (#1720) ----

test("productionClauseFor: empty dev-id list uses bare ENV_ONLY, never NOT IN ()", () => {
  const clause = productionClauseFor([]);
  assert.doesNotMatch(clause, /NOT IN/);
  assert.match(clause, /properties\.environment = 'production'/);
});

test("productionClauseFor: non-empty list appends a literal NOT IN exclusion", () => {
  const clause = productionClauseFor(["dev-1", "dev-2"]);
  assert.match(clause, /NOT IN \('dev-1', 'dev-2'\)/);
});

// ---- adoption section formatting ----
// Golden fixture: real production numbers from a live-query-smoke.mjs run
// against the ACTUAL implemented queries (2026-07-08 Eastern calendar day,
// captured post-implementation, not the earlier hand-verified planning-time
// numbers). The engine/polish buckets differ meaningfully from the
// planning-time hand-check BY DESIGN: this run uses the corrected
// methodology (direct per-dictation argMax for engine; the
// settings.snapshot + settings.changed UNION for polish tier-a), which the
// planning-time numbers predated. The shift itself (e.g. egOne roughly
// doubling once settings.changed is included) is expected evidence the
// union fix matters, not a regression.

const GOLDEN_DATA = {
  freshInstalls: 90,
  onboarded: 82,
  activated: 60,
  netDictations: 1868,
  totalUsers: 110,
  geo: [
    { country: "Germany", n: 66 },
    { country: "United States", n: 16 },
    { country: "India", n: 3 },
    { country: "Austria", n: 3 },
    { country: "United Kingdom", n: 3 },
  ],
  top5: [{ n: 557 }, { n: 139 }, { n: 113 }, { n: 94 }, { n: 70 }],
};

const GOLDEN_BUCKETS = {
  engineBuckets: { parakeet: 100, whisperKit: 10 },
  polishBuckets: { appleIntelligence: 64, egOne: 36, gemini: 4, none: 3, ollama: 2, openAI: 1 },
};

test("adoption section: golden fixture matches the founder-approved report shape", () => {
  const msg = formatAdoption(GOLDEN_DATA, GOLDEN_BUCKETS).join("\n");

  // The report title is the Discord message's `content` line and has exactly
  // one producer; the adoption embed titles itself and never repeats it.
  assert.equal(reportHeader("2026-07-08"), "EnviousWispr Daily Report, Wednesday, July 8, 2026");
  assert.match(msg, /^Adoption\n/);
  assert.doesNotMatch(msg, /EnviousWispr Daily Report/);
  assert.match(msg, /New installs: 90\. People who finished setup that day: 82\. Of those, 60 also dictated that day\./);
  assert.doesNotMatch(msg, /for the first time/);
  assert.doesNotMatch(msg, /out of 90/); // no funnel-bleed wording (r1 fix)
  assert.match(msg, /Total users: 110 people used the app that day\./);
  // Percentages are against total_users (110), not net_dictations (1868).
  assert.match(msg, /Parakeet 100 \(91%\)/);
  assert.match(msg, /WhisperKit 10 \(9%\)/);
  assert.match(msg, /Apple Intelligence 64 \(58%\)/);
  assert.match(msg, /EG-1 \(our own model\) 36 \(33%\)/);
  assert.match(msg, /Net total dictations: 1868\./);
  assert.match(msg, /Germany 66/);
  assert.match(msg, /Top 5 users by dictation volume: 557, 139, 113, 94, 70\./);
  // No em-dashes/en-dashes anywhere (global CLAUDE.md Rule 6).
  assert.doesNotMatch(msg, /[–—]/);
  // Nothing degraded on the golden run - no "temporarily unavailable" wording.
  assert.doesNotMatch(msg, /temporarily unavailable/);
});

test("adoption section: zero-count buckets are omitted, not shown as '(0%)'", () => {
  const msg = formatAdoption(GOLDEN_DATA, {
    engineBuckets: { parakeet: 110, whisperKit: 0 },
    polishBuckets: { appleIntelligence: 110, gemini: 0 },
  }).join("\n");
  assert.doesNotMatch(msg, /WhisperKit 0/);
  assert.doesNotMatch(msg, /Gemini 0/);
});

test("adoption section: zero total_users omits the engine/polish section entirely (no divide-by-zero)", () => {
  const msg = formatAdoption({ ...GOLDEN_DATA, totalUsers: 0 }, { engineBuckets: {}, polishBuckets: {} }).join("\n");
  assert.doesNotMatch(msg, /Transcription engine/);
  assert.doesNotMatch(msg, /AI polishing/);
  assert.match(msg, /Total users: 0 people used the app that day\./);
});

// ---- adoption section: per-section fail-soft degradation (#1720) ----
//
// Each of the 5 non-essential primary queries can independently degrade to
// "temporarily unavailable" - never a fabricated zero or empty list shown as
// real data - while the rest of the report still ships. `totals` never
// degrades (verified separately below via fetchReportData/runReport).

test("adoption section: installsDegraded omits the freshInstalls number, keeps onboarding intact", () => {
  const msg = formatAdoption({ ...GOLDEN_DATA, installsDegraded: true }, GOLDEN_BUCKETS).join("\n");
  assert.match(msg, /New installs: temporarily unavailable\./);
  assert.doesNotMatch(msg, /New installs: 90/);
  assert.match(msg, /People who finished setup that day: 82\. Of those, 60 also dictated that day\./);
  assert.match(msg, /Note: .*new installs/);
});

test("adoption section: onboardActivateDegraded omits onboarding, keeps installs intact", () => {
  const msg = formatAdoption({ ...GOLDEN_DATA, onboardActivateDegraded: true }, GOLDEN_BUCKETS).join("\n");
  assert.match(msg, /New installs: 90\./);
  assert.match(msg, /Onboarding and activation: temporarily unavailable\./);
  assert.doesNotMatch(msg, /People who finished setup that day/);
  assert.match(msg, /Note: .*onboarding\/activation/);
});

test("adoption section: engineAndTierBDegraded omits both engine and polish lines, never fabricates a bucket", () => {
  const msg = formatAdoption({ ...GOLDEN_DATA, engineAndTierBDegraded: true }, GOLDEN_BUCKETS).join("\n");
  assert.match(msg, /Transcription engine and AI-polish breakdown: temporarily unavailable\./);
  assert.doesNotMatch(msg, /Parakeet/);
  assert.doesNotMatch(msg, /Apple Intelligence/);
  assert.match(msg, /Note: .*transcription engine and AI-polish breakdown/);
});

test("adoption section: geoDegraded omits the countries line, not an empty list shown as zero data", () => {
  const msg = formatAdoption({ ...GOLDEN_DATA, geoDegraded: true }, GOLDEN_BUCKETS).join("\n");
  assert.match(msg, /Where they are: temporarily unavailable\./);
  assert.doesNotMatch(msg, /Germany/);
  assert.match(msg, /Note: .*where they are/);
});

test("adoption section: top5Degraded omits the top-users line", () => {
  const msg = formatAdoption({ ...GOLDEN_DATA, top5Degraded: true }, GOLDEN_BUCKETS).join("\n");
  assert.match(msg, /Top 5 users by dictation volume: temporarily unavailable\./);
  assert.doesNotMatch(msg, /557, 139/);
  assert.match(msg, /Note: .*top 5 users/);
});

test("adoption section: multiple degraded sections all appear in one combined note", () => {
  const msg = formatAdoption({ ...GOLDEN_DATA, installsDegraded: true, geoDegraded: true },
    GOLDEN_BUCKETS
  ).join("\n");
  const noteLine = msg.split("\n").find((l) => l.startsWith("Note:"));
  assert.ok(noteLine, "expected one combined Note line");
  assert.match(noteLine, /new installs/);
  assert.match(noteLine, /where they are/);
});

test("adoption section: totals never has a degrade flag - no such branch exists", () => {
  // totals staying fail-loud means the adoption section throws before
  // formatAdoption is ever called with degraded totals data - there is no
  // totalsDegraded field to test here by design (see the section tests).
  const msg = formatAdoption(GOLDEN_DATA, GOLDEN_BUCKETS).join("\n");
  assert.doesNotMatch(msg, /Total users: temporarily unavailable/);
});

// ---- Source-level guardrail: every list-returning query still carries an
// explicit LIMIT (defense-in-depth per plan §3.3a; the PRIMARY correctness
// mechanism is resolveBuckets' completeness check above, not this string
// check alone - this only guards against a future edit silently dropping
// the LIMIT that bounds worst-case query cost). ----

test("source guardrail: every per-user GROUP BY query has an explicit LIMIT", async () => {
  // Matches ANY backtick template literal in the source, not just `const
  // XSql = \`...\`` assignments -- a query built inside a helper function
  // (e.g. returned via `return \`...\`` rather than assigned to a const)
  // must still be caught. An earlier version of this test only matched the
  // `const` form and would have silently stopped checking tierASqlFor's
  // query when it was refactored into a function during live-smoke-test
  // debugging.
  const fs = await import("node:fs");
  const src = fs.readFileSync(new URL("../src/adoption.js", import.meta.url), "utf8");
  const templateLiterals = src.match(/`[^`]*`/gs) || [];
  const groupByQueries = templateLiterals.filter((q) => /GROUP BY distinct_id/.test(q));
  assert.ok(groupByQueries.length >= 3, "expected to find at least 3 per-user GROUP BY queries in the source");
  for (const body of groupByQueries) {
    assert.match(body, /LIMIT/, `per-user GROUP BY query missing LIMIT: ${body.slice(0, 80)}...`);
  }
});

// Note: the settings.changed-beats-stale-settings.snapshot temporal ordering
// (plan §3.3 row 4) is expressed as SQL (UNION ALL + argMax(value, timestamp)
// over the combined stream) and cannot be exercised by a pure JS unit test
// without mocking the HogQL engine. It is verified by the pre-deploy
// live-query smoke (live-query-smoke.mjs) against real production data, and
// by code review of the tierASql query text in src/adoption.js.

// ---- runLimited (#1588 - PostHog's 3-concurrent-query project limit) ----

/** Signal-based async waits. Each task announces that it started and waits
 * to be released, so every asserted ordering follows an observed signal
 * instead of elapsed wall-clock time. */
function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

test("runLimited: never exceeds the given concurrency and preserves input order", async () => {
  let inFlight = 0;
  let maxInFlight = 0;
  const controls = [1, 2, 3, 4, 5].map((value) => ({
    value,
    started: deferred(),
    release: deferred(),
  }));
  const tasks = controls.map(({ value, started, release }) => async () => {
    inFlight += 1;
    maxInFlight = Math.max(maxInFlight, inFlight);
    started.resolve();
    try {
      await release.promise;
      return value;
    } finally {
      inFlight -= 1;
    }
  });

  const run = runLimited(tasks, 2);
  await Promise.all([controls[0].started.promise, controls[1].started.promise]);

  controls[0].release.resolve();
  await controls[2].started.promise;
  controls[1].release.resolve();
  await controls[3].started.promise;
  controls[2].release.resolve();
  await controls[4].started.promise;
  controls[3].release.resolve();
  controls[4].release.resolve();

  assert.deepEqual(await run, [1, 2, 3, 4, 5]);
  assert.ok(maxInFlight <= 2, `expected at most 2 concurrent tasks, saw ${maxInFlight}`);
});

// #1838 chunk 1 REPLACES the former "a failed wave rejects and never starts a
// later wave" test with its deliberate opposite. The old fail-fast contract is
// incompatible with the merged report's section isolation: one failing adoption
// query would strand the version scorecard's queued work and blank a section
// that could have rendered. Replaced, never deleted - the behaviour it locked is
// now asserted in the other direction so a silent regression to waves fails.
test("runLimited: a rejected task releases its slot and later work STILL runs", async () => {
  let laterWorkStarted = false;
  const tasks = [
    () => Promise.resolve("ok"),
    () => Promise.reject(new Error("boom")),
    () => {
      laterWorkStarted = true;
      return Promise.resolve("must still run");
    },
  ];
  await assert.rejects(() => runLimited(tasks, 2), /boom/);
  assert.equal(
    laterWorkStarted,
    true,
    "queued work after a rejection must still start - see #1838 section isolation"
  );
});

test("runLimited: reports the FIRST failure in input order, not arrival order", async () => {
  // The later-indexed task rejects FIRST in wall-clock terms. Which failure a
  // caller sees must depend on input position, never on scheduling, or a
  // fail-loud caller's error would vary run to run.
  const firstByIndex = deferred();
  const firstByTime = deferred();
  const run = runLimited([() => firstByIndex.promise, () => firstByTime.promise], 2);

  firstByTime.reject(new Error("first-by-time"));
  firstByIndex.reject(new Error("first-by-index"));

  await assert.rejects(run, /first-by-index/);
});

test("runLimited: honours the concurrency ceiling even when tasks reject", async () => {
  let inFlight = 0;
  let maxInFlight = 0;
  const controls = Array.from({ length: 6 }, (_, index) => ({
    index,
    started: deferred(),
    release: deferred(),
  }));
  const tasks = controls.map(({ index, started, release }) => async () => {
    inFlight += 1;
    maxInFlight = Math.max(maxInFlight, inFlight);
    started.resolve();
    try {
      await release.promise;
      if (index % 2 === 0) throw new Error(`boom-${index}`);
      return index;
    } finally {
      inFlight -= 1;
    }
  });

  const run = runLimited(tasks, 2);
  await Promise.all([controls[0].started.promise, controls[1].started.promise]);

  for (let index = 0; index < 4; index += 1) {
    controls[index].release.resolve();
    await controls[index + 2].started.promise;
  }
  controls[4].release.resolve();
  controls[5].release.resolve();

  await assert.rejects(run, /boom-0/);
  assert.ok(maxInFlight <= 2, `expected at most 2 concurrent tasks, saw ${maxInFlight}`);
});

test("runLimited: every task settles before the failure is reported", async () => {
  const secondStarted = deferred();
  const thirdStarted = deferred();
  const secondRelease = deferred();
  const thirdRelease = deferred();
  const secondFinished = deferred();
  const finished = [];
  let rejectionReported = false;

  const run = runLimited(
    [
      () => Promise.reject(new Error("boom")),
      async () => {
        secondStarted.resolve();
        await secondRelease.promise;
        finished.push(1);
        secondFinished.resolve();
      },
      async () => {
        thirdStarted.resolve();
        await thirdRelease.promise;
        finished.push(2);
      },
    ],
    2
  );
  const rejection = assert.rejects(run, /boom/).then(() => {
    rejectionReported = true;
  });

  await Promise.all([secondStarted.promise, thirdStarted.promise]);
  secondRelease.resolve();
  await secondFinished.promise;
  assert.equal(rejectionReported, false, "failure must wait for the remaining task");
  thirdRelease.resolve();

  await rejection;
  assert.deepEqual(finished, [1, 2]);
});

// ---- querySection / rowsToObjects / sqlIdList characterization (#1838 chunk 1) ----
// These three moved with the rest of the PostHog infrastructure but had NO
// direct coverage, so an extraction defect in them would have been invisible.
// Characterizing them here makes the refactor provable independently of the
// feature work that follows.

test("querySection: degrades ONLY on an exhausted retryable status", async () => {
  const env = { POSTHOG_PROJECT_ID: "1", POSTHOG_PERSONAL_API_KEY: "k" };
  const opts = {
    fetchFn: async () => fakeResponse(503, null),
    sleepFn: async () => {},
    randomFn: () => 0,
  };
  const out = await querySection(env, "SELECT 1", "geo", opts);
  assert.equal(out.degraded, true);
  assert.equal(out.response, null);
});

test("querySection: a NON-retryable status still throws, never degrades", async () => {
  const env = { POSTHOG_PROJECT_ID: "1", POSTHOG_PERSONAL_API_KEY: "k" };
  const opts = { fetchFn: async () => fakeResponse(401, null), sleepFn: async () => {}, randomFn: () => 0 };
  await assert.rejects(() => querySection(env, "SELECT 1", "geo", opts), PostHogQueryError);
});

test("querySection: a malformed 200 response throws rather than degrading", async () => {
  // A programming/contract error must stay loud - degrading it would render a
  // section as "temporarily unavailable" and hide a real bug indefinitely.
  const env = { POSTHOG_PROJECT_ID: "1", POSTHOG_PERSONAL_API_KEY: "k" };
  const opts = { fetchFn: async () => fakeResponse(200, {}), sleepFn: async () => {}, randomFn: () => 0 };
  await assert.rejects(() => querySection(env, "SELECT 1", "geo", opts), /returned no results array/);
});

test("querySection: passes through a successful response undegraded", async () => {
  const env = { POSTHOG_PROJECT_ID: "1", POSTHOG_PERSONAL_API_KEY: "k" };
  const body = { results: [[1]], columns: ["n"] };
  const opts = { fetchFn: async () => fakeResponse(200, body), sleepFn: async () => {}, randomFn: () => 0 };
  const out = await querySection(env, "SELECT 1", "geo", opts);
  assert.equal(out.degraded, false);
  assert.deepEqual(out.response, body);
});

test("rowsToObjects: zips columns to rows, and tolerates absent columns/results", () => {
  assert.deepEqual(
    rowsToObjects({ columns: ["a", "b"], results: [[1, 2], [3, 4]] }),
    [{ a: 1, b: 2 }, { a: 3, b: 4 }]
  );
  assert.deepEqual(rowsToObjects({}), []);
  assert.deepEqual(rowsToObjects({ columns: ["a"], results: [] }), []);
});

test("sqlTimestamp: renders a HogQL timestamp literal in UTC, second precision", () => {
  assert.equal(sqlTimestamp(new Date("2026-07-08T04:00:00.000Z")), "2026-07-08 04:00:00");
  // Sub-second precision is deliberately dropped; the window boundaries this
  // builds are whole-second instants.
  assert.equal(sqlTimestamp(new Date("2026-07-08T04:00:00.937Z")), "2026-07-08 04:00:00");
});

test("windowClause: builds a half-open range, start inclusive and end exclusive", () => {
  const clause = windowClause(
    new Date("2026-07-08T04:00:00.000Z"),
    new Date("2026-07-09T04:00:00.000Z")
  );
  assert.equal(
    clause,
    "timestamp >= '2026-07-08 04:00:00' AND timestamp < '2026-07-09 04:00:00'"
  );
  // Half-open matters: an inclusive end would double-count the boundary
  // instant across two consecutive daily reports.
  assert.ok(clause.includes(">="), "start must be inclusive");
  assert.ok(clause.includes("< '"), "end must be exclusive");
});

test("sqlIdList: doubles single quotes so an id cannot break out of its literal", () => {
  assert.equal(sqlIdList(["abc"]), "'abc'");
  assert.equal(sqlIdList(["a'b"]), "'a''b'");
  assert.equal(sqlIdList(["a", "b"]), "'a', 'b'");
  assert.equal(sqlIdList([]), "");
});

test("runLimited: rejects a non-positive-integer limit", async () => {
  await assert.rejects(() => runLimited([() => Promise.resolve(1)], 0), TypeError);
});

// ---- hogql retry (#1588/#1720 - PostHog project concurrency limit / 5xx / 429) ----

function fakeResponse(status, body, { onCancel } = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    body: onCancel ? { cancel: async () => onCancel() } : undefined,
  };
}

test("hogql: retries on 504, waits within the attempt-2 backoff range, then succeeds", async () => {
  let calls = 0;
  const fetchFn = async () => {
    calls += 1;
    return calls === 1 ? fakeResponse(504) : fakeResponse(200, { results: [[1]] });
  };
  const sleeps = [];
  const sleepFn = async (ms) => sleeps.push(ms);
  const json = await hogql({ POSTHOG_PROJECT_ID: "x", POSTHOG_PERSONAL_API_KEY: "k" }, "SELECT 1", "test_query", {
    fetchFn,
    sleepFn,
    randomFn: () => 0, // pins the delay to the range floor for a deterministic assertion
  });
  assert.deepEqual(json.results, [[1]]);
  assert.equal(calls, 2);
  assert.deepEqual(sleeps, [12_000], "attempt 2's backoff floor is 12s");
});

test("hogql: retries on 429 (previously threw immediately)", async () => {
  let calls = 0;
  const fetchFn = async () => {
    calls += 1;
    return calls === 1 ? fakeResponse(429) : fakeResponse(200, { results: [[1]] });
  };
  const json = await hogql({ POSTHOG_PROJECT_ID: "x", POSTHOG_PERSONAL_API_KEY: "k" }, "SELECT 1", "test_query", {
    fetchFn,
    sleepFn: async () => {},
  });
  assert.deepEqual(json.results, [[1]]);
  assert.equal(calls, 2, "429 must be retried, not thrown immediately");
});

test("hogql: retry delay for attempt 3 falls within the documented 30-45s backoff range", async () => {
  let calls = 0;
  const fetchFn = async () => {
    calls += 1;
    return calls < 3 ? fakeResponse(503) : fakeResponse(200, { results: [[1]] });
  };
  const sleeps = [];
  const json = await hogql({ POSTHOG_PROJECT_ID: "x", POSTHOG_PERSONAL_API_KEY: "k" }, "SELECT 1", "test_query", {
    fetchFn,
    sleepFn: async (ms) => sleeps.push(ms),
    // Math.random() returns [0, 1), never exactly 1 - 0.5 is a realistic
    // midpoint probe, not an out-of-domain edge value.
    randomFn: () => 0.5,
  });
  assert.deepEqual(json.results, [[1]]);
  assert.equal(calls, 3);
  assert.deepEqual(sleeps, [15_000, 37_500], "attempt 2 midpoint is 15s, attempt 3 midpoint is 37.5s");
});

// Codex code-diff review, round 2 (#1588): an earlier draft of the retry
// path left the failed response body uncancelled, which could keep a
// Cloudflare outbound subrequest connection occupied across retries.
test("hogql: cancels the failed response body before retrying", async () => {
  let cancelled = false;
  const fetchFn = async () => fakeResponse(504, undefined, { onCancel: () => (cancelled = true) });
  await assert.rejects(
    () =>
      hogql({ POSTHOG_PROJECT_ID: "x", POSTHOG_PERSONAL_API_KEY: "k" }, "SELECT 1", "test_query", {
        fetchFn,
        sleepFn: async () => {
          // Assert cancellation already happened by the time we'd be sleeping before a retry.
          assert.equal(cancelled, true, "expected the failed body to be cancelled before the retry delay");
        },
      }),
    /PostHog query test_query HTTP 504/
  );
  assert.equal(cancelled, true);
});

test("hogql: does not retry on a non-transient 4xx status", async () => {
  let calls = 0;
  const fetchFn = async () => {
    calls += 1;
    return fakeResponse(400);
  };
  await assert.rejects(
    () => hogql({ POSTHOG_PROJECT_ID: "x", POSTHOG_PERSONAL_API_KEY: "k" }, "SELECT 1", "test_query", { fetchFn }),
    /PostHog query test_query HTTP 400/
  );
  assert.equal(calls, 1, "must not retry a non-transient status");
});

test("hogql: throws with the query name after exhausting all 3 attempts on repeated 504", async () => {
  let calls = 0;
  const fetchFn = async () => {
    calls += 1;
    return fakeResponse(504);
  };
  await assert.rejects(
    () =>
      hogql({ POSTHOG_PROJECT_ID: "x", POSTHOG_PERSONAL_API_KEY: "k" }, "SELECT 1", "engine_and_tier_b", {
        fetchFn,
        sleepFn: async () => {},
      }),
    /PostHog query engine_and_tier_b HTTP 504/
  );
  assert.equal(calls, 3, "expected exactly 3 attempts total (#1720 raised this from 2)");
});

// ---- resolveDevIds (#1720) ----

test("resolveDevIds: accepts hogqlOpts so its own retry path is test-deterministic", async () => {
  let calls = 0;
  const fetchFn = async () => {
    calls += 1;
    return calls === 1 ? fakeResponse(504) : fakeResponse(200, { results: [["dev-1"]] });
  };
  const devIds = await resolveDevIds({ POSTHOG_PROJECT_ID: "x", POSTHOG_PERSONAL_API_KEY: "k" }, {
    fetchFn,
    sleepFn: async () => {},
  });
  assert.deepEqual(devIds, ["dev-1"]);
  assert.equal(calls, 2, "resolveDevIds' own hogql call retries like any other query");
});

test("resolveDevIds: throws on overflow rather than silently building a truncated exclusion list", async () => {
  // PER_USER_LIST_LIMIT is 5000; simulate a result over that ceiling via the
  // LIMIT+1 query shape - the fetchFn doesn't need to know the real limit,
  // it just needs to return more than 5000 rows.
  const overflowRows = Array.from({ length: 5001 }, (_, i) => [`dev-${i}`]);
  const fetchFn = async () => fakeResponse(200, { results: overflowRows });
  await assert.rejects(
    () => resolveDevIds({ POSTHOG_PROJECT_ID: "x", POSTHOG_PERSONAL_API_KEY: "k" }, { fetchFn }),
    /dev-id completeness check failed/,
    "must fail loud on overflow, never silently truncate"
  );
});

test("resolveDevIds: an empty result is a valid, non-throwing state", async () => {
  const fetchFn = async () => fakeResponse(200, { results: [] });
  const devIds = await resolveDevIds({ POSTHOG_PROJECT_ID: "x", POSTHOG_PERSONAL_API_KEY: "k" }, { fetchFn });
  assert.deepEqual(devIds, []);
});

// ---- fail-soft boundary: tier-a (#1655) and all 6 primary queries (#1720) ----
//
// These MUST drive the real section and orchestrator, not hogql in isolation:
// the defect they guard against (a blanket catch silently swallowing real
// errors) lives in the section's own interpretation step, so a test that only
// exercises hogql would pass even with the guard broken. The sections call
// hogql without an injectable fetchFn, so the mock is installed on
// globalThis.fetch and dispatches on the query name the worker puts in the
// request body, on the GitHub host, or on the Discord webhook.

// ---- #1838 chunk 6 fixtures: one internally consistent production picture ----
//
// The two scorecard queries measure the SAME successful dictations, so their
// dictation counts must agree per window and version or buildMeasurements
// refuses them. `total_group_rows` must equal the row count or the truncation
// check refuses them. Both are deliberate: a fixture that could not satisfy
// them would be measuring a shape production can never produce.
const SCORECARD_ADDITIVE_COLUMNS = ["day", "app_version", "total_group_rows", "dictations",
  "paste_attempts", "paste_fallbacks", "afm_attempts", "afm_discards",
  "afm_classifier_discards", "terminal_failures"];
const SCORECARD_ADDITIVE_ROWS = [
  ["2026-07-17", "2.4.1", 2, 60, 60, 6, 40, 4, 1, 2],
  ["2026-07-17", "2.4.0", 2, 40, 40, 8, 20, 4, 2, 1],
];
const SCORECARD_NON_ADDITIVE_COLUMNS = ["window_index", "app_version", "total_group_rows",
  "people", "dictations", "speed_samples", "speed_p50", "speed_p95"];
const SCORECARD_NON_ADDITIVE_ROWS = [
  [0, "2.4.1", 2, 12, 60, 60, 1.2, 2.4],
  [0, "2.4.0", 2, 9, 40, 40, 1.3, 2.9],
];
const PUBLISHED_RELEASES = [
  { tag_name: "v2.4.1", published_at: "2026-07-10T12:00:00Z", draft: false, prerelease: false },
  { tag_name: "v2.4.0", published_at: "2026-06-28T12:00:00Z", draft: false, prerelease: false },
];

const GITHUB_HOST = "https://api.github.com";

function githubResponse(status, body) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: () => null },
    json: async () => body,
  };
}

/** Installs a global fetch that lets every query (including the dev_ids
 * preflight, both scorecard queries, the GitHub release list and the Discord
 * post) succeed, and lets the caller redirect any one of them. `seen` records
 * every PostHog query name in order; `requests` records every outbound call so
 * a test can count what actually left the worker. Returns a restore fn. */
function mockPostHog({ failQuery, failWith, github, discordStatus, onDiscord } = {}) {
  const realFetch = globalThis.fetch;
  const seen = [];
  const requests = [];
  const discordPayloads = [];
  const sqlByName = new Map();
  // Real overlap, not a synthetic counter: every call yields to the event loop
  // before answering, so two tasks genuinely coexist and a raised ceiling shows
  // up here instead of being invisible to an instantly-resolving mock.
  let inFlight = 0;
  const state = { maxInFlight: 0 };
  globalThis.fetch = async (url, init) => {
    const target = String(url);
    requests.push(target);
    inFlight += 1;
    state.maxInFlight = Math.max(state.maxInFlight, inFlight);
    try {
      await new Promise((resolve) => setTimeout(resolve, 0));
      return await answer(target, init);
    } finally {
      inFlight -= 1;
    }
  };

  async function answer(target, init) {
    if (target.startsWith(GITHUB_HOST)) {
      if (github instanceof Error) throw github;
      if (typeof github === "number") return githubResponse(github, null);
      return githubResponse(200, github ?? PUBLISHED_RELEASES);
    }

    const body = init?.body ? JSON.parse(init.body) : {};
    if (!body.name) {
      // Discord webhook: its body carries `content`, never a query `name`.
      discordPayloads.push(body);
      if (onDiscord) onDiscord(body);
      return fakeResponse(discordStatus ?? 204);
    }
    const queryName = body.name.replace(/^daily_report_/, "");
    seen.push(queryName);
    sqlByName.set(queryName, body.query.query);
    if (queryName === failQuery) {
      if (failWith instanceof Error) throw failWith;
      return fakeResponse(failWith);
    }
    // dev_ids: empty list is the common, valid case - keeps every downstream
    // query's ${prod} predicate as plain ENV_ONLY in these tests.
    if (queryName === "dev_ids") {
      return fakeResponse(200, { results: [] });
    }
    // totals' total_users must match engine_and_tier_b's row count (1, "u1"),
    // or resolveBuckets' completeness check throws on tests that chain all
    // the way through runReport - the generic fallback below returns an
    // unrelated {c: 0} shape that would falsely trip that check.
    if (queryName === "totals") {
      return fakeResponse(200, { results: [[42, 1]], columns: ["net_dictations", "total_users"] });
    }
    // engine_and_tier_b must return a non-empty id list, or tier-a is skipped
    // entirely and the degrade path is never reached.
    if (queryName === "engine_and_tier_b") {
      return fakeResponse(200, { results: [["u1", "parakeet", null]], columns: ["distinct_id", "engine", "tier_b_provider"] });
    }
    if (queryName === "tier_a") {
      return fakeResponse(200, { results: [["u1", "openai"]], columns: ["distinct_id", "provider"] });
    }
    if (queryName === "scorecard_additive") {
      return fakeResponse(200, { results: SCORECARD_ADDITIVE_ROWS, columns: SCORECARD_ADDITIVE_COLUMNS });
    }
    if (queryName === "scorecard_non_additive") {
      return fakeResponse(200, { results: SCORECARD_NON_ADDITIVE_ROWS, columns: SCORECARD_NON_ADDITIVE_COLUMNS });
    }
    return fakeResponse(200, { results: [[0]], columns: ["c"] });
  }
  return {
    restore: () => (globalThis.fetch = realFetch),
    seen, requests, discordPayloads, sqlByName, state,
  };
}

const TEST_ENV = {
  POSTHOG_PROJECT_ID: "x",
  POSTHOG_PERSONAL_API_KEY: "k",
  GITHUB_REPO: "saurabhav88/EnviousWispr",
  DISCORD_WEBHOOK_URL: "https://discord.example/webhook",
};
const TEST_WIN = "timestamp >= '2026-07-17 04:00:00' AND timestamp < '2026-07-18 04:00:00'";
const TEST_END = new Date("2026-07-18T04:00:00Z");

// The orchestrator's resolved context for the 2026-07-17 Eastern day, exactly
// as resolveReportWindow builds it (asserted below, so a drift in either
// direction fails rather than letting these tests measure a window production
// never uses).
const TEST_CONTEXT = Object.freeze({
  ...resolveReportWindow(new Date("2026-07-18T12:00:00Z"), "2026-07-17"),
  prod: "properties.environment = 'production'",
});

/**
 * Drives the adoption section through the REAL orchestrator. A hand-rolled
 * stand-in here would be a second staging authority: it would pass while
 * production ran a different path, which is the whole class of defect this
 * chunk exists to make impossible.
 */
const SECRET_ENV = { ...TEST_ENV, TRIGGER_SECRET: "s3cret" };

/** Drives the worker's HTTP entry point, so the trigger STATUS is part of the
 * assertion rather than an inference from runReport's return value. */
function trigger(search = "", env = SECRET_ENV) {
  return worker.fetch(new Request(`https://worker.example/?token=s3cret${search}`), env);
}

async function fetchAdoption(sectionOpts = {}) {
  const driver = createAdoptionSection(TEST_ENV, TEST_CONTEXT, {
    hogqlOpts: { sleepFn: async () => {} },
    ...sectionOpts,
  });
  let captured;
  const [outcome] = await driveSections(
    [{
      driver,
      describe: (result) => { captured = result; return ["Adoption", "body"]; },
      unavailable: () => ["Adoption", "unavailable"],
    }],
    2
  );
  if (outcome.status === "rejected") throw outcome.reason;
  return captured;
}

test("tier-a: an exhausted 504 degrades instead of failing the whole report", async () => {
  const mock = mockPostHog({ failQuery: "tier_a", failWith: 504 });
  try {
    const { data } = await fetchAdoption();
    assert.equal(data.tierADegraded, true, "expected the degraded flag to be set");
    assert.deepEqual(data.tierA, [], "expected tier-a to fall back to empty rows");
    // The report itself must still be intact - this is the whole point.
    assert.equal(data.engineAndTierB.length, 1, "the successful batch data must survive");
  } finally {
    mock.restore();
  }
});

test("tier-a: 502 and 503 also degrade (the note wording covers all three)", async () => {
  for (const status of [502, 503]) {
    const mock = mockPostHog({ failQuery: "tier_a", failWith: status });
    try {
      const { data } = await fetchAdoption();
      assert.equal(data.tierADegraded, true, `expected HTTP ${status} to degrade`);
    } finally {
      mock.restore();
    }
  }
});

test("tier-a: a NON-retryable HTTP failure still throws (no silent swallow)", async () => {
  const mock = mockPostHog({ failQuery: "tier_a", failWith: 401 });
  try {
    await assert.rejects(
      () => fetchAdoption(),
      (err) => {
        assert.ok(err instanceof PostHogQueryError, "expected the original structured error");
        assert.equal(err.status, 401);
        return true;
      },
      "an auth failure must NOT be disguised as an approximate report"
    );
  } finally {
    mock.restore();
  }
});

test("tier-a: an ordinary Error still throws (no silent swallow)", async () => {
  const boom = new TypeError("undefined is not a function");
  const mock = mockPostHog({ failQuery: "tier_a", failWith: boom });
  try {
    await assert.rejects(
      () => fetchAdoption(),
      (err) => {
        assert.equal(err, boom, "expected the ORIGINAL error, unwrapped and unswallowed");
        return true;
      },
      "a programming error must NOT be disguised as an approximate report"
    );
  } finally {
    mock.restore();
  }
});

test("totals: an exhausted 504 still fails the whole report - the sole fail-loud primary query", async () => {
  const mock = mockPostHog({ failQuery: "totals", failWith: 504 });
  try {
    await assert.rejects(
      () => fetchAdoption(),
      /PostHog query totals HTTP 504/,
      "totals must never degrade - it anchors resolveBuckets' completeness check"
    );
  } finally {
    mock.restore();
  }
});

test("resolveDevIds: an exhausted 504 fails the whole report, never silently treated as 'no dev ids'", async () => {
  // Now a SHARED-preflight failure: without a resolved exclusion there is no
  // honest production population for either section, so neither may start.
  const mock = mockPostHog({ failQuery: "dev_ids", failWith: 504 });
  try {
    await assert.rejects(
      () => runReport(TEST_ENV, "2026-07-17", { hogqlOpts: { sleepFn: async () => {} } }),
      /PostHog query dev_ids HTTP 504/
    );
    assert.ok(!mock.seen.includes("totals"), "no adoption query may start");
    assert.ok(!mock.seen.includes("scorecard_additive"), "no scorecard query may start");
  } finally {
    mock.restore();
  }
});

test("a clean run leaves tierADegraded false and every other degraded flag false", async () => {
  const mock = mockPostHog({ failQuery: null });
  try {
    const { data } = await fetchAdoption();
    assert.equal(data.tierADegraded, false);
    assert.equal(data.tierA.length, 1);
    for (const key of ["installsDegraded", "onboardActivateDegraded", "engineAndTierBDegraded", "geoDegraded", "top5Degraded"]) {
      assert.equal(data[key], false, `expected ${key} to be false on a clean run`);
    }
  } finally {
    mock.restore();
  }
});

// ---- fail-soft: the 5 non-essential primary queries individually (#1720) ----

for (const queryName of ["installs", "onboard_activate", "engine_and_tier_b", "geo", "top5"]) {
  test(`${queryName}: an exhausted 504 degrades that section instead of failing the whole report`, async () => {
    const mock = mockPostHog({ failQuery: queryName, failWith: 504 });
    try {
      const { data } = await fetchAdoption();
      const degradedKey = {
        installs: "installsDegraded",
        onboard_activate: "onboardActivateDegraded",
        engine_and_tier_b: "engineAndTierBDegraded",
        geo: "geoDegraded",
        top5: "top5Degraded",
      }[queryName];
      assert.equal(data[degradedKey], true, `expected ${degradedKey} to be true`);
    } finally {
      mock.restore();
    }
  });

  test(`${queryName}: a NON-retryable failure (401) still throws, no silent swallow`, async () => {
    const mock = mockPostHog({ failQuery: queryName, failWith: 401 });
    try {
      await assert.rejects(
        () => fetchAdoption(),
        (err) => err instanceof PostHogQueryError && err.status === 401
      );
    } finally {
      mock.restore();
    }
  });
}

test("engineAndTierBDegraded also empties activeIds, so tier_a is naturally skipped (not separately queried)", async () => {
  const mock = mockPostHog({ failQuery: "engine_and_tier_b", failWith: 504 });
  try {
    const { data } = await fetchAdoption();
    assert.equal(data.engineAndTierBDegraded, true);
    assert.deepEqual(data.engineAndTierB, []);
    assert.equal(data.tierADegraded, false, "tier_a was never attempted, so it is not itself degraded");
    assert.ok(!mock.seen.includes("tier_a"), "tier_a must not be queried when there are no active ids to enrich");
  } finally {
    mock.restore();
  }
});

// ---- runReport: engineAndTierBDegraded skips resolveBuckets entirely (#1720) ----
//
// Proven via an injected/spied deps.resolveBuckets, not just output
// inspection - a test asserting only on runReport's return value can't
// distinguish "resolveBuckets ran and happened to produce empty buckets"
// from "resolveBuckets was never called." deps.hogqlOpts is also injected so
// the exhausted-retry path here doesn't sit through real backoff delays.

test("runReport: engineAndTierBDegraded means resolveBuckets is never called, and the report still renders", async () => {
  const mock = mockPostHog({ failQuery: "engine_and_tier_b", failWith: 504 });
  let resolveBucketsCalls = 0;
  const spyResolveBuckets = (data) => {
    resolveBucketsCalls += 1;
    return resolveBuckets(data);
  };
  try {
    const message = await runReport(TEST_ENV, "2026-07-17", {
      resolveBuckets: spyResolveBuckets,
      hogqlOpts: { sleepFn: async () => {} },
    });
    assert.equal(resolveBucketsCalls, 0, "resolveBuckets must not be called when engineAndTierB degraded");
    // runReport returns the message's content line; the sections travel as
    // embeds, so the degraded wording is asserted where it is actually sent.
    assert.equal(message, reportHeader("2026-07-17"));
    assert.equal(mock.discordPayloads.length, 1, "exactly one Discord request");
    assert.match(mock.discordPayloads[0].embeds[0].description,
      /Transcription engine and AI-polish breakdown: temporarily unavailable\./);
  } finally {
    mock.restore();
  }
});

test("runReport: a clean run DOES call resolveBuckets (the spy is a real trigger, not always-skipped)", async () => {
  const mock = mockPostHog({ failQuery: null });
  let resolveBucketsCalls = 0;
  const spyResolveBuckets = (data) => {
    resolveBucketsCalls += 1;
    return resolveBuckets(data);
  };
  try {
    await runReport(TEST_ENV, "2026-07-17", {
      resolveBuckets: spyResolveBuckets,
      hogqlOpts: { sleepFn: async () => {} },
    });
    assert.equal(resolveBucketsCalls, 1, "expected resolveBuckets to run exactly once on a clean report");
  } finally {
    mock.restore();
  }
});

// ---- degraded note placement (#1655/#1720) ----

test("degraded note appears near the top, and a long report is never truncated", () => {
  // A long report: far more geography than any real day produces. The old
  // transport sliced content at 1990 characters, which could cut the tail off
  // exactly on the busiest days; the section now travels in an embed and is
  // sent WHOLE or not at all (an over-budget payload is refused before any
  // request, never shortened into something that reads as complete).
  const data = {
    ...GOLDEN_DATA,
    tierADegraded: true,
    geo: Array.from({ length: 60 }, (_, i) => ({ country: `Country-With-A-Long-Name-${i}`, n: i })),
  };
  const msg = formatAdoption(data, GOLDEN_BUCKETS).join("\n");

  assert.match(msg, /polish-provider breakdown is approximate/);
  assert.ok(msg.length > 1990, "fixture must be long enough to have tripped the old cap");
  assert.doesNotMatch(msg, /\.\.\.$/, "the section must never be truncated");
  assert.match(msg, /Top 5 users by dictation volume: 557, 139, 113, 94, 70\.$/,
    "the LAST line must survive in full");
  const noteIndex = msg.indexOf("Note: the polish-provider breakdown is approximate");
  assert.ok(noteIndex >= 0 && noteIndex < 200, `note must be near the top, was at ${noteIndex}`);
});

test("no degraded note on a clean run", () => {
  const msg = formatAdoption({ ...GOLDEN_DATA, tierADegraded: false }, GOLDEN_BUCKETS).join("\n");
  assert.doesNotMatch(msg, /approximate/);
  assert.doesNotMatch(msg, /^Note:/m);
});

// ---- load-bearing coupling guards ----
//
// tier-a and activeUsersSubquery may each omit the whole-history dev-ID
// exclusion ONLY because the population they're tested against was already
// filtered by the report's shared `${prod}` predicate elsewhere. If a future
// edit breaks that coupling, the omission silently becomes a correctness
// bug rather than a redundancy removal.

test("source guardrail: tier-a may omit dev exclusion only while active ids come from the full production predicate", async () => {
  const fs = await import("node:fs");
  const src = fs.readFileSync(new URL("../src/adoption.js", import.meta.url), "utf8");

  const engineQuery = src.match(/const engineAndTierBSql = `([\s\S]*?)`;/)?.[1];
  assert.ok(engineQuery, "expected engineAndTierBSql");
  assert.match(engineQuery, /\$\{prod\}/);

  const tierAFunction = src.match(/function tierASqlFor\([\s\S]*?\n}\n/)?.[0];
  assert.ok(tierAFunction, "expected tierASqlFor");
  assert.match(tierAFunction, /\$\{ENV_ONLY\}/);
  assert.doesNotMatch(tierAFunction, /\$\{prod\}/);
  assert.equal(
    (tierAFunction.match(/distinct_id IN \(\$\{ids\}\)/g) || []).length,
    2,
    "both tier-a UNION branches must remain restricted to the pre-filtered active-id list"
  );
});

test("source guardrail: onboard-activate's active-user lookup may omit dev exclusion only while its own outer WHERE keeps the full predicate", async () => {
  const fs = await import("node:fs");
  const src = fs.readFileSync(new URL("../src/adoption.js", import.meta.url), "utf8");

  const activeUsersFunction = src.match(/function activeUsersSubquery\([\s\S]*?\n}\n/)?.[0];
  assert.ok(activeUsersFunction, "expected activeUsersSubquery");
  assert.match(activeUsersFunction, /\$\{ENV_ONLY\}/);
  assert.doesNotMatch(activeUsersFunction, /\$\{prod\}/);

  const onboardActivateQuery = src.match(/const onboardActivateSql = `([\s\S]*?)`;/)?.[1];
  assert.ok(onboardActivateQuery, "expected onboardActivateSql");
  assert.match(
    onboardActivateQuery,
    /WHERE event = 'onboarding\.completed' AND \$\{prod\} AND \$\{win\}/,
    "the outer onboarding.completed filter must keep the full production predicate - activeUsersSubquery's env-only shortcut depends on it"
  );
});

test("source guardrail: all 6 primary *Sql builders reference the shared ${prod} predicate, none re-embeds a raw dev-exclusion subquery", async () => {
  const fs = await import("node:fs");
  const src = fs.readFileSync(new URL("../src/adoption.js", import.meta.url), "utf8");

  for (const name of ["installsSql", "onboardActivateSql", "totalsSql", "engineAndTierBSql", "geoSql", "top5Sql"]) {
    const query = src.match(new RegExp(`const ${name} = \`([\\s\\S]*?)\`;`))?.[1];
    assert.ok(query, `expected ${name}`);
    assert.match(query, /\$\{prod\}/, `${name} must reference the shared \${prod} predicate`);
    assert.doesNotMatch(
      query,
      /app_version LIKE/,
      `${name} must not re-embed the raw dev-exclusion subquery inline`
    );
  }
});

// ---- worst-case fetch-count bound (#1720, R1/R4 corrections) ----
//
// This worker is invoked via an incoming HTTP fetch (no Cloudflare hard
// wall-time limit for that invocation type); the real caps are total
// subrequests (50) and concurrent subrequests (6) per incoming request.
// This test locks the arithmetic, not a wall-clock duration.

test("worst-case explicit fetch count stays under Cloudflare's 50-subrequest cap", async () => {
  // Both halves are asserted EXACTLY, not just against the 50 ceiling: a
  // ceiling-only check passes while an accidental extra query per run goes
  // unnoticed for months, and query count is the resource this worker is
  // actually scarce in (PostHog concurrency, not Cloudflare subrequests).
  const PREFLIGHT_QUERIES = 1; // resolveDevIds
  const ADOPTION_QUERIES = 7; // installs, onboard_activate, totals, engine_and_tier_b, geo, top5, tier_a
  const SCORECARD_QUERIES = 2; // additive (day grain) + non-additive (window grain)
  const GITHUB_REQUESTS = 1; // the published release list
  const MAX_ATTEMPTS_PER_REQUEST = 3;
  const DISCORD_POSTS = 1; // one atomic payload, one attempt, never a retry

  const worstCase =
    (PREFLIGHT_QUERIES + ADOPTION_QUERIES + SCORECARD_QUERIES + GITHUB_REQUESTS) *
      MAX_ATTEMPTS_PER_REQUEST +
    DISCORD_POSTS;

  assert.equal(worstCase, 34, "the designed worst case is exactly 34 outbound requests");
  assert.ok(worstCase < 50, "worst-case fetch count must stay under Cloudflare's 50-subrequest-per-request cap");

  // And the CLEAN case, measured against the real worker rather than restated:
  // one attempt each, tier A included because the fixture has active ids.
  const mock = mockPostHog({});
  try {
    await runReport(TEST_ENV, "2026-07-17", { hogqlOpts: { sleepFn: async () => {} } });
    assert.equal(mock.requests.length, 12, `expected 12 clean-run requests, got ${mock.requests.length}`);
    assert.deepEqual(
      [...mock.seen].sort(),
      ["dev_ids", "engine_and_tier_b", "geo", "installs", "onboard_activate",
       "scorecard_additive", "scorecard_non_additive", "tier_a", "top5", "totals"],
      "the clean run's ten PostHog queries, each asked exactly once"
    );
  } finally {
    mock.restore();
  }
});


// ---- #1838 chunk 3: release selection + telemetry comparability ------------
// Publication decides WHICH releases are judged; usage decides only order and
// coverage. Comparability depends solely on declared contracts, never on which
// event codes happen to appear.

function ghResponse(status, body, { headers = {}, onCancel } = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: (k) => headers[k.toLowerCase()] ?? null },
    json: async () => body,
    body: onCancel ? { cancel: async () => onCancel() } : undefined,
  };
}
const release = (tag, publishedAt, extra = {}) => ({
  tag_name: tag,
  published_at: publishedAt,
  draft: false,
  prerelease: false,
  ...extra,
});
const usage = (v, n) => ({ app_version: v, dictations: n });
/** A sparse array whose PROTOTYPE supplies the missing index. `i in arr` walks
 * the prototype and reads true, so this looks dense while owning no element -
 * the combination of two acceptance mechanisms, not either alone. */
function protoBackedSparse(length, protoValue) {
  const proto = [];
  for (let i = 0; i < length; i += 1) proto[i] = protoValue;
  const arr = new Array(length);
  Object.setPrototypeOf(arr, proto);
  return arr;
}

test("normalizeReleaseVersion: maps a GitHub tag to a telemetry version", () => {
  for (const [input, expected] of [
    ["v2.4.1", "2.4.1"],
    ["2.4.1", "2.4.1"],
    ["  v2.4.1  ", "2.4.1"],
    ["v02.04.01", "2.4.1"],
  ]) {
    assert.equal(normalizeReleaseVersion(input), expected, `input ${input}`);
  }
});

test("compareVersions: orders numerically, so 2.4.10 is newer than 2.4.9", () => {
  assert.ok(compareVersions("2.4.10", "2.4.9") > 0, "2.4.10 must outrank 2.4.9");
  assert.ok(compareVersions("2.4.9", "2.4.10") < 0);
  assert.equal(compareVersions("2.4.1", "2.4.1"), 0);
  assert.ok(compareVersions("3.0.0", "2.99.99") > 0);
  // Lexicographic ordering would invert the first case and quietly drop the
  // newest release off the table.
  assert.ok("2.4.10" < "2.4.9", "guard: string ordering really is wrong here");
});

test("malformed tags, versions and usage rows are refused, never silently absorbed", async () => {
  // Non-strings are refused rather than coerced: String(x) would have accepted
  // an object or number as a version the rest of the module treats as a string.
  for (const bad of ["", "v2.4", "2.4.1-beta", "latest", "v2.4.1.1", null, undefined, "vX.Y.Z",
                     241, {}, [], { toString: () => "2.4.1" }, true]) {
    assert.equal(normalizeReleaseVersion(bad), null, `expected refusal for ${String(bad)}`);
  }
  assert.throws(() => compareVersions("2.4", "2.4.1"), ReleaseResolutionError);

  // Silently skipping a malformed row would drop real dictations from the
  // coverage DENOMINATOR while still printing a high coverage percentage - a
  // better-looking number produced by losing data.
  const published = [{ version: "2.4.1", publishedAt: "2026-07-24T00:00:00Z" }];
  assert.throws(
    () => selectReleases(published, [usage("2.4.1", 10), usage("not-a-version", 500)]),
    ReleaseResolutionError,
    "a malformed version must fail loud, not shrink the denominator"
  );
  for (const badRow of [null, "2.4.1", ["2.4.1", 5], 42]) {
    assert.throws(
      () => selectReleases(published, [badRow]),
      ReleaseResolutionError,
      `usage row ${JSON.stringify(badRow)} must be refused`
    );
  }
  for (const badCount of ["500", 1.5, -1, null, undefined, NaN]) {
    assert.throws(
      () => selectReleases(published, [{ app_version: "2.4.1", dictations: badCount }]),
      ReleaseResolutionError,
      `count ${String(badCount)} must be refused, not coerced to 0`
    );
  }
  assert.throws(() => selectReleases(published, null), ReleaseResolutionError);
  assert.throws(() => selectReleases(published, new Array(2)), ReleaseResolutionError,
    "a sparse usageRows array must be refused, not silently skipped");
  assert.throws(
    () => selectReleases(published, protoBackedSparse(2, usage("2.4.1", 1))),
    ReleaseResolutionError,
    "prototype-backed indices must not read as owned elements"
  );

  // SOURCE GUARDRAIL, matching this suite's existing dev-exclusion guards. The
  // strict parser must be the ONLY date authority. A second `new Date(...)` in
  // the sort is not observably wrong today - both agree on every input that
  // survives validation - so no behavioural test can catch it. It is still a
  // second authority that would drift, which is exactly what a source guard is
  // for. Permitted occurrences are inside parseGitHubTimestamp only.
  const fs = await import("node:fs");
  const scSrc = fs.readFileSync(new URL("../src/version-scorecard.js", import.meta.url), "utf8");
  // Every `new Date(` must sit inside a declared STRICT parser. Counting
  // occurrences was the wrong shape (chunk 4 legitimately added a second strict
  // parser), and a backward scan for the nearest `function` was ALSO wrong: it
  // does not track closing braces, so a loose call placed AFTER a parser's body
  // gets attributed to that already-closed parser. This extracts each parser's
  // bounded body, then requires zero operational uses anywhere else.
  const STRICT_PARSERS = ["parseGitHubTimestamp", "parseEasternDay", "easternDayOf"];
  const operational = (text) =>
    text.split("\n").filter((l) => l.includes("new Date(") && !l.trimStart().startsWith("*")).length;

  let remaining = scSrc;
  for (const parser of STRICT_PARSERS) {
    const start = scSrc.indexOf(`function ${parser}(`);
    assert.ok(start !== -1, `${parser} must exist`);
    // Walk braces from the body's opening brace to its matching close.
    let depth = 0;
    let end = -1;
    for (let i = scSrc.indexOf("{", start); i < scSrc.length; i += 1) {
      if (scSrc[i] === "{") depth += 1;
      else if (scSrc[i] === "}") {
        depth -= 1;
        if (depth === 0) { end = i + 1; break; }
      }
    }
    assert.ok(end !== -1, `could not bound ${parser}`);
    const body = scSrc.slice(start, end);
    assert.equal(operational(body), 1, `${parser} must contain exactly one new Date(`);
    remaining = remaining.replace(body, "");
  }
  assert.equal(
    operational(remaining),
    0,
    "new Date( outside a strict parser body - every date must go through one"
  );

  // selectReleases is exported and pure, so it revalidates its own release
  // input rather than trusting that a caller went through resolveReleases.
  for (const badReleases of [
    null,
    [{ version: "nope", publishedAt: "2026-07-24T00:00:00Z" }],
    [{ version: "2.4.1", publishedAt: "not-a-date" }],
    [{ version: "2.4.1" }],
    [
      { version: "2.4.1", publishedAt: "2026-07-24T00:00:00Z" },
      { version: "2.4.1", publishedAt: "2026-07-25T00:00:00Z" },
    ],
    // CANONICALIZATION: "v2.4.1" and "2.4.1" are the SAME release. Validating
    // the normalized form while storing the raw one accepted them as two, giving
    // duplicate columns and usage that attached to neither.
    [
      { version: "v2.4.1", publishedAt: "2026-07-24T00:00:00Z" },
      { version: "2.4.1", publishedAt: "2026-07-25T00:00:00Z" },
    ],
    [null],
    ["not-an-object"],
    [{ version: 241, publishedAt: "2026-07-24T00:00:00Z" }],
    [{ version: "2.4.1", publishedAt: 1753300000000 }],
    // Permissive date parsing: "0" becomes the year 2000, "July 24, 2026"
    // parses in LOCAL time, and "2026-02-30" silently rolls to March 2nd. Any
    // of these would be accepted as a publication date and could reorder the
    // displayed set.
    [{ version: "2.4.1", publishedAt: "0" }],
    [{ version: "2.4.1", publishedAt: "July 24, 2026" }],
    [{ version: "2.4.1", publishedAt: "2026-02-30T00:00:00Z" }],
    [{ version: "2.4.1", publishedAt: "2026-07-24" }],
    [{ version: "2.4.1", publishedAt: "2026-07-24T17:10:48.000Z" }],
    // SPARSE: .map and .some SKIP holes, so a hole passes every null check and
    // then surfaces as undefined downstream. Length is not proof of contents.
    new Array(1),
    Object.assign([{ version: "2.4.1", publishedAt: "2026-07-24T00:00:00Z" }], { length: 2 }),
    protoBackedSparse(1, { version: "2.4.1", publishedAt: "2026-07-24T00:00:00Z" }),
  ]) {
    assert.throws(
      () => selectReleases(badReleases, [usage("2.4.1", 1)]),
      ReleaseResolutionError,
      `expected refusal for ${JSON.stringify(badReleases)}`
    );
  }
});

test("resolveReleases: uses GITHUB_REPO + User-Agent, drops draft/prerelease, newest by published_at", async () => {
  let seenUrl = null;
  let seenUA = null;
  const body = [
    // Deliberately NOT in published_at order - array order must not decide.
    release("v2.3.2", "2026-07-10T10:00:00Z"),
    release("v2.4.1", "2026-07-24T17:00:00Z"),
    release("v9.9.9", "2026-07-28T00:00:00Z", { draft: true }),
    release("v8.8.8", "2026-07-27T00:00:00Z", { prerelease: true }),
    release("v2.4.0", "2026-07-18T21:00:00Z"),
  ];
  const out = await resolveReleases(
    { GITHUB_REPO: "saurabhav88/EnviousWispr" },
    [usage("2.4.1", 100)],
    {
      windowEndExclusive: "2026-07-29",
        fetchFn: async (url, init) => {
        seenUrl = url;
        seenUA = init.headers["User-Agent"];
        return ghResponse(200, body);
      },
      sleepFn: async () => {},
    }
  );
  assert.ok(seenUrl.includes("/repos/saurabhav88/EnviousWispr/releases"), seenUrl);
  assert.equal(seenUA, "EnviousWispr-Daily-Report");
  assert.equal(out.releases[0].version, "2.4.1", "newest by published_at must lead");
  const shown = out.releases.map((r) => r.version);
  assert.ok(!shown.includes("9.9.9"), "draft must be excluded");
  assert.ok(!shown.includes("8.8.8"), "prerelease must be excluded");
});

test("resolveReleases: bad configuration and malformed release data fail loud, never silently", async () => {
  // Configuration is checked before any request, and validated as a real
  // owner/repo slug - "EnviousWispr" alone would build a URL that 404s and read
  // as a genuine API failure.
  // URL syntax and path traversal are not repository names: each of these
  // previously built a request URL that meant something else entirely.
  for (const repo of [undefined, "", "   ", "EnviousWispr", "owner/repo/extra", "owner /repo",
                      "owner/repo?per_page=1", "owner#fragment/repo", "../repo", "owner/..",
                      "./repo", "owner/.", 42, null, {}]) {
    let called = false;
    await assert.rejects(
      () =>
        resolveReleases(repo === undefined ? {} : { GITHUB_REPO: repo }, [], {
          windowEndExclusive: "2026-07-29",
        fetchFn: async () => { called = true; return ghResponse(200, []); },
        }),
      (err) => err instanceof ReleaseResolutionError && err.transient === false,
      `repo ${JSON.stringify(repo)}`
    );
    assert.equal(called, false, `config error for ${JSON.stringify(repo)} must not make a request`);
  }

  // A malformed NEWEST release must never be silently filtered out: dropping it
  // crowns the second-newest and changes the entire displayed set with nothing
  // reporting a problem.
  const env = { GITHUB_REPO: "o/r" };
  const bodies = [
    [release("v9.9.9", null), release("v2.4.1", "2026-07-24T00:00:00Z")],
    [release("v9.9.9", "not-a-date"), release("v2.4.1", "2026-07-24T00:00:00Z")],
    [release("v9.9.9", "2026-07-29T00:00:00Z", { draft: "yes" })],
    [release("bad-tag", "2026-07-29T00:00:00Z")],
    ["not-an-object"],
    [null],
    [release("v2.4.1", "2026-07-24T00:00:00Z"), release("2.4.1", "2026-07-25T00:00:00Z")],
    { not: "an array" },
    [release("v2.4.1", "July 24, 2026")],
    [release("v2.4.1", "2026-02-30T00:00:00Z")],
    [release("v2.4.1", "0")],
    new Array(1),
    protoBackedSparse(1, release("v2.4.1", "2026-07-24T00:00:00Z")),
  ];
  for (const body of bodies) {
    await assert.rejects(
      () => resolveReleases(env, [usage("2.4.1", 1)], {
        windowEndExclusive: "2026-07-29",
        fetchFn: async () => ghResponse(200, body),
        sleepFn: async () => {},
      }),
      (err) => err instanceof ReleaseResolutionError && err.transient === false,
      `body ${JSON.stringify(body)}`
    );
  }

  // Invalid JSON is a contract failure, not a transient blip.
  await assert.rejects(
    () => resolveReleases(env, [], {
      windowEndExclusive: "2026-07-29",
        fetchFn: async () => ({ ok: true, status: 200, headers: { get: () => null },
        json: async () => { throw new SyntaxError("bad json"); } }),
      sleepFn: async () => {},
    }),
    (err) => err instanceof ReleaseResolutionError && err.transient === false
  );
});

test("resolveReleases: rate-limited 403, 429 and 5xx retry to exactly 3 attempts then signal transient", async () => {
  // A network-level rejection produces no response to inspect, so without
  // explicit handling it escapes unretried AND unclassified.
  let netAttempts = 0;
  await assert.rejects(
    () =>
      resolveReleases({ GITHUB_REPO: "o/r" }, [], {
        windowEndExclusive: "2026-07-29",
        fetchFn: async () => {
          netAttempts += 1;
          throw new TypeError("network failure");
        },
        sleepFn: async () => {},
      }),
    (err) => err instanceof ReleaseResolutionError && err.transient === true,
    "network rejection"
  );
  assert.equal(netAttempts, 3, "a network rejection must retry to exactly 3 attempts");

  for (const [status, headers] of [
    [403, { "x-ratelimit-remaining": "0" }],
    [429, {}],
    [503, {}],
  ]) {
    let attempts = 0;
    await assert.rejects(
      () =>
        resolveReleases({ GITHUB_REPO: "o/r" }, [], {
          windowEndExclusive: "2026-07-29",
        fetchFn: async () => {
            attempts += 1;
            return ghResponse(status, null, { headers });
          },
          sleepFn: async () => {},
        }),
      (err) => err instanceof ReleaseResolutionError && err.transient === true,
      `status ${status}`
    );
    assert.equal(attempts, 3, `status ${status} must make exactly 3 attempts`);
  }
});

test("resolveReleases: a non-transient 4xx fails loud after ONE attempt", async () => {
  for (const [status, headers] of [
    [404, {}],
    // A forbidden response that is NOT rate-limit exhaustion is a real failure,
    // not a blip - retrying it would report a permission problem as temporary.
    [403, { "x-ratelimit-remaining": "57" }],
  ]) {
    let attempts = 0;
    await assert.rejects(
      () =>
        resolveReleases({ GITHUB_REPO: "o/r" }, [], {
          windowEndExclusive: "2026-07-29",
        fetchFn: async () => {
            attempts += 1;
            return ghResponse(status, null, { headers });
          },
          sleepFn: async () => {},
        }),
      (err) => err instanceof ReleaseResolutionError && err.transient === false,
      `status ${status}`
    );
    assert.equal(attempts, 1, `status ${status} must not retry`);
  }
});

test("selectReleases: newest is always included at 1% share, then fills by descending share to 80%", () => {
  // Deliberately NOT in publication order: the pure selector must derive
  // "newest" from published_at, never from the caller's array position.
  const published = [
    { version: "2.3.2", publishedAt: "2026-07-10T00:00:00Z" },
    { version: "2.4.2", publishedAt: "2026-07-29T00:00:00Z" },
    { version: "2.4.0", publishedAt: "2026-07-18T00:00:00Z" },
    { version: "2.4.1", publishedAt: "2026-07-24T00:00:00Z" },
  ];
  const out = selectReleases(published, [
    usage("2.4.2", 10),
    usage("2.4.1", 440),
    usage("2.4.0", 410),
    usage("2.3.2", 140),
  ]);
  assert.equal(out.releases[0].version, "2.4.2", "newest leads even at ~1% share");
  assert.deepEqual(out.releases.map((r) => r.version), ["2.4.2", "2.4.1", "2.4.0"]);
  assert.ok(out.coverage >= 0.8, `expected >=80% coverage, got ${out.coverage}`);
  assert.equal(out.capReached, false);
});

test("selectReleases: cap stops selection, and equal shares break toward the newer version", () => {
  // The tied group SHARES one publishedAt, so the publication-date sort cannot
  // decide their order and only the newer-version tie-break can. With distinct
  // dates this assertion passes even with the tie-break deleted - verified by
  // negative control - so identical timestamps are what makes it bite.
  const TIED_AT = "2026-06-01T00:00:00Z";
  const published = [
    { version: "2.3.1", publishedAt: TIED_AT },
    { version: "2.4.0", publishedAt: TIED_AT },
    { version: "2.2.0", publishedAt: TIED_AT },
    { version: "2.5.0", publishedAt: "2026-07-20T00:00:00Z" },
    { version: "2.3.2", publishedAt: TIED_AT },
    { version: "2.4.1", publishedAt: TIED_AT },
  ];
  // Every non-newest release also has an IDENTICAL share, and the rows are
  // scrambled. Asserting length alone would pass with no tie-break at all.
  const out = selectReleases(published, [
    usage("2.3.1", 100),
    usage("2.4.0", 100),
    usage("2.2.0", 100),
    usage("2.5.0", 1),
    usage("2.3.2", 100),
    usage("2.4.1", 100),
  ]);
  assert.equal(out.releases.length, 4);
  assert.deepEqual(
    out.releases.map((r) => r.version),
    ["2.5.0", "2.4.1", "2.4.0", "2.3.2"],
    "newest first, then equal shares ordered by newer version"
  );
  assert.ok(out.coverage < 0.8, `expected <80%, got ${out.coverage}`);
  assert.equal(out.capReached, true, "must say the cap stopped us short of the target");

  // Using all four slots is NOT a degraded state when coverage is already met.
  const met = selectReleases(
    ["2.5.0", "2.4.1", "2.4.0", "2.3.2", "2.3.1"].map((v, i) => ({
      version: v,
      publishedAt: `2026-0${7 - i}-01T00:00:00Z`,
    })),
    [usage("2.5.0", 25), usage("2.4.1", 25), usage("2.4.0", 25), usage("2.3.2", 20), usage("2.3.1", 5)]
  );
  assert.equal(met.releases.length, 4);
  assert.ok(met.coverage >= 0.8, `expected >=80%, got ${met.coverage}`);
  assert.equal(met.capReached, false, "four slots at or above target is not a cap failure");
});

test("selectReleases: a newest release with NO events is 'no data', never an observed zero", () => {
  const out = selectReleases(
    [
      { version: "2.4.2", publishedAt: "2026-07-29T00:00:00Z" },
      { version: "2.4.1", publishedAt: "2026-07-24T00:00:00Z" },
    ],
    [usage("2.4.1", 500)]
  );
  const newest = out.releases[0];
  assert.equal(newest.version, "2.4.2");
  assert.equal(newest.observed, false, "absent from telemetry must be distinguishable from zero");
  assert.equal(newest.dictations, 0);
  // A release that IS present with zero is a genuine measured zero.
  const measured = selectReleases(
    [
      { version: "2.4.2", publishedAt: "2026-07-29T00:00:00Z" },
      { version: "2.4.1", publishedAt: "2026-07-24T00:00:00Z" },
    ],
    [usage("2.4.2", 0), usage("2.4.1", 500)]
  );
  assert.equal(measured.releases[0].observed, true);
});

test("selectReleases: coverage denominator includes versions that are never displayed", () => {
  const out = selectReleases(
    [
      { version: "2.4.1", publishedAt: "2026-07-24T00:00:00Z" },
      { version: "2.4.0", publishedAt: "2026-07-18T00:00:00Z" },
    ],
    [usage("2.4.1", 40), usage("2.4.0", 40), usage("2.1.1", 20)]
  );
  assert.equal(out.totalDictations, 100, "unselected 2.1.1 must still count in the denominator");
  assert.ok(Math.abs(out.coverage - 0.8) < 1e-9, `expected 0.8, got ${out.coverage}`);
});

test("selectReleases: day-grain rows for one version are aggregated before share", () => {
  const published = [
    { version: "2.4.1", publishedAt: "2026-07-24T00:00:00Z" },
    { version: "2.4.0", publishedAt: "2026-07-18T00:00:00Z" },
  ];
  // Without aggregation a version's share would be its busiest DAY, not its week.
  const out = selectReleases(published, [
    usage("2.4.1", 10), usage("2.4.1", 10), usage("2.4.1", 10),
    usage("2.4.0", 25),
  ]);
  assert.equal(out.releases.find((r) => r.version === "2.4.1").dictations, 30);
  assert.equal(out.totalDictations, 55);

  // Usage must ATTACH across tag forms, not merely be rejected as a duplicate.
  // A release carried as "v2.4.1" while telemetry says "2.4.1" would otherwise
  // look up an unnormalized key, miss every row, and report 0 dictations and
  // observed:false - a real release rendering as "no production data yet".
  const tagged = selectReleases(
    [
      { version: "v2.4.1", publishedAt: "2026-07-24T00:00:00Z" },
      { version: "v2.4.0", publishedAt: "2026-07-18T00:00:00Z" },
    ],
    // Deliberately below the 80% target on the newest alone, so selection must
    // continue and BOTH releases appear - otherwise this asserts nothing about
    // the second one.
    [usage("2.4.1", 40), usage("2.4.0", 40)]
  );
  assert.deepEqual(tagged.releases.map((r) => r.version), ["2.4.1", "2.4.0"],
    "stored versions must be canonical, not the raw tag form");
  assert.equal(tagged.releases[0].dictations, 40, "usage must attach across tag forms");
  assert.equal(tagged.releases[0].observed, true);
});

test("telemetryContractFor: resolves stable and boundary contracts", () => {
  for (const [metric, version, expected] of [
    ["people", "2.1.1", "people-v1-distinct-successful-dictators"],
    ["speed_p50", "2.4.1", "speed-v1-e2e-seconds"],
    ["speed_p95", "2.4.1", "speed-v1-e2e-seconds"],
    ["transcription_failed", "2.3.2", "trans-v1-prose-codes"],
    ["transcription_failed", "2.4.0", "trans-v2-typed-codes"],
    ["transcription_failed", "2.4.1", "trans-v2-typed-codes"],
    ["polish_kept", "2.1.4", null],
    ["polish_kept", "2.2.0", "polish-v2-fallback-reason"],
    ["polish_kept", "2.3.0", "polish-v2-fallback-reason"],
    ["polish_kept", "2.3.1", "polish-v2-fallback-reason"],
    ["polish_kept", "2.4.1", "polish-v2-fallback-reason"],
  ]) {
    assert.equal(telemetryContractFor(metric, version), expected, `${metric} @ ${version}`);
  }
  assert.throws(() => telemetryContractFor("no_such_metric", "2.4.1"), ReleaseResolutionError);
  // Inherited Object.prototype keys are truthy on any object, so a plain
  // lookup let these past the unknown-metric guard and threw a raw TypeError
  // rather than our typed error.
  for (const inherited of ["constructor", "toString", "__proto__", "hasOwnProperty", "valueOf"]) {
    assert.throws(
      () => telemetryContractFor(inherited, "2.4.1"),
      ReleaseResolutionError,
      `${inherited} must be refused as an unknown metric, with the typed error`
    );
  }
  for (const notAString of [42, null, undefined, {}, ["people"]]) {
    assert.throws(() => telemetryContractFor(notAString, "2.4.1"), ReleaseResolutionError);
  }
  assert.throws(() => telemetryContractFor("people", "not-a-version"), ReleaseResolutionError);
});

test("decideComparability: comparable when every release shares one non-null contract", () => {
  const out = decideComparability("transcription_failed", ["2.4.1", "2.4.0"]);
  assert.equal(out.comparable, true);
  assert.equal(out.contract, "trans-v2-typed-codes");
});

test("decideComparability: not comparable for differing IDs, or for any null ID", () => {
  const changed = decideComparability("transcription_failed", ["2.4.1", "2.3.2"]);
  assert.equal(changed.comparable, false);
  assert.equal(changed.reason, COMPARABILITY_REASONS.definitionChanged);

  // 2.2.0 and 2.3.0 both emit fallback_reason, so they ARE comparable: the
  // table used to claim 2.3.1 and would have marked these non-comparable and
  // dropped their weeks from historical variation.
  const acrossPolishV2 = decideComparability("polish_kept", ["2.3.0", "2.2.0"]);
  assert.equal(acrossPolishV2.comparable, true);

  // Below the floor the metric is genuinely unmeasurable, and null must read as
  // unavailable rather than as a zero.
  const unavailable = decideComparability("polish_kept", ["2.4.1", "2.1.4"]);
  assert.equal(unavailable.comparable, false);
  assert.equal(unavailable.reason, COMPARABILITY_REASONS.definitionUnavailable);

  assert.equal(decideComparability("people", []).comparable, false);
  // null must NOT silently become an empty set: that would report a programming
  // error as a legitimate "definition unavailable" data state.
  // new Array(1) has length 1 and NO element: .map skips the hole, .some never
  // sees it, and the result was comparable:true with an undefined contract.
  for (const bad of [null, undefined, "2.4.1", 42, {}, new Array(1),
                     Object.assign(["2.4.1"], { length: 3 }),
                     protoBackedSparse(2, "2.4.1")]) {
    assert.throws(() => decideComparability("people", bad), ReleaseResolutionError,
      `versions ${JSON.stringify(bad)} must be refused`);
  }
});

test("a release's contract assignment never changes when OTHER releases are added or removed", () => {
  // The rejected design derived comparability from which event codes happened to
  // appear, so changing the displayed set changed a metric with no product
  // change. Chunk 3 can prove the half it owns: each release's own contract is a
  // function of that release alone. (The stronger claim - that metric VALUES are
  // unaffected by the displayed set - needs chunk 4's calculations and is
  // asserted there, not faked here.)
  const metrics = ["transcription_failed", "polish_kept", "people", "speed_p95"];
  const perRelease = {};
  for (const metric of metrics) {
    for (const version of ["2.3.0", "2.3.1", "2.3.2", "2.4.0", "2.4.1"]) {
      perRelease[`${metric}@${version}`] = telemetryContractFor(metric, version);
    }
  }
  // Re-resolve each one while wildly different sets are notionally displayed.
  for (const displayed of [
    ["2.4.1"],
    ["2.4.1", "2.4.0"],
    ["2.4.1", "2.4.0", "2.3.2", "2.3.1", "2.3.0"],
    ["2.3.0", "2.4.1"],
  ]) {
    for (const metric of metrics) {
      for (const version of displayed) {
        assert.equal(
          telemetryContractFor(metric, version),
          perRelease[`${metric}@${version}`],
          `${metric}@${version} changed when the displayed set was ${displayed.join(",")}`
        );
      }
    }
  }
  // And the derived verdict follows only from that set's own contracts.
  assert.equal(decideComparability("transcription_failed", ["2.4.1", "2.4.0"]).comparable, true);
  assert.equal(decideComparability("transcription_failed", ["2.4.1", "2.3.2"]).comparable, false);
});

// ---- #1838 chunk 4: scorecard measurement engine ---------------------------
// Two queries, deliberately. Additive counts at day grain are freely summable;
// people and percentiles are computed by PostHog at WINDOW grain because they
// cannot be derived from daily rows at all.

const ANCHOR = "2026-07-29"; // resolved window end, exclusive
const SQL_ARGS = { prod: "env='production'", historyStart: "'2026-06-03 00:00:00'",
                   windowEndExclusive: "'2026-07-29 00:00:00'" };

/** Day N days before the anchor (0 = the day immediately before it). */
function dayBefore(n) {
  const d = new Date(Date.UTC(2026, 6, 29) - (n + 1) * 86400000);
  return d.toISOString().slice(0, 10);
}
const addRow = (day, version, over, extra = {}) => ({
  day, app_version: version, total_group_rows: over,
  dictations: 0, paste_attempts: 0, paste_fallbacks: 0, afm_attempts: 0,
  afm_discards: 0, afm_classifier_discards: 0, terminal_failures: 0, ...extra,
});
const naRow = (windowIndex, version, over, extra = {}) => ({
  window_index: windowIndex, app_version: version, total_group_rows: over,
  people: 0, dictations: 0, speed_samples: 0, speed_p50: null, speed_p95: null, ...extra,
});

test("scorecardSql: renders both templates from the RESOLVED anchor, never the clock", () => {
  const additive = scorecardSql("additive", SQL_ARGS);
  const nonAdditive = scorecardSql("nonAdditive", SQL_ARGS);
  for (const sql of [additive, nonAdditive]) {
    assert.ok(!sql.includes("now()"), "no query may anchor to now() - it breaks backfilled runs");
    assert.ok(!sql.includes("${"), "every placeholder must be rendered");
    assert.ok(sql.includes("America/New_York"), "windows are Eastern calendar days");
    assert.ok(sql.includes("count() OVER ()"), "completeness needs the true group count");
    assert.ok(sql.includes("LIMIT 5000"));
  }
  assert.ok(nonAdditive.includes("intDiv(dateDiff("), "window index derived in-query");
  // String#replaceAll interprets `$&`, "$`" and `$'` inside a STRING
  // replacement, so a predicate containing them would render the placeholder
  // back into the SQL instead of the predicate - a silently wrong query against
  // a silently wrong population.
  for (const token of ["$&", "$`", "$'", "$$"]) {
    const predicate = `env='production' AND note='${token}'`;
    const rendered = scorecardSql("additive", { ...SQL_ARGS, prod: predicate });
    assert.ok(rendered.includes(predicate),
      `predicate containing ${token} must render literally, got: ${rendered.slice(0, 200)}`);
    assert.ok(!rendered.includes("${prod}"), `${token} must not resurrect the placeholder`);
  }
  assert.throws(() => scorecardSql("nope", SQL_ARGS), ReleaseResolutionError);
  for (const bad of [{ ...SQL_ARGS, prod: "" }, { ...SQL_ARGS, historyStart: 42 },
                     { ...SQL_ARGS, windowEndExclusive: null }]) {
    assert.throws(() => scorecardSql("additive", bad), ReleaseResolutionError);
  }
});

test("query 1 CANNOT expose people or percentiles - the non-additive law in SQL shape", () => {
  const additive = scorecardSqlTemplate("additive");
  for (const forbidden of ["uniqExact", "quantile", "people", "speed_p50", "speed_p95",
                           "speed_samples"]) {
    assert.ok(!additive.includes(forbidden),
      `the additive query must not compute ${forbidden} - it is not summable across days`);
  }
  const nonAdditive = scorecardSqlTemplate("nonAdditive");
  for (const required of ["uniqExact(distinct_id)", "quantileIf(0.50)", "quantileIf(0.95)"]) {
    assert.ok(nonAdditive.includes(required), `the window query must compute ${required}`);
  }
  // And the additive query must not silently acquire them later either.
  assert.ok(!additive.includes("distinct_id"), "no distinct-count of any kind at day grain");
});

test("assertCompleteScorecardRows: rejects truncation, disagreement and empty results", () => {
  assertCompleteScorecardRows([addRow(dayBefore(0), "2.4.1", 1)], "additive");
  // PostHog silently caps results; a truncated response renders as a healthy
  // report with missing history, so it must never be absorbed.
  assert.throws(() => assertCompleteScorecardRows([addRow(dayBefore(0), "2.4.1", 2)], "additive"),
    /truncated: received 1 of 2/);
  assert.throws(() => assertCompleteScorecardRows(
    [addRow(dayBefore(0), "2.4.1", 2), addRow(dayBefore(1), "2.4.1", 3)], "additive"),
    /disagree on total_group_rows/);
  assert.throws(() => assertCompleteScorecardRows([], "additive"), /returned no rows/);
  for (const bad of [null, undefined, "rows", new Array(1), 42,
                     [{ ...addRow(dayBefore(0), "2.4.1", 1), total_group_rows: 0 }],
                     [{ ...addRow(dayBefore(0), "2.4.1", 1), total_group_rows: 1.5 }],
                     [{ ...addRow(dayBefore(0), "2.4.1", 1), total_group_rows: "1" }]]) {
    assert.throws(() => assertCompleteScorecardRows(bad, "additive"), ReleaseResolutionError,
      `expected refusal for ${JSON.stringify(bad)}`);
  }
});

test("both responses are validated INDEPENDENTLY for truncation", () => {
  const good = { additiveRows: [addRow(dayBefore(0), "2.4.1", 1, { dictations: 5 })],
                 nonAdditiveRows: [naRow(0, "2.4.1", 1, { people: 3, dictations: 5 })],
                 windowEndExclusive: ANCHOR };
  assert.ok(buildMeasurements(good));
  assert.throws(() => buildMeasurements({ ...good,
    additiveRows: [addRow(dayBefore(0), "2.4.1", 9, { dictations: 5 })] }), /additive truncated/);
  assert.throws(() => buildMeasurements({ ...good,
    nonAdditiveRows: [naRow(0, "2.4.1", 9, { people: 3, dictations: 5 })] }),
    /non-additive truncated/);
});

test("windows are eight consecutive, non-overlapping, exactly-7-Eastern-day buckets", () => {
  const rows = [];
  for (let d = 0; d < 56; d += 1) rows.push(addRow(dayBefore(d), "2.4.1", 56, { dictations: 1 }));
  // Every window carrying additive dictations needs its window-grain row: a
  // version with real usage and no window row would otherwise render as
  // unmeasured while it was in fact being used.
  const naRows = [];
  for (let w = 0; w < WINDOW_COUNT; w += 1) {
    naRows.push(naRow(w, "2.4.1", WINDOW_COUNT, { dictations: 7, people: 1 }));
  }
  const out = buildMeasurements({ additiveRows: rows, nonAdditiveRows: naRows,
    windowEndExclusive: ANCHOR });
  assert.equal(out.windows.size, WINDOW_COUNT);
  for (let w = 0; w < WINDOW_COUNT; w += 1) {
    assert.equal(out.windows.get(w).versions.get("2.4.1").dictations.value, 7,
      `window ${w} must hold exactly 7 days`);
  }
});

test("BACKFILL anchor: window 0 cannot absorb dates after its target, nor become 13 days", () => {
  // The defect this proves: anchoring to now() made a backfilled window 0 span
  // 2026-07-08..07-20 - thirteen days straddling the target, including events
  // from AFTER it - because days past the anchor give a negative dateDiff that
  // intDiv folds into window zero.
  const backfill = "2026-07-16";
  const rows = [];
  for (let d = 0; d < 7; d += 1) {
    const day = new Date(Date.UTC(2026, 6, 16) - (d + 1) * 86400000).toISOString().slice(0, 10);
    rows.push(addRow(day, "2.4.1", 8, { dictations: 1 }));
  }
  rows.push(addRow("2026-07-16", "2.4.1", 8, { dictations: 1 })); // AT the anchor
  assert.throws(
    () => buildMeasurements({ additiveRows: rows, nonAdditiveRows:
      [naRow(0, "2.4.1", 1, { dictations: 7, people: 1 })], windowEndExclusive: backfill }),
    /falls at or after the window anchor/
  );
  const ok = buildMeasurements({ additiveRows: rows.slice(0, 7).map((r) =>
    ({ ...r, total_group_rows: 7 })), nonAdditiveRows:
    [naRow(0, "2.4.1", 1, { dictations: 7, people: 1 })], windowEndExclusive: backfill });
  assert.equal(ok.windows.get(0).versions.get("2.4.1").dictations.value, 7);
  assert.equal(ok.windows.get(1).versions.size, 0, "nothing may leak into window 1");
});

test("NON-ADDITIVE LAW: window people/p95 come from query 2, never a daily rollup", () => {
  // Synthetic event-level truth: ONE person dictating on 3 days, with wildly
  // different daily latency distributions.
  const dailyPeople = [1, 1, 1];       // sums to 3
  const trueWindowPeople = 1;          // the SAME person all three days
  const dailyP95 = [1.0, 2.0, 9.0];    // mean 4.0
  const trueWindowP95 = 6.5;           // the real 95th percentile of the pooled sample
  assert.ok(trueWindowPeople < dailyPeople.reduce((a, b) => a + b, 0),
    "true distinct people MUST be strictly less than the sum of daily distincts");
  assert.notEqual(trueWindowP95, dailyP95.reduce((a, b) => a + b, 0) / dailyP95.length,
    "true window p95 MUST differ from the mean of daily p95s");

  const additiveRows = [0, 1, 2].map((d) => addRow(dayBefore(d), "2.4.1", 3, { dictations: 10 }));
  const out = buildMeasurements({
    additiveRows,
    nonAdditiveRows: [naRow(0, "2.4.1", 1, { people: trueWindowPeople, dictations: 30,
      speed_samples: 30, speed_p50: 2.0, speed_p95: trueWindowP95 })],
    windowEndExclusive: ANCHOR,
  });
  const m = out.windows.get(0).versions.get("2.4.1");
  assert.equal(m.people.value, trueWindowPeople, "people must come from the window query");
  assert.equal(m.speed_p95.value, trueWindowP95, "p95 must come from the window query");
  assert.equal(m.dictations.value, 30, "dictations stay additive");
});

test("the two queries must AGREE on dictations, in every window not just window 0", () => {
  const additiveRows = [addRow(dayBefore(0), "2.4.1", 2, { dictations: 5 }),
                        addRow(dayBefore(8), "2.4.1", 2, { dictations: 4 })];
  const agree = buildMeasurements({ additiveRows, nonAdditiveRows: [
    naRow(0, "2.4.1", 2, { dictations: 5, people: 2 }),
    naRow(1, "2.4.1", 2, { dictations: 4, people: 2 })], windowEndExclusive: ANCHOR });
  assert.ok(agree);
  // A disagreement in a LATER window must still fail: checking only window 0
  // would let a mismatched population through into the mover history.
  assert.throws(() => buildMeasurements({ additiveRows, nonAdditiveRows: [
    naRow(0, "2.4.1", 2, { dictations: 5, people: 2 }),
    naRow(1, "2.4.1", 2, { dictations: 99, people: 2 })], windowEndExclusive: ANCHOR }),
    /queries disagree for window 1/);

  // The agreement must be BIDIRECTIONAL. A version with real additive
  // dictations and NO window-grain row would otherwise render with missing
  // people and speed - silently reported as unmeasured while it was being used.
  assert.throws(() => buildMeasurements({ additiveRows, nonAdditiveRows:
    [naRow(0, "2.4.1", 1, { dictations: 5, people: 2 })], windowEndExclusive: ANCHOR }),
    /has 4 additive dictations but no non-additive row/);

  // Query 2 carries HAVING dictations > 0, so a zero row did not come from it.
  assert.throws(() => buildMeasurements({
    additiveRows: [addRow(dayBefore(0), "2.4.1", 1, { dictations: 0 })],
    nonAdditiveRows: [naRow(0, "2.4.1", 1, { dictations: 0, people: 0 })],
    windowEndExclusive: ANCHOR }), /dictations must exceed 0/);
});

test("zero denominators and zero samples are MISSING, never a fabricated zero", () => {
  // Query 2 carries `HAVING dictations > 0`, so a version with no successful
  // dictations returns NO window row at all - which is exactly why people and
  // speed must read as missing rather than zero.
  const out = buildMeasurements({
    additiveRows: [addRow(dayBefore(0), "2.4.1", 2, { dictations: 0 }),
                   addRow(dayBefore(0), "2.4.0", 2, { dictations: 3 })],
    nonAdditiveRows: [naRow(0, "2.4.0", 1, { dictations: 3, people: 2 })],
    windowEndExclusive: ANCHOR,
  });
  const m = out.windows.get(0).versions.get("2.4.1");
  assert.equal(m.people.value, null, "no window row means people is missing, not zero");
  for (const key of ["autopaste_direct", "polish_kept", "transcription_failed",
                     "speed_p50", "speed_p95"]) {
    assert.equal(m[key].value, null, `${key} must be missing, not 0`);
    assert.ok(typeof m[key].missing === "string" && m[key].missing.length > 0,
      `${key} must say WHY it is missing`);
    assert.ok(!Number.isNaN(m[key].value), `${key} must never be NaN`);
  }
});

test("metric values are computed from the approved definitions", () => {
  const out = buildMeasurements({
    additiveRows: [addRow(dayBefore(0), "2.4.1", 1, {
      dictations: 100, paste_attempts: 100, paste_fallbacks: 2,
      afm_attempts: 50, afm_discards: 8, afm_classifier_discards: 7, terminal_failures: 25 })],
    nonAdditiveRows: [naRow(0, "2.4.1", 1, { dictations: 100, people: 40,
      speed_samples: 100, speed_p50: 0.8, speed_p95: 5.9 })],
    windowEndExclusive: ANCHOR,
  });
  const m = out.windows.get(0).versions.get("2.4.1");
  assert.equal(m.autopaste_direct.value, 0.98);
  assert.equal(m.polish_kept.value, 0.84);
  assert.equal(m.polish_kept.classifierDiscards, 7);
  assert.equal(m.polish_kept.otherDiscards, 1);
  assert.equal(m.transcription_failed.value, 25 / 125);
  assert.equal(m.people.value, 40);
  assert.equal(m.speed_p50.value, 0.8);
  assert.equal(m.dictations.shareOfWindow, 1);
});

test("impossible cross-field relationships are refused", () => {
  const base = { nonAdditiveRows: [naRow(0, "2.4.1", 1, { dictations: 5, people: 3 })],
                 windowEndExclusive: ANCHOR };
  const cases = [
    [{ dictations: 5, paste_attempts: 1, paste_fallbacks: 2 }, /paste_fallbacks exceeds/],
    [{ dictations: 5, afm_attempts: 1, afm_discards: 2 }, /afm_discards exceeds/],
    [{ dictations: 5, afm_attempts: 5, afm_discards: 1, afm_classifier_discards: 2 },
      /afm_classifier_discards exceeds/],
  ];
  for (const [extra, pattern] of cases) {
    assert.throws(() => buildMeasurements({ ...base,
      additiveRows: [addRow(dayBefore(0), "2.4.1", 1, extra)] }), pattern);
  }
  assert.throws(() => buildMeasurements({ additiveRows:
    [addRow(dayBefore(0), "2.4.1", 1, { dictations: 5 })],
    nonAdditiveRows: [naRow(0, "2.4.1", 1, { dictations: 5, people: 9 })],
    windowEndExclusive: ANCHOR }), /people exceeds dictations/);
  assert.throws(() => buildMeasurements({ additiveRows:
    [addRow(dayBefore(0), "2.4.1", 1, { dictations: 5 })],
    nonAdditiveRows: [naRow(0, "2.4.1", 1, { dictations: 5, people: 1, speed_samples: 9 })],
    windowEndExclusive: ANCHOR }), /speed_samples exceeds dictations/);
});

test("the PostHog response boundary refuses every silent-acceptance mechanism", () => {
  const ok = { additiveRows: [addRow(dayBefore(0), "2.4.1", 1, { dictations: 1 })],
               nonAdditiveRows: [naRow(0, "2.4.1", 1, { dictations: 1, people: 1 })],
               windowEndExclusive: ANCHOR };
  const bad = [
    [{ ...ok, windowEndExclusive: "2026-02-30" }, "impossible calendar date"],
    [{ ...ok, windowEndExclusive: "July 29, 2026" }, "non-canonical date"],
    [{ ...ok, windowEndExclusive: 20260729 }, "non-string anchor"],
    [{ ...ok, additiveRows: [addRow("2026-02-30", "2.4.1", 1)] }, "impossible day"],
    [{ ...ok, additiveRows: [addRow(dayBefore(0), "v2.4.1x", 1)] }, "malformed version"],
    [{ ...ok, additiveRows: [addRow(dayBefore(0), "2.4.1", 1, { dictations: "5" })] }, "coerced count"],
    [{ ...ok, additiveRows: [addRow(dayBefore(0), "2.4.1", 1, { dictations: -1 })] }, "negative"],
    [{ ...ok, additiveRows: [addRow(dayBefore(0), "2.4.1", 1, { dictations: 1.5 })] }, "fraction"],
    [{ ...ok, additiveRows: [addRow(dayBefore(0), "2.4.1", 1, { dictations: Infinity })] }, "infinity"],
    [{ ...ok, additiveRows: [addRow(dayBefore(0), "2.4.1", 2), addRow(dayBefore(0), "2.4.1", 2)] },
      "duplicate day/version key"],
    [{ ...ok, nonAdditiveRows: [naRow(WINDOW_COUNT, "2.4.1", 1, { dictations: 1 })] },
      "window index out of range"],
    [{ ...ok, nonAdditiveRows: [naRow(-1, "2.4.1", 1, { dictations: 1 })] }, "negative window"],
    [{ ...ok, nonAdditiveRows: [naRow(0, "2.4.1", 1, { dictations: 1, people: 1,
      speed_samples: 1, speed_p50: 2, speed_p95: 1 })] }, "p95 below p50"],
    [{ ...ok, additiveRows: new Array(1) }, "sparse"],
    [{ ...ok, additiveRows: [null] }, "null row"],
    // Inherited fields: a row whose PROTOTYPE supplies every column reads as
    // complete while owning nothing, and those values then flow into real
    // measurements.
    [{ ...ok, additiveRows: [Object.create(addRow(dayBefore(0), "2.4.1", 1, { dictations: 1 }))] },
      "prototype-backed additive row"],
    [{ ...ok, nonAdditiveRows: [Object.create(naRow(0, "2.4.1", 1, { dictations: 1, people: 1 }))] },
      "prototype-backed non-additive row"],
    // Aggregate arithmetic beyond the safe-integer range silently loses
    // precision and then divides into shares and rates.
    [{ additiveRows: [
        addRow(dayBefore(0), "2.4.1", 2, { dictations: Number.MAX_SAFE_INTEGER - 1 }),
        addRow(dayBefore(0), "2.4.0", 2, { dictations: Number.MAX_SAFE_INTEGER - 1 })],
       nonAdditiveRows: [
        naRow(0, "2.4.1", 2, { dictations: Number.MAX_SAFE_INTEGER - 1, people: 1 }),
        naRow(0, "2.4.0", 2, { dictations: Number.MAX_SAFE_INTEGER - 1, people: 1 })],
       windowEndExclusive: ANCHOR }, "cross-version dictation overflow"],
    [{ additiveRows: [addRow(dayBefore(0), "2.4.1", 1, {
        dictations: Number.MAX_SAFE_INTEGER - 1, terminal_failures: Number.MAX_SAFE_INTEGER - 1 })],
       nonAdditiveRows: [naRow(0, "2.4.1", 1, {
        dictations: Number.MAX_SAFE_INTEGER - 1, people: 1 })],
       windowEndExclusive: ANCHOR }, "transcription denominator overflow"],
  ];
  for (const [input, label] of bad) {
    assert.throws(() => buildMeasurements(input), ReleaseResolutionError, `must refuse: ${label}`);
  }
});

test("calculationId is stable under formatting and independent of rendered values", async () => {
  // FROZEN BASELINE. Self-derived once, then independently reproduced by the
  // reviewer using Node's separate createHash implementation - so this is a
  // second implementation agreeing, not an oracle agreeing with itself. Its job
  // is to make later SEMANTIC drift visible: if a query's meaning changes and
  // nobody bumps a definition, one of these stops matching.
  const FROZEN = {
    people: "sha256:c69cd94d49fb654f28078b98879ce94f3ab5ba61f88e2930904c00ca3cb3b403",
    dictations: "sha256:d20ab223c879bf71a5f0b187cc62772522be0fb674eb45d7000c5d3122821b53",
    speed_p50: "sha256:8a4da84fcbdda2531a9027cbb7eb9534072dc2cccc06d64e824f27948f9f94e2",
    speed_p95: "sha256:757c4e9dee47c5f111d5ab9607a6c9e21ccff347b3105deb47ddb5c8d245d2a1",
    autopaste_direct: "sha256:6c11fc48f2ac8ee1fb5384b953b4fd4dc03d1ab30575fa1571945818787de912",
    polish_kept: "sha256:1fb2bd4239d81cdfe52f2f5320447d33d6bbdcc87aa91b6804dc1d15503ab4a3",
    transcription_failed: "sha256:512754ab0f3d3925e37e6ac22ac90b0c89f8d2a45d1c5cf10ceb52f7a7418c3b",
  };
  for (const [metric, expected] of Object.entries(FROZEN)) {
    assert.equal(await calculationId(metric), expected, `${metric} calculation drifted`);
  }
  assert.equal(Object.keys(FROZEN).length, Object.keys(METRIC_CALCULATIONS).length,
    "every declared metric must carry a frozen calculation id");

  const id = await calculationId("polish_kept");
  assert.match(id, /^sha256:[0-9a-f]{64}$/);
  // Two different renderings of the same template must not change the identity:
  // the hash covers the TEMPLATE, not dates, dev ids or the production predicate.
  const again = await calculationId("polish_kept");
  assert.equal(id, again);
  // Metrics reading different queries must differ; metrics sharing a query and
  // differing in declaration must also differ.
  assert.notEqual(await calculationId("polish_kept"), await calculationId("speed_p95"));
  assert.notEqual(await calculationId("speed_p50"), await calculationId("speed_p95"));
  await assert.rejects(() => calculationId("no_such_metric"), ReleaseResolutionError);
  for (const inherited of ["constructor", "toString", "__proto__"]) {
    await assert.rejects(() => calculationId(inherited), ReleaseResolutionError);
  }
});

test("METRIC_CALCULATIONS is a separate authority from METRIC_CONTRACTS", () => {
  const metrics = ["people", "dictations", "speed_p50", "speed_p95", "autopaste_direct",
                   "polish_kept", "transcription_failed"];
  for (const key of metrics) {
    const c = METRIC_CALCULATIONS[key];
    assert.ok(c, `${key} must declare a calculation`);
    for (const field of ["population", "numerator", "denominator", "aggregation", "unit", "source"]) {
      assert.ok(typeof c[field] === "string" && c[field].length > 0,
        `${key}.${field} must be declared`);
    }
    assert.ok(["additive", "nonAdditive"].includes(c.source));
    // The two authorities answer different questions and must not be merged:
    // one describes what an APP RELEASE emitted, the other how the WORKER
    // computes today. Blurring them would let a worker refactor rewrite release
    // history.
    assert.ok(!("from" in c) && !("id" in c),
      `${key} calculation must not carry telemetry-contract fields`);
  }
  // people and percentiles must be sourced from the window query, by declaration.
  assert.equal(METRIC_CALCULATIONS.people.source, "nonAdditive");
  assert.equal(METRIC_CALCULATIONS.speed_p95.source, "nonAdditive");
  assert.equal(METRIC_CALCULATIONS.polish_kept.source, "additive");
  // Context rows must not be mover-eligible: adoption shifts must never compete
  // with product-performance changes.
  assert.equal(METRIC_CALCULATIONS.people.moverEligible, false);
  assert.equal(METRIC_CALCULATIONS.dictations.moverEligible, false);
});

// ---- #1838 chunk 5: movers and scorecard presentation ---------------------
// The report is a SCORECARD, not an alarm. Movers guide the eye; they never
// render a verdict, and nothing here carries a threshold or a health state.

const ANCHOR_MS = Date.UTC(2026, 6, 29);
const rel = (v, publishedAt) => ({ version: v, publishedAt, observed: true, dictations: 100 });
const stamp = (daysBeforeAnchor) =>
  new Date(ANCHOR_MS - daysBeforeAnchor * 86400000).toISOString().replace(/\.\d{3}Z$/, "Z");

/** Builds a measurements-shaped object directly, so mover tests exercise the
 * ranker rather than re-running the measurement engine. */
function fakeMeasurements(spec, opts = {}) {
  const windows = new Map();
  for (let w = 0; w < WINDOW_COUNT; w += 1) {
    const versions = new Map();
    for (const [version, perWindow] of Object.entries(spec)) {
      const v = perWindow[w];
      if (v === undefined) continue;
      const bump = opts.contextSwing && version === Object.keys(spec)[0] ? 1e6 : 0;
      versions.set(version, {
        // Context rows carry a denominator deliberately: without it, sample
        // disclosure alone would exclude them and the moverEligible check would
        // never be exercised.
        people: { value: 10 + bump, missing: null, denominator: 100 },
        dictations: { value: 100 + bump, missing: null, shareOfWindow: 0.5, denominator: 200 },
        speed_p50: { value: 1, missing: null, samples: 100 },
        speed_p95: v === null
          ? { value: null, missing: "no timed dictations" }
          : { value: v, missing: null, samples: 100 },
        autopaste_direct: { value: 0.98, missing: null, numerator: 98, denominator: 100 },
        polish_kept: { value: 0.84, missing: null, numerator: 84, denominator: 100,
                       classifierDiscards: 7, otherDiscards: 1 },
        transcription_failed: { value: 0.01, missing: null, numerator: 1, denominator: 100 },
      });
    }
    windows.set(w, { windowIndex: w, versions, totalDictations: 200 });
  }
  return { windows, usageRows: [], windowEndExclusive: "2026-07-29" };
}

test("selection exposes the complete canonical release catalog without changing the displayed set", () => {
  const published = [
    { version: "2.4.1", publishedAt: "2026-07-24T00:00:00Z" },
    { version: "2.4.0", publishedAt: "2026-07-18T00:00:00Z" },
    { version: "2.3.2", publishedAt: "2026-07-10T00:00:00Z" },
    { version: "2.3.1", publishedAt: "2026-07-06T00:00:00Z" },
  ];
  const out = selectReleases(published, [usage("2.4.1", 45), usage("2.4.0", 40),
                                         usage("2.3.2", 10), usage("2.3.1", 5)]);
  assert.deepEqual(out.releases.map((r) => r.version), ["2.4.1", "2.4.0"],
    "displayed set must be unchanged by the catalog addition");
  // History pools same-contract releases that are NOT displayed: a two-release
  // history is far too thin to describe normal movement.
  assert.deepEqual(out.releaseCatalog.map((r) => r.version),
    ["2.4.1", "2.4.0", "2.3.2", "2.3.1"]);
  for (const entry of out.releaseCatalog) {
    assert.ok(!("publishedMs" in entry), "internal fields must not leak into the catalog");
  }
});

test("release age counts Eastern publication days and clamps to zero through seven", () => {
  const at = (iso) => Date.parse(iso);
  // Anchor is 2026-07-29 exclusive, so window 0 is Eastern July 22..28.
  for (const [iso, expected, why] of [
    ["2026-07-28T12:00:00Z", 1, "published on the last day of the window"],
    // 02:00 UTC is 22:00 EASTERN THE PREVIOUS DAY. Flooring to UTC days read
    // this as July 29 and reported zero; in Eastern terms it is July 28, so it
    // was publicly available for one day of the window.
    ["2026-07-29T02:00:00Z", 1, "22:00 Eastern on the last day"],
    ["2026-07-27T12:00:00Z", 2, "two days"],
    ["2026-07-22T12:00:00Z", 7, "first day of the window"],
    ["2026-07-22T04:00:00Z", 7, "exactly Eastern midnight on the first day"],
    ["2026-07-01T12:00:00Z", 7, "long before the window, clamped to 7"],
    ["2026-07-29T12:00:00Z", 0, "published at the anchor, not yet in the window"],
  ]) {
    assert.equal(releaseAgeInWindow(at(iso), ANCHOR_MS), expected, `${iso}: ${why}`);
  }
  // A malformed instant must fail loudly rather than default to a confident 7/7.
  assert.throws(() => releaseAgeInWindow(NaN, ANCHOR_MS), ReleaseResolutionError);
});

test("historical windows require full release availability", () => {
  // The decisive case: published at NOON Eastern on a window's first day. The
  // release existed for most of that week, which is exactly why it is tempting
  // to count it, but it missed part of the window so its value is not a
  // like-for-like weekly observation. Only publication at or before Eastern
  // midnight on the first day qualifies.
  //
  // The fixture gives 2.4.0 values in EXACTLY four windows (4..7), which is the
  // minimum for normalisation. Excluding window 7 therefore drops it to three
  // observations and two adjacent differences, and the basis must visibly
  // change from normalised to raw. A median comparison would not discriminate
  // here: medians are robust, and dropping one difference leaves it unchanged.
  //
  // 2.4.1 is deliberately given ONE window. Historical variation pools every
  // same-contract catalog release, so an eight-window 2.4.1 series fed its own
  // observations into the same pool: measured, that padding carried sufficiency
  // on its own, and this test could have passed without 2.4.0's window count
  // mattering at all. One window supplies the comparison value and contributes
  // ZERO adjacent differences, so the basis flip below is attributable to 2.4.0
  // and nothing else. Sufficiency needs three differences; 2.4.0 supplies
  // exactly three with window 3 counted and two without it.
  const boundarySpec = {
    "2.4.1": [5, undefined, undefined, undefined, undefined, undefined, undefined, undefined],
    // Values in windows 0..3 only: window 0 supplies the comparison, and all
    // four together are the minimum for normalisation.
    "2.4.0": [1, 3, 1, 3, undefined, undefined, undefined, undefined],
  };
  const mB = fakeMeasurements(boundarySpec);
  // Window 3 starts 28 days before the anchor; Eastern midnight is 04:00Z (EDT),
  // noon Eastern is 16:00Z.
  const w7Midnight = new Date(ANCHOR_MS - 28 * 86400000 + 4 * 3600000)
    .toISOString().replace(/\.\d{3}Z$/, "Z");
  const w7Noon = new Date(ANCHOR_MS - 28 * 86400000 + 16 * 3600000)
    .toISOString().replace(/\.\d{3}Z$/, "Z");
  const basisFor = (publishedAt) => {
    const out = rankMovers({ measurements: mB, selection: {
      releases: [rel("2.4.1", w7Midnight), rel("2.4.0", publishedAt)],
      releaseCatalog: [{ version: "2.4.1", publishedAt: w7Midnight },
                       { version: "2.4.0", publishedAt }],
      coverage: 0.9, capReached: false } });
    return out.movers.find((m) => m.metricKey === "speed_p95")?.basis ?? "absent";
  };
  assert.equal(basisFor(w7Midnight), "median-historical-movement",
    "Eastern midnight on the first day makes that window a complete observation");
  assert.equal(basisFor(w7Noon), "raw-absolute-movement",
    "a noon publication must NOT count that window, dropping below sufficiency");

  const spec = { "2.4.1": [5, 5, 5, 5, 5, 5, 5, 5], "2.4.0": [1, 2, 1, 2, 1, 2, 1, 2] };
  const measurements = fakeMeasurements(spec);
  // 2.4.0 published mid-history: windows before it existed cannot contribute.
  const selection = {
    releases: [rel("2.4.1", stamp(30)), rel("2.4.0", stamp(21))],
    releaseCatalog: [{ version: "2.4.1", publishedAt: stamp(30) },
                     { version: "2.4.0", publishedAt: stamp(21) }],
    coverage: 0.9, capReached: false,
  };
  const out = rankMovers({ measurements, selection });
  assert.ok(Array.isArray(out.movers));
  // A release published partway through window 2 contributes windows 0 and 1
  // only; its partial week is not an observation.
  const partial = { ...selection,
    releases: [rel("2.4.1", stamp(30)), rel("2.4.0", stamp(10))],
    releaseCatalog: [{ version: "2.4.1", publishedAt: stamp(30) },
                     { version: "2.4.0", publishedAt: stamp(10) }] };
  const limited = rankMovers({ measurements, selection: partial });
  assert.ok(limited.movers.every((m) => m.basis === "raw-absolute-movement"),
    "too few complete windows must fall back rather than normalise");
});

test("rankMovers compares the first two selected releases and checks every displayed contract", () => {
  const measurements = fakeMeasurements({ "2.4.1": Array(8).fill(5), "2.4.0": Array(8).fill(3) });
  const two = {
    releases: [rel("2.4.1", stamp(40)), rel("2.4.0", stamp(45))],
    releaseCatalog: [{ version: "2.4.1", publishedAt: stamp(40) },
                     { version: "2.4.0", publishedAt: stamp(45) }],
    coverage: 0.9, capReached: false,
  };
  const out = rankMovers({ measurements, selection: two });
  assert.deepEqual(out.comparisonPair, ["2.4.1", "2.4.0"]);

  // A THIRD displayed release on a different telemetry contract makes the row
  // non-comparable even though the compared pair agree.
  // transcription_failed is given a large movement so it WOULD rank if only the
  // compared pair were checked; both 2.4.x releases share the typed-code
  // contract, and only the third displayed release breaks comparability.
  const m3 = fakeMeasurements({ "2.4.1": Array(8).fill(5), "2.4.0": Array(8).fill(3),
                                "2.3.2": Array(8).fill(4) });
  m3.windows.get(0).versions.get("2.4.1").transcription_failed =
    { value: 0.40, missing: null, numerator: 40, denominator: 100 };
  m3.windows.get(0).versions.get("2.4.0").transcription_failed =
    { value: 0.01, missing: null, numerator: 1, denominator: 100 };
  const three = {
    releases: [rel("2.4.1", stamp(40)), rel("2.4.0", stamp(45)), rel("2.3.2", stamp(50))],
    releaseCatalog: three_catalog(),
    coverage: 0.95, capReached: false,
  };
  const out3 = rankMovers({ measurements: m3, selection: three });
  assert.ok(!out3.movers.some((mv) => mv.metricKey === "transcription_failed"),
    "a third release on a different contract must exclude that row from movers");

  // Fewer than two displayed releases: no movers, nothing invented - and the
  // grid must still RENDER. Returning early without row decisions crashed the
  // formatter outright, and one displayed release is a legitimate production
  // state (a fresh release before its predecessor drops off, say).
  const one = { releases: [rel("2.4.1", stamp(40))],
    releaseCatalog: [{ version: "2.4.1", publishedAt: stamp(40) }], coverage: 1, capReached: false };
  const oneRanking = rankMovers({ measurements, selection: one });
  assert.deepEqual(oneRanking.movers, []);
  assert.equal(oneRanking.comparisonPair, null);
  assert.equal(oneRanking.rows.length, 7, 'all seven rows must exist with one release');
  for (const row of oneRanking.rows) {
    assert.equal(row.cells.length, 1, 'one release means one column');
  }
  const oneText = formatScorecard({ ranking: oneRanking }).join('\n');
  assert.match(oneText, /No comparable ranked changes were available/);
  assert.match(oneText, /Dictations ending without a completed transcript/);

  // Duplicate catalog entries multiply observations and can manufacture enough
  // history to normalise a ranking that should fall back.
  const dup = { releases: [rel("2.4.1", stamp(40)), rel("2.4.0", stamp(45))],
    releaseCatalog: [{ version: "2.4.1", publishedAt: stamp(40) },
                     { version: "v2.4.1", publishedAt: stamp(40) }],
    coverage: 0.9, capReached: false };
  assert.throws(() => rankMovers({ measurements, selection: dup }), ReleaseResolutionError,
    'v2.4.1 and 2.4.1 are the SAME release and must be refused as a duplicate');
});
function three_catalog() {
  return [{ version: "2.4.1", publishedAt: stamp(40) },
          { version: "2.4.0", publishedAt: stamp(45) },
          { version: "2.3.2", publishedAt: stamp(50) }];
}

test("mover eligibility consumes METRIC_CALCULATIONS and never admits context rows", () => {
  // People and Dictations swing by a million here and carry valid sample
  // disclosure, so they would DOMINATE the ranking if eligibility were bypassed.
  // Only METRIC_CALCULATIONS.moverEligible keeps adoption out of a performance
  // ranking.
  const measurements = fakeMeasurements(
    { "2.4.1": Array(8).fill(5), "2.4.0": Array(8).fill(3) }, { contextSwing: true });
  const selection = {
    releases: [rel("2.4.1", stamp(40)), rel("2.4.0", stamp(45))],
    releaseCatalog: [{ version: "2.4.1", publishedAt: stamp(40) },
                     { version: "2.4.0", publishedAt: stamp(45) }],
    coverage: 0.9, capReached: false,
  };
  const out = rankMovers({ measurements, selection });
  assert.ok(out.movers.length > 0, "something must rank, or this asserts nothing");
  for (const m of out.movers) {
    assert.notEqual(m.metricKey, "people", "adoption context must never compete with performance");
    assert.notEqual(m.metricKey, "dictations");
    assert.equal(METRIC_CALCULATIONS[m.metricKey].moverEligible, true);
    assert.ok(m.direction === "lower-is-better" || m.direction === "higher-is-better");
  }
});

test("historical variation pools every same-contract catalog release", () => {
  // BOTH DISPLAYED releases have too little history on their own. The history
  // that makes normalisation possible lives ONLY on a third, UNSELECTED
  // same-contract catalog release. If history were restricted to the displayed
  // pair, this must fall back to raw movement.
  const spec = {
    "2.4.1": [10, 5, undefined, undefined, undefined, undefined, undefined, undefined],
    "2.4.0": [4, 3, undefined, undefined, undefined, undefined, undefined, undefined],
    "2.4.2": [4, 5, 4, 5, 4, 5, 4, 5],
  };
  const measurements = fakeMeasurements(spec);
  const selection = {
    releases: [rel("2.4.1", stamp(20)), rel("2.4.0", stamp(20))],
    releaseCatalog: [{ version: "2.4.1", publishedAt: stamp(20) },
                     { version: "2.4.0", publishedAt: stamp(20) },
                     // Not displayed, same contract, and the sole source of the
                     // eight-window history the ranking needs.
                     { version: "2.4.2", publishedAt: stamp(60) }],
    coverage: 0.9, capReached: false,
  };
  const out = rankMovers({ measurements, selection });
  const p95 = out.movers.find((m) => m.metricKey === "speed_p95");
  assert.ok(p95, "speed_p95 should rank");
  assert.equal(p95.basis, "median-historical-movement",
    "an UNSELECTED same-contract catalog release must supply the history");
});

test("historical differences require same-version adjacent complete windows", () => {
  // A gap in the middle must not be bridged: windows 0 and 2 are not adjacent.
  const spec = { "2.4.1": [10, null, 5, null, 10, null, 5, null],
                 "2.4.0": [3, 3, 3, 3, 3, 3, 3, 3] };
  const measurements = fakeMeasurements(spec);
  const selection = {
    releases: [rel("2.4.1", stamp(60)), rel("2.4.0", stamp(60))],
    releaseCatalog: [{ version: "2.4.1", publishedAt: stamp(60) },
                     { version: "2.4.0", publishedAt: stamp(60) }],
    coverage: 0.9, capReached: false,
  };
  const out = rankMovers({ measurements, selection });
  const p95 = out.movers.find((m) => m.metricKey === "speed_p95");
  assert.equal(p95.basis, "raw-absolute-movement",
    "gapped windows yield no adjacent differences, so it must fall back");
});

test("historical sufficiency requires four windows and three adjacent differences", () => {
  // Four observations that are NOT adjacent produce fewer than three diffs.
  const spec = { "2.4.1": [5, null, 5, null, 5, null, 5, null], "2.4.0": [3, 3, 3, 3, 3, 3, 3, 3] };
  const measurements = fakeMeasurements(spec);
  const selection = {
    releases: [rel("2.4.1", stamp(60)), rel("2.4.0", stamp(60))],
    releaseCatalog: [{ version: "2.4.1", publishedAt: stamp(60) },
                     { version: "2.4.0", publishedAt: stamp(60) }],
    coverage: 0.9, capReached: false,
  };
  const p95 = rankMovers({ measurements, selection }).movers.find((m) => m.metricKey === "speed_p95");
  assert.equal(p95.basis, "raw-absolute-movement", "observation count alone must not qualify");
});

test("historical variation uses the median and resists an outlier", () => {
  // Weekly movements of 1,1,1 and one freak 100. Mean would be ~25 and would
  // suppress a real mover; median stays 1.
  const spec = { "2.4.1": [5, 4, 3, 2, 1, 0, 100, 0], "2.4.0": [3, 3, 3, 3, 3, 3, 3, 3] };
  const measurements = fakeMeasurements(spec);
  const selection = {
    releases: [rel("2.4.1", stamp(60)), rel("2.4.0", stamp(60))],
    releaseCatalog: [{ version: "2.4.1", publishedAt: stamp(60) },
                     { version: "2.4.0", publishedAt: stamp(60) }],
    coverage: 0.9, capReached: false,
  };
  const p95 = rankMovers({ measurements, selection }).movers.find((m) => m.metricKey === "speed_p95");
  assert.equal(p95.basis, "median-historical-movement");
  // 2.4.1 contributes weekly movements of 1,1,1,1,1 plus two freak 100s; the
  // companion release contributes a flat history of zeros. Pooled, the median
  // is 0.5. The mean would be about 14.6, which would bury every real mover.
  assert.equal(p95.historicalVariation, 0.5,
    "one freak week must not inflate the denominator");
  assert.ok(p95.historicalVariation < 2,
    "the median must stay near the typical weekly movement, not the outlier");
});

test("zero or insufficient variation uses the explicit raw fallback without epsilon", () => {
  // A perfectly flat history has a median of exactly zero. No epsilon: it falls
  // back rather than dividing by an invented constant.
  const spec = { "2.4.1": [5, 5, 5, 5, 5, 5, 5, 5], "2.4.0": [3, 3, 3, 3, 3, 3, 3, 3] };
  const measurements = fakeMeasurements(spec);
  const selection = {
    releases: [rel("2.4.1", stamp(60)), rel("2.4.0", stamp(60))],
    releaseCatalog: [{ version: "2.4.1", publishedAt: stamp(60) },
                     { version: "2.4.0", publishedAt: stamp(60) }],
    coverage: 0.9, capReached: false,
  };
  const p95 = rankMovers({ measurements, selection }).movers.find((m) => m.metricKey === "speed_p95");
  assert.equal(p95.basis, "raw-absolute-movement");
  assert.equal(p95.historicalVariation, null);
  assert.ok(typeof p95.fallbackReason === "string" && p95.fallbackReason.length > 0);
  assert.ok(Number.isFinite(p95.score), "score must never be Infinity from a zero denominator");
});

test("rankMovers returns a deterministic top two with complete sample disclosure", () => {
  const measurements = fakeMeasurements({ "2.4.1": Array(8).fill(9), "2.4.0": Array(8).fill(3) });
  const selection = {
    releases: [rel("2.4.1", stamp(60)), rel("2.4.0", stamp(60))],
    releaseCatalog: [{ version: "2.4.1", publishedAt: stamp(60) },
                     { version: "2.4.0", publishedAt: stamp(60) }],
    coverage: 0.9, capReached: false,
  };
  const a = rankMovers({ measurements, selection });
  const b = rankMovers({ measurements, selection });
  assert.ok(a.movers.length <= 2, "at most two movers");
  assert.deepEqual(a.movers.map((m) => m.metricKey), b.movers.map((m) => m.metricKey),
    "ranking must be deterministic across identical calls");
  for (const m of a.movers) {
    for (const field of ["newestValue", "previousValue", "signedDifference",
                         "newestSamples", "previousSamples"]) {
      assert.ok(m[field] !== undefined && m[field] !== null, `mover must disclose ${field}`);
    }
    assert.ok(Number.isSafeInteger(m.newestSamples) && Number.isSafeInteger(m.previousSamples));
  }
});

test("mover and formatter boundaries refuse silent acceptance mechanisms", () => {
  const measurements = fakeMeasurements({ "2.4.1": Array(8).fill(5), "2.4.0": Array(8).fill(3) });
  const good = {
    releases: [rel("2.4.1", stamp(60)), rel("2.4.0", stamp(60))],
    releaseCatalog: [{ version: "2.4.1", publishedAt: stamp(60) },
                     { version: "2.4.0", publishedAt: stamp(60) }],
    coverage: 0.9, capReached: false,
  };
  for (const [input, label] of [
    [{ measurements: null, selection: good }, "null measurements"],
    [{ measurements: {}, selection: good }, "measurements without windows"],
    [{ measurements, selection: null }, "null selection"],
    [{ measurements, selection: { ...good, releases: null } }, "non-array releases"],
    [{ measurements, selection: { ...good, releases: new Array(2) } }, "sparse releases"],
    [{ measurements, selection: { ...good, releaseCatalog: new Array(1) } }, "sparse catalog"],
    [{ measurements: { ...measurements, windowEndExclusive: "2026-02-30" }, selection: good },
      "impossible anchor date"],
    // Silent-default paths: each of these previously became "missing data" or a
    // confident zero rather than failing.
    [{ measurements, selection: { ...good,
       releases: [{ version: "2.4.1", publishedAt: "not-a-date" }, rel("2.4.0", stamp(60))] } },
      "malformed publication timestamp"],
    [{ measurements, selection: { ...good,
       releases: [{ version: "2.4.1" }, rel("2.4.0", stamp(60))] } },
      "release missing publishedAt"],
    [{ measurements, selection: { ...good,
       releases: [Object.create(rel("2.4.1", stamp(60))), rel("2.4.0", stamp(60))] } },
      "prototype-backed release fields"],
    [{ measurements: { ...measurements, windows: new Map([[0, measurements.windows.get(0)]]) },
       selection: good }, "incomplete window set"],
    // A displayed release absent from the catalog silently changes real ranking
    // numbers: with it missing, a metric fell back to raw movement scoring 6;
    // with it present it normalised to 12.
    [{ measurements, selection: { ...good, releaseCatalog: [] } },
      "displayed release missing from the catalog"],
    [{ measurements, selection: { ...good,
       releaseCatalog: [{ version: "2.4.1", publishedAt: stamp(60) }] } },
      "second displayed release missing from the catalog"],
    [{ measurements, selection: { ...good,
       releaseCatalog: [{ version: "2.4.1", publishedAt: stamp(59) },
                        { version: "2.4.0", publishedAt: stamp(60) }] } },
      "catalog publication time disagrees with the displayed release"],
    [{ measurements, selection: { ...good, releases: [] } }, "empty displayed set"],
    [{ measurements, selection: { ...good, coverage: 1.5 } }, "coverage above 1"],
    [{ measurements, selection: { ...good, coverage: "0.9" } }, "coverage as a string"],
  ]) {
    assert.throws(() => rankMovers(input), ReleaseResolutionError, `must refuse: ${label}`);
  }
  // A coerced or inherited sample count must not pass as a real disclosure.
  const coerced = fakeMeasurements({ "2.4.1": Array(8).fill(5), "2.4.0": Array(8).fill(3) });
  coerced.windows.get(0).versions.get("2.4.1").speed_p95.samples = "100";
  assert.throws(() => rankMovers({ measurements: coerced, selection: good }),
    ReleaseResolutionError, "a stringified sample count must be refused");

  // A MEASURED value whose disclosure is absent must not silently vanish from
  // the ranking - that hides a broken measurement as an ordinary quiet week.
  const undisclosed = fakeMeasurements({ "2.4.1": Array(8).fill(5), "2.4.0": Array(8).fill(3) });
  delete undisclosed.windows.get(0).versions.get("2.4.1").speed_p95.samples;
  // Asserts the SPECIFIC message: an absent field and a malformed one are
  // different faults, and the numeric check alone would catch both with wording
  // that misdescribes the first. Without this the own-property check is
  // untestable defence-in-depth.
  assert.throws(
    () => rankMovers({ measurements: undisclosed, selection: good }),
    (err) => err instanceof ReleaseResolutionError && /missing its required samples/.test(err.message),
    "an absent sample count must be reported as absent, not as malformed"
  );
});

test("scorecard formatting freezes coverage release age rows reasons and missing data", () => {
  const measurements = fakeMeasurements({ "2.4.1": Array(8).fill(5), "2.3.2": Array(8).fill(3) });
  const selection = {
    releases: [{ ...rel("2.4.1", stamp(3)), observed: true },
               { ...rel("2.3.2", stamp(60)), observed: false }],
    releaseCatalog: [{ version: "2.4.1", publishedAt: stamp(3) },
                     { version: "2.3.2", publishedAt: stamp(60) }],
    coverage: 0.848, capReached: true,
  };
  const ranking = rankMovers({ measurements, selection });
  const text = formatScorecard({ measurements, selection, ranking }).join("\n");

  assert.match(text, /last 7 complete Eastern days/);
  assert.ok(!/[\u2013\u2014]/.test(text),
    "user-facing copy must contain no em-dashes or en-dashes");
  assert.match(text, /84\.8% of measured dictations across 2 releases/,
    "coverage must name its denominator, not just say 'of use'");
  assert.match(text, /newest release is always included/);
  assert.match(text, /4-version cap reached/);
  assert.match(text, /non-additive/, "people counts must be declared non-additive");
  // stamp(3) is 2026-07-26T00:00:00Z, which is 20:00 EASTERN on July 25, so the
  // release was publicly available for July 25-28: FOUR days of window 0. Under
  // the previous UTC flooring this read as three. That difference is the bug.
  assert.match(text, /2\.4\.1: 4\/7 days publicly available/);
  assert.match(text, /no production data yet/, "an unobserved release must say so, not show zero");
  assert.match(text, /Dictations ending without a completed transcript/);
  assert.ok(!text.includes("Transcription failed"),
    "must never label the row as speech-engine reliability");
  assert.match(text, /by the safety classifier/, "classifier split sits under Polish kept");
  // 2.4.1 and 2.3.2 straddle the typed-code boundary, so that row is not
  // comparable - and must still PRINT, with the reason in plain words.
  assert.match(text, /not compared, definition changed between these releases/);
  for (const label of Object.values({ p: "People", d: "Dictations", s: "Typical speed",
      x: "Slowest 5%", a: "Auto-paste landed directly", k: "Polish kept" })) {
    assert.ok(text.includes(label), `row ${label} must be present`);
  }
});

test("ranked-change formatting freezes normalized raw-fallback and unavailable copy", async () => {
  const measurements = fakeMeasurements({ "2.4.1": [9, 1, 2, 1, 2, 1, 2, 1],
                                          "2.4.0": Array(8).fill(3) });
  const selection = {
    releases: [rel("2.4.1", stamp(60)), rel("2.4.0", stamp(60))],
    releaseCatalog: [{ version: "2.4.1", publishedAt: stamp(60) },
                     { version: "2.4.0", publishedAt: stamp(60) }],
    coverage: 0.9, capReached: false,
  };
  const ranking = rankMovers({ measurements, selection });
  const text = formatScorecard({ measurements, selection, ranking }).join("\n");

  assert.match(text, /ranked changes, not alerts/,
    "the section must state plainly that it is not an alarm");
  assert.match(text, /samples\)/, "every mover must disclose both sample counts");
  assert.match(text, /median week-to-week movement|size of change only/,
    "each mover must say which basis ranked it");

  // Prohibited copy: this is a scorecard, not a verdict. The only permitted
  // occurrence of "alert" is the explicit not-alerts statement.
  for (const banned of ["healthy", "unhealthy", "warning", "regression", "improvement",
                        "threshold", "better", "worse"]) {
    assert.ok(!text.toLowerCase().includes(banned), `must not use verdict language: ${banned}`);
  }
  assert.equal((text.toLowerCase().match(/alert/g) || []).length, 1,
    "the only 'alert' must be the not-alerts statement");

  // SOURCE GUARD: the formatter must consume decisions, never re-derive them.
  // Importing a metric authority here would create a second opinion on row
  // order, units or comparability that could silently disagree with the ranker.
  const fs2 = await import("node:fs");
  const fmtSrc = fs2.readFileSync(new URL("../src/report-format.js", import.meta.url), "utf8");
  const codeOnly = fmtSrc
    .split("\n")
    .filter((l) => !l.trimStart().startsWith("*") && !l.trimStart().startsWith("//"))
    .join("\n");
  for (const authority of ["METRIC_CALCULATIONS", "decideComparability", "telemetryContractFor",
                           "METRIC_CONTRACTS"]) {
    assert.ok(!codeOnly.includes(authority),
      `report-format.js must not reference ${authority} - it would become a second authority`);
  }
  assert.ok(!/^import .* from "\.\/version-scorecard\.js"/m.test(codeOnly),
    "the formatter must not import from version-scorecard.js at all");

  const unavailable = formatScorecardUnavailable().join("\n");
  // A missing release age must fail rather than print a confident 0/7 for a
  // release we simply failed to measure.
  const badRanking = { ...ranking, ages: new Map() };
  assert.throws(() => formatScorecard({ ranking: badRanking }), TypeError);

  // The formatter must render the CANONICAL displayed set from the ranker, not
  // the raw selection list. Feeding it a selection whose tags differ must not
  // change a single header: otherwise headers and rows can disagree, or a raw
  // tag reaches the page.
  // The formatter no longer receives the selection at all, so no raw field can
  // reach the page. The real guard is the source check below asserting zero code
  // references; a mutation test here would compare two identical calls and
  // assert nothing, which is the kind of hollow test this suite exists to avoid.
  assert.equal(formatScorecard.length, 1,
    "formatScorecard must take a single argument, so no selection can be passed in");
  assert.throws(() => formatScorecard({ ranking: { ...ranking, summary: undefined } }),
    TypeError, "the formatter must require the canonical release set");

  assert.match(unavailable, /unavailable/);
  assert.match(unavailable, /not a report of zero/);
  // A section describes only ITSELF. Both halves can fail in the same run, and
  // a cross-reference then prints two calm sentences each declaring the other
  // fine (#1838 chunk 6 round 3).
  assert.doesNotMatch(unavailable, /unaffected/);
  for (const leak of ["http", "Error", "https://", "500", "PostHog"]) {
    assert.ok(!unavailable.includes(leak), `failure copy must not leak ${leak}`);
  }
});

// ===========================================================================
// #1838 chunk 6 — orchestration and atomic delivery
// ===========================================================================
//
// One resolved window, one dev-ID resolution, one production predicate, one
// limiter, one payload, one request. Every test below exists because the
// alternative is a report that looks entirely reasonable and is not.

test("a clean run resolves ONE context and posts ONE payload carrying both sections", async () => {
  const mock = mockPostHog({});
  try {
    const content = await runReport(TEST_ENV, "2026-07-17", { hogqlOpts: { sleepFn: async () => {} } });

    assert.equal(mock.discordPayloads.length, 1, "exactly one Discord request");
    const payload = mock.discordPayloads[0];
    assert.equal(payload.content, content);
    assert.equal(payload.content, reportHeader("2026-07-17"));
    assert.equal(payload.embeds.length, 2, "exactly two embeds");
    assert.equal(payload.embeds[0].title, "Adoption");
    assert.match(payload.embeds[1].title, /^Version scorecard/);
    // Real sections, not the unavailable copy.
    assert.match(payload.embeds[0].description, /Total users: 1 people used the app that day\./);
    assert.match(payload.embeds[1].description, /2\.4\.1: 7\/7 days publicly available/);
    assert.match(payload.embeds[1].description, /2\.4\.0: 7\/7 days publicly available/);
    assert.doesNotMatch(payload.embeds[0].description, /unavailable today/);
    assert.doesNotMatch(payload.embeds[1].description, /unavailable today/);
    for (const embed of payload.embeds) {
      assert.ok(embed.description.length > 0, "an embed description is never empty");
      assert.doesNotMatch(embed.description, /[–—]/, "no en-dashes or em-dashes");
    }
  } finally {
    mock.restore();
  }
});

test("a clean run's twelve requests go to the expected queries, repository and webhook", async () => {
  const mock = mockPostHog({});
  try {
    await runReport(TEST_ENV, "2026-07-17", { hogqlOpts: { sleepFn: async () => {} } });

    assert.equal(mock.requests.length, 12);
    const posthog = mock.requests.filter((u) => u.includes("posthog.com"));
    const github = mock.requests.filter((u) => u.startsWith(GITHUB_HOST));
    const discord = mock.requests.filter((u) => u === TEST_ENV.DISCORD_WEBHOOK_URL);
    assert.equal(posthog.length, 10, "1 dev-ID + 7 adoption + 2 scorecard");
    assert.equal(github.length, 1, "the release list is fetched exactly once");
    assert.equal(discord.length, 1, "one delivery");
    assert.equal(posthog.length + github.length + discord.length, mock.requests.length,
      "no unaccounted outbound request");
    // GITHUB_REPO is OBSERVED, not assumed: a hard-coded repository would still
    // pass a count check while reading somebody else's release history.
    assert.equal(github[0], `${GITHUB_HOST}/repos/${TEST_ENV.GITHUB_REPO}/releases`);
    assert.equal(mock.seen.filter((n) => n === "dev_ids").length, 1);
    assert.equal(mock.seen.filter((n) => n.startsWith("scorecard_")).length, 2);
  } finally {
    mock.restore();
  }
});

test("a backfill override moves BOTH sections' windows to the same resolved anchor", async () => {
  // The scorecard anchored to `now()` once made a backfilled run's newest
  // window thirteen days long, absorbing events from after the target day.
  for (const [date, win, anchor, history] of [
    ["2026-07-17", "timestamp >= '2026-07-17 04:00:00' AND timestamp < '2026-07-18 04:00:00'",
     "2026-07-18", "2026-05-23"],
    ["2026-07-15", "timestamp >= '2026-07-15 04:00:00' AND timestamp < '2026-07-16 04:00:00'",
     "2026-07-16", "2026-05-21"],
  ]) {
    const mock = mockPostHog({});
    try {
      // The 2026-07-15 run's scorecard legitimately fails: the fixture's rows
      // sit AFTER that anchor, which is exactly what the anchor must refuse.
      await runReport(TEST_ENV, date, { hogqlOpts: { sleepFn: async () => {} } }).catch(() => {});

      assert.ok(mock.sqlByName.get("totals").includes(win), `adoption window for ${date}`);
      for (const q of ["scorecard_additive", "scorecard_non_additive"]) {
        const sql = mock.sqlByName.get(q);
        assert.ok(sql.includes(`'${anchor} 00:00:00'`), `${q} end anchor for ${date}`);
        assert.ok(sql.includes(`'${history} 00:00:00'`), `${q} history start for ${date}`);
        assert.ok(!sql.includes("now()"), `${q} must never anchor to the clock`);
      }
    } finally {
      mock.restore();
    }
  }
});

test("dev IDs resolve ONCE and both sections share that one production predicate", async () => {
  const mock = mockPostHog({});
  const inner = globalThis.fetch;
  // A non-empty dev list, so the predicate is distinctive rather than the
  // plain environment clause every query would carry anyway.
  let devIdCalls = 0;
  globalThis.fetch = async (url, init) => {
    const body = init?.body ? JSON.parse(init.body) : {};
    if (body.name === "daily_report_dev_ids") {
      devIdCalls += 1;
      return fakeResponse(200, { results: [["dev-alpha"], ["dev-beta"]] });
    }
    return inner(url, init);
  };
  try {
    await runReport(TEST_ENV, "2026-07-17", { hogqlOpts: { sleepFn: async () => {} } });

    assert.equal(devIdCalls, 1, "one resolution per run, never one per section");
    const predicate = "distinct_id NOT IN ('dev-alpha', 'dev-beta')";
    for (const q of ["totals", "installs", "scorecard_additive", "scorecard_non_additive"]) {
      assert.ok(mock.sqlByName.get(q).includes(predicate),
        `${q} must carry the shared exclusion`);
    }
    // The raw ids never leave the orchestrator: the sections receive a
    // predicate string, so there is nothing for them to rebuild differently.
    const adoption = createAdoptionSection(TEST_ENV, TEST_CONTEXT, {});
    const scorecard = createScorecardSection(TEST_ENV, TEST_CONTEXT, {});
    for (const section of [adoption, scorecard]) {
      assert.ok(!("devIds" in section), "a section must not hold raw dev ids");
    }
  } finally {
    mock.restore(); // restores the ORIGINAL fetch, discarding both layers
  }
});

test("concurrency never exceeds two ACROSS both sections, not two per section", async () => {
  const mock = mockPostHog({});
  try {
    await runReport(TEST_ENV, "2026-07-17", { hogqlOpts: { sleepFn: async () => {} } });
    assert.equal(mock.state.maxInFlight, 2,
      `PostHog allows three concurrent project queries; observed ${mock.state.maxInFlight}`);
  } finally {
    mock.restore();
  }
});

test("an adoption rejection releases its slot and the scorecard still runs and renders", async () => {
  // installs fails NON-retryably, so the adoption section is lost early. If a
  // failure could cancel queued work, the scorecard would never be asked.
  const mock = mockPostHog({ failQuery: "installs", failWith: 401 });
  try {
    await assert.rejects(() => runReport(TEST_ENV, "2026-07-17", { hogqlOpts: { sleepFn: async () => {} } }));
    assert.ok(mock.seen.includes("scorecard_additive"), "the scorecard's queries must still run");
    assert.ok(mock.seen.includes("scorecard_non_additive"));
    assert.ok(mock.requests.some((u) => u.startsWith(GITHUB_HOST)),
      "stage-2 release resolution must still run for the surviving section");
    assert.equal(mock.discordPayloads.length, 1);
    assert.match(mock.discordPayloads[0].embeds[1].description, /2\.4\.1: 7\/7 days publicly available/);
  } finally {
    mock.restore();
  }
});

test("an adoption-only failure posts the scorecard beside an unavailable adoption, then fails the trigger", async () => {
  const mock = mockPostHog({ failQuery: "totals", failWith: 401 });
  try {
    const res = await trigger("&date=2026-07-17");
    assert.equal(res.status, 500, "a lost section must never report a healthy run");
    assert.equal(mock.discordPayloads.length, 1, "one combined report, not one message per section");
    const [adoption, scorecard] = mock.discordPayloads[0].embeds;
    assert.match(adoption.description, /could not be measured, so this is not a report of zero/);
    assert.match(scorecard.description, /2\.4\.1: 7\/7 days publicly available/);
  } finally {
    mock.restore();
  }
});

test("a scorecard-only failure posts the real adoption beside an unavailable scorecard, then fails the trigger", async () => {
  const mock = mockPostHog({ failQuery: "scorecard_non_additive", failWith: 401 });
  try {
    const res = await trigger("&date=2026-07-17");
    assert.equal(res.status, 500);
    assert.equal(mock.discordPayloads.length, 1);
    const [adoption, scorecard] = mock.discordPayloads[0].embeds;
    assert.match(adoption.description, /Total users: 1 people used the app that day\./);
    assert.match(scorecard.title, /unavailable today/);
    assert.match(scorecard.description,
      /Version measurements could not be completed, so this is not a report of zero/);
  } finally {
    mock.restore();
  }
});

test("both sections failing still posts exactly one message, with both marked unavailable", async () => {
  const mock = mockPostHog({});
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    const body = init?.body ? JSON.parse(init.body) : {};
    if (body.name === "daily_report_totals" || body.name === "daily_report_scorecard_additive") {
      return fakeResponse(401);
    }
    return realFetch(url, init);
  };
  try {
    const res = await trigger("&date=2026-07-17");
    assert.equal(res.status, 500);
    assert.equal(mock.discordPayloads.length, 1, "one message, never one per failure");
    const [adoption, scorecard] = mock.discordPayloads[0].embeds;
    assert.match(adoption.title, /unavailable today/);
    assert.match(scorecard.title, /unavailable today/);
    // Still a report, still two embeds: the founder learns that nothing was
    // measured, which is not the same as learning that everything was zero.
    assert.equal(mock.discordPayloads[0].embeds.length, 2);
    // Neither half may reassure the founder about the other. Both failed, so a
    // cross-reference would print two calm, mutually contradicting sentences.
    assert.doesNotMatch(adoption.description, /unaffected/);
    assert.doesNotMatch(scorecard.description, /unaffected/);
  } finally {
    globalThis.fetch = realFetch;
    mock.restore();
  }
});

test("exhausted TRANSIENT release resolution loses only the scorecard, and never falls back to telemetry versions", async () => {
  const mock = mockPostHog({ github: 503 });
  try {
    const res = await trigger("&date=2026-07-17");
    assert.equal(res.status, 500);
    assert.equal(mock.requests.filter((u) => u.startsWith(GITHUB_HOST)).length, 3,
      "three attempts, then give up");
    assert.equal(mock.discordPayloads.length, 1);
    const [adoption, scorecard] = mock.discordPayloads[0].embeds;
    assert.match(adoption.description, /Total users: 1 people used the app that day\./,
      "a GitHub outage costs the scorecard, never adoption");
    assert.match(scorecard.title, /unavailable today/);
    // The versions ARE in the telemetry we already hold. Printing them anyway
    // would silently restore the version-blind report this issue removed.
    assert.doesNotMatch(scorecard.description, /2\.4\.1/);
    assert.doesNotMatch(scorecard.description, /2\.4\.0/);
  } finally {
    mock.restore();
  }
});

test("a release-resolution CONTRACT failure fails the whole run and never posts a normal report", async () => {
  for (const [label, opts, env] of [
    ["a 404 from the release list", { github: 404 }, TEST_ENV],
    ["an unusable GITHUB_REPO", {}, { ...TEST_ENV, GITHUB_REPO: "EnviousWispr" }],
  ]) {
    const mock = mockPostHog(opts);
    try {
      await assert.rejects(
        () => runReport(env, "2026-07-17", { hogqlOpts: { sleepFn: async () => {} } }),
        (err) => err instanceof ScorecardSectionError && err.wholeRun === true,
        label
      );
      // Exactly one message, and it is the fixed notice: no embeds, so the
      // adoption half is NOT quietly published beside a broken scorecard. A
      // misconfigured worker must not read as a healthy morning for months.
      assert.equal(mock.discordPayloads.length, 1, label);
      assert.ok(!("embeds" in mock.discordPayloads[0]), `${label}: no combined report`);
      assert.match(mock.discordPayloads[0].content, /could not be generated/);
      assert.doesNotMatch(mock.discordPayloads[0].content, /404|GITHUB_REPO|http/i,
        "the notice discloses no technical detail");
    } finally {
      mock.restore();
    }
  }
});

test("a shared-preflight failure starts NEITHER section", async () => {
  for (const [label, search] of [
    ["a malformed date override", "&date=not-a-date"],
    ["an impossible calendar date", "&date=2026-02-30"],
  ]) {
    const mock = mockPostHog({});
    try {
      const res = await trigger(search);
      assert.equal(res.status, 500, label);
      assert.match(await res.text(), /date override/,
        `${label}: must be refused AS a bad override, not by an incidental
         downstream crash - a report for a day nobody asked for is the failure`);
      assert.equal(mock.seen.length, 0, `${label}: no PostHog query may start`);
      assert.ok(!mock.requests.some((u) => u.startsWith(GITHUB_HOST)), `${label}: no GitHub call`);
      assert.equal(mock.discordPayloads.length, 1, `${label}: one fixed notice`);
      assert.ok(!("embeds" in mock.discordPayloads[0]), `${label}: never a partial report`);
    } finally {
      mock.restore();
    }
  }
  // And an unauthenticated trigger does none of it, not even the notice.
  const mock = mockPostHog({});
  try {
    const res = await worker.fetch(new Request("https://worker.example/?token=wrong"), SECRET_ENV);
    assert.equal(res.status, 401);
    assert.equal(mock.requests.length, 0, "a rejected trigger makes no outbound request at all");
  } finally {
    mock.restore();
  }
});

test("Discord delivery sends exactly one request at the exact budget boundaries", async () => {
  const calls = [];
  const okFetch = async (url, init) => {
    calls.push({ url, body: JSON.parse(init.body) });
    return { status: 204 };
  };
  // Every field exactly at its limit, and the combined embed text exactly at
  // 6000: the boundary must be inclusive, or a legitimate busy day is refused.
  const title = "T".repeat(DISCORD_LIMITS.embedTitle);
  const payload = {
    content: "c".repeat(DISCORD_LIMITS.content),
    embeds: [
      { title, description: "a".repeat(DISCORD_LIMITS.embedDescription) },
      { title, description: "b".repeat(DISCORD_LIMITS.combinedText - DISCORD_LIMITS.embedDescription - title.length * 2) },
    ],
  };
  await deliverReport("https://discord.example/webhook", payload, { fetchFn: okFetch });
  assert.equal(calls.length, 1, "one request, one attempt");
  assert.deepEqual(calls[0].body, payload, "the object validated is the object sent");
  assert.equal(calls[0].url, "https://discord.example/webhook");

  // 200 is also success (Discord answers 200 when `wait` is requested).
  await deliverReport("https://discord.example/webhook", { content: "x" },
    { fetchFn: async () => ({ status: 200 }) });

  // A rejected or unreachable webhook is ONE attempt, never a retry and never
  // a second consolation message.
  for (const [label, fetchFn] of [
    ["a non-2xx response", async () => { calls.push({}); return { status: 500 }; }],
    ["an unrecognised 2xx", async () => { calls.push({}); return { status: 202 }; }],
    ["a network rejection", async () => { calls.push({}); throw new TypeError("network"); }],
  ]) {
    const before = calls.length;
    await assert.rejects(() => deliverReport("https://d/w", { content: "x" }, { fetchFn }), label);
    assert.equal(calls.length - before, 1, `${label}: exactly one attempt`);
  }
});

test("Discord refuses every over-budget or malformed payload BEFORE any request", async () => {
  const title = "T";
  const ok = (extra) => ({ content: "hello", embeds: [{ title, description: "d" }], ...extra });
  const sparse = [{ title, description: "d" }, { title, description: "d" }];
  delete sparse[0];

  const refused = [
    ["content one character over", { content: "c".repeat(DISCORD_LIMITS.content + 1), embeds: [{ title, description: "d" }] }],
    ["empty content", ok({ content: "" })],
    ["missing content", { embeds: [{ title, description: "d" }] }],
    ["non-string content", ok({ content: 42 })],
    ["a description one character over", ok({ embeds: [{ title, description: "d".repeat(DISCORD_LIMITS.embedDescription + 1) }] })],
    ["combined embed text one character over", ok({ embeds: [
      { title, description: "a".repeat(DISCORD_LIMITS.embedDescription) },
      { title, description: "b".repeat(DISCORD_LIMITS.combinedText - DISCORD_LIMITS.embedDescription - 2 * title.length + 1) },
    ] })],
    ["a title one character over", ok({ embeds: [{ title: "T".repeat(DISCORD_LIMITS.embedTitle + 1), description: "d" }] })],
    ["one embed too many", ok({ embeds: Array.from({ length: DISCORD_LIMITS.embeds + 1 }, () => ({ title, description: "d" })) })],
    ["an empty embed list", ok({ embeds: [] })],
    ["a non-array embed list", ok({ embeds: { title, description: "d" } })],
    ["a sparse embed list", ok({ embeds: sparse })],
    ["a null embed", ok({ embeds: [null] })],
    ["an embed missing its title", ok({ embeds: [{ description: "d" }] })],
    ["an embed with an empty description", ok({ embeds: [{ title, description: "" }] })],
    // An INHERITED field serializes to nothing, so the sent object would lack
    // exactly the field that was validated.
    ["an inherited content", Object.create({ content: "hello" })],
    ["an inherited embed description", ok({ embeds: [Object.assign(Object.create({ description: "d" }), { title })] })],
    // An unknown textual field cannot be counted toward the 6000 budget, so it
    // is refused rather than passed through uncounted.
    ["an uncountable extra embed field", ok({ embeds: [{ title, description: "d", footer: "x".repeat(9000) }] })],
    ["a payload that is not an object", "just a string"],
  ];

  // ---- validated-by-read, consumed-by-serialization ------------------------
  //
  // JSON.stringify is a DIFFERENT consumption mechanism from a property read:
  // it calls toJSON and it invokes getters. Every fixture below passed the
  // read-based validator while putting different bytes on the wire. The one
  // that proved it: a toJSON returning 3,000 characters of content and no
  // embeds at all.
  const withToJSON = (target, replacement) => {
    Object.defineProperty(target, "toJSON", { value: () => replacement, configurable: true });
    return target;
  };
  const accessor = (target, field, value) => {
    Object.defineProperty(target, field, { get: () => value, configurable: true, enumerable: true });
    return target;
  };
  const goodEmbed = () => ({ title, description: "d" });

  refused.push(
    ["a payload toJSON that replaces everything",
     withToJSON({ content: "ok", embeds: [goodEmbed()] }, { content: "x".repeat(3000) })],
    ["an embed toJSON", ok({ embeds: [withToJSON(goodEmbed(), { title: "T", description: "x".repeat(9000) })] })],
    ["an embeds-array toJSON", ok({ embeds: withToJSON([goodEmbed()], [{ title: "T", description: "x".repeat(9000) }]) })],
    ["a content accessor", accessor({ embeds: [goodEmbed()] }, "content", "ok")],
    ["an embeds accessor", accessor({ content: "ok" }, "embeds", [goodEmbed()])],
    ["an embed title accessor", ok({ embeds: [accessor({ description: "d" }, "title", title)] })],
    ["an embed description accessor", ok({ embeds: [accessor({ title }, "description", "d")] })],
    ["a non-enumerable extra payload field",
     Object.defineProperty({ content: "ok", embeds: [goodEmbed()] }, "hidden",
       { value: "x", enumerable: false, configurable: true })],
    ["a symbol-keyed extra payload field",
     Object.defineProperty({ content: "ok", embeds: [goodEmbed()] }, Symbol("s"),
       { value: "x", configurable: true })],
    ["a symbol-keyed extra embed field",
     ok({ embeds: [Object.defineProperty(goodEmbed(), Symbol("s"), { value: "x", configurable: true })] })],
    ["a payload with a custom prototype",
     Object.assign(Object.create({ toJSON: () => ({ content: "x".repeat(3000) }) }),
       { content: "ok", embeds: [goodEmbed()] })],
    ["an embed with a custom prototype",
     ok({ embeds: [Object.assign(Object.create({ toJSON: () => ({ title: "T", description: "x".repeat(9000) }) }),
       goodEmbed())] })],
    ["an embeds array with a custom prototype",
     ok({ embeds: Object.setPrototypeOf([goodEmbed()],
       Object.assign(Object.create(Array.prototype), { toJSON: () => [{ title: "T", description: "x".repeat(9000) }] })) })],
    ["an extra own key on the embeds array",
     ok({ embeds: Object.assign([goodEmbed()], { extra: "x" }) })]
  );

  // JSON.stringify serializes only ENUMERABLE own properties of an object. A
  // non-enumerable field validates perfectly and is then simply absent from the
  // body: checked, and not sent.
  const hidden = (target, field, value) => {
    Object.defineProperty(target, field, { value, enumerable: false, configurable: true });
    return target;
  };
  refused.push(
    ["a non-enumerable content", hidden({ embeds: [goodEmbed()] }, "content", "ok")],
    ["a non-enumerable embeds", hidden({ content: "ok" }, "embeds", [goodEmbed()])],
    ["a non-enumerable embed title", ok({ embeds: [hidden({ description: "d" }, "title", title)] })],
    ["a non-enumerable embed description", ok({ embeds: [hidden({ title }, "description", "d")] })]
  );

  for (const [label, payload] of refused) {
    let attempts = 0;
    await assert.rejects(
      () => deliverReport("https://d/w", payload, { fetchFn: async () => { attempts += 1; return { status: 204 }; } }),
      (err) => err instanceof DiscordPayloadError,
      label
    );
    assert.equal(attempts, 0, `${label}: nothing may be sent`);
  }

  // MUTABLE PROTOTYPES. Knowing which prototype an object uses is not the same
  // as knowing that prototype is clean: both Object.prototype and
  // Array.prototype are writable, so a toJSON planted on either replaces the
  // whole serialized payload while every own-property check still passes.
  //
  // The pollution is restored in a `finally` that runs BEFORE the returned
  // promise is awaited, which is safe precisely because deliverReport validates
  // synchronously: the checks run while the prototype is still dirty, and no
  // other test ever sees it.
  async function assertPrototypeToJSONRefused(prototype, replacement, label, payload) {
    const previous = Object.getOwnPropertyDescriptor(prototype, "toJSON");
    let attempts = 0;
    let result;
    Object.defineProperty(prototype, "toJSON", { value: replacement, configurable: true });
    try {
      result = deliverReport(
        "https://d/w",
        payload ?? { content: "ok", embeds: [{ title: "T", description: "D" }] },
        { fetchFn: async () => { attempts += 1; return { status: 204 }; } }
      );
    } finally {
      if (previous) Object.defineProperty(prototype, "toJSON", previous);
      else delete prototype.toJSON;
    }
    await assert.rejects(result, (error) => error instanceof DiscordPayloadError, label);
    assert.equal(attempts, 0, `${label}: nothing may be sent`);
  }

  await assertPrototypeToJSONRefused(Object.prototype, () => ({ content: "x".repeat(3000) }),
    "Object.prototype toJSON");
  await assertPrototypeToJSONRefused(Array.prototype, () => [], "Array.prototype toJSON");
  // The failure notice carries no embeds, so the array check cannot cover it:
  // only the object-level prototype check stands between a planted toJSON and a
  // replaced notice. Without this case the two checks mask each other.
  await assertPrototypeToJSONRefused(Object.prototype, () => ({ content: "x".repeat(3000) }),
    "Object.prototype toJSON on a content-only notice", { content: "ok" });

  // A missing webhook is refused the same way, before anything is built.
  let attempts = 0;
  await assert.rejects(
    () => deliverReport("", ok(), { fetchFn: async () => { attempts += 1; return { status: 204 }; } }),
    (err) => err instanceof DiscordPayloadError
  );
  assert.equal(attempts, 0);
});

test("an over-budget report is refused whole, with zero requests and no fallback message", async () => {
  // The founder gets nothing rather than something that reads as complete.
  const mock = mockPostHog({});
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    const body = init?.body ? JSON.parse(init.body) : {};
    if (body.name === "daily_report_geo") {
      // Far more geography than a real day produces: enough to push the
      // adoption embed past Discord's 4096-character description limit.
      return fakeResponse(200, {
        results: Array.from({ length: 400 }, (_, i) => [`Country-With-A-Very-Long-Name-${i}`, i]),
        columns: ["country", "n"],
      });
    }
    return realFetch(url, init);
  };
  try {
    const res = await trigger("&date=2026-07-17");
    assert.equal(res.status, 500);
    assert.equal(mock.discordPayloads.length, 0,
      "no partial report, no split, no truncation, and no failure notice either");
  } finally {
    globalThis.fetch = realFetch;
    mock.restore();
  }
});

test("a truncated scorecard response, and an unrenderable section, each lose only that section", async () => {
  // (a) PostHog silently caps a result at 100 rows. A truncated response
  // renders as a perfectly healthy report with missing history, which is the
  // defect that made a "56 days, every version" planning measurement read as
  // complete while holding 100 of 227 rows. The completeness check must be
  // WIRED, not merely present: this drives it through the real section.
  const mock = mockPostHog({});
  const inner = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    const body = init?.body ? JSON.parse(init.body) : {};
    if (body.name === "daily_report_scorecard_additive") {
      return fakeResponse(200, {
        // Two rows returned, three claimed: exactly what truncation looks like.
        results: SCORECARD_ADDITIVE_ROWS.map((r) => [...r.slice(0, 2), 3, ...r.slice(3)]),
        columns: SCORECARD_ADDITIVE_COLUMNS,
      });
    }
    return inner(url, init);
  };
  try {
    const res = await trigger("&date=2026-07-17");
    assert.equal(res.status, 500);
    assert.equal(mock.discordPayloads.length, 1);
    const [adoption, scorecard] = mock.discordPayloads[0].embeds;
    assert.match(adoption.description, /Total users: 1 people used the app that day\./);
    assert.match(scorecard.title, /unavailable today/);
  } finally {
    mock.restore();
  }

  // (b) A section that computes cleanly but cannot be RENDERED is still an
  // unavailable section, not a crashed report. Rendering therefore happens
  // inside the settled outcome, which this drives through the real driver.
  const outcomes = await driveSections(
    [
      {
        driver: { name: "broken", primaryTasks: [], followUpTasks: () => [], finish: () => "computed" },
        describe: () => { throw new TypeError("cannot render"); },
        unavailable: () => ["Title", "unused"],
      },
      {
        driver: { name: "healthy", primaryTasks: [], followUpTasks: () => [], finish: () => "computed" },
        describe: (v) => ["Title", v],
        unavailable: () => ["Title", "unused"],
      },
    ],
    2
  );
  assert.equal(outcomes[0].status, "rejected", "a render failure is a lost section");
  assert.deepEqual(outcomes[1],
    { status: "fulfilled", value: { title: "Title", description: "computed" } },
    "and it costs the other section nothing");
});

test("a section refuses to finish before its own results were interpreted", async () => {
  // Not a hypothetical tidiness check: `{ ...null }` is `{}`, so skipping the
  // interpretation step renders a complete-looking report of `undefined`
  // people and `undefined` dictations rather than failing. The orchestrator
  // makes the order impossible today; this keeps it impossible to get wrong
  // quietly if the staging is ever changed.
  for (const [label, section] of [
    ["adoption", createAdoptionSection(TEST_ENV, TEST_CONTEXT, {})],
    ["scorecard", createScorecardSection(TEST_ENV, TEST_CONTEXT, {})],
  ]) {
    assert.throws(() => section.finish([], []), /ran before/, label);
  }
});

test("a falsy rejection value is still a failure, never a healthy section", async () => {
  // `throw undefined` is legal JavaScript. Using the reason itself as the
  // failure flag reports a LOST section as a fine one, which is the worst
  // possible direction for this report to be wrong in.
  for (const thrown of [undefined, null, false, 0, ""]) {
    const outcomes = await driveSections(
      [
        {
          driver: {
            name: "falsy-thrower",
            primaryTasks: [],
            followUpTasks: () => { throw thrown; },
            finish: () => "never reached",
          },
          describe: () => ["Title", "apparently healthy"],
          unavailable: () => ["Title", "unavailable"],
        },
        {
          driver: { name: "healthy", primaryTasks: [], followUpTasks: () => [], finish: () => "fine" },
          describe: (v) => ["Title", v],
          unavailable: () => ["Title", "unavailable"],
        },
      ],
      2
    );
    assert.equal(outcomes[0].status, "rejected", `throw ${String(thrown)} must reject`);
    assert.ok(outcomes[0].reason instanceof Error,
      "a non-Error rejection is normalised, so downstream .message is always safe");
    assert.equal(outcomes[1].status, "fulfilled", "and the other section is untouched");
  }

  // The same normalisation applies to a task that rejects falsily, so a lost
  // QUERY cannot read as a successful one either.
  const [outcome] = await driveSections(
    [{
      driver: {
        name: "falsy-task",
        primaryTasks: [() => Promise.reject(undefined)],
        followUpTasks: (primary) => {
          assert.equal(primary[0].status, "rejected", "a falsy rejection stays rejected");
          assert.ok(primary[0].reason instanceof Error);
          throw primary[0].reason;
        },
        finish: () => "never reached",
      },
      describe: () => ["Title", "body"],
      unavailable: () => ["Title", "unavailable"],
    }],
    2
  );
  assert.equal(outcome.status, "rejected");
});

test("a requested tier-A lookup cannot silently vanish into default attribution", async () => {
  // If the settings lookup was ASKED for and its result is missing, the polish
  // breakdown would quietly fall back to the weaker tier while still printing
  // as authoritative, with no "approximate" note. That is a wrong number that
  // looks right, so it fails loudly instead.
  const mock = mockPostHog({});
  try {
    const section = createAdoptionSection(TEST_ENV, TEST_CONTEXT, { hogqlOpts: { sleepFn: async () => {} } });
    const primary = await Promise.all(section.primaryTasks.map(async (t) => ({
      status: "fulfilled", value: await t(),
    })));
    const followUp = section.followUpTasks(primary);
    assert.equal(followUp.length, 1, "the fixture has active ids, so tier A is requested");
    assert.throws(() => section.finish(primary, []), /expected 1 follow-up result/);
    assert.throws(() => section.finish(primary, [{ status: "fulfilled", value: { results: [], columns: [] } },
                                                  { status: "fulfilled", value: { results: [], columns: [] } }]),
      /expected 1 follow-up result/, "an extra result is equally wrong");
    assert.throws(() => section.finish(primary, undefined), /a non-array/);
  } finally {
    mock.restore();
  }
});

test("a malformed formatter loses only its own section, never the whole report", async () => {
  // Validated at DELIVERY, a bad embed shape fails the entire payload and costs
  // the other, perfectly good, section its place in the report.
  // A hole is not merely a missing string: Array#every SKIPS holes, so a sparse
  // result reads as valid and joins into a description with a blank line where a
  // whole section should have been. And a hole masked by a prototype index
  // reads as a perfectly good line that is not the caller's own.
  const sparse = ["Title"];
  sparse.length = 3;
  sparse[2] = "Body";

  const inherited = ["Title"];
  inherited.length = 3;
  inherited[2] = "Body";
  const inheritedPrototype = Object.create(Array.prototype);
  Object.defineProperty(inheritedPrototype, "1", { value: "inherited body", configurable: true });
  Object.setPrototypeOf(inherited, inheritedPrototype);

  // A formatter result whose ITERATOR disagrees with its indices: the checks
  // read lines[i], and destructuring would re-read through Symbol.iterator.
  // Same class as the Discord toJSON case, different consumption mechanism.
  const lyingIterator = ["Title", "Body"];
  lyingIterator[Symbol.iterator] = function* () { yield "Other"; yield "x".repeat(9000); };

  // The expected MESSAGE is part of each case. Without it the too-few-lines
  // check is unarmed: a one-line result still fails later on an empty
  // description, so only the wording distinguishes a formatter that returned
  // the wrong SHAPE from one that returned an empty section.
  for (const [bad, expected] of [
    [[], /title and body as string lines/],
    [["only a title"], /title and body as string lines/],
    [["", "empty title"], /non-empty title and description/],
    [["Title", ""], /non-empty title and description/],
    [["Title", 42], /title and body as string lines/],
    ["not an array", /title and body as string lines/],
    [sparse, /title and body as string lines/],
    [inherited, /title and body as string lines/],
  ]) {
    const outcomes = await driveSections(
      [
        {
          driver: { name: "bad-format", primaryTasks: [], followUpTasks: () => [], finish: () => "computed" },
          describe: () => bad,
          unavailable: () => ["Title", "unavailable"],
        },
        {
          driver: { name: "healthy", primaryTasks: [], followUpTasks: () => [], finish: () => "computed" },
          describe: (v) => ["Title", v],
          unavailable: () => ["Title", "unavailable"],
        },
      ],
      2
    );
    assert.equal(outcomes[0].status, "rejected", `${JSON.stringify(bad)} must be refused`);
    assert.match(outcomes[0].reason.message, expected,
      `${JSON.stringify(bad)} must say WHICH contract it broke`);
    assert.deepEqual(outcomes[1], { status: "fulfilled", value: { title: "Title", description: "computed" } },
      "the healthy section survives a malformed sibling");
  }

  // The embed must be built from the values that were CHECKED, so a lying
  // iterator changes nothing rather than smuggling a 9,000-character line past
  // the per-index string check.
  const [lying] = await driveSections(
    [{
      driver: { name: "lying-iterator", primaryTasks: [], followUpTasks: () => [], finish: () => null },
      describe: () => lyingIterator,
      unavailable: () => ["Title", "unavailable"],
    }],
    2
  );
  assert.deepEqual(lying, { status: "fulfilled", value: { title: "Title", description: "Body" } },
    "the embed comes from the indexed values, never a second read of the container");

  // ONE observation per value. A second read of the same index lets an accessor
  // answer the check and the consumer differently, and the oversized line would
  // then fail the WHOLE payload at delivery instead of losing one section.
  const changing = ["Title"];
  changing.length = 2;
  let reads = 0;
  Object.defineProperty(changing, "1", {
    enumerable: true,
    configurable: true,
    get() {
      reads += 1;
      return reads === 1 ? "Body" : "x".repeat(9000);
    },
  });

  const [changingOutcome] = await driveSections(
    [{
      driver: { name: "changing-format", primaryTasks: [], followUpTasks: () => [], finish: () => null },
      describe: () => changing,
      unavailable: () => ["Unavailable", "Body"],
    }],
    2
  );
  assert.deepEqual(changingOutcome,
    { status: "fulfilled", value: { title: "Title", description: "Body" } });
  assert.equal(reads, 1, "each formatter line is observed exactly once");
});

test("only a declared scorecard contract failure can trigger the whole-run path", async () => {
  // An adoption error that happened to carry a `wholeRun` property would
  // otherwise discard a perfectly good scorecard and post only the notice.
  const mock = mockPostHog({});
  const inner = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    const body = init?.body ? JSON.parse(init.body) : {};
    if (body.name === "daily_report_totals") {
      const err = new Error("adoption blew up");
      err.wholeRun = true; // the impostor
      throw err;
    }
    return inner(url, init);
  };
  try {
    const res = await trigger("&date=2026-07-17");
    assert.equal(res.status, 500);
    assert.equal(mock.discordPayloads.length, 1);
    const payload = mock.discordPayloads[0];
    assert.ok("embeds" in payload, "an adoption failure must still produce a combined report");
    assert.match(payload.embeds[0].title, /unavailable today/);
    assert.match(payload.embeds[1].description, /2\.4\.1: 7\/7 days publicly available/,
      "the scorecard is real, not discarded by an impostor property");
  } finally {
    mock.restore();
  }
});

test("builds below the measurement floor are hidden everywhere, not shown with a caveat", async () => {
  // Releases before 2.2.0 never emitted a discard reason, so their AI-polish
  // figure reads a flat, false 100%. Measured on 56 production days: 2.1.0
  // reports 100% where the truth is 88.7%. The founder chose to hide those
  // builds rather than print a known-wrong number beside a footnote, because a
  // perfect score with a footnote still reads as a perfect score.
  assert.equal(isScorecardEligible("2.2.0"), true, "the floor itself is eligible");
  assert.equal(isScorecardEligible("2.1.9"), false);
  assert.equal(isScorecardEligible("1.9.9"), false);
  assert.equal(isScorecardEligible(null), false);
  // Lexical string comparison would put 2.10.0 BELOW 2.2.0 and silently start
  // hiding future releases. This is the case a string floor gets wrong.
  assert.equal(isScorecardEligible("2.10.0"), true, "version order is numeric, never lexical");

  // An old row is DROPPED before validation, not refused: it is a different
  // producer schema, not malformed data. Before this, one 2.1.4 row from a real
  // 56-day window failed the whole scorecard on a cross-field invariant that
  // only holds for 2.2.0 and later.
  const measurements = buildMeasurements({
    additiveRows: [
      addRow("2026-07-28", "2.4.1", 3, { dictations: 10, afm_attempts: 4, afm_discards: 1, afm_classifier_discards: 1 }),
      // classifier EXCEEDS discards, exactly as production emits for 2.1.x
      addRow("2026-07-28", "2.1.4", 3, { dictations: 5, afm_attempts: 4, afm_discards: 0, afm_classifier_discards: 4 }),
      addRow("2026-07-28", "1.9.9", 3, { dictations: 2, afm_attempts: 1, afm_discards: 0, afm_classifier_discards: 1 }),
    ],
    nonAdditiveRows: [
      naRow(0, "2.4.1", 3, { dictations: 10, people: 3 }),
      naRow(0, "2.1.4", 3, { dictations: 5, people: 2 }),
      naRow(0, "1.9.9", 3, { dictations: 2, people: 1 }),
    ],
    windowEndExclusive: "2026-07-29",
  });
  const window0 = measurements.windows.get(0).versions;
  assert.deepEqual([...window0.keys()], ["2.4.1"], "only eligible builds are measured");
  assert.deepEqual(measurements.usageRows, [{ app_version: "2.4.1", dictations: 10 }],
    "and only eligible builds can be selected");
  assert.equal(measurements.windows.get(0).totalDictations, 10,
    "the share denominator counts measured builds only, so shares still sum to 100%");

  // A published old release is never crowned newest and never displayed.
  // selectReleases takes ALREADY-PARSED releases, the shape fetchPublishedReleases
  // returns, not the raw GitHub payload.
  const pub = (version, publishedAt) => ({ version, publishedAt });
  const selection = selectReleases(
    [pub("2.1.4", "2026-07-20T12:00:00Z"), pub("2.4.1", "2026-07-10T12:00:00Z")],
    [{ app_version: "2.4.1", dictations: 10 }]
  );
  assert.deepEqual(selection.releases.map((r) => r.version), ["2.4.1"],
    "a NEWER but ineligible release must not be crowned");
  assert.ok(!selection.releaseCatalog.some((r) => r.version === "2.1.4"),
    "and must not be pooled for historical variation");

  // Every published release below the floor is a hard failure, not an empty
  // scorecard that reads as "nothing shipped".
  assert.throws(
    () => selectReleases([pub("2.1.4", "2026-07-20T12:00:00Z")], []),
    /no eligible published releases to judge at or above 2\.2\.0/
  );

  // The floor is DISCLOSED, and it travels with the displayed set rather than
  // being re-derived by the formatter: reading it from a field the ranker never
  // supplied rendered "Builds before undefined are not measured", green.
  const ranking = rankMovers({ measurements, selection });
  assert.equal(ranking.summary.minVersion, "2.2.0");
  const text = formatScorecard({ ranking }).join("\n");
  assert.match(text, /Builds before 2\.2\.0 are not measured/);
  // Those builds DID record filter_tripped; production shows classifier_discard
  // on them. What they did not record was every fallback reason.
  assert.match(text, /did not record every reason polished text was rejected/);
  assert.doesNotMatch(text, /never recorded why/);
  // The floor exists BECAUSE of the polish boundary, so the two must not drift.
  assert.equal(telemetryContractFor("polish_kept", "2.2.0"), "polish-v2-fallback-reason");
  assert.equal(telemetryContractFor("polish_kept", "2.1.9"), null);
  assert.doesNotMatch(text, /undefined/);
  assert.throws(
    () => formatScorecard({ ranking: { ...ranking, summary: { ...ranking.summary, minVersion: undefined } } }),
    /minVersion must be a version string/
  );
});

test("a release published after the reported window is never crowned newest", async () => {
  // GitHub returns every published release, including ones published AFTER the
  // window being reported. A build shipped at 08:00 would otherwise be crowned
  // newest in the 09:12 report covering yesterday, and a backfill would crown a
  // release that did not exist during the reported week at all - both printing
  // "0/7 days publicly available, no production data yet" for the build
  // supposedly most worth watching, while displacing one that has real data.
  const body = [
    release("v2.4.0", "2026-07-18T21:00:00Z"),
    release("v2.4.1", "2026-07-24T17:00:00Z"),
    release("v2.5.0", "2026-07-29T08:00:00Z"), // published the morning of the run
  ];
  const opts = {
    fetchFn: async () => ghResponse(200, body),
    sleepFn: async () => {},
  };
  const env = { GITHUB_REPO: "saurabhav88/EnviousWispr" };
  const usageRows = [usage("2.4.1", 100), usage("2.4.0", 60)];

  const excluded = await resolveReleases(env, usageRows,
    { ...opts, windowEndExclusive: "2026-07-29" });
  assert.equal(excluded.releases[0].version, "2.4.1",
    "the newest release that existed during the window is crowned");
  assert.ok(!excluded.releases.some((r) => r.version === "2.5.0"));
  assert.ok(!excluded.releaseCatalog.some((r) => r.version === "2.5.0"),
    "and it is not pooled for historical variation either");

  // The SAME release IS crowned once the window it shipped in is the one being
  // reported - a two-way control, so the filter cannot simply be hiding
  // everything.
  const included = await resolveReleases(env, usageRows,
    { ...opts, windowEndExclusive: "2026-07-30" });
  assert.equal(included.releases[0].version, "2.5.0",
    "a release published inside the window IS the newest, with no data yet");
  assert.equal(included.releases[0].observed, false);

  // A backfill for an older day must not see July releases at all.
  const backfill = await resolveReleases(env, [usage("2.4.0", 60)],
    { ...opts, windowEndExclusive: "2026-07-19" });
  assert.deepEqual(backfill.releases.map((r) => r.version), ["2.4.0"]);

  // The anchor is REQUIRED, never defaulted to "no filter": a forgotten caller
  // would silently restore the defect this closes.
  await assert.rejects(() => resolveReleases(env, usageRows, opts),
    /requires opts.windowEndExclusive/);
  await assert.rejects(
    () => resolveReleases(env, usageRows, { ...opts, windowEndExclusive: "July 29" }),
    /requires opts.windowEndExclusive/);
});

// ---- #1589: shared-transport worker label ------------------------------------
// These call the RAW imports deliberately. The wrapped helpers at the top of
// this file always supply a label, so they could never prove the requirement
// exists - a guard nothing can trip is not a guard.

test("shared hogql: a missing workerLabel throws BEFORE any request is made", async () => {
  let calls = 0;
  const fetchFn = async () => { calls += 1; return fakeResponse(200, { results: [] }); };
  await assert.rejects(
    () => rawHogql({ POSTHOG_PROJECT_ID: "x", POSTHOG_PERSONAL_API_KEY: "k" }, "SELECT 1", "q", { fetchFn }),
    /requires a non-empty workerLabel/
  );
  // The point of failing loud is failing EARLY: an unlabelled query must never
  // reach PostHog, or it lands in the query log under no worker at all.
  assert.equal(calls, 0, "no request may be made without a label");
});

test("shared hogql: a non-string or empty workerLabel is refused, not coerced", async () => {
  const env = { POSTHOG_PROJECT_ID: "x", POSTHOG_PERSONAL_API_KEY: "k" };
  const fetchFn = async () => fakeResponse(200, { results: [] });
  for (const bad of [null, 42, "", {}, ["daily_report"]]) {
    await assert.rejects(
      () => rawHogql(env, "SELECT 1", "q", { fetchFn, workerLabel: bad }),
      /requires a non-empty workerLabel/,
      `workerLabel ${JSON.stringify(bad)} must be refused`
    );
  }
});

test("shared hogql: the query name PostHog sees is <workerLabel>_<queryName>", async () => {
  const seen = [];
  const fetchFn = async (_url, init) => {
    seen.push(JSON.parse(init.body).name);
    return fakeResponse(200, { results: [] });
  };
  const env = { POSTHOG_PROJECT_ID: "x", POSTHOG_PERSONAL_API_KEY: "k" };
  await rawHogql(env, "SELECT 1", "totals", { fetchFn, workerLabel: "daily_report" });
  await rawHogql(env, "SELECT 1", "totals", { fetchFn, workerLabel: "weekly_digest" });
  // Two-way control: the SAME queryName must produce two DIFFERENT logged names,
  // which is the whole reason the label is required rather than defaulted.
  assert.deepEqual(seen, ["daily_report_totals", "weekly_digest_totals"]);
});

test("shared querySection: requires the label too, and refuses before requesting", async () => {
  let calls = 0;
  const fetchFn = async () => { calls += 1; return fakeResponse(503, null); };
  await assert.rejects(
    () => rawQuerySection({ POSTHOG_PROJECT_ID: "x", POSTHOG_PERSONAL_API_KEY: "k" }, "SELECT 1", "geo", { fetchFn }),
    /requires a non-empty workerLabel/
  );
  assert.equal(calls, 0);
});

test("daily-report still labels every query daily_report_*, unchanged by the move", async () => {
  const names = [];
  const fetchFn = async (_url, init) => {
    const body = JSON.parse(init.body);
    names.push(body.name);
    return fakeResponse(200, { results: [], columns: [] });
  };
  await rawResolveDevIds({ POSTHOG_PROJECT_ID: "x", POSTHOG_PERSONAL_API_KEY: "k" },
    { fetchFn, workerLabel: "daily_report" });
  assert.deepEqual(names, ["daily_report_dev_ids"]);
});

// ---- #1589: shared Discord module owns the PROTOCOL, not one worker's layout --

test("deliverReport accepts color, footer and timestamp — Discord permits them", async () => {
  let sent;
  const fetchFn = async (_url, init) => { sent = JSON.parse(init.body); return { status: 204 }; };
  await deliverReport("https://hook", {
    content: "EnviousWispr Weekly Digest",
    embeds: [{
      title: "App usage",
      description: "189 people used the app.",
      color: 0x7c3aed,
      footer: { text: "EnviousWispr Weekly Digest" },
      timestamp: "2026-08-01T13:00:00.000Z",
    }],
  }, { fetchFn });
  // Before #1589 this payload was REFUSED, which forced the weekly digest to
  // drop its brand colour to reuse this transport. That was one worker's layout
  // choice enforced as if it were a protocol limit.
  assert.equal(sent.embeds[0].color, 0x7c3aed);
  assert.equal(sent.embeds[0].footer.text, "EnviousWispr Weekly Digest");
  assert.equal(sent.embeds[0].timestamp, "2026-08-01T13:00:00.000Z");
});

test("footer text counts toward the 6000-character budget, like Discord counts it", async () => {
  const fetchFn = async () => { throw new Error("must not reach the network"); };
  const long = "x".repeat(3000);
  // Title+description alone are under budget; adding footer text pushes the
  // total over. If footer text were permitted but uncounted, this would send.
  await assert.rejects(
    () => deliverReport("https://hook", {
      content: "c",
      embeds: [
        { title: "A", description: long },
        { title: "B", description: long, footer: { text: "y".repeat(500) } },
      ],
    }, { fetchFn }),
    /exceeds the 6000 limit/
  );
});

test("a permitted-looking but malformed color, timestamp or footer is refused", async () => {
  const fetchFn = async () => { throw new Error("must not reach the network"); };
  const base = { title: "T", description: "D" };
  const bad = [
    { ...base, color: -1 },
    { ...base, color: 0x1000000 },
    { ...base, color: 1.5 },
    { ...base, color: "purple" },
    { ...base, timestamp: "not a date" },
    { ...base, timestamp: 1754049600000 },
    { ...base, footer: "EnviousWispr" },
    { ...base, footer: { text: "ok", icon_url: "https://x" } },
    { ...base, footer: {} },
  ];
  for (const embed of bad) {
    await assert.rejects(
      () => deliverReport("https://hook", { content: "c", embeds: [embed] }, { fetchFn }),
      DiscordPayloadError,
      `${JSON.stringify(embed)} must be refused`
    );
  }
});

test("an embed field this module cannot count is STILL refused", async () => {
  const fetchFn = async () => { throw new Error("must not reach the network"); };
  // The allowlist widened; it did not become a passthrough. `fields` carries
  // countable text this module does not know how to count, so permitting it
  // would silently break the combined-text arithmetic.
  await assert.rejects(
    () => deliverReport("https://hook", {
      content: "c",
      embeds: [{ title: "T", description: "D", fields: [{ name: "n", value: "v" }] }],
    }, { fetchFn }),
    /unsupported field fields/
  );
});
