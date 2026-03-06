# WhisperKit Highway — Gap Analysis

> Reviewer: Gap Finder
> Date: 2026-03-06
> Scope: Master plan, system boundaries, phase map, risks/decisions, guardrails, parakeet patterns, 5 new skills

---

## Critical Gaps

### GAP-1: AppState deeply coupled to `pipeline.state` -- Phase 0 scope underestimated

**File:** `master-phased-implementation-plan.md`, Phase 0

**What it says:** Phase 0 modifies 3 files: `TranscriptionPipeline` (1-line conformance), `AppState` (activePipeline routing), `RecordingOverlayPanel` (observe overlayIntent). Claims "Zero visible change for users."

**What's actually true:** `AppState` currently accesses `pipeline.state` directly in at least 5 places:
- `AppState.swift:174` -- checks `if case .error = self.pipeline.state`
- `AppState.swift:290` -- checks `if pipeline.state == .recording`
- `AppState.swift:320` -- returns `pipeline.state` (computed property)
- `AppState.swift:373` -- switches on `pipeline.state`
- `AppState.swift:387` -- checks `.complete` and `.error`

Phase 0 says the overlay observes `overlayIntent` instead of `PipelineState`, but it does NOT address that `AppState` itself deeply consumes `PipelineState` for hotkey registration, transcript loading, error handling, and state exposure. If `activePipeline` only exposes `overlayIntent` (per the `DictationPipeline` protocol), all these `AppState` consumers of `.state` break.

Additionally, SwiftUI views reference `appState.pipeline.lastPolishError` and `appState.pipeline.reset()` directly (`TranscriptDetailView.swift:97`, `MainWindowView.swift:129,149`). These assume a single concrete pipeline type.

**What's missing:** Phase 0 needs to specify:
1. Which `AppState` properties/methods will be refactored to use `overlayIntent` vs which still need `PipelineState`
2. Whether `DictationPipeline` protocol needs additional properties beyond `overlayIntent` (e.g., `lastPolishError`, `currentTranscript`, `reset()`)
3. How SwiftUI views that reference `appState.pipeline` will be updated

**Suggested fix:** Add to `DictationPipeline` protocol:
```swift
var lastPolishError: String? { get }
var currentTranscript: Transcript? { get }
```
And explicitly list every `AppState` line that needs updating in Phase 0.

---

### GAP-2: `TextProcessingContext` is `@MainActor` -- plan ignores isolation annotation

**File:** `master-phased-implementation-plan.md` Phase 1, `system-boundaries-and-handoffs.md`, `wispr-scaffold-independent-pipeline/SKILL.md`

**What the plan says:** The merge contract shows `TextProcessingContext` as a plain struct with no isolation annotation. The skill template creates it freely within `WhisperKitPipeline`.

**What the source code shows:** `TextProcessingContext` (at `Pipeline/TextProcessingStep.swift:4-5`) is annotated `@MainActor`. So is the `TextProcessingStep` protocol. This means the text processing chain can only run on `@MainActor`.

**Why it matters:** The plan's code snippets and the skill template omit the `@MainActor` annotation when showing `TextProcessingContext`. An implementation agent might try to use it from a non-MainActor context, or might be confused when the compiler complains.

**Suggested fix:** Note `@MainActor` isolation on `TextProcessingContext` and `TextProcessingStep` in the system-boundaries doc and the skill template. Since `WhisperKitPipeline` is already `@MainActor`, this is compatible, but the plan should state it explicitly to prevent confusion.

---

### GAP-3: `WhisperKitBackend` is an `actor`, not a class -- plan's code snippets assume wrong calling convention

**File:** `wispr-scaffold-independent-pipeline/SKILL.md` Step 4, `master-phased-implementation-plan.md` Phase 1

**What the plan says:** `WhisperKitPipeline` (which is `@MainActor`) calls `await backend.transcribe(audioSamples:options:)` and `await backend.prepare()`. The skill uses `await backend.isReady` for a property check.

**What the source code shows:** `WhisperKitBackend` is an `actor` (line 20 of WhisperKitBackend.swift). `isReady` is a stored property on the actor. Accessing `actor.isReady` from `@MainActor` requires `await`.

**Why it matters:** The skill template's `handlePreWarm()` does `if !(await backend.isReady)` which is correct, but `startRecording()` does the same check -- the plan needs to be consistent. More critically, `WhisperKitBackend.whisperKit` is a `private` property. The streaming skill (Step 2) references `backend.whisperKit!` directly, which won't compile because:
1. It's `private`
2. Accessing it requires `await` (actor isolation)

**Suggested fix:**
- The streaming skill must not access `backend.whisperKit!` directly. Either add a public accessor method to `WhisperKitBackend` (e.g., `func getWhisperKit() -> WhisperKit?`) or restructure `WhisperKitStreamingCoordinator.start()` to not need the internal WhisperKit instance.
- Note the actor isolation crossing explicitly in Phase 1 and Phase 3 implementation steps.

---

### GAP-4: `Transcript` init parameter mismatch in skill template

**File:** `wispr-scaffold-independent-pipeline/SKILL.md` Step 4 (stopAndTranscribe)

**What the skill says:**
```swift
let transcript = Transcript(
    originalText: asrResult.text,
    polishedText: processedText.polishedText,
    ...
)
```

**What the source code shows:** `Transcript.init` (at `Models/Transcript.swift:16-38`) uses `text:` not `originalText:` as the parameter label:
```swift
init(id: UUID = UUID(), text: String, polishedText: String? = nil, ...)
```

**Why it matters:** An implementation agent copy-pasting this code will get a compiler error.

**Suggested fix:** Change `originalText:` to `text:` in the skill template.

---

### GAP-5: `TranscriptStore.save()` method signature unverified

**File:** `wispr-scaffold-independent-pipeline/SKILL.md` Step 4, `system-boundaries-and-handoffs.md`

**What the plan says:** `transcriptStore.save(transcript)` and `try transcriptStore.save(transcript)`

**Why it matters:** The plan uses two different calling conventions (throwing vs non-throwing) without verifying which is correct. An implementation agent needs to know whether `save()` throws.

**Suggested fix:** Verify the actual `TranscriptStore.save()` signature and use it consistently across all documents and skills.

---

### GAP-6: `.ready` state described but not in `WhisperKitPipelineState` enum

**File:** `master-phased-implementation-plan.md` (lines 102-117 vs skill template)

**What the plan says:** The state machine section (line 106) includes `.ready` as a case and describes it extensively (lines 117-118: "Model is loaded and warm, pipeline is idle"). The `stopAndTranscribe()` flow says "state = .ready (not .idle) -- model stays loaded" (line 199).

**What the skill says:** The `wispr-scaffold-independent-pipeline/SKILL.md` Step 1 defines `WhisperKitPipelineState` WITHOUT `.ready`:
```swift
enum WhisperKitPipelineState: Equatable {
    case idle
    case loadingModel
    case recording
    case transcribing
    case polishing
    case complete
    case error(String)
}
```

The `handleToggleRecording()` in Step 3 transitions from `.complete` and `.error` to `startRecording()`, but does NOT handle `.ready`. The `handleCancelRecording()` has no `.ready` case either.

**Why it matters:** The master plan and the skill template contradict each other. `.ready` changes the entire lifecycle:
- After transcription: `.complete -> .ready` (not `.idle`)
- Model stays loaded in `.ready`
- Idle timeout: `.ready -> .idle` (model unloaded)
- `handleToggleRecording()` from `.ready` should skip model load

An implementation agent following the skill template will build a pipeline without `.ready`, then hit the master plan's description of `.ready` and be confused.

**Suggested fix:** Either:
(a) Add `.ready` to the skill template's enum, update all event handlers to handle it, and wire the `ModelUnloadPolicy` timer, OR
(b) Remove `.ready` from the master plan and document that `.idle` covers both "model loaded" and "model unloaded" (simpler, but loses the pre-warm optimization)

---

### GAP-7: `PipelineEvent.preWarm` guard is wrong in skill -- blocks pre-warm after first recording

**File:** `wispr-scaffold-independent-pipeline/SKILL.md` Step 3

**What the skill says:**
```swift
private func handlePreWarm() async {
    guard state == .idle else { return }
    await audioCapture.preWarm()
    ...
}
```

**What the master plan says (line 199):** After `stopAndTranscribe()`, state goes to `.ready` (not `.idle`). But the skill template doesn't have `.ready`.

**Why it matters:** If `.ready` exists, `handlePreWarm()` should also accept it. If `.ready` doesn't exist, after a transcription completes (state = `.complete`), the next PTT key-down fires `.preWarm` but the guard rejects it because state isn't `.idle`. The user has to wait for the auto-reset to `.idle` before pre-warm works.

More practically: even without `.ready`, after state goes to `.complete`, the guard blocks pre-warm. The skill has `handleToggleRecording()` accepting `.complete` as a start condition, but `preWarm` doesn't.

**Suggested fix:** Change guard to:
```swift
guard state == .idle || state == .complete || state == .ready else { return }
```

---

### GAP-8: No specification for `ModelUnloadPolicy` timer integration

**File:** `master-phased-implementation-plan.md` lines 117-118, 199

**What the plan says:** "Idle timeout transitions .ready -> .idle (model unloaded)." "The ModelUnloadPolicy timer fires from .ready, not from active states." Phase 4 mentions "Model unload policy wired to WhisperKitPipeline.noteTranscriptionComplete(policy:) via ASRManager."

**What's missing:** No code, no method signatures, no timer implementation details. How does the timer get started? How does `noteTranscriptionComplete(policy:)` work? Is it a `DispatchWorkItem`? A `Task.sleep`? What cancels the timer on new recording start? Which file does it live in?

**Suggested fix:** Add a concrete code snippet showing:
1. Timer start after `state = .ready`
2. Timer cancellation on `handlePreWarm()` or `handleToggleRecording()`
3. Timer firing: `state = .ready -> .idle`, `await backend.unload()`

---

### GAP-9: `RecordingOverlayPanel` update strategy completely unspecified

**File:** `master-phased-implementation-plan.md` Phase 0

**What the plan says:** "RecordingOverlayPanel updated to observe `activePipeline.overlayIntent` instead of `pipeline.state` directly."

**What's missing:** RecordingOverlayPanel is an NSPanel-based class (not SwiftUI). It currently receives explicit method calls like `show(audioLevelProvider:)`, `showPolishing()`, `hide()` from AppState's `onStateChange` callback. The plan doesn't describe:
1. HOW RecordingOverlayPanel observes `overlayIntent` -- is it KVO? A callback? Observation framework?
2. Whether `RecordingOverlayPanel` is refactored to be OverlayIntent-driven, or whether AppState remains the intermediary that translates `overlayIntent` changes to `show()`/`hide()` calls
3. The generation counter pattern -- does it change? Does OverlayIntent make it unnecessary?

**Suggested fix:** Specify the observation mechanism. Most likely: AppState observes `activePipeline.overlayIntent` (via Swift Observation) and translates to RecordingOverlayPanel method calls. Say this explicitly. The generation counter stays as-is.

---

### GAP-10: `OverlayIntent.recording(audioLevel: Float)` -- who updates the audio level?

**File:** `master-phased-implementation-plan.md` Phase 1, `wispr-scaffold-independent-pipeline/SKILL.md`

**What the plan says:** `overlayIntent = .recording(audioLevel: 0)` is set once when recording starts (skill template Step 4).

**What's missing:** Audio levels change continuously during recording (50ms polling). The Parakeet pipeline provides an `audioLevelProvider: () -> Float` closure to the overlay. With `OverlayIntent.recording(audioLevel: Float)`, who updates the `Float` value every 50ms? Options:
1. WhisperKitPipeline runs a timer that updates `overlayIntent` every 50ms with new audio level
2. The overlay still uses a closure/polling pattern for audio level (in which case `audioLevel` in the enum is pointless)
3. Something else

The `parakeet-success-patterns.md` shows `OverlayIntent.recording(audioLevelProvider: () -> Float)` (closure-based), but the master plan uses `recording(audioLevel: Float)` (value-based). The simplify review (M3) flagged this inconsistency but didn't resolve it.

**Why it matters:** `OverlayIntent` is declared `Equatable`. A closure-based variant CANNOT conform to `Equatable`. But a value-based variant requires continuous updates to `overlayIntent` at 50ms intervals, which means 20 `@Observable` change notifications per second. Is that acceptable?

**Suggested fix:** Pick one approach:
- (a) Value-based: `recording(audioLevel: Float)`. Pipeline runs a 50ms timer updating overlayIntent. Document the 20Hz update rate and confirm Observable handles it.
- (b) Closure-based: `recording(audioLevelProvider: () -> Float)`. Remove `Equatable` conformance from `OverlayIntent` or make it conform manually (closures always compare as not-equal).
- (c) Hybrid: `recording` case with no associated value. Audio level provided separately via a shared `audioCapture.audioLevel` property that the overlay reads independently.

---

## Medium Gaps

### GAP-11: `WhisperKitBackend.makeDecodeOptions` is `private` -- skill calls it from pipeline

**File:** `wispr-configure-whisperkit-streaming/SKILL.md` Step 2

**What the skill says:** `backend.makeDecodeOptions(from: transcriptionOptions)`

**What the source shows:** `makeDecodeOptions(from:)` is `private` in `WhisperKitBackend.swift:91`.

**Suggested fix:** Either make it `internal` or add a public wrapper. Note this in the streaming skill.

---

### GAP-12: Streaming skill references `WhisperKitAudioCapture` which doesn't exist

**File:** `wispr-configure-whisperkit-streaming/SKILL.md` Step 4

**What the skill says:** "In WhisperKitAudioCapture: var onBufferCaptured..."

**What the plan says:** No `WhisperKitAudioCapture` exists (Decision D1, shared AudioCaptureManager).

**Suggested fix:** Remove Step 4 entirely. Buffer forwarding is wired in WhisperKitPipeline via the shared AudioCaptureManager, which already has `onBufferCaptured`.

---

### GAP-13: Backend switching drain -- `handle(event: .requestStop)` vs `handle(event: .reset)` confusion

**File:** `master-phased-implementation-plan.md`, Backend Switching Drain Protocol (lines 77-95)

**What it says:** Step 2: "Request stop on current pipeline: activePipeline.handle(event: .requestStop) if recording, .reset if idle." Step 3: "Wait for current pipeline state to reach .idle, .ready, .complete, or .error."

**What's missing:** How does AppState know if the pipeline is "recording" to choose between `.requestStop` and `.reset`? The `DictationPipeline` protocol only exposes `overlayIntent`, not the internal state. Is `overlayIntent != .hidden` the proxy for "active"?

Also, the drain waits for "pipeline state to reach .idle, .ready, .complete, or .error" but `DictationPipeline` doesn't expose the internal state enum. How does AppState observe this? Is there a new protocol requirement needed?

**Suggested fix:** Add either:
- `var isActive: Bool { get }` to `DictationPipeline` protocol, OR
- Specify that `overlayIntent == .hidden` implies pipeline is in a terminal state and switching is safe

---

### GAP-14: `withTimeout(seconds:)` utility function not defined

**File:** `wispr-configure-whisperkit-streaming/SKILL.md` Step 3

**What the skill says:** `let finalText = await withTimeout(seconds: 10) { await coordinator.finalize() }`

**What exists:** No `withTimeout` utility exists in the codebase. `TranscriptionPipeline` uses `withThrowingTaskGroup` for its timeout pattern.

**Suggested fix:** Either provide the `withTimeout` implementation or use the existing `withThrowingTaskGroup` race pattern that Parakeet uses.

---

### GAP-15: Language picker UI and model auto-switching -- no file paths or UI details

**File:** `master-phased-implementation-plan.md`, Language Selection section (lines 441-499)

**What the plan says:** Phase 1 includes "Language picker in Settings UI" and "Model variant auto-switching logic." Phase integration table places this in Phase 1.

**What's missing:**
1. Which Settings file to modify (there are multiple settings views)
2. Where in the Settings UI the picker goes (under which tab/section)
3. The SettingsManager key name for persisting language choice
4. How model auto-switching interacts with WhisperKitSetupService (does it trigger a new download?)
5. What the UX looks like during model switch (progress indicator? blocking UI?)

**Suggested fix:** Specify the exact Settings view file, the section within it, the SettingsManager property name, and the download flow for model variant switching.

---

### GAP-16: Five or six LLM providers?

**File:** `master-phased-implementation-plan.md` lines 377, 516

**What it says:** Phase 4 says "5 LLM providers (OpenAI, Gemini, Ollama, Apple Intelligence, none)" but Definition of Done says "All 6 LLM providers." The simplify review flagged this (M2) but it wasn't fixed.

**Suggested fix:** Enumerate the exact list. If there are 6, name all 6. Count "none/disabled" as a test case, not a provider.

---

### GAP-17: `WhisperKitPipeline` settings sync mechanism unspecified

**File:** `wispr-scaffold-independent-pipeline/SKILL.md` Step 2

**What the skill says:** Properties like `autoCopyToClipboard`, `autoPasteToActiveApp`, `transcriptionOptions` are declared as stored properties but no mechanism syncs them from `SettingsManager`.

**What Parakeet does:** `TranscriptionPipeline` has a `syncSettings(from:)` method or observes `SettingsManager` directly.

**What's missing:** How/when do these properties get updated? At init? Via observation? Is there a settings sync method? If SettingsManager changes while a recording is in progress, do changes apply immediately or on next recording?

**Suggested fix:** Specify the settings sync pattern: either `SettingsManager` observation on init, or a `syncSettings()` call before each recording start. Include the exact properties that need syncing.

---

### GAP-18: `HotkeyService` routing change not specified

**File:** `master-phased-implementation-plan.md` Phase 1, `execution-agent-map.md`

**What the plan says:** Phase 1 modifies `HotkeyService.swift` to route events via `AppState.dispatch()`.

**What's missing:** `HotkeyService` currently calls methods like `appState.toggleRecording()`, `appState.preWarmAudioInput()`, etc. The plan says these become `appState.dispatch(.toggleRecording)`, `appState.dispatch(.preWarm)`, etc. But it doesn't list:
1. Which specific HotkeyService callbacks to change
2. Whether the existing methods on AppState (`toggleRecording()`, `preWarmAudioInput()`) are removed or kept as wrappers
3. How cancel hotkey (ESC) maps to `.cancelRecording` event

**Suggested fix:** List the exact callback changes needed in HotkeyService and whether existing AppState methods are preserved as wrappers or deleted.

---

### GAP-19: `wispr-scaffold-whisperkit-capture` skill has incorrect batch capture code

**File:** `wispr-scaffold-whisperkit-capture/SKILL.md` Step 2

**What the skill says:**
```swift
func stopCapture() -> [Float] {
    let samples = audioCapture.stopCapture()
    return audioCapture.capturedSamples
}
```

**What's wrong:** `stopCapture()` is called, its return value is discarded, then `capturedSamples` is accessed separately. Either `stopCapture()` returns the samples (in which case use its return value) or `capturedSamples` is the property to access (in which case calling `stopCapture()` just for side effects should use `_ =`). The skill template in `wispr-scaffold-independent-pipeline` Step 4 does it differently: `_ = audioCapture.stopCapture()` then `let samples = audioCapture.capturedSamples`. These should be consistent and one should be verified against the actual `AudioCaptureManager` API.

**Suggested fix:** Verify whether `stopCapture()` returns samples or void, then use consistent pattern across both skills.

---

### GAP-20: Phase 0 `TranscriptionPipeline` conformance -- `handle(event:)` not mapped

**File:** `master-phased-implementation-plan.md` Phase 0

**What the plan says:** TranscriptionPipeline gains `DictationPipeline` conformance with `overlayIntent` computed property (maps existing PipelineState to OverlayIntent).

**What's missing:** `DictationPipeline` requires `func handle(event: PipelineEvent) async`. TranscriptionPipeline doesn't have this method. The plan says TranscriptionPipeline gets a "1-line" conformance, but implementing `handle(event:)` is NOT 1 line. It needs to map:
- `.preWarm` -> `preWarmAudioInput()`
- `.toggleRecording` -> `toggleRecording()`
- `.requestStop` -> `stopAndTranscribe()`
- `.cancelRecording` -> `cancelRecording()`
- `.reset` -> reset state

This is a non-trivial adapter method, not a 1-line change.

**Suggested fix:** Acknowledge that conforming TranscriptionPipeline to `DictationPipeline` requires:
1. `overlayIntent` computed property (mapping PipelineState -> OverlayIntent)
2. `handle(event:)` method (routing events to existing methods)
This is ~20-30 lines of new code in TranscriptionPipeline, not "1-line."

---

## Low Gaps

### GAP-21: `missing-skills-and-recommended-new-agents.md` still references rejected architecture

**File:** `missing-skills-and-recommended-new-agents.md`

The simplify review (C3) flagged this: skill #1 describes creating `WhisperKitAudioCapture` wrapper, Research Gap #2 asks about "two AVAudioEngine instances." Both contradict D1. The actual skills have been created correctly, but this doc remains stale and misleading.

**Suggested fix:** Add a header note: "SUPERSEDED: Skills have been created. See .claude/skills/ for current versions."

---

### GAP-22: No error recovery path after `.error` state in WhisperKitPipeline

**File:** `wispr-scaffold-independent-pipeline/SKILL.md` Step 3

The skill's `handleToggleRecording()` handles `.error` by calling `startRecording()`. But `handleReset()` clears the error. There's no auto-reset timer. If the user doesn't press the hotkey again after an error, the pipeline stays in `.error` indefinitely.

**What Parakeet does:** AppState has an auto-reset: "if case .error = self.pipeline.state" with a timer.

**Suggested fix:** Note that AppState should implement the same auto-reset-on-error pattern for WhisperKitPipeline, or add it to the skill template.

---

### GAP-23: `wispr-test-dual-pipeline` UAT code uses non-existent Python API

**File:** `wispr-test-dual-pipeline/SKILL.md`

The UAT scenarios use Python decorators (`@uat_test`) and functions (`assert_value_becomes`, `nav_to_tab`, `ctx.click_element`) that appear to be pseudo-code. There's no verification these match the actual wispr-eyes Python API.

**Suggested fix:** Mark these as "pseudo-code templates" or verify against the actual wispr-eyes API.

---

### GAP-24: `WhisperKitStreamingCoordinator.feedAudio()` body is empty

**File:** `wispr-configure-whisperkit-streaming/SKILL.md` Step 1

The `feedAudio(_ buffer:)` method has a comment "NOTE: Verify exact feed API -- may need to extract Float samples from buffer" but no implementation. This is flagged as needing R5 verification, but there should at least be a TODO pattern or placeholder that makes it obvious the method is incomplete.

**Suggested fix:** Add an explicit `fatalError("TODO: Verify AudioStreamTranscriber feed API before implementing")` or similar compile-time gate so an implementation agent doesn't ship a no-op.

---

### GAP-25: No specification for `AppDelegate` changes

**File:** All plan documents

`AppDelegate` is not mentioned in any phase's "Key source files touched" list, but it currently contains pipeline state observation code (the `onStateChange` callback wiring shown in parakeet-success-patterns.md:46-63). Moving to `overlayIntent`-based observation likely requires changes here.

**Suggested fix:** Verify whether `AppDelegate` or `AppState` owns the overlay state observation, and add the correct file to Phase 0's modified files list.

---

## Summary

| Severity | Count | Description |
|----------|-------|-------------|
| Critical | 10 (GAP 1-10) | Missing implementation details that would cause compilation errors or wrong behavior |
| Medium | 10 (GAP 11-20) | Ambiguities or inconsistencies that would force an implementation agent to guess |
| Low | 5 (GAP 21-25) | Stale docs, pseudo-code, or minor omissions |

**The top 3 gaps by implementation impact:**

1. **GAP-6** (.ready state contradiction) -- Master plan describes it, skill template omits it. This changes the entire state machine.
2. **GAP-1** (AppState coupling) -- Phase 0 scope is vastly underestimated. AppState + SwiftUI views need significant refactoring.
3. **GAP-10** (audio level update mechanism) -- Fundamental design decision for OverlayIntent unresolved.
