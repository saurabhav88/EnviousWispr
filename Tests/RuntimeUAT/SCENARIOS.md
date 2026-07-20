# V2 Fault-Injection Scenarios

Standing menu of runtime fault scenarios for EnviousWispr (issue #291). On-demand only — no CI integration. Each scenario has a documented one-line negative control: a tiny code change that should make the scenario fail. PR demonstration runs per-mechanism red/green for at least seven families.

## Prerequisites

1. **Build and launch via `wispr-rebuild-debug`.** The skill compiles `-c debug` (so `#if DEBUG` seams are present) and launches `build/EnviousWispr Local.app` with `EW_FAULT_INJECTION=1` set via `open --env`. The `DebugFaultEndpoint` only starts when both gates are satisfied (DEBUG build + env var). The shipped release build does NOT contain the V2 endpoint — by design.
2. `Tests/RuntimeUAT/` requirements (Accessibility permission, mic, OpenAI key for TTS) — see `README.md`.
3. Per-launch token written by the app at `~/Library/Logs/EnviousWispr/fault-token-<pid>` (`0600` perms).

Drive the harness from repo root:

```bash
python3 Tests/RuntimeUAT/faultInjection.py list             # print menu
python3 Tests/RuntimeUAT/faultInjection.py run A3_asr_xpc_kill
python3 Tests/RuntimeUAT/faultInjection.py query            # current state
```

Or via Python:

```python
import sys; sys.path.insert(0, "Tests/RuntimeUAT")
from wispr_eyes import list_scenarios, run_scenario
list_scenarios()
run_scenario("A3_asr_xpc_kill")
```

## Index by symptom

| Symptom (something broke in production?) | Scenario | Mechanism family |
|---|---|---|
| Real OS-level audio interruption (BT codec switch, Zoom mic-grab, device sleep/wake) | See `docs/LANE_B_AUDIO_TESTS.md` (HITL only — not synthetic-viable, see `docs/audits/2026-05-02-v2-synthetic-viability-codex.txt`) | hardware/HITL |
| Dictation lost (or pipeline stuck) after ASR service crash | A3_asr_xpc_kill | xpc |
| Cancel mid-record leaks task / state | A2_force_cancel | timing |
| Rapid stop/start corrupts state | A1_rapid_stop_start | timing |
| Live setting toggle doesn't apply mid-record | A6_settings_storm | settings |
| Orphan helpers after force-quit | A7_app_quit | app-quit |
| Cancel during Parakeet model load lingers | A8a_cancel_during_parakeet_load | model-load |
| Cancel during WhisperKit model load leaves state inconsistent | A8b_cancel_during_whisperkit_load | model-load |
| Switching backend mid-record aborts active recording | A9_backend_switch_mid_record | backend-switch |
| BT codec switch mid-record corrupts state | B1_bluetooth_route_flip (founder-required) | bt-route |
| Dead/zombie mic delivers all-zero audio (#1317, FIXED) | bench moved OFFLINE -> `docs/bench-offline/` (gitignored) | dead-mic |

## Index by scenario name

### A1_rapid_stop_start (Lane A — timing/cancel)
Backends: both. Budget: 3s. Mechanism: timing.

Three rapid Start→Stop cycles via the menu, 100ms apart. Pipeline must reach a terminal state within budget without leaking VAD monitor tasks or audio-engine state.

**Negative control:** remove the recording-start debounce in `HotkeyService` / pipeline-start guards. The double-toggle no longer serializes; rapid restart corrupts streaming ASR state.

### A2_force_cancel (Lane A — timing/cancel)
Backends: both. Budget: 2s. Mechanism: timing.

Start recording, wait 1s, dispatch `force_cancel` via the DEBUG endpoint. Pipeline reaches `.idle` within 2s. Equivalent in effect to a user pressing the cancel hotkey mid-record, but deterministic.

**Negative control:** remove cancellation cleanup in `TranscriptionPipeline.cancelRecording()` — cancelled task lingers, audio capture not stopped, asserted via `assert_no_zombie()`.

### A3_asr_xpc_kill (Lane A — XPC)
Backends: parakeet (WhisperKit ASR is in-process). Budget: 30s. Mechanism: xpc.

Start recording, wait 1s, `kill -9` the real `EnviousWisprASRService` process (`force_xpc_process_kill` — a genuine crash, not `force_xpc_kill`'s connection-only invalidation, which leaves the helper alive and the model resident and never exercises the slow reload path). #1707: the pipeline salvages the already-captured audio — it reconnects through a freshly-respawned process (cold model reload included) and decodes rather than discarding the dictation, within the poll window (15s, deliberately wider than the production recovery deadline of 8.0s plus decode/finalize time). `assert_no_zombie` confirms no orphan ASR helper. `salvage_succeeded` reads the kernel's own precomputed recovery-outcome log line, not the final pipeline state — gates on whether the recovery mechanism itself succeeded, not on whether the captured audio also happened to be VAD-detectable (a separate, test-environment-dependent concern); a build that regressed to discarding the dictation on crash raises `AssertionError`, not a silent pass.

**Negative control:** remove `ASREngineAdapter.recoverFromASRInterruption()` / revert #1707 (`RecordingSessionKernel`'s ASR-interruption salvage tail). The dictation is discarded instead of salvaged; `salvage_succeeded` is `False` and the scenario raises.

**A4_audio_xpc_kill and A5_proxy_buffer_drop_watchdog were removed (#1543)** — both drove the deleted host-side audio-capture proxy DEBUG commands, which cannot exist now that capture runs in-process. Real OS-level audio interruption (BT codec switch, Zoom mic-grab, device sleep/wake) is covered by the HITL Lane B matrix (`docs/LANE_B_AUDIO_TESTS.md`); the capture-stall watchdog is exercised in-process by the #1317 zero-fill proof-bench.

### A6_settings_storm (Lane A — settings)
Backends: both. Budget: 30s. Mechanism: settings.

During an active recording, navigate to AI Polish settings. Toggle `wordCorrectionEnabled` and `fillerRemovalEnabled`. Recording continues; toggles apply via `PipelineSettingsSync` live-sync.

**Do NOT toggle:** frozen-at-start fields (`autoCopyToClipboard`, `restoreClipboardAfterPaste`, `vadAutoStop`, `vadSilenceTimeout`, `vadSensitivity`, `vadEnergyGate`, `languageMode`, `useStreamingASR`). (`noiseSuppression` was the heaviest live-sync — cancelled the active recording and rebuilt the engine — but the toggle was removed in #734 because the rebuild path was structurally hostile to the heart and Apple Voice Processing was empirically unhelpful for ASR.)

**Negative control:** remove `wordCorrectionEnabled` live-sync from `PipelineSettingsSync.handleSettingChanged`. Setting takes no effect mid-record; observable via post-recording transcript word handling.

### A7_app_quit (Lane A — app-quit)
Backends: both. Budget: 10s. Mechanism: app-quit.

During an active recording, invoke `Quit EnviousWispr` (Cocoa terminate via the menu). `applicationWillTerminate` runs, cleans up the ASR XPC helper + audio engine. Next launch starts clean — no orphan helper processes from `pgrep -x EnviousWisprASRService`.

**Out of scope:** raw `SIGTERM`, `kill -9`, force-quit. No `signal` / `DispatchSourceSignal` handler exists in the codebase; A7 validates only the Cocoa terminate path.

**Negative control:** remove `applicationWillTerminate` cleanup in `AppDelegate`. Orphan helpers persist; `assert_no_zombie` returns non-empty `orphan_pids`.

### A8a_cancel_during_parakeet_load (Lane A — model-load)
Backends: parakeet. Budget: 3s. Mechanism: model-load.

Start recording while Parakeet model is loading; immediately dispatch `force_cancel`. Pipeline reaches `.idle` within 3s. `modelLoadTask?.cancel()` propagates cleanly.

**Negative control:** remove `modelLoadTask?.cancel()` at `TranscriptionPipeline.swift:1091`. Cancelled load task lingers; pipeline state may briefly flicker to `.recording` after cancel.

### A8b_cancel_during_whisperkit_load (Lane A — model-load)
Backends: whisperKit. Budget: 3s. Mechanism: model-load.

Start recording while WhisperKit prepare is running; dispatch `force_cancel`. Pipeline state reaches `.idle` and remains coherent. **Documented limitation:** WhisperKit's `prepare()` is awaited directly with no held task, so the underlying load may complete in the background after state has flipped — A8b validates state-unwind only, not true cancellation. True cancellation requires a Sources change to add a cancel API on the prepare path; tracked as a follow-up.

**Negative control:** remove the WhisperKit prepare-state-flip at `WhisperKitPipeline.swift:1078-1084`. State stays inconsistent (e.g., `.transcribing` after cancel).

### A9_backend_switch_mid_record (Lane A — backend-switch)
Backends: both. Budget: 2s. Mechanism: backend-switch.

During an active recording, attempt to flip `selectedBackend` via the Speech Engine settings tab. The `PipelineSettingsSync.handleSettingChanged` guard at `:86-98` rejects the switch; recording continues uninterrupted. Companion deterministic invariant in Lane C `BackendSwitchGuardTests`.

**Negative control:** remove `if parakeetActive || whisperKitActive { break }` in `PipelineSettingsSync.handleSettingChanged(.selectedBackend, …)`. Active recording aborts on backend toggle.

**A10_audio_start_wedge_retry was removed (#1543)** — it drove the deleted
XPC line-death start-retry (#1194), which cannot occur with capture in-process
(no XPC line to wedge).

### A11_asr_kill_mid_model_load (Lane A — model-load, #1388)
Backends: parakeet. Budget: 30s. Mechanism: model-load.

Kill the ASR XPC connection while the model is LOADING — not mid-stream (A3's shape) and not a user cancel (A8a's shape). Sequence: `force_xpc_kill` drops the resident model; a record press then drives the cold sessionless warm-up (`ensureEngineWarm(.coldPress)`) with a real in-flight `loadModel`; a second `force_xpc_kill` lands ~0.4s into it. The #1388 step-1 contract requires the invalidation handler to resume the pending load continuation with the typed transport error, so the warm-up reaches a terminal outcome and the adapter's one-shot transport retry reconnects to the respawned helper. Verdict: pipeline reaches a terminal token, no helper leak, the recovery dictation PASSES, and the wedge guard did NOT fire (`wedge_guard_fired == False` — the kill produces a typed error, not a detector-owned silence).

**Negative control:** remove the `pendingLoadCompletion` resume from `ASRManagerProxy`'s invalidation handler — the warm-up await hangs, `isLoadInFlight` never clears, readiness pins at `warming`, and every subsequent press is blocked (the recovery dictation fails). This is precisely the pre-#1388 production defect (119 of 126 wedge fires with no terminal outcome).

### B1_bluetooth_route_flip (Lane B — bt-route, founder-required)
Backends: both. Budget: 15s. Mechanism: bt-route.

Founder physically toggles AirPods (or other BT input) power off/on during an active recording. Pipeline either continues with new route or terminates cleanly via the existing capture-session-interruption path. No pipeline lockup.

**Founder action required:** the harness prompts `"Founder action: toggle AirPods power off, wait 2s, power on. Press Enter when done."` — physically toggle the device. Re-run with `founder_present=True`.

**Optional Lane B' (programmatic device flip):** `AudioObjectSetPropertyData` on `kAudioHardwarePropertyDefaultInputDevice` may exercise the same code path. Pending the spike documented in the V2 plan §3.2; if feasibility is confirmed, B1' joins Lane A and B1 becomes release-time-only.

**Negative control:** remove the BT route handler in `AudioDeviceManager` / capture-session-interruption flow. Recording behaves incorrectly on real BT toggle (audio cuts out, pipeline stuck).

### Dead-mic scenarios (Z1-Z3, #1317) — MOVED OFFLINE

The #1317 dead-mic proof bench (`Z1_all_zero_from_start`, `Z2_valid_then_all_zero`,
`Z3_bounded_zero_then_restore`, plus its zero-fill trial machinery, manifest/identity
gates and log-cursor oracles) was moved out of the tracked tree on 2026-07-11. It was
never a CI gate, and it needs a rethink rather than a patch (founder call).

A complete, self-contained working copy — the exact code that validated the fix —
lives GITIGNORED at **`docs/bench-offline/`**, with `docs/bench-offline/README.md`
covering how to run it, the A/B result that proves the #1317 fix, the two checks that
are known stale, and what a rewrite should do differently.

The DEBUG all-zero injector inside the app (`DebugFaultEndpoint`, compiled out of
release) is untouched and still ships, so the offline bench still drives a real fault.

## Wire protocol

The DEBUG endpoint accepts text, line-delimited:

```
<token>\n
<command>\n
```

Reply: `OK\n`, `OK <state>\n` (for `query_state`), or `ERR <reason>\n`.

Token: per-launch random hex written by the app to `~/Library/Logs/EnviousWispr/fault-token-<pid>` with `0600` perms. The app deletes this file on `applicationWillTerminate`.

Fixed command set (no arbitrary RPC):

| Command | Effect |
|---|---|
| `force_cancel` | Invoke `forceCancelNow()` on the active backend's pipeline |
| `force_xpc_kill` | Invalidate `ASRManagerProxy` connection mid-stream |
| `query_state` | Return current pipeline + backend state (one line, no side effects) |
| `force_zero_fill(mode,N,trialID)` | #1317: arm the DEBUG all-zero injector in-process on `AudioCaptureManager` (#1543). `mode` ∈ {`zero_from_start`, `zero_after_samples`, `zero_next_samples`, `disarmed`}; `N` = LIVE-sample threshold/budget; `trialID` correlates the status query. |
| `query_fault_status(trialID)` | #1317: read the in-process fault status (injector fields + manager source-incarnation). Fails CLOSED to `ERR` on an absent manager or trial-id mismatch. `armed` is not evidence of `hit`. |

(#1543 removed `force_proxy_buffer_drop`, `force_audio_wedge_start`, and `force_audio_xpc_kill` with the audio-capture boundary.)

## Adding a new scenario

1. Add a `package`-access DEBUG seam on the type that owns the behavior. Gate everything in `#if DEBUG`.
2. Add a command to the fixed set in `DebugFaultEndpoint.handle(request:)`.
3. Add a `@scenario(...)`-decorated function in `faultInjection.py`. Document its negative control.
4. Add a row to "Index by scenario name" above. Add an entry to "Index by symptom" if the scenario maps to a known production failure mode.
5. Demonstrate red/green at PR time: revert the negative control, scenario fails. Restore, scenario passes.
