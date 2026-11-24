@preconcurrency import AVFoundation
import Combine
import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprPipeline
@testable import EnviousWisprTranscribeCpp

/// #4896 tests for Whisper status 8 (`TRANSCRIBE_ERR_BACKEND`) forced unload + reload.
@MainActor
@Suite("Whisper status 8 forced unload and reload (#4896)", .serialized, .tags(.productOutcome))
struct WhisperBackendErrorReloadTests {
  private typealias Backend = TranscribeCppWhisperBackend<FakeReloadWhisperDriver>
  private static let speech: [Float] = [Float](repeating: 0.25, count: 16_000)

  private struct Harness {
    let adapter: WhisperEngineAdapter
    let backend: Backend
    let driver: FakeReloadWhisperDriver
    let kernel: RecordingSessionKernel
    let capture: FakeAudioCapture
    let vad: FakeVADSignalSource
    let paste: FakePasteTarget
    let driverUI: KernelDictationDriver
    let stateWaiter: PipelineStateWaiter
  }

  private func makeAdapter(
    _ driver: FakeReloadWhisperDriver = FakeReloadWhisperDriver(),
    scope: EngineMutationScope = .alwaysAllowedForTesting
  ) -> (backend: Backend, adapter: WhisperEngineAdapter) {
    let backend = Backend(
      driver: driver, modelVariant: "whisper-large-v3-turbo-Q8_0",
      admittedModelPath: { "turbo.gguf" }, modelIdentity: nil,
      scopeDelivery: nil, authorizeUnload: nil, warmupDeadlineSeconds: 5)
    return (backend, WhisperEngineAdapter(backend: backend, engineMutationScope: scope))
  }

  private func makeHarness(
    driver: FakeReloadWhisperDriver = FakeReloadWhisperDriver(),
    retryTimeout: Double? = nil,
    onRetryTimeout: (@MainActor () -> Void)? = nil
  ) -> Harness {
    let (backend, adapter) = makeAdapter(driver)
    let kernelAdapter: any ASREngineAdapter =
      retryTimeout.map { FastRetryTimeoutAdapter(wrapping: adapter, retryTimeoutSeconds: $0, onBumpRetryGeneration: onRetryTimeout) } ?? adapter
    let capture = FakeAudioCapture(), vad = FakeVADSignalSource(), paste = FakePasteTarget()
    let kernel = RecordingSessionKernel(
      adapter: kernelAdapter, audioCapture: capture, vad: vad, currentTick: { 0 }, sleepTicks: { _ in },
      processText: { raw, _ in raw }, store: { _, _, _ in },
      deliver: { text, _ in paste.attemptPaste(text) == .pasted ? .pasted : .clipboardOnly },
      engineMutationScope: .alwaysAllowedForTesting, minimumRecordingTicks: 0)
    let observer = KernelHeartPathTelemetryObserver(
      kernel: kernel, audioCapture: capture,
      emitter: HeartPathTelemetryEmitter(backend: .whisper, captureTelemetry: CaptureTelemetryState()), emitLifecycleEvent: { _ in })
    let steps = LimbSteps(
      snippetExpansion: SnippetExpansionStep(), wordCorrection: WordCorrectionStep(), learnedWordCheck: LearnedWordCheckStep(),
      fillerRemoval: FillerRemovalStep(), emojiFormatter: EmojiFormatterStep(), inverseTextNormalization: InverseTextNormalizationStep(),
      englishSpelling: EnglishSpellingStep(target: .text), llmPolish: LLMPolishStep(keychainManager: KeychainManager(), localPolishers: .llamaForTests),
      englishSpellingAfterPolish: EnglishSpellingStep(target: .polishedText), emojiRestore: EmojiRestoreStep(), casualEnding: CasualEndingStep())
    let driverUI = KernelDictationDriver(
      kernel: kernel, observer: observer, outcome: KernelFinalizationOutcome(), context: KernelSessionContext(),
      steps: steps, adapter: kernelAdapter, engineMutationScope: .alwaysAllowedForTesting)
    driverUI.start()
    return Harness(adapter: adapter, backend: backend, driver: driver, kernel: kernel, capture: capture, vad: vad, paste: paste, driverUI: driverUI, stateWaiter: PipelineStateWaiter(driverUI))
  }

  private func runTake(_ h: Harness, timeoutSeconds: Double = 5.0) async {
    let deadline = Duration.seconds(timeoutSeconds)
    h.kernel.start(
      config: .testDefault(autoPasteToActiveApp: true, languageMode: .locked("en"), useStreamingASR: false, modelUnloadPolicy: .never),
      microphoneStartDeadline: nil)
    await h.stateWaiter.wait(for: { s in
      if case .loadingModel = s { return false }; if case .transcribing = s { return false }; if case .polishing = s { return false }
      if case .idle = s { return h.kernel.recordingOutcome != nil }
      return true
    }, timeout: deadline)
    guard h.kernel.state == .live else { Issue.record("kernel exited before .live: \(h.kernel.state)"); return }
    let epochBefore = h.kernel.workEpoch, epochSig = SignalWaiter()
    withObservationTracking { _ = h.kernel.workEpoch } onChange: { Task { @MainActor in epochSig.signal() } }
    h.capture.deliverBuffer(frameCount: 16_000, amplitude: 0.25)
    h.vad.evidence = .voiced; h.vad.segments = [SpeechSegment(startSample: 0, endSample: 16_000)]
    if h.kernel.workEpoch == epochBefore { _ = await epochSig.wait(what: "acceptAudio", timeoutSeconds: timeoutSeconds) }
    h.kernel.requestStop()
    await h.stateWaiter.wait(for: { s in
      switch s {
      case .complete, .error, .advisory, .idle: return h.kernel.recordingOutcome != nil
      case .loadingModel, .recording, .transcribing, .polishing: return false
      }
    }, timeout: deadline)
  }

  private func runDirect(_ adapter: WhisperEngineAdapter) async throws -> ASREngineOutcome {
    let sid = SessionID()
    try await adapter.beginSession(sid, options: TranscriptionOptions(language: "en"), streaming: false)
    let buf = try #require(FakeAudioCapture.makeBuffer(samples: Self.speech))
    adapter.acceptAudio(AudioBufferHandoff(buffer: buf, frameCount: Self.speech.count, sequence: 1, sessionID: sid))
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: Self.speech.count)], captureSamples: Self.speech)
    return await adapter.finalize(batchSamples: [])
  }

  @Test("status 8 twice frees handle once under .never and next take reloads and pastes")
  func fullTakeFailureForcesUnloadAndReloadsTake2() async throws {
    let h = makeHarness(); try await h.adapter.warmUp(modelReceipt: nil)
    let calls = LockedCounter(), retrySawZeroUnloads = LockedCounter()
    h.driver.onTranscribeAsync = { [driver = h.driver] h in
      if h == 1, calls.incrementAndGet() == 2, driver.unloadedHandles.isEmpty { _ = retrySawZeroUnloads.incrementAndGet() }
    }
    h.driver.poisonHandle(1, status: 8)
    await runTake(h)
    #expect(retrySawZeroUnloads.current == 1 && h.driver.transcribeHandles == [1, 1, 1] && h.adapter.readiness == .notReady)
    #expect(await h.driver.waitFor("uc:1") && h.driver.unloadedHandles == [1] && h.paste.pastedTexts.isEmpty)
    #expect(await h.backend.isReady == false)
    h.kernel.reset(); await runTake(h)
    #expect(h.driver.loadedHandles == [1, 2] && h.adapter.readiness == .ready && h.paste.pastedTexts == ["ok from handle 2"])
  }

  @Test("retry timeout after status 8 primary finalize still forces unload at finishTerminal")
  func retryTimeoutAfterStatus8StillForcesUnload() async throws {
    let calls = LockedCounter(), retryTimedOut = LockedCounter(), gate = SignalWaiter()
    let h = makeHarness(retryTimeout: 0.05, onRetryTimeout: { _ = retryTimedOut.incrementAndGet(); gate.signal() })
    defer { gate.signal() }; try await h.adapter.warmUp(modelReceipt: nil)
    h.driver.onTranscribeAsync = { handle in
      guard handle == 1 else { return }
      if calls.incrementAndGet() == 1 { throw TranscribeCppError(rawStatus: 8) }
      _ = await gate.wait(what: "retry timeout signal", timeoutSeconds: 5.0)
    }
    await runTake(h, timeoutSeconds: 2.0)
    // [1, 1] = warmUp probe + primary status-8 finalize; Phase-2 retry entry vs deadline is
    // uncoupled under load (`retryTimedOut == 1` proves the kernel's retry timeout fired).
    #expect(h.driver.transcribeHandles.starts(with: [1, 1]) && retryTimedOut.current == 1 && h.adapter.readiness == .notReady)
    #expect(await h.driver.waitFor("uc:1") && h.driver.unloadedHandles == [1])
  }

  @Test("status 7, cancel, .empty, LID, rolling, and meeting status 8 do not unload handle")
  func nonStatus8FailuresCancelEmptyAndRollingDoNotUnload() async throws {
    let h7 = makeHarness(); try await h7.adapter.warmUp(modelReceipt: nil); h7.driver.poisonHandle(1, status: 7)
    await runTake(h7)
    #expect(h7.driver.transcribeHandles == [1, 1, 1] && h7.driver.unloadedHandles.isEmpty && h7.adapter.readiness == .ready)

    let (_, adCancel) = makeAdapter(); try await adCancel.warmUp(modelReceipt: nil)
    try await adCancel.beginSession(SessionID(), options: TranscriptionOptions(language: "en"), streaming: false)
    await adCancel.cancel(); adCancel.applyUnloadPolicy(.never); #expect(adCancel.readiness == .ready)

    let emptyDrv = FakeReloadWhisperDriver(), (_, adEmpty) = makeAdapter(emptyDrv)
    try await adEmpty.warmUp(modelReceipt: nil); emptyDrv.setEmptyResult(for: 1)
    _ = try await runDirect(adEmpty); adEmpty.applyUnloadPolicy(.never)
    #expect(emptyDrv.unloadedHandles.isEmpty && adEmpty.readiness == .ready)

    let h = makeHarness(); try await h.adapter.warmUp(modelReceipt: nil); h.driver.poisonLID(1, status: 8)
    _ = await h.backend.observeLID(samples: Self.speech, maxWindows: 1); h.driver.poisonHandle(1, status: 8)
    await #expect(throws: TranscribeCppWhisperError.runFailed(status: 8)) { _ = try await h.backend.decodeForRollingSession(samples: Self.speech, language: "en", onDecode: {}) }
    await #expect(throws: TranscribeCppWhisperError.runFailed(status: 8)) { _ = try await h.backend.transcribeForMeeting(audioSamples: Self.speech, language: "en") }
    h.adapter.applyUnloadPolicy(.never)
    #expect(h.driver.unloadedHandles.isEmpty && h.adapter.readiness == .ready)
    #expect(await h.backend.isReady == true)
  }

  @Test("held teardown keeps .notReady against .never/cancel and warmUp joins before loading handle 2")
  func heldTeardownConcurrencyAndJoin() async throws {
    let h = makeHarness(); try await h.adapter.warmUp(modelReceipt: nil)
    h.driver.poisonHandle(1, status: 8); h.driver.holdUnload(1); defer { h.driver.releaseUnload(1) }
    _ = try await runDirect(h.adapter); _ = await h.adapter.retryDecode(inputSamples: Self.speech)
    h.adapter.applyUnloadPolicy(.immediately); #expect(h.adapter.readiness == .notReady)
    await h.driver.waitFor("us:1")
    try await h.adapter.warmUpFromCache(); h.adapter.cancelPendingUnload(); h.adapter.applyUnloadPolicy(.never)
    let entered = SignalWaiter(), cancelEntered = SignalWaiter()
    let cancelledWarm = Task { cancelEntered.signal(); try await h.adapter.warmUp(modelReceipt: nil) }
    _ = await cancelEntered.wait(what: "cancelled warmUp"); await h.adapter.cancel()
    let warmTask = Task { entered.signal(); try await h.adapter.warmUp(modelReceipt: nil) }
    _ = await entered.wait(what: "warmUp entered"); _ = await h.backend.isReady
    #expect(h.driver.loadedHandles == [1] && h.adapter.readiness == .notReady)
    h.driver.releaseUnload(1); try await warmTask.value
    await #expect(throws: CancellationError.self) { try await cancelledWarm.value }
    #expect(h.driver.unloadedHandles == [1] && h.driver.loadedHandles == [1, 2] && h.adapter.readiness == .ready)
  }

  @Test("slow finishing unload settles warm without Try again; hung unload keeps MainActor unblocked")
  func hungUnloadDoesNotBlockMainThreadAndHitsColdPressGuard() async throws {
    let h = makeHarness(); try await h.adapter.warmUp(modelReceipt: nil)
    h.driver.poisonHandle(1, status: 8); h.driver.holdUnload(1); defer { h.driver.releaseUnload(1) }
    _ = try await runDirect(h.adapter); _ = await h.adapter.retryDecode(inputSamples: Self.speech)
    h.adapter.applyUnloadPolicy(.immediately); await h.driver.waitFor("us:1")
    let (overlay, _) = OverlayTestDouble.headlessDirectorWithHost()
    var retryChecked = false
    let settled = SignalWaiter(), warmingSignal = SignalWaiter(), readySignal = SignalWaiter()
    h.driverUI.onEngineWarmSettled = { settled.signal() }
    let c1 = overlay.renderModel.$state.sink {
      guard case .notice(let n)? = $0.presentation?.content else { return }
      if n.kind == .warmingUp { warmingSignal.signal() }
      if n.kind == .ready { readySignal.signal() }
    }
    defer { c1.cancel() }
    ColdPressGuard.handle(overlay: overlay, active: h.driverUI, backendTag: "whisper", readiness: h.driverUI.engineReadiness, confirmExplicitRetry: { retryChecked = true; return false })
    var mainRan = false; await Task { @MainActor in mainRan = true }.value
    _ = await warmingSignal.wait(what: ".warmingUp notice")
    #expect(mainRan && h.driverUI.engineReadiness == .notReady && h.driver.loadedHandles == [1])
    h.driver.releaseUnload(1)
    _ = await settled.wait(what: "onEngineWarmSettled")
    _ = await readySignal.wait(what: ".ready notice")
    #expect(!retryChecked && h.driver.loadedHandles == [1, 2] && h.driverUI.engineReadiness == .ready)
  }

  @Test("refused claim keeps forced teardown pending without loops or timers and reloads once authorized")
  func refusedClaimKeepsForcedTeardownPendingUntilAuthorizedWarmUp() async throws {
    let driver = FakeReloadWhisperDriver(); var allowed = true; let refused = SignalWaiter()
    let scope = EngineMutationScope.live(tryBegin: { allowed }, end: { false }, wake: {}, onRefused: { _ in Task { @MainActor in refused.signal() } })
    let (backend, adapter) = makeAdapter(driver, scope: scope); try await adapter.warmUp(modelReceipt: nil)
    driver.poisonHandle(1, status: 8); _ = try await runDirect(adapter); _ = await adapter.retryDecode(inputSamples: Self.speech)
    allowed = false; adapter.applyUnloadPolicy(.immediately); _ = await refused.wait(what: "claim refused")
    #expect(adapter.shouldForceUnloadAfterFailure && adapter.readiness == .notReady && driver.unloadedHandles.isEmpty)
    adapter.applyUnloadPolicy(.fiveMinutes)
    #expect(adapter.modelUnloadTaskForUnitTests == nil && adapter.shouldForceUnloadAfterFailure)
    await #expect(throws: ASRLoadSupersededError.self) { try await adapter.warmUp(modelReceipt: nil) }
    #expect(await backend.isReady == true && driver.loadedHandles == [1])
    await adapter.cancel()
    #expect(adapter.shouldForceUnloadAfterFailure && adapter.readiness == .notReady)
    allowed = true; try await adapter.warmUp(modelReceipt: nil)
    #expect(driver.unloadedHandles == [1] && driver.loadedHandles == [1, 2] && adapter.readiness == .ready && !adapter.shouldForceUnloadAfterFailure)
  }

  @Test("transcribeForMeeting aborted by backend.unload() yields MeetingEngineYield")
  func transcribeForMeetingDuringUnloadThrowsYield() async throws {
    let driver = FakeReloadWhisperDriver(); let (backend, _) = makeAdapter(driver); try await backend.prepare()
    driver.holdTranscribe(1, abortWhenUnloaded: true)
    let task = Task { try await backend.transcribeForMeeting(audioSamples: Self.speech, language: "en") }
    _ = await driver.waitFor("ts:1#2"); await backend.unload()
    let guardTask = Task { try? await Task.sleep(for: .seconds(2)); if !Task.isCancelled { Issue.record("abort timed out"); driver.releaseTranscribe(1) } }
    defer { guardTask.cancel() }
    await #expect(throws: MeetingEngineYield.self) { _ = try await task.value }
    #expect(driver.unloadedHandles == [1])
  }
}

private final class FakeReloadWhisperDriver: WhisperExecutorDriving, @unchecked Sendable {
  typealias Handle = Int
  private let lock = NSLock()
  private var nextHandle = 1, _loaded: [Int] = [], _unloaded: [Int] = [], _transcribes: [Int] = []
  private var poisoned: [Int: Int32] = [:], poisonedLID: [Int: Int32] = [:], empty: Set<Int> = []
  private var heldUnloads: Set<Int> = [], events: Set<String> = [], eventWaiters: [String: [(UUID, CheckedContinuation<Bool, Never>)]] = [:]
  private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
  private var unloadConts: [Int: CheckedContinuation<Void, Never>] = [:], txConts: [Int: CheckedContinuation<Void, Never>] = [:]
  private var heldTx: [Int: Bool] = [:], abortedTx: Set<Int> = [], txOcc: [Int: Int] = [:]
  var onTranscribeAsync: (@Sendable (Int) async throws -> Void)?
  var loadedHandles: [Int] { lock.withLock { _loaded } }
  var unloadedHandles: [Int] { lock.withLock { _unloaded } }
  var transcribeHandles: [Int] { lock.withLock { _transcribes } }

  func poisonHandle(_ h: Int, status: Int32) { lock.withLock { poisoned[h] = status } }
  func poisonLID(_ h: Int, status: Int32) { lock.withLock { poisonedLID[h] = status } }
  func setEmptyResult(for h: Int) { lock.withLock { _ = empty.insert(h) } }
  func holdUnload(_ h: Int) { lock.withLock { _ = heldUnloads.insert(h) } }
  func releaseUnload(_ h: Int) { lock.withLock { heldUnloads.remove(h); return unloadConts.removeValue(forKey: h) }?.resume() }
  func holdTranscribe(_ h: Int, abortWhenUnloaded: Bool = false) { lock.withLock { abortedTx.remove(h); heldTx[h] = abortWhenUnloaded } }
  func releaseTranscribe(_ h: Int) { lock.withLock { heldTx.removeValue(forKey: h); return txConts.removeValue(forKey: h) }?.resume() }

  private func signal(_ key: String) {
    let conts = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in _ = events.insert(key); return (eventWaiters.removeValue(forKey: key) ?? []).map(\.1) }
    conts.forEach { $0.resume(returning: true) }
  }

  @discardableResult
  func waitFor(_ key: String, timeoutSeconds: Double = 2.0) async -> Bool {
    let id = UUID()
    let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      let already = lock.withLock { () -> Bool in
        if events.contains(key) { return true }
        eventWaiters[key, default: []].append((id, cont))
        timeoutTasks[id] = Task { [weak self] in
          try? await Task.sleep(for: .seconds(timeoutSeconds))
          guard !Task.isCancelled, let self else { return }
          let timedOut = self.lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            self.timeoutTasks.removeValue(forKey: id)
            guard var list = self.eventWaiters[key], let i = list.firstIndex(where: { $0.0 == id }) else { return nil }
            let c = list.remove(at: i).1
            if list.isEmpty { self.eventWaiters.removeValue(forKey: key) } else { self.eventWaiters[key] = list }
            return c
          }
          if let timedOut { Issue.record("timed out waiting for \(key)"); timedOut.resume(returning: false) }
        }
        return false
      }
      if already { cont.resume(returning: true) }
    }
    lock.withLock { timeoutTasks.removeValue(forKey: id) }?.cancel()
    return ok
  }

  func load(modelPath: String, lane: TranscribeCppExecutor.Lane) async throws -> Int { lock.withLock { let h = nextHandle; nextHandle += 1; _loaded.append(h); return h } }
  func detectLanguage(_ h: Int, samples: [Float], lane: TranscribeCppExecutor.Lane) async throws -> TranscribeCppLanguageObservation {
    if let s = lock.withLock({ poisonedLID[h] }) { throw TranscribeCppError(rawStatus: s) }
    return TranscribeCppLanguageObservation(code: "en", logProb: -0.01)
  }
  func transcribe(_ h: Int, samples: [Float], language: String?, lane: TranscribeCppExecutor.Lane, onInferenceEntered: (@Sendable () -> Void)?, onProgress: (@Sendable (Int64, Int64) -> Void)?) async throws -> TranscribeCppRunResult {
    onInferenceEntered?()
    let (occ, shouldHold) = lock.withLock { () -> (Int, Bool) in _transcribes.append(h); let o = (txOcc[h] ?? 0) + 1; txOcc[h] = o; return (o, heldTx[h] != nil) }
    signal("ts:\(h)#\(occ)")
    if shouldHold {
      await withCheckedContinuation { c in if lock.withLock({ if heldTx[h] == nil { return false }; txConts[h] = c; return true }) == false { c.resume() } }
      if lock.withLock({ abortedTx.remove(h) != nil }) { throw TranscribeCppError(rawStatus: TranscribeCppError.abortedStatus) }
    }
    if let asyncHook = onTranscribeAsync { try await asyncHook(h) }
    let (s, isEmpty) = lock.withLock { (poisoned[h], empty.contains(h)) }
    if let s { throw TranscribeCppError(rawStatus: s) }
    if isEmpty { return TranscribeCppRunResult(text: "", detectedLanguage: "en", segments: []) }
    return TranscribeCppRunResult(text: " ok from handle \(h)", detectedLanguage: "en", segments: [TranscribeCppSegment(startMs: 0, endMs: 900, text: " ok from handle \(h)")])
  }
  func waitForDrain(_ handle: Int) async {}
  func unload(_ h: Int) async {
    let (shouldHold, abortCont) = lock.withLock { () -> (Bool, CheckedContinuation<Void, Never>?) in
      var ac: CheckedContinuation<Void, Never>?
      if heldTx[h] == true { heldTx.removeValue(forKey: h); _ = abortedTx.insert(h); ac = txConts.removeValue(forKey: h) }
      return (heldUnloads.contains(h), ac)
    }
    signal("us:\(h)"); abortCont?.resume()
    if shouldHold { await withCheckedContinuation { c in if lock.withLock({ if !heldUnloads.contains(h) { return false }; unloadConts[h] = c; return true }) == false { c.resume() } } }
    lock.withLock { _unloaded.append(h) }; signal("uc:\(h)")
  }
  func awaitSettled(openedOn lane: TranscribeCppExecutor.Lane) async -> Int { 0 }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock(); private var value = 0
  var current: Int { lock.withLock { value } }
  func incrementAndGet() -> Int { lock.withLock { value += 1; return value } }
}

@MainActor
private final class SignalWaiter {
  private var signaled = false, waiter: CheckedContinuation<Bool, Never>?
  func signal() { guard !signaled else { return }; signaled = true; let c = waiter; waiter = nil; c?.resume(returning: true) }
  func wait(what: String, timeoutSeconds: Double = 2.0) async -> Bool {
    if signaled { return true }
    let t = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(timeoutSeconds)); guard !Task.isCancelled, let self, let c = self.waiter else { return }
      self.waiter = nil; Issue.record("timed out waiting for \(what)"); c.resume(returning: false)
    }
    let ok = await withCheckedContinuation { c in if signaled { c.resume(returning: true) } else { waiter = c } }
    t.cancel(); return ok
  }
}

@MainActor
private final class FastRetryTimeoutAdapter: ASREngineAdapter, @unchecked Sendable {
  private let inner: WhisperEngineAdapter; private let retryTimeoutSeconds: Double; private let onBumpRetryGeneration: (@MainActor () -> Void)?
  init(wrapping inner: WhisperEngineAdapter, retryTimeoutSeconds: Double, onBumpRetryGeneration: (@MainActor () -> Void)? = nil) {
    self.inner = inner; self.retryTimeoutSeconds = retryTimeoutSeconds; self.onBumpRetryGeneration = onBumpRetryGeneration
  }
  var engineIdentity: ASREngineIdentity { inner.engineIdentity }
  var capabilities: ASREngineCapabilities { inner.capabilities }
  var readiness: ASREngineReadiness { inner.readiness }
  var servingModelIdentity: ASRModelIdentity? { inner.servingModelIdentity }
  func requestedModelIdentity() -> ASRModelIdentity? { inner.requestedModelIdentity() }
  func inferenceEntry(for session: SessionID) -> ASRInferenceEntry? { inner.inferenceEntry(for: session) }
  var onInferenceEntryRecorded: (@MainActor (SessionID) -> Void)? { get { inner.onInferenceEntryRecorded } set { inner.onInferenceEntryRecorded = newValue } }
  var lastWarmupInferenceMs: Int? { inner.lastWarmupInferenceMs }
  func warmUp(modelReceipt: WarmUpModelReceipt?) async throws { try await inner.warmUp(modelReceipt: modelReceipt) }
  var loadProgress: AsyncStream<ASRLoadProgressTick>? { inner.loadProgress }
  var lastObservedPhase: String { inner.lastObservedPhase }
  var warmupStallGuardEligible: Bool { inner.warmupStallGuardEligible }
  func beginSession(_ id: SessionID, options: TranscriptionOptions, streaming: Bool) async throws { try await inner.beginSession(id, options: options, streaming: streaming) }
  func acceptAudio(_ buffer: AudioBufferHandoff) { inner.acceptAudio(buffer) }
  func finalize(batchSamples: [Float]) async -> ASREngineOutcome { await inner.finalize(batchSamples: batchSamples) }
  var finalizeProgress: AsyncStream<ASRFinalizeProgressTick>? { inner.finalizeProgress }
  var isVendorDecodeInFlight: Bool { inner.isVendorDecodeInFlight }
  func retryDecode(inputSamples: [Float]) async -> ASREngineOutcome { await inner.retryDecode(inputSamples: inputSamples) }
  func retryDecodeTimeoutSeconds(forSampleCount sampleCount: Int) -> Double { retryTimeoutSeconds }
  func bumpRetryGeneration() { onBumpRetryGeneration?(); inner.bumpRetryGeneration() }
  func cancel() async { await inner.cancel() }
  func recoverFromWedge() async { await inner.recoverFromWedge() }
  var onEngineInterrupted: (@MainActor () -> Void)? { get { inner.onEngineInterrupted } set { inner.onEngineInterrupted = newValue } }
  func recoverFromASRInterruption() async -> ASRInterruptionRecoveryOutcome { await inner.recoverFromASRInterruption() }
  func applyUnloadPolicy(_ policy: ModelUnloadPolicy) { inner.applyUnloadPolicy(policy) }
  var lastResult: ASRResult? { inner.lastResult }
  func warmUpFromCache() async throws { try await inner.warmUpFromCache() }
  func cancelPendingUnload() { inner.cancelPendingUnload() }
  func observeSpeechSegments(_ segments: [SpeechSegment], rawCaptureSamples: [Float]) { inner.observeSpeechSegments(segments, rawCaptureSamples: rawCaptureSamples) }
  var shouldForceUnloadAfterFailure: Bool { inner.shouldForceUnloadAfterFailure }
}
