/**
 * EnviousWispr Daily Product-Health Check - Cloudflare Worker (issue #1092)
 *
 * Runs once a day (cron) plus a manual HTTP trigger. Reads existing product
 * events from PostHog over COMPLETED time windows, compares each metric to a
 * baseline-calibrated threshold with low-volume guards, and posts to Discord:
 *   - a one-line heartbeat EVERY run (carries the day's dictation volume +
 *     which metrics evaluated / were skipped / are dark / failed), so a silent
 *     worker death or a telemetry blackout is itself visible;
 *   - a louder alert block when a metric crosses.
 *
 * Advisory only. Gates nothing. Plan + thresholds:
 *   docs/feature-requests/issue-1092-2026-06-20-daily-product-health-check.md
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

// Per-distinct_id -dev exclusion implements analytics-operations.md
// RULE: founder-machine-tell-in-distinct-id (a dev build anywhere in an id's
// history marks the whole id as dogfood). Bare field names do not resolve in
// HogQL, so every property reference is prefixed `properties.`.
const PROD = `properties.environment = 'production'
  AND distinct_id NOT IN (
    SELECT distinct_id FROM events
    WHERE properties.app_version LIKE '%-dev%' )`;

async function hogql(env, sql) {
  const res = await fetch(`${POSTHOG_HOST}/api/projects/${env.POSTHOG_PROJECT_ID}/query/`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.POSTHOG_PERSONAL_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ query: { kind: "HogQLQuery", query: sql }, refresh: "blocking" }),
  });
  if (!res.ok) {
    // Loud: do not let a query failure look like healthy silence.
    throw new Error(`PostHog query HTTP ${res.status}`);
  }
  const json = await res.json();
  if (!json.results) throw new Error("PostHog query returned no results array");
  return json; // { results: [...rows], columns: [...] }
}

// Completed-window helpers: every window ends at the start of today (UTC), so
// the partial current day (and late-flushing offline laptops) is excluded.
const DAY = "toStartOfDay(now())"; // ClickHouse/PostHog default timezone is UTC

export async function fetchHealth(env) {
  // 1) Per-day latency for the last 14 complete days (covers the 2-qualifying-day
  //    sustained check AND the 14d drift median).
  const latencySql = `
    SELECT toDate(timestamp) AS day, count() AS n,
           round(quantile(0.5)(toFloat(properties.e2e_seconds)), 3) AS p50,
           round(quantile(0.95)(toFloat(properties.e2e_seconds)), 3) AS p95
    FROM events
    WHERE event = 'dictation.completed' AND ${PROD}
      AND properties.e2e_seconds IS NOT NULL
      AND timestamp >= ${DAY} - INTERVAL 14 DAY AND timestamp < ${DAY}
    GROUP BY day ORDER BY day DESC`;

  // 2) The four 7d rate metrics in one pass (previous 7 complete days).
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
    WHERE ${PROD}
      AND event IN ('paste.completed', 'llm.polish_completed', 'pipeline.failed', 'dictation.completed')
      AND timestamp >= ${DAY} - INTERVAL 7 DAY AND timestamp < ${DAY}`;

  // 3) Per-day volume + co-firing counts for the last 8 complete days
  //    (T-1 vs the 7 days before it; co-firing blackout = schema drift).
  const volumeSql = `
    SELECT toDate(timestamp) AS day,
           countIf(event = 'dictation.completed') AS dictations,
           countIf(event = 'paste.completed') AS pastes,
           countIf(event = 'asr.completed') AS asr
    FROM events
    WHERE ${PROD} AND event IN ('dictation.completed', 'paste.completed', 'asr.completed')
      AND timestamp >= ${DAY} - INTERVAL 8 DAY AND timestamp < ${DAY}
    GROUP BY day ORDER BY day DESC`;

  // 4) Top app-versions for the crossing-prone metrics (one pass, 7d).
  const versionSql = `
    SELECT properties.app_version AS ver,
           countIf(event = 'paste.completed' AND properties.tier LIKE 'clipboard_only%') AS paste_fb,
           countIf(event = 'pipeline.failed' AND properties.stage = 'transcription') AS trans_fail,
           countIf(event = 'llm.polish_completed'
                   AND properties.fallback_reason IN ('guard_discard', 'validator_discard')) AS afm_disc
    FROM events
    WHERE ${PROD}
      AND event IN ('paste.completed', 'pipeline.failed', 'llm.polish_completed')
      AND timestamp >= ${DAY} - INTERVAL 7 DAY AND timestamp < ${DAY}
    GROUP BY ver ORDER BY (paste_fb + trans_fail + afm_disc) DESC LIMIT 5`;

  // The expected T-1 date per PostHog's own clock. Used to detect a zero-event
  // T-1: the GROUP BY day query emits NO row for a day with zero events, so we
  // must look T-1 up by date rather than trust the newest row.
  const refSql = `SELECT toString(toDate(toStartOfDay(now()) - INTERVAL 1 DAY)) AS t1`;

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
  const onboardingSql = `
    SELECT toDate(timestamp) AS day,
           countIf(event = 'onboarding.started') AS started,
           countIf(event = 'onboarding.completed') AS completed,
           countIf(event = 'onboarding.abandoned' AND properties.screen != 'welcome') AS abandoned,
           countIf(event = 'onboarding.abandoned') AS abandonedRaw,
           countIf(event = 'onboarding.abandoned' AND (properties.screen IS NULL OR properties.screen = '')) AS abandonedMissingScreen
    FROM events
    WHERE ${PROD}
      AND event IN ('onboarding.started', 'onboarding.completed', 'onboarding.abandoned')
      AND timestamp >= ${DAY} - INTERVAL 21 DAY AND timestamp < ${DAY}
    GROUP BY day ORDER BY day DESC`;

  // 6) Phase 10 (#1179): per-day, per-backend transcription attempts, 14
  //    complete days. Backend enumeration comes from EITHER event's backend
  //    tag (dictation.completed's asr_backend, pipeline.failed's backend) —
  //    canonical contract B2: an active backend with zero matching failures
  //    still gets a row (fails: 0), never silently drops.
  const backendTranscriptionSql = `
    SELECT toDate(timestamp) AS day,
           coalesce(properties.asr_backend, properties.backend) AS backend,
           countIf(event = 'dictation.completed') AS dictations,
           countIf(event = 'pipeline.failed' AND properties.stage = 'transcription') AS fails
    FROM events
    WHERE ${PROD}
      AND ((event = 'dictation.completed')
        OR (event = 'pipeline.failed' AND properties.stage = 'transcription'))
      AND timestamp >= ${DAY} - INTERVAL 14 DAY AND timestamp < ${DAY}
    GROUP BY day, backend ORDER BY day DESC`;

  // 7) Phase 10 (#1179) per-release segmentation, matching each metric's own
  //    window (§3 Design "Per-release segmentation").
  const onboardingVersionSql = `
    SELECT properties.app_version AS ver,
           countIf(event = 'onboarding.abandoned' AND properties.screen != 'welcome') AS onboarding_abandon
    FROM events
    WHERE ${PROD} AND event = 'onboarding.abandoned'
      AND timestamp >= ${DAY} - INTERVAL 21 DAY AND timestamp < ${DAY}
    GROUP BY ver ORDER BY onboarding_abandon DESC LIMIT 5`;

  // LIMIT is generous (not per-backend) headroom, not a per-backend cap: a
  // global LIMIT 10 could let one high-volume backend's rows crowd out a
  // second backend's rows entirely, since `topVersionsFor` filters BY backend
  // only after this query returns (Codex review finding). Two backends today
  // (Parakeet, WhisperKit) with `limit: 3` displayed each means 40 comfortably
  // covers both without a per-backend-ranked subquery this codebase has no
  // other precedent for.
  const backendVersionSql = `
    SELECT properties.app_version AS ver,
           properties.backend AS backend,
           countIf(event = 'pipeline.failed' AND properties.stage = 'transcription') AS backend_trans_fail
    FROM events
    WHERE ${PROD} AND event = 'pipeline.failed' AND properties.stage = 'transcription'
      AND timestamp >= ${DAY} - INTERVAL 14 DAY AND timestamp < ${DAY}
    GROUP BY ver, backend ORDER BY backend_trans_fail DESC LIMIT 40`;

  const [latency, seven, volume, versions, ref, onboarding, backendTranscription, onboardingVersions, backendVersions] =
    await Promise.all([
      hogql(env, latencySql),
      hogql(env, sevenDaySql),
      hogql(env, volumeSql),
      hogql(env, versionSql),
      hogql(env, refSql),
      hogql(env, onboardingSql),
      hogql(env, backendTranscriptionSql),
      hogql(env, onboardingVersionSql),
      hogql(env, backendVersionSql),
    ]);

  return {
    latencyDays: rowsToObjects(latency),
    seven: rowsToObjects(seven)[0] || {},
    volumeDays: rowsToObjects(volume),
    versions: rowsToObjects(versions),
    t1ref: (rowsToObjects(ref)[0] || {}).t1,
    onboardingDays: rowsToObjects(onboarding),
    backendTranscriptionDays: groupByBackend(rowsToObjects(backendTranscription)),
    onboardingVersions: rowsToObjects(onboardingVersions),
    backendVersions: rowsToObjects(backendVersions),
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
  const recentTerminals = recent.reduce((sum, row) => sum + num(row.completed) + num(row.abandoned), 0);
  const baselineAvg = baseline.reduce((sum, row) => sum + num(row.started), 0) / TH.baselineDays;

  // (a) Entry point itself broke: zero starts against a real trailing baseline.
  const entryPointDown = recentStarted === 0 && baselineAvg >= TH.activeBaselineAvg;
  // (b) Terminal events stopped firing despite starts continuing (schema drift) —
  // NOT "nobody abandoned" (a low/zero abandon count with healthy completions is GOOD).
  const terminalDrift = recentStarted >= TH.terminalMinStarted && recentTerminals === 0;

  return { state: entryPointDown || terminalDrift ? "alerting" : "evaluated-ok",
    entryPointDown, terminalDrift, recentStarted, recentTerminals, baselineAvg };
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
    .map((row) => `${row.ver || "unknown"}: ${num(row[key])}`)
    .join(", ");
}

// ----- Message ------------------------------------------------------------

export function buildMessage(r, versions = [], onboardingVersions = [], backendVersions = []) {
  const alerts = [];
  const evaluated = [];
  const skipped = [];
  const dark = [];

  const note = (name, ev) => {
    if (ev.state === "alerting") return; // handled as an alert
    if (ev.state === "evaluated-ok") evaluated.push(name);
    else if (ev.state === "dark-awaiting-release") dark.push(name);
    else skipped.push(name);
  };

  // Latency
  if (r.latency.state === "alerting") {
    const d = r.latency.latest;
    alerts.push(
      `latency high: p50 ${d.p50}s / p95 ${d.p95}s, ${r.latency.last2.length} qualifying days, ` +
      `thresholds p50>${THRESHOLDS.latency.p50}s or p95>${THRESHOLDS.latency.p95}s (baseline p50 ~1.5s).`
    );
  }
  note("latency", r.latency);

  // Paste
  if (r.paste.state === "alerting") {
    const tv = topVersionsFor(versions, "paste_fb");
    alerts.push(
      `paste fallback ${pct(r.paste.share)} (${r.paste.fb}/${r.paste.total}, prev 7d), ` +
      `threshold >${pct(THRESHOLDS.paste.share)}, baseline ~1.2%. ` +
      `Split: ax_denied ${r.paste.ax}, direct-paste-failed ${r.paste.cb}.` +
      (tv ? ` Top versions ${tv}.` : "")
    );
  }
  note("paste", r.paste);

  // AFM discard
  if (r.afm.state === "alerting") {
    const tv = topVersionsFor(versions, "afm_disc");
    alerts.push(
      `AFM genuine discard ${pct(r.afm.share)} (${r.afm.disc}/${r.afm.frRows} fr-rows, prev 7d), ` +
      `threshold >${pct(THRESHOLDS.afm.share)}, baseline ~10%.` + (tv ? ` Top versions ${tv}.` : "")
    );
  }
  note("AFM-discard", r.afm);

  // Transcription
  if (r.transcription.state === "alerting") {
    const tv = topVersionsFor(versions, "trans_fail");
    alerts.push(
      `transcription failure family ${pct(r.transcription.share)} ` +
      `(${r.transcription.fails}/${r.transcription.denom}, prev 7d, includes legitimate no-speech), ` +
      `threshold >${pct(THRESHOLDS.transcription.share)}, baseline ~0.9%.` + (tv ? ` Top versions ${tv}.` : "")
    );
  }
  note("transcription", r.transcription);

  // Onboarding abandon (Phase 10, #1179)
  if (r.onboardingAbandon) {
    const ev = r.onboardingAbandon;
    if (ev.state === "alerting" && ev.attributionDrift) {
      // Screen-attribution drift: distinct wording, no version attribution
      // (this is a schema-drift signal, not a rate). Names the missing-screen
      // count directly (Codex r4 review finding), not the raw total, so the
      // alert cannot fire on a legitimate all-welcome concentration.
      alerts.push(
        `onboarding abandon attribution lost: ${ev.totalAbandonedMissingScreen} of ` +
        `${ev.totalAbandonedRaw} onboarding.abandoned events over the prev 21d had no usable ` +
        `properties.screen (properties.screen may have stopped emitting or been renamed).`
      );
    } else if (ev.state === "alerting") {
      // Report the window that actually crossed (Codex review finding: a
      // fast-only crossing must not display the healthy rolling total).
      const windowText = ev.fastCrossing
        ? `${pct(ev.fastShare)} (${ev.fastAbandoned}/${ev.fastStarted}, fast 2-day crossing)`
        : `${pct(ev.rollingShare)} (${ev.totalAbandoned}/${ev.totalStarted}, prev 21d, rolling crossing)`;
      // Version attribution only matches the metric's own 21-day window —
      // a fast (2-day) crossing must not misattribute to it (Codex review
      // finding: an older high-volume release can otherwise be blamed for a
      // regression confined to the last 2 days).
      const tv = ev.fastCrossing ? "" : topVersionsFor(onboardingVersions, "onboarding_abandon");
      alerts.push(
        `onboarding abandon ${windowText}, threshold >${pct(THRESHOLDS.onboardingAbandon.share)}, ` +
        `baseline ~37%.` + (tv ? ` Top versions ${tv}.` : "")
      );
    }
    note("onboarding-abandon", ev);
  }

  // Per-backend transcription (Phase 10, #1179)
  if (r.backendTranscription) {
    for (const row of r.backendTranscription) {
      if (row.state === "alerting" && row.attributionDrift) {
        // Backend-attribution drift (Codex review finding): distinct wording,
        // no version attribution.
        alerts.push(
          `transcription backend attribution lost: ${row.attempts} dictation/failure events ` +
          `over the prev 14d carried no usable asr_backend or backend tag ` +
          `(the per-backend split has degraded to an aggregate).`
        );
      } else if (row.state === "alerting") {
        // Same fix as onboarding-abandon: name the window that actually
        // crossed, and only attribute versions to a matching window.
        const windowText = row.fastCrossing
          ? `${pct(row.fastShare)} (${row.fastFails}/${row.fastAttempts}, fast 2-day crossing)`
          : `${pct(row.rollingShare)} (${row.fails}/${row.attempts}, prev 14d, rolling crossing)`;
        const tv = row.fastCrossing
          ? ""
          : topVersionsFor(backendVersions, "backend_trans_fail", { backend: row.backend });
        alerts.push(
          `${row.backend} transcription failure ${windowText}, ` +
          `threshold >${pct(THRESHOLDS.backendTranscription.share)}.` + (tv ? ` Top versions ${tv}.` : "")
        );
      }
      note(`transcription-${row.backend}`, row);
    }
    if (r.backendAttributionBlackout) {
      // Total backend-attribution blackout (Codex review finding): the query
      // matched zero (day, backend) groups despite healthy overall dictation
      // volume — the per-backend split vanished entirely rather than reading
      // as merely quiet.
      alerts.push(
        `transcription backend attribution blackout: 0 backend rows over the prev 14d despite ` +
        `healthy aggregate 7d dictation volume (asr_backend/backend may have stopped emitting entirely).`
      );
    }
  }

  // Onboarding blackout (Phase 10, #1179) — evaluated-ok/alerting only, no
  // low-volume/dark states, so it participates in `note()`'s evaluated bucket
  // like the rate metrics, but can never land in skipped/dark.
  if (r.onboardingBlackout) {
    if (r.onboardingBlackout.state === "alerting") {
      if (r.onboardingBlackout.entryPointDown) {
        alerts.push(
          `onboarding entry point down: 0 starts over the trailing 48h while the 7-day ` +
          `baseline average is ${r.onboardingBlackout.baselineAvg.toFixed(1)}/day ` +
          `(possible onboarding-screen crash or telemetry blackout).`
        );
      }
      if (r.onboardingBlackout.terminalDrift) {
        alerts.push(
          `onboarding terminal drift: ${r.onboardingBlackout.recentStarted} starts over the trailing 48h ` +
          `but neither onboarding.completed nor onboarding.abandoned fired ` +
          `(a terminal event may have stopped emitting).`
        );
      }
    }
    note("onboarding-blackout", r.onboardingBlackout);
  }

  // Volume / integrity
  if (r.volume.state === "alerting") {
    if (r.volume.zeroAlert) {
      alerts.push(
        `ZERO dictations on T-1 while trailing-7d average is ${r.volume.avg.toFixed(0)}/day ` +
        `(possible crash-on-launch or telemetry blackout).`
      );
    }
    if (r.volume.driftAlert) {
      alerts.push(
        `telemetry drift: T-1 had ${r.volume.t1d} dictations but asr.completed was 0 ` +
        `(it co-fires on every successful dictation) - a success event may have stopped emitting.`
      );
    }
  }

  // Heartbeat line (always)
  const t1d = r.volume.t1d != null ? r.volume.t1d : "?";
  const ratioStr =
    r.volume.ratio != null ? ` (${r.volume.ratio.toFixed(2)}x trailing avg)` : "";
  const driftStr =
    r.latency.driftMedian != null && r.latency.latest
      ? ` p50 drift: ${r.latency.latest.p50}s vs 14d ${r.latency.driftMedian.toFixed(2)}s`
      : "";
  const coverage =
    `Evaluated: ${evaluated.join(", ") || "none"}.` +
    (dark.length ? ` Dark: ${dark.join(", ")}.` : "") +
    (skipped.length ? ` Skipped (low volume): ${skipped.join(", ")}.` : "");
  const head = alerts.length ? "EnviousWispr health - ALERT" : "EnviousWispr health - OK";
  // H1 (canonical contract H1): a static pointer, every run — this worker does
  // NOT deliver crash-free-session-rate or per-version crash regression.
  const h1Line = " Crash/error-rate monitoring lives in Sentry's own alert rules (see Error Spike >5/hr), not in this report.";
  const heartbeat = `${head}. T-1: ${t1d} dictations${ratioStr}. ${coverage}${driftStr}${h1Line}`;

  if (!alerts.length) return heartbeat;

  // Discord content cap is 2000 chars. A blind character slice can cut mid-
  // alert and silently drop the dashboard link, hiding the very alerts most
  // worth seeing (Codex review finding) — drop whole alerts from the end
  // instead, always keeping the heartbeat and the dashboard link.
  for (let keep = alerts.length; keep > 0; keep--) {
    const omitted = alerts.length - keep;
    const trailer = omitted > 0 ? `\n(${omitted} more alert(s) omitted; see dashboard)` : "";
    const trial =
      heartbeat + "\n\n" + alerts.slice(0, keep).map((a) => "* " + a).join("\n") + trailer + `\n${DASHBOARD}`;
    if (trial.length <= 1990) return trial;
  }
  return `${heartbeat}\n\n${alerts.length} alert(s) triggered; see ${DASHBOARD}`.slice(0, 1990);
}

// ----- Run ----------------------------------------------------------------

async function runHealth(env) {
  let data;
  try {
    data = await fetchHealth(env);
  } catch (err) {
    // Loud failure: post a notice if Discord is reachable, then rethrow so
    // Cloudflare logs it. A failed run must never read as "all green".
    await safePost(env, `EnviousWispr health - CHECK FAILED TO RUN: ${err.message}`);
    throw err;
  }

  const backendTranscription = evaluateBackendTranscription(data.backendTranscriptionDays, data.t1ref);
  // Backend-attribution blackout (Codex review finding): an empty result here
  // means the query matched zero (day, backend) groups at all — every row's
  // backend tag AND every dictation/failure vanished together. The existing
  // aggregate transcription metric's own 7-day dictation count is proof this
  // worker already has of real activity; if it's healthy while this metric's
  // per-backend split came back with nothing, that split has silently gone
  // dark rather than merely being quiet, so it must alert, not disappear.
  const backendAttributionBlackout =
    backendTranscription.length === 0 && num(data.seven.dictations_7d) >= THRESHOLDS.transcription.minDictations;

  const results = {
    latency: evaluateLatency(data.latencyDays),
    paste: evaluatePaste(data.seven),
    afm: evaluateAFM(data.seven),
    transcription: evaluateTranscription(data.seven),
    volume: evaluateVolume(data.volumeDays, data.t1ref),
    onboardingAbandon: evaluateOnboardingAbandon(data.onboardingDays, data.t1ref),
    backendTranscription,
    backendAttributionBlackout,
    onboardingBlackout: evaluateOnboardingBlackout(data.onboardingDays, data.t1ref),
  };
  const message = buildMessage(results, data.versions, data.onboardingVersions, data.backendVersions);

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
