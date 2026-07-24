/**
 * EnviousWispr Daily Product-Health Check - Cloudflare Worker (issue #1092)
 *
 * Runs once a day (cron) plus a manual HTTP trigger. Reads existing product
 * events from PostHog over COMPLETED time windows, compares each metric to a
 * baseline-calibrated threshold with low-volume guards, and posts to Discord:
 *   - a heartbeat block EVERY run (carries the day's dictation volume +
 *     which metrics evaluated / were skipped / are dark / temporarily
 *     unavailable), so a silent worker death or a telemetry blackout is
 *     itself visible;
 *   - a louder alert block when a metric crosses.
 *
 * Message text is plain English (issue #1589) - no internal field names or
 * abbreviations in anything posted to Discord.
 *
 * Reliability (issue #1589, porting workers/daily-report's already-shipped
 * #1588/#1655/#1716/#1720 fixes): PostHog allows only 3 concurrent queries
 * per project, so queries run in capped waves with retry on 429/502/503/504;
 * the dev-id exclusion is resolved ONCE per run, not once per query; a
 * non-essential query's exhausted retry degrades only the metrics it feeds
 * (see evaluateHealthData) instead of discarding the whole run.
 *
 * Advisory only. Gates nothing. Plan + thresholds:
 *   docs/feature-requests/issue-1092-2026-06-20-daily-product-health-check.md
 *   docs/feature-requests/issue-1589-2026-07-24-product-health-reliability-and-plain-english.md
 *
 * Privacy: output and logs are counts / rates / version-tags only. Never an
 * error_code string, never a raw PostHog row, never a per-user id.
 */

const POSTHOG_HOST = "https://us.posthog.com";
const DASHBOARD = "https://us.posthog.com/project/354235/dashboard/1391797";

// All thresholds in one place for easy tuning. Calibrated to production
// baselines queried 2026-06-20 (see plan section 1).
export const THRESHOLDS = {
  latency: { minN: 50, p50: 2.5, p95: 9.0, sustainDays: 2, driftWindowDays: 14 },
  paste: { minTotal: 50, share: 0.05 },
  afm: { minFrRows: 50, minDiscards: 10, share: 0.15 },
  transcription: { minDictations: 200, share: 0.05 },
  volume: { activeBaselineAvg: 20 },
  // Phase 10 (#1179): calibrated 2026-07-15 against real 21d/14d baselines
  // (see plan section 1). onboardingAbandon/backendTranscription each carry a
  // rolling share/minN pair AND a fast-path pair (2-day sustained crossing,
  // checked first and independently — canonical contract O1/B1 in the plan).
  onboardingAbandon: { minStarted: 30, share: 0.5, fastMinStarted: 8, fastDays: 2 },
  backendTranscription: { minAttempts: 200, share: 0.08, fastMinAttempts: 20, fastDays: 2 },
  onboardingBlackout: { recentDays: 2, baselineDays: 7, activeBaselineAvg: 8, terminalMinStarted: 8 },
};

export default {
  async scheduled(event, env) {
    await runHealth(env);
  },
  async fetch(request, env) {
    // Manual trigger is secret-gated: the workers.dev URL is public, so an
    // unauthenticated request must NOT run the check or post to Discord (it
    // would spam the channel + burn PostHog quota). Fail closed.
    const url = new URL(request.url);
    const provided = url.searchParams.get("token") || request.headers.get("x-trigger-secret");
    if (!env.TRIGGER_SECRET || provided !== env.TRIGGER_SECRET) {
      return new Response("unauthorized\n", { status: 401 });
    }
    try {
      const summary = await runHealth(env);
      return new Response(summary + "\n", { status: 200 });
    } catch (err) {
      return new Response("health check failed: " + err.message + "\n", { status: 500 });
    }
  },
};

// ----- PostHog -------------------------------------------------------------

// Environment predicate alone; combined with the resolved dev-id exclusion by
// productionClauseFor() below. Bare field names do not resolve in HogQL, so
// every property reference is prefixed `properties.`.
const ENV_ONLY = "properties.environment = 'production'";

/** Converts a resolved dev-tainted distinct_id list (from resolveDevIds
 * below) into the reusable production-filter predicate: environment =
 * production, AND (only if any dev ids exist) NOT IN that literal list.
 * Resolving the list ONCE per run and threading the result through every
 * query that needs it replaces the old per-query live dev-exclusion
 * subquery, which independently re-scanned the same whole-history data in
 * 8 separate top-level queries (issue #1589, porting workers/daily-report's
 * #1720 fix - RULE: founder-machine-tell-in-distinct-id: a dev build
 * anywhere in an id's history marks the whole id as dogfood). An empty list
 * is a legitimate state and must not produce invalid `NOT IN ()` SQL. */
export function productionClauseFor(devIds) {
  if (devIds.length === 0) return ENV_ONLY;
  return `${ENV_ONLY}
    AND distinct_id NOT IN (${sqlIdList(devIds)})`;
}

/** Escapes a distinct_id for a HogQL string literal (single-quote doubling -
 * distinct_ids are opaque PostHog-generated ids, never user-authored text). */
function sqlIdList(ids) {
  return ids.map((id) => `'${String(id).replace(/'/g, "''")}'`).join(", ");
}

// Per-worker distinct_id list bound - defense-in-depth ceiling, never the
// primary correctness mechanism (see resolveDevIds below). 5000 is far above
// any realistic single-day population.
const PER_USER_LIST_LIMIT = 5000;

/** Resolves the whole-history dev-tainted distinct_id list ONCE per run.
 * Queried at PER_USER_LIST_LIMIT+1 to detect overflow: if the true count
 * exceeds the ceiling, this throws rather than silently building a
 * truncated exclusion list that would under-exclude dev accounts from
 * production totals - fail loud, not warn-and-continue. This is itself a
 * fail-loud query: an unresolved dev-id list can never safely be treated as
 * "no dev accounts," so callers must never wrap it in querySection's fail-
 * soft catch. */
export async function resolveDevIds(env, hogqlOpts = {}) {
  const result = await hogql(
    env,
    `SELECT DISTINCT distinct_id FROM events
     WHERE properties.app_version LIKE '%-dev%'
     LIMIT ${PER_USER_LIST_LIMIT + 1}`,
    "dev_ids",
    hogqlOpts
  );
  const devIds = (result.results || []).map((row) => row[0]);
  if (devIds.length > PER_USER_LIST_LIMIT) {
    throw new Error(`dev-id completeness check failed: more than ${PER_USER_LIST_LIMIT} ids`);
  }
  return devIds;
}

// PostHog's project-level rate limit allows only 3 concurrent queries, up to
// 10s execution time per query, and queues/cancels/times out (HTTP
// 502/503/504) anything beyond that; 429 is the documented, distinct
// concurrency-limit-reached status (posthog.com/docs/api/queries,
// posthog.com/docs/endpoints/troubleshooting). `runLimited` below caps this
// worker's own concurrency under that ceiling; this retry is the second,
// complementary layer for genuine transient contention (e.g. the project is
// shared with EnviousStaging - analytics-operations.md FACT:
// posthog-project-is-shared-with-enviousstaging). Retries up to twice (3
// attempts total), only on this status class, only ever before any Discord
// post happens.
const RETRYABLE_POSTHOG_STATUSES = new Set([429, 502, 503, 504]);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Randomized backoff windows for retry attempts 2 and 3 (ported from
// workers/daily-report's #1588/#1720 shipped precedent).
const RETRY_DELAY_RANGES_MS = [
  [12_000, 18_000],
  [30_000, 45_000],
];

function retryDelayMs(range, randomFn) {
  const [min, max] = range;
  return Math.floor(min + randomFn() * (max - min + 1));
}

/** Carries the query name and HTTP status alongside the message, so a caller
 * can distinguish an exhausted transient failure (which a degradable query
 * is allowed to degrade on) from an auth failure, a malformed query, or a
 * bad response shape (which must stay loud). */
export class PostHogQueryError extends Error {
  constructor(queryName, status) {
    super(`PostHog query ${queryName} HTTP ${status}`);
    this.name = "PostHogQueryError";
    this.queryName = queryName;
    this.status = status;
  }
}

export async function hogql(
  env,
  sql,
  queryName,
  { fetchFn = fetch, sleepFn = sleep, randomFn = Math.random } = {}
) {
  const url = `${POSTHOG_HOST}/api/projects/${env.POSTHOG_PROJECT_ID}/query/`;
  const maxAttempts = RETRY_DELAY_RANGES_MS.length + 1;

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    const res = await fetchFn(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.POSTHOG_PERSONAL_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        query: { kind: "HogQLQuery", query: sql },
        refresh: "blocking",
        name: `product_health_${queryName}`,
      }),
    });

    if (res.ok) {
      const json = await res.json();
      if (!json.results) throw new Error(`PostHog query ${queryName} returned no results array`);
      return json; // { results: [...rows], columns: [...] }
    }

    const status = res.status;
    if (res.body) {
      try {
        await res.body.cancel();
      } catch (_) {
        // Best effort: the status remains the authoritative failure, and a
        // failed cancel must not mask it. Draining the failed body matters
        // because a retry immediately opens a new outbound request on the
        // same wave - an uncancelled body can hold its Cloudflare
        // subrequest connection open.
      }
    }

    if (attempt === maxAttempts || !RETRYABLE_POSTHOG_STATUSES.has(status)) {
      throw new PostHogQueryError(queryName, status);
    }
    await sleepFn(retryDelayMs(RETRY_DELAY_RANGES_MS[attempt - 1], randomFn));
  }
}

// Runs `tasks` (zero-arg async thunks) in fixed waves of at most `limit`
// concurrently, preserving input order in the returned results. A failed
// wave stops later waves from starting, matching `Promise.all`'s existing
// all-or-nothing contract for the whole batch.
export async function runLimited(tasks, limit) {
  if (!Number.isInteger(limit) || limit < 1) {
    throw new TypeError("limit must be a positive integer");
  }
  const results = [];
  for (let start = 0; start < tasks.length; start += limit) {
    const wave = tasks.slice(start, start + limit);
    results.push(...(await Promise.all(wave.map((task) => task()))));
  }
  return results;
}

/** Runs one hogql() call and reports whether it degraded instead of
 * throwing. Only an EXHAUSTED retryable status (RETRYABLE_POSTHOG_STATUSES,
 * after hogql's own retries) degrades; anything else - auth, bad SQL, a
 * malformed response, a programming error - still throws. A silently
 * "approximate" report that hides a real defect is worse than no report. */
async function querySection(env, sql, queryName, hogqlOpts) {
  try {
    return { response: await hogql(env, sql, queryName, hogqlOpts), degraded: false };
  } catch (err) {
    const isExpectedTransientFailure =
      err instanceof PostHogQueryError &&
      err.queryName === queryName &&
      RETRYABLE_POSTHOG_STATUSES.has(err.status);
    if (!isExpectedTransientFailure) throw err;
    console.log(`product-health ${queryName} degraded after retries: HTTP ${err.status}`);
    return { response: null, degraded: true };
  }
}

// Completed-window helpers: every window ends at the start of today (UTC), so
// the partial current day (and late-flushing offline laptops) is excluded.
const DAY = "toStartOfDay(now())"; // ClickHouse/PostHog default timezone is UTC

// `hogqlOpts` forwards the injection bag `hogql` already accepts, so tests can
// drive the retry path without real backoff delays. Production passes nothing.
export async function fetchHealth(env, hogqlOpts = {}) {
  // The expected T-1 date per PostHog's own clock. Used to detect a zero-event
  // T-1: the GROUP BY day query emits NO row for a day with zero events, so we
  // must look T-1 up by date rather than trust the newest row.
  const refSql = `SELECT toString(toDate(toStartOfDay(now()) - INTERVAL 1 DAY)) AS t1`;

  // refSql and the dev-id resolution both stay fail-loud and run first: every
  // other query below depends on the T-1 date or the production filter (or
  // both), so there is nothing left to meaningfully degrade around if either
  // of these fails (issue #1589 §2.5 point 4).
  const [ref, devIds] = await Promise.all([
    hogql(env, refSql, "ref", hogqlOpts),
    resolveDevIds(env, hogqlOpts),
  ]);
  const prod = productionClauseFor(devIds);

  // 1) Per-day latency for the last 14 complete days (covers the 2-qualifying-day
  //    sustained check AND the 14d drift median). Degradable: feeds only the
  //    latency alert and the heartbeat's response-speed line.
  const latencySql = `
    SELECT toDate(timestamp) AS day, count() AS n,
           round(quantile(0.5)(toFloat(properties.e2e_seconds)), 3) AS p50,
           round(quantile(0.95)(toFloat(properties.e2e_seconds)), 3) AS p95
    FROM events
    WHERE event = 'dictation.completed' AND ${prod}
      AND properties.e2e_seconds IS NOT NULL
      AND timestamp >= ${DAY} - INTERVAL 14 DAY AND timestamp < ${DAY}
    GROUP BY day ORDER BY day DESC`;

  // 2) The four 7d rate metrics in one pass (previous 7 complete days).
  //    Degradable, but degrades paste + AFM + transcription TOGETHER (they
  //    share this one query), and also disables the backend-attribution-
  //    blackout check, which needs dictations_7d as its own volume proof
  //    (issue #1589 §2.5 point 4 - this query is NOT "one query, one metric").
  const sevenDaySql = `
    SELECT
      countIf(event = 'paste.completed') AS paste_total,
      countIf(event = 'paste.completed' AND properties.tier = 'clipboard_only') AS paste_cb,
      countIf(event = 'paste.completed' AND properties.tier = 'clipboard_only_ax_denied') AS paste_ax,
      countIf(event = 'llm.polish_completed' AND properties.provider = 'appleIntelligence'
              AND properties.fallback_reason IS NOT NULL) AS afm_fr_rows,
      countIf(event = 'llm.polish_completed' AND properties.provider = 'appleIntelligence'
              AND properties.fallback_reason IN ('guard_discard', 'validator_discard')) AS afm_disc,
      countIf(event = 'pipeline.failed' AND properties.stage = 'transcription') AS trans_fails,
      countIf(event = 'dictation.completed') AS dictations_7d
    FROM events
    WHERE ${prod}
      AND event IN ('paste.completed', 'llm.polish_completed', 'pipeline.failed', 'dictation.completed')
      AND timestamp >= ${DAY} - INTERVAL 7 DAY AND timestamp < ${DAY}`;

  // 3) Per-day volume + co-firing counts for the last 8 complete days
  //    (T-1 vs the 7 days before it; co-firing blackout = schema drift).
  //    Fail-loud: this owns the heartbeat's headline dictation count and the
  //    zero/drift integrity alerts - a heartbeat with no volume number is not
  //    a heartbeat.
  const volumeSql = `
    SELECT toDate(timestamp) AS day,
           countIf(event = 'dictation.completed') AS dictations,
           countIf(event = 'paste.completed') AS pastes,
           countIf(event = 'asr.completed') AS asr
    FROM events
    WHERE ${prod} AND event IN ('dictation.completed', 'paste.completed', 'asr.completed')
      AND timestamp >= ${DAY} - INTERVAL 8 DAY AND timestamp < ${DAY}
    GROUP BY day ORDER BY day DESC`;

  // 4) Top app-versions for the crossing-prone metrics (one pass, 7d).
  //    Degradable, enrichment-only: never suppresses the paste/AFM/
  //    transcription alerts themselves, only their "top versions" detail.
  const versionSql = `
    SELECT properties.app_version AS ver,
           countIf(event = 'paste.completed' AND properties.tier LIKE 'clipboard_only%') AS paste_fb,
           countIf(event = 'pipeline.failed' AND properties.stage = 'transcription') AS trans_fail,
           countIf(event = 'llm.polish_completed'
                   AND properties.fallback_reason IN ('guard_discard', 'validator_discard')) AS afm_disc
    FROM events
    WHERE ${prod}
      AND event IN ('paste.completed', 'pipeline.failed', 'llm.polish_completed')
      AND timestamp >= ${DAY} - INTERVAL 7 DAY AND timestamp < ${DAY}
    GROUP BY ver ORDER BY (paste_fb + trans_fail + afm_disc) DESC LIMIT 5`;

  // 5) Phase 10 (#1179): per-day onboarding funnel, 21 complete days (covers
  //    the rolling baseline AND the fast path AND the blackout's 9-day need).
  // `onboarding.started` fires ONLY on the "Get Started" click
  // (OnboardingV2View.swift:670); `onboarding.abandoned` can fire earlier, on
  // a welcome-screen close BEFORE that click (OnboardingProgress.swift's
  // `begin()` runs at presentation, not at Get-Started) — that session never
  // emitted `started`. Excluding `screen = 'welcome'` abandons matches the
  // denominator to sessions that actually started (Codex review finding).
  //
  // Known residual limitation (Codex review, second round): a user who
  // reopens the reused onboarding window after abandoning past `welcome` (via
  // "Continue Setup...") gets a FRESH in-memory session per `begin()`
  // (`OnboardingProgress.swift`) without a fresh `onboarding.started`, since
  // that event fires only from the "Get Started" button and the reused
  // window resumes at the last observed screen. Each such reopen-then-close
  // adds one non-welcome abandon with no matching start. Fixing this fully
  // requires either a new started-per-reopen event (violates this phase's
  // explicit no-new-app-telemetry non-goal) or query-side session pairing
  // this worker's HogQL has no other precedent for. Accepted, matching the
  // project's own precedent for telemetry-model ambiguities it cannot
  // perfectly resolve from existing events (e.g. the paste-only-copy
  // ambiguity `evaluateVolume` already accepts, #1130).
  // `abandonedRaw` (no screen filter) alongside the filtered `abandoned`:
  // ClickHouse's `!=` is NULL-unsafe, so if `properties.screen` ever stops
  // emitting (schema drift), every abandon silently reads as "welcome" and
  // gets excluded — `abandoned` would read a healthy zero while abandon
  // activity is actually still happening.
  //
  // `abandonedMissingScreen` counts the drift signal DIRECTLY (NULL/empty
  // `properties.screen`) rather than inferring it from `abandonedRaw -
  // abandoned` (Codex r4 review finding): a legitimate concentration of
  // abandons on the real "welcome" screen also produces `abandonedRaw > 0`
  // with `abandoned === 0`, which is healthy, correctly-tagged data, not
  // drift, and the old raw-vs-filtered inference could not tell the two
  // apart.
  // 5) Degradable, but degrades BOTH onboarding evaluators together - they
  //    share this one query's rows (issue #1589 §2.5 point 4).
  const onboardingSql = `
    SELECT toDate(timestamp) AS day,
           countIf(event = 'onboarding.started') AS started,
           countIf(event = 'onboarding.completed') AS completed,
           countIf(event = 'onboarding.abandoned' AND properties.screen != 'welcome') AS abandoned,
           countIf(event = 'onboarding.abandoned') AS abandonedRaw,
           countIf(event = 'onboarding.abandoned' AND (properties.screen IS NULL OR properties.screen = '')) AS abandonedMissingScreen
    FROM events
    WHERE ${prod}
      AND event IN ('onboarding.started', 'onboarding.completed', 'onboarding.abandoned')
      AND timestamp >= ${DAY} - INTERVAL 21 DAY AND timestamp < ${DAY}
    GROUP BY day ORDER BY day DESC`;

  // 6) Phase 10 (#1179): per-day, per-backend transcription attempts, 14
  //    complete days. Backend enumeration comes from EITHER event's backend
  //    tag (dictation.completed's asr_backend, pipeline.failed's backend) —
  //    canonical contract B2: an active backend with zero matching failures
  //    still gets a row (fails: 0), never silently drops. Degradable, but
  //    degrades the per-backend evaluation AND backend-attribution-blackout
  //    together - a degraded query must read as "we couldn't check this,"
  //    never get reinterpreted as "zero backends found = blackout" (issue
  //    #1589 §2.5 point 4).
  const backendTranscriptionSql = `
    SELECT toDate(timestamp) AS day,
           coalesce(properties.asr_backend, properties.backend) AS backend,
           countIf(event = 'dictation.completed') AS dictations,
           countIf(event = 'pipeline.failed' AND properties.stage = 'transcription') AS fails
    FROM events
    WHERE ${prod}
      AND ((event = 'dictation.completed')
        OR (event = 'pipeline.failed' AND properties.stage = 'transcription'))
      AND timestamp >= ${DAY} - INTERVAL 14 DAY AND timestamp < ${DAY}
    GROUP BY day, backend ORDER BY day DESC`;

  // 7) Phase 10 (#1179) per-release segmentation, matching each metric's own
  //    window (§3 Design "Per-release segmentation"). Degradable, enrichment-
  //    only: never suppresses the onboarding-abandon rolling alert itself.
  const onboardingVersionSql = `
    SELECT properties.app_version AS ver,
           countIf(event = 'onboarding.abandoned' AND properties.screen != 'welcome') AS onboarding_abandon
    FROM events
    WHERE ${prod} AND event = 'onboarding.abandoned'
      AND timestamp >= ${DAY} - INTERVAL 21 DAY AND timestamp < ${DAY}
    GROUP BY ver ORDER BY onboarding_abandon DESC LIMIT 5`;

  // LIMIT is generous (not per-backend) headroom, not a per-backend cap: a
  // global LIMIT 10 could let one high-volume backend's rows crowd out a
  // second backend's rows entirely, since `topVersionsFor` filters BY backend
  // only after this query returns (Codex review finding). Two backends today
  // (Parakeet, WhisperKit) with `limit: 3` displayed each means 40 comfortably
  // covers both without a per-backend-ranked subquery this codebase has no
  // other precedent for. Degradable, enrichment-only.
  const backendVersionSql = `
    SELECT properties.app_version AS ver,
           properties.backend AS backend,
           countIf(event = 'pipeline.failed' AND properties.stage = 'transcription') AS backend_trans_fail
    FROM events
    WHERE ${prod} AND event = 'pipeline.failed' AND properties.stage = 'transcription'
      AND timestamp >= ${DAY} - INTERVAL 14 DAY AND timestamp < ${DAY}
    GROUP BY ver, backend ORDER BY backend_trans_fail DESC LIMIT 40`;

  // PostHog allows only 3 concurrent queries per project (posthog-project-
  // concurrency-limit); `runLimited(..., 2)` runs these 8 in 4 fixed waves of
  // 2, leaving one slot of headroom for the shared project's other traffic
  // (EnviousStaging) rather than firing all 8 at once. `volumeSql` is the
  // sole fail-loud member of this batch (mirrors daily-report's `totals`);
  // the other 7 go through `querySection` and degrade to "temporarily
  // unavailable" instead of discarding the whole run on an exhausted
  // transient failure.
  const [latencyResult, sevenDayResult, volume, versionsResult, onboardingResult, backendTranscriptionResult, onboardingVersionsResult, backendVersionsResult] =
    await runLimited(
      [
        () => querySection(env, latencySql, "latency", hogqlOpts),
        () => querySection(env, sevenDaySql, "seven_day", hogqlOpts),
        () => hogql(env, volumeSql, "volume", hogqlOpts),
        () => querySection(env, versionSql, "versions", hogqlOpts),
        () => querySection(env, onboardingSql, "onboarding", hogqlOpts),
        () => querySection(env, backendTranscriptionSql, "backend_transcription", hogqlOpts),
        () => querySection(env, onboardingVersionSql, "onboarding_versions", hogqlOpts),
        () => querySection(env, backendVersionSql, "backend_versions", hogqlOpts),
      ],
      2
    );

  return {
    latencyDays: latencyResult.degraded ? [] : rowsToObjects(latencyResult.response),
    latencyDegraded: latencyResult.degraded,
    seven: sevenDayResult.degraded ? {} : rowsToObjects(sevenDayResult.response)[0] || {},
    sevenDayDegraded: sevenDayResult.degraded,
    volumeDays: rowsToObjects(volume),
    versions: versionsResult.degraded ? [] : rowsToObjects(versionsResult.response),
    versionsDegraded: versionsResult.degraded,
    t1ref: (rowsToObjects(ref)[0] || {}).t1,
    onboardingDays: onboardingResult.degraded ? [] : rowsToObjects(onboardingResult.response),
    onboardingDegraded: onboardingResult.degraded,
    backendTranscriptionDays: backendTranscriptionResult.degraded
      ? {}
      : groupByBackend(rowsToObjects(backendTranscriptionResult.response)),
    backendTranscriptionDegraded: backendTranscriptionResult.degraded,
    onboardingVersions: onboardingVersionsResult.degraded ? [] : rowsToObjects(onboardingVersionsResult.response),
    onboardingVersionsDegraded: onboardingVersionsResult.degraded,
    backendVersions: backendVersionsResult.degraded ? [] : rowsToObjects(backendVersionsResult.response),
    backendVersionsDegraded: backendVersionsResult.degraded,
  };
}

function groupByBackend(rows) {
  const grouped = {};
  for (const row of rows) {
    const backend = row.backend || "unknown";
    (grouped[backend] || (grouped[backend] = [])).push(row);
  }
  return grouped;
}

function rowsToObjects(res) {
  const cols = res.columns || [];
  return (res.results || []).map((row) => {
    const o = {};
    cols.forEach((c, i) => (o[c] = row[i]));
    return o;
  });
}

// ----- Pure evaluation (unit-tested, no IO) --------------------------------

function median(nums) {
  if (!nums.length) return null;
  const s = [...nums].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

export function evaluateLatency(days, TH = THRESHOLDS.latency) {
  const qualifying = days.filter((d) => d.n >= TH.minN);
  const driftMedian = median(qualifying.slice(0, TH.driftWindowDays).map((d) => d.p50));
  if (qualifying.length === 0) return { state: "skipped-low-volume", driftMedian };
  const last2 = qualifying.slice(0, TH.sustainDays);
  const crossing =
    last2.length === TH.sustainDays &&
    last2.every((d) => d.p50 > TH.p50 || d.p95 > TH.p95);
  return {
    state: crossing ? "alerting" : "evaluated-ok",
    latest: qualifying[0],
    last2,
    driftMedian,
  };
}

export function evaluatePaste(row, TH = THRESHOLDS.paste) {
  const total = num(row.paste_total);
  const cb = num(row.paste_cb);
  const ax = num(row.paste_ax);
  const fb = cb + ax;
  if (total < TH.minTotal) return { state: "skipped-low-volume", total };
  const share = fb / total;
  return { state: share > TH.share ? "alerting" : "evaluated-ok", share, fb, cb, ax, total };
}

export function evaluateAFM(row, TH = THRESHOLDS.afm) {
  const frRows = num(row.afm_fr_rows);
  const disc = num(row.afm_disc);
  if (frRows === 0) return { state: "dark-awaiting-release", frRows, disc };
  if (frRows < TH.minFrRows || disc < TH.minDiscards)
    return { state: "skipped-low-volume", frRows, disc };
  const share = disc / frRows;
  return { state: share > TH.share ? "alerting" : "evaluated-ok", share, disc, frRows };
}

export function evaluateTranscription(row, TH = THRESHOLDS.transcription) {
  const fails = num(row.trans_fails);
  const dictations = num(row.dictations_7d);
  if (dictations < TH.minDictations) return { state: "skipped-low-volume", dictations };
  const denom = dictations + fails;
  const share = denom > 0 ? fails / denom : 0;
  return { state: share > TH.share ? "alerting" : "evaluated-ok", share, fails, denom };
}

export function evaluateVolume(days, expectedT1, TH = THRESHOLDS.volume) {
  // Look T-1 up BY DATE: a zero-event day produces no row, so an absent T-1
  // means zero dictations that day (the blackout case), not "use the newest row".
  const t1Row = days.find((d) => String(d.day) === String(expectedT1));
  const t1d = t1Row ? num(t1Row.dictations) : 0;
  // Trailing = the 7 days before T-1 (fixed divisor 7; absent days count as 0).
  const trailing = days.filter((d) => String(d.day) !== String(expectedT1));
  const avg = trailing.reduce((a, d) => a + num(d.dictations), 0) / 7;
  const zeroAlert = t1d === 0 && avg >= TH.activeBaselineAvg;
  // Co-firing blackout (schema drift): asr.completed co-fires UNCONDITIONALLY on
  // every successful dictation (TelemetryService.swift:73-112 -> :501-529), so
  // asr==0 with dictations>0 is genuine drift. We deliberately do NOT flag
  // pastes==0: paste.completed is conditional (only emits when auto-paste runs;
  // copy-only users never emit it, KernelFinalizationWiring.swift:279-284). A zero
  // is ambiguous (copy-only vs broken; an AX-denied auto-paste still emits with a
  // clipboard_only_ax_denied tier), so it is not an actionable alert (#1130).
  const asrDrift = t1Row != null && t1d > 0 && num(t1Row.asr) === 0;
  const driftAlert = asrDrift;
  const ratio = avg > 0 ? t1d / avg : null;
  return {
    state: zeroAlert || driftAlert ? "alerting" : "evaluated-ok",
    t1: t1Row || null, t1d, avg, ratio, zeroAlert, driftAlert, asrDrift,
  };
}

// Reconstructs `count` TRUE calendar days ending at `expectedT1`, filling any
// day with zero events (which emits no row at all — same gap evaluateVolume's
// own t1ref lookup already works around) with an empty stub rather than
// silently skipping it.
function completeDayWindow(rows, expectedT1, count) {
  const byDay = new Map(rows.map((row) => [String(row.day), row]));
  const end = new Date(`${expectedT1}T00:00:00Z`);
  return Array.from({ length: count }, (_, index) => {
    const day = new Date(end);
    day.setUTCDate(day.getUTCDate() - index);
    const key = day.toISOString().slice(0, 10);
    return byDay.get(key) || { day: key };
  });
}

export function evaluateOnboardingAbandon(rows, expectedT1, TH = THRESHOLDS.onboardingAbandon) {
  // rows: per-day {day, started, abandoned, abandonedRaw, abandonedMissingScreen}, any order — mirrors evaluateLatency's `days` shape.
  const totalStarted = rows.reduce((sum, row) => sum + num(row.started), 0);
  const totalAbandoned = rows.reduce((sum, row) => sum + num(row.abandoned), 0);
  const totalAbandonedRaw = rows.reduce((sum, row) => sum + num(row.abandonedRaw), 0);
  const totalAbandonedMissingScreen = rows.reduce(
    (sum, row) => sum + num(row.abandonedMissingScreen), 0);

  // Screen-attribution drift, checked FIRST: alert directly on missing/empty
  // `properties.screen` volume, not on `abandonedRaw - abandoned` (Codex r4
  // review finding — that difference is also nonzero when abandons
  // legitimately concentrate on the real "welcome" screen, which is healthy,
  // correctly-tagged data, not drift). A drifted denominator makes every
  // rate below meaningless, so this check runs before the fast path and the
  // low-volume guard.
  if (totalAbandonedMissingScreen >= TH.minStarted) {
    return {
      state: "alerting", attributionDrift: true, fastCrossing: false,
      totalStarted, totalAbandoned, totalAbandonedRaw, totalAbandonedMissingScreen,
    };
  }

  // Fast path checked FIRST and independently — see canonical contract O1.
  const fastRows = completeDayWindow(rows, expectedT1, TH.fastDays);
  const fastCrossing = fastRows.every((row) => {
    const started = num(row.started);
    return started >= TH.fastMinStarted && num(row.abandoned) / started > TH.share;
  });
  if (fastCrossing) {
    // Report the fast-window's OWN rate, not the rolling total — the alert
    // text must name the numbers that actually triggered it (Codex review
    // finding: a healthy rolling share can otherwise read alongside a fast
    // crossing and contradict the stated threshold).
    const fastStarted = fastRows.reduce((sum, row) => sum + num(row.started), 0);
    const fastAbandoned = fastRows.reduce((sum, row) => sum + num(row.abandoned), 0);
    return { state: "alerting", rollingShare: totalStarted > 0 ? totalAbandoned / totalStarted : 0,
      fastCrossing: true, fastStarted, fastAbandoned,
      fastShare: fastStarted > 0 ? fastAbandoned / fastStarted : 0,
      totalStarted, totalAbandoned };
  }

  if (totalStarted < TH.minStarted) {
    return { state: "skipped-low-volume", fastCrossing: false, totalStarted, totalAbandoned };
  }
  const rollingShare = totalAbandoned / totalStarted;
  return { state: rollingShare > TH.share ? "alerting" : "evaluated-ok",
    rollingShare, fastCrossing: false, totalStarted, totalAbandoned };
}

export function evaluateBackendTranscription(perBackendDays, expectedT1, TH = THRESHOLDS.backendTranscription) {
  // perBackendDays: { [backend]: per-day {day, fails, dictations} rows } —
  // backend enumeration: see canonical contract B2.
  return Object.entries(perBackendDays).map(([backend, rows]) => {
    const dictations = rows.reduce((sum, row) => sum + num(row.dictations), 0);
    const fails = rows.reduce((sum, row) => sum + num(row.fails), 0);
    const attempts = dictations + fails;

    // Backend-attribution drift, checked FIRST (Codex review finding): "unknown"
    // is a synthetic bucket `groupByBackend` assigns when BOTH asr_backend and
    // backend are absent — never a real backend name. Meaningful volume there
    // means the attribution tag itself stopped emitting; the per-backend split
    // this metric promises has silently degraded to an aggregate, which must
    // alert rather than read as just another (possibly "evaluated-ok") backend.
    if (backend === "unknown" && attempts >= TH.minAttempts) {
      return {
        backend, state: "alerting", attributionDrift: true, fastCrossing: false,
        fails, dictations, attempts,
      };
    }

    const fastRows = completeDayWindow(rows, expectedT1, TH.fastDays);
    const fastCrossing = fastRows.every((row) => {
      const dayDictations = num(row.dictations);
      const dayFails = num(row.fails);
      const dayAttempts = dayDictations + dayFails;
      return dayAttempts >= TH.fastMinAttempts && dayFails / dayAttempts > TH.share;
    });
    const rollingShare = attempts > 0 ? fails / attempts : 0;
    if (fastCrossing) {
      // Same fix as evaluateOnboardingAbandon: report the fast-window's own
      // rate, not the rolling 14-day rate, when the fast path is what fired.
      const fastDictations = fastRows.reduce((sum, row) => sum + num(row.dictations), 0);
      const fastFails = fastRows.reduce((sum, row) => sum + num(row.fails), 0);
      const fastAttempts = fastDictations + fastFails;
      return { backend, state: "alerting", rollingShare, fastCrossing: true,
        fastDictations, fastFails, fastAttempts,
        fastShare: fastAttempts > 0 ? fastFails / fastAttempts : 0,
        fails, dictations, attempts };
    }

    if (attempts < TH.minAttempts) {
      return { backend, state: "skipped-low-volume", fastCrossing: false, fails, dictations, attempts };
    }
    return { backend, state: rollingShare > TH.share ? "alerting" : "evaluated-ok",
      rollingShare, fastCrossing: false, fails, dictations, attempts };
  }).sort((a, b) => a.backend.localeCompare(b.backend));
}

export function evaluateOnboardingBlackout(rows, expectedT1, TH = THRESHOLDS.onboardingBlackout) {
  const recent = completeDayWindow(rows, expectedT1, TH.recentDays);
  const baselineEnd = new Date(`${expectedT1}T00:00:00Z`);
  baselineEnd.setUTCDate(baselineEnd.getUTCDate() - TH.recentDays);
  const baseline = completeDayWindow(rows, baselineEnd.toISOString().slice(0, 10), TH.baselineDays);

  const recentStarted = recent.reduce((sum, row) => sum + num(row.started), 0);
  // Raw (unfiltered) abandon count (Codex r6 review finding): the
  // welcome-screen-excluded `abandoned` field exists for the ABANDON-SHARE
  // metric's denominator, not for "did any terminal event fire at all." Using
  // it here means screen-attribution drift (abandoned reads 0 while
  // abandonedRaw keeps firing) would falsely present as terminal drift too.
  const recentTerminals = recent.reduce((sum, row) => sum + num(row.completed) + num(row.abandonedRaw), 0);
  const baselineAvg = baseline.reduce((sum, row) => sum + num(row.started), 0) / TH.baselineDays;

  // (a) Entry point itself broke: zero starts against a real trailing baseline.
  const entryPointDown = recentStarted === 0 && baselineAvg >= TH.activeBaselineAvg;
  // (b) Terminal events stopped firing despite starts continuing (schema drift) —
  // NOT "nobody abandoned" (a low/zero abandon count with healthy completions is GOOD).
  const terminalDrift = recentStarted >= TH.terminalMinStarted && recentTerminals === 0;

  return { state: entryPointDown || terminalDrift ? "alerting" : "evaluated-ok",
    entryPointDown, terminalDrift, recentStarted, recentTerminals, baselineAvg };
}

/** Issue #1589: the SOLE owner of turning `fetchHealth()`'s output (real
 * rows + per-query degrade flags) into the per-metric `evaluate*()` results
 * `buildMessage()` consumes. Calls each `evaluate*()` only when its backing
 * query did NOT degrade; on a degraded query, substitutes
 * `{ state: "temporarily-unavailable" }` for every metric that query feeds,
 * per the dependency table in the plan (§2.5 point 4) - `sevenDayDegraded`
 * alone yields THREE unavailable metrics (paste, afm, transcription) plus an
 * uncheckable `backendAttributionBlackout`; `onboardingDegraded` yields two
 * (onboardingAbandon, onboardingBlackout). Both `runHealth()` (production)
 * and `live-query-smoke.mjs` call this ONE function, so they cannot drift
 * apart the way they previously did (the smoke script used to omit the
 * `backendAttributionBlackout` computation entirely). */
export function evaluateHealthData(data) {
  const unavailable = () => ({ state: "temporarily-unavailable" });

  const backendTranscription = data.backendTranscriptionDegraded
    ? []
    : evaluateBackendTranscription(data.backendTranscriptionDays, data.t1ref);

  const backendAttributionBlackoutUnavailable =
    data.backendTranscriptionDegraded || data.sevenDayDegraded;

  return {
    latency: data.latencyDegraded ? unavailable() : evaluateLatency(data.latencyDays),
    paste: data.sevenDayDegraded ? unavailable() : evaluatePaste(data.seven),
    afm: data.sevenDayDegraded ? unavailable() : evaluateAFM(data.seven),
    transcription: data.sevenDayDegraded ? unavailable() : evaluateTranscription(data.seven),
    volume: evaluateVolume(data.volumeDays, data.t1ref),
    onboardingAbandon: data.onboardingDegraded
      ? unavailable()
      : evaluateOnboardingAbandon(data.onboardingDays, data.t1ref),
    onboardingBlackout: data.onboardingDegraded
      ? unavailable()
      : evaluateOnboardingBlackout(data.onboardingDays, data.t1ref),
    backendTranscription,
    backendTranscriptionUnavailable: data.backendTranscriptionDegraded,
    backendAttributionBlackout:
      !backendAttributionBlackoutUnavailable &&
      backendTranscription.length === 0 &&
      num(data.seven.dictations_7d) >= THRESHOLDS.transcription.minDictations,
    backendAttributionBlackoutUnavailable,
    versions: data.versions,
    onboardingVersions: data.onboardingVersions,
    backendVersions: data.backendVersions,
    versionsDegraded: data.versionsDegraded,
    onboardingVersionsDegraded: data.onboardingVersionsDegraded,
    backendVersionsDegraded: data.backendVersionsDegraded,
  };
}

function num(v) {
  const n = typeof v === "string" ? parseFloat(v) : v;
  return Number.isFinite(n) ? n : 0;
}

function pct(x) {
  return (x * 100).toFixed(1) + "%";
}

function topVersionsFor(versions, key, { backend = null, limit = 3 } = {}) {
  return versions
    .filter((row) => backend == null || row.backend === backend)
    .filter((row) => num(row[key]) > 0)
    .sort((a, b) => num(b[key]) - num(a[key]))
    .slice(0, limit)
    .map((row) => `${row.ver || "unknown"} (${num(row[key])})`)
    .join(", ");
}

// Issue #1589: naive title-casing turns `whisperKit` into "Whisperkit."
// `ASRBackendType`'s Swift rawValue is `whisperKit` camelCase
// (Sources/EnviousWisprCore/ASRResult.swift) - the lowercase alias is
// defensive in case an older/renamed tag ever reaches this worker.
const BACKEND_LABELS = { parakeet: "Parakeet", whisperKit: "WhisperKit", whisperkit: "WhisperKit" };
function backendLabel(backend) {
  return BACKEND_LABELS[backend] || (backend ? backend.charAt(0).toUpperCase() + backend.slice(1) : "unknown");
}

// Issue #1589: the `{ topVersions }` clause. Enrichment-only degrades must
// stay visible rather than silently vanish, so a degraded backing version
// query renders a plain "couldn't break this down" sentence instead of
// omitting the clause. `fastCrossing` alerts never get version attribution
// at all (a 2-day window can't be honestly attributed to a 21/14-day version
// query), so callers pass `degraded = false` and `entries = []` for those.
function topVersionsClause(versions, key, degraded, opts) {
  if (degraded) return " We couldn't break this down by app version today.";
  const tv = topVersionsFor(versions, key, opts);
  return tv ? ` App versions with the most affected events: ${tv}.` : "";
}

// ----- Message ------------------------------------------------------------

// Issue #1589: plain-English rewrite. `r` is evaluateHealthData()'s return
// object - one argument, carrying every evaluate*() result plus the version
// row arrays and every degrade flag `buildMessage` needs.
export function buildMessage(r) {
  const alerts = [];
  const evaluated = [];
  const skipped = [];
  const dark = [];
  const unavailable = [];

  const note = (label, ev) => {
    if (ev.state === "alerting") return; // handled as an alert
    if (ev.state === "evaluated-ok") evaluated.push(label);
    else if (ev.state === "dark-awaiting-release") dark.push(label);
    else if (ev.state === "temporarily-unavailable") unavailable.push(label);
    else skipped.push(label);
  };

  // Response speed (latency)
  if (r.latency.state === "alerting") {
    const d = r.latency.latest;
    alerts.push(
      `Dictation is taking longer than usual to finish. On the latest day with enough data, the typical time was ${d.p50}s and the slowest 5% took at least ${d.p95}s. This crossed the alert line on each of the latest ${r.latency.last2.length} days with enough data. We alert above ${THRESHOLDS.latency.p50}s typical or ${THRESHOLDS.latency.p95}s for the slowest 5%; normal typical time is about 1.5s.`
    );
  }
  note("response speed", r.latency);

  // Auto-paste reliability
  if (r.paste.state === "alerting") {
    const tv = topVersionsClause(r.versions, "paste_fb", r.versionsDegraded);
    alerts.push(
      `Auto-paste is failing more than usual: ${pct(r.paste.share)} of pastes over the last week fell back to copying to the clipboard instead of pasting directly (${r.paste.fb} of ${r.paste.total} pastes). ${r.paste.ax} were caused by a missing permission; ${r.paste.cb} failed another way. Normal is about 1.2%; we alert above ${pct(THRESHOLDS.paste.share)}.${tv}`
    );
  }
  note("auto-paste reliability", r.paste);

  // Apple on-device polishing quality (AFM)
  if (r.afm.state === "alerting") {
    const tv = topVersionsClause(r.versions, "afm_disc", r.versionsDegraded);
    alerts.push(
      `Among the times Apple's on-device polishing used the raw transcript, it did so because it rejected its own rewritten text more often than usual: ${pct(r.afm.share)} over the last week (${r.afm.disc} of ${r.afm.frRows} raw-text fallbacks). Normal is about 10%; we alert above ${pct(THRESHOLDS.afm.share)}.${tv}`
    );
  }
  note("Apple on-device polishing quality", r.afm);

  // Speech-to-text reliability (aggregate)
  if (r.transcription.state === "alerting") {
    const tv = topVersionsClause(r.versions, "trans_fail", r.versionsDegraded);
    alerts.push(
      `Speech-to-text failed to produce any text more than usual: ${pct(r.transcription.share)} of attempts over the last week (${r.transcription.fails} of ${r.transcription.denom}; this includes attempts where the person genuinely said nothing). Normal is about 0.9%; we alert above ${pct(THRESHOLDS.transcription.share)}.${tv}`
    );
  }
  note("speech-to-text reliability", r.transcription);

  // Onboarding completion (Phase 10, #1179)
  if (r.onboardingAbandon) {
    const ev = r.onboardingAbandon;
    if (ev.state === "alerting" && ev.attributionDrift) {
      // Screen-attribution drift: distinct wording, no version attribution
      // (this is a schema-drift signal, not a rate). Names the missing-screen
      // count directly (Codex r4 review finding), not the raw total, so the
      // alert cannot fire on a legitimate all-welcome concentration.
      alerts.push(
        `We lost the ability to tell where setup was abandoned: ${ev.totalAbandonedMissingScreen} of ${ev.totalAbandonedRaw} abandon events over the last three weeks are missing the tag for which screen they were on. Onboarding tracking may be broken.`
      );
    } else if (ev.state === "alerting" && ev.fastCrossing) {
      // Report the fast window's own rate, never the healthy rolling total
      // (Codex review finding), and never attribute a 2-day crossing to the
      // metric's own 21-day version query (window mismatch).
      alerts.push(
        `In just the last 2 days, ${pct(ev.fastShare)} of setup attempts ended before setup was finished (${ev.fastAbandoned} of ${ev.fastStarted}). This is a sudden change worth a look even though the 3-week average still looks fine.`
      );
    } else if (ev.state === "alerting") {
      const tv = topVersionsClause(r.onboardingVersions, "onboarding_abandon", r.onboardingVersionsDegraded);
      alerts.push(
        `Of the setup attempts started over the last three weeks, ${pct(ev.rollingShare)} ended before setup was finished (${ev.totalAbandoned} of ${ev.totalStarted}). Normal is about 37%; we alert above ${pct(THRESHOLDS.onboardingAbandon.share)}.${tv}`
      );
    }
    note("onboarding completion", ev);
  }

  // Speech-to-text reliability by engine (Phase 10, #1179)
  if (r.backendTranscriptionUnavailable) {
    note("speech-to-text reliability by engine", { state: "temporarily-unavailable" });
  } else if (r.backendTranscription) {
    for (const row of r.backendTranscription) {
      const label = backendLabel(row.backend);
      if (row.state === "alerting" && row.attributionDrift) {
        // Backend-attribution drift (Codex review finding): distinct wording,
        // no version attribution.
        alerts.push(
          `We lost track of which speech engine, Parakeet or WhisperKit, was used for ${row.attempts} dictation or failure events over the last two weeks. That tracking tag may have stopped working.`
        );
      } else if (row.state === "alerting" && row.fastCrossing) {
        alerts.push(
          `In just the last 2 days, ${label} speech-to-text failed on ${pct(row.fastShare)} of attempts (${row.fastFails} of ${row.fastAttempts}). This crossed the alert line on both days, a sudden change worth a look even if the 2-week average still looks fine.`
        );
      } else if (row.state === "alerting") {
        const tv = topVersionsClause(r.backendVersions, "backend_trans_fail", r.backendVersionsDegraded, { backend: row.backend });
        alerts.push(
          `${label} speech-to-text is failing more than usual: ${pct(row.rollingShare)} of attempts over the last two weeks (${row.fails} of ${row.attempts}). We alert above ${pct(THRESHOLDS.backendTranscription.share)}.${tv}`
        );
      }
      note(`${label} speech-to-text`, row);
    }
    if (r.backendTranscription.length === 0 && !r.backendAttributionBlackout && !r.backendAttributionBlackoutUnavailable) {
      // Codex r5 review finding: an empty result during a genuinely
      // low-volume period (not blackout, since aggregate volume is also
      // low) never reaches the loop above, so the metric silently vanished
      // from evaluated/skipped/alerts instead of reading as skipped.
      note("speech-to-text reliability by engine", { state: "skipped-low-volume" });
    }
  }

  // Speech-engine tracking (backend-attribution blackout)
  if (r.backendAttributionBlackoutUnavailable) {
    note("speech-engine tracking", { state: "temporarily-unavailable" });
  } else if (r.backendAttributionBlackout) {
    // Total backend-attribution blackout (Codex review finding): the query
    // matched zero (day, backend) groups despite healthy overall dictation
    // volume - the per-backend split vanished entirely rather than reading
    // as merely quiet.
    alerts.push(
      `We can no longer tell which speech engine people are using at all, even though overall dictation volume looks normal. That tracking may have broken entirely.`
    );
  }

  // Onboarding tracking (Phase 10, #1179) - evaluated-ok/alerting only, no
  // low-volume/dark states normally, but CAN now be temporarily-unavailable.
  if (r.onboardingBlackout) {
    if (r.onboardingBlackout.state === "alerting") {
      if (r.onboardingBlackout.entryPointDown) {
        alerts.push(
          `There were no setup starts in the last 2 days, even though a typical day sees about ${r.onboardingBlackout.baselineAvg.toFixed(1)}. Either the setup screen is broken, or our own tracking is.`
        );
      }
      if (r.onboardingBlackout.terminalDrift) {
        alerts.push(
          `There were ${r.onboardingBlackout.recentStarted} setup starts in the last 2 days, but none registered as either finishing or giving up. That tracking may be broken.`
        );
      }
    }
    note("onboarding tracking", r.onboardingBlackout);
  }

  // Volume / integrity
  if (r.volume.state === "alerting") {
    if (r.volume.zeroAlert) {
      alerts.push(
        `No dictations were completed yesterday, even though a typical day sees about ${r.volume.avg.toFixed(0)}. This usually means either the app is crashing for everyone, or our own tracking is broken.`
      );
    }
    if (r.volume.driftAlert) {
      alerts.push(
        `Something looks broken in our own tracking: ${r.volume.t1d} dictations finished successfully yesterday, but a signal that should fire every time did not fire once. Today's numbers may not be trustworthy until this is fixed.`
      );
    }
  }

  // Heartbeat block (always)
  const t1d = r.volume.t1d != null ? r.volume.t1d : "?";
  const ratioClause =
    r.volume.ratio == null
      ? ""
      : r.volume.ratio < 0.7
        ? ", well below the usual amount"
        : r.volume.ratio > 1.3
          ? ", well above the usual amount"
          : ", about the usual amount";
  const responseSpeedLine =
    r.latency.latest && r.latency.driftMedian != null
      ? `\nResponse speed on the latest day with enough data: ${r.latency.latest.p50}s, compared with a 14-day median of ${r.latency.driftMedian.toFixed(2)}s.`
      : "";
  const coverageLine =
    `Checked and normal: ${evaluated.join(", ") || "none"}.` +
    (dark.length ? ` Waiting for enough eligible data: ${dark.join(", ")}.` : "") +
    (skipped.length ? ` Not enough activity to judge: ${skipped.join(", ")}.` : "") +
    (unavailable.length ? ` Temporarily unavailable: ${unavailable.join(", ")}.` : "");
  // Codex diff review finding: a degraded-but-not-alerting run must NOT claim
  // "everything looks normal" - that is exactly the partial-failure scenario
  // this reliability fix introduces, and it would falsely reassure a founder
  // skimming only the headline while checks silently couldn't run.
  const headline = alerts.length
    ? `found ${alerts.length} thing${alerts.length === 1 ? "" : "s"} worth a look`
    : unavailable.length
      ? `no problems found, but ${unavailable.length} check${unavailable.length === 1 ? "" : "s"} couldn't run today`
      : "everything looks normal";
  // `heartbeatHead` deliberately excludes the dashboard line: it is appended
  // exactly once, as the final line, by each of the three return paths below
  // - never duplicated, and never at risk of being truncated away (Codex
  // review finding: a blind character slice can cut mid-alert and silently
  // drop the dashboard link, hiding the very alerts most worth seeing - drop
  // whole alerts from the end instead, always keeping the dashboard link).
  const heartbeatHead =
    `EnviousWispr health check for yesterday: ${headline}.\n` +
    `${t1d} dictations were completed yesterday${ratioClause}.\n` +
    `${coverageLine}${responseSpeedLine}\n` +
    `Crashes and app errors are tracked separately and alert on their own. This check is only about product usage patterns.`;

  if (!alerts.length) return `${heartbeatHead}\nFull data: ${DASHBOARD}`;

  for (let keep = alerts.length; keep > 0; keep--) {
    const omitted = alerts.length - keep;
    const trailer = omitted > 0 ? `\n(${omitted} more alert(s) omitted; see full data below.)` : "";
    const trial =
      heartbeatHead +
      "\n\n" +
      alerts.slice(0, keep).map((a) => "* " + a).join("\n") +
      trailer +
      `\nFull data: ${DASHBOARD}`;
    if (trial.length <= 1990) return trial;
  }
  return `${heartbeatHead}\n\n${alerts.length} alert(s) triggered.\nFull data: ${DASHBOARD}`.slice(0, 1990);
}

// ----- Run ----------------------------------------------------------------

// `deps` is a test-only injection seam (production passes nothing, both
// defaults apply): `deps.evaluateHealthData` lets a test spy on it; `deps.
// hogqlOpts` forwards into fetchHealth so a test can force an exhausted
// retry deterministically instead of waiting through real backoff delays.
export async function runHealth(env, deps = {}) {
  const evaluateHealthDataFn = deps.evaluateHealthData || evaluateHealthData;
  const hogqlOpts = deps.hogqlOpts || {};

  let data;
  try {
    data = await fetchHealth(env, hogqlOpts);
  } catch (err) {
    // Loud failure: post a plain-English notice if Discord is reachable, then
    // rethrow so Cloudflare logs it. A failed run must never read as "all
    // green". No claimed cause in the plain sentence (issue #1589): this path
    // also carries auth failures, malformed SQL, malformed responses, and
    // dev-id-list overflow, none of which are a timeout. Codex diff review
    // finding: `err.message` (e.g. "PostHog query ref HTTP 503") must stay in
    // the Cloudflare log for my own debugging, never in the Discord post -
    // exposing raw HTTP/query-name jargon to the founder is exactly the
    // unreadable-error-text problem this rewrite exists to remove.
    console.log(`product-health check failed to run: ${err.message}`);
    await safePost(env, "EnviousWispr health check didn't run today.");
    throw err;
  }

  const results = evaluateHealthDataFn(data);
  const message = buildMessage(results);

  const ok = await postToDiscord(env.DISCORD_WEBHOOK_URL, message);
  if (!ok) throw new Error("Discord post failed");
  return message;
}

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
    // best-effort failure notice; the throw in runHealth surfaces it in logs
  }
}
