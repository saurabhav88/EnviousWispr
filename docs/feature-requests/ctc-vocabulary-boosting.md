# CTC Vocabulary Boosting: Implementation Plan

**Bead:** ew-8a4.1 (wiring), ew-8a4.3 (calibration)
**Epic:** ew-8a4 (Custom Words v2)
**Status:** Planning (v2, post-GPT review)
**Council:** GPT-5.4 (ctc-wiring-plan-gpt-v2, 2 rounds) + Gemini 3.1 Pro (ctc-wiring-plan-gemini)

## Goal

Wire FluidAudio's CTC-based vocabulary boosting into the Parakeet pipeline so custom vocabulary terms (proper nouns, brand names, technical jargon) get acoustic-level verification and correction. This is the key differentiator: no competitor does ASR-level custom word boosting on-device.

## Architecture Decision Record

### Council consensus (GPT-5.4 + Gemini, 2026-03-29)

1. **Separate CTC AsrManager** (not configuring the heart manager). Two batch managers in ParakeetBackend: heart (raw) + limb (CTC-configured). Hard failure isolation.

2. **New XPC methods** on existing protocol. Not piggybacked on loadModel (wrong lifecycle), not a separate XPC connection (unnecessary complexity).

3. **CTC is NOT a TextProcessingStep.** It requires audio samples and ASR models, runs in the XPC service process. It is an ASR refinement limb, not text post-processing. But its orchestration is post-processing-like (optional, async, timeout-bounded, silent fallback).

4. **Dedicated coordinator** keeps TranscriptionPipeline clean. Pipeline makes 2 calls: syncVocabulary (on PTT press) and scheduleRescore (after heart result). No CTC logic in the 1140-line pipeline.

5. **Lazy CTC model download** after primary Parakeet model ready, only when custom vocab is non-empty.

6. **Heart-first in ALL modes.** Streaming and batch both produce the heart result first, then async CTC refine. CTC never on the critical path. (GPT R1 correction: direct CTC-first in batch mode violates Heart & Limbs because timeout fallback causes duplicate full transcription.)

7. **Revision-based vocab sync** with composite configuration key (revision + termsHash + backendModelID). No hot-swap mid-utterance.

### GPT Round 1 corrections (incorporated)

- **Preparation must be fire-and-forget.** `prepareVocabularyBoosting` returns immediately; service spawns background prep task. `rescoreWithVocabulary` fails fast with `.notReady` if prep incomplete. Prevents long CTC download from blocking XPC.
- **CTC manager operations must be explicitly serialized.** Actor reentrancy around `await` means `configureVocabularyBoosting` and `transcribe` can interleave on the non-actor `AsrManager`. Internal operation gate required.
- **Batch mode must be heart-first.** Heart manager transcribes, then optional async CTC rescore. Not CTC-first with fallback.

## Infrastructure Constraints

### FluidAudio API surface
- `AsrManager` is a class, not actor. `init(config:)` + `initialize(models:)`. Can create second instance sharing same `AsrModels`.
- `configureVocabularyBoosting(vocabulary:ctcModels:config:)` configures CTC on an AsrManager instance. After configuration, all `transcribe()` calls on that manager include CTC rescoring automatically. No way to separate "transcribe TDT" from "rescore CTC" in FluidAudio.
- `CtcModels.downloadAndLoad(variant: .ctc110m)` downloads ~64MB model. One-time, cached.
- `CtcTokenizer.load(from:)` + `encode(text)` converts terms to CTC token IDs. Terms without ctcTokenIds are silently skipped.
- `CustomVocabularyTerm` requires `ctcTokenIds` to be populated. Must tokenize in XPC service process.
- **Concurrency unknown:** Whether two `AsrManager` instances sharing `AsrModels` can run concurrent inference safely is not documented. Design must support fallback to serialized inference.

### XPC constraints
- All params must be @objc-compatible: Data, String, Bool, Int, NSError.
- XPC serializes all replies: long-running prep must not block heart-path calls.
- CTC model download progress: use ProgressFile (shared temp file), same pattern as primary model.

### Existing type mapping
- `CustomWord` (Core): has canonical, aliases, category, priority, forceReplace
- `CustomVocabularyTerm` (FluidAudio): has text, aliases, weight, tokenIds, ctcTokenIds
- `CustomWordsManager` (PostProcessing, @MainActor): manages persistence + merge of built-in + user words
- `TextProcessingStep` protocol: text-only, @MainActor, has name/isEnabled/maxDuration/process()
- `ASRManagerInterface` (@MainActor): app-side abstraction. Both ASRManager (in-process) and ASRManagerProxy (XPC) conform.

### Streaming CTC limitation
- StreamingAsrManager has 10s minContextForConfirmation. Short dictation never confirms.
- Correct pattern: stream for speed, batch post-rescore with CTC on accumulated audio.

## Key Design Patterns

### Limb state machine

```swift
enum VocabularyBoostingState: Sendable {
    case disabled
    case idle                                          // no vocab configured
    case preparing(revision: Int, task: Task<Void, Error>)
    case ready(key: VocabularyConfigurationKey)
    case failed(revision: Int, error: String, retryAfter: Date?)
}
```

This prevents nil-checks-and-booleans spread. All state transitions are explicit. Rescore checks state: only `.ready` proceeds; `.preparing` can optionally await the task; all others fail fast.

### Configuration key (not just revision)

```swift
struct VocabularyConfigurationKey: Hashable, Sendable {
    let revision: Int
    let termsHash: String
    let backendModelID: String
}
```

Prevents stale-config bugs after model swaps or backend switches.

### Operation serialization gate

```swift
/// Serializes all operations on the non-actor AsrManager to prevent
/// reentrancy between configureVocabularyBoosting and transcribe.
actor VocabularyManagerGate {
    func run<T: Sendable>(_ op: @Sendable () async throws -> T) async throws -> T {
        try await op()
    }
}
```

All CTC manager calls (configure + transcribe) go through this gate. Actor isolation ensures only one runs at a time across suspension points.

### CTC resource bundle

```swift
struct LoadedCtcResources: Sendable {
    let models: CtcModels
    let tokenizer: CtcTokenizer
    let variant: CtcModelVariant
}
```

Tokenizer cached with model bundle; invalidated together. Prevents tokenizer/model mismatch.

### Vocabulary boosting policy

```swift
struct VocabularyBoostingPolicy: Sendable {
    func shouldPrepare(backend: ASRBackendType, vocabEmpty: Bool) -> Bool
    func shouldRescore(backend: ASRBackendType, vocabEmpty: Bool, audioDuration: TimeInterval) -> Bool
    func timeout(for audioDuration: TimeInterval) -> Duration
    func shouldAcceptRefinement(new: ASRResult, old: ASRResult) -> Bool
}
```

Separates policy from orchestration. Product changes (timeout tuning, minimum duration, per-backend rules) don't touch coordinator logic.

### Capability abstraction (iOS future-proofing)

```swift
struct VocabularyBoostingCapabilities: Sendable {
    let supported: Bool
    let supportsBackgroundPreparation: Bool
    let supportsConcurrentInference: Bool
}
```

Coordinator queries capabilities; does not assume two managers always available. macOS: full support. iOS: may be disabled or limited by memory.

## Implementation Steps

### Phase 1: XPC Protocol + Service-Side Wiring

**Goal:** CTC vocabulary boosting works inside the XPC service process. No app-side changes yet.

#### 1.1 Add XPC protocol methods

Add to `ASRServiceProtocol` in `EnviousWisprCore`:

```swift
// Vocabulary boosting (Parakeet CTC limb)
// Fire-and-forget: enqueues preparation, returns immediately.
func requestVocabularyBoostingPreparation(_ configData: Data, reply: @escaping (NSError?) -> Void)
func clearVocabularyBoosting(reply: @escaping () -> Void)
func rescoreWithVocabulary(_ audioData: Data, sampleCount: Int, language: String, reply: @escaping (Data?, NSError?) -> Void)
```

Note: `requestVocabularyBoostingPreparation` returns immediately after validating config and spawning the background prep task. It does NOT wait for CTC model download or configuration to complete. The `rescoreWithVocabulary` call fails fast with a specific error if preparation is not yet complete.

Add DTOs in `EnviousWisprCore`:

```swift
public struct VocabularyBoostingConfig: Codable, Sendable {
    public let terms: [VocabularyBoostingTerm]
    public let revision: Int

    public struct VocabularyBoostingTerm: Codable, Sendable {
        public let canonical: String
        public let aliases: [String]
    }
}

public enum VocabularyBoostingError: String, Codable, Sendable {
    case notReady        // prep not complete
    case notConfigured   // no vocab set
    case unsupported     // wrong backend
}
```

#### 1.2 Add ParakeetVocabularyBoostingLimb actor

New file in `EnviousWisprASR`:

```swift
actor ParakeetVocabularyBoostingLimb {
    private var state: VocabularyBoostingState = .idle
    private var ctcResources: LoadedCtcResources?
    private var ctcAsrManager: AsrManager?
    private let operationGate = VocabularyManagerGate()

    /// Fire-and-forget: spawns background task, updates state.
    func requestPreparation(
        config: VocabularyBoostingConfig,
        primaryModels: AsrModels,
        backendModelID: String
    )

    func clear()

    /// Fails fast if state != .ready
    func rescore(
        audioSamples: [Float],
        language: String
    ) async throws -> ASRResult

    var isReady: Bool { ... }
}
```

Internal flow for `requestPreparation`:
1. Compute target `VocabularyConfigurationKey`
2. If already `.ready` with same key, no-op
3. Cancel any in-flight `.preparing` task
4. Set state to `.preparing(revision:task:)`
5. Task body: download CtcModels if needed -> load tokenizer -> tokenize terms -> create/configure AsrManager -> set state to `.ready`
6. On failure: set state to `.failed` with retry backoff

All AsrManager operations (configure + transcribe) go through `operationGate`.

#### 1.3 Wire into ParakeetBackend

```swift
actor ParakeetBackend {
    // existing heart managers...
    private var vocabularyBoostingLimb: ParakeetVocabularyBoostingLimb?

    func requestVocabularyBoostingPreparation(_ config: VocabularyBoostingConfig)
    func clearVocabularyBoosting()
    func rescoreWithVocabulary(audioSamples: [Float], language: String) async throws -> ASRResult
}
```

Limb created lazily on first `requestVocabularyBoostingPreparation` call with non-empty terms.

#### 1.4 Wire into ASRServiceHandler

Handle the 3 new XPC methods, deserialize Data, forward to ParakeetBackend.

**Validation:** Can create second AsrManager sharing AsrModels, configure CTC, transcribe with CTC terms detected. XPC round-trip: request prep, wait, rescore. Verify rescore fails fast when not ready.

### Phase 2: App-Side Proxy + Coordinator

**Goal:** App can send vocabulary config and request rescores over XPC.

#### 2.1 Extend ASRManagerProxy (minimal)

Add 3 methods matching the new XPC protocol methods. Thin bridges.

#### 2.2 Add VocabularyBoostingCoordinator

New file in `EnviousWisprPipeline`:

```swift
@MainActor
public final class VocabularyBoostingCoordinator {
    private let asrManager: ASRManagerInterface
    private let customWordsManager: CustomWordsManager
    private let policy: VocabularyBoostingPolicy
    private var lastSyncedRevision: Int = 0
    private var currentUtteranceID: UUID?

    public init(
        asrManager: ASRManagerInterface,
        customWordsManager: CustomWordsManager,
        policy: VocabularyBoostingPolicy = .default
    )

    /// Call on PTT press or model ready. Fire-and-forget.
    public func syncVocabularyIfNeeded()

    /// Call after heart result produced. Returns improved result or nil.
    /// Validates utterance identity to prevent stale refinements.
    public func rescoreIfEligible(
        utteranceID: UUID,
        audioSamples: [Float],
        baseResult: ASRResult,
        language: String
    ) async -> ASRResult?

    /// Call when starting a new utterance. Sets current utterance ID.
    public func beginUtterance() -> UUID

    /// Call on cancellation/teardown.
    public func cancelCurrentUtterance()
}
```

Coordinator checks policy at every decision point:
- `shouldPrepare` before syncing vocab
- `shouldRescore` before attempting rescore
- `shouldAcceptRefinement` before returning result
- `timeout(for:)` for the rescore deadline
- Validates `utteranceID` matches current to prevent stale refinements

#### 2.3 CustomWord -> VocabularyBoostingConfig conversion

```swift
extension CustomWordsManager {
    func vocabularyBoostingConfig() -> VocabularyBoostingConfig
}
```

Revision incremented on any word list change (add, edit, delete, import).

**Validation:** App sends vocab config over XPC, receives rescore results. Coordinator handles timeout, not-ready, and stale utterance rejection.

### Phase 3: Pipeline Integration

**Goal:** CTC rescoring wired into TranscriptionPipeline with minimal changes.

#### 3.1 Add coordinator to TranscriptionPipeline

Pipeline gets a `vocabularyBoostingCoordinator` property, injected at init.

#### 3.2 Sync on recording start

In recording start path, after model prewarm:

```swift
vocabularyBoostingCoordinator.syncVocabularyIfNeeded()
```

Fire-and-forget. Does not await. CTC prep happens in background.

#### 3.3 Utterance tracking

```swift
let utteranceID = vocabularyBoostingCoordinator.beginUtterance()
```

Set at recording start. Used to validate rescore results are for current utterance.

#### 3.4 Heart-first ASR, then optional CTC rescore

```swift
// Heart path: always runs first, both streaming and batch
let result: ASRResult
if wasStreaming {
    result = try await finalizeStreamingWithTimeout(samples: samples)
} else {
    result = try await asrManager.transcribe(audioSamples: samples, options: transcriptionOptions)
}

// ... existing post-processing (WordCorrector, filler removal, LLM polish) ...
// ... paste ...

// Limb: optional async CTC rescore (after paste)
if let ctcResult = await vocabularyBoostingCoordinator.rescoreIfEligible(
    utteranceID: utteranceID,
    audioSamples: samples,
    baseResult: result,
    language: transcriptionOptions.language ?? "en"
) {
    // v1: log for calibration only
    // v2: safe replacement if insertion anchor still valid
    logCtcRefinement(base: result, refined: ctcResult)
}
```

Pipeline grows by ~10 lines. No CTC branching logic. No batch-vs-streaming split for CTC.

#### 3.5 Cancellation

```swift
// In cancelRecording / teardown
vocabularyBoostingCoordinator.cancelCurrentUtterance()
```

Prevents stale CTC results from arriving after cancellation.

**Validation:** Full rebuild-relaunch. Exercise: record with custom words, verify CTC rescore logged in both streaming and batch modes. Verify streaming paste latency unchanged. Verify no-vocab case has zero overhead. Verify cancellation prevents stale results.

### Phase 4: Calibration and Instrumentation (ew-8a4.3)

**Goal:** Prove CTC business value before enabling visible corrections.

#### 4.1 Telemetry

Track per-utterance:
- prep requested / prep succeeded / prep failed / prep duration
- CTC model download duration (first time only)
- rescore attempted / skipped (reason) / timed out / succeeded
- rescore duration
- text changed? (yes/no)
- ctcDetectedTerms / ctcAppliedTerms (counts)
- per-candidate rejection reasons from RescoreOutput.replacements

#### 4.2 Add spoken-form entries

For hard cases like "Saurabh", add ASR-mangled variants as aliases: "sorabh", "saru", "sarab", "sarub". These become CTC spotting entries.

#### 4.3 Threshold sweep

Test minSimilarity at 0.40, 0.45, 0.50, 0.52, 0.55. Measure across confirmation (terms ASR gets right) and correction (terms ASR mangles) buckets.

#### 4.4 CTC model download UX

Progress indicator using ProgressFile pattern. Show in settings or status bar. Background, never blocks recording.

### Phase 5: Visible Corrections (v2, post-calibration)

**Goal:** CTC results actually improve pasted text.

#### 5.1 Safe replacement mechanism

Only replace if:
- insertion anchor still valid (same app, same field, same text range)
- refined text differs only by custom vocabulary substitutions
- `policy.shouldAcceptRefinement` returns true

#### 5.2 Transcript history update

Update stored transcript with CTC-refined version regardless of paste replacement.

#### 5.3 Future: streaming CTC

If FluidAudio adds native streaming CTC support, extend `VocabularyBoostingPolicy` with mode:

```swift
enum StreamingVocabularyPolicy {
    case postUtteranceBatchRescore  // current
    case nativeStreamingBoosting   // future
}
```

Coordinator queries backend capabilities and chooses. No pipeline changes needed.

## Module Placement

| Component | Module | Rationale |
|-----------|--------|-----------|
| `VocabularyBoostingConfig` DTO | EnviousWisprCore | Shared across process boundary |
| `VocabularyBoostingError` | EnviousWisprCore | Error type for XPC |
| `VocabularyConfigurationKey` | EnviousWisprCore | Shared identity type |
| `ParakeetVocabularyBoostingLimb` | EnviousWisprASR | XPC service, owns CTC models |
| `VocabularyManagerGate` | EnviousWisprASR | Serialization for non-actor manager |
| `LoadedCtcResources` | EnviousWisprASR | CTC model + tokenizer bundle |
| `VocabularyBoostingCoordinator` | EnviousWisprPipeline | Orchestrates limb from pipeline |
| `VocabularyBoostingPolicy` | EnviousWisprPipeline | Rescore/accept decisions |
| `VocabularyBoostingCapabilities` | EnviousWisprPipeline | Platform capability abstraction |
| CustomWord -> DTO conversion | EnviousWisprPostProcessing | Near CustomWordsManager |

## Dependency Direction

```
Pipeline (Coordinator, Policy, Capabilities)
    -> uses ASRManagerInterface (from ASR module)
    -> uses CustomWordsManager (from PostProcessing)
    -> uses VocabularyBoostingConfig (from Core)

ASR (Limb, Gate, Resources)
    -> uses VocabularyBoostingConfig (from Core)
    -> uses FluidAudio (CtcModels, AsrManager, CustomVocabularyContext)

Core (Config, Error, Key, XPC protocol)
    -> no upward imports
```

Clean. No circular dependencies. No upward imports.

## Risk Register

| Risk | Mitigation |
|------|------------|
| CTC model download fails | State machine: `.failed` with retry backoff. Never blocks heart. |
| Second AsrManager doubles memory | ~130MB peak. Acceptable on macOS. Unload hook for idle/backend switch. |
| Concurrent inference unsafe | Operation gate serializes by default. Can enable concurrent after stress testing. |
| CTC rescore slower than timeout | Hard timeout via policy. Fall back to heart result. |
| Vocab changes during recording | Revision-based. Current utterance uses old revision. Next picks up new. |
| XPC crash during CTC rescore | Existing crash recovery. CTC state rebuilt on next prepare. |
| CTC false positives | Calibration phase before enabling visible corrections. |
| Stale refinement arrives late | Utterance ID validation. Cancelled utterances rejected. |
| Download blocks XPC | Fire-and-forget prep. Rescore fails fast if not ready. |
| AsrManager reentrancy | VocabularyManagerGate serializes all CTC manager calls. |
| Backend/model switch invalidation | Composite VocabularyConfigurationKey includes backendModelID. |
| iOS memory constraints | Capability abstraction. CTC can be disabled per-platform. |

## Open Decisions

1. **Streaming refinement UX (v2):** How to safely replace already-pasted text. Deferred to after calibration.
2. **CTC for WhisperKit:** Not applicable. WhisperKit has promptTokens. Separate bead (ew-ci6).
3. **CTC model unload triggers:** Start with: unload on backend switch, vocab clear, or 5-min idle.
4. **Vocabulary normalization policy:** Case folding, phrase length caps, max vocab size, dangerous single-letter terms. Define before user-facing ship.
5. **Concurrent vs serialized inference:** Default serialized. Test concurrent on macOS. Gate behind execution policy enum.

## Definition of Done

- [ ] CTC rescore works end-to-end: prep + rescore over XPC
- [ ] Heart path unaffected in all modes (streaming and batch)
- [ ] CTC model downloads lazily, with progress indicator
- [ ] Preparation is fire-and-forget, rescore fails fast if not ready
- [ ] All CTC manager operations serialized via gate
- [ ] Timeout + fallback to heart result on any CTC failure
- [ ] Utterance identity validated on rescore results
- [ ] No changes to WhisperKit pipeline
- [ ] TranscriptionPipeline grows by < 20 lines
- [ ] Telemetry for all CTC operations (prep, rescore, acceptance)
- [ ] Architecture DoD checklist passes
- [ ] Calibration data collected (ew-8a4.3) before enabling visible corrections
