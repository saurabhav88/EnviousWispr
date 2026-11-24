@preconcurrency import AVFoundation
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

/// #4896 verification tests for Whisper status 8 (`TRANSCRIBE_ERR_BACKEND`) forced unload + reload.
@MainActor
@Suite("Whisper status 8 forced unload and reload (#4896)", .serialized, .tags(.productOutcome))
struct WhisperBackendErrorReloadTests {

  private typealias Backend = TranscribeCppWhisperBackend<FakeReloadWhisperDriver>

  private static let speech: [Float] =
    [Float](repeating: 0.25, count: 16_000)

  private func makeBackend(_ driver: FakeReloadWhisperDriver) -> Backend {
    Backend(
      driver: driver,
      modelVariant: "whisper-large-v3-turbo-Q8_0",
      admittedModelPath: { "turbo.gguf" },
      modelIdentity: nil,
      scopeDelivery: nil,
      authorizeUnload: nil,
      warmupDeadlineSeconds: 5
    )
  }

  private func makeAdapter(
    _ driver: FakeReloadWhisperDriver,
    scope: EngineMutationScope = .alwaysAllowedForTesting,
    faultController: BatchDecodeFaultController? = nil
  ) -> (backend: Backend, adapter: WhisperEngineAdapter) {
    let backend = makeBackend(driver)
    let adapter = WhisperEngineAdapter(
      backend: backend,
      engineMutationScope: scope,
      batchDecodeFaultController: faultController
    )
    return (backend, adapter)
  }

  private struct KernelHarness {
    let adapter: WhisperEngineAdapter
    let backend: Backend
    let driver: FakeReloadWhisperDriver
    let kernel: RecordingSessionKernel
    let capture: FakeAudioCapture
    let vad: FakeVADSignalSource
    let paste: FakePasteTarget
    let kernelDriver: KernelDictationDriver
  }

  private func makeKernelHarness(
    driver: FakeReloadWhisperDriver = FakeReloadWhisperDriver(),
    faultController: BatchDecodeFaultController? = nil
  ) -> KernelHarness {
    let (backend, adapter) = makeAdapter(driver, faultController: faultController)
    let capture = FakeAudioCapture()
    let vad = FakeVADSignalSource()
    let paste = FakePasteTarget()
    let kernel = RecordingSessionKernel(
      adapter: adapter,
      audioCapture: capture,
      vad: vad,
      currentTick: { 0 },
      sleepTicks: { _ in },
      processText: { raw, _ in raw },
      store: { _, _, _ in },
      deliver: { text, _ in paste.attemptPaste(text) == .pasted ? .pasted : .clipboardOnly },
      engineMutationScope: .alwaysAllowedForTesting,
      minimumRecordingTicks: 0
    )
    let observer = KernelHeartPathTelemetryObserver(
      kernel: kernel,
      audioCapture: capture,
      emitter: HeartPathTelemetryEmitter(
        backend: .whisper, captureTelemetry: CaptureTelemetryState()),
      emitLifecycleEvent: { _ in }
    )
    let steps = LimbSteps(
      snippetExpansion: SnippetExpansionStep(),
      wordCorrection: WordCorrectionStep(),
      learnedWordCheck: LearnedWordCheckStep(),
      fillerRemoval: FillerRemovalStep(),
      emojiFormatter: EmojiFormatterStep(),
      inverseTextNormalization: InverseTextNormalizationStep(),
      englishSpelling: EnglishSpellingStep(target: .text),
      llmPolish: LLMPolishStep(keychainManager: KeychainManager(), localPolishers: .llamaForTests),
      englishSpellingAfterPolish: EnglishSpellingStep(target: .polishedText),
      emojiRestore: EmojiRestoreStep(),
      casualEnding: CasualEndingStep()
    )
    let kernelDriver = KernelDictationDriver(
      kernel: kernel,
      observer: observer,
      outcome: KernelFinalizationOutcome(),
      context: KernelSessionContext(),
      steps: steps,
      adapter: adapter,
      engineMutationScope: .alwaysAllowedForTesting
    )
    kernelDriver.start()
    return KernelHarness(
      adapter: adapter,
      backend: backend,
      driver: driver,
      kernel: kernel,
      capture: capture,
      vad: vad,
      paste: paste,
      kernelDriver: kernelDriver
    )
  }

  private func runKernelTake(
    _ h: KernelHarness,
    policy: ModelUnloadPolicy = .never,
    timeoutSeconds: Double = 0
  ) async {
    h.kernel.start(
      config: .testDefault(
        autoPasteToActiveApp: true,
        languageMode: .locked("en"),
        useStreamingASR: false,
        modelUnloadPolicy: policy
      ),
      microphoneStartDeadline: nil
    )
    await drainUntil(
      { h.kernel.state == .live || h.kernel.recordingOutcome != nil },
      what: "kernel to reach .live (state=\(h.kernel.state))"
    )
    guard h.kernel.state == .live else {
      Issue.record(
        "kernel exited before .live: state=\(h.kernel.state) outcome=\(String(describing: h.kernel.recordingOutcome))"
      )
      return
    }
    h.capture.deliverBuffer(frameCount: 16_000, amplitude: 0.25)
    h.vad.evidence = .voiced
    h.vad.segments = [SpeechSegment(startSample: 0, endSample: 16_000)]
    await drainReadyWork(h.kernel)
    h.kernel.requestStop()
    if timeoutSeconds > 0 {
      await waitForKernelConclusion(h.kernel, timeoutSeconds: timeoutSeconds)
    } else {
      await drainUntilConcluded(h.kernel)
    }
  }

  private func drainUntil(_ signal: @MainActor () -> Bool, what: String) async {
    for _ in 0..<5_000 {
      if signal() { return }
      await Task.yield()
    }
    Issue.record("timed out waiting for \(what)")
  }

  private func waitForKernelConclusion(_ kernel: RecordingSessionKernel, timeoutSeconds: Double) async {
    let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
    while kernel.recordingOutcome == nil, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(50))
    }
    guard kernel.recordingOutcome != nil else {
      Issue.record("kernel timed out after \(timeoutSeconds)s waiting for recordingOutcome (state=\(kernel.state))")
      return
    }
    await drainReadyWork(kernel)
  }

  private func drainReadyWork(_ kernel: RecordingSessionKernel) async {
    var last = kernel.workEpoch
    var stable = 0
    for _ in 0..<2_000 {
      await Task.yield()
      let now = kernel.workEpoch
      if now == last {
        stable += 1
      } else {
        stable = 0
        last = now
      }
      if stable >= 64, !kernel.hasUnconsumedRecordingExit { return }
    }
    Issue.record("kernel did not settle in drainReadyWork (state=\(kernel.state))")
  }

  private func drainUntilConcluded(_ kernel: RecordingSessionKernel) async {
    for _ in 0..<5_000 {
      if kernel.recordingOutcome != nil { break }
      await Task.yield()
    }
    guard kernel.recordingOutcome != nil else {
      Issue.record("kernel did not conclude in drainUntilConcluded (state=\(kernel.state))")
      return
    }
    await drainReadyWork(kernel)
  }

  private func awaitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<5_000 {
      if predicate() { return true }
      await Task.yield()
    }
    return predicate()
  }

  private func runDirectAdapterTake(
    _ adapter: WhisperEngineAdapter,
    samples: [Float] = Self.speech,
    language: String? = "en"
  ) async throws -> ASREngineOutcome {
    let sid = SessionID()
    try await adapter.beginSession(
      sid,
      options: TranscriptionOptions(language: language),
      streaming: false
    )
    let buffer = try #require(FakeAudioCapture.makeBuffer(samples: samples))
    adapter.acceptAudio(
      AudioBufferHandoff(buffer: buffer, frameCount: samples.count, sequence: 1, sessionID: sid)
    )
    adapter.observeSpeechSegments(
      [SpeechSegment(startSample: 0, endSample: samples.count)],
      captureSamples: samples
    )
    return await adapter.finalize(batchSamples: [])
  }

  // MARK: - 1. Full kernel take failure -> retry -> forced unload -> reload -> next take succeeds

  @Test("status 8 full take failure retries before unload, forces .immediately under .never, and reloads cleanly for take 2")
  func fullTakeFailureForcesUnloadAndReloadsTake2() async throws {
    let h = makeKernelHarness()
    try await h.adapter.warmUp(modelReceipt: nil)
    #expect(h.adapter.readiness == .ready)
    #expect(h.driver.loadedHandles == [1])

    // Record whether unload had already happened when handle 1 was retried.
    var unloadCountAtRetry = -1
    var transcribeCall = 0
    h.driver.onTranscribe = { [driver = h.driver] handle in
      transcribeCall += 1
      if handle == 1, transcribeCall == 2 {
        unloadCountAtRetry = driver.unloadedHandles.count
      }
    }
    h.driver.poisonHandle(1, status: 8)

    await runKernelTake(h, policy: .never)

    // Retry must have executed BEFORE unload fired; readiness flips synchronously at finishTerminal.
    #expect(unloadCountAtRetry == 0)
    #expect(h.driver.transcribeHandles == [1, 1, 1])  // warmup + finalize + Phase-2 retry
    #expect(h.adapter.readiness == .notReady)
    #expect(h.adapter.shouldForceUnloadAfterFailure == false)
    #expect(await awaitUntil { h.driver.unloadedHandles == [1] })
    #expect(await h.backend.isReady == false)
    #expect(h.paste.pastedTexts.isEmpty)

    // Take 2 resets kernel and starts normally: warmUp reloads handle 2 and pastes cleanly.
    h.kernel.reset()
    await runKernelTake(h, policy: .never)
    #expect(h.driver.loadedHandles == [1, 2])
    #expect(h.adapter.readiness == .ready)
    #expect(h.paste.pastedTexts == ["ok from handle 2"])
  }

  // MARK: - 2. Held teardown + cancelPendingUnload + applyUnloadPolicy(.never) + warmUp join

  @Test("held teardown keeps readiness .notReady, resists .never/cancelPendingUnload, and warmUp joins before loading handle 2")
  func heldTeardownConcurrencyAndJoin() async throws {
    let h = makeKernelHarness()
    try await h.adapter.warmUp(modelReceipt: nil)
    h.driver.poisonHandle(1, status: 8)
    h.driver.holdUnload(1)
    defer { h.driver.releaseUnload(1) }

    _ = try await runDirectAdapterTake(h.adapter)
    _ = await h.adapter.retryDecode(inputSamples: Self.speech)
    #expect(h.adapter.shouldForceUnloadAfterFailure == true)

    h.adapter.applyUnloadPolicy(.immediately)
    #expect(h.adapter.readiness == .notReady)
    await h.driver.waitForUnloadStarted(1)

    try await h.adapter.warmUpFromCache()
    #expect(h.adapter.readiness == .notReady)

    // Sibling cancellation/never-unload hooks must not abort forced teardown.
    h.adapter.cancelPendingUnload()
    h.adapter.applyUnloadPolicy(.never)

    let warmTask = Task { try await h.adapter.warmUp(modelReceipt: nil) }
    for _ in 0..<20 { await Task.yield() }
    #expect(h.driver.loadedHandles == [1], "warmUp must wait for in-flight unload before loading handle 2")
    #expect(h.adapter.readiness == .notReady)

    h.driver.releaseUnload(1)
    try await warmTask.value

    #expect(h.driver.unloadedHandles == [1])
    #expect(h.driver.loadedHandles == [1, 2])
    #expect(h.adapter.readiness == .ready)

    let outcome = try await runDirectAdapterTake(h.adapter)
    guard case .transcript(let res) = outcome else {
      Issue.record("expected transcript after reload, got \(outcome)")
      return
    }
    #expect(res.text == "ok from handle 2")
  }

  // MARK: - 3. Hung unload: MainActor unblocked & press enters ColdPressGuard cleanly

  @Test("hung forced unload keeps ColdPressGuard cold-press path working without blocking the main thread")
  func hungUnloadDoesNotBlockMainThreadAndHitsColdPressGuard() async throws {
    let h = makeKernelHarness()
    try await h.adapter.warmUp(modelReceipt: nil)
    h.driver.poisonHandle(1, status: 8)
    h.driver.holdUnload(1)
    defer { h.driver.releaseUnload(1) }

    _ = try await runDirectAdapterTake(h.adapter)
    _ = await h.adapter.retryDecode(inputSamples: Self.speech)
    h.adapter.applyUnloadPolicy(.immediately)
    await h.driver.waitForUnloadStarted(1)

    #expect(h.kernelDriver.engineReadiness == .notReady)
    let (overlay, _) = OverlayTestDouble.headlessDirectorWithHost()
    var mainThreadYieldRan = false

    // Mirrors RecordingStarter press handling when active.engineReadiness != .ready.
    ColdPressGuard.handle(
      overlay: overlay,
      active: h.kernelDriver,
      backendTag: "whisper",
      readiness: h.kernelDriver.engineReadiness,
      confirmExplicitRetry: { false }
    )
    let turn = Task { @MainActor in mainThreadYieldRan = true }
    await turn.value

    #expect(mainThreadYieldRan == true)
    #expect(h.kernelDriver.engineReadiness == .notReady)
    #expect(h.driver.loadedHandles == [1])
    #expect(h.driver.unloadedHandles.isEmpty)
    if case .notice(let notice)? = overlay.renderModel.state.presentation?.content {
      #expect(notice.kind == .warmingUp)
    } else {
      Issue.record(
        "expected cachingModel (.warmingUp) pill, got \(String(describing: overlay.renderModel.state.presentation?.content))"
      )
    }
  }

  // MARK: - 4. Slow finishing unload: press during unload ends warm (.ready), not failed

  @Test("press during a slow finishing unload settles warm (.ready), never failed or retry-required")
  func pressDuringSlowUnloadEndsWarm() async throws {
    let h = makeKernelHarness()
    try await h.adapter.warmUp(modelReceipt: nil)
    h.driver.poisonHandle(1, status: 8)
    h.driver.holdUnload(1)

    _ = try await runDirectAdapterTake(h.adapter)
    _ = await h.adapter.retryDecode(inputSamples: Self.speech)
    h.adapter.applyUnloadPolicy(.immediately)
    await h.driver.waitForUnloadStarted(1)

    let (overlay, _) = OverlayTestDouble.headlessDirectorWithHost()
    var retryChecked = false
    var warmOutcome: EngineWarmupOutcome?
    let warmOutcomeTask = Task { @MainActor in
      warmOutcome = await h.kernelDriver.ensureEngineWarm(reason: .coldPress)
    }
    ColdPressGuard.handle(
      overlay: overlay,
      active: h.kernelDriver,
      backendTag: "whisper",
      readiness: h.kernelDriver.engineReadiness,
      confirmExplicitRetry: {
        retryChecked = true
        return false
      }
    )
    for _ in 0..<20 { await Task.yield() }
    #expect(h.driver.loadedHandles == [1])

    h.driver.releaseUnload(1)
    await warmOutcomeTask.value
    if case .ready = warmOutcome {} else {
      Issue.record("expected .ready warmup outcome, got \(String(describing: warmOutcome))")
    }
    #expect(await awaitUntil {
      if case .notice(let notice)? = overlay.renderModel.state.presentation?.content {
        return notice.kind == .ready
      }
      return false
    })
    #expect(h.kernelDriver.engineReadiness == .ready)
    #expect(retryChecked == false)
    #expect(h.driver.unloadedHandles == [1])
    #expect(h.driver.loadedHandles == [1, 2])
  }

  // MARK: - 5. Retry timeout after primary status 8 still forces unload at finishTerminal

  @Test("retry timeout after status 8 primary finalize still triggers forced unload at finishTerminal")
  func retryTimeoutAfterStatus8StillForcesUnload() async throws {
    let h = makeKernelHarness()
    try await h.adapter.warmUp(modelReceipt: nil)

    let callsOnHandle1 = LockedCounter()
    h.driver.onTranscribeAsync = { handle in
      guard handle == 1 else { return }
      if callsOnHandle1.incrementAndGet() == 1 {
        throw TranscribeCppError(rawStatus: 8)
      }
      // Second call is the Phase-2 retry: hang cooperatively until kernel's 5.3s retry deadline cancels it.
      try await Task.sleep(for: .seconds(30))
    }

    await runKernelTake(h, policy: .never, timeoutSeconds: 10)

    #expect(h.adapter.readiness == .notReady)
    #expect(await awaitUntil { h.driver.unloadedHandles == [1] })
    #expect(await h.backend.isReady == false)
  }

  // MARK: - 6. Non-8 errors, cancel, empty, and batch-rescue never forced-unload

  @Test("status 7, cancel, no-speech .empty, and batch-rescue never forced-unload under .never")
  func nonStatus8FailuresCancelEmptyAndRescueStayReady() async throws {
    // status 7 failure: confirm primary + retry actually reached decode before asserting ready preserved
    let h7 = makeKernelHarness()
    try await h7.adapter.warmUp(modelReceipt: nil)
    h7.driver.poisonHandle(1, status: 7)
    await runKernelTake(h7, policy: .never)
    if case .failed = h7.kernel.recordingOutcome {} else {
      Issue.record("expected .failed kernel outcome on status 7, got \(String(describing: h7.kernel.recordingOutcome))")
    }
    #expect(h7.driver.transcribeHandles == [1, 1, 1])
    #expect(h7.adapter.shouldForceUnloadAfterFailure == false)
    #expect(h7.driver.unloadedHandles.isEmpty)
    #expect(h7.adapter.readiness == .ready)

    // Pre-finalize cancel
    let hCancel = makeKernelHarness()
    try await hCancel.adapter.warmUp(modelReceipt: nil)
    try await hCancel.adapter.beginSession(
      SessionID(), options: TranscriptionOptions(language: "en"), streaming: false)
    await hCancel.adapter.cancel()
    hCancel.adapter.applyUnloadPolicy(.never)
    #expect(hCancel.adapter.shouldForceUnloadAfterFailure == false)
    #expect(hCancel.driver.unloadedHandles.isEmpty)
    #expect(hCancel.adapter.readiness == .ready)

    // No-speech .empty
    let hEmpty = makeKernelHarness()
    try await hEmpty.adapter.warmUp(modelReceipt: nil)
    hEmpty.driver.setEmptyResult(for: 1)
    let sidEmpty = SessionID()
    try await hEmpty.adapter.beginSession(
      sidEmpty, options: TranscriptionOptions(language: "en"), streaming: false)
    hEmpty.adapter.observeSpeechSegments([], captureSamples: [])
    let emptyOutcome = await hEmpty.adapter.finalize(batchSamples: [])
    if case .empty = emptyOutcome {} else { Issue.record("expected .empty, got \(emptyOutcome)") }
    hEmpty.adapter.applyUnloadPolicy(.never)
    #expect(hEmpty.driver.unloadedHandles.isEmpty)
    #expect(hEmpty.adapter.readiness == .ready)

    // Primary finalize fails status 8, retryDecode rescues -> latch clears, no unload!
    let hRescue = makeKernelHarness()
    try await hRescue.adapter.warmUp(modelReceipt: nil)
    let rescueCalls = LockedCounter()
    hRescue.driver.onTranscribeAsync = { handle in
      guard handle == 1 else { return }
      if rescueCalls.incrementAndGet() == 1 {
        throw TranscribeCppError(rawStatus: 8)
      }
    }
    await runKernelTake(hRescue, policy: .never)
    #expect(hRescue.adapter.shouldForceUnloadAfterFailure == false)
    #expect(hRescue.driver.unloadedHandles.isEmpty)
    #expect(hRescue.adapter.readiness == .ready)
    #expect(hRescue.paste.pastedTexts == ["ok from handle 1"])
  }

  // MARK: - 7. Status 8 in LID, rolling, or meeting decode alone never unloads

  @Test("status 8 in observeLID, decodeForRollingSession, or transcribeForMeeting never unloads dictation handle")
  func lidRollingAndMeetingStatus8NeverUnload() async throws {
    let h = makeKernelHarness()
    try await h.adapter.warmUp(modelReceipt: nil)
    h.driver.poisonLID(1, status: 8)

    // observeLID error -> ready preserved, no unload.
    let lidOutcome = await h.backend.observeLID(samples: Self.speech, maxWindows: 1)
    if case .error = lidOutcome {} else { Issue.record("expected LID error, got \(lidOutcome)") }
    #expect(h.driver.unloadedHandles.isEmpty)
    #expect(await h.backend.isReady == true)

    // Rolling decode status 8 -> throws, no forced unload, readiness intact.
    h.driver.poisonHandle(1, status: 8)
    await #expect(throws: TranscribeCppWhisperError.runFailed(status: 8)) {
      _ = try await h.backend.decodeForRollingSession(
        samples: Self.speech, language: "en", onDecode: {})
    }
    h.adapter.applyUnloadPolicy(.never)
    #expect(h.adapter.shouldForceUnloadAfterFailure == false)
    #expect(h.driver.unloadedHandles.isEmpty)
    #expect(await h.backend.isReady == true)

    // Meeting decode status 8 -> throws, no unload of dictation handle.
    await #expect(throws: TranscribeCppWhisperError.runFailed(status: 8)) {
      _ = try await h.backend.transcribeForMeeting(audioSamples: Self.speech, language: "en")
    }
    #expect(h.adapter.shouldForceUnloadAfterFailure == false)
    #expect(h.driver.unloadedHandles.isEmpty)
    #expect(await h.backend.isReady == true)
    #expect(h.adapter.readiness == .ready)
  }

  // MARK: - 8. No reload loop when handle 2 fails with status 8 too

  @Test("repeated status 8 on handle 2 produces at most one unload per failed take with no reload loop")
  func noReloadLoopOnHandle2Failure() async throws {
    let h = makeKernelHarness()
    try await h.adapter.warmUp(modelReceipt: nil)
    h.driver.poisonHandle(1, status: 8)
    h.driver.poisonHandle(2, status: 8)

    await runKernelTake(h, policy: .never)
    #expect(await awaitUntil { h.driver.unloadedHandles == [1] })
    #expect(h.driver.loadedHandles == [1], "must not auto-reload after unload")

    h.kernel.reset()
    await runKernelTake(h, policy: .never)
    #expect(await awaitUntil { h.driver.unloadedHandles == [1, 2] })
    #expect(h.driver.loadedHandles == [1, 2], "only two explicit takes loaded; no reload loop")
    #expect(h.adapter.readiness == .notReady)
  }

  // MARK: - 9. Ordinary .immediately + synchronous beginSession cancels modelUnloadTask

  @Test("ordinary applyUnloadPolicy(.immediately) followed by beginSession(B) cancels unload task cleanly")
  func ordinaryImmediateUnloadCancelledByBeginSessionB() async throws {
    let (backend, adapter) = makeAdapter(FakeReloadWhisperDriver())
    try await adapter.warmUp(modelReceipt: nil)
    _ = try await runDirectAdapterTake(adapter)
    adapter.applyUnloadPolicy(.immediately)
    try await adapter.beginSession(
      SessionID(), options: TranscriptionOptions(language: "en"), streaming: false)
    await adapter.modelUnloadTaskForUnitTests?.value
    #expect(await backend.isReady == true)
    #expect(adapter.readiness == .ready)
  }

  // MARK: - 10. Refused mutation claim keeps forced teardown pending until authorized warmUp

  @Test("if forced unload claim is refused by recovery, warmUpFromCache stays .notReady and warmUp retries unload before trusting isReady")
  func refusedClaimKeepsForcedTeardownPendingUntilAuthorizedWarmUp() async throws {
    let driver = FakeReloadWhisperDriver()
    let claimGate = ClaimGate()
    let scope = EngineMutationScope.live(
      tryBegin: { claimGate.allowed },
      end: { false },
      wake: {},
      onRefused: { _ in }
    )
    let (backend, adapter) = makeAdapter(driver, scope: scope)
    try await adapter.warmUp(modelReceipt: nil)
    #expect(adapter.readiness == .ready)

    driver.poisonHandle(1, status: 8)
    _ = try await runDirectAdapterTake(adapter)
    _ = await adapter.retryDecode(inputSamples: Self.speech)

    // Recovery owns the engine when finishTerminal applies forced unload.
    claimGate.allowed = false
    adapter.applyUnloadPolicy(.immediately)
    #expect(adapter.readiness == .notReady)
    for _ in 0..<20 { await Task.yield() }
    #expect(driver.unloadedHandles.isEmpty)
    #expect(await backend.isReady == true)

    try await adapter.warmUpFromCache()
    #expect(adapter.readiness == .notReady, "pending refused teardown keeps readiness .notReady")

    // While claim stays refused, warmUp must refuse to trust stale backend.isReady.
    await #expect(throws: ASRLoadSupersededError.self) {
      try await adapter.warmUp(modelReceipt: nil)
    }
    #expect(adapter.readiness == .notReady)
    #expect(driver.unloadedHandles.isEmpty)

    // Once recovery releases the engine, warmUp retries forced unload and loads fresh handle 2.
    claimGate.allowed = true
    try await adapter.warmUp(modelReceipt: nil)
    #expect(driver.unloadedHandles == [1])
    #expect(driver.loadedHandles == [1, 2])
    #expect(adapter.readiness == .ready)
  }

  // MARK: - 11. transcribeForMeeting aborted by backend.unload() yields MeetingEngineYield

  @Test("transcribeForMeeting completes normally without unload and throws MeetingEngineYield when unload aborts it")
  func transcribeForMeetingDuringUnloadThrowsYield() async throws {
    let driver = FakeReloadWhisperDriver()
    let backend = makeBackend(driver)
    try await backend.prepare()

    // Control without unload succeeds cleanly.
    driver.holdTranscribe(1)
    let controlTask = Task {
      try await backend.transcribeForMeeting(audioSamples: Self.speech, language: "en")
    }
    await driver.waitForTranscribeStarted(1, occurrence: 2)
    driver.releaseTranscribe(1)
    let controlResult = try await controlTask.value
    #expect(controlResult.text == "ok from handle 1")

    // With unload: teardown itself aborts the held transcribe and surfaces MeetingEngineYield.
    driver.holdTranscribe(1, abortWhenUnloaded: true)
    let meetingTask = Task {
      try await backend.transcribeForMeeting(audioSamples: Self.speech, language: "en")
    }
    await driver.waitForTranscribeStarted(1, occurrence: 3)

    await backend.unload()
    await #expect(throws: MeetingEngineYield.self) {
      _ = try await meetingTask.value
    }
    #expect(driver.unloadedHandles == [1])
  }

  // MARK: - 11. #if DEBUG fail_whisper_backend command faults 2 decodes -> unload -> reload -> recover

  #if DEBUG
    @Test("fail_whisper_backend via DebugFaultEndpoint injects status 8 for take 1 + retry, clears, and take 2 succeeds")
    func debugFaultEndpointForcesStatus8AndClears() async throws {
      let faultController = BatchDecodeFaultController(whisperBackend: nil, asrManager: nil)
      let h = makeKernelHarness(faultController: faultController)
      try await h.adapter.warmUp(modelReceipt: nil)

      let endpoint = DebugFaultEndpoint(
        audioCapture: nil,
        kernelDriver: h.kernelDriver,
        whisperKernelDriver: h.kernelDriver,
        activeBackend: { .whisper },
        batchDecodeFaultController: faultController
      )

      #expect(await endpoint.handleForTesting(command: "fail_whisper_backend") == "OK")

      // Both primary finalize and Phase-2 retry fault status 8 without calling native transcribe again.
      await runKernelTake(h, policy: .never)
      #expect(h.driver.transcribeHandles == [1], "warmup only; faulted decodes short-circuit")
      #expect(await awaitUntil { h.driver.unloadedHandles == [1] })
      #expect(h.adapter.readiness == .notReady)

      // Next press reloads handle 2 and decodes cleanly.
      h.kernel.reset()
      await runKernelTake(h, policy: .never)
      #expect(h.driver.loadedHandles == [1, 2])
      #expect(h.paste.pastedTexts == ["ok from handle 2"])

      // clear_batch_decode_fault resets any armed whisperStatus8Remaining.
      #expect(await endpoint.handleForTesting(command: "fail_whisper_backend") == "OK")
      #expect(await endpoint.handleForTesting(command: "clear_batch_decode_fault(whisper,t1)") == "OK")
      h.kernel.reset()
      await runKernelTake(h, policy: .never)
      #expect(h.paste.pastedTexts == ["ok from handle 2", "ok from handle 2"])
    }
  #endif
}

private final class FakeReloadWhisperDriver: WhisperExecutorDriving, @unchecked Sendable {
  typealias Handle = Int

  private let lock = NSLock()
  private var nextHandle = 1
  private var _loadedHandles: [Int] = []
  private var _unloadedHandles: [Int] = []
  private var _transcribeHandles: [Int] = []
  private var _lidHandles: [Int] = []
  private var poisoned: [Int: Int32] = [:]
  private var emptyHandles: Set<Int> = []
  private var poisonedLID: [Int: Int32] = [:]

  private var heldUnloads: Set<Int> = []
  private var startedUnloads: Set<Int> = []
  private var unloadStartedWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
  private var unloadReleaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

  private var heldTranscribeHandles: [Int: Bool] = [:]
  private var abortedTranscribeHandles: Set<Int> = []
  private var transcribeOccurrenceCount: [Int: Int] = [:]
  private var transcribeStartedWaiters: [(handle: Int, occ: Int, cont: CheckedContinuation<Void, Never>)] = []
  private var transcribeReleaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

  var onTranscribe: (@MainActor (Int) -> Void)?
  var onTranscribeAsync: (@Sendable (Int) async throws -> Void)?

  var loadedHandles: [Int] { lock.withLock { _loadedHandles } }
  var unloadedHandles: [Int] { lock.withLock { _unloadedHandles } }
  var transcribeHandles: [Int] { lock.withLock { _transcribeHandles } }
  var lidHandles: [Int] { lock.withLock { _lidHandles } }

  func poisonHandle(_ handle: Int, status: Int32) {
    lock.withLock { poisoned[handle] = status }
  }

  func setEmptyResult(for handle: Int) {
    lock.withLock { _ = emptyHandles.insert(handle) }
  }

  func poisonLID(_ handle: Int, status: Int32) {
    lock.withLock { poisonedLID[handle] = status }
  }

  func holdUnload(_ handle: Int) {
    lock.withLock { _ = heldUnloads.insert(handle) }
  }

  func waitForUnloadStarted(_ handle: Int) async {
    await withCheckedContinuation { cont in
      let alreadyStarted = lock.withLock { () -> Bool in
        if startedUnloads.contains(handle) || _unloadedHandles.contains(handle) {
          return true
        }
        unloadStartedWaiters[handle] = cont
        return false
      }
      if alreadyStarted { cont.resume() }
    }
  }

  func releaseUnload(_ handle: Int) {
    let cont = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      heldUnloads.remove(handle)
      return unloadReleaseWaiters.removeValue(forKey: handle)
    }
    cont?.resume()
  }

  func holdTranscribe(_ handle: Int, abortWhenUnloaded: Bool = false) {
    lock.withLock {
      abortedTranscribeHandles.remove(handle)
      heldTranscribeHandles[handle] = abortWhenUnloaded
    }
  }

  func waitForTranscribeStarted(_ handle: Int, occurrence: Int) async {
    await withCheckedContinuation { cont in
      let satisfied = lock.withLock { () -> Bool in
        if (transcribeOccurrenceCount[handle] ?? 0) >= occurrence { return true }
        transcribeStartedWaiters.append((handle, occurrence, cont))
        return false
      }
      if satisfied { cont.resume() }
    }
  }

  func releaseTranscribe(_ handle: Int) {
    let cont = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      heldTranscribeHandles.removeValue(forKey: handle)
      return transcribeReleaseWaiters.removeValue(forKey: handle)
    }
    cont?.resume()
  }

  func load(modelPath: String, lane: TranscribeCppExecutor.Lane) async throws -> Int {
    lock.withLock {
      let handle = nextHandle
      nextHandle += 1
      _loadedHandles.append(handle)
      return handle
    }
  }

  func detectLanguage(
    _ handle: Int,
    samples: [Float],
    lane: TranscribeCppExecutor.Lane
  ) async throws -> TranscribeCppLanguageObservation {
    let status = lock.withLock { () -> Int32? in
      _lidHandles.append(handle)
      return poisonedLID[handle]
    }
    if let status { throw TranscribeCppError(rawStatus: status) }
    return TranscribeCppLanguageObservation(code: "en", logProb: -0.01)
  }

  func transcribe(
    _ handle: Int,
    samples: [Float],
    language: String?,
    lane: TranscribeCppExecutor.Lane,
    onInferenceEntered: (@Sendable () -> Void)?,
    onProgress: (@Sendable (Int64, Int64) -> Void)?
  ) async throws -> TranscribeCppRunResult {
    onInferenceEntered?()
    let (occ, shouldHold, abortOnRelease) = lock.withLock { () -> (Int, Bool, Bool) in
      _transcribeHandles.append(handle)
      let occ = (transcribeOccurrenceCount[handle] ?? 0) + 1
      transcribeOccurrenceCount[handle] = occ
      let waiters = transcribeStartedWaiters.filter { $0.handle == handle && occ >= $0.occ }
      transcribeStartedWaiters.removeAll { $0.handle == handle && occ >= $0.occ }
      waiters.forEach { $0.cont.resume() }
      let abort = heldTranscribeHandles[handle]
      return (occ, abort != nil, abort ?? false)
    }
    _ = occ
    if shouldHold {
      await withCheckedContinuation { cont in
        let stillHeld = lock.withLock { () -> Bool in
          if heldTranscribeHandles[handle] == nil { return false }
          transcribeReleaseWaiters[handle] = cont
          return true
        }
        if !stillHeld { cont.resume() }
      }
      if lock.withLock({ abortedTranscribeHandles.remove(handle) != nil }) {
        throw TranscribeCppError(rawStatus: TranscribeCppError.abortedStatus)
      }
    }
    if let hook = onTranscribe {
      await MainActor.run { hook(handle) }
    }
    if let asyncHook = onTranscribeAsync {
      try await asyncHook(handle)
    }
    let (status, isEmpty) = lock.withLock { (poisoned[handle], emptyHandles.contains(handle)) }
    if let status { throw TranscribeCppError(rawStatus: status) }
    if isEmpty {
      return TranscribeCppRunResult(text: "", detectedLanguage: "en", segments: [])
    }
    return TranscribeCppRunResult(
      text: " ok from handle \(handle)",
      detectedLanguage: "en",
      segments: [TranscribeCppSegment(startMs: 0, endMs: 900, text: " ok from handle \(handle)")]
    )
  }

  func waitForDrain(_ handle: Int) async {}

  func unload(_ handle: Int) async {
    let (shouldHold, startedCont, abortCont) = lock.withLock {
      () -> (Bool, CheckedContinuation<Void, Never>?, CheckedContinuation<Void, Never>?) in
      _ = startedUnloads.insert(handle)
      let cont = unloadStartedWaiters.removeValue(forKey: handle)
      var abortWaiter: CheckedContinuation<Void, Never>?
      if heldTranscribeHandles[handle] == true {
        heldTranscribeHandles.removeValue(forKey: handle)
        abortedTranscribeHandles.insert(handle)
        abortWaiter = transcribeReleaseWaiters.removeValue(forKey: handle)
      }
      return (heldUnloads.contains(handle), cont, abortWaiter)
    }
    startedCont?.resume()
    abortCont?.resume()
    if shouldHold {
      await withCheckedContinuation { cont in
        let stillHeld = lock.withLock { () -> Bool in
          if !heldUnloads.contains(handle) { return false }
          unloadReleaseWaiters[handle] = cont
          return true
        }
        if !stillHeld { cont.resume() }
      }
    }
    lock.withLock { _unloadedHandles.append(handle) }
  }

  func awaitSettled(openedOn lane: TranscribeCppExecutor.Lane) async -> Int { 0 }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func incrementAndGet() -> Int {
    lock.withLock {
      value += 1
      return value
    }
  }
}

@MainActor
private final class ClaimGate {
  var allowed = true
}
