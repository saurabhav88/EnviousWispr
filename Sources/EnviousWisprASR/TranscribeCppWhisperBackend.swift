import EnviousWisprCore
import EnviousWisprServices
import EnviousWisprTranscribeCpp
import Foundation

// MARK: - Executor seam (#3735 plan §3.2, §3.2a)

/// The executor operations the Whisper backend drives. Production uses
/// `LiveWhisperExecutorDriver` (every call goes to `TranscribeCppExecutor.shared`); tests use a
/// fake with its own handle type, so no test fabricates an executor handle or constructs a
/// second executor.
package protocol WhisperExecutorDriving: Sendable {
  associatedtype Handle: Hashable & Sendable
  func load(modelPath: String, lane: TranscribeCppExecutor.Lane) async throws -> Handle
  func detectLanguage(
    _ handle: Handle, samples: [Float], lane: TranscribeCppExecutor.Lane
  ) async throws -> TranscribeCppLanguageObservation
  /// `onInferenceEntered` is called synchronously immediately before the native run starts;
  /// never while the request only waits for the executor.
  func transcribe(
    _ handle: Handle, samples: [Float], language: String?,
    lane: TranscribeCppExecutor.Lane,
    onInferenceEntered: (@Sendable () -> Void)?,
    onProgress: (@Sendable (Int64, Int64) -> Void)?
  ) async throws -> TranscribeCppRunResult
  /// Returns once no native work for `handle` is running (the executor releases a cancelled
  /// caller before its aborted native call ends). Never frees anything.
  func waitForDrain(_ handle: Handle) async
  /// Aborts and drains work on `handle`, then frees it. Unknown handles return at once.
  func unload(_ handle: Handle) async
}

/// The production driver: a thin forwarder to the one process-wide executor.
package struct LiveWhisperExecutorDriver: WhisperExecutorDriving {
  package typealias Handle = TranscribeCppExecutor.ModelHandle

  package init() {}

  package func load(modelPath: String, lane: TranscribeCppExecutor.Lane) async throws -> Handle {
    try await TranscribeCppExecutor.shared.load(modelPath: modelPath, lane: lane)
  }

  package func detectLanguage(
    _ handle: Handle, samples: [Float], lane: TranscribeCppExecutor.Lane
  ) async throws -> TranscribeCppLanguageObservation {
    try await TranscribeCppExecutor.shared.detectLanguage(handle, samples: samples, lane: lane)
  }

  package func transcribe(
    _ handle: Handle, samples: [Float], language: String?,
    lane: TranscribeCppExecutor.Lane,
    onInferenceEntered: (@Sendable () -> Void)?,
    onProgress: (@Sendable (Int64, Int64) -> Void)?
  ) async throws -> TranscribeCppRunResult {
    try await TranscribeCppExecutor.shared.transcribe(
      handle, samples: samples, language: language, lane: lane, onProgress: onProgress,
      onInferenceEntered: onInferenceEntered)
  }

  package func waitForDrain(_ handle: Handle) async {
    await TranscribeCppExecutor.shared.waitForDrain(handle)
  }

  package func unload(_ handle: Handle) async {
    await TranscribeCppExecutor.shared.unload(handle)
  }
}

// MARK: - Errors

/// Stable Sentry identities for transcribe.cpp load and run failures (#3735 plan §7). The
/// status is the native `transcribe_status` value, so the identity never depends on Swift
/// enum layout.
package enum TranscribeCppWhisperError: LocalizedError, Sendable, Equatable {
  case loadFailed(status: Int32)
  case runFailed(status: Int32)

  package var errorDescription: String? {
    switch self {
    case .loadFailed(let status): return "transcribe.cpp model load failed (status \(status))"
    case .runFailed(let status): return "transcribe.cpp transcription failed (status \(status))"
    }
  }
}

extension TranscribeCppWhisperError: StableSentryErrorIdentity {
  package var sentryFingerprintDescriptor: String {
    switch self {
    case .loadFailed(let status): return "TranscribeCpp.load#\(status)"
    case .runFailed(let status): return "TranscribeCpp.run#\(status)"
    }
  }

  package var sentrySemanticID: String {
    switch self {
    case .loadFailed: return "transcribecpp.load_failed"
    case .runFailed: return "transcribecpp.run_failed"
    }
  }
}

// MARK: - Backend

/// The loaded-model marker the shared load-state machine carries (`WhisperKitLoadState.swift`).
final class LoadedWhisperModel<Handle: Hashable & Sendable>: LoadedASRModel, Sendable {
  let handle: Handle
  init(handle: Handle) { self.handle = handle }
}

/// #3735 plan §3.2: Whisper on transcribe.cpp. Every native call goes through the driver to
/// `TranscribeCppExecutor`, which owns serialization, lanes, abort and teardown order; this
/// actor owns the model lifecycle (single-flight load, generation, warm-up readiness, model
/// scope), the speech envelope, language and timing mapping, LID observation and the memory
/// pressure policy.
///
/// The load lifecycle reuses `WhisperKitLoadStateMachine` unchanged (its reasons are in that
/// file and in `WhisperKitBackend`): one load at a time, a load or warm-up completing after an
/// unload is stale by generation, readiness flips only after the warm-up resolves, and the
/// warm-up's 20 s fail-open ceiling is paid at most once per generation.
package actor TranscribeCppWhisperBackend<Driver: WhisperExecutorDriving>: ASRBackend {
  package var isReady: Bool { loadState.isReady && !admissionClosed }

  private let driver: Driver
  private let variant: String
  private var loadState: LoadState = .idle
  /// Bumped by `unload()` BEFORE the teardown transition (#1282: captured at load-task
  /// creation, before any await), so a load or warm-up finishing later is recognizably stale.
  private var generation: UInt64 = 0
  private var loadSeq: UInt64 = 0
  /// Every handle the driver returned and this actor has not unloaded. A load that finishes
  /// after an unload or a newer load leaves a handle no state carries; it is freed from here,
  /// never leaked.
  private var liveHandles: Set<Driver.Handle> = []

  /// Duration of the most recent completed warm-up decode in ms; nil until one completes.
  package private(set) var lastWarmupInferenceMs: Int?

  /// Resolves the ADMITTED GGUF file, or nil when none is admitted. Availability truth is the
  /// delivery controller's admission; this backend never fetches.
  private let admittedModelPath: @Sendable () async -> String?

  private let warmupDeadlineSeconds: Double

  private let scopeIdentity: ASRModelIdentity?
  typealias ScopeDelivery = @Sendable (UInt64, ASRModelScopeOwner.Snapshot) async -> Void
  private let deliverScope: ScopeDelivery?
  private var scopeSequence: UInt64 = 0
  private var scopeRequested: ASRModelIdentity?
  private var scopePhase: ASRModelScopeOwner.Phase?
  private var lastScopeReport: (sequence: UInt64, snapshot: ASRModelScopeOwner.Snapshot)?

  /// Runs `teardown` under the app's engine-mutation authorization (EngineMutationScope or a
  /// lease) and returns whether it ran it; false when the claim is refused. `teardown`
  /// returns whether the model was actually unloaded, so the caller updates its readiness only
  /// after a real teardown. Installed by the adapter (`bindMemoryPressure(authorizer:)`); nil
  /// means memory pressure never unloads.
  package typealias UnloadAuthorizer =
    @Sendable (_ teardown: @escaping @Sendable () async -> Bool) async -> Bool
  private var authorizeUnload: UnloadAuthorizer?

  // Operation and pressure bookkeeping.
  private var inFlight = 0
  private var admissionClosed = false
  private var pressurePending = false
  private var pressureRunning = false
  private var pressureSource: (any DispatchSourceMemoryPressure)?

  package var modelVariantName: String { variant }

  package init(
    driver: Driver,
    modelVariant: String,
    admittedModelPath: @escaping @Sendable () async -> String?,
    modelIdentity: ASRModelIdentity? = nil,
    scopeOwner: ASRModelScopeOwner? = nil,
    authorizeUnload: UnloadAuthorizer? = nil
  ) {
    self.init(
      driver: driver, modelVariant: modelVariant, admittedModelPath: admittedModelPath,
      modelIdentity: modelIdentity, scopeDelivery: Self.delivery(to: scopeOwner),
      authorizeUnload: authorizeUnload, warmupDeadlineSeconds: 20)
  }

  /// Full initializer; tests shorten the warm-up ceiling and capture scope reports.
  init(
    driver: Driver,
    modelVariant: String,
    admittedModelPath: @escaping @Sendable () async -> String?,
    modelIdentity: ASRModelIdentity?,
    scopeDelivery: ScopeDelivery?,
    authorizeUnload: UnloadAuthorizer?,
    warmupDeadlineSeconds: Double
  ) {
    self.driver = driver
    self.variant = modelVariant
    self.admittedModelPath = admittedModelPath
    self.scopeIdentity = modelIdentity?.variant == modelVariant ? modelIdentity : nil
    self.deliverScope = scopeDelivery
    self.authorizeUnload = authorizeUnload
    self.warmupDeadlineSeconds = warmupDeadlineSeconds
  }

  private static func delivery(to owner: ASRModelScopeOwner?) -> ScopeDelivery? {
    guard let owner else { return nil }
    let deliver: ScopeDelivery = { (sequence: UInt64, snapshot: ASRModelScopeOwner.Snapshot) in
      await owner.observe(.whisperKit, sequence: sequence, snapshot: snapshot)
    }
    return deliver
  }

  var loadPhaseForTesting: LoadPhase { loadState.phase }

  // MARK: - Load

  /// Loads the admitted model, or throws `.notReady` when none is admitted. No download and no
  /// automatic repair: the current Whisper policy (`WhisperKitBackend.prepare()` comment) is
  /// that a download is the user's decision, so an admitted but unloadable file is an honest,
  /// visible load failure.
  package func prepare() async throws {
    // A teardown in progress still frees handles after it published idle; a replacement load
    // started now could be freed by it.
    guard !admissionClosed else { throw ASRError.notReady }
    let effects = await emit(.prepareRequested)
    for effect in effects {
      switch effect {
      case .joinLoad(let task):
        try await task.value
        return
      case .beginLoad:
        try await startLoad()
        return
      default:
        break
      }
    }
  }

  private func startLoad() async throws {
    let capturedGeneration = generation  // #1282: capture BEFORE any await
    loadSeq &+= 1
    let identity = LoadIdentity(generation: capturedGeneration, id: loadSeq)
    let task = Task<Void, Error> { try await self.runLoad(identity: identity) }
    await emit(.loadStarted(identity, task: task))
    try await task.value
  }

  private func runLoad(identity: LoadIdentity) async throws {
    let model: LoadedWhisperModel<Driver.Handle>
    do {
      guard let path = await admittedModelPath() else { throw ASRError.notReady }
      // #3546 §3.7 T3: this load's `loading` tags land before the native load, and a load
      // unloaded or cancelled while they were delivered never enters it.
      await publishLoadingScope()
      guard identity.generation == generation else { throw ASRLoadSupersededError() }
      try Task.checkCancellation()
      let handle = try await loadHandle(path)
      liveHandles.insert(handle)
      model = LoadedWhisperModel(handle: handle)
    } catch {
      await emit(.loadFailed(identity), failure: error)
      throw error
    }
    for effect in await emit(.loadSucceeded(kit: model, identity)) {
      switch effect {
      case .throwSuperseded:
        await release(model.handle)
        throw ASRLoadSupersededError()
      case .beginWarmup(let kit, let warmGeneration):
        do {
          try await runWarmupPhase(kit: kit, generation: warmGeneration)
        } catch {
          // A superseded warm-up's model is no longer carried by the state.
          if !isCurrent(model.handle) { await release(model.handle) }
          throw error
        }
      default:
        break
      }
    }
  }

  private func loadHandle(_ path: String) async throws -> Driver.Handle {
    do {
      return try await driver.load(modelPath: path, lane: .heart)
    } catch let error as TranscribeCppError {
      throw TranscribeCppWhisperError.loadFailed(status: error.status)
    } catch TranscribeCppExecutor.ExecutorError.cancelled {
      throw CancellationError()
    }
  }

  /// One silent warm-up decode before readiness flips, so the first real press never pays the
  /// first-decode cost (#1275 item A; the first Metal compile after an install or update can
  /// take seconds). Fail-open under the 20 s ceiling, which bounds an invisible background
  /// task, never a user-facing wait (founder-approved exception, #1275 Gate 2).
  private func runWarmupPhase(kit: any LoadedASRModel, generation warmGeneration: UInt64)
    async throws
  {
    lastWarmupInferenceMs = nil
    let warmupTask = Task<WarmupOutcome, Never> { await self.performWarmup(kit) }
    await emit(.warmupStarted(kit: kit, generation: warmGeneration, warmupTask: warmupTask))
    guard case .warming = loadState else { throw ASRLoadSupersededError() }
    if let outcome = await withDeadline(
      seconds: warmupDeadlineSeconds, operation: { await warmupTask.value })
    {
      await emit(.warmupResolved(outcome, generation: warmGeneration))
    } else {
      await emit(.warmupTimedOut(generation: warmGeneration))
      // The timed-out warm-up keeps running natively. When it physically returns, clear the
      // orphan for this generation, so a deferred pressure request does not wait for the
      // next dictation's vend to clear it.
      if let model = kit as? LoadedWhisperModel<Driver.Handle> {
        let driver = driver
        Task {
          _ = await warmupTask.value
          await driver.waitForDrain(model.handle)
          await self.orphanWarmupDrained(warmGeneration)
        }
      }
    }
    guard warmGeneration == generation else { throw ASRLoadSupersededError() }
  }

  private func orphanWarmupDrained(_ orphanGeneration: UInt64) async {
    guard orphanGeneration == generation,
      case .ready(_, .some(let orphan)) = loadState, orphan.info.generation == orphanGeneration
    else { return }
    await emit(.drainResolved(didTimeOut: false, generation: orphanGeneration))
  }

  private func performWarmup(_ kit: any LoadedASRModel) async -> WarmupOutcome {
    guard let model = kit as? LoadedWhisperModel<Driver.Handle> else {
      return .threw(desc: "warm-up skipped: unexpected model type")
    }
    let silence = [Float](repeating: 0, count: 16_000)  // 1 s at 16 kHz
    let start = ContinuousClock.now
    do {
      _ = try await driver.transcribe(
        model.handle, samples: silence, language: nil, lane: .heart,
        onInferenceEntered: nil, onProgress: nil)
      // Recorded only for an actual completion: a throw or a timeout records nothing.
      let elapsed = ContinuousClock.now - start
      return .completed(ms: Int(elapsed / .milliseconds(1)))
    } catch {
      return .threw(desc: error.localizedDescription)
    }
  }

  /// The vend gate (state machine `vendRequested`): a clean ready model vends at once; an
  /// orphaned or live warm-up is drained under the same fail-open budget first.
  private func readyHandleAfterWarmupDrain() async -> Driver.Handle? {
    for effect in await emit(.vendRequested) {
      if case .beginDrain(let task, let drainGeneration) = effect {
        let outcome = await withDeadline(
          seconds: warmupDeadlineSeconds, operation: { await task.value })
        await emit(.drainResolved(didTimeOut: outcome == nil, generation: drainGeneration))
      }
    }
    return currentHandle()
  }

  private func currentHandle() -> Driver.Handle? {
    guard case .ready(let kit, _) = loadState else { return nil }
    return (kit as? LoadedWhisperModel<Driver.Handle>)?.handle
  }

  private func isCurrent(_ handle: Driver.Handle) -> Bool {
    switch loadState {
    case .warming(let kit, _, _, _), .ready(let kit, _):
      return (kit as? LoadedWhisperModel<Driver.Handle>)?.handle == handle
    case .idle, .loading:
      return false
    }
  }

  private func release(_ handle: Driver.Handle) async {
    guard liveHandles.remove(handle) != nil else { return }
    await driver.unload(handle)
  }

  // MARK: - State machine plumbing (ported from WhisperKitBackend)

  @discardableResult
  private func emit(_ event: LoadEvent, failure: (any Error)? = nil) async -> [Effect] {
    let (next, effects) = WhisperKitLoadStateMachine.transition(
      loadState, on: event, generation: generation)
    let previous = loadState.phase
    loadState = next
    reportModelScope(from: previous, on: event, failure: failure)
    for effect in effects { await runSideEffect(effect) }
    // A pressure request deferred by a load or warm-up is serviced once the model settles.
    if pressurePending, !pressureRunning, idleForPressure {
      Task { await self.servicePressure() }
    }
    return effects
  }

  /// #3546 §3.7 T3: crash-report model tags follow ACCEPTED transitions only. Same mapping
  /// as `WhisperKitBackend.reportModelScope` (that method holds the reasons).
  private func reportModelScope(
    from previous: LoadPhase, on event: LoadEvent, failure: (any Error)?
  ) {
    guard let deliverScope else { return }
    let current = loadState.phase
    var phase = scopePhase
    var requested = scopeRequested
    switch (previous, current) {
    case (.idle, .loading), (.ready, .loading):
      requested = scopeIdentity
      phase = .loading
    case (.loading, .ready), (.warming, .ready):
      phase = .loaded
    case (.loading, .idle), (.warming, .idle):
      if case .loadFailed = event {
        if let failure,
          failure is CancellationError || failure is ASRLoadCancelledError
            || failure is ASRLoadSupersededError
        {
          phase = .cancelled
        } else {
          phase = .failed
        }
      } else {
        phase = .cancelled
      }
    default:
      break
    }
    let serving = loadState.isReady ? scopeIdentity : nil
    let snapshot = ASRModelScopeOwner.Snapshot(
      requested: requested, phase: phase, serving: serving)
    let wasReady: Bool
    if case .ready = previous { wasReady = true } else { wasReady = false }
    let changed =
      phase != scopePhase || requested != scopeRequested || loadState.isReady != wasReady
    scopePhase = phase
    scopeRequested = requested
    guard changed else { return }
    scopeSequence &+= 1
    let sequence = scopeSequence
    lastScopeReport = (sequence, snapshot)
    Task { await deliverScope(sequence, snapshot) }
  }

  private func publishLoadingScope() async {
    guard let deliverScope, let report = lastScopeReport else { return }
    await deliverScope(report.sequence, report.snapshot)
  }

  private func runSideEffect(_ effect: Effect) async {
    switch effect {
    case .cancelLoadTask(let task): task.cancel()
    case .cancelWarmupTask(let task): task.cancel()
    case .cancelOrphanWarmupOnUnload(let task): task.cancel()
    case .recordWarmupMs(let ms):
      lastWarmupInferenceMs = ms
      await AppLogger.shared.log(
        "Whisper warm-up: completed(\(ms)ms)", level: .info, category: "TranscribeCppWhisper")
    case .logWarmupThrew(let desc):
      await AppLogger.shared.log(
        "Whisper warm-up: threw(\(desc))", level: .info, category: "TranscribeCppWhisper")
    case .logWarmupTimedOut:
      await AppLogger.shared.log(
        "Whisper warm-up: timed_out (fail-open ceiling)", level: .info,
        category: "TranscribeCppWhisper")
    case .logBudgetExhaustedVend:
      await AppLogger.shared.log(
        "Whisper warm-up: budget already exhausted — vending without re-draining",
        level: .info, category: "TranscribeCppWhisper")
    case .logDrainTimedOutVend:
      await AppLogger.shared.log(
        "Whisper warm-up: drain also timed_out — vending anyway", level: .info,
        category: "TranscribeCppWhisper")
    case .beginLoad, .joinLoad, .beginWarmup, .beginDrain, .throwSuperseded:
      break
    }
  }

  // MARK: - Transcription

  private var transcriptionProgressObserver: (@Sendable (Double) -> Void)?

  package func setTranscriptionProgressObserver(_ observer: (@Sendable (Double) -> Void)?) async {
    transcriptionProgressObserver = observer
  }

  /// 500 ms of trailing silence gives the decoder look-ahead at the end of speech; without it
  /// abruptly-ending audio loses its last words (BRAIN gotcha `silence-padding`). Padding is
  /// synthetic: no returned timestamp may land in it.
  static var silencePaddingSamples: Int { 8_000 }
  static var sampleRate: Int { 16_000 }

  package func transcribe(
    audioSamples: [Float], options: TranscriptionOptions,
    onInferenceEntered inferenceObserver: ASRInferenceEntryObserver? = nil
  ) async throws -> ASRResult {
    // #2918: captured and cleared BEFORE any suspension, so a refused call leaves nothing
    // installed for a later decode and a replacement during the suspension is not picked up.
    let progressObserver = transcriptionProgressObserver
    transcriptionProgressObserver = nil
    guard !admissionClosed else { throw ASRError.notReady }
    inFlight += 1
    defer { endOperation() }

    guard let handle = await readyHandleAfterWarmupDrain(), !admissionClosed else {
      throw ASRError.notReady
    }
    let envelope = Self.speechEnvelope(options.speechSegments, sampleCount: audioSamples.count)
    var input = Array(audioSamples[envelope])
    input.append(contentsOf: [Float](repeating: 0, count: Self.silencePaddingSamples))
    let progress = progressObserver.map(SeekProgressForwarder.init)
    // Native work can outlive a cancelled caller; its later seeks report nothing.
    defer { progress?.invalidate() }
    let start = ContinuousClock.now
    // #3546 §3.7 T1: the last cancellation check before the native boundary; the entry
    // observer fires inside the executor immediately before `transcribe_run`.
    try Task.checkCancellation()
    let run: TranscribeCppRunResult
    do {
      run = try await driver.transcribe(
        handle, samples: input, language: options.language, lane: .heart,
        onInferenceEntered: inferenceObserver, onProgress: progress?.forward)
    } catch {
      let mapped = Self.mapRunError(error)
      if mapped is CancellationError {
        // The executor releases a cancelled caller at once and aborts the native run. Return
        // only after that run physically ends, so callers that count this call as engine
        // occupancy (`VendorDecodeOccupancy`) never see idle while native work continues.
        progress?.invalidate()
        await driver.waitForDrain(handle)
      }
      throw mapped
    }
    let elapsed = ContinuousClock.now - start
    return Self.mapResult(
      run, languageHint: options.language, envelope: envelope,
      originalSampleCount: audioSamples.count,
      processingTime: Double(elapsed / .milliseconds(1)) / 1000,
      enableTimestamps: options.enableTimestamps)
  }

  static func mapRunError(_ error: any Error) -> any Error {
    switch error {
    case is CancellationError:
      return CancellationError()
    case TranscribeCppExecutor.ExecutorError.cancelled,
      TranscribeCppExecutor.ExecutorError.preempted:
      return CancellationError()
    case TranscribeCppExecutor.ExecutorError.modelUnavailable,
      TranscribeCppExecutor.ExecutorError.heartBusy:
      return ASRError.notReady
    case let native as TranscribeCppError where native.isAborted:
      return CancellationError()
    case let native as TranscribeCppError:
      return TranscribeCppWhisperError.runFailed(status: native.status)
    default:
      return error
    }
  }

  /// transcribe_run has no range field, so WhisperKit's per-range `clipTimestamps` becomes one
  /// envelope: first valid speech start to last valid speech end, clamped to the input. No
  /// usable range (file import, replay, empty or zero-width ranges) means the whole input:
  /// the kernel already decided to decode, and this never becomes a new no-speech gate.
  static func speechEnvelope(_ segments: [SpeechSegment], sampleCount: Int) -> Range<Int> {
    var lower: Int?
    var upper: Int?
    for segment in segments {
      let start = max(0, min(segment.startSample, sampleCount))
      let end = max(0, min(segment.endSample, sampleCount))
      guard end > start else { continue }
      lower = min(lower ?? start, start)
      upper = max(upper ?? end, end)
    }
    guard let lower, let upper else { return 0..<sampleCount }
    return lower..<upper
  }

  /// Maps one native run onto the caller's original input. Text is the repaired native text,
  /// edge whitespace trimmed as before, never changed to fit timings.
  static func mapResult(
    _ run: TranscribeCppRunResult, languageHint: String?, envelope: Range<Int>,
    originalSampleCount: Int, processingTime: TimeInterval, enableTimestamps: Bool
  ) -> ASRResult {
    let text = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
    // A hint is the forced-language result contract (`WhisperKitBackend.swift:983`); without
    // one, the native detection. The native call returns no detection when a hint was given.
    let language: String?
    if let languageHint {
      language = languageHint
    } else if let detected = run.detectedLanguage, !detected.isEmpty {
      language = detected
    } else {
      language = nil
    }
    let segmentTimings =
      enableTimestamps
      ? bindSegments(
        run.segments, text: text, envelope: envelope, originalSampleCount: originalSampleCount)
      : nil
    return ASRResult(
      text: text, language: language,
      duration: Double(originalSampleCount) / Double(sampleRate),
      processingTime: processingTime, backendType: .whisperKit,
      wordTimings: nil, wordTimingCoverage: nil, segmentTimings: segmentTimings)
  }

  /// Binds each segment's text to its UTF-16 range in `text`, in order, and restores its
  /// bounds to the original timeline. A segment whose text is not found after the previous
  /// one is left out (untimed), never guessed. A match is taken when it directly follows the
  /// previous bound segment (only whitespace between) or when it is the only remaining
  /// occurrence; after an unmatched segment, a text that still occurs more than once ahead is
  /// ambiguous and left out. Bounds that are invalid, or that start in the synthetic padding,
  /// are nil; an end past the real envelope is clamped to it.
  static func bindSegments(
    _ segments: [TranscribeCppSegment], text: String, envelope: Range<Int>,
    originalSampleCount: Int
  ) -> [ASRSegmentTiming] {
    let realEndMs = Int64(envelope.count) * 1000 / Int64(sampleRate)
    let offsetMs = Int64(envelope.lowerBound) * 1000 / Int64(sampleRate)
    let originalMs = Int64(originalSampleCount) * 1000 / Int64(sampleRate)
    var result: [ASRSegmentTiming] = []
    var cursor = text.startIndex
    var alignmentKnown = true
    for segment in segments {
      let piece = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !piece.isEmpty else { continue }
      guard let found = text.range(of: piece, range: cursor..<text.endIndex) else {
        alignmentKnown = false
        continue
      }
      let anchored = alignmentKnown && text[cursor..<found.lowerBound].allSatisfy(\.isWhitespace)
      if !anchored,
        text.range(of: piece, range: text.index(after: found.lowerBound)..<text.endIndex) != nil
      {
        alignmentKnown = false
        continue
      }
      alignmentKnown = true
      cursor = found.upperBound
      let lower = text.utf16.distance(from: text.startIndex, to: found.lowerBound)
      let upper = text.utf16.distance(from: text.startIndex, to: found.upperBound)
      var startMs: Int?
      var endMs: Int?
      if segment.startMs >= 0, segment.endMs >= segment.startMs, segment.startMs < realEndMs {
        let start = segment.startMs + offsetMs
        let end = min(segment.endMs, realEndMs) + offsetMs
        if end <= originalMs, let s = Int(exactly: start), let e = Int(exactly: end) {
          startMs = s
          endMs = e
        }
      }
      result.append(ASRSegmentTiming(range: lower..<upper, startMs: startMs, endMs: endMs))
    }
    return result
  }

  // MARK: - Language identification

  /// Window construction (fixed windows, full-window cap, dedup, prefix) is
  /// `WhisperKitBackend.observeLID`'s, unchanged (R2 characterization); only the per-window
  /// observation comes from the fork's language-probability API.
  package func observeLID(samples: [Float], maxWindows: Int) async -> LIDObservationBatch {
    guard !admissionClosed else { return .unavailable }
    inFlight += 1
    defer { endOperation() }
    guard let handle = await readyHandleAfterWarmupDrain(), !admissionClosed else {
      return .unavailable
    }
    let windows = Self.lidWindows(samples: samples, maxWindows: maxWindows)
    guard !windows.isEmpty else { return .noWindows }
    var observations: [RawLIDObservation] = []
    var lastError: String?
    for (index, window) in windows.enumerated() {
      if Task.isCancelled { return .cancelled }
      do {
        let observation = try await driver.detectLanguage(handle, samples: window, lane: .heart)
        observations.append(
          RawLIDObservation(argmaxLang: observation.code, logProb: observation.logProb))
      } catch {
        if Self.mapRunError(error) is CancellationError {
          // As in `transcribe`: returns only after the aborted native call ends.
          await driver.waitForDrain(handle)
          return .cancelled
        }
        lastError = error.localizedDescription
        await AppLogger.shared.log(
          "LID window \(index) failed: \(error.localizedDescription)", level: .info,
          category: "TranscribeCppWhisper")
      }
    }
    if observations.isEmpty { return .error(reason: lastError ?? "all_windows_failed") }
    return .observations(observations)
  }

  static func lidWindows(samples: [Float], maxWindows: Int) -> [[Float]] {
    let sampleRate = LanguageDetectorThresholds.sampleRate
    let totalSamples = samples.count
    var windows: [[Float]] = []
    var seenRanges: Set<[Int]> = []
    func appendIfNew(_ startIdx: Int, _ endIdx: Int) {
      guard endIdx > startIdx else { return }
      guard seenRanges.insert([startIdx, endIdx]).inserted else { return }
      windows.append(Array(samples[startIdx..<endIdx]))
    }
    for w in LanguageDetectorThresholds.windows {
      let startIdx = min(totalSamples, Int(w.start * Double(sampleRate)))
      let endIdx = min(totalSamples, Int(w.end * Double(sampleRate)))
      appendIfNew(startIdx, endIdx)
    }
    let fullEnd = min(
      totalSamples, Int(LanguageDetectorThresholds.fullWindowMaxSec * Double(sampleRate)))
    appendIfNew(0, fullEnd)
    return Array(windows.prefix(maxWindows))
  }

  // MARK: - Streaming

  /// #3735 §3.11: the rolling session arrives in Chunk 8. Until then no session is vended, which
  /// the adapter already treats as batch degradation: the take is decoded once, in batch, from
  /// the full recording.
  package func makeStreamingSession(
    options: TranscriptionOptions, vendorDecodeOccupancy: VendorDecodeOccupancy,
    onDecode: ASRInferenceEntryObserver?
  ) async -> (any WhisperKitIncrementalSession)? {
    nil
  }

  // MARK: - Unload and memory pressure

  /// Supersedes any in-flight load or warm-up, then frees every model this actor holds. The
  /// executor aborts and drains running work before it frees. Callers hold the app's
  /// engine-mutation authorization (the adapter's guarded unload).
  package func unload() async {
    // Coalesces: a second caller waits for the one teardown. Admission stays closed until
    // every handle is freed, so no replacement load can start under it.
    if unloading {
      await withCheckedContinuation { unloadWaiters.append($0) }
      return
    }
    unloading = true
    admissionClosed = true
    defer {
      unloading = false
      admissionClosed = false
      let waiters = unloadWaiters
      unloadWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }
    generation &+= 1
    await emit(.unloadRequested)
    for handle in Array(liveHandles) { await release(handle) }
  }

  private var unloading = false
  private var unloadWaiters: [CheckedContinuation<Void, Never>] = []

  /// Installs the unload authorizer and only then starts the memory-pressure monitor, in one
  /// actor step, so no pressure event can arrive before the authorization path exists. Called
  /// by the adapter that owns the EngineMutationScope.
  package func bindMemoryPressure(authorizer: @escaping UnloadAuthorizer) {
    authorizeUnload = authorizer
    startMemoryPressureMonitoring()
  }

  /// Installs the system memory-pressure source. Not started by default: activation belongs
  /// to `bindMemoryPressure(authorizer:)`.
  private func startMemoryPressureMonitoring() {
    guard pressureSource == nil else { return }
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.warning, .critical], queue: .global(qos: .utility))
    source.setEventHandler { [weak self] in
      Task { await self?.handleMemoryPressure() }
    }
    source.resume()
    pressureSource = source
  }

  /// A memory-pressure event. Unloads through the authorized path only when no load,
  /// warm-up, transcription or LID work exists; otherwise the request is
  /// deferred and retried when the last one ends. A refused authorization leaves the model
  /// ready.
  package func handleMemoryPressure() async {
    pressurePending = true
    await servicePressure()
  }

  private var idleForPressure: Bool {
    guard inFlight == 0 else { return false }
    switch loadState {
    case .idle: return true
    case .ready(_, let stale): return stale == nil
    case .loading, .warming: return false
    }
  }

  private func servicePressure() async {
    guard pressurePending, !pressureRunning, idleForPressure else { return }
    guard case .ready = loadState, let authorizeUnload else {
      pressurePending = false
      return
    }
    pressureRunning = true
    teardownRan = false
    let authorized = await authorizeUnload { [weak self] in await self?.pressureTeardown() ?? false }
    pressureRunning = false
    // Refused, or an authorizer that never ran the teardown: the model stays ready.
    if !authorized || !teardownRan { pressurePending = false }
    // Work that started while the claim was acquired deferred the teardown; when it has
    // already ended, retry now rather than at the next operation.
    if pressurePending, idleForPressure { Task { await self.servicePressure() } }
  }

  private var teardownRan = false

  /// Returns whether the model was unloaded.
  private func pressureTeardown() async -> Bool {
    teardownRan = true
    // Re-checked under the authorization: work may have started while it was acquired.
    guard case .ready = loadState else {
      pressurePending = false
      return false
    }
    guard idleForPressure else { return false }  // still pending; retried when that work ends
    admissionClosed = true
    if let handle = currentHandle() { await driver.waitForDrain(handle) }
    await unload()
    pressurePending = false
    return true
  }

  /// Ends one transcription or LID operation. A cancelled operation has already waited for
  /// its native call to end.
  private func endOperation() {
    inFlight -= 1
    if pressurePending { Task { await self.servicePressure() } }
  }

  var operationCountsForTesting: (inFlight: Int, pressurePending: Bool) {
    (inFlight, pressurePending)
  }
}

/// Forwards native seek progress as a 0...1 fraction, monotonically and only while it is
/// real: (advanced, total) frames with total > 0, never a value the engine did not report.
final class SeekProgressForwarder: @unchecked Sendable {
  private let lock = NSLock()
  private var highWater: Double = 0
  private var active = true
  private let observer: @Sendable (Double) -> Void

  init(observer: @escaping @Sendable (Double) -> Void) { self.observer = observer }

  /// Called when the caller's transcription ends: nothing is reported after it.
  func invalidate() { lock.withLock { active = false } }

  var forward: @Sendable (Int64, Int64) -> Void {
    { [self] advanced, total in
      guard total > 0, advanced >= 0 else { return }
      let fraction = Double(min(advanced, total)) / Double(total)
      lock.lock()
      defer { lock.unlock() }
      guard active, fraction > highWater else { return }
      highWater = fraction
      observer(fraction)
    }
  }
}
