# Issue #291 — V2 Fault-Injection Toolkit (Q2 Hardening) — 2026-04-30

GitHub issue: `#291`. Parent / epic: #319 Q2 Hardening. Tier: **LARGE**. Status: **READY FOR GATE 2 SIGN-OFF** (round 2 grounded review absorbed 2026-04-30).

> **Revision note.** This is the v3 plan, after two rounds of Codex grounded review (`docs/audits/2026-04-30-v2-grounded-review.txt` + `docs/audits/2026-04-30-v2-grounded-review-round2.txt`) + council from GPT 5.5 + Gemini 3.1 Pro. Round 1: 5 PIVOTs absorbed in v2. Round 2: 3 precision revisions absorbed in v3 (this version). Round 2 sign-off was YES_WITH_REVISIONS, all revisions applied. Direction is sound. Plan is implementable.

## Preface — Lane + Live UAT declaration

**Lane:** Mixed — Code (DEBUG seams in `Sources/`, Swift `@Test` cases in `Tests/EnviousWisprTests/`) + Docs/dev-tooling (`Tests/UITests/` harness extensions + scenario menu documentation).

**PR sequencing — corrected after GPT review.** Original split made PR-1's Live UAT depend on PR-2-only harness code. Two viable shapes:

- **Shape A (preferred): one bundled PR.** Code + harness in one merge. Lane discipline relaxed because the lanes are tightly co-dependent and splitting forces each PR to demonstrate things the other PR provides. Phase 3 validation runs both Code-lane (build + Swift tests + Live UAT) and Docs/dev-tooling-lane (Python lint + self-tests) artifacts in the same PR.
- **Shape B: two PRs only if PR-1 carries its own Live UAT path that does NOT need wispr_eyes.** PR-1 demonstrates DEBUG seams via a small Swift test that exercises the trigger path directly (no Python harness invocation in PR-1's Live UAT). PR-2 adds the Python harness + full scenario suite + per-mechanism red/green demonstrations.

**Defaulting to Shape A.** Two PRs would not produce cleaner reviewability for this scope; the harness scenarios are the test vehicle for the seams, and the seams are dead weight without the scenarios. One PR keeps the round-trip honest. If reviewer pushback during Gate 2 demands a split, we fall to Shape B.

**Live UAT:** Y — describe in §11.1.

## Preface — User Rubric

**User Rubric: N/A** — epic #319 Q2 Hardening is internal-only, no user-visible surface. The eventual user benefit (fewer recording-edge-case bugs in production) is downstream of this toolkit, not a direct surface change.

---

## 0. TL;DR

**Problem.** Heart-path bugs around timing windows, audio buffer stalls, XPC service crashes, and concurrent stop/start are caught either by founder-only manual testing or by Sentry weeks after merge. The 2026-04-18 senior audit named "live audio/MainActor/XPC interleavings during active recording" as the top unassessed gap.

**Fix.** A standing on-demand fault-injection toolkit. Three lanes split by what each is good at:
- **Lane A** (wispr_eyes runtime, Claude-driven): 9 fault scenarios covering capture stall, force-cancel, XPC service kill (Parakeet only — WhisperKit ASR is in-process), settings storms on actually-live-syncable settings, app quit during active recording, model-load cancellation, and rapid stop/start fuzzing.
- **Lane B** (runtime, founder-required for v1): 1 Bluetooth route flip scenario via physical device toggle. **Optional Lane B' (Claude-driven):** programmatic default-input-device flip via `AudioObjectSetPropertyData` if a 30-min spike confirms it triggers the same code path as a physical BT route change.
- **Lane C** (Swift `@Test`, deterministic, on PR CI): 4 invariants on the actual code surfaces that own the behavior — only the 2 that legitimately belong on pipeline stay there; the other 2 move to their real owners (PipelineSettingsSync guard, HotkeyService lock).

**Policy.** Lane A/B run **on demand only** — no CI integration, no nightly automation. Lane C runs as standard Swift tests on PR CI like any other deterministic unit test. The previous "no CI" framing was wrong on Lane C — pure state-machine invariants are exactly what CI is for.

**Tier.** LARGE — touches `Sources/EnviousWisprAudio/AudioCaptureProxy.swift` (DEBUG seams), `Sources/EnviousWisprASR/ASRManagerProxy.swift` (DEBUG seams), `Tests/EnviousWisprTests/Pipeline/V2/` (Swift `@Test`), `Tests/UITests/faultInjection.py` (Python harness).

**Evidence the toolkit works.** Each scenario has a documented negative control (what one-line regression makes it fail). PR demonstrates per-mechanism red/green for at least one representative scenario per family (timing, stall, XPC, settings, backend-switch guard, BT route, app-quit). Ongoing use does NOT require regression+revert cycles — that was overkill in v1 of the plan.

## 1. Problem

Concrete evidence the gap exists:

1. **2026-04-18 Senior Codex audit (`docs/audits/2026-04-18-senior-audit.json`)** — graded the codebase C and listed "live audio/MainActor/XPC interleavings during active recording" as the Red Team top unassessed gap. Static analysis cannot reach this class of failure.
2. **Session-log evidence of past regressions caught only by hand:**
   - 2026-04-15 #289 recovery-gap fix shipped after manual triage.
   - 2026-04-15 zombie-engine bug (#294) found by founder during shared-box dictation; reproduced by kill+relaunch only.
   - 2026-04-20 Phase A (`a00cbcb`/`5fffb96`) WhisperKit batch transcription broke under `any RecordingOverlayPanelProtocol` indirection — caught by manual A/B isolation, NOT by tests.
   - 2026-04-29 Phase D test theater rounds 1-3 (Codex caught state-flip claims bypassed by `guard state == .recording`) — these would have shipped without manual review.
3. **Production telemetry (V1a, 2026-04-30):** real users hit `audio_capture_failed` (19 events, 1 user, last 2026-04-15), `xpc_service_error` (4 events), `model_load_failed: cancelled` (1 event), `audio_capture_stalled` (2 events). Each is exactly the class of bug runtime fault injection would have caught pre-merge.

The pattern: every meaningful concurrency / XPC / timing bug we shipped this quarter was found either by chance during founder dictation, by Sentry after merge, or by manual code-review pressure — none by tests.

## 2. Goals & non-goals

### 2.1 Goals

- **G1.** Build a standing menu of 9 runtime fault scenarios in `Tests/UITests/faultInjection.py`, each invocable by name, each with a documented negative control.
- **G2.** Build 4 Swift `@Test` cases on the actual owners of the behavior they test (Lane C: 2 on pipeline, 1 on PipelineSettingsSync guard, 1 on HotkeyService lock).
- **G3.** Add DEBUG-only fault-injection seams on the actual XPC/capture types: `AudioCaptureProxy.forceStallNextN(_:)` (capture-side, where stall actually originates), `ASRManagerProxy.forceConnectionTerminationNow()` (true mid-stream connection termination, not connection-failure stub), and a per-pipeline `forceCancelNow()` for cancellation tests. All gated by `#if DEBUG` and `internal` (NOT `package` — see §3b for the correction).
- **G4.** Each runtime scenario has a documented one-line negative control. PR demonstrates per-mechanism red/green for at least one representative scenario per family. Ongoing use does NOT require regression+revert cycles.
- **G5.** Make the menu discoverable: `wispr_eyes list_scenarios` prints scenarios with metadata (lane, founder-required, runtime budget, mechanism family). `wispr_eyes run_scenario <name>` invokes one scenario.
- **G6.** Document the menu in `Tests/UITests/SCENARIOS.md` — indexed by symptom AND by scenario name — so future Claude sessions and the founder can find scenarios by failure class.

### 2.2 Non-goals

- **NG1.** No CI integration for Lane A/B. wispr_eyes cannot run on hosted runners (no audio device, no GUI, no app bundle, no microphone). Even on self-hosted, blocking PRs on a runtime suite for unrelated changes is anti-velocity. Founder rule 2026-04-30.
- **NG1-corrected.** Lane C tests DO run on PR CI as part of `swift test`. They are deterministic, fast, and heart-path-relevant. The original "no CI" framing was wrong on Lane C.
- **NG2.** No nightly automation. Founder rule 2026-04-30: nights are reserved for smaller bounded autonomous tasks; "full V2/V3/V4 adversarial review" is an explicit ask, not a recurring schedule.
- **NG3.** No new plan-template field for "scenarios this PR runs." Per NG1, PRs do not run Lane A/B.
- **NG4.** No global `FaultInjectionRegistry` type. Anti-god-object per `architecture-rules.md`. Each DEBUG seam lives on the type that owns the behavior being injected.
- **NG5.** No production code change beyond DEBUG-only seams. Heart path behavior unchanged in release builds.
- **NG6.** No coverage of LLM polish provider chaos. V4's scope.
- **NG7.** No coverage of paste cascade. The recent paste_failed cluster (V1a §6.5) is its own follow-up issue. **V2 does NOT fully cover the heart path** — paste is part of heart and explicitly excluded here.
- **NG8.** No new production telemetry. V2 is tests only. If production telemetry is needed for a fault class (e.g., `pipeline.fault_recovered` event), that's a separate scope decision.
- **NG9.** No backend-switch-mid-record product behavior change. V2 documents what currently happens. If current behavior is "abort active dictation on backend change," file a follow-up bug; do not fix in V2 scope.
- **NG10.** No fake `WhisperKitBackend` for testing. PreWarmThrowsTests notes this gap. V2 does NOT close it. If WhisperKit-specific Lane C invariants need a fake, file as separate issue.

## 3. Design

### 3.1 Lane A — wispr_eyes runtime scenarios (Claude-driven, autonomous)

Each scenario is a Python function in `Tests/UITests/faultInjection.py`. Function decorator carries metadata (lane, founder-required, runtime budget, mechanism family, negative control description).

Helper layer added to `wispr_eyes.py`:
- `record_with_fault(scenario, **kwargs)` — orchestrates app launch, audio injection via TTS, fault trigger via DEBUG localhost endpoint (see §3.5), result capture.
- `assert_terminated(timeout_s)` — polls pipeline state via existing accessibility tree probe, fails if not terminal within budget.
- `assert_no_zombie()` — verifies audio engine `isRunning == false`, microphone hold released, no orphan XPC connection.

**Scenarios (9):**

| # | Scenario | Mechanism family | Backend(s) | Acceptance budget | Negative control |
|---|---|---|---|---|---|
| A1 | Rapid stop/start fuzz (boundary 100ms + jittered 100-500ms) | Timing/cancel | both | <3s to terminal | Remove debounce window, scenario passes when it should fail |
| A2 | Force-cancel mid-record (1s into recording) | Timing/cancel | both | <2s to .idle | Remove cancellation cleanup, scenario detects leaked task |
| A3 | XPC ASR service mid-stream kill (after 1s of audio captured) | XPC | parakeet | <5s to .error, no zombie | Remove ASR-crash handler, scenario sees pipeline stuck |
| A4 | Audio XPC service kill (after capture started) | XPC | both | <5s to .error, no zombie | Remove audio-XPC-error handler, scenario sees pipeline stuck |
| A5 | Forced audio buffer stall (drop next N capture buffers, where N exceeds stall-detector threshold) | Stall | both | <`stallDetectorTimeout` + 2s to .error | Remove stall detector, scenario passes when it should fail (recording continues without audio) |
| A6 | Settings storm — toggle live-syncable settings during recording | Settings | both | <30s to .complete | Remove `wordCorrectionEnabled` live-sync, scenario detects setting takes no effect |
| A7 | App quit during active recording (Cocoa terminate, NOT raw SIGTERM) | App-quit | both | post-launch app starts clean within 5s; no orphan XPC helpers | Remove `applicationWillTerminate` cleanup, scenario detects orphaned state on next launch |
| A8a | Cancel during Parakeet model load | Model-load | parakeet | <3s to .idle, modelLoadTask cancelled cleanly | Remove `modelLoadTask.cancel()` at TranscriptionPipeline.swift:1089-1096, scenario sees task linger |
| A8b | Cancel during WhisperKit model load | Model-load | whisperKit | <3s to .idle (state-unwind only — no underlying cancel) | Remove WhisperKit prepare-state-flip at WhisperKitPipeline.swift:1078-1084, scenario sees inconsistent state |
| A9 | Backend switch mid-record (settings UI change attempt) | Backend-switch guard | both directions | <1s rejection, recording continues | Remove `PipelineSettingsSync` guard, scenario sees active recording aborted |

Each scenario writes evidence to `.validation/scenarios/<name>-<timestamp>.json`.

**A6 settings to toggle (per Codex grounded review of `PipelineSettingsSync.swift:137-169`):** `wordCorrectionEnabled`, `fillerRemovalEnabled`, `writingStylePreset`, `customSystemPrompt`, `useExtendedThinking`. **Do NOT toggle `noiseSuppression`** — it cancels active Parakeet recording (`PipelineSettingsSync.swift:175-185`). **Do NOT toggle frozen-at-start fields** (`autoCopyToClipboard`, `restoreClipboardAfterPaste`, `vadAutoStop`, `vadSilenceTimeout`, `vadSensitivity`, `vadEnergyGate`, `languageMode`, `useStreamingASR`) — those are Phase B's `DictationSessionConfig` and are intentionally frozen.

### 3.2 Lane B — Bluetooth founder-required scenarios

Same `Tests/UITests/faultInjection.py` file. Function decorated with `@founder_required` so `list_scenarios()` flags them and `run_scenario()` aborts with clear instructions if invoked unattended.

**Scenarios in scope (1, with optional Lane B' split):**

| # | Scenario | Backend | Founder action | Lane |
|---|---|---|---|---|
| B1 | True Bluetooth route flip mid-record (physical AirPods on/off) | both | Toggle device when prompted | B (founder-required) |
| B1' (optional) | Programmatic default-input-device flip via `AudioObjectSetPropertyData` | both | None | A (Claude-driven) |

**B1' justification.** Codex confirmed via Apple docs that `AudioObjectSetPropertyData` on `kAudioHardwarePropertyDefaultInputDevice` fires the same HAL listeners that physical BT toggle does, observed via `AudioObjectAddPropertyListenerBlock` — which our codebase already uses (`AudioDeviceManager.swift:226-259`). This is a default-device flip, NOT a true BT codec transition or physical disconnect, so B1 is still meaningful. **Spike (~30 min) before merging:** confirm B1' actually exercises the same code path as B1; if yes, B1' becomes a Claude-driven scenario in Lane A and B1 becomes a "release-time only" check.

### 3.2.1 A7 narrowed contract (round 2 revision)

Round 2 grounded review confirmed: no `SIGTERM` / `signal` / `DispatchSourceSignal` handler exists in `Sources/`. Only standard Cocoa `applicationWillTerminate` cleanup at `Sources/EnviousWispr/App/AppDelegate.swift:408-420`. So A7 cannot validate "graceful SIGTERM cleanup" without first adding a signal handler — which is scope creep.

**A7's narrowed contract:** trigger app exit via Cocoa terminate (NSApp.terminate or equivalent) during active recording. Verify (a) `applicationWillTerminate` runs and cleans up XPC helpers + audio engine, (b) next launch starts clean (no orphan helper processes via `pgrep -x EnviousWisprAudioService EnviousWisprASRService`).

**Out of A7 scope:** raw SIGTERM handling, kill -9, force-quit. If founder wants those, file a separate issue to add a signal handler first.

### 3.2.2 A8 split into A8a (Parakeet) + A8b (WhisperKit) (round 2 revision)

Round 2 grounded review confirmed asymmetry between backends:
- **Parakeet:** `modelLoadTask` is a held `Task` at `TranscriptionPipeline.swift:117-119, :359-365`, cancelled at `:1089-1096`. A8a tests true cancellation propagation.
- **WhisperKit:** `backend.prepare()` is awaited directly at `WhisperKitPipeline.swift:420-431`, no held task. Cancellation only flips state at `:1078-1084`. A8b tests state-unwind only — the underlying load may still complete in the background.
- **ASRManager / ASRManagerProxy `inFlightLoadTask`** (`ASRManager.swift:20-21`, `ASRManagerProxy.swift:40-41`) has no explicit cancel API.

**Documented limitation in `SCENARIOS.md`:** A8b's pass criterion is "pipeline state reaches `.idle` and remains coherent"; it does NOT prove the underlying WhisperKit prepare task was actually cancelled. If we want true WhisperKit load cancellation, that's a separate Sources/ change to add a cancel API to the prepare path.

### 3.3 Lane C — Swift `@Test` invariants on actual owners (deterministic, fast, on PR CI)

Reviewers (especially Codex grounded review #6) showed that 4 of the original 6 invariants did not belong on the pipeline. Revised list:

| # | Invariant | Test name | File location | Owner type |
|---|---|---|---|---|
| C1 | Dedup-survives-stall on pipeline (via `FixtureAudioCapture` + `pipeline.handleCaptureStall` — does NOT exercise the new proxy seam; that's A5's job) | `testDedupSurvivesStallRestart` | `Tests/EnviousWisprTests/Pipeline/V2/DedupSurvivesStallTests.swift` | TranscriptionPipeline |
| C2 | Cancellation silent unwind on Parakeet pipeline | `testCancellationSilentUnwind` | `Tests/EnviousWisprTests/Pipeline/V2/CancellationSilentUnwindTests.swift` | TranscriptionPipeline |
| C3 | Backend-switch is rejected/deferred while recording active (NOT `.error`) | `testBackendSwitchDeferredWhileRecording` | `Tests/EnviousWisprTests/App/V2/BackendSwitchGuardTests.swift` | PipelineSettingsSync |
| C4 | Hands-free lock cleared on completion | `testHandsFreeLockClearedOnComplete` | `Tests/EnviousWisprTests/Services/V2/HandsFreeLockTests.swift` | HotkeyService + AppState |

**Removed from Lane C:**
- "Session-id mismatch rejected" — not a pipeline invariant in current code; if a real bug exists, file as standalone investigation.
- "Zombie recovery reaches `.recording`" — needs fake `WhisperKitBackend` that does not exist in the codebase (`PreWarmThrowsTests.swift:7-13` confirms gap). Scope creep into building the fake. **File as follow-up: "Build fake WhisperKitBackend for Lane C invariant coverage"** rather than blocking V2 on it.

**Backend-switch C3 invariant precision.** The original C5 said "backend switch surfaces error." Codex pointed out `PipelineSettingsSync.swift:86-98` already blocks switching when either pipeline is active — current behavior is "rejected without canceling recording," which IS the heart-path-correct invariant per GPT review. C3 codifies that current correct behavior and protects it from regression.

Use the existing test patterns from `Tests/EnviousWisprTests/Pipeline/HeartPathTelemetryEmitterTests.swift` (introduced R5/PR #511) and `HeartPathIntegrationTests.swift:70-128` (cancellation pattern).

### 3.4 Wiring (cross-lane)

- `Tests/UITests/wispr_eyes.py`: add `list_scenarios()` and `run_scenario(name, **kwargs)` functions. Pure dispatch — no scenario logic in `wispr_eyes.py` itself.
- CLI invocation: `python3 -c "import sys; sys.path.insert(0, 'Tests/UITests'); from wispr_eyes import *; list_scenarios()"`. Returns table with name, lane, founder-required, runtime budget, mechanism family, brief description.
- `Tests/UITests/SCENARIOS.md`: human-readable menu indexed by symptom AND by scenario name. Updated whenever a scenario is added or removed.

### 3.5 Lane A trigger mechanism — DEBUG-only localhost command endpoint

**Decision (replaces Open Q1).** Reviewers all rejected `defaults write`-with-polling: it perturbs timing measurement, is global/persistent, awkward to route to the active session, not immediate enough for sub-100ms scenarios, and pollutes the heart path with hot-path config reads.

**Selected mechanism: tightly-gated DEBUG-only localhost command endpoint.**

Constraints (per GPT review §6 Q1):
- Compiled out of release entirely (`#if DEBUG` around the entire endpoint listener init in `App` startup).
- Disabled by default even in DEBUG. Enabled only when launched with environment variable `EW_FAULT_INJECTION=1`.
- Binds only to `127.0.0.1`.
- Authenticates with a per-launch random token written to `~/Library/Logs/EnviousWispr/fault-token-<pid>` (one-shot file readable only by owning user, deleted on app exit).
- Exposes a tiny fixed command set (no arbitrary RPC): `force_stall(N)`, `force_cancel()`, `force_xpc_kill()`, `force_audio_xpc_kill()`, `query_state`. No method invocation, no eval, no shell escape.
- Each command is dispatched onto the owning actor / session via `Task { @MainActor in ... }` or the relevant actor hop.
- Endpoint listener removed in `deinit` of the app delegate.

**Alternative considered but rejected: DistributedNotificationCenter.** Cleaner from "no localhost surface" perspective, but: (a) NSDistributedNotificationCenter is being slowly deprecated by Apple, (b) cross-process delivery latency is non-deterministic for sub-100ms timing scenarios, (c) the gating + one-shot token model is the same complexity for both.

**Even better alternative not in v1: Unix domain socket** at `~/Library/Caches/EnviousWispr/fault.sock`. Equivalent functionality, no network surface at all. Worth considering if a security review later objects to even DEBUG-only localhost binding.

### 3.6 What's intentionally NOT designed

- No fault-injection-as-a-service. No global registry. Each DEBUG seam is a single property/method on the type it affects.
- No automated scenario discovery from Swift code. Python menu is source of truth; if a new Swift fault seam is added, the corresponding Python scenario is added in the same PR.
- No new production telemetry (NG8).
- No paste cascade fault injection (NG7) — V2 does not fully cover heart path; paste is its own follow-up.
- No backend-switch product behavior change (NG9).
- No fake `WhisperKitBackend` (NG10) — separate follow-up issue.

## 3a. Metric Definition + Earliest Failure Point

**Metric Definition.**

- **Scenario "terminated" =** `pipelineState in {.complete, .error, .idle}` observed via the existing accessibility tree probe in `wispr_eyes.py`. Polled at 100ms intervals.
- **Scenario "no zombie" =** post-terminal-state check that (a) audio engine `isRunning == false`, verified via existing `check_recording_state()` helper; (b) microphone hold released (`kAudioHardwarePropertyDevices` shows our app NOT as active client); (c) no orphan XPC connection (process tree shows no detached `EnviousWisprASRService` for non-current session-id).
- **Scenario "negative control documented" =** scenario has a plain-English line in `SCENARIOS.md` describing the one-line regression that makes it fail. Verified during plan review by reading the line; verified during PR by demonstrating per-family red/green at least once.
- **Scenario runtime budget =** wall-clock seconds from `run_scenario()` invocation to result return. Per-scenario sub-budgets in §3.1 table. Default ceiling 30s.
- **Lane C `@Test` count =** files matching `Tests/EnviousWisprTests/{Pipeline,App,Services}/V2/*Tests.swift`, must contain exactly 4 `@Test` functions covering C1-C4.
- **Acceptance budgets tied to actual stall-detector timeouts** (per GPT review §7.5). A5's budget is `stallDetectorTimeout + 2s` rather than blanket 30s — read the actual timeout from the codebase before finalizing the test.

**Earliest Failure Point.**

| Plan failure mode | Earliest catchable layer | Justification |
|---|---|---|
| DEBUG seam name conflicts with existing API | Build-time | Swift compiler |
| Lane C Swift `@Test` doesn't compile | Build-time | `swift build --build-tests` |
| Lane C `@Test` fails | Local test-time | `scripts/swift-test.sh` |
| Lane A scenario fails to terminate within budget | Local runtime (Live UAT) | wispr_eyes invocation; cannot be caught earlier — runtime behavior |
| Lane A scenario "terminated" but actually has zombie engine | Local runtime + post-check | Same as above |
| Plan claims a scenario exists but Python file lacks the function | Plan-time (Codex grounded review) | grep before merge |
| Scenario negative control claim unproven | Local runtime (Live UAT, must demonstrate per-family red/green at least once) | Cannot be caught earlier without the demonstration |
| Founder-required scenario invoked unattended | Local runtime (`run_scenario` aborts with instructions) | Behavioral guard |
| DEBUG endpoint listener leaks into release build | Local build + symbol grep | Verified by `nm` against release binary in ship criteria |

PR CI runs Lane C as part of standard `swift test`. PR CI does NOT run Lane A/B (impossible — no audio device on hosted runners).

## 3b. Ownership justification

**Owner choice — DEBUG seams in `Sources/`.** Pivoted from v1 of the plan after Codex grounded review.

| Seam | v1 location (wrong) | v2 location (correct) | Why |
|---|---|---|---|
| `forceStallNextN(_:)` | WhisperKitPipeline + TranscriptionPipeline | `AudioCaptureProxy` | Stall is a capture-side concern. WhisperKit batch doesn't have a chunk handler (`WhisperKitPipeline.swift:439-440` clears `onBufferCaptured`). Pipeline-level stall would either miss WhisperKit or test only the tail worker. Capture proxy is where buffers and stall watchdog state actually live (`AudioCaptureProxy.swift:148-176`, `:211-230`). |
| `forceConnectionTerminationNow()` | (was `XPCServiceClient.forceKillNext`, simulating connection-establish failure) | `ASRManagerProxy` for ASR XPC; `AudioCaptureProxy` for audio XPC | Connection-establish-failure stub does not catch late-reply, mid-stream death, or invalidated-connection-while-streaming. True mid-stream connection termination on the active connection's owning client is what production failure looks like. |
| `forceCancelNow()` | WhisperKitPipeline + TranscriptionPipeline | Stays on pipelines (correct in v1) | Cancellation IS a pipeline-level concern. The pipeline owns the in-flight transcription Task; cancelling it tests the pipeline's unwind path, which is the right scope. |

**Why these owners and not more local ones?** Heart vs limb: the capture proxy and ASR proxy ARE the heart-side XPC clients. The fault flags are not heart-path code; they are inert in release builds (`#if DEBUG`-gated). In DEBUG, the flag IS the failure path being tested. Putting the flags on a separate `FaultInjectionRegistry` would create a new always-on coordinator, violating anti-god-object (`architecture-rules.md` § Anti-God-Object — concrete-collaborator count ≤19).

**Top-level coordination?** No. Each seam is local to one type. Three types touched, no central coordinator.

**Is this truly top-level?** No. AppState does NOT see any seam.

**Owner choice — Lane A localhost endpoint listener (round 2 revision).** Round 2 grounded review pivoted this from `EnviousWisprApp.swift` to `AppDelegate`. `EnviousWisprApp.swift` (lines 11-16) only initializes observability + builds scenes — no `appState` access at startup. The real runtime startup hook is `AppDelegate.applicationDidFinishLaunching` (lines 37-86) with cleanup in `applicationWillTerminate` (lines 408-420).

**Selected shape:** small `DebugFaultEndpoint` type (DEBUG-only, defined in `Sources/EnviousWispr/App/Debug/DebugFaultEndpoint.swift`) retained as a property on `AppDelegate`, started in `applicationDidFinishLaunching`, stopped + token file deleted in `applicationWillTerminate`. ~80 LOC for the type + ~15 LOC of AppDelegate wiring (all gated `#if DEBUG`).

**Why a type rather than inline function (versus my v2 instinct)?** Codex placement challenge: a named type makes the lifecycle visible (start/stop/cleanup) and gives tests a seam if Lane C ever needs to verify endpoint behavior directly. 80 LOC justifies a type. Concrete-collaborator count on AppState unaffected — the type is owned by AppDelegate, not AppState.

**Owner choice — Python harness scenarios.** Live in `Tests/UITests/faultInjection.py`. Module-level functions parallel to `Tests/UITests/wispr_eyes.py`. No class hierarchy, no Swift-side owner.

**Owner choice — Swift `@Test` invariants.** Lane C tests live where their owner lives:
- C1 + C2 (pipeline behavior) → `Tests/EnviousWisprTests/Pipeline/V2/`
- C3 (PipelineSettingsSync guard) → `Tests/EnviousWisprTests/App/V2/`
- C4 (HotkeyService lock) → `Tests/EnviousWisprTests/Services/V2/`

**Concrete-collaborator count impact:** Zero. No new types added to AppState. AppState's count stays at 19 (Phase E ceiling).

## 4. Contract deltas

### 4.1 New DEBUG-only members on `AudioCaptureProxy`

```swift
#if DEBUG
extension AudioCaptureProxy {
    // Note: extensions cannot add stored properties. The flag goes IN the type body.
}

// In AudioCaptureProxy class body:
#if DEBUG
internal var forceStallRemainingBuffers: Int = 0  // Drop next N buffers
internal func forceConnectionTerminationNow() { ... }
#endif
```

- **Semantics:** **Bypass** — DEBUG-only test seam, inert in release. `forceStallRemainingBuffers > 0` causes the next N captured buffers to be silently dropped (decrementing per drop until 0). `forceConnectionTerminationNow()` invalidates the active `NSXPCConnection` mid-stream.
- **Invariants:** `internal` access (NOT `package` — see §3b correction). Visible only to test target via `@testable import EnviousWisprAudio`. App target cannot see them. `#if DEBUG` ensures release builds compile them out entirely.
- **Stored property in the type body, NOT in extension** (per GPT review §2 — Swift extensions cannot add stored properties).

### 4.2 New DEBUG-only members on `ASRManagerProxy`

```swift
#if DEBUG
internal func forceConnectionTerminationNow() { ... }
#endif
```

- **Semantics:** **Bypass.** Invalidates the active XPC connection mid-stream during an in-flight ASR request.
- **Invariants:** Same `internal` + `#if DEBUG` discipline.

### 4.3 New DEBUG-only members on pipelines (`WhisperKitPipeline`, `TranscriptionPipeline`)

```swift
#if DEBUG
internal func forceCancelNow() { /* cancels in-flight transcription Task */ }
#endif
```

- **Semantics:** **Bypass.** Cancels the in-flight transcription Task with a synthetic `CancellationError`. Tests the pipeline's existing cancellation unwind path.
- **Invariants:** `@MainActor` (matches pipeline isolation per Codex review §5 — `TranscriptionPipeline.swift:10-13`, `WhisperKitPipeline.swift:48-54`).

### 4.4 New DEBUG-only Lane A endpoint listener — `DebugFaultEndpoint` owned by `AppDelegate`

> **Round 2 pivot — see §3.7 Owner choice.** Originally drafted as a private function on `EnviousWisprApp`; per round 2 grounded review the listener is a dedicated `DebugFaultEndpoint` type (DEBUG-only, ~80 LOC at `Sources/EnviousWispr/App/Debug/DebugFaultEndpoint.swift`) retained as a property on `AppDelegate`. `EnviousWisprApp.swift` has no `appState` access at startup; `AppDelegate.applicationDidFinishLaunching` (lines 37-86) is the real runtime startup hook with `applicationWillTerminate` (lines 408-420) for cleanup.

```swift
// Sources/EnviousWispr/App/Debug/DebugFaultEndpoint.swift
#if DEBUG
final class DebugFaultEndpoint {
    func start() {
        guard ProcessInfo.processInfo.environment["EW_FAULT_INJECTION"] == "1" else { return }
        // Bind 127.0.0.1, write per-launch token to ~/Library/Logs/EnviousWispr/fault-token-<pid>,
        // accept fixed command set, dispatch to owning actor via Task { @MainActor in ... }.
    }
    func stop() { /* close listener, delete token file */ }
}
#endif

// Sources/EnviousWispr/App/AppDelegate.swift (wiring, all #if DEBUG-gated)
#if DEBUG
private let debugFaultEndpoint = DebugFaultEndpoint()
// in applicationDidFinishLaunching: debugFaultEndpoint.start()
// in applicationWillTerminate:    debugFaultEndpoint.stop()
#endif
```

- **Semantics:** **Bypass.** Off by default in DEBUG; on only when env var set. Production: compiled out.
- **Invariants:** Single-purpose, fixed command set, no arbitrary RPC. Lifecycle bound to `AppDelegate`, not `EnviousWisprApp` (the SwiftUI scene root has no startup hook).

### 4.5 New Lane C Swift `@Test` functions

Four `@Test` functions added to `Tests/EnviousWisprTests/{Pipeline,App,Services}/V2/`. Each consumes existing public APIs only — no new public surface. Tests are observers, not contract changes.

**Legacy data compatibility.** No new persisted fields. No new enum cases reaching disk. DEBUG seams are in-memory only, lost on app exit. No migration concerns.

## 5. E2E state & lifecycle audit

The audit applies once per scenario family, not once per scenario.

| Path | Behavior under this change |
|---|---|
| Live / new item (primary path) | Unchanged in release. In DEBUG with `EW_FAULT_INJECTION=1`, scenarios trigger their fault, expect terminal state within budget, verify no zombie. |
| Saved / reloaded item | Unchanged. DEBUG seams do not touch persistence. |
| Retry or re-run (same item, same step) | Unchanged. DEBUG seam state is per-recording (forceStallRemainingBuffers decrements to 0); subsequent recordings behave normally. |
| Background / async completion arriving after state changed | Lane A3/A4 (XPC kill) explicitly test this — XPC reply or callback arrives after pipeline canceled. Expected: ignored cleanly. |
| User manual override / edit path | N/A — no user-visible surface. |

**Upstream sources.** The DEBUG seams have exactly two upstream sources:
1. `Tests/UITests/faultInjection.py` scenarios via the DEBUG localhost endpoint (which dispatches to the owning actor).
2. `Tests/EnviousWisprTests/{Pipeline,App,Services}/V2/` Swift tests via direct property/method access (`@testable import`).

No production source. Verified by grep before each PR (§6 Discovery method).

**UI side effects.** None directly. Pipeline state changes that result from triggered faults flow through existing state-change handlers; no new UI surface.

**Persistence.** None. DEBUG flags are in-memory only. Per-launch fault-injection token file (`~/Library/Logs/EnviousWispr/fault-token-<pid>`) is deleted on app exit.

**App-kill scenario.** Force-quit during a triggered fault: the next launch starts clean (DEBUG flags reset, token file recreated on next `EW_FAULT_INJECTION=1` launch). Scenario A7 explicitly tests this.

**Concurrency guard.** DEBUG flags accessed only from the actor that owns the type (`@MainActor` for pipelines + AudioCaptureProxy + ASRManagerProxy per Codex review §5). No cross-thread mutation. Endpoint listener dispatches incoming commands via `Task { @MainActor in ... }` to avoid actor boundary violations.

## 6. Downstream consumer matrix

| Contract delta | Consumer | Current behavior | Required behavior | Code change? | Verified by |
|---|---|---|---|---|---|
| `AudioCaptureProxy.forceStallRemainingBuffers` (DEBUG, internal) | `Tests/UITests/faultInjection.py` A5 | n/a (new) | Endpoint dispatches `force_stall(N)` → set property → buffers drop → pipeline reaches `.error` after stall-detector timeout | Yes (~10 LOC AudioCaptureProxy + ~50 LOC endpoint) | A5 negative control |
| `AudioCaptureProxy.forceStallRemainingBuffers` (DEBUG) | `Tests/EnviousWisprTests/Pipeline/V2/DedupSurvivesStallTests.swift` (C1) | n/a (new) | Set value, simulate stall+restart, assert dedup behavior holds | Yes | C1 test |
| `AudioCaptureProxy.forceConnectionTerminationNow()` (DEBUG) | A4 (audio XPC kill) | n/a | Endpoint dispatches `force_audio_xpc_kill` → invalidate active connection mid-stream → pipeline reaches `.error` | Yes (~5 LOC AudioCaptureProxy) | A4 negative control |
| `ASRManagerProxy.forceConnectionTerminationNow()` (DEBUG) | A3 (Parakeet ASR XPC kill) | n/a | Endpoint dispatches `force_xpc_kill` → invalidate active ASR connection mid-stream → pipeline reaches `.error` | Yes (~5 LOC ASRManagerProxy) | A3 negative control |
| `WhisperKitPipeline.forceCancelNow()` (DEBUG) | A2 + (no Lane C — cancellation Lane C is Parakeet only via fixture pattern from `HeartPathIntegrationTests.swift:70-128`) | n/a | Endpoint dispatches `force_cancel` → cancels active Task → pipeline reaches `.idle` | Yes (~5 LOC) | A2 negative control |
| `TranscriptionPipeline.forceCancelNow()` (DEBUG) | A2 + C2 testCancellationSilentUnwind | n/a | Same as above for Parakeet | Yes (~5 LOC) | A2 + C2 |
| Lane A endpoint listener | A1, A6, A7, A8, A9 use existing wispr_eyes accessibility/menu drivers (no new seam needed) | n/a | Listener accepts fixed commands when `EW_FAULT_INJECTION=1` | Yes (~50 LOC EnviousWisprApp.swift) | All Lane A scenarios |

**Discovery method.** Two separate greps (per GPT review §7.2 — original was confused because XPCServiceClient.swift didn't exist; corrected paths below):

```bash
# Definition grep — confirm seams ONLY exist in their owning files:
grep -rn "forceStallRemainingBuffers\|forceConnectionTerminationNow\|forceCancelNow" \
  Sources/EnviousWisprAudio/AudioCaptureProxy.swift \
  Sources/EnviousWisprASR/ASRManagerProxy.swift \
  Sources/EnviousWisprPipeline/WhisperKitPipeline.swift \
  Sources/EnviousWisprPipeline/TranscriptionPipeline.swift
# Should match the declarations only, all under #if DEBUG.

# Unauthorized consumer grep — confirm NO production code reads them:
grep -rn "forceStallRemainingBuffers\|forceConnectionTerminationNow\|forceCancelNow" \
  Sources/EnviousWispr/ Sources/EnviousWisprServices/ Sources/EnviousWisprCore/ \
  Sources/EnviousWisprPostProcessing/ Sources/EnviousWisprLLM/
# Should return ZERO matches.

# Endpoint listener consumer grep:
grep -rn "EW_FAULT_INJECTION\|fault-token" Sources/
# Should match only Sources/EnviousWispr/App/Debug/DebugFaultEndpoint.swift
# plus the DEBUG-gated start/stop wiring lines in Sources/EnviousWispr/App/AppDelegate.swift,
# all under #if DEBUG.

# Test consumers grep:
grep -rn "forceStallRemainingBuffers\|forceConnectionTerminationNow\|forceCancelNow\|EW_FAULT_INJECTION" Tests/
# Should match only the Lane A harness + Lane C @Test files.
```

## 7. Failure-mode × caller table

| Failure mode | Origin | Caller | Expected UX | Expected persisted state | Expected metadata stamp | Expected retry |
|---|---|---|---|---|---|---|
| `forceStallRemainingBuffers > 0` triggered → audio buffers dropped | DEBUG seam in AudioCaptureProxy | A5 / C1 | DEBUG-only; no production UX | None | None | Pipeline `.recording` → `.error("Audio capture stalled")` after stall-detector timeout |
| `forceConnectionTerminationNow()` on AudioCaptureProxy | DEBUG seam method | A4 | DEBUG-only | None | None | Existing audio-XPC-error handler fires (`xpc_service_error` Sentry breadcrumb in DEBUG only; no Sentry in production because `#if DEBUG`) |
| `forceConnectionTerminationNow()` on ASRManagerProxy | DEBUG seam method | A3 | DEBUG-only | None | None | Existing ASR-crash handler fires (`WhisperKitPipeline.swift:1044` "ASR XPC service crashed" path; for Parakeet, equivalent path in `TranscriptionPipeline`) |
| `forceCancelNow()` triggered | DEBUG seam method | A2 / C2 | DEBUG-only | None | None | Pipeline transitions to `.idle` after cancellation unwinds. C2 asserts no Sentry breadcrumb spam during unwind. |
| Endpoint listener active without env var | n/a (cannot happen) | n/a | Listener doesn't start | n/a | n/a | n/a |
| Endpoint listener active in release | n/a (cannot happen — `#if DEBUG`) | n/a | Compiled out | n/a | n/a | n/a |

## 8. Caller-visible signals audit

DEBUG seams have NO caller-visible signals in production code.

**Touched fields/methods:**
- `AudioCaptureProxy.forceStallRemainingBuffers: Int` (DEBUG, internal)
- `AudioCaptureProxy.forceConnectionTerminationNow()` (DEBUG, internal)
- `ASRManagerProxy.forceConnectionTerminationNow()` (DEBUG, internal)
- `WhisperKitPipeline.forceCancelNow()` (DEBUG, internal)
- `TranscriptionPipeline.forceCancelNow()` (DEBUG, internal)
- `EnviousWisprApp.startFaultInjectionEndpointIfRequested()` (DEBUG, private)

**Verification grep** (per GPT review §7.2 corrected):

```bash
# No UI / persistence / analytics code keys off these:
grep -rn "forceStallRemainingBuffers\|forceConnectionTerminationNow\|forceCancelNow" \
  Sources/EnviousWispr/Views Sources/EnviousWispr/App Sources/EnviousWisprCore/ \
  Sources/EnviousWisprServices/ScreenInsight*.swift
# Should return ZERO matches.
```

The Swift `@Test` cases (Lane C) observe state via existing public APIs (`pipeline.state`, etc.). No new signals from those tests either.

## 9. Fallback source-of-truth audit

DEBUG seams introduce no fallback branches. Each is a deterministic single-shot trigger:
- `forceStallRemainingBuffers > 0` → next buffer dropped → counter decrements → reaches 0 automatically
- `forceConnectionTerminationNow()` → invalidates connection synchronously → caller's existing XPC error path handles
- `forceCancelNow()` → cancels Task → caller's existing CancellationError catch handles

No fallback path because no graceful-degradation behavior exists in DEBUG seams. They cause the failure they advertise; production code's existing error handling responds.

## 10. File-by-file changes (corrected paths from Codex review)

**Code-lane changes (`Sources/`):**

- `Sources/EnviousWisprAudio/AudioCaptureProxy.swift` — `#if DEBUG` block in type body adding `internal var forceStallRemainingBuffers: Int = 0` + `internal func forceConnectionTerminationNow()`. Modify buffer delivery path (1 line, gated `#if DEBUG`) to check + decrement + drop. ~25 LOC.
- `Sources/EnviousWisprASR/ASRManagerProxy.swift` — `#if DEBUG` block in type body adding `internal func forceConnectionTerminationNow()`. ~10 LOC.
- `Sources/EnviousWisprPipeline/WhisperKitPipeline.swift` — `#if DEBUG` block adding `internal func forceCancelNow()`. ~5 LOC.
- `Sources/EnviousWisprPipeline/TranscriptionPipeline.swift` — `#if DEBUG` block adding `internal func forceCancelNow()`. ~5 LOC.
- `Sources/EnviousWispr/App/Debug/DebugFaultEndpoint.swift` — new file, entire content gated `#if DEBUG`. `DebugFaultEndpoint` type with `start()` + `stop()` methods. Env-gated (`EW_FAULT_INJECTION=1`), binds `127.0.0.1`, fixed command set, per-launch token at `~/Library/Logs/EnviousWispr/fault-token-<pid>` (created with `0600` permissions, atomic write before accepting commands). Routes commands to owning actor via `Task { @MainActor in ... }`. ~80 LOC.
- `Sources/EnviousWispr/App/AppDelegate.swift` — wire `DebugFaultEndpoint` start/stop into `applicationDidFinishLaunching` (lines 37-86) + `applicationWillTerminate` (lines 408-420). All `#if DEBUG`-gated. ~15 LOC of wiring.

Code-lane subtotal: ~125 LOC, all gated `#if DEBUG`. Zero release-build impact (verified by symbol grep in ship criteria).

**Test changes (`Tests/`):**

- `Tests/EnviousWisprTests/Pipeline/V2/DedupSurvivesStallTests.swift` — C1. ~50 LOC.
- `Tests/EnviousWisprTests/Pipeline/V2/CancellationSilentUnwindTests.swift` — C2. ~60 LOC (Sentry breadcrumb capture via existing test sink).
- `Tests/EnviousWisprTests/App/V2/BackendSwitchGuardTests.swift` — C3. ~50 LOC.
- `Tests/EnviousWisprTests/Services/V2/HandsFreeLockTests.swift` — C4. ~40 LOC.
- `Tests/UITests/faultInjection.py` — new file. 9 Lane A scenarios + 1 Lane B scenario, each as a top-level decorated function. Endpoint client in shared module. ~450 LOC.
- `Tests/UITests/wispr_eyes.py` — extensions: `list_scenarios()`, `run_scenario(name, **kwargs)`, helper layer (`record_with_fault`, `assert_terminated`, `assert_no_zombie`). Endpoint token reader. ~150 LOC.
- `Tests/UITests/SCENARIOS.md` — human-readable menu, indexed by symptom and by name, includes negative control per scenario. ~250 lines.

Test subtotal: ~1050 LOC + docs.

**Cross-cutting:**

- Bible §6.1 V2 row updated PLANNED → SHIPPED on V2 PR merge.
- Issue #291 closed with reference to V2 PR.

**Total V2 LOC: ~1175.** Tier LARGE confirmed.

## 11. Testing

### 11.1 Live UAT spec (the V2 PR)

- **Subsystem touched:** heart path (DEBUG seams on AudioCaptureProxy + ASRManagerProxy + pipelines + DEBUG-only endpoint).
- **Driver:** Smoke pass = `python3 -c "import sys; sys.path.insert(0, 'Tests/UITests'); from wispr_eyes import *; run_scenario('A5_forced_stall', backend='parakeet')"` — invokes the most representative Lane A scenario. Per-mechanism red/green = repeat for one scenario per family (timing/cancel = A1; stall = A5; XPC = A3; settings = A6; backend-switch guard = A9; app-quit = A7; model-load = A8).
- **Input sentence:** `"this is a fault injection test"` (TTS via `tts()` helper, OpenAI echo voice per `tools-and-apps.md` §4).
- **Expected token:** none — these scenarios validate fault injection, not transcription accuracy. Acceptance is on terminal state + no zombie.
- **Preconditions:** app NOT running (test launches fresh with `EW_FAULT_INJECTION=1`), clipboard cleared, mic enabled.
- **Core acceptance criterion:** for each demonstrated scenario, pipeline reaches its target terminal state within budget; audio engine `.idle` post-run; no orphan XPC connection.
- **Feature acceptance criterion:** per-mechanism red/green demonstrated for at least 7 scenarios (one per family above). For each: revert the corresponding negative control documented in `SCENARIOS.md`, confirm scenario produces FAIL; restore, confirm scenario produces PASS. Evidence in `.validation/runs/<id>/scenario-redgreen-<name>.json`.
- **Evidence path:** `.validation/runs/<id>/live-uat.json` + `.validation/runs/<id>/scenario-redgreen-*.json`.

### 11.2 Other test obligations

- **Unit tests:** the 4 Lane C `@Test` cases run as part of `scripts/swift-test.sh`. Test count goes 491+ → 495+. These DO run on PR CI (corrected from v1 of plan).
- **Lane B B1 (true Bluetooth toggle):** demonstrated manually with founder during Gate 2 sign-off; result captured in PR description. Lane B' (programmatic device flip) demonstrated separately if the spike confirms feasibility.
- **No benchmarks.** Scenarios have wall-clock budgets but are not performance tests.

## 12. Blast radius & rollback

**Modules touched:**
- `EnviousWisprAudio` (`AudioCaptureProxy.swift`)
- `EnviousWisprASR` (`ASRManagerProxy.swift`)
- `EnviousWisprPipeline` (`WhisperKitPipeline.swift`, `TranscriptionPipeline.swift`)
- `EnviousWispr` (`App/EnviousWisprApp.swift` — DEBUG endpoint listener)
- `EnviousWisprTests` (new V2/ subdirs under Pipeline, App, Services)
- `UITests` (Python harness + SCENARIOS.md)

**Modules NOT touched:**
- `EnviousWisprCore` — no public type changes
- `EnviousWisprPostProcessing` — out of scope
- `EnviousWisprLLM` — V4's territory
- Any view file — no UI change

**Rollback:** revert the squash commit. Production behavior unchanged because everything DEBUG-only. Lane C tests removed. Worst case, future Claude sessions don't have the seams; they re-add them.

## 13. Ship criteria

- [ ] `scripts/swift-test.sh` passes (495+ tests, including 4 new V2 invariants on PR CI)
- [ ] `swift build -c release` exit 0, AND release binary symbol grep confirms zero `forceStallRemainingBuffers` / `forceConnectionTerminationNow` / `forceCancelNow` / `EW_FAULT_INJECTION` / `fault-token` symbols leak. Verified via `nm $(swift build -c release --show-bin-path)/EnviousWispr | grep -E "forceStall|forceConnection|forceCancel|EW_FAULT"` returning empty.
- [ ] Per-mechanism red/green demonstrated for at least 7 scenarios (one per family). Evidence in `.validation/runs/`.
- [ ] Lane B B1 (true Bluetooth toggle) demonstrated manually with founder. Evidence in PR description.
- [ ] Spike result on B1' (programmatic default-device flip via `AudioObjectSetPropertyData`): documented in PR; if feasible, B1' added to Lane A; if not, deferred with one-line reason.
- [ ] Codex grounded review pass (re-run after this revision per workflow §1 step 6 — substantial revisions warrant re-check)
- [ ] Codex code-diff review clean (3 rounds max)
- [ ] Council pass on this revised plan (1 round if reviewers want a re-check; otherwise current sign-offs stand)
- [ ] Zero em-dashes / en-dashes in new code/docs (verified by grep)
- [ ] Architecture DoD satisfied (LARGE tier touches `Sources/` but adds no new types or modules; AppState count stays ≤19)
- [ ] Bible §6.1 V2 row updated PLANNED → SHIPPED on merge
- [ ] Issue #291 closed with reference to PR

## 14. Open questions

For Gate 2 sign-off:

1. **Shape A (one bundled PR) vs Shape B (split, with PR-1 carrying its own UAT path).** Plan defaults to A. Confirm.
2. **B1' programmatic device flip spike.** OK to spend ~30 min during build to confirm whether `AudioObjectSetPropertyData` triggers the same code path as physical BT toggle? If yes, B1' joins Lane A and reduces founder dependency. If no, only B1 remains.
3. **Backend-switch C3 invariant precision.** Plan codifies "rejected without canceling recording" per current `PipelineSettingsSync.swift:86-98` behavior. If you want to change this product behavior (allow graceful switching mid-record), that's a separate issue, NOT V2 scope. Confirm acceptance.
4. **Lane A endpoint mechanism.** Plan picks DEBUG-only localhost endpoint over `defaults write` polling and `DistributedNotificationCenter`. Reviewers all agreed localhost is right with tight gating. Endpoint constraints listed in §3.5. Confirm.
5. **NG10: no fake `WhisperKitBackend` for testing.** Means C6-equivalent (zombie recovery on WhisperKit) is NOT in V2. Codex grounded review confirmed the fake doesn't exist (`PreWarmThrowsTests.swift:7-13`). Plan files this as a follow-up issue rather than blocking V2 on building the fake. Confirm.
6. **NG7: paste cascade explicitly out of V2 scope.** Plan acknowledges V2 does not fully cover heart path because paste is excluded. paste_failed cluster (V1a §6.5) gets its own follow-up issue. Confirm.

## 15. Related

- Parent epic: `docs/feature-requests/issue-319-2026-04-18-q2-hardening-epic.md` §19 (V2 plan section)
- V1 closure: `docs/audits/2026-04-30-v1a-cold-path-telemetry.md` (sets the precedent that production telemetry can replace synthetic suites where applicable)
- Codex grounded review: `docs/audits/2026-04-30-v2-grounded-review.txt`
- Council reviews (in this session, agent transcripts): GPT 5.5 + Gemini 3.1 Pro
- Existing UAT pattern: `Tests/UITests/wispr_eyes.py` `test_recording()`, `test_ptt()`, `record_tts()`, `check_recording_state()`
- Reference test patterns: `Tests/EnviousWisprTests/Pipeline/HeartPathTelemetryEmitterTests.swift` (R5/PR #511), `HeartPathIntegrationTests.swift:70-128` (cancellation), `HeartPathTelemetryWiringTests.swift:219-274` (dedup-survives-stall)
- Architecture rules: `.claude/rules/architecture-rules.md` § Anti-God-Object (concrete-collaborator ceiling)
- Dependency rule: `.claude/knowledge/architecture.md` § Module dependency direction
- m13v public comment: issue #291 thread, 2026-04-18 (independently aligned with our split-by-mechanism approach)

---

## Checklist for the plan author

- [x] Sections 4-9 filled
- [x] Every new (DEBUG) member has a row in §4
- [x] Every new failure mode has a row in §7
- [x] No new persisted fields → §4 legacy data row says "DEBUG flags in-memory only; per-launch token file deleted on exit"
- [x] Fallback audit (§9) explicitly states no fallback branches introduced
- [x] File paths in §10 reference existing files (verified by grep before plan finalized — `AudioCaptureProxy.swift`, `ASRManagerProxy.swift`, `WhisperKitPipeline.swift`, `TranscriptionPipeline.swift`, `EnviousWisprApp.swift`, `wispr_eyes.py` all exist)
- [x] Testing section names actual test files to be added or modified
- [x] All three reviewers' PIVOTs absorbed: A5 dropped, stall moved to AudioCaptureProxy, internal+@testable instead of package, real XPC client paths, Lane C rewritten to actual owners, Lane A endpoint replaces UserDefaults polling, no-CI corrected to apply only to Lane A/B (Lane C runs on PR CI), self-test discipline reframed per-mechanism-red/green not per-scenario-regression-revert
- [x] Stored property in type body (NOT in extension) per GPT correction

## Checklist for the council reviewer (re-run after revision)

- [ ] Are the absorbed pivots correctly applied? Specifically: stall on AudioCaptureProxy not pipelines, ASRManagerProxy not XPCServiceClient, internal not package, A5 dropped, Lane C 4 invariants on actual owners.
- [ ] Endpoint design (§3.5): is the gating + per-launch token model sufficient for security in DEBUG, or does even DEBUG-only localhost binding warrant Unix domain socket?
- [ ] Lane C C3 backend-switch invariant: is "rejected without canceling recording" the right invariant per current code, or should V2 require graceful switching?
- [ ] B1' spike: is `AudioObjectSetPropertyData` likely to trigger same code path as physical BT toggle, or is the codec-transition mechanism fundamentally different?
- [ ] Per-mechanism red/green vs per-scenario red/green: is the GPT-suggested reframe (one demonstration per family in PR; no ongoing regression+revert) sufficient anti-theater discipline?
