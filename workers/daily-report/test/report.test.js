// Unit tests for the pure date-boundary / bucketing / message-formatting
// logic (no network). Run: node --test (from workers/daily-report/)
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  easternYesterdayWindowUTC,
  buildMessage,
  runReport,
} from "../src/index.js";
// #1838 chunk 2: the adoption domain has its own owner. Tests import from it
// directly - a re-export from index.js would be a forwarding shim.
import { fetchReportData, resolveBuckets } from "../src/adoption.js";
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
  releaseAgeInWindow,
} from "../src/version-scorecard.js";
import { formatScorecard, formatScorecardUnavailable } from "../src/report-format.js";
// #1838 chunk 1: the PostHog transport/concurrency/production-filter
// infrastructure now has ONE owner. Tests import it from there directly - a
// re-export from index.js would be a forwarding shim kept alive solely for
// tests, which this REFACTOR-tier change forbids.
import {
  hogql,
  runLimited,
  resolveDevIds,
  productionClauseFor,
  querySection,
  rowsToObjects,
  sqlIdList,
  sqlTimestamp,
  windowClause,
  PostHogQueryError,
} from "../src/lib/posthog.js";

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

// ---- buildMessage ----
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

test("buildMessage: golden fixture matches the founder-approved report shape", () => {
  const msg = buildMessage("2026-07-08", GOLDEN_DATA, GOLDEN_BUCKETS);

  assert.match(msg, /^EnviousWispr Daily Report, Wednesday, July 8, 2026/);
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

test("buildMessage: zero-count buckets are omitted, not shown as '(0%)'", () => {
  const msg = buildMessage("2026-07-08", GOLDEN_DATA, {
    engineBuckets: { parakeet: 110, whisperKit: 0 },
    polishBuckets: { appleIntelligence: 110, gemini: 0 },
  });
  assert.doesNotMatch(msg, /WhisperKit 0/);
  assert.doesNotMatch(msg, /Gemini 0/);
});

test("buildMessage: zero total_users omits the engine/polish section entirely (no divide-by-zero)", () => {
  const msg = buildMessage("2026-07-08", { ...GOLDEN_DATA, totalUsers: 0 }, { engineBuckets: {}, polishBuckets: {} });
  assert.doesNotMatch(msg, /Transcription engine/);
  assert.doesNotMatch(msg, /AI polishing/);
  assert.match(msg, /Total users: 0 people used the app that day\./);
});

// ---- buildMessage: per-section fail-soft degradation (#1720) ----
//
// Each of the 5 non-essential primary queries can independently degrade to
// "temporarily unavailable" - never a fabricated zero or empty list shown as
// real data - while the rest of the report still ships. `totals` never
// degrades (verified separately below via fetchReportData/runReport).

test("buildMessage: installsDegraded omits the freshInstalls number, keeps onboarding intact", () => {
  const msg = buildMessage("2026-07-08", { ...GOLDEN_DATA, installsDegraded: true }, GOLDEN_BUCKETS);
  assert.match(msg, /New installs: temporarily unavailable\./);
  assert.doesNotMatch(msg, /New installs: 90/);
  assert.match(msg, /People who finished setup that day: 82\. Of those, 60 also dictated that day\./);
  assert.match(msg, /Note: .*new installs/);
});

test("buildMessage: onboardActivateDegraded omits onboarding, keeps installs intact", () => {
  const msg = buildMessage("2026-07-08", { ...GOLDEN_DATA, onboardActivateDegraded: true }, GOLDEN_BUCKETS);
  assert.match(msg, /New installs: 90\./);
  assert.match(msg, /Onboarding and activation: temporarily unavailable\./);
  assert.doesNotMatch(msg, /People who finished setup that day/);
  assert.match(msg, /Note: .*onboarding\/activation/);
});

test("buildMessage: engineAndTierBDegraded omits both engine and polish lines, never fabricates a bucket", () => {
  const msg = buildMessage("2026-07-08", { ...GOLDEN_DATA, engineAndTierBDegraded: true }, GOLDEN_BUCKETS);
  assert.match(msg, /Transcription engine and AI-polish breakdown: temporarily unavailable\./);
  assert.doesNotMatch(msg, /Parakeet/);
  assert.doesNotMatch(msg, /Apple Intelligence/);
  assert.match(msg, /Note: .*transcription engine and AI-polish breakdown/);
});

test("buildMessage: geoDegraded omits the countries line, not an empty list shown as zero data", () => {
  const msg = buildMessage("2026-07-08", { ...GOLDEN_DATA, geoDegraded: true }, GOLDEN_BUCKETS);
  assert.match(msg, /Where they are: temporarily unavailable\./);
  assert.doesNotMatch(msg, /Germany/);
  assert.match(msg, /Note: .*where they are/);
});

test("buildMessage: top5Degraded omits the top-users line", () => {
  const msg = buildMessage("2026-07-08", { ...GOLDEN_DATA, top5Degraded: true }, GOLDEN_BUCKETS);
  assert.match(msg, /Top 5 users by dictation volume: temporarily unavailable\./);
  assert.doesNotMatch(msg, /557, 139/);
  assert.match(msg, /Note: .*top 5 users/);
});

test("buildMessage: multiple degraded sections all appear in one combined note", () => {
  const msg = buildMessage(
    "2026-07-08",
    { ...GOLDEN_DATA, installsDegraded: true, geoDegraded: true },
    GOLDEN_BUCKETS
  );
  const noteLine = msg.split("\n").find((l) => l.startsWith("Note:"));
  assert.ok(noteLine, "expected one combined Note line");
  assert.match(noteLine, /new installs/);
  assert.match(noteLine, /where they are/);
});

test("buildMessage: totals never has a degrade flag - no such branch exists", () => {
  // totals staying fail-loud means fetchReportData/runReport throw before
  // buildMessage is ever called with degraded totals data - there is no
  // totalsDegraded field to test here by design (see fetchReportData tests).
  const msg = buildMessage("2026-07-08", GOLDEN_DATA, GOLDEN_BUCKETS);
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
// These MUST drive fetchReportData, not hogql in isolation: the defect they
// guard against (a blanket catch silently swallowing real errors) lives in
// fetchReportData's catch, so a test that only exercises hogql would pass even
// with the guard broken. fetchReportData calls hogql without an injectable
// fetchFn, so the mock is installed on globalThis.fetch and dispatches on the
// query name the worker puts in the request body.

/** Installs a global fetch that lets every batch query (including the new
 * dev_ids preflight) succeed and lets the caller decide what one named query
 * does. Also transparently succeeds any non-PostHog call (the Discord
 * webhook POST runReport makes after a successful report - its body is
 * `{content}`, with no `.name` field, unlike every hogql() request body) so
 * tests can drive runReport end-to-end, not just fetchReportData. Returns a
 * restore fn. */
function mockPostHog({ failQuery, failWith }) {
  const realFetch = globalThis.fetch;
  const seen = [];
  globalThis.fetch = async (_url, init) => {
    const body = init?.body ? JSON.parse(init.body) : {};
    if (!body.name) {
      return fakeResponse(204); // Discord webhook success shape, not a PostHog call
    }
    const queryName = body.name.replace(/^daily_report_/, "");
    seen.push(queryName);
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
    return fakeResponse(200, { results: [[0]], columns: ["c"] });
  };
  return { restore: () => (globalThis.fetch = realFetch), seen };
}

const TEST_ENV = { POSTHOG_PROJECT_ID: "x", POSTHOG_PERSONAL_API_KEY: "k" };
const TEST_WIN = "timestamp >= '2026-07-17 04:00:00' AND timestamp < '2026-07-18 04:00:00'";
const TEST_END = new Date("2026-07-18T04:00:00Z");

test("tier-a: an exhausted 504 degrades instead of failing the whole report", async () => {
  const mock = mockPostHog({ failQuery: "tier_a", failWith: 504 });
  try {
    const data = await fetchReportData(TEST_ENV, TEST_WIN, TEST_END, { sleepFn: async () => {} });
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
      const data = await fetchReportData(TEST_ENV, TEST_WIN, TEST_END, { sleepFn: async () => {} });
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
      () => fetchReportData(TEST_ENV, TEST_WIN, TEST_END, { sleepFn: async () => {} }),
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
      () => fetchReportData(TEST_ENV, TEST_WIN, TEST_END, { sleepFn: async () => {} }),
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
      () => fetchReportData(TEST_ENV, TEST_WIN, TEST_END, { sleepFn: async () => {} }),
      /PostHog query totals HTTP 504/,
      "totals must never degrade - it anchors resolveBuckets' completeness check"
    );
  } finally {
    mock.restore();
  }
});

test("resolveDevIds: an exhausted 504 fails the whole report, never silently treated as 'no dev ids'", async () => {
  const mock = mockPostHog({ failQuery: "dev_ids", failWith: 504 });
  try {
    await assert.rejects(
      () => fetchReportData(TEST_ENV, TEST_WIN, TEST_END, { sleepFn: async () => {} }),
      /PostHog query dev_ids HTTP 504/
    );
  } finally {
    mock.restore();
  }
});

test("a clean run leaves tierADegraded false and every other degraded flag false", async () => {
  const mock = mockPostHog({ failQuery: null });
  try {
    const data = await fetchReportData(TEST_ENV, TEST_WIN, TEST_END, { sleepFn: async () => {} });
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
      const data = await fetchReportData(TEST_ENV, TEST_WIN, TEST_END, { sleepFn: async () => {} });
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
        () => fetchReportData(TEST_ENV, TEST_WIN, TEST_END, { sleepFn: async () => {} }),
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
    const data = await fetchReportData(TEST_ENV, TEST_WIN, TEST_END, { sleepFn: async () => {} });
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
    assert.match(message, /Transcription engine and AI-polish breakdown: temporarily unavailable\./);
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

test("degraded note appears near the top, above the truncation point", () => {
  // A long report: enough geo/top5 volume to push the tail past the 1990-char
  // cap, proving the note survives exactly when it matters most.
  const data = {
    ...GOLDEN_DATA,
    tierADegraded: true,
    geo: Array.from({ length: 60 }, (_, i) => ({ country: `Country-With-A-Long-Name-${i}`, n: i })),
  };
  const msg = buildMessage("2026-07-17", data, GOLDEN_BUCKETS);

  assert.match(msg, /polish-provider breakdown is approximate/);
  assert.ok(msg.length <= 1990, "message must respect the Discord cap");
  const noteIndex = msg.indexOf("Note: the polish-provider breakdown is approximate");
  assert.ok(noteIndex >= 0 && noteIndex < 200, `note must be near the top, was at ${noteIndex}`);
});

test("no degraded note on a clean run", () => {
  const msg = buildMessage("2026-07-17", { ...GOLDEN_DATA, tierADegraded: false }, GOLDEN_BUCKETS);
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

test("worst-case explicit fetch count stays under Cloudflare's 50-subrequest cap", () => {
  const PRIMARY_QUERIES = 6; // installs, onboard_activate, totals, engine_and_tier_b, geo, top5
  const PREFLIGHT_QUERIES = 1; // resolveDevIds
  const CONDITIONAL_QUERIES = 1; // tier_a, only when activeIds is non-empty
  const MAX_ATTEMPTS_PER_QUERY = 3; // #1720 raised this from 2
  const DISCORD_POSTS = 1;

  const worstCase =
    (PRIMARY_QUERIES + PREFLIGHT_QUERIES + CONDITIONAL_QUERIES) * MAX_ATTEMPTS_PER_QUERY + DISCORD_POSTS;

  assert.equal(worstCase, 25);
  assert.ok(worstCase < 50, "worst-case fetch count must stay under Cloudflare's 50-subrequest-per-request cap");
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
    ["polish_kept", "2.3.0", null],
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

  const unavailable = decideComparability("polish_kept", ["2.4.1", "2.3.0"]);
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
  const boundarySpec = {
    "2.4.1": Array(8).fill(5),
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
  assert.match(text, /84\.8% of successful dictations across 2 releases/,
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
  assert.match(unavailable, /adoption figures above are unaffected/);
  for (const leak of ["http", "Error", "https://", "500", "PostHog"]) {
    assert.ok(!unavailable.includes(leak), `failure copy must not leak ${leak}`);
  }
});
