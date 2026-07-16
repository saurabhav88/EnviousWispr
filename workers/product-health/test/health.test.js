// Unit tests for the pure threshold/state logic (no network).
// Run: node --test  (from workers/product-health/)
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  THRESHOLDS,
  evaluateLatency,
  evaluatePaste,
  evaluateAFM,
  evaluateTranscription,
  evaluateVolume,
  evaluateOnboardingAbandon,
  evaluateBackendTranscription,
  evaluateOnboardingBlackout,
  buildMessage,
} from "../src/index.js";

// ---- latency ----
test("latency: clean baseline does not alert", () => {
  const days = [
    { day: "2026-06-19", n: 200, p50: 1.5, p95: 4.9 },
    { day: "2026-06-18", n: 180, p50: 1.6, p95: 5.1 },
  ];
  assert.equal(evaluateLatency(days).state, "evaluated-ok");
});

test("latency: 2 sustained qualifying days over p50 floor -> alert", () => {
  const days = [
    { day: "2026-06-19", n: 200, p50: 2.8, p95: 6.0 },
    { day: "2026-06-18", n: 180, p50: 2.6, p95: 5.5 },
  ];
  assert.equal(evaluateLatency(days).state, "alerting");
});

test("latency: only 1 qualifying day over floor -> no alert", () => {
  const days = [
    { day: "2026-06-19", n: 200, p50: 2.8, p95: 6.0 },
    { day: "2026-06-18", n: 30, p50: 3.0, p95: 8.0 }, // below minN, skipped
    { day: "2026-06-17", n: 180, p50: 1.6, p95: 5.0 }, // qualifying but under floor
  ];
  assert.equal(evaluateLatency(days).state, "evaluated-ok");
});

test("latency: all days below minN -> skipped", () => {
  const days = [
    { day: "2026-06-19", n: 10, p50: 3.0, p95: 9.5 },
    { day: "2026-06-18", n: 5, p50: 3.0, p95: 9.5 },
  ];
  assert.equal(evaluateLatency(days).state, "skipped-low-volume");
});

test("latency: p95 floor alone trips when sustained", () => {
  const days = [
    { day: "2026-06-19", n: 200, p50: 1.5, p95: 9.5 },
    { day: "2026-06-18", n: 200, p50: 1.5, p95: 10.0 },
  ];
  assert.equal(evaluateLatency(days).state, "alerting");
});

// ---- paste ----
test("paste: ~1.2% baseline does not alert", () => {
  const row = { paste_total: 1000, paste_cb: 9, paste_ax: 3 };
  assert.equal(evaluatePaste(row).state, "evaluated-ok");
});

test("paste: >5% fallback -> alert with split", () => {
  const row = { paste_total: 260, paste_cb: 7, paste_ax: 10 };
  const ev = evaluatePaste(row);
  assert.equal(ev.state, "alerting");
  assert.equal(ev.ax, 10);
  assert.equal(ev.cb, 7);
});

test("paste: below 50 total -> skipped", () => {
  assert.equal(evaluatePaste({ paste_total: 40, paste_cb: 30, paste_ax: 0 }).state, "skipped-low-volume");
});

// ---- AFM (dark / forward-looking) ----
test("AFM: zero fr-bearing rows (pre-release) -> dark", () => {
  const row = { afm_fr_rows: 0, afm_disc: 0 };
  assert.equal(evaluateAFM(row).state, "dark-awaiting-release");
});

test("AFM: release seen but too few rows -> skipped (not 0%)", () => {
  assert.equal(evaluateAFM({ afm_fr_rows: 20, afm_disc: 2 }).state, "skipped-low-volume");
});

test("AFM: genuine discard >15% with enough rows -> alert", () => {
  const ev = evaluateAFM({ afm_fr_rows: 100, afm_disc: 20 });
  assert.equal(ev.state, "alerting");
});

test("AFM: ~10% genuine discard -> ok", () => {
  assert.equal(evaluateAFM({ afm_fr_rows: 100, afm_disc: 10 }).state, "evaluated-ok");
});

// ---- transcription ----
test("transcription: ~0.9% baseline does not alert", () => {
  const row = { trans_fails: 14, dictations_7d: 1500 };
  assert.equal(evaluateTranscription(row).state, "evaluated-ok");
});

test("transcription: >5% family rate -> alert", () => {
  const row = { trans_fails: 120, dictations_7d: 1500 };
  assert.equal(evaluateTranscription(row).state, "alerting");
});

test("transcription: below 200 dictations -> skipped", () => {
  assert.equal(evaluateTranscription({ trans_fails: 50, dictations_7d: 100 }).state, "skipped-low-volume");
});

// ---- volume / integrity ----
test("volume: normal day -> ok", () => {
  const days = [
    { day: "2026-06-19", dictations: 200, pastes: 200, asr: 200 },
    { day: "2026-06-18", dictations: 220, pastes: 220, asr: 220 },
  ];
  assert.equal(evaluateVolume(days, "2026-06-19").state, "evaluated-ok");
});

test("volume: zero dictations on active baseline (T-1 row present, 0) -> alert", () => {
  const days = [
    { day: "2026-06-19", dictations: 0, pastes: 0, asr: 0 },
    { day: "2026-06-18", dictations: 200, pastes: 200, asr: 200 },
    { day: "2026-06-17", dictations: 210, pastes: 210, asr: 210 },
  ];
  const ev = evaluateVolume(days, "2026-06-19");
  assert.equal(ev.state, "alerting");
  assert.equal(ev.zeroAlert, true);
});

test("volume: T-1 ABSENT (blackout) on active baseline -> alert (the Codex P1 fix)", () => {
  // The grouped query emits no row for a zero-event day; T-1 must still read 0.
  const days = [
    { day: "2026-06-18", dictations: 200, pastes: 200, asr: 200 },
    { day: "2026-06-17", dictations: 210, pastes: 210, asr: 210 },
  ];
  const ev = evaluateVolume(days, "2026-06-19"); // 2026-06-19 not in days
  assert.equal(ev.state, "alerting");
  assert.equal(ev.zeroAlert, true);
  assert.equal(ev.t1d, 0);
});

test("volume: genuinely quiet period (zero with low baseline) -> no alert", () => {
  const days = [
    { day: "2026-06-19", dictations: 0, pastes: 0, asr: 0 },
    { day: "2026-06-18", dictations: 5, pastes: 5, asr: 5 },
    { day: "2026-06-17", dictations: 3, pastes: 3, asr: 3 },
  ];
  assert.equal(evaluateVolume(days, "2026-06-19").state, "evaluated-ok");
});

test("volume: weekend dip below trailing avg does NOT false-fire", () => {
  // T-1 is a quiet Sunday far below the weekday-heavy average; must stay ok.
  const days = [
    { day: "2026-06-21", dictations: 40, pastes: 40, asr: 40 }, // Sunday
    { day: "2026-06-20", dictations: 300, pastes: 300, asr: 300 },
    { day: "2026-06-19", dictations: 320, pastes: 320, asr: 320 },
    { day: "2026-06-18", dictations: 300, pastes: 300, asr: 300 },
  ];
  assert.equal(evaluateVolume(days, "2026-06-21").state, "evaluated-ok");
});

test("volume: asr blackout (schema drift) -> alert", () => {
  // asr.completed co-fires UNCONDITIONALLY on success, so asr==0 with dictations
  // present is a genuine co-fire vanish (the only drift leg, #1130).
  const days = [
    { day: "2026-06-19", dictations: 200, pastes: 200, asr: 0 }, // asr event vanished
    { day: "2026-06-18", dictations: 200, pastes: 200, asr: 200 },
  ];
  const ev = evaluateVolume(days, "2026-06-19");
  assert.equal(ev.state, "alerting");
  assert.equal(ev.driftAlert, true);
  assert.equal(ev.asrDrift, true);
});

test("volume: paste-only blackout does NOT alert (copy-only ambiguity, #1130)", () => {
  // paste.completed is conditional (auto-paste only); pastes==0 is ambiguous
  // (copy-only vs broken), so it must NOT fire a drift alert even on an active day.
  const days = [
    { day: "2026-06-19", dictations: 200, pastes: 0, asr: 200 },
    { day: "2026-06-18", dictations: 200, pastes: 200, asr: 200 },
  ];
  const ev = evaluateVolume(days, "2026-06-19");
  assert.equal(ev.state, "evaluated-ok");
  assert.equal(ev.driftAlert, false);
});

test("volume: copy-only quiet day does NOT alert (#1130)", () => {
  const days = [
    { day: "2026-06-19", dictations: 8, pastes: 0, asr: 8 },
    { day: "2026-06-18", dictations: 6, pastes: 0, asr: 6 },
  ];
  const ev = evaluateVolume(days, "2026-06-19");
  assert.equal(ev.state, "evaluated-ok");
  assert.equal(ev.driftAlert, false);
});

test("volume: copy-only ACTIVE day does NOT alert (#1130)", () => {
  // The false-positive class the old (pastes==0) leg hit: a clearly active day
  // whose users are all copy-only. Must stay quiet now.
  const days = [
    { day: "2026-06-19", dictations: 50, pastes: 0, asr: 50 },
    { day: "2026-06-18", dictations: 200, pastes: 200, asr: 200 },
  ];
  const ev = evaluateVolume(days, "2026-06-19");
  assert.equal(ev.state, "evaluated-ok");
  assert.equal(ev.driftAlert, false);
});

// ---- message ----
function results(over = {}) {
  return Object.assign(
    {
      latency: { state: "evaluated-ok", latest: { p50: 1.5, p95: 4.9 }, last2: [], driftMedian: 1.4 },
      paste: { state: "evaluated-ok" },
      afm: { state: "dark-awaiting-release" },
      transcription: { state: "evaluated-ok" },
      volume: { state: "evaluated-ok", t1d: 312, avg: 280, ratio: 1.11 },
    },
    over
  );
}

test("message: clean day posts a heartbeat only, no alert block", () => {
  const msg = buildMessage(results());
  assert.match(msg, /health - OK/);
  assert.match(msg, /312 dictations/);
  assert.match(msg, /Dark: AFM-discard/);
  assert.ok(!msg.includes("\n\n*"), "no alert block on a clean day");
});

test("message: a crossing produces an ALERT header + block + dashboard link", () => {
  const msg = buildMessage(
    results({ paste: { state: "alerting", share: 0.065, fb: 17, cb: 7, ax: 10, total: 260 } }),
    [{ ver: "v2.1.4", paste_fb: 12, trans_fail: 0, afm_disc: 0 }]
  );
  assert.match(msg, /health - ALERT/);
  assert.match(msg, /paste fallback 6\.5%/);
  assert.match(msg, /ax_denied 10, direct-paste-failed 7/);
  assert.match(msg, /v2\.1\.4: 12/);
  assert.match(msg, /dashboard/);
});

test("message: drift alert names asr.completed, not paste/asr (#1130)", () => {
  const msg = buildMessage(
    results({
      volume: { state: "alerting", t1d: 200, avg: 200, ratio: 1.0, zeroAlert: false, driftAlert: true, asrDrift: true },
    })
  );
  assert.match(msg, /health - ALERT/);
  assert.match(msg, /asr\.completed was 0/);
  assert.ok(!msg.includes("paste/asr"), "drift wording must not reference the dropped paste leg");
});

test("message: stays within Discord 2000-char cap", () => {
  const msg = buildMessage(
    results({
      latency: { state: "alerting", latest: { p50: 3.0, p95: 10 }, last2: [1, 2], driftMedian: 1.4 },
      paste: { state: "alerting", share: 0.07, fb: 20, cb: 10, ax: 10, total: 285 },
      transcription: { state: "alerting", share: 0.06, fails: 90, denom: 1500 },
      volume: { state: "alerting", t1d: 0, avg: 200, ratio: 0, zeroAlert: true, driftAlert: false },
    })
  );
  assert.ok(msg.length <= 2000);
});

// ---- Phase 10 (#1179): onboarding abandon ----
test("onboarding abandon: low volume -> skipped", () => {
  const rows = [{ day: "2026-07-14", started: 10, abandoned: 2 }];
  assert.equal(evaluateOnboardingAbandon(rows, "2026-07-15").state, "skipped-low-volume");
});

test("onboarding abandon: normal -> ok", () => {
  const rows = [
    { day: "2026-07-15", started: 50, abandoned: 15 },
    { day: "2026-07-14", started: 50, abandoned: 15 },
  ];
  assert.equal(evaluateOnboardingAbandon(rows, "2026-07-15").state, "evaluated-ok");
});

test("onboarding abandon: rolling regression only (recent 2 days healthy, older days bad) -> alert", () => {
  const rows = [
    { day: "2026-07-15", started: 5, abandoned: 4 },
    { day: "2026-07-14", started: 5, abandoned: 4 },
    { day: "2026-07-01", started: 30, abandoned: 17 },
  ];
  const ev = evaluateOnboardingAbandon(rows, "2026-07-15");
  assert.equal(ev.state, "alerting");
  assert.equal(ev.fastCrossing, false);
});

test("onboarding abandon: fast regression only, healthy rolling average -> alert via fastCrossing", () => {
  const rows = [
    { day: "2026-07-15", started: 10, abandoned: 6 },
    { day: "2026-07-14", started: 10, abandoned: 6 },
    { day: "2026-07-01", started: 200, abandoned: 20 },
  ];
  const ev = evaluateOnboardingAbandon(rows, "2026-07-15");
  assert.equal(ev.state, "alerting");
  assert.equal(ev.fastCrossing, true);
  assert.ok(ev.rollingShare < THRESHOLDS.onboardingAbandon.share, "rolling share must stay healthy");
  assert.equal(ev.fastStarted, 20);
  assert.equal(ev.fastAbandoned, 12);
  assert.equal(ev.fastShare, 0.6, "fast-window share must reflect only the crossing window, not the rolling total");
});

test("onboarding abandon: screen-attribution drift (real raw volume, zero passes the filter) -> alert", () => {
  const rows = [{ day: "2026-07-15", started: 100, abandoned: 0, abandonedRaw: 40 }];
  const ev = evaluateOnboardingAbandon(rows, "2026-07-15");
  assert.equal(ev.state, "alerting");
  assert.equal(ev.attributionDrift, true);
  assert.equal(ev.totalAbandonedRaw, 40);
});

test("onboarding abandon: low but real raw abandon volume with zero filtered does NOT trip drift (below floor)", () => {
  const rows = [{ day: "2026-07-15", started: 100, abandoned: 0, abandonedRaw: 5 }];
  const ev = evaluateOnboardingAbandon(rows, "2026-07-15");
  assert.notEqual(ev.attributionDrift, true);
});

// ---- Phase 10 (#1179): onboarding blackout ----
function baselineDays(startedPerDay) {
  return ["2026-07-13", "2026-07-12", "2026-07-11", "2026-07-10", "2026-07-09", "2026-07-08", "2026-07-07"].map(
    (day) => ({ day, started: startedPerDay, completed: Math.max(0, startedPerDay - 2), abandoned: 1 })
  );
}

test("onboarding blackout (a): entry point down (active baseline) -> flagged", () => {
  const rows = baselineDays(10); // avg 10 >= activeBaselineAvg(8), T-1/T-2 absent -> recentStarted 0
  const ev = evaluateOnboardingBlackout(rows, "2026-07-15");
  assert.equal(ev.state, "alerting");
  assert.equal(ev.entryPointDown, true);
  assert.equal(ev.terminalDrift, false);
});

test("onboarding blackout (a): inactive baseline -> not flagged", () => {
  const rows = baselineDays(5); // avg 5 < activeBaselineAvg(8)
  const ev = evaluateOnboardingBlackout(rows, "2026-07-15");
  assert.equal(ev.state, "evaluated-ok");
  assert.equal(ev.entryPointDown, false);
});

test("onboarding blackout (b): healthy sessions, zero abandons -> not flagged", () => {
  const rows = [
    { day: "2026-07-15", started: 10, completed: 10, abandoned: 0 },
    { day: "2026-07-14", started: 10, completed: 10, abandoned: 0 },
  ];
  const ev = evaluateOnboardingBlackout(rows, "2026-07-15");
  assert.equal(ev.state, "evaluated-ok");
  assert.equal(ev.terminalDrift, false);
});

test("onboarding blackout (b): terminal drift (starts continue, no terminal fires) -> flagged", () => {
  const rows = [{ day: "2026-07-15", started: 10, completed: 0, abandoned: 0 }];
  const ev = evaluateOnboardingBlackout(rows, "2026-07-15");
  assert.equal(ev.state, "alerting");
  assert.equal(ev.terminalDrift, true);
  assert.equal(ev.entryPointDown, false);
});

test("onboarding blackout (b): insufficient recent activity -> not flagged", () => {
  const rows = [{ day: "2026-07-15", started: 5, completed: 0, abandoned: 0 }];
  const ev = evaluateOnboardingBlackout(rows, "2026-07-15");
  assert.equal(ev.state, "evaluated-ok");
  assert.equal(ev.terminalDrift, false);
});

// ---- Phase 10 (#1179): per-backend transcription ----
test("backend transcription: Parakeet low volume -> skipped", () => {
  const perBackendDays = { parakeet: [{ day: "2026-07-15", dictations: 50, fails: 5 }] };
  const [ev] = evaluateBackendTranscription(perBackendDays, "2026-07-15");
  assert.equal(ev.backend, "parakeet");
  assert.equal(ev.state, "skipped-low-volume");
});

test("backend transcription: catastrophic all-failure fast window -> alert, not suppressed as low volume", () => {
  const perBackendDays = {
    parakeet: [
      { day: "2026-07-15", dictations: 0, fails: 25 },
      { day: "2026-07-14", dictations: 0, fails: 25 },
    ],
  };
  const [ev] = evaluateBackendTranscription(perBackendDays, "2026-07-15");
  assert.equal(ev.state, "alerting");
  assert.equal(ev.fastCrossing, true);
});

test("backend transcription: WhisperKit at its real-world volume -> correctly evaluated, not skipped", () => {
  const perBackendDays = {
    whisperkit: [
      { day: "2026-07-15", dictations: 35, fails: 2 },
      { day: "2026-07-14", dictations: 35, fails: 2 },
      { day: "2026-06-20", dictations: 400, fails: 20 },
    ],
  };
  const [ev] = evaluateBackendTranscription(perBackendDays, "2026-07-15");
  assert.equal(ev.state, "evaluated-ok");
});

test("backend transcription: one backend regresses, the other doesn't", () => {
  const perBackendDays = {
    parakeet: [{ day: "2026-07-15", dictations: 300, fails: 5 }],
    whisperkit: [{ day: "2026-07-15", dictations: 250, fails: 150 }],
  };
  const evs = evaluateBackendTranscription(perBackendDays, "2026-07-15");
  const parakeet = evs.find((e) => e.backend === "parakeet");
  const whisperkit = evs.find((e) => e.backend === "whisperkit");
  assert.equal(parakeet.state, "evaluated-ok");
  assert.equal(whisperkit.state, "alerting");
});

test("backend transcription: fast-path regression, backend-scoped", () => {
  const perBackendDays = {
    parakeet: [
      { day: "2026-07-15", dictations: 10, fails: 15 },
      { day: "2026-07-14", dictations: 10, fails: 15 },
    ],
  };
  const [ev] = evaluateBackendTranscription(perBackendDays, "2026-07-15");
  assert.equal(ev.state, "alerting");
  assert.equal(ev.fastCrossing, true);
  assert.equal(ev.fastAttempts, 50);
  assert.equal(ev.fastFails, 30);
  assert.equal(ev.fastShare, 0.6, "fast-window share must reflect only the crossing window, not the rolling total");
});

test("backend transcription: anti-masking, active backend with zero failures stays visible", () => {
  const perBackendDays = { onlybackend: [{ day: "2026-07-15", dictations: 250, fails: 0 }] };
  const evs = evaluateBackendTranscription(perBackendDays, "2026-07-15");
  assert.equal(evs.length, 1);
  assert.equal(evs[0].backend, "onlybackend");
  assert.equal(evs[0].state, "evaluated-ok");
  assert.equal(evs[0].fails, 0);
});

test("backend transcription: attribution drift, unknown backend with material volume -> alert", () => {
  const perBackendDays = { unknown: [{ day: "2026-07-15", dictations: 250, fails: 20 }] };
  const [ev] = evaluateBackendTranscription(perBackendDays, "2026-07-15");
  assert.equal(ev.state, "alerting");
  assert.equal(ev.attributionDrift, true);
});

test("backend transcription: unknown backend with trivial volume does NOT trip drift (below minAttempts)", () => {
  const perBackendDays = { unknown: [{ day: "2026-07-15", dictations: 5, fails: 0 }] };
  const [ev] = evaluateBackendTranscription(perBackendDays, "2026-07-15");
  assert.notEqual(ev.attributionDrift, true);
});

// ---- message: Phase 10 additions ----
test("message: H1 static pointer appears every run", () => {
  const msg = buildMessage(results());
  assert.match(msg, /Sentry's own alert rules/);
  assert.match(msg, /Error Spike >5\/hr/);
});

test("message: onboarding-abandon alert renders and is not double-counted as evaluated", () => {
  const msg = buildMessage(
    results({
      onboardingAbandon: {
        state: "alerting", fastCrossing: true, fastStarted: 10, fastAbandoned: 6, fastShare: 0.6,
        rollingShare: 0.145, totalStarted: 220, totalAbandoned: 32,
      },
    })
  );
  assert.match(msg, /onboarding abandon 60\.0%/);
  assert.ok(!msg.includes("Evaluated: onboarding-abandon"));
});

test("message: onboarding-abandon fast crossing does not report the healthy rolling rate", () => {
  const msg = buildMessage(
    results({
      onboardingAbandon: {
        state: "alerting", fastCrossing: true, fastStarted: 10, fastAbandoned: 6, fastShare: 0.6,
        rollingShare: 0.145, totalStarted: 220, totalAbandoned: 32,
      },
    })
  );
  assert.match(msg, /fast 2-day crossing/);
  assert.ok(!msg.includes("14.5%"), "must not display the healthy rolling share when the fast path fired");
});

test("message: onboarding-abandon rolling crossing reports the rolling window", () => {
  const msg = buildMessage(
    results({
      onboardingAbandon: { state: "alerting", fastCrossing: false, rollingShare: 0.6, totalStarted: 40, totalAbandoned: 24 },
    })
  );
  assert.match(msg, /rolling crossing/);
  assert.match(msg, /60\.0%/);
});

test("message: per-backend transcription alerts name the backend and skip clean backends", () => {
  const msg = buildMessage(
    results({
      backendTranscription: [
        { backend: "parakeet", state: "evaluated-ok", rollingShare: 0.02, fastCrossing: false, fails: 5, dictations: 300, attempts: 305 },
        { backend: "whisperkit", state: "alerting", rollingShare: 0.3, fastCrossing: false, fails: 60, dictations: 140, attempts: 200 },
      ],
    })
  );
  assert.match(msg, /whisperkit transcription failure 30\.0%/);
  assert.ok(!msg.includes("parakeet transcription failure"));
  assert.match(msg, /Evaluated:.*transcription-parakeet/);
});

test("message: onboarding-blackout entry-point-down and terminal-drift render distinct wording", () => {
  const entryDown = buildMessage(
    results({ onboardingBlackout: { state: "alerting", entryPointDown: true, terminalDrift: false, recentStarted: 0, recentTerminals: 0, baselineAvg: 12 } })
  );
  assert.match(entryDown, /onboarding entry point down/);

  const terminalDrift = buildMessage(
    results({ onboardingBlackout: { state: "alerting", entryPointDown: false, terminalDrift: true, recentStarted: 10, recentTerminals: 0, baselineAvg: 12 } })
  );
  assert.match(terminalDrift, /onboarding terminal drift/);
  assert.ok(!terminalDrift.includes("entry point down"));
});

test("message: many simultaneous alerts drop whole alerts from the end, never the dashboard link", () => {
  // Manufacture enough alerting metrics that the naive character slice would
  // have cut mid-alert (Codex review finding) — assert the dashboard link and
  // heartbeat always survive, and any drop is announced, never silent.
  const longVersion = "v9.9.9-a-very-long-version-identifier-to-pad-the-message-length-out";
  const backendTranscription = Array.from({ length: 20 }, (_, i) => ({
    backend: `backend-${i}-${longVersion}`,
    state: "alerting",
    fastCrossing: false,
    rollingShare: 0.5,
    fails: 500,
    dictations: 500,
    attempts: 1000,
  }));
  const msg = buildMessage(results({ backendTranscription }));
  assert.ok(msg.length <= 2000, `message must respect the Discord cap, got ${msg.length}`);
  assert.match(msg, /https:\/\/us\.posthog\.com\/project\/\d+\/dashboard\/\d+/, "dashboard link must always survive truncation");
  if (msg.includes("more alert(s) omitted")) {
    assert.match(msg, /\d+ more alert\(s\) omitted; see dashboard/);
  }
});

test("message: onboarding screen-attribution drift renders distinct wording, no version attribution", () => {
  const msg = buildMessage(
    results({
      onboardingAbandon: { state: "alerting", attributionDrift: true, fastCrossing: false, totalStarted: 100, totalAbandoned: 0, totalAbandonedRaw: 40 },
    }),
    [], [{ ver: "v2.1.4", onboarding_abandon: 40 }]
  );
  assert.match(msg, /onboarding abandon attribution lost/);
  assert.ok(!msg.includes("v2.1.4"), "attribution-drift alert must not attach version data to a broken denominator");
});

test("message: backend attribution drift (unknown backend) renders distinct wording", () => {
  const msg = buildMessage(
    results({
      backendTranscription: [
        { backend: "unknown", state: "alerting", attributionDrift: true, fastCrossing: false, fails: 20, dictations: 250, attempts: 270 },
      ],
    })
  );
  assert.match(msg, /transcription backend attribution lost/);
});

test("message: backend attribution blackout (empty result set) renders and alerts", () => {
  const msg = buildMessage(results({ backendTranscription: [], backendAttributionBlackout: true }));
  assert.match(msg, /transcription backend attribution blackout/);
  assert.match(msg, /health - ALERT/);
});

test("message: fast-crossing alerts omit version attribution (window mismatch, Codex review finding)", () => {
  const onboardingMsg = buildMessage(
    results({ onboardingAbandon: { state: "alerting", fastCrossing: true, fastStarted: 10, fastAbandoned: 6, fastShare: 0.6, rollingShare: 0.1, totalStarted: 300, totalAbandoned: 30 } }),
    [], [{ ver: "v2.1.4", onboarding_abandon: 40 }]
  );
  assert.ok(!onboardingMsg.includes("v2.1.4"), "a fast (2-day) crossing must not attribute to a 21-day version query");

  const backendMsg = buildMessage(
    results({
      backendTranscription: [
        { backend: "parakeet", state: "alerting", fastCrossing: true, fastFails: 20, fastDictations: 10, fastAttempts: 30, fastShare: 0.67, rollingShare: 0.05, fails: 50, dictations: 950, attempts: 1000 },
      ],
    }),
    [], [], [{ ver: "v2.1.4", backend: "parakeet", backend_trans_fail: 40 }]
  );
  assert.ok(!backendMsg.includes("v2.1.4"), "a fast (2-day) crossing must not attribute to a 14-day version query");
});
