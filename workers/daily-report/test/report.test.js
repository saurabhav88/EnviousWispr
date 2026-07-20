// Unit tests for the pure date-boundary / bucketing / message-formatting
// logic (no network). Run: node --test (from workers/daily-report/)
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  easternYesterdayWindowUTC,
  resolveBuckets,
  buildMessage,
  hogql,
  runLimited,
  fetchReportData,
  runReport,
  resolveDevIds,
  productionClauseFor,
  PostHogQueryError,
} from "../src/index.js";

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
  assert.match(msg, /New installs: 90\. People who finished setup today: 82\. Of those, 60 also dictated today\./);
  assert.doesNotMatch(msg, /for the first time/);
  assert.doesNotMatch(msg, /out of 90/); // no funnel-bleed wording (r1 fix)
  assert.match(msg, /Total users: 110 people used the app today\./);
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
  assert.match(msg, /Total users: 0 people used the app today\./);
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
  assert.match(msg, /People who finished setup today: 82\. Of those, 60 also dictated today\./);
  assert.match(msg, /Note: .*new installs/);
});

test("buildMessage: onboardActivateDegraded omits onboarding, keeps installs intact", () => {
  const msg = buildMessage("2026-07-08", { ...GOLDEN_DATA, onboardActivateDegraded: true }, GOLDEN_BUCKETS);
  assert.match(msg, /New installs: 90\./);
  assert.match(msg, /Onboarding and activation: temporarily unavailable\./);
  assert.doesNotMatch(msg, /People who finished setup today/);
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
  const src = fs.readFileSync(new URL("../src/index.js", import.meta.url), "utf8");
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
// by code review of the tierASql query text in src/index.js.

// ---- runLimited (#1588 - PostHog's 3-concurrent-query project limit) ----

test("runLimited: never exceeds the given concurrency and preserves input order", async () => {
  let inFlight = 0;
  let maxInFlight = 0;
  const tasks = [1, 2, 3, 4, 5].map(
    (n) => () =>
      new Promise((resolve) => {
        inFlight += 1;
        maxInFlight = Math.max(maxInFlight, inFlight);
        setTimeout(() => {
          inFlight -= 1;
          resolve(n);
        }, 5);
      })
  );
  const results = await runLimited(tasks, 2);
  assert.deepEqual(results, [1, 2, 3, 4, 5]);
  assert.ok(maxInFlight <= 2, `expected at most 2 concurrent tasks, saw ${maxInFlight}`);
});

test("runLimited: a failed wave rejects and never starts a later wave", async () => {
  let laterWaveStarted = false;
  const tasks = [
    () => Promise.resolve("ok"),
    () => Promise.reject(new Error("boom")),
    () => {
      laterWaveStarted = true;
      return Promise.resolve("should not run");
    },
  ];
  await assert.rejects(() => runLimited(tasks, 2), /boom/);
  assert.equal(laterWaveStarted, false);
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
  const noteIndex = msg.indexOf("Note: today's polish-provider breakdown");
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
  const src = fs.readFileSync(new URL("../src/index.js", import.meta.url), "utf8");

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
  const src = fs.readFileSync(new URL("../src/index.js", import.meta.url), "utf8");

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
  const src = fs.readFileSync(new URL("../src/index.js", import.meta.url), "utf8");

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
