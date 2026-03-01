# Code Audit Action Plan — 2026-03-01

Comprehensive 4-agent audit + Gemini review. Priorities ordered by user-facing impact.

## Priority 1: Prevent Data Loss & Silent Failures

### 1.1 Emergency teardown partial transcription
- **File**: `Audio/AudioCaptureManager.swift:593`
- **Problem**: `emergencyTeardown()` zeroes `capturedSamples` on device disconnect. A 10-minute recording is silently discarded.
- **Fix**: Before clearing samples, snapshot the buffer and hand it to the pipeline for partial transcription. Even a messy partial transcript is better than nothing.
- **Agent**: `audio-pipeline`

### 1.2 Fail loudly on device switch
- **File**: `Audio/AudioCaptureManager.swift:111`
- **Problem**: `setInputDevice()` logs `AudioUnitSetProperty` failure but doesn't throw. Recording silently proceeds on default (laptop) mic — user gets garbage transcript and blames app quality.
- **Fix**: Throw or surface a user-visible warning: "Audio Device 'X' Disconnected."
- **Agent**: `audio-pipeline`

## Priority 2: LLM Resilience

### 2.1 Add total timeout ceiling for Gemini SSE streaming
- **Files**: `LLM/LLMNetworkSession.swift:15`, `LLM/GeminiConnector.swift:94`
- **Problem**: `timeoutIntervalForRequest = 60` only covers gaps between data. No `timeoutIntervalForResource` — a slow response can run forever.
- **Fix**: Set `timeoutIntervalForResource = 180` (3 min ceiling) on the session config.
- **Agent**: `build-compile` or direct fix (1 line)

### 2.2 Add retry/backoff to LLM connectors
- **Files**: All 3 cloud connectors (`OpenAIConnector`, `GeminiConnector`, `OllamaConnector`)
- **Problem**: 429/500/network errors surface directly to user with zero retry.
- **Fix**: Simple exponential backoff — 1-2 retries with 1s/3s delays for transient errors (429, 5xx, network timeout). Don't retry 4xx auth errors.
- **Agent**: `audio-pipeline` (LLM domain) or new utility

### 2.3 Sanitize API error strings
- **Files**: `OpenAIConnector.swift:56`, `GeminiConnector.swift:197`, `OllamaConnector.swift:74`
- **Problem**: Full HTTP response bodies in user-facing error strings. Raw JSON is unprofessional.
- **Fix**: Map to user-friendly messages: "AI service temporarily unavailable" / "API key invalid" / "Model not found". Truncate raw body to max 200 chars for debug log only.
- **Agent**: `quality-security` or `macos-platform` (UX)

## Priority 3: Unified Error Handling Strategy

### 3.1 Design error classification system
- **Problem**: Scattered silent failures (#1.2, VAD swallowing errors, customWordStore try?) and user-hostile raw errors — no consistent strategy.
- **Fix**: Define error classes and consistent UI treatment:

| Error Class | Example | UI Treatment |
|-------------|---------|-------------|
| **Transient Network** | LLM 429/500, timeout | Auto-retry, then toast: "AI service busy, retrying..." |
| **Device Error** | Mic disconnect, device switch fail | Recording stops, banner: "Audio Device Disconnected" |
| **Config Error** | Invalid API key, missing model | Settings highlight, clear message |
| **Internal** | VAD failure, file I/O error | Log to debug, degrade gracefully |

- **Agent**: `macos-platform` (UI) + `quality-security` (error propagation)

## Priority 4: Main Thread Performance

### 4.1 VAD monitor main actor pressure
- **File**: `Pipeline/TranscriptionPipeline.swift:616`
- **Problem**: `Array(audioCapture.capturedSamples[...])` runs every 100ms on `@MainActor`. Inner catch-up loop serializes all buffered chunks without yielding.
- **Fix**: Move VAD processing to a background actor or use `AsyncStream` to decouple from main actor reads.
- **Agent**: `audio-pipeline`

## Priority 5: Crash Prevention & Robustness

### 5.1 Replace force-unwrap in TaskGroup
- **File**: `Pipeline/TranscriptionPipeline.swift:660`
- **Problem**: `group.next()!` — safe today but fragile under refactoring.
- **Fix**: `guard let result = try await group.next() else { throw ASRError.streamingTimeout }`
- **Agent**: direct fix (1 line)

### 5.2 Guard concurrent stopAndTranscribe
- **File**: `Pipeline/TranscriptionPipeline.swift:229`
- **Problem**: Two rapid hotkey events while `state == .recording` could both pass the guard.
- **Fix**: Add `isStopping` flag or transition to `.stopping` state before first await.
- **Agent**: `audio-pipeline`

### 5.3 CustomWordStore Sendable correctness
- **File**: `PostProcessing/CustomWordStore.swift`
- **Problem**: `Sendable` class with unserialized file I/O. Thread-safe by accident (single MainActor caller), not by contract.
- **Fix**: Annotate `@MainActor` instead of `Sendable`, or serialize with an actor.
- **Agent**: `quality-security`

## Priority 6: Polish & Feedback

### 6.1 VAD processChunk error logging
- **File**: `Audio/SilenceDetector.swift:130`
- **Problem**: VAD errors silently swallowed — auto-stop degrades with no visibility.
- **Fix**: Log VAD errors at `.verbose` debug level.
- **Agent**: `audio-pipeline`

### 6.2 CustomWordStore user feedback
- **File**: `App/AppState.swift:469,472`
- **Problem**: `try?` on add/remove gives no user feedback on failure.
- **Fix**: Surface error to UI (toast or inline message).
- **Agent**: `macos-platform`

### 6.3 TranscriptStore.deleteAll() consistency
- **File**: `Storage/TranscriptStore.swift:98-106`
- **Problem**: First-error-wins leaves disk/memory inconsistent after partial delete.
- **Fix**: Collect all errors, clear in-memory state only after full disk success.
- **Agent**: direct fix

## Deferred (Not Blocking v1)

These are real findings but not worth fixing before launch:

| Finding | Why Defer |
|---------|-----------|
| Dead code (4 items: TranscriptSegment, usePrefixLanguageToken, manufacturer, inputChannelCount) | 4 items in 10.8K lines is a rounding error |
| TranscriptStore.loadAll() full disk scan | Few hundred files = instant. Optimize when data shows otherwise |
| stopAndTranscribe() 224 lines | Style preference, not a bug. Well-commented, sequential logic |
| recoverFromCodecSwitch() duplication | Technical debt, not user-facing |
| Loose dependency version constraints | Monitor on updates, no upper-bound pin needed yet |
| AppState.init() 127 lines | All wiring in one place is acceptable for this codebase size |
| LLMModelDiscovery uses URLSession.shared | Minor inconsistency, no user impact |
| KeychainManager permission re-verification | Defense-in-depth, directory is already 0700 |

## Documentation Fixes (DONE — 2026-03-01)

- [x] gotchas.md: Removed resolved WhisperKitBackend @preconcurrency gotcha
- [x] file-index.md: Added FillerRemovalStep.swift, updated counts (63→64 files, ~10,856 lines)
- [x] MEMORY.md: Fixed feature count (7→8, added #21)
