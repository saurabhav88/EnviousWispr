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

  const [latency, seven, volume, versions, ref] = await Promise.all([
    hogql(env, latencySql),
    hogql(env, sevenDaySql),
    hogql(env, volumeSql),
    hogql(env, versionSql),
    hogql(env, refSql),
  ]);

  return {
    latencyDays: rowsToObjects(latency),
    seven: rowsToObjects(seven)[0] || {},
    volumeDays: rowsToObjects(volume),
    versions: rowsToObjects(versions),
    t1ref: (rowsToObjects(ref)[0] || {}).t1,
  };
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

function num(v) {
  const n = typeof v === "string" ? parseFloat(v) : v;
  return Number.isFinite(n) ? n : 0;
}

function pct(x) {
  return (x * 100).toFixed(1) + "%";
}

function topVersionsFor(versions, key) {
  return versions
    .filter((v) => num(v[key]) > 0)
    .sort((a, b) => num(b[key]) - num(a[key]))
    .slice(0, 3)
    .map((v) => `${v.ver || "unknown"}: ${num(v[key])}`)
    .join(", ");
}

// ----- Message ------------------------------------------------------------

export function buildMessage(r, versions = []) {
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
  const heartbeat = `${head}. T-1: ${t1d} dictations${ratioStr}. ${coverage}${driftStr}`;

  let content = heartbeat;
  if (alerts.length) {
    content += "\n\n" + alerts.map((a) => "* " + a).join("\n") + `\n${DASHBOARD}`;
  }
  // Discord content cap is 2000 chars.
  return content.length > 1990 ? content.slice(0, 1987) + "..." : content;
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

  const results = {
    latency: evaluateLatency(data.latencyDays),
    paste: evaluatePaste(data.seven),
    afm: evaluateAFM(data.seven),
    transcription: evaluateTranscription(data.seven),
    volume: evaluateVolume(data.volumeDays, data.t1ref),
  };
  const message = buildMessage(results, data.versions);

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
