/**
 * Adoption domain for the daily report (issue #1838 chunk 2).
 *
 * Yesterday's install / onboarding / activation / engine / polish-provider /
 * volume / geography picture, extracted unchanged from `./index.js`. Queries,
 * populations, result shapes, degradation behaviour and rendered content are
 * byte-for-byte what they were - this chunk moves ownership, nothing else.
 *
 * Owns the seven adoption queries and `resolveBuckets`. Deliberately does NOT
 * own presentation: `buildMessage` and its label/percentage/date helpers stay
 * with the presentation owner until a later chunk moves that whole concern once,
 * rather than relocating it twice.
 */

import {
  ENV_ONLY,
  PER_USER_LIST_LIMIT,
  PostHogQueryError,
  RETRYABLE_POSTHOG_STATUSES,
  hogql,
  productionClauseFor,
  querySection,
  resolveDevIds,
  rowsToObjects,
  runLimited,
  sqlIdList,
  sqlTimestamp,
} from "./lib/posthog.js";

// Shipped app defaults (SettingsDefaultValues.swift) - the tier-of-last-resort
// when a user has neither a settings record nor any dictation carrying a
// signal. See plan §3.3 row 4.
const DEFAULT_ENGINE = "parakeet";
const DEFAULT_PROVIDER = "appleIntelligence";

/** The day's active-user population (successful dictators), used once as an
 * IN-membership test inside onboardActivateSql's `activated` column - see
 * that query below. Deliberately ${ENV_ONLY}, not the full production
 * predicate: every row this set is tested against already came from
 * onboardActivateSql's own outer `WHERE ... AND ${prod}` on
 * onboarding.completed, so a dev-tainted id can never appear on the outer
 * side to begin with - whether this inner set is ALSO dev-filtered cannot
 * change which outer ids match it. The full predicate here would evaluate
 * the dev-exclusion a second time for no change in result, which is exactly
 * the doubled-subquery shape that measurably timed out production PostHog
 * for polish tier-a (#1655) - fixed here the same way, after #1655's fix
 * didn't cover this sibling query and it 504'd for real on 2026-07-20. This
 * argument is local to this one call site; a new caller must re-derive it,
 * not assume it. */
function activeUsersSubquery(win) {
  return `SELECT DISTINCT distinct_id FROM events
    WHERE event = 'dictation.completed' AND properties.result = 'success'
      AND ${ENV_ONLY} AND ${win}`;
}

/** Polish tier-a: latest llm_provider across settings.snapshot and
 * settings.changed, restricted to a literal list of already-known active-user
 * ids (rather than a re-evaluated subquery, which timed out).
 *
 * Deliberately uses ${ENV_ONLY} rather than the full production predicate.
 * Every active id came from engineAndTierBSql, which already applied the
 * full predicate, including the whole-history dev-ID exclusion. Repeating
 * that exclusion twice inside this UNION adds substantial work without
 * changing results. Live A/B verification found identical provider
 * attribution for all active users. This argument is local to tier-a and to
 * activeUsersSubquery's own, separately-derived use of ${ENV_ONLY} below;
 * every other query keeps the full dev-exclusion via
 * `productionClauseFor`. */
function tierASqlFor(activeIds, endTs) {
  const ids = sqlIdList(activeIds);
  return `
    SELECT distinct_id, argMax(value, ts) AS provider
    FROM (
      SELECT distinct_id, properties.llm_provider AS value, timestamp AS ts
      FROM events
      WHERE event = 'settings.snapshot' AND ${ENV_ONLY}
        AND distinct_id IN (${ids})
        AND timestamp < '${endTs}'
      UNION ALL
      SELECT distinct_id, properties.to AS value, timestamp AS ts
      FROM events
      WHERE event = 'settings.changed' AND properties.setting = 'llm_provider' AND ${ENV_ONLY}
        AND distinct_id IN (${ids})
        AND timestamp < '${endTs}'
    )
    GROUP BY distinct_id
    LIMIT ${PER_USER_LIST_LIMIT}`;
}

// `hogqlOpts` forwards the same injection bag `hogql` already accepts, so tests
// can drive the retry path without real backoff delays - the pattern the
// hogql unit tests already use. Production passes nothing.
export async function fetchReportData(env, win, endUTC, hogqlOpts = {}) {
  const endTs = sqlTimestamp(endUTC);
  // Resolved ONCE per report run and threaded through every query below,
  // replacing the old per-query inline dev-exclusion subquery (#1720).
  const devIds = await resolveDevIds(env, hogqlOpts);
  const prod = productionClauseFor(devIds);
  const activeUsers = activeUsersSubquery(win);

  const installsSql = `
    SELECT uniqExact(distinct_id) FROM events
    WHERE event = 'app.launched' AND properties.is_fresh_install = true
      AND ${prod} AND ${win}`;

  const onboardActivateSql = `
    SELECT
      uniqExact(distinct_id) AS onboarded,
      uniqExactIf(distinct_id, distinct_id IN (${activeUsers})) AS activated
    FROM events
    WHERE event = 'onboarding.completed' AND ${prod} AND ${win}`;

  const totalsSql = `
    SELECT count() AS net_dictations, uniqExact(distinct_id) AS total_users
    FROM events
    WHERE event = 'dictation.completed' AND properties.result = 'success' AND ${prod} AND ${win}`;

  // Engine (row 3) + polish tier-b fallback (row 4) share the same event
  // population, so one query resolves both per user.
  const engineAndTierBSql = `
    SELECT distinct_id,
           argMax(properties.asr_backend, timestamp) AS engine,
           anyIf(properties.llm_provider, properties.llm_provider IS NOT NULL) AS tier_b_provider
    FROM events
    WHERE event = 'dictation.completed' AND properties.result = 'success' AND ${prod} AND ${win}
    GROUP BY distinct_id
    LIMIT ${PER_USER_LIST_LIMIT}`;

  const geoSql = `
    SELECT properties.$geoip_country_name AS country, uniqExact(distinct_id) AS n
    FROM events
    WHERE event = 'dictation.completed' AND properties.result = 'success'
      AND properties.$geoip_country_name IS NOT NULL AND properties.$geoip_country_name != ''
      AND ${prod} AND ${win}
    GROUP BY country
    ORDER BY n DESC
    LIMIT 5`;

  const top5Sql = `
    SELECT distinct_id, count() AS n
    FROM events
    WHERE event = 'dictation.completed' AND properties.result = 'success' AND ${prod} AND ${win}
    GROUP BY distinct_id
    ORDER BY n DESC
    LIMIT 5`;

  // These 6 primary queries are independent, but PostHog allows only 3
  // concurrent queries per project (#1588). `runLimited(..., 2)` keeps at
  // most 2 requests in flight, leaving one slot of headroom for the shared
  // project's other traffic (EnviousStaging). A rejected task releases its
  // slot and queued work continues (#1838), so one failure cannot strand
  // later work. Polish tier-a (below) runs sequentially *after* the entire
  // limited batch settles - it does not need reserved concurrency.
  // `totals` is the sole fail-loud query in this batch (it anchors
  // resolveBuckets's completeness check and supplies the report's
  // headline numbers); the other five go through querySection and degrade
  // to "temporarily unavailable" instead of discarding the whole report on
  // an exhausted transient failure (#1720).
  const [installsResult, onboardActivateResult, totals, engineAndTierBResult, geoResult, top5Result] =
    await runLimited(
      [
        () => querySection(env, installsSql, "installs", hogqlOpts),
        () => querySection(env, onboardActivateSql, "onboard_activate", hogqlOpts),
        () => hogql(env, totalsSql, "totals", hogqlOpts),
        () => querySection(env, engineAndTierBSql, "engine_and_tier_b", hogqlOpts),
        () => querySection(env, geoSql, "geo", hogqlOpts),
        () => querySection(env, top5Sql, "top5", hogqlOpts),
      ],
      2
    );

  const engineAndTierB = engineAndTierBResult.degraded ? [] : rowsToObjects(engineAndTierBResult.response);
  const activeIds = engineAndTierB.map((row) => row.distinct_id);
  // tier-a is an ENRICHMENT: resolveBuckets already falls back
  // tierA -> tier_b_provider -> DEFAULT_PROVIDER per user, so an empty tier-a
  // still yields a complete breakdown. A tier-a failure must therefore degrade
  // that one attribution tier rather than discard an otherwise-complete report.
  // On 2026-07-18 all six batched queries succeeded and were discarded because
  // tier-a timed out (#1655). When engineAndTierB itself is degraded,
  // activeIds is empty, so tier-a is naturally skipped below - runReport
  // separately skips resolveBuckets entirely in that case (#1720), since a
  // completeness check has nothing real to verify against.
  //
  // ONLY an exhausted retryable status degrades. Anything else - auth, bad SQL,
  // a malformed response, a programming error - stays loud: a silently
  // "approximate" report that hides a real defect is worse than no report.
  let tierA = { results: [], columns: [] };
  let tierADegraded = false;
  if (activeIds.length) {
    try {
      tierA = await hogql(env, tierASqlFor(activeIds, endTs), "tier_a", hogqlOpts);
    } catch (err) {
      const isExpectedTransientFailure =
        err instanceof PostHogQueryError &&
        err.queryName === "tier_a" &&
        RETRYABLE_POSTHOG_STATUSES.has(err.status);
      if (!isExpectedTransientFailure) throw err;
      tierADegraded = true;
      console.log(`daily-report tier_a degraded after retries: HTTP ${err.status}`);
    }
  }

  return {
    freshInstalls: installsResult.degraded ? null : installsResult.response.results[0][0],
    installsDegraded: installsResult.degraded,
    onboarded: onboardActivateResult.degraded ? null : rowsToObjects(onboardActivateResult.response)[0]?.onboarded ?? 0,
    activated: onboardActivateResult.degraded ? null : rowsToObjects(onboardActivateResult.response)[0]?.activated ?? 0,
    onboardActivateDegraded: onboardActivateResult.degraded,
    netDictations: rowsToObjects(totals)[0]?.net_dictations ?? 0,
    totalUsers: rowsToObjects(totals)[0]?.total_users ?? 0,
    engineAndTierB,
    engineAndTierBDegraded: engineAndTierBResult.degraded,
    tierA: rowsToObjects(tierA),
    tierADegraded,
    geo: geoResult.degraded ? [] : rowsToObjects(geoResult.response),
    geoDegraded: geoResult.degraded,
    top5: top5Result.degraded ? [] : rowsToObjects(top5Result.response),
    top5Degraded: top5Result.degraded,
  };
}

/**
 * Resolves each active user's engine and polish-provider bucket, per the
 * plan §3.3 rules, and verifies completeness against the independently
 * queried `totalUsers` (plan §3.3a) - a mismatch means some per-user rows
 * were silently dropped (the 100-row-truncation bug class) and throws
 * rather than silently under-reporting.
 */
export function resolveBuckets(data) {
  const tierAByUser = new Map(data.tierA.map((r) => [r.distinct_id, r.provider]));
  const engineBuckets = {};
  const polishBuckets = {};
  let engineCount = 0;
  let polishCount = 0;
  const resolutionSource = { settings: 0, actual_dictation: 0, shipped_default: 0 };

  for (const row of data.engineAndTierB) {
    const engine = row.engine || DEFAULT_ENGINE;
    engineBuckets[engine] = (engineBuckets[engine] || 0) + 1;
    engineCount += 1;

    const tierAProvider = tierAByUser.get(row.distinct_id);
    const provider = tierAProvider || row.tier_b_provider || DEFAULT_PROVIDER;
    polishBuckets[provider] = (polishBuckets[provider] || 0) + 1;
    polishCount += 1;
    if (tierAProvider) resolutionSource.settings += 1;
    else if (row.tier_b_provider) resolutionSource.actual_dictation += 1;
    else resolutionSource.shipped_default += 1;
  }

  if (engineCount !== data.totalUsers || polishCount !== data.totalUsers) {
    throw new Error(
      `completeness check failed: engine=${engineCount} polish=${polishCount} totalUsers=${data.totalUsers}`
    );
  }

  return { engineBuckets, polishBuckets, resolutionSource };
}
