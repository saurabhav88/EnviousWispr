/**
 * PostHog transport + production-filter infrastructure, shared by every worker
 * that queries PostHog (issues #1838, #1589).
 *
 * HISTORY, because it explains why this file moved rather than being copied a
 * fifth time. It began inside `daily-report/src/index.js`, duplicated
 * function-for-function with the since-retired product-health worker and
 * hand-ported between the two (#1720 -> #1775). It then lived at
 * `daily-report/src/lib/posthog.js` with a header arguing AGAINST promoting it
 * here, on the stated ground that "after that retirement the daily report is
 * its only consumer, and a shared module with one consumer is indirection, not
 * reuse." That precondition no longer holds: `workers/weekly-digest` is now a
 * real second consumer (#1589), and the same header recorded that hand-porting
 * "demonstrably did not converge." Two consumers, one owner.
 *
 * CONSUMERS: workers/daily-report, workers/weekly-digest.
 *
 * DEPLOY RULE: Cloudflare bundles each worker separately, so editing this file
 * changes NOTHING in production until EVERY consumer above is redeployed
 * (`npx wrangler deploy` from each worker directory). A merged PR does not
 * deploy; a `git revert` does not roll back. See workers/shared/README.md.
 *
 * Infrastructure ONLY - transport, retry, concurrency, dev-ID resolution, the
 * production predicate, SQL literal escaping, and row conversion. Metric SQL,
 * report windows, section failure policy and every product judgement stay in
 * the owning worker.
 *
 * Privacy: this module logs query NAMES and HTTP statuses only. Never a
 * response body, never a distinct_id, never the API key.
 */

const POSTHOG_HOST = "https://us.posthog.com";

// Per-worker distinct_id list bound. Genuinely a defense-in-depth ceiling,
// never the primary correctness mechanism - see resolveDevIds's completeness
// check below. 5000 is far above any realistic single-day population.
const PER_USER_LIST_LIMIT = 5000;

const ENV_ONLY = "properties.environment = 'production'";

// Retried (3 attempts total) only on this documented status class, and only
// ever before any Discord post happens - unlike the deliberately-rejected
// outer GitHub-Actions-level retry (see the comment in daily-report-ping.yml),
// this cannot produce a duplicate or confusing failure notice.
const RETRYABLE_POSTHOG_STATUSES = new Set([429, 502, 503, 504]);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Randomized backoff windows for retry attempts 2 and 3, informed by (not a
// guarantee derived from) PostHog's documented up-to-30s queue-wait: once a
// request has already queued, waited, and failed, its original window is
// already over, so this is conservative contention backoff, not a claim that a
// fixed wait "clears" any specific prior window (#1720).
const RETRY_DELAY_RANGES_MS = [
  [12_000, 18_000],
  [30_000, 45_000],
];

function retryDelayMs(range, randomFn) {
  const [min, max] = range;
  return Math.floor(min + randomFn() * (max - min + 1));
}

/** Carries the query name and HTTP status alongside the message, so a caller
 * can distinguish an exhausted transient failure (which a degradable section is
 * allowed to absorb) from an auth failure, a malformed query, or a bad response
 * shape (which must stay loud). Message text is unchanged from the plain Error
 * it replaced - existing assertions and the production failure notice both
 * depend on it (#1655). */
export class PostHogQueryError extends Error {
  constructor(queryName, status) {
    super(`PostHog query ${queryName} HTTP ${status}`);
    this.name = "PostHogQueryError";
    this.queryName = queryName;
    this.status = status;
  }
}

/** Escapes a distinct_id for a HogQL string literal. distinct_ids are opaque
 * PostHog-generated ids, never user-authored text, so single-quote doubling is
 * sufficient. */
export function sqlIdList(ids) {
  return ids.map((id) => `'${String(id).replace(/'/g, "''")}'`).join(", ");
}

/** Converts a resolved dev-tainted distinct_id list (from resolveDevIds) into
 * the reusable production-filter predicate: environment = production, AND (only
 * if any dev ids exist) NOT IN that literal list.
 *
 * Resolving the list ONCE per report run and threading the result through every
 * query replaces the old per-query inline dev-exclusion subquery, which
 * independently re-scanned the same whole-history data in every primary query -
 * the duplicated-subquery shape that measurably timed out production PostHog
 * for polish tier-a (#1655) and onboard_activate (#1716). An empty list is a
 * legitimate state (genuinely zero dev-tainted ids found across event history)
 * and must not produce invalid `NOT IN ()` SQL, hence the empty-list branch
 * (#1720). */
export function productionClauseFor(devIds) {
  if (devIds.length === 0) return ENV_ONLY;
  return `${ENV_ONLY}
    AND distinct_id NOT IN (${sqlIdList(devIds)})`;
}

/** Resolves the whole-history dev-tainted distinct_id list ONCE per report run
 * (analytics-operations.md RULE: founder-machine-tell-in-distinct-id: a dev
 * build anywhere in an id's history marks the whole id as dogfood, so this is
 * an unbounded scan, not day-windowed).
 *
 * Queried at PER_USER_LIST_LIMIT+1 to detect overflow: if the true count
 * exceeds the ceiling this throws rather than silently building a truncated
 * exclusion list that would under-exclude dev accounts from production totals -
 * fail loud, not warn-and-continue (#1720). This is itself a fail-loud query:
 * an unresolved dev-id list can never safely be treated as "no dev accounts,"
 * so callers must never wrap it in querySection's fail-soft catch. */
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

/** Identifies the calling worker in PostHog's query log and in Cloudflare logs.
 *
 * REQUIRED, never defaulted. A default of "daily_report" would file another
 * worker's queries under the daily report's name - an answer that looks right
 * everywhere it is read, which is worse than a crash. Both consumers set it
 * once at the top of their run and forward the same options bag verbatim to
 * every call site. */
function requireWorkerLabel(workerLabel) {
  if (typeof workerLabel !== "string" || workerLabel.length === 0) {
    throw new TypeError("hogql requires a non-empty workerLabel");
  }
  return workerLabel;
}

export async function hogql(
  env,
  sql,
  queryName,
  { fetchFn = fetch, sleepFn = sleep, randomFn = Math.random, workerLabel } = {}
) {
  const label = requireWorkerLabel(workerLabel);
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
        name: `${label}_${queryName}`,
      }),
    });

    if (res.ok) {
      const json = await res.json();
      if (!json.results) throw new Error(`PostHog query ${queryName} returned no results array`);
      return json;
    }

    const status = res.status;
    if (res.body) {
      try {
        await res.body.cancel();
      } catch (_) {
        // Best effort: the status remains the authoritative failure, and a
        // failed cancel must not mask it. Draining/cancelling the failed body
        // here matters specifically because a retry immediately opens a NEW
        // outbound request - an uncancelled body can hold its Cloudflare
        // subrequest connection open, and enough of those piling up across
        // retries could exhaust Cloudflare's own outbound-connection ceiling
        // and recreate the stall this exists to fix (#1588 review round 2).
      }
    }

    if (attempt === maxAttempts || !RETRYABLE_POSTHOG_STATUSES.has(status)) {
      throw new PostHogQueryError(queryName, status);
    }
    await sleepFn(retryDelayMs(RETRY_DELAY_RANGES_MS[attempt - 1], randomFn));
  }
}

/** Runs `tasks` (zero-arg async thunks) with at most `limit` in flight,
 * preserving input order in the returned results. Exists because PostHog's
 * project-level query-concurrency ceiling is 3 (#1588) - firing more than that
 * at once gets the excess queued for up to 30s before PostHog cancels it.
 *
 * NOT fail-fast, deliberately changed by #1838. The previous implementation ran
 * fixed waves of `limit` under `Promise.all`, so a single rejection prevented
 * every LATER wave from starting. That contract is incompatible with the merged
 * report's section isolation: one failing adoption query would strand the
 * version scorecard's queued work and blank a section that could have rendered.
 *
 * Now a rejected task releases its slot, queued work keeps starting, and the
 * failure is reported only once everything has settled. Fail-loud callers are
 * unaffected: the first rejection IN INPUT ORDER is rethrown, so `totals`
 * failing still fails the whole report exactly as before - it simply no longer
 * cancels sibling work that had not started yet. */
export async function runLimited(tasks, limit) {
  if (!Number.isInteger(limit) || limit < 1) {
    throw new TypeError("limit must be a positive integer");
  }

  const results = new Array(tasks.length);
  let firstFailureIndex = -1;
  let firstFailure;
  let nextIndex = 0;

  async function worker() {
    for (;;) {
      const index = nextIndex;
      nextIndex += 1;
      if (index >= tasks.length) return;
      try {
        results[index] = await tasks[index]();
      } catch (err) {
        // Track by input index, not arrival order: which task failed must not
        // depend on scheduling. A separate index sentinel (rather than probing
        // a sparse `failures` array) keeps a task that rejects with `undefined`
        // indistinguishable from any other rejection.
        if (firstFailureIndex === -1 || index < firstFailureIndex) {
          firstFailureIndex = index;
          firstFailure = err;
        }
      }
    }
  }

  const workerCount = Math.min(limit, tasks.length);
  const workers = [];
  for (let w = 0; w < workerCount; w += 1) workers.push(worker());
  await Promise.all(workers);

  if (firstFailureIndex !== -1) throw firstFailure;
  return results;
}

/** Runs one hogql() call and reports whether it degraded instead of throwing,
 * for a non-essential query. Only an EXHAUSTED retryable status
 * (RETRYABLE_POSTHOG_STATUSES, after hogql's own retries) degrades; anything
 * else - auth, bad SQL, a malformed response, a programming error - still
 * throws, matching tier_a's existing degrade philosophy (#1655, extended
 * report-wide by #1720). `totals` deliberately does NOT go through this helper;
 * it stays fail-loud, see its call site in fetchReportData. */
export async function querySection(env, sql, queryName, hogqlOpts) {
  const label = requireWorkerLabel(hogqlOpts?.workerLabel);
  try {
    return { response: await hogql(env, sql, queryName, hogqlOpts), degraded: false };
  } catch (err) {
    const isExpectedTransientFailure =
      err instanceof PostHogQueryError &&
      err.queryName === queryName &&
      RETRYABLE_POSTHOG_STATUSES.has(err.status);
    if (!isExpectedTransientFailure) throw err;
    console.log(`${label} ${queryName} degraded after retries: HTTP ${err.status}`);
    return { response: null, degraded: true };
  }
}

export function rowsToObjects(res) {
  const cols = res.columns || [];
  return (res.results || []).map((row) => {
    const o = {};
    cols.forEach((c, i) => (o[c] = row[i]));
    return o;
  });
}

/** HogQL timestamp literal. Kept beside `sqlIdList` because it is generic SQL
 * construction with no adoption-specific population or product judgement in it —
 * the version scorecard needs its own window predicate too, so a single owner
 * here keeps both consumers off an index.js <-> adoption.js import cycle
 * (#1838 chunk 2). */
export function sqlTimestamp(date) {
  return date.toISOString().slice(0, 19).replace("T", " ");
}

export function windowClause(startUTC, endUTC) {
  return `timestamp >= '${sqlTimestamp(startUTC)}' AND timestamp < '${sqlTimestamp(endUTC)}'`;
}

export { ENV_ONLY, PER_USER_LIST_LIMIT, RETRYABLE_POSTHOG_STATUSES };
