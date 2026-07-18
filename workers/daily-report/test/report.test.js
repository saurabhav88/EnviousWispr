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

// ---- hogql retry (#1588 - PostHog project concurrency limit / 504s) ----

function fakeResponse(status, body, { onCancel } = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    body: onCancel ? { cancel: async () => onCancel() } : undefined,
  };
}

test("hogql: retries once on 504 then succeeds, without a real delay", async () => {
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
  });
  assert.deepEqual(json.results, [[1]]);
  assert.equal(calls, 2);
  assert.deepEqual(sleeps, [1500]);
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

test("hogql: throws with the query name after exhausting retries on repeated 504", async () => {
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
  assert.equal(calls, 2, "expected exactly 2 attempts total");
});

// ---- tier-a fail-soft boundary (#1655) ----
//
// These MUST drive fetchReportData, not hogql in isolation: the defect they
// guard against (a blanket catch silently swallowing real errors) lives in
// fetchReportData's catch, so a test that only exercises hogql would pass even
// with the guard broken. fetchReportData calls hogql without an injectable
// fetchFn, so the mock is installed on globalThis.fetch and dispatches on the
// query name the worker puts in the request body.

/** Installs a global fetch that lets every batch query succeed and lets the
 * caller decide what tier-a (or a named other query) does. Returns a restore fn. */
function mockPostHog({ failQuery, failWith }) {
  const realFetch = globalThis.fetch;
  const seen = [];
  globalThis.fetch = async (_url, init) => {
    const name = JSON.parse(init.body).name; // "daily_report_<queryName>"
    const queryName = name.replace(/^daily_report_/, "");
    seen.push(queryName);
    if (queryName === failQuery) {
      if (failWith instanceof Error) throw failWith;
      return fakeResponse(failWith);
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

test("a failure in a query OTHER than tier-a still fails the whole report", async () => {
  const mock = mockPostHog({ failQuery: "totals", failWith: 504 });
  try {
    await assert.rejects(
      () => fetchReportData(TEST_ENV, TEST_WIN, TEST_END, { sleepFn: async () => {} }),
      /PostHog query totals HTTP 504/,
      "fail-soft is scoped to tier-a only"
    );
  } finally {
    mock.restore();
  }
});

test("a clean run leaves tierADegraded false", async () => {
  const mock = mockPostHog({ failQuery: null });
  try {
    const data = await fetchReportData(TEST_ENV, TEST_WIN, TEST_END, { sleepFn: async () => {} });
    assert.equal(data.tierADegraded, false);
    assert.equal(data.tierA.length, 1);
  } finally {
    mock.restore();
  }
});

// ---- degraded note placement (#1655) ----

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
});

// ---- load-bearing coupling guard (#1655) ----
//
// tier-a may omit PROD's dev-ID exclusion ONLY because activeIds already came
// from a full-PROD query. If a future edit breaks that coupling, the omission
// silently becomes a correctness bug rather than a redundancy removal.

test("source guardrail: tier-a may omit dev exclusion only while active ids come from full PROD", async () => {
  const fs = await import("node:fs");
  const src = fs.readFileSync(new URL("../src/index.js", import.meta.url), "utf8");

  const engineQuery = src.match(/const engineAndTierBSql = `([\s\S]*?)`;/)?.[1];
  assert.ok(engineQuery, "expected engineAndTierBSql");
  assert.match(engineQuery, /\$\{PROD\}/);

  const tierAFunction = src.match(/function tierASqlFor\([\s\S]*?\n}\n/)?.[0];
  assert.ok(tierAFunction, "expected tierASqlFor");
  assert.match(tierAFunction, /properties\.environment = 'production'/);
  assert.doesNotMatch(tierAFunction, /\$\{PROD\}/);
  assert.equal(
    (tierAFunction.match(/distinct_id IN \(\$\{ids\}\)/g) || []).length,
    2,
    "both tier-a UNION branches must remain restricted to the pre-filtered active-id list"
  );
});
