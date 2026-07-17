/**
 * EnviousWispr Daily Performance Report - Cloudflare Worker (issue #1433)
 *
 * Runs once a day via a secret-gated HTTP trigger (scheduling lives in
 * .github/workflows/daily-report-ping.yml, not a Cloudflare cron - the CF
 * account is at its 5-cron free-plan limit, see #1092). Reads PostHog events
 * over the previous COMPLETE Eastern calendar day and posts a plain-English
 * summary to Discord (EnviousNotes): installs/onboarding/activation, total
 * active users, transcription-engine choice by user, AI-polish choice by
 * user (their CONFIGURED choice, not per-dictation runtime outcome - a
 * dictation that silently skipped polish for a by-design reason still
 * counts toward whatever provider the user has selected), net dictation
 * volume, top-5 countries, and the top-5 heaviest users by volume.
 *
 * Gates nothing, alerts on nothing - purely a daily digest. Plan + full
 * metric-definition rationale: docs/feature-requests/issue-1433-2026-07-09-daily-report.md
 *
 * Privacy: output and logs are counts / rates / labels only. Never a raw
 * transcript, a PostHog response body, a Discord response body, or the
 * trigger secret.
 */

const POSTHOG_HOST = "https://us.posthog.com";

// Shipped app defaults (SettingsDefaultValues.swift) - the tier-of-last-resort
// when a user has neither a settings record nor any dictation carrying a
// signal. See plan §3.3 row 4.
const DEFAULT_ENGINE = "parakeet";
const DEFAULT_PROVIDER = "appleIntelligence";

// Per-worker distinct_id list bound. Genuinely a defense-in-depth ceiling,
// never the primary correctness mechanism - see PROD/completeness check below
// and plan §3.3a. 5000 is far above any realistic single-day population.
const PER_USER_LIST_LIMIT = 5000;

export default {
  async fetch(request, env) {
    // Manual trigger is secret-gated: the workers.dev URL is public, so an
    // unauthenticated request must NOT run the report or post to Discord.
    // Fail closed. Mirrors workers/product-health/src/index.js exactly.
    const url = new URL(request.url);
    const provided = url.searchParams.get("token") || request.headers.get("x-trigger-secret");
    if (!env.TRIGGER_SECRET || provided !== env.TRIGGER_SECRET) {
      return new Response("unauthorized\n", { status: 401 });
    }
    const dateOverride = url.searchParams.get("date"); // optional YYYY-MM-DD Eastern-date recovery override
    try {
      const message = await runReport(env, dateOverride);
      return new Response(message + "\n", { status: 200 });
    } catch (err) {
      return new Response("daily report failed: " + err.message + "\n", { status: 500 });
    }
  },
};

// ----- Eastern calendar-day boundary ---------------------------------------

const EASTERN_TZ = "America/New_York";

/**
 * Returns { dateStr, startUTC, endUTC } for the target Eastern calendar day:
 * yesterday relative to `now`, or the explicit `dateOverride` (YYYY-MM-DD)
 * when provided (manual recovery after a missed scheduled run - plan §4-9
 * failure-mode table). startUTC/endUTC are the true UTC instants of that
 * day's midnight-to-midnight boundary in America/New_York, computed via the
 * Intl timezone API (handles EST/EDT correctly, no library dependency).
 */
export function easternYesterdayWindowUTC(now = new Date(), dateOverride = null) {
  const targetDateStr = dateOverride || shiftDateString(easternDateString(now), -1);
  const startUTC = findUTCForEasternMidnight(targetDateStr);
  const endUTC = findUTCForEasternMidnight(shiftDateString(targetDateStr, 1));
  return { dateStr: targetDateStr, startUTC, endUTC };
}

function easternDateString(date) {
  // en-CA formats as YYYY-MM-DD.
  return new Intl.DateTimeFormat("en-CA", { timeZone: EASTERN_TZ }).format(date);
}

function shiftDateString(dateStr, days) {
  const [y, m, d] = dateStr.split("-").map(Number);
  const noonUTC = new Date(Date.UTC(y, m - 1, d, 12)); // noon avoids any DST-edge ambiguity
  noonUTC.setUTCDate(noonUTC.getUTCDate() + days);
  return noonUTC.toISOString().slice(0, 10);
}

function findUTCForEasternMidnight(dateStr) {
  const [y, m, d] = dateStr.split("-").map(Number);
  const naiveUTCMs = Date.UTC(y, m - 1, d, 0, 0, 0);
  // Converges in one correction: the ET offset is stable across the ~4-5hr
  // window between a naive-UTC guess and the true instant, except exactly on
  // a DST-transition calendar day, where a second pass fixes it.
  // easternOffsetMinutesAt returns a SIGNED offset (negative for ET, e.g.
  // -300 for EST/-240 for EDT, standard "west of UTC" convention) -
  // SUBTRACTING it converts local midnight to the real UTC instant.
  let guessMs = naiveUTCMs;
  for (let i = 0; i < 2; i++) {
    const offsetMinutes = easternOffsetMinutesAt(new Date(guessMs));
    guessMs = naiveUTCMs - offsetMinutes * 60000;
  }
  return new Date(guessMs);
}

/** Signed UTC offset in minutes for America/New_York at `date` (EST=-300, EDT=-240). */
function easternOffsetMinutesAt(date) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: EASTERN_TZ,
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).formatToParts(date);
  const v = {};
  for (const p of parts) v[p.type] = p.value;
  const localAsUTC = Date.UTC(
    Number(v.year), Number(v.month) - 1, Number(v.day),
    Number(v.hour), Number(v.minute), Number(v.second)
  );
  return (localAsUTC - date.getTime()) / 60000;
}

function sqlTimestamp(date) {
  return date.toISOString().slice(0, 19).replace("T", " ");
}

// ----- PostHog ---------------------------------------------------------------

// Per-distinct_id -dev exclusion (analytics-operations.md RULE:
// founder-machine-tell-in-distinct-id): a dev build anywhere in an id's
// history marks the whole id as dogfood. Verbatim shape from
// workers/product-health/src/index.js.
const PROD = `properties.environment = 'production'
  AND distinct_id NOT IN (
    SELECT distinct_id FROM events
    WHERE properties.app_version LIKE '%-dev%' )`;

function windowClause(startUTC, endUTC) {
  return `timestamp >= '${sqlTimestamp(startUTC)}' AND timestamp < '${sqlTimestamp(endUTC)}'`;
}

/** The day's active-user population (successful dictators) as a reusable
 * subquery fragment - used once, for the onboarded->activated intersection
 * (a single subquery evaluation, cheap). NOT reused for polish tier-a: an
 * earlier version nested this same subquery twice inside a UNION, which
 * measurably timed out against production PostHog - see the comment above
 * `tierASqlFor` below for why tier-a instead takes a literal id list. */
function activeUsersSubquery(win) {
  return `SELECT DISTINCT distinct_id FROM events
    WHERE event = 'dictation.completed' AND properties.result = 'success'
      AND ${PROD} AND ${win}`;
}

/** Escapes a distinct_id for a HogQL string literal (single-quote doubling,
 * the standard SQL escape - distinct_ids are opaque PostHog-generated ids,
 * never user-authored text, so this is a closed, low-risk input class). */
function sqlIdList(ids) {
  return ids.map((id) => `'${String(id).replace(/'/g, "''")}'`).join(", ");
}

/** Polish tier-a: latest value across the UNION of settings.snapshot and
 * settings.changed{setting='llm_provider'}, bounded to a LITERAL list of
 * already-known active-user ids (plan §3.3 row 4, r2 precision fix) rather
 * than a re-evaluated subquery - the subquery form (distinct_id IN
 * (activeUsersSubquery)) repeated twice inside this UNION timed out (HTTP
 * 504) against production PostHog; the literal-list form is the exact
 * pattern already validated empirically during planning. */
function tierASqlFor(activeIds, endTs) {
  const ids = sqlIdList(activeIds);
  return `
    SELECT distinct_id, argMax(value, ts) AS provider
    FROM (
      SELECT distinct_id, properties.llm_provider AS value, timestamp AS ts
      FROM events
      WHERE event = 'settings.snapshot' AND ${PROD}
        AND distinct_id IN (${ids})
        AND timestamp < '${endTs}'
      UNION ALL
      SELECT distinct_id, properties.to AS value, timestamp AS ts
      FROM events
      WHERE event = 'settings.changed' AND properties.setting = 'llm_provider' AND ${PROD}
        AND distinct_id IN (${ids})
        AND timestamp < '${endTs}'
    )
    GROUP BY distinct_id
    LIMIT ${PER_USER_LIST_LIMIT}`;
}

// PostHog's project-level rate limit allows only 3 concurrent queries and
// queues/cancels/times-out (HTTP 502/503/504) anything beyond that (#1588,
// posthog.com/docs/api/queries + posthog.com/docs/endpoints/rate-limits).
// `runLimited` below caps our own concurrency under that ceiling; this retry
// is the second, complementary layer for genuine transient contention (e.g.
// the project is shared with EnviousStaging - analytics-operations.md FACT:
// posthog-project-is-shared-with-enviousstaging). It retries exactly once,
// only on the documented queue-timeout status class, and only ever before
// any Discord post happens - unlike the deliberately-rejected outer
// GitHub-Actions-level retry (see the comment in daily-report-ping.yml),
// this cannot produce a duplicate or confusing failure notice.
const RETRYABLE_POSTHOG_STATUSES = new Set([502, 503, 504]);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export async function hogql(
  env,
  sql,
  queryName,
  { fetchFn = fetch, sleepFn = sleep, retryDelayMs = 1500 } = {}
) {
  const url = `${POSTHOG_HOST}/api/projects/${env.POSTHOG_PROJECT_ID}/query/`;

  for (let attempt = 1; attempt <= 2; attempt += 1) {
    const res = await fetchFn(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.POSTHOG_PERSONAL_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        query: { kind: "HogQLQuery", query: sql },
        refresh: "blocking",
        name: `daily_report_${queryName}`,
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
        // failed cancel must not mask it. Draining/cancelling the failed
        // body here matters specifically because a retry immediately opens
        // a NEW outbound request on the same wave - an uncancelled body can
        // hold its Cloudflare subrequest connection open, and enough of
        // those piling up across retries could exhaust Cloudflare's own
        // outbound-connection ceiling and recreate the stall this change
        // exists to fix (Codex code-diff review, round 2, #1588).
      }
    }

    if (attempt === 2 || !RETRYABLE_POSTHOG_STATUSES.has(status)) {
      throw new Error(`PostHog query ${queryName} HTTP ${status}`);
    }
    await sleepFn(retryDelayMs);
  }
}

// Runs `tasks` (zero-arg async thunks) in fixed waves of at most `limit`
// concurrently, preserving input order in the returned results. Exists
// because PostHog's project-level query-concurrency ceiling is 3 (#1588) -
// firing more than that at once gets the excess queued for up to 30s before
// PostHog cancels/times it out. A failed wave stops later waves from
// starting, matching `Promise.all`'s existing all-or-nothing contract for
// the whole batch (already-started requests within a wave still run to
// completion; a new wave simply never starts).
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

function rowsToObjects(res) {
  const cols = res.columns || [];
  return (res.results || []).map((row) => {
    const o = {};
    cols.forEach((c, i) => (o[c] = row[i]));
    return o;
  });
}

export async function fetchReportData(env, win, endUTC) {
  const endTs = sqlTimestamp(endUTC);
  const activeUsers = activeUsersSubquery(win);

  const installsSql = `
    SELECT uniqExact(distinct_id) FROM events
    WHERE event = 'app.launched' AND properties.is_fresh_install = true
      AND ${PROD} AND ${win}`;

  const onboardActivateSql = `
    SELECT
      uniqExact(distinct_id) AS onboarded,
      uniqExactIf(distinct_id, distinct_id IN (${activeUsers})) AS activated
    FROM events
    WHERE event = 'onboarding.completed' AND ${PROD} AND ${win}`;

  const totalsSql = `
    SELECT count() AS net_dictations, uniqExact(distinct_id) AS total_users
    FROM events
    WHERE event = 'dictation.completed' AND properties.result = 'success' AND ${PROD} AND ${win}`;

  // Engine (row 3) + polish tier-b fallback (row 4) share the same event
  // population, so one query resolves both per user.
  const engineAndTierBSql = `
    SELECT distinct_id,
           argMax(properties.asr_backend, timestamp) AS engine,
           anyIf(properties.llm_provider, properties.llm_provider IS NOT NULL) AS tier_b_provider
    FROM events
    WHERE event = 'dictation.completed' AND properties.result = 'success' AND ${PROD} AND ${win}
    GROUP BY distinct_id
    LIMIT ${PER_USER_LIST_LIMIT}`;

  const geoSql = `
    SELECT properties.$geoip_country_name AS country, uniqExact(distinct_id) AS n
    FROM events
    WHERE event = 'dictation.completed' AND properties.result = 'success'
      AND properties.$geoip_country_name IS NOT NULL AND properties.$geoip_country_name != ''
      AND ${PROD} AND ${win}
    GROUP BY country
    ORDER BY n DESC
    LIMIT 5`;

  const top5Sql = `
    SELECT distinct_id, count() AS n
    FROM events
    WHERE event = 'dictation.completed' AND properties.result = 'success' AND ${PROD} AND ${win}
    GROUP BY distinct_id
    ORDER BY n DESC
    LIMIT 5`;

  // These 6 queries are independent, but PostHog allows only 3 concurrent
  // queries per project (#1588) - `runLimited(..., 2)` runs them in 3 fixed
  // waves of 2, leaving one slot of headroom for the shared project's other
  // traffic (EnviousStaging) rather than firing all 6 at once and getting
  // the excess queued/timed-out. Polish tier-a (below) runs sequentially
  // *after* all 3 waves finish - it does not need reserved concurrency.
  // Tier-a has its own history: an EARLIER version embedded the active-user
  // bound as a re-evaluated nested subquery inside a UNION and that
  // measurably timed out against production PostHog (HTTP 504) - two nested
  // re-scans of the whole PROD filter's dev-exclusion subquery, twice,
  // inside a UNION, is too expensive. Fixed by resolving the active-user id
  // list from `engineAndTierB` (already fetched, zero extra cost) and
  // passing it to tier-a as a literal IN-list instead of a subquery.
  const [installs, onboardActivate, totals, engineAndTierB, geo, top5] = await runLimited(
    [
      () => hogql(env, installsSql, "installs"),
      () => hogql(env, onboardActivateSql, "onboard_activate"),
      () => hogql(env, totalsSql, "totals"),
      () => hogql(env, engineAndTierBSql, "engine_and_tier_b"),
      () => hogql(env, geoSql, "geo"),
      () => hogql(env, top5Sql, "top5"),
    ],
    2
  );

  const activeIds = (engineAndTierB.results || []).map((row) => row[0]);
  const tierA = activeIds.length
    ? await hogql(env, tierASqlFor(activeIds, endTs), "tier_a")
    : { results: [], columns: [] };

  return {
    freshInstalls: installs.results[0][0],
    onboarded: rowsToObjects(onboardActivate)[0]?.onboarded ?? 0,
    activated: rowsToObjects(onboardActivate)[0]?.activated ?? 0,
    netDictations: rowsToObjects(totals)[0]?.net_dictations ?? 0,
    totalUsers: rowsToObjects(totals)[0]?.total_users ?? 0,
    engineAndTierB: rowsToObjects(engineAndTierB),
    tierA: rowsToObjects(tierA),
    geo: rowsToObjects(geo),
    top5: rowsToObjects(top5),
  };
}

// ----- Pure resolution + bucketing (unit-tested, no IO) --------------------

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

// ----- Message ---------------------------------------------------------------

const ENGINE_LABELS = { parakeet: "Parakeet", whisperKit: "WhisperKit" };
const PROVIDER_LABELS = {
  appleIntelligence: "Apple Intelligence",
  egOne: "EG-1 (our own model)",
  gemini: "Gemini",
  openAI: "OpenAI",
  ollama: "Ollama",
  none: "polish turned off",
};

function pctOf(n, total) {
  return total > 0 ? `${Math.round((n / total) * 100)}%` : "0%";
}

function formatBuckets(buckets, labels, total) {
  return Object.entries(buckets)
    .filter(([, n]) => n > 0)
    .sort((a, b) => b[1] - a[1])
    .map(([key, n]) => `${labels[key] || key} ${n} (${pctOf(n, total)})`)
    .join(", ");
}

function formatWeekdayDate(dateStr) {
  const [y, m, d] = dateStr.split("-").map(Number);
  const noonUTC = new Date(Date.UTC(y, m - 1, d, 12));
  return new Intl.DateTimeFormat("en-US", {
    timeZone: "UTC",
    weekday: "long",
    month: "long",
    day: "numeric",
    year: "numeric",
  }).format(noonUTC);
}

export function buildMessage(dateStr, data, buckets) {
  const lines = [`EnviousWispr Daily Report, ${formatWeekdayDate(dateStr)}`, ""];

  lines.push(
    `New installs: ${data.freshInstalls}. People who finished setup today: ${data.onboarded}. Of those, ${data.activated} also dictated today.`,
    ""
  );

  lines.push(`Total users: ${data.totalUsers} people used the app today.`, "");

  if (data.totalUsers > 0) {
    const engineLine = formatBuckets(buckets.engineBuckets, ENGINE_LABELS, data.totalUsers);
    if (engineLine) lines.push(`Transcription engine (by user): ${engineLine}.`, "");

    const polishLine = formatBuckets(buckets.polishBuckets, PROVIDER_LABELS, data.totalUsers);
    if (polishLine) lines.push(`AI polishing (by user, their selected choice): ${polishLine}.`, "");
  }

  lines.push(`Net total dictations: ${data.netDictations}.`, "");

  if (data.geo.length) {
    lines.push(`Where they are: ${data.geo.map((g) => `${g.country} ${g.n}`).join(", ")}.`, "");
  }

  if (data.top5.length) {
    lines.push(`Top 5 users by dictation volume: ${data.top5.map((u) => u.n).join(", ")}.`);
  }

  const content = lines.join("\n").trim();
  // Discord content cap is 2000 chars.
  return content.length > 1990 ? content.slice(0, 1987) + "..." : content;
}

// ----- Discord + run ---------------------------------------------------------

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
    // best-effort failure notice; the caller's throw is what surfaces the failure in logs/CI
  }
}

export async function runReport(env, dateOverride = null) {
  const { dateStr, startUTC, endUTC } = easternYesterdayWindowUTC(new Date(), dateOverride);
  const win = windowClause(startUTC, endUTC);

  let data, buckets;
  try {
    data = await fetchReportData(env, win, endUTC);
    buckets = resolveBuckets(data);
    // Resolution-tier logging (Cloudflare log only, never the Discord
    // message) - plan §3.3a. A spike in shipped_default's share vs
    // settings/actual_dictation is the telemetry-drift canary.
    console.log(
      `daily-report resolution tiers: settings=${buckets.resolutionSource.settings} ` +
        `actual_dictation=${buckets.resolutionSource.actual_dictation} ` +
        `shipped_default=${buckets.resolutionSource.shipped_default}`
    );
  } catch (err) {
    // Loud failure: never let a partial/failed run read as a normal report.
    await safePost(env, `Daily report failed to generate for ${dateStr}: ${err.message}`);
    throw err;
  }

  const message = buildMessage(dateStr, data, buckets);
  const ok = await postToDiscord(env.DISCORD_WEBHOOK_URL, message);
  if (!ok) throw new Error("Discord post failed");
  return message;
}
