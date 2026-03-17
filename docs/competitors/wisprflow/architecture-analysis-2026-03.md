# WisprFlow v1.4.517 Architecture Analysis

**Date:** 2026-03-13
**Version analyzed:** v1.4.517
**Method:** Deep static analysis of bundle contents, IPC protocol reverse engineering, runtime observation

---

## Table of Contents

- [App Architecture](#app-architecture)
- [Audio Pipeline](#audio-pipeline)
- [ASR](#asr)
- [Feature Architecture (Thunk/Action Queue)](#feature-architecture-thunkaction-queue)
- [Error Handling (Multi-Layer Fallback)](#error-handling-multi-layer-fallback)
- [Swift Helper (Thin Native Bridge)](#swift-helper-thin-native-bridge)
- [Post-Processing Pipeline](#post-processing-pipeline)
- [Custom Words / Dictionary](#custom-words--dictionary)
- [Paste Mechanism](#paste-mechanism)
- [Platform & Distribution](#platform--distribution)
- [Competitive Implications for EnviousWispr](#competitive-implications-for-enviouswispr)

---

## App Architecture

| Property | Value |
|---|---|
| Framework | Electron 39.5.2 (Chrome 142) |
| Native bridge | Swift helper sidecar (NOT XPC) |
| IPC transport | Localhost HTTP stream, port 8969 |
| IPC format | JSON, types auto-generated via quicktype (TypeScript + Swift + C#) |
| Process count | 6+ (Electron multiprocess model) |
| Bundle size | ~437 MB |
| RAM usage | ~800 MB |
| Database | SQLite (`flow.sqlite`), 61 migrations (May 2024 -- March 2026) |

Key architectural decision: they chose a sidecar process over XPC. The Swift helper communicates with Electron via a localhost HTTP stream rather than Apple's XPC framework. This means no Mach-level crash isolation or memory isolation -- if the helper crashes, Electron must detect it via health monitoring and restart it.

---

## Audio Pipeline

Audio capture runs entirely in the Electron renderer process via Web Audio API, not native CoreAudio.

**Capture chain:**
1. `getUserMedia` with `exact: deviceId` constraint
2. Web Audio API `AudioWorklet` processes raw PCM
3. Opus encoding via `WebCodecs AudioEncoder`
4. Audio streamed as Opus chunks to backend

**getUserMedia options:**
```javascript
{
  echoCancellation: false,
  noiseSuppression: false,
  autoGainControl: false,
  channelCount: 1
}
```

**Device management:**
- `navigator.mediaDevices.ondevicechange` listener for hot-swap detection
- Exact `deviceId` constraint (no default device fallback)
- 8-second timeout warning on `getUserMedia` (they know it can hang on certain devices)

**System audio integration:**
- `shouldMuteAudio` flag for controlling system audio muting
- `AudioCodecChanged` IPC message from Swift helper monitors codec switches
- `AudioInterruptionEvent` IPC message from Swift helper monitors audio interruptions
- `IsMediaPlayingUpdate` detects active media playback

---

## ASR

| Property | Value |
|---|---|
| Primary location | Server-side (proprietary, NOT Deepgram / Whisper / AssemblyAI) |
| Primary transport | gRPC |
| Fallback transport | WebSocket |
| Audio format | Opus chunks |
| Local inference | ONNX Runtime via WebAssembly (see below) |
| Offline capability | Partial — likely local ONNX fallback |

**Dual ASR architecture:**
- Primary + fallback ASR paths run simultaneously
- Divergence scoring compares results from both paths
- `transcriptOrigin` field tracks whether transcript came from internal vs external path
- If primary fails or diverges too far, fallback result is used
- `usedFallbackAsr` / `fallbackAsrText` columns in SQLite suggest the fallback may be local ONNX inference

This is more sophisticated than simple try/catch -- they actively compare two transcript streams and score confidence.

### ONNX Runtime Discovery

Bundle contains ONNX Runtime compiled to WebAssembly:
- `ort-wasm-simd-threaded.jsep.mjs`
- `ort-wasm-simd-threaded.jsep.wasm`
- `ort-wasm-simd-threaded.mjs`
- `ort-wasm-simd-threaded.wasm`

This means WisprFlow has **local inference capability** running in the browser context. Possible uses:

1. **Local VAD (Voice Activity Detection)** for endpointing — detecting speech start/stop without a server round-trip
2. **Local fallback ASR** — explains the `usedFallbackAsr` / `fallbackAsrText` columns in their SQLite schema. Their "fallback ASR" may be a local ONNX model, not a second cloud service
3. **Local keyword/command detection** — recognizing wake words or control commands locally

This **revises the "100% cloud" assessment**. While their primary ASR is server-side, they appear to have a local inference safety net via ONNX Runtime WASM. This is architecturally significant — it means they are not fully dependent on network connectivity for basic functionality, and their dual-path ASR architecture may pit cloud against local rather than two cloud services against each other.

---

## Feature Architecture (Thunk/Action Queue)

WisprFlow uses a custom Redux-inspired Thunk system. This is NOT standard Redux Toolkit.

**Core files:**
```
src/thunk/
  Thunk.ts
  ThunkManager.ts
  ThunkScheduler.ts
  ThunkRegistrationQueue.ts
  ThunkLifecycleManager.ts

src/action/
  ActionExecutor.ts
  ActionScheduler.ts
```

**How it works:**
1. Each feature registers as a **Thunk** via `ThunkRegistrationQueue`
2. `ThunkScheduler` determines execution order
3. `MainThunkProcessor` or `RendererThunkProcessor` executes thunks in appropriate process
4. Actions flow through `ActionExecutor` with completion callbacks and per-action timeouts
5. `SelectorActionRegistry` maps state changes to downstream thunks (reactive pattern)
6. `StateUpdateTracker` tracks state mutations for debugging/replay

This validates our FeatureStep limb architecture -- they independently arrived at a similar "register features as pluggable units with lifecycle management" pattern.

---

## Error Handling (Multi-Layer Fallback)

WisprFlow has seven distinct fallback layers:

| Layer | Mechanism | Details |
|---|---|---|
| 1. Dual-path ASR | Divergence scoring | Two ASR streams compared in real-time |
| 2. Per-feature status enums | Granular failure taxonomy | e.g., Polish: `succeeded` / `long_text` / `short_text` / `timeout` / `error` / `cancelled` / `no_changes` / `not_editable` / `no_text` / `no_instructions` |
| 3. Action timeouts | Per-thunk deadline | Each action has its own timeout |
| 4. Audio recovery | State machine | States: `attempted` / `failed` / `succeeded` |
| 5. Helper health | Escalating response | `helper_not_ready` -> `helper_persistent_failure` -> `swift_giving_up` |
| 6. Network fallback | Transport downgrade | gRPC -> WebSocket -> HTTP |
| 7. Paste failure | Retry with detection | `PasteBlocked`, `CancelPaste`, `retry_last_text` |

The per-feature status enums are notable -- each feature has its own taxonomy of failure modes rather than generic error codes. This is a good model for our limb failure taxonomy.

---

## Swift Helper (Thin Native Bridge)

The Swift helper is deliberately thin. It handles ONLY what requires native macOS APIs:

- AX (accessibility) queries
- Paste / keyboard simulation
- Hardware info
- Audio interruption monitoring
- Focus change detection
- Sound playback

### IPC Message Types: Electron -> Swift (17 requests)

| # | Message Type | Purpose |
|---|---|---|
| 1 | GetFocusedApp | Query frontmost application |
| 2 | GetFocusedElement | Query focused AX element |
| 3 | SimulatePaste | Trigger Cmd+V paste |
| 4 | SimulateKeyPress | Simulate arbitrary keystrokes |
| 5 | GetHardwareInfo | Query device hardware details |
| 6 | StartAudioMonitor | Begin audio interruption monitoring |
| 7 | StopAudioMonitor | End audio interruption monitoring |
| 8 | PlaySound | Play system/custom sounds |
| 9 | GetAccessibilityStatus | Check AX trust |
| 10 | RequestAccessibility | Prompt for AX permissions |
| 11 | GetEditableState | Check if focused element is editable |
| 12 | GetSelectedText | Read currently selected text via AX |
| 13 | SetClipboard | Write to clipboard |
| 14 | GetClipboard | Read from clipboard |
| 15 | UpdateFeatureFlags | Push feature flags from Electron |
| 16 | HealthCheck | Ping for liveness |
| 17 | GetCurKeysDown | Query currently held modifier keys |

### IPC Message Types: Swift -> Electron (16 responses)

| # | Message Type | Purpose |
|---|---|---|
| 1 | FocusedAppChanged | Frontmost app switched |
| 2 | FocusedElementChanged | AX focus moved |
| 3 | AudioCodecChanged | Audio device codec switch detected |
| 4 | AudioInterruptionEvent | Audio session interruption |
| 5 | IsMediaPlayingUpdate | Media playback state changed |
| 6 | PasteComplete | Paste simulation finished |
| 7 | PasteBlocked | Paste was blocked (target not editable) |
| 8 | HealthCheckResponse | Liveness ack |
| 9 | HardwareInfoResponse | Hardware details |
| 10 | AccessibilityStatusResponse | AX trust status |
| 11 | EditableStateResponse | Editable state result |
| 12 | SelectedTextResponse | Selected text result |
| 13 | ClipboardResponse | Clipboard contents |
| 14 | KeysDownResponse | Current modifier keys |
| 15 | HelperError | Error from helper |
| 16 | HelperReady | Helper startup complete |

**Key design decisions:**
- Feature flags are pushed FROM Electron TO helper (single source of truth in Electron)
- Helper has Sentry crash reporting
- Health monitoring with escalating failure responses: `helper_not_ready` -> `helper_persistent_failure` -> `swift_giving_up`

---

## Post-Processing Pipeline

| Feature | Details |
|---|---|
| Smart Formatting | Dual path with fallback + divergence scoring (same pattern as ASR) |
| AI Auto-Edit | Separate from Auto-Polish; explicit user action |
| Auto-Polish | Automatic post-transcription polish with full status enum, undo support |
| Tone Matching | Per-app tone pairs (different tone for Slack vs Email vs Docs) |
| Style/Personalization | Contexts: `work` / `email` / `personal` / `other` with formality levels |
| Editing Strength | Adjustable parameter controlling how aggressively polish rewrites |

Auto-Polish status enum: `succeeded` | `long_text` | `short_text` | `timeout` | `error` | `cancelled` | `no_changes` | `not_editable` | `no_text` | `no_instructions`

---

## Custom Words / Dictionary

**Two-stage system:**
1. **ASR-level word boosting** -- server-side, sent with audio stream
2. **Post-ASR string replacement** -- client-side, after transcription

**SQLite Dictionary table schema:**

| Column | Purpose |
|---|---|
| `phrase` | The custom word/phrase |
| `lastUsed` | Timestamp of last use |
| `lastSeen` | Timestamp of last detection |
| `frequencyUsed` | Usage count |
| `frequencySeen` | Detection count |
| `manuallyAdded` | User-added vs auto-learned |
| `source` | Origin of the word |
| `platform` | Which platform added it |
| `isSnippet` | Text expansion trigger (like TextExpander) |
| `toReplace` | Replacement string for substitution rules |

**Additional capabilities:**
- Auto-learn mode (`shouldAutoLearnWords` flag) -- learns new words from usage
- Snippets -- text expansion via `isSnippet` flag (type abbreviation, get full expansion)
- Replace rules -- `toReplace` column enables ASR correction rules
- Cloud sync via Supabase
- CSV bulk import for enterprise deployment

---

## Paste Mechanism

| Component | Detail |
|---|---|
| Clipboard provider | `DelayedClipboardProvider` (`NSPasteboardItemDataProvider`) -- lazy clipboard writing |
| Paste simulation | `CGEvent`-based Cmd+V |
| Clipboard hygiene | Save/restore cycle with timing |
| Failure detection | Timeout-based failed paste detection |
| Privacy | `org.nspasteboard.ConcealedType` (password manager technique to hide from clipboard managers) |
| Target validation | AX focus tracking to verify target is editable |
| Modifier awareness | Tracks currently-held modifier keys during paste (`curKeysDown`) |

Their paste implementation is nearly identical to ours. The `DelayedClipboardProvider` pattern, `CGEvent` simulation, clipboard save/restore, and `ConcealedType` usage all match our approach.

---

## Platform & Distribution

| Property | Value |
|---|---|
| Platforms | macOS, Windows (C# IPC models), iOS, Android |
| Auto-updates | Squirrel (triggers after 1 hour inactivity) |
| Auth/backend | Supabase |
| Feature flags + analytics | PostHog |
| Billing | RevenueCat |
| Enterprise | MDM deployment supported |

The C# IPC models generated by quicktype confirm Windows uses the same JSON protocol with a C# native bridge instead of Swift.

---

## Competitive Implications for EnviousWispr

### Our Advantages

| Area | Why We Win |
|---|---|
| **Offline capability** | Still a major weakness. Their primary ASR is server-side, though ONNX WASM provides a local fallback (likely lower quality). Our on-device Parakeet/WhisperKit gives full-quality offline transcription. |
| **Privacy** | They capture screenshots for context. We don't. |
| **Native performance** | Swift vs Electron: ~437MB bundle, ~800MB RAM vs our ~50MB and <100MB RAM |
| **Crash isolation** | XPC > sidecar. Mach-level isolation vs HTTP stream reconnection |
| **Memory isolation** | XPC services have separate address spaces. Their sidecar shares user-space memory concerns |

### What We Should Adopt

| Pattern | Why |
|---|---|
| **Thunk registration** | Validates our FeatureStep limb architecture. Their pattern independently confirms pluggable feature registration is the right approach. |
| **Per-feature status enums** | Good model for our limb failure taxonomy. Each limb should have its own granular failure modes, not generic errors. |
| **Dual-path divergence scoring** | More sophisticated than our current try/catch. Consider for ASR and Smart Formatting. |
| **Audio interruption monitoring** | Proactive Swift helper -> app notification pattern. Our XPC service should do the same. |
| **shouldMuteAudio** | Confirmed: they mute system audio before BT recording to mask HFP quality degradation (not to prevent the switch — that's impossible). Mute-before-record + restore-after pattern with `wasPreviouslyMuted` tracking. |
| **Auto-learn dictionary** | Usage-frequency tracking and auto-learning from context is a strong UX pattern. |

### Neutral (Parity)

- Paste mechanism: nearly identical implementations
- AX focus tracking: both do it
- Custom Words two-stage approach: similar concept, different execution
