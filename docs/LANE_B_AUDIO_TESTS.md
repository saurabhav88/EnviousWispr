# Lane B — Audio Heart-Path Human-In-The-Loop Tests

Manual test checklist for OS-level audio interruption scenarios that the synthetic V2 harness (Lane A) cannot honestly reproduce.

## Why this exists

V2's automated Lane A scenarios test our own code: state machines, cancellation paths, settings live-sync, app-lifecycle cleanup, our XPC service kills. These run honestly via the `DebugFaultEndpoint`.

OS-level audio interruption is different. AVFoundation, CoreAudio HAL, and Bluetooth profile transitions cannot be faithfully simulated from inside the app. `NotificationCenter.post(.AVAudioEngineConfigurationChange)` would invoke our handler but `AVAudioEngine.isRunning` and `AVCaptureSession.isInterrupted` continue to report healthy state because the framework's internal C++ state never actually changed. A test built that way is a more sophisticated lie than the original `force_stall`. Codex grounded review (2026-05-02, see `docs/audits/2026-05-02-v2-synthetic-viability-codex.txt`) confirmed: the host-process `DebugFaultEndpoint` cannot reach the service-process audio source observers at all. GPT and Gemini independently reached the same verdict.

These scenarios run on real hardware with real OS behavior, with the founder driving. No deception about what's being tested.

## When to run

- Before any release that touches `Sources/EnviousWisprAudio/` (route resolver, capture manager, sources, device manager).
- Before any release that changes XPC audio service lifecycle or supervisor behavior.
- After macOS minor or major version updates.
- When Sentry shows new `AudioCaptureProxy XPC interruptionHandler fired`, `Audio onEngineInterrupted`, or `Audio engine interrupted` events accumulating in production environment.
- Quarterly soak: pick one scenario at random, run it, file the report.

There is no CI gate. There is no schedule. There is a checklist and a reporting template.

## Setup

Before each run, capture in your run log:

| Field | Value |
|---|---|
| Date / time | (UTC) |
| Tester | (you) |
| Commit SHA | `git rev-parse HEAD` |
| Build ID | from `EnviousWispr Dev v...` in About menu |
| macOS version | `sw_vers -productVersion` |
| Mac model | `system_profiler SPHardwareDataType \| grep "Model Name"` |
| Microphone | (Built-in / AirPods / external USB) |
| Bluetooth device | (model + firmware if known) |
| ASR backend | Parakeet (Fast English) / WhisperKit (Multi-Language) |
| Sentry environment | production / staging / dev |

## Fixed spoken script

Use the same script every run so degraded segments can be compared across runs:

> "Start marker. The quick brown fox jumps over the lazy dog. EnviousWispr heart path test. Numbers one two three four five. End marker."

If the scenario calls for continuous speech across an interruption, repeat the script.

## Global invariants — every scenario must satisfy ALL of these

- App does not wedge. Recording can always be stopped.
- UI returns to idle or a clear recoverable error state.
- User receives a transcript for the audio that WAS captured (degraded segments are acceptable; total loss is not).
- No unrecoverable spinner.
- No app crash.
- If audio is genuinely unavailable (mic taken by another app, HAL gave up), failure is explicit and the user is told.
- Sentry / `~/Library/Logs/EnviousWispr/app.log` contains useful breadcrumbs.

## Scenarios

### B1 — Bluetooth HFP/A2DP profile flip mid-recording

**Trigger**: physical Bluetooth headset (AirPods, BeatsX, similar HFP-capable headset).

**Steps**:
1. Pair Bluetooth headset, set as system default input. Confirm via System Settings → Sound → Input.
2. Start EnviousWispr recording (lock-record via double Right-Cmd or your configured PTT).
3. Speak the fixed script, continuously.
4. Open Zoom (or another HFP-grabbing app). Start a meeting or test call. This forces HFP handoff.
5. Continue speaking through the codec switch.
6. Leave the Zoom call. Headset returns to A2DP if it does (some don't until reconnect).
7. Continue speaking.
8. Stop recording.

**Expected**: app survives both transitions. Transcript may have degraded or missing audio during the codec-switch window; that is acceptable. App must not wedge or crash. Next dictation cycle must work.

**Negative observation worth filing**: pipeline stays in `recording` indefinitely after route change; or app crashes; or next dictation fails.

### B2 — Zoom mic coexistence

**Trigger**: Zoom client (any version), any audio device.

**Steps**:
1. Start EnviousWispr recording.
2. Speak the fixed script.
3. Open Zoom. Join a meeting (test meeting fine) or open Audio settings.
4. Toggle Zoom mute / unmute.
5. Change Zoom selected microphone if possible.
6. Continue speaking through each toggle.
7. Stop EnviousWispr recording.

**Expected**: same as B1. App survives, transcript returned.

### B3 — Discord voice-channel coexistence

**Trigger**: Discord client.

**Steps**:
1. Start EnviousWispr recording.
2. Join Discord voice channel.
3. Speak the script.
4. Toggle mute / deafen.
5. Leave channel.
6. Stop EnviousWispr recording.

**Expected**: same as B1.

### B4 — System default input flip mid-recording

**Trigger**: System Settings → Sound → Input, OR `SwitchAudioSource -s "Other Mic"` if installed.

**Steps**:
1. Start EnviousWispr recording with Built-in mic selected as default.
2. Speak the fixed script.
3. Switch system default input to a different mic (USB, second Built-in, AirPods).
4. Continue speaking.
5. Switch back.
6. Stop recording.

**Expected**: if app pins the device at recording start, transcript continues from the original mic and the switch is invisible to the recording (the change applies to next recording). If app follows the system default, transcript may have a gap at switch but app survives. Either is acceptable; both must satisfy the global invariants.

### B5 — Spotify (or other audio playback) starts mid-recording

**Trigger**: Spotify or any audio playback app.

**Steps**:
1. Start EnviousWispr recording.
2. Speak the script for ~3 seconds.
3. Start Spotify playback (any track).
4. Continue speaking for ~3 seconds.
5. Pause Spotify.
6. Stop recording.

**Expected**: playback should not affect input capture (output devices change but input is independent). App survives, transcript returned.

## Reporting

For each run, file a GitHub issue using the template below or create the issue via:

```bash
gh issue create --label "lane-b-run" --title "Lane B run: B1 BT route flip — $(date +%Y-%m-%d)" --body-file .github/lane-b-template.md
```

### Run log template

```markdown
# Lane B Audio Heart-Path Run

**Date / time:**
**Tester:**
**Commit SHA:**
**Build ID:**
**macOS:**
**Mac model:**
**Mic / BT device:**
**ASR backend:**
**Sentry env:**

## Scenario(s) run

- [ ] B1 Bluetooth HFP/A2DP flip
- [ ] B2 Zoom coexistence
- [ ] B3 Discord coexistence
- [ ] B4 System default input flip
- [ ] B5 Audio playback during recording
- [ ] Other: ___

## Observed behavior

(What actually happened, in order. Include UI state, audio you heard, any error messages.)

## Transcript snippet

Paste the actual transcript produced. Mark missing or degraded segments with `[gap]` or `[degraded]`.

## Logs / artifacts

- [ ] `app.log` (last 500 lines, filtered for the run window)
- [ ] `bt-route.log` (if BT involved)
- [ ] Sentry event link (if any breadcrumb fired)
- [ ] Screen recording / screenshot (if visual issue)

## Verdict

- [ ] PASS — all global invariants satisfied
- [ ] PASS WITH DEGRADATION — invariants satisfied, transcript has acceptable degraded segment(s)
- [ ] FAIL — heart-path defect (file separately as `bug` + `P0` or `P1`)
- [ ] FAIL — limb defect (file separately as `bug` + appropriate severity)

## Notes
```

## What this is NOT

- Not a CI gate. CI cannot reproduce real audio hardware behavior.
- Not a release blocker checklist by default. Run before releases that touch the audio subsystem; otherwise opportunistic.
- Not a substitute for production telemetry. Sentry is the ongoing fault detection signal at our user count.
- Not exhaustive. New realistic scenarios get added as we discover them in real use.

## See also

- `Tests/RuntimeUAT/SCENARIOS.md` — Lane A automated scenarios for our own state machines.
- `docs/audits/2026-05-02-v2-synthetic-viability-codex.txt` — code-grounded analysis of why audio-stack interruption can't be honestly synthesized.
- `.claude/knowledge/v2-uat-bypass-2026-05-01.md` — the V2 systemic-failure cluster that triggered this rebucket.
