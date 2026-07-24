// Unit tests for the pure threshold/state logic (no network) plus the
// reliability machinery (issue #1589: concurrency cap, retry, resolve-once
// dev exclusion, fail-soft degrade, evaluateHealthData, plain-English copy).
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
  evaluateHealthData,
  buildMessage,
  hogql,
  runLimited,
  fetchHealth,
  runHealth,
  resolveDevIds,
  productionClauseFor,
  PostHogQueryError,
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

// ---- AFM data availability ----
test("AFM: zero eligible fallback-reason rows -> dark", () => {
  const row = { afm_fr_rows: 0, afm_disc: 0 };
  assert.equal(evaluateAFM(row).state, "dark-awaiting-release");
});

test("AFM: too few eligible fallback-reason rows -> skipped (not 0%)", () => {
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
      versions: [],
      onboardingVersions: [],
      backendVersions: [],
      versionsDegraded: false,
      onboardingVersionsDegraded: false,
      backendVersionsDegraded: false,
      backendTranscriptionUnavailable: false,
      backendAttributionBlackoutUnavailable: false,
    },
    over
  );
}

test("message: clean day posts a heartbeat only, no alert block", () => {
  const msg = buildMessage(results());
  assert.match(msg, /everything looks normal/);
  assert.match(msg, /312 dictations were completed yesterday/);
  assert.match(msg, /Waiting for enough eligible data: Apple on-device polishing quality/);
  assert.ok(!msg.includes("\n\n*"), "no alert block on a clean day");
});

test("message: a crossing produces a found-N-things header + alert block + dashboard link", () => {
  const msg = buildMessage(
    results({
      paste: { state: "alerting", share: 0.065, fb: 17, cb: 7, ax: 10, total: 260 },
      versions: [{ ver: "v2.1.4", paste_fb: 12, trans_fail: 0, afm_disc: 0 }],
    })
  );
  assert.match(msg, /found 1 thing worth a look/);
  assert.match(msg, /Auto-paste is failing more than usual: 6\.5%/);
  assert.match(msg, /10 were caused by a missing permission; 7 failed another way/);
  assert.match(msg, /v2\.1\.4 \(12\)/);
  assert.match(msg, /Full data: https:\/\/us\.posthog\.com/);
});

test("message: drift alert renders the tracking-broken wording, not the zero-dictations wording (#1130)", () => {
  const msg = buildMessage(
    results({
      volume: { state: "alerting", t1d: 200, avg: 200, ratio: 1.0, zeroAlert: false, driftAlert: true, asrDrift: true },
    })
  );
  assert.match(msg, /found 1 thing worth a look/);
  assert.match(msg, /a signal that should fire every time did not fire once/);
  assert.ok(
    !msg.includes("even though a typical day sees about"),
    "drift wording must not also render the zero-dictations wording"
  );
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

test("onboarding abandon: screen-attribution drift (missing-screen volume crosses floor) -> alert", () => {
  const rows = [
    { day: "2026-07-15", started: 100, abandoned: 0, abandonedRaw: 40, abandonedMissingScreen: 40 },
  ];
  const ev = evaluateOnboardingAbandon(rows, "2026-07-15");
  assert.equal(ev.state, "alerting");
  assert.equal(ev.attributionDrift, true);
  assert.equal(ev.totalAbandonedRaw, 40);
  assert.equal(ev.totalAbandonedMissingScreen, 40);
});

test("onboarding abandon: low but real missing-screen volume does NOT trip drift (below floor)", () => {
  const rows = [
    { day: "2026-07-15", started: 100, abandoned: 0, abandonedRaw: 5, abandonedMissingScreen: 5 },
  ];
  const ev = evaluateOnboardingAbandon(rows, "2026-07-15");
  assert.notEqual(ev.attributionDrift, true);
});

test("onboarding abandon: legitimate all-welcome concentration does NOT trip drift (Codex r4 false-positive fix)", () => {
  // Real raw volume, zero passes the "not welcome" filter, but every one of
  // those events genuinely carries screen = 'welcome' (abandonedMissingScreen
  // stays 0) — healthy, correctly-tagged data, not schema drift.
  const rows = [
    { day: "2026-07-15", started: 100, abandoned: 0, abandonedRaw: 40, abandonedMissingScreen: 0 },
  ];
  const ev = evaluateOnboardingAbandon(rows, "2026-07-15");
  assert.notEqual(ev.attributionDrift, true);
  assert.equal(ev.state, "evaluated-ok");
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
  const rows = [{ day: "2026-07-15", started: 10, completed: 0, abandoned: 0, abandonedRaw: 0 }];
  const ev = evaluateOnboardingBlackout(rows, "2026-07-15");
  assert.equal(ev.state, "alerting");
  assert.equal(ev.terminalDrift, true);
  assert.equal(ev.entryPointDown, false);
});

test("onboarding blackout (b): screen-attribution drift does NOT falsely present as terminal drift (Codex r6 fix)", () => {
  // Real abandon events fired (abandonedRaw) but properties.screen dropped,
  // so the welcome-filtered `abandoned` reads 0 — a terminal event DID fire,
  // this must not read as "terminal events stopped firing."
  const rows = [{ day: "2026-07-15", started: 10, completed: 0, abandoned: 0, abandonedRaw: 8 }];
  const ev = evaluateOnboardingBlackout(rows, "2026-07-15");
  assert.equal(ev.terminalDrift, false);
  assert.equal(ev.recentTerminals, 8);
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
test("message: crash-tracking disclaimer appears every run", () => {
  const msg = buildMessage(results());
  assert.match(msg, /Crashes and app errors are tracked separately and alert on their own/);
});

test("message: onboarding-abandon alert renders and is not double-counted as checked-and-normal", () => {
  const msg = buildMessage(
    results({
      onboardingAbandon: {
        state: "alerting", fastCrossing: true, fastStarted: 10, fastAbandoned: 6, fastShare: 0.6,
        rollingShare: 0.145, totalStarted: 220, totalAbandoned: 32,
      },
    })
  );
  assert.match(msg, /60\.0% of setup attempts ended before setup was finished \(6 of 10\)/);
  assert.ok(!/Checked and normal:[^\n]*onboarding completion/.test(msg));
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
  assert.match(msg, /In just the last 2 days/);
  assert.match(msg, /sudden change worth a look/);
  assert.ok(!msg.includes("14.5%"), "must not display the healthy rolling share when the fast path fired");
});

test("message: onboarding-abandon rolling crossing reports the rolling window", () => {
  const msg = buildMessage(
    results({
      onboardingAbandon: { state: "alerting", fastCrossing: false, rollingShare: 0.6, totalStarted: 40, totalAbandoned: 24 },
    })
  );
  assert.match(msg, /Of the setup attempts started over the last three weeks/);
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
  assert.match(msg, /WhisperKit speech-to-text is failing more than usual: 30\.0%/);
  assert.ok(!msg.includes("Parakeet speech-to-text is failing"));
  assert.match(msg, /Checked and normal:[^\n]*Parakeet speech-to-text/);
});

test("message: empty per-backend result during genuine low volume reports skipped, not silence (Codex r5 fix)", () => {
  const msg = buildMessage(
    results({ backendTranscription: [], backendAttributionBlackout: false })
  );
  assert.match(msg, /Not enough activity to judge:[^\n]*speech-to-text reliability by engine/);
  assert.ok(!msg.includes("We can no longer tell which speech engine"));
});

test("message: backend-transcription and blackout unavailable together render as unavailable, not alerts", () => {
  const msg = buildMessage(
    results({ backendTranscriptionUnavailable: true, backendAttributionBlackoutUnavailable: true })
  );
  assert.match(msg, /Temporarily unavailable:[^\n]*speech-to-text reliability by engine/);
  assert.match(msg, /Temporarily unavailable:[^\n]*speech-engine tracking/);
  // Codex diff review finding: a degraded-but-not-alerting run must NOT claim
  // "everything looks normal" - that would falsely reassure a founder
  // skimming only the headline while two checks silently couldn't run.
  assert.match(msg, /no problems found, but 2 checks couldn't run today/);
  assert.ok(!msg.includes("everything looks normal"));
});

test("message: a single unavailable check uses singular grammar in the headline", () => {
  const msg = buildMessage(results({ afm: { state: "temporarily-unavailable" } }));
  assert.match(msg, /no problems found, but 1 check couldn't run today/);
});

test("message: onboarding-blackout entry-point-down and terminal-drift render distinct wording", () => {
  const entryDown = buildMessage(
    results({ onboardingBlackout: { state: "alerting", entryPointDown: true, terminalDrift: false, recentStarted: 0, recentTerminals: 0, baselineAvg: 12 } })
  );
  assert.match(entryDown, /There were no setup starts in the last 2 days/);

  const terminalDrift = buildMessage(
    results({ onboardingBlackout: { state: "alerting", entryPointDown: false, terminalDrift: true, recentStarted: 10, recentTerminals: 0, baselineAvg: 12 } })
  );
  assert.match(terminalDrift, /but none registered as either finishing or giving up/);
  assert.ok(!terminalDrift.includes("no setup starts"));
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
    assert.match(msg, /\d+ more alert\(s\) omitted; see full data below\./);
  }
});

test("message: onboarding screen-attribution drift renders distinct wording, no version attribution", () => {
  const msg = buildMessage(
    results({
      onboardingAbandon: { state: "alerting", attributionDrift: true, fastCrossing: false, totalStarted: 100, totalAbandoned: 0, totalAbandonedRaw: 40, totalAbandonedMissingScreen: 40 },
      onboardingVersions: [{ ver: "v2.1.4", onboarding_abandon: 40 }],
    })
  );
  assert.match(msg, /We lost the ability to tell where setup was abandoned/);
  assert.match(msg, /40 of 40 abandon events/);
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
  assert.match(msg, /We lost track of which speech engine, Parakeet or WhisperKit, was used for 270/);
});

test("message: backend attribution blackout (empty result set) renders and alerts", () => {
  const msg = buildMessage(results({ backendTranscription: [], backendAttributionBlackout: true }));
  assert.match(msg, /We can no longer tell which speech engine people are using at all/);
  assert.match(msg, /found 1 thing worth a look/);
});

test("message: fast-crossing alerts omit version attribution (window mismatch, Codex review finding)", () => {
  const onboardingMsg = buildMessage(
    results({
      onboardingAbandon: { state: "alerting", fastCrossing: true, fastStarted: 10, fastAbandoned: 6, fastShare: 0.6, rollingShare: 0.1, totalStarted: 300, totalAbandoned: 30 },
      onboardingVersions: [{ ver: "v2.1.4", onboarding_abandon: 40 }],
    })
  );
  assert.ok(!onboardingMsg.includes("v2.1.4"), "a fast (2-day) crossing must not attribute to a 21-day version query");

  const backendMsg = buildMessage(
    results({
      backendTranscription: [
        { backend: "parakeet", state: "alerting", fastCrossing: true, fastFails: 20, fastDictations: 10, fastAttempts: 30, fastShare: 0.67, rollingShare: 0.05, fails: 50, dictations: 950, attempts: 1000 },
      ],
      backendVersions: [{ ver: "v2.1.4", backend: "parakeet", backend_trans_fail: 40 }],
    })
  );
  assert.ok(!backendMsg.includes("v2.1.4"), "a fast (2-day) crossing must not attribute to a 14-day version query");
});

test("message: a degraded version query preserves the core alert, only its top-versions clause changes", () => {
  const msg = buildMessage(
    results({
      paste: { state: "alerting", share: 0.065, fb: 17, cb: 7, ax: 10, total: 260 },
      versionsDegraded: true,
    })
  );
  assert.match(msg, /Auto-paste is failing more than usual: 6\.5%/, "the core alert must still fire normally");
  assert.match(msg, /We couldn't break this down by app version today\./);
});

// ---- runLimited (issue #1589 - PostHog's 3-concurrent-query project limit) ----
test("runLimited: never exceeds the given concurrency and preserves input order", async () => {
  let inFlight = 0;
  let maxInFlight = 0;
  const tasks = [1, 2, 3, 4, 5].map(
    (n) => () =>
      new Promise((resolve) => {
        inFlight += 1;
        maxInFlight = Math.max(maxInFlight, inFlight);
        // settle: fixed synthetic duration observed via the maxInFlight counter, not a wall-clock race
        setTimeout(() => {
          inFlight -= 1;
          resolve(n);
        }, 5);
      })
  );
  const out = await runLimited(tasks, 2);
  assert.deepEqual(out, [1, 2, 3, 4, 5]);
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

// ---- hogql retry (issue #1589, ported from workers/daily-report #1588/#1720) ----
function fakeResponse(status, body, { onCancel } = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    body: onCancel ? { cancel: async () => onCancel() } : undefined,
  };
}

const TEST_ENV = { POSTHOG_PROJECT_ID: "x", POSTHOG_PERSONAL_API_KEY: "k" };

test("hogql: retries on 504, waits within the attempt-2 backoff range, then succeeds", async () => {
  let calls = 0;
  const fetchFn = async () => {
    calls += 1;
    return calls === 1 ? fakeResponse(504) : fakeResponse(200, { results: [[1]] });
  };
  const sleeps = [];
  const sleepFn = async (ms) => sleeps.push(ms);
  const json = await hogql(TEST_ENV, "SELECT 1", "test_query", {
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
  const json = await hogql(TEST_ENV, "SELECT 1", "test_query", { fetchFn, sleepFn: async () => {}, randomFn: () => 0 });
  assert.deepEqual(json.results, [[1]]);
  assert.equal(calls, 2);
});

test("hogql: cancels the failed response body before retrying", async () => {
  let cancelled = false;
  let calls = 0;
  const fetchFn = async () => {
    calls += 1;
    if (calls === 1) return fakeResponse(504, undefined, { onCancel: () => (cancelled = true) });
    return fakeResponse(200, { results: [[1]] });
  };
  await hogql(TEST_ENV, "SELECT 1", "test_query", { fetchFn, sleepFn: async () => {}, randomFn: () => 0 });
  assert.equal(cancelled, true);
});

test("hogql: does not retry on a non-transient 4xx status", async () => {
  let calls = 0;
  const fetchFn = async () => {
    calls += 1;
    return fakeResponse(401);
  };
  await assert.rejects(
    () => hogql(TEST_ENV, "SELECT 1", "test_query", { fetchFn, sleepFn: async () => {}, randomFn: () => 0 }),
    (err) => err instanceof PostHogQueryError && err.status === 401
  );
  assert.equal(calls, 1, "a non-retryable status must not be retried");
});

test("hogql: throws with the query name after exhausting all 3 attempts on repeated 504", async () => {
  let calls = 0;
  const fetchFn = async () => {
    calls += 1;
    return fakeResponse(504);
  };
  await assert.rejects(
    () => hogql(TEST_ENV, "SELECT 1", "test_query", { fetchFn, sleepFn: async () => {}, randomFn: () => 0 }),
    (err) => {
      assert.ok(err instanceof PostHogQueryError);
      assert.equal(err.queryName, "test_query");
      assert.equal(err.status, 504);
      return true;
    }
  );
  assert.equal(calls, 3);
});

// ---- resolveDevIds / productionClauseFor (issue #1589, ported from daily-report #1720) ----
test("resolveDevIds: accepts hogqlOpts so its own retry path is test-deterministic", async () => {
  let calls = 0;
  const fetchFn = async () => {
    calls += 1;
    return calls === 1 ? fakeResponse(504) : fakeResponse(200, { results: [["dev-1"]] });
  };
  const ids = await resolveDevIds(TEST_ENV, { fetchFn, sleepFn: async () => {}, randomFn: () => 0 });
  assert.deepEqual(ids, ["dev-1"]);
  assert.equal(calls, 2);
});

test("resolveDevIds: throws on overflow rather than silently building a truncated exclusion list", async () => {
  const manyIds = Array.from({ length: 5001 }, (_, i) => [`dev-${i}`]);
  const fetchFn = async () => fakeResponse(200, { results: manyIds });
  await assert.rejects(() => resolveDevIds(TEST_ENV, { fetchFn }), /dev-id completeness check failed/);
});

test("resolveDevIds: an empty result is a valid, non-throwing state", async () => {
  const fetchFn = async () => fakeResponse(200, { results: [] });
  const ids = await resolveDevIds(TEST_ENV, { fetchFn });
  assert.deepEqual(ids, []);
});

test("productionClauseFor: empty dev-id list uses the bare environment filter, never NOT IN ()", () => {
  const clause = productionClauseFor([]);
  assert.doesNotMatch(clause, /NOT IN/);
  assert.match(clause, /properties\.environment = 'production'/);
});

test("productionClauseFor: non-empty list appends a literal NOT IN exclusion", () => {
  const clause = productionClauseFor(["dev-1", "dev-2"]);
  assert.match(clause, /NOT IN \('dev-1', 'dev-2'\)/);
});

// ---- fetchHealth: fail-loud vs degradable queries (issue #1589) ----
//
// These MUST drive fetchHealth, not hogql in isolation - the dependency-
// graph-aware degrade wiring these guard lives in fetchHealth's own
// construction of the return object. fetchHealth calls hogql without an
// injectable fetchFn of its own, so the mock installs on globalThis.fetch
// and dispatches on the query name the worker puts in the request body.

const DEFAULT_QUERY_RESPONSES = {
  ref: { results: [["2026-07-17"]], columns: ["t1"] },
  dev_ids: { results: [], columns: ["distinct_id"] },
  latency: { results: [], columns: ["day", "n", "p50", "p95"] },
  seven_day: {
    results: [[0, 0, 0, 0, 0, 0, 0]],
    columns: ["paste_total", "paste_cb", "paste_ax", "afm_fr_rows", "afm_disc", "trans_fails", "dictations_7d"],
  },
  volume: { results: [], columns: ["day", "dictations", "pastes", "asr"] },
  versions: { results: [], columns: ["ver", "paste_fb", "trans_fail", "afm_disc"] },
  onboarding: { results: [], columns: ["day", "started", "completed", "abandoned", "abandonedRaw", "abandonedMissingScreen"] },
  backend_transcription: { results: [], columns: ["day", "backend", "dictations", "fails"] },
  onboarding_versions: { results: [], columns: ["ver", "onboarding_abandon"] },
  backend_versions: { results: [], columns: ["ver", "backend", "backend_trans_fail"] },
};

/** Installs a global fetch that lets every query succeed with a minimal
 * valid shape and lets the caller decide what one named query does. Also
 * transparently succeeds any non-PostHog call (the Discord webhook POST
 * runHealth makes - its body is `{content}`, with no `.name` field, unlike
 * every hogql() request body) so tests can drive runHealth end-to-end, not
 * just fetchHealth. Returns a restore fn and any Discord post bodies
 * captured. */
function mockPostHog({ failQuery, failWith }) {
  const realFetch = globalThis.fetch;
  const discordPosts = [];
  globalThis.fetch = async (_url, init) => {
    const body = init?.body ? JSON.parse(init.body) : {};
    if (!body.name) {
      if (typeof body.content === "string") discordPosts.push(body.content);
      return fakeResponse(204); // Discord webhook success shape, not a PostHog call
    }
    const queryName = body.name.replace(/^product_health_/, "");
    if (queryName === failQuery) {
      if (failWith instanceof Error) throw failWith;
      return fakeResponse(failWith);
    }
    const shape = DEFAULT_QUERY_RESPONSES[queryName] || { results: [], columns: [] };
    return fakeResponse(200, shape);
  };
  return { restore: () => (globalThis.fetch = realFetch), discordPosts };
}

for (const queryName of ["ref", "dev_ids", "volume"]) {
  test(`fetchHealth: ${queryName} exhausting retries fails the whole run (fail-loud)`, async () => {
    const mock = mockPostHog({ failQuery: queryName, failWith: 504 });
    try {
      await assert.rejects(
        () => fetchHealth(TEST_ENV, { sleepFn: async () => {} }),
        new RegExp(`PostHog query ${queryName} HTTP 504`)
      );
    } finally {
      mock.restore();
    }
  });
}

const DEGRADABLE_QUERY_FLAGS = {
  latency: "latencyDegraded",
  seven_day: "sevenDayDegraded",
  versions: "versionsDegraded",
  onboarding: "onboardingDegraded",
  backend_transcription: "backendTranscriptionDegraded",
  onboarding_versions: "onboardingVersionsDegraded",
  backend_versions: "backendVersionsDegraded",
};

for (const [queryName, flag] of Object.entries(DEGRADABLE_QUERY_FLAGS)) {
  test(`fetchHealth: ${queryName} exhausting retries degrades only its own flag (${flag})`, async () => {
    const mock = mockPostHog({ failQuery: queryName, failWith: 504 });
    try {
      const data = await fetchHealth(TEST_ENV, { sleepFn: async () => {} });
      assert.equal(data[flag], true, `expected ${flag} to be true`);
      for (const otherFlag of Object.values(DEGRADABLE_QUERY_FLAGS)) {
        if (otherFlag !== flag) assert.equal(data[otherFlag], false, `expected ${otherFlag} to stay false`);
      }
    } finally {
      mock.restore();
    }
  });

  test(`fetchHealth: ${queryName} a NON-retryable failure (401) still throws, no silent swallow`, async () => {
    const mock = mockPostHog({ failQuery: queryName, failWith: 401 });
    try {
      await assert.rejects(
        () => fetchHealth(TEST_ENV, { sleepFn: async () => {} }),
        (err) => err instanceof PostHogQueryError && err.status === 401
      );
    } finally {
      mock.restore();
    }
  });
}

test("fetchHealth: a clean run leaves every degrade flag false", async () => {
  const mock = mockPostHog({ failQuery: null });
  try {
    const data = await fetchHealth(TEST_ENV, { sleepFn: async () => {} });
    for (const flag of Object.values(DEGRADABLE_QUERY_FLAGS)) {
      assert.equal(data[flag], false, `expected ${flag} to be false on a clean run`);
    }
  } finally {
    mock.restore();
  }
});

// ---- evaluateHealthData (issue #1589): single owner of degrade-then-evaluate wiring ----
function healthData(over = {}) {
  return Object.assign(
    {
      latencyDays: [{ day: "2026-07-15", n: 200, p50: 1.5, p95: 4.9 }],
      latencyDegraded: false,
      seven: { paste_total: 1000, paste_cb: 9, paste_ax: 3, afm_fr_rows: 100, afm_disc: 10, trans_fails: 14, dictations_7d: 1500 },
      sevenDayDegraded: false,
      volumeDays: [{ day: "2026-07-15", dictations: 300, pastes: 300, asr: 300 }],
      versions: [],
      versionsDegraded: false,
      t1ref: "2026-07-15",
      onboardingDays: [{ day: "2026-07-15", started: 50, completed: 40, abandoned: 5, abandonedRaw: 5, abandonedMissingScreen: 0 }],
      onboardingDegraded: false,
      backendTranscriptionDays: { parakeet: [{ day: "2026-07-15", dictations: 300, fails: 5 }] },
      backendTranscriptionDegraded: false,
      onboardingVersions: [],
      onboardingVersionsDegraded: false,
      backendVersions: [],
      backendVersionsDegraded: false,
    },
    over
  );
}

test("evaluateHealthData: sevenDayDegraded disables paste+afm+transcription together and makes the blackout check uncheckable", () => {
  const r = evaluateHealthData(healthData({ sevenDayDegraded: true }));
  assert.equal(r.paste.state, "temporarily-unavailable");
  assert.equal(r.afm.state, "temporarily-unavailable");
  assert.equal(r.transcription.state, "temporarily-unavailable");
  assert.equal(r.backendAttributionBlackoutUnavailable, true);
  assert.equal(r.backendAttributionBlackout, false, "must never fabricate a blackout when it can't be checked");
  // Unrelated metrics stay real.
  assert.equal(r.latency.state, "evaluated-ok");
});

test("evaluateHealthData: onboardingDegraded disables both onboarding checks together", () => {
  const r = evaluateHealthData(healthData({ onboardingDegraded: true }));
  assert.equal(r.onboardingAbandon.state, "temporarily-unavailable");
  assert.equal(r.onboardingBlackout.state, "temporarily-unavailable");
});

test("evaluateHealthData: backendTranscriptionDegraded can never fabricate a blackout reading", () => {
  const r = evaluateHealthData(healthData({ backendTranscriptionDegraded: true }));
  assert.deepEqual(r.backendTranscription, []);
  assert.equal(r.backendTranscriptionUnavailable, true);
  assert.equal(r.backendAttributionBlackoutUnavailable, true);
  assert.equal(r.backendAttributionBlackout, false);
});

test("evaluateHealthData: latencyDegraded is independent of every other metric", () => {
  const r = evaluateHealthData(healthData({ latencyDegraded: true }));
  assert.equal(r.latency.state, "temporarily-unavailable");
  assert.equal(r.paste.state, "evaluated-ok");
  assert.equal(r.onboardingAbandon.state, "evaluated-ok");
});

test("evaluateHealthData: a clean run carries the version arrays through untouched", () => {
  const data = healthData({
    versions: [{ ver: "v2.1.4", paste_fb: 5 }],
    onboardingVersions: [{ ver: "v2.1.4", onboarding_abandon: 3 }],
    backendVersions: [{ ver: "v2.1.4", backend: "parakeet", backend_trans_fail: 1 }],
  });
  const r = evaluateHealthData(data);
  assert.deepEqual(r.versions, data.versions);
  assert.deepEqual(r.onboardingVersions, data.onboardingVersions);
  assert.deepEqual(r.backendVersions, data.backendVersions);
});

// ---- runHealth (issue #1589): plain failure notice, no claimed cause, no raw error text on Discord ----
test("runHealth: an exhausted retryable failure posts a plain notice with no technical detail, logs the detail instead, and rethrows", async () => {
  const mock = mockPostHog({ failQuery: "volume", failWith: 504 });
  const realConsoleLog = console.log;
  const logged = [];
  console.log = (...args) => logged.push(args.join(" "));
  try {
    await assert.rejects(
      () =>
        runHealth(
          { ...TEST_ENV, DISCORD_WEBHOOK_URL: "https://discord.example/webhook" },
          { hogqlOpts: { sleepFn: async () => {} } }
        ),
      /PostHog query volume HTTP 504/
    );
    assert.equal(mock.discordPosts.length, 1);
    assert.equal(mock.discordPosts[0], "EnviousWispr health check didn't run today.");
    assert.ok(
      !mock.discordPosts[0].includes("didn't respond in time"),
      "must not claim a specific cause for a failure class that also covers auth/malformed-response/overflow errors"
    );
    // Codex diff review finding: raw HTTP/query-name jargon must never reach
    // the founder-facing Discord post - it belongs only in the Cloudflare log.
    assert.ok(
      !/PostHog|HTTP \d/.test(mock.discordPosts[0]),
      "must not expose raw PostHog error text on Discord"
    );
    assert.ok(
      logged.some((line) => line.includes("PostHog query volume HTTP 504")),
      "the technical detail must still be logged for debugging, just not posted to Discord"
    );
  } finally {
    console.log = realConsoleLog;
    mock.restore();
  }
});

test("runHealth: a clean run calls evaluateHealthData exactly once and posts a real heartbeat", async () => {
  const mock = mockPostHog({ failQuery: null });
  let calls = 0;
  const spy = (data) => {
    calls += 1;
    return evaluateHealthData(data);
  };
  try {
    const message = await runHealth(
      { ...TEST_ENV, DISCORD_WEBHOOK_URL: "https://discord.example/webhook" },
      { evaluateHealthData: spy, hogqlOpts: { sleepFn: async () => {} } }
    );
    assert.equal(calls, 1);
    assert.match(message, /EnviousWispr health check for yesterday/);
  } finally {
    mock.restore();
  }
});
