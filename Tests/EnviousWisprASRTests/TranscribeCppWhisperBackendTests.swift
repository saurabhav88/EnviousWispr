import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprTranscribeCpp

/// #3735 plan §3.2: the transcribe.cpp Whisper backend over a fake executor driver.
///
/// **What the user sees when this fails:** the first dictation after launch waits for a cold
/// model, a cancelled or stale load leaks a 1 GB model, a cancelled take still pastes text,
/// the wrong language is reported, File Import's progress bar jumps or finishes falsely,
/// speaker turns land on the wrong time, or a memory-pressure unload frees a model mid-decode.
@Suite("transcribe.cpp Whisper backend (#3735)", .serialized, .tags(.productOutcome))
struct TranscribeCppWhisperBackendTests {

  fileprivate typealias Backend = TranscribeCppWhisperBackend<FakeWhisperDriver>

  fileprivate static func makeBackend(
    _ driver: FakeWhisperDriver, path: String? = "turbo.gguf",
    authorize: Backend.UnloadAuthorizer? = nil, warmupDeadline: Double = 5,
    loadsAfterPressureBinding: Bool = false, initiallyParked: Bool = false
  ) -> Backend {
    Backend(
      driver: driver, modelVariant: "whisper-large-v3-turbo-Q8_0",
      admittedModelPath: { path }, modelIdentity: nil, scopeDelivery: nil,
      authorizeUnload: authorize, warmupDeadlineSeconds: warmupDeadline,
      loadsAfterPressureBinding: loadsAfterPressureBinding, initiallyParked: initiallyParked)
  }

  /// The backend's parked-caller announcements, recorded in the driver's log.
  fileprivate static func observe(_ backend: Backend, into driver: FakeWhisperDriver) async {
    await backend.setTestEventObserver { event in driver.record("event \(event)") }
  }

  static func run(
    _ text: String, detected: String? = nil, segments: [TranscribeCppSegment] = []
  ) -> TranscribeCppRunResult {
    TranscribeCppRunResult(text: text, detectedLanguage: detected, segments: segments)
  }

  // MARK: - Load lifecycle

  @Test("concurrent prepares join one load and one warm-up, and readiness waits for the warm-up")
  func joinedPrepares() async throws {
    let driver = FakeWhisperDriver()
    driver.holdLoad("turbo.gguf")
    let backend = Self.makeBackend(driver)
    let first = Task { try await backend.prepare() }
    await driver.waitForLog("load turbo.gguf")
    let second = Task { try await backend.prepare() }
    #expect(await backend.isReady == false)
    driver.releaseLoad("turbo.gguf")
    try await driver.bounded(first)
    try await driver.bounded(second)
    #expect(await backend.isReady)
    #expect(driver.log.filter { $0.hasPrefix("load ") }.count == 1)
    // The warm-up is one silent auto-language decode, recorded only on completion.
    #expect(driver.log.filter { $0.hasPrefix("enter ") } == ["enter 1 lang=nil samples=16000"])
    #expect(await backend.lastWarmupInferenceMs != nil)
  }

  @Test("no admitted model is not-ready and loads nothing")
  func noAdmittedModel() async {
    let driver = FakeWhisperDriver()
    let backend = Self.makeBackend(driver, path: nil)
    await #expect(throws: ASRError.self) { try await backend.prepare() }
    #expect(driver.log.isEmpty)
    #expect(await backend.isReady == false)
  }

  @Test("a native load failure surfaces with its stable status identity")
  func loadFailureIdentity() async {
    let driver = FakeWhisperDriver()
    driver.failLoad = TranscribeCppError(rawStatus: 5)
    let backend = Self.makeBackend(driver)
    await #expect(throws: TranscribeCppWhisperError.loadFailed(status: 5)) {
      try await backend.prepare()
    }
    #expect(
      TranscribeCppWhisperError.loadFailed(status: 5).sentryFingerprintDescriptor
        == "TranscribeCpp.load#5")
    #expect(await backend.loadPhaseForTesting == .idle)
  }

  @Test("a failed warm-up still readies the model and records no warm-up duration")
  func failedWarmup() async throws {
    let driver = FakeWhisperDriver()
    driver.runOutcome = { _, _ in throw TranscribeCppError(rawStatus: 7) }
    let backend = Self.makeBackend(driver)
    try await backend.prepare()
    #expect(await backend.isReady)
    #expect(await backend.lastWarmupInferenceMs == nil)
  }

  @Test("an unload during a native load returns only after the late model is physically freed")
  func lateLoadIsFreed() async throws {
    let driver = FakeWhisperDriver()
    driver.holdLoad("turbo.gguf")
    let backend = Self.makeBackend(driver)
    let prepare = Task { try await backend.prepare() }
    await driver.waitForLog("load turbo.gguf")
    let unload = Task { await backend.unloadAndSettle() }
    // The cancelled caller left at once (as the executor releases it); the native open goes on.
    await #expect(throws: CancellationError.self) { try await driver.bounded(prepare) }
    await driver.waitForLog("settle-wait")
    #expect(!driver.log.contains("orphan-free 1"), "control: the native open is still running")
    await #expect(throws: ASRError.self, "admission stays closed while the unload settles") {
      try await backend.prepare()
    }
    driver.releaseLoad("turbo.gguf")
    #expect(try await driver.bounded(unload) == UnloadReceipt(freed: 0, remaining: 0))
    #expect(driver.log.contains("orphan-free 1"), "the stale model must be freed, never leaked")
    #expect(!driver.log.contains("enter 1 lang=nil samples=16000"), "no warm-up on a stale model")
    #expect(await backend.isReady == false)
  }

  @Test("#3973 C3: Remove during a meeting model load frees the late model before it returns")
  func meetingEngineRemovalFreesALateLoad() async throws {
    let driver = FakeWhisperDriver()
    driver.holdLoad("turbo.gguf")
    let engine = MeetingWhisperEngine(driver: driver)
    let load = Task { try await engine.load(modelPath: "turbo.gguf") }
    await driver.waitForLog("load turbo.gguf")
    await engine.setRemovalObserver { driver.record("removal done") }
    let removal = Task { await engine.closeForRemoval() }
    let closed = Task {
      while await !engine.isClosedForRemoval { await Task.yield() }
    }
    try await driver.bounded(closed)
    #expect(!driver.log.contains("unload 1"), "control: the load has not returned yet")
    driver.releaseLoad("turbo.gguf")
    try await driver.bounded(removal)
    let log = driver.log
    #expect(
      log.firstIndex(of: "unload 1").map { $0 < log.firstIndex(of: "removal done")! } == true,
      "Remove returned only after the late model was freed")
    await #expect(throws: MeetingEngineYield.self) { try await driver.bounded(load) }
    #expect(await engine.isLoaded == false)
    await #expect(throws: MeetingEngineYield.self, "no load starts until Remove ends") {
      try await engine.load(modelPath: "turbo.gguf")
    }
    await engine.reopenAfterRemoval()
    try await engine.load(modelPath: "turbo.gguf")
    #expect(await engine.isLoaded)
  }

  @Test("#3973 C3: Remove waits for the meeting model free the route already started")
  func meetingEngineRemovalJoinsARunningFree() async throws {
    let driver = FakeWhisperDriver()
    let engine = MeetingWhisperEngine(driver: driver)
    try await engine.load(modelPath: "turbo.gguf")
    driver.holdUnloads()
    let routeUnload = Task { await engine.unload() }
    await driver.waitForLog("unloading 1")
    await engine.setRemovalObserver { driver.record("removal done") }
    let removal = Task { await engine.closeForRemoval() }
    let closed = Task {
      while await !engine.isClosedForRemoval { await Task.yield() }
    }
    try await driver.bounded(closed)
    driver.releaseUnloads()
    try await driver.bounded(removal)
    try await driver.bounded(routeUnload)
    let log = driver.log
    #expect(
      log.firstIndex(of: "unload 1").map { $0 < log.firstIndex(of: "removal done")! } == true,
      "Remove returned only after the running free ended")
    #expect(log.filter { $0 == "unloading 1" }.count == 1, "the model is freed once")
  }

  @Test("an unload joins a load still travelling to the executor before it settles")
  func unloadJoinsBlockedLoad() async throws {
    let driver = FakeWhisperDriver()
    driver.holdArrival("turbo.gguf")
    driver.holdLoad("turbo.gguf")
    let backend = Self.makeBackend(driver)
    let prepare = Task { try await backend.prepare() }
    await driver.waitForLog("travelling turbo.gguf")
    let unload = Task { await backend.unloadAndSettle() }
    await driver.waitForLog("cancel-seen turbo.gguf")
    driver.releaseArrival("turbo.gguf")
    await #expect(throws: CancellationError.self) { try await driver.bounded(prepare) }
    // Settling started only after the load reached the executor, so it waits for that open.
    await driver.waitForLog("settle-wait")
    let log = driver.log
    #expect(log.firstIndex(of: "arrived turbo.gguf")! < log.firstIndex(of: "settle-wait")!)
    driver.releaseLoad("turbo.gguf")
    #expect(try await driver.bounded(unload) == UnloadReceipt(freed: 0, remaining: 0))
    #expect(driver.log.contains("orphan-free 1"))
  }

  @Test("an unload of a resident model returns only after its free, with admission closed")
  func unloadWaitsForPhysicalFreeAndSettlement() async throws {
    let driver = FakeWhisperDriver()
    let backend = Self.makeBackend(driver)
    try await backend.prepare()
    driver.holdUnloads()
    let unload = Task { await backend.unloadAndSettle() }
    await driver.waitForLog("unloading 1")
    await #expect(throws: ASRError.self) { try await backend.prepare() }
    driver.releaseUnloads()
    #expect(try await driver.bounded(unload) == UnloadReceipt(freed: 1, remaining: 0))
    #expect(driver.log.last == "unload 1")
    try await backend.prepare()
    #expect(await backend.isReady, "an unparked backend reopens after the teardown")
  }

  @Test("an unload joins a warm-up that outlives its cancellation; the load frees its own model")
  func unloadJoinsWarmupTask() async throws {
    let driver = FakeWhisperDriver()
    driver.holdRuns(ignoringCancel: true)
    let backend = Self.makeBackend(driver)
    let prepare = Task { try await backend.prepare() }
    await driver.waitForLog("enter 1 lang=nil samples=16000")
    let unload = Task { await backend.unloadAndSettle() }
    await driver.waitForLog("run-cancel-seen 1")
    await #expect(throws: ASRError.self) { try await backend.prepare() }
    driver.releaseRuns()
    #expect(try await driver.bounded(unload) == UnloadReceipt(freed: 0, remaining: 0))
    await #expect(throws: (any Error).self) { try await driver.bounded(prepare) }
    #expect(driver.log.contains("unload 1"))
    #expect(!driver.log.contains("abort 1"), "the warm-up ended before its model was freed")
  }

  @Test("an unload joins a timed-out warm-up still running natively before it frees the model")
  func unloadJoinsOrphanWarmup() async throws {
    let driver = FakeWhisperDriver()
    driver.holdRuns(ignoringCancel: true)
    let backend = Self.makeBackend(driver, warmupDeadline: 0.2)
    try await backend.prepare()  // fail-open ready after the warm-up ceiling
    #expect(await backend.isReady)
    let unload = Task { await backend.unloadAndSettle() }
    await driver.waitForLog("run-cancel-seen 1")
    #expect(!driver.log.contains("unloading 1"), "the free waits for the orphan warm-up")
    driver.releaseRuns()
    #expect(try await driver.bounded(unload) == UnloadReceipt(freed: 1, remaining: 0))
    #expect(!driver.log.contains("abort 1"), "the orphan warm-up ended before its model was freed")
  }

  @Test("an unload during the warm-up frees the model and readiness never flips")
  func unloadDuringWarmup() async throws {
    let driver = FakeWhisperDriver()
    driver.holdRuns()
    let backend = Self.makeBackend(driver)
    let prepare = Task { try await backend.prepare() }
    await driver.waitForLog("enter 1 lang=nil samples=16000")
    await backend.unload()
    await #expect(throws: (any Error).self) { try await driver.bounded(prepare) }
    #expect(driver.log.contains("unload 1"))
    #expect(await backend.isReady == false)
    #expect(await backend.loadPhaseForTesting == .idle)
  }

  // MARK: - Transcription

  @Test("a forced language is reported as the hint; auto uses the native detection")
  func languageOutcomes() async throws {
    let driver = FakeWhisperDriver()
    let backend = Self.makeBackend(driver)
    try await backend.prepare()
    driver.runOutcome = { _, _ in Self.run(" hola ", detected: nil) }
    let forced = try await backend.transcribe(
      audioSamples: [Float](repeating: 0.1, count: 16_000),
      options: TranscriptionOptions(language: "es"), onInferenceEntered: nil)
    #expect(forced.language == "es")
    #expect(forced.text == "hola")
    #expect(driver.lastLanguage == "es")

    driver.runOutcome = { _, _ in Self.run("bonjour", detected: "fr") }
    let auto = try await backend.transcribe(
      audioSamples: [Float](repeating: 0.1, count: 16_000), options: .default,
      onInferenceEntered: nil)
    #expect(auto.language == "fr")
    #expect(driver.lastLanguage == nil)

    driver.runOutcome = { _, _ in Self.run("…", detected: "") }
    let empty = try await backend.transcribe(
      audioSamples: [Float](repeating: 0.1, count: 16_000), options: .default,
      onInferenceEntered: nil)
    #expect(empty.language == nil, "an empty native detection maps to nil")
  }

  @Test("only the speech envelope is decoded, with padding, and the original duration is kept")
  func speechEnvelope() async throws {
    let driver = FakeWhisperDriver()
    let backend = Self.makeBackend(driver)
    try await backend.prepare()
    // 4 s of silence with speech at 20_000..<36_000 under the fake segment (#3801: constant
    // audio has no quieter room tone, so the silent-tail filter would classify it as unvoiced).
    var samples = [Float](repeating: 0, count: 64_000)
    samples.replaceSubrange(20_000..<36_000, with: [Float](repeating: 0.1, count: 16_000))
    let options = TranscriptionOptions(
      language: "en", enableTimestamps: true,
      speechSegments: [
        SpeechSegment(startSample: 20_000, endSample: 30_000),
        SpeechSegment(startSample: 16_000, endSample: 16_000),  // zero-width: ignored
        SpeechSegment(startSample: 40_000, endSample: 90_000),  // past the end: clamped
      ])
    driver.runOutcome = { _, _ in
      Self.run(
        "hello there",
        segments: [TranscribeCppSegment(startMs: 100, endMs: 900, text: " hello there")])
    }
    let result = try await backend.transcribe(
      audioSamples: samples, options: options, onInferenceEntered: nil)
    // 20_000..<64_000 decoded plus 8_000 samples of synthetic padding.
    #expect(driver.lastSampleCount == 44_000 + 8_000)
    #expect(result.duration == 4.0)
    // 20_000 samples = 1_250 ms offset onto the original timeline.
    #expect(
      result.segmentTimings == [ASRSegmentTiming(range: 0..<11, startMs: 1_350, endMs: 2_150)])
    #expect(result.wordTimings == nil, "segment timing never becomes word timing")
  }

  // MARK: - #3801 silent-tail filter at the native boundary

  /// 4 s: silence, speech at 20_000..<36_000 (1.25-2.25 s), silence.
  static var speechInSilence: [Float] {
    var samples = [Float](repeating: 0, count: 64_000)
    samples.replaceSubrange(20_000..<36_000, with: [Float](repeating: 0.1, count: 16_000))
    return samples
  }

  @Test("a batch decode drops an invented trailing sentence and keeps the real one timed")
  func batchDropsSilentTail() async throws {
    let driver = FakeWhisperDriver()
    let backend = Self.makeBackend(driver)
    try await backend.prepare()
    // Envelope 16_000..<64_000: native times are 1_000 ms behind the capture timeline.
    let options = TranscriptionOptions(
      language: "en", enableTimestamps: true,
      speechSegments: [SpeechSegment(startSample: 16_000, endSample: 64_000)])
    driver.runOutcome = { _, _ in
      Self.run(
        "hello there Thank you.",
        segments: [
          TranscribeCppSegment(startMs: 300, endMs: 1_100, text: " hello there"),
          TranscribeCppSegment(startMs: 1_800, endMs: 2_400, text: " Thank you."),
        ])
    }
    let result = try await backend.transcribe(
      audioSamples: Self.speechInSilence, options: options, onInferenceEntered: nil)
    #expect(result.text == "hello there")
    #expect(
      result.segmentTimings == [ASRSegmentTiming(range: 0..<11, startMs: 1_300, endMs: 2_100)])
    #expect(result.silentTailDropped == 1)
  }

  @Test("batch statistics read the full capture, so an all-speech envelope keeps its sentence")
  func batchStatsUseFullCapture() async throws {
    let driver = FakeWhisperDriver()
    let backend = Self.makeBackend(driver)
    try await backend.prepare()
    // Envelope 20_000..<36_000 is all speech: loud first, then quieter. Read alone, it sets a
    // threshold above the quiet half; read with the room tone around it, the quiet half is voiced.
    // One loud sentence cannot show this: the filter never empties a result.
    var samples = [Float](repeating: 0, count: 64_000)
    samples.replaceSubrange(20_000..<28_000, with: [Float](repeating: 0.1, count: 8_000))
    samples.replaceSubrange(28_000..<36_000, with: [Float](repeating: 0.02, count: 8_000))
    let options = TranscriptionOptions(
      language: "en", enableTimestamps: false,
      speechSegments: [SpeechSegment(startSample: 20_000, endSample: 36_000)])
    driver.runOutcome = { _, _ in
      Self.run(
        "hello there",
        segments: [
          TranscribeCppSegment(startMs: 0, endMs: 500, text: "hello"),
          TranscribeCppSegment(startMs: 750, endMs: 1_000, text: " there"),
        ])
    }
    let result = try await backend.transcribe(
      audioSamples: samples, options: options, onInferenceEntered: nil)
    #expect(driver.lastSampleCount == 16_000 + 8_000)
    #expect(result.text == "hello there")
    #expect(result.silentTailDropped == 0, "the filter ran and removed nothing")
  }

  @Test("a batch decode with no voiced segment keeps its text (never emptied)")
  func batchAllSilentIsKept() async throws {
    let driver = FakeWhisperDriver()
    let backend = Self.makeBackend(driver)
    try await backend.prepare()
    driver.runOutcome = { _, _ in
      Self.run(
        "Thank you.", segments: [TranscribeCppSegment(startMs: 0, endMs: 2_000, text: "Thank you.")]
      )
    }
    let result = try await backend.transcribe(
      audioSamples: [Float](repeating: 0, count: 32_000), options: .default,
      onInferenceEntered: nil)
    #expect(result.text == "Thank you.")
    #expect(result.silentTailDropped == 0)
  }

  @Test("a rolling-session decode returns the filtered result to the loop and the flush")
  func rollingDecodeDropsSilentTail() async throws {
    let driver = FakeWhisperDriver()
    let backend = Self.makeBackend(driver)
    try await backend.prepare()
    driver.runOutcome = { _, _ in
      Self.run(
        "hello there Thank you.",
        segments: [
          TranscribeCppSegment(startMs: 1_300, endMs: 2_100, text: "hello there"),
          TranscribeCppSegment(startMs: 3_000, endMs: 3_800, text: "Thank you."),
        ])
    }
    let run = try await backend.decodeForRollingSession(
      samples: Self.speechInSilence, language: "en", onDecode: nil)
    #expect(run.text == "hello there")
    #expect(run.segments.map(\.text) == ["hello there"])
    #expect(run.silentTailDropped == 1)
  }

  @Test("no usable speech range decodes the whole input")
  func wholeInputFallback() async throws {
    let driver = FakeWhisperDriver()
    let backend = Self.makeBackend(driver)
    try await backend.prepare()
    for ranges in [[SpeechSegment](), [SpeechSegment(startSample: 5, endSample: 5)]] {
      _ = try await backend.transcribe(
        audioSamples: [Float](repeating: 0.1, count: 32_000),
        options: TranscriptionOptions(language: "en", speechSegments: ranges),
        onInferenceEntered: nil)
      #expect(driver.lastSampleCount == 32_000 + 8_000)
    }
  }

  @Test("segment bounds in the padding or invalid stay untimed; unfound text is left out")
  func segmentValidation() {
    let text = "one two three four"
    let segments = [
      TranscribeCppSegment(startMs: 0, endMs: 500, text: "one"),
      TranscribeCppSegment(startMs: 700, endMs: 600, text: "two"),  // end before start
      TranscribeCppSegment(startMs: 900, endMs: 1_200, text: "missing"),  // not in text
      TranscribeCppSegment(startMs: 1_100, endMs: 1_400, text: "three"),  // end past real audio
      TranscribeCppSegment(startMs: 1_600, endMs: 1_700, text: "four"),  // starts in padding
    ]
    let bound = Backend.bindSegments(
      segments, text: text, envelope: 0..<20_000, originalSampleCount: 20_000)
    #expect(
      bound == [
        ASRSegmentTiming(range: 0..<3, startMs: 0, endMs: 500),
        ASRSegmentTiming(range: 4..<7, startMs: nil, endMs: nil),
        ASRSegmentTiming(range: 8..<13, startMs: 1_100, endMs: 1_250),
        ASRSegmentTiming(range: 14..<18, startMs: nil, endMs: nil),
      ])
  }

  @Test("a repeated segment text binds in order, never to an earlier occurrence")
  func repeatedSegmentText() {
    let bound = Backend.bindSegments(
      [
        TranscribeCppSegment(startMs: 0, endMs: 400, text: "yes"),
        TranscribeCppSegment(startMs: 400, endMs: 900, text: "yes yes"),
      ], text: "yes yes yes", envelope: 0..<16_000, originalSampleCount: 16_000)
    #expect(bound.map(\.range) == [0..<3, 4..<11])
  }

  @Test("the inference-entry signal fires once, at the native boundary, after cancellation checks")
  func nativeEntryOrdering() async throws {
    let driver = FakeWhisperDriver()
    let backend = Self.makeBackend(driver)
    try await backend.prepare()
    let entries = Counter()
    _ = try await backend.transcribe(
      audioSamples: [Float](repeating: 0.1, count: 16_000), options: .default,
      onInferenceEntered: {
        entries.increment()
        driver.record("observer")
      })
    #expect(entries.value == 1)
    let tail = Array(driver.log.suffix(2))
    #expect(tail == ["observer", "enter 1 lang=nil samples=24000"])

    // A caller cancelled before the native boundary never fires it.
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await backend.transcribe(
        audioSamples: [Float](repeating: 0.1, count: 16_000), options: .default,
        onInferenceEntered: { entries.increment() })
    }
    await #expect(throws: CancellationError.self) { try await driver.bounded(cancelled) }
    #expect(entries.value == 1)
  }

  @Test("progress is forwarded monotonically from native seeks and cleared after one call")
  func progressObserver() async throws {
    let driver = FakeWhisperDriver()
    let backend = Self.makeBackend(driver)
    try await backend.prepare()
    let seen = Recorder<Double>()
    await backend.setTranscriptionProgressObserver { seen.append($0) }
    driver.progressScript = [(0, 0), (30, 100), (20, 100), (100, 100), (150, 100)]
    _ = try await backend.transcribe(
      audioSamples: [Float](repeating: 0.1, count: 16_000), options: .default,
      onInferenceEntered: nil)
    #expect(seen.values == [0.3, 1.0])
    // Cleared: the next call reports nothing.
    _ = try await backend.transcribe(
      audioSamples: [Float](repeating: 0.1, count: 16_000), options: .default,
      onInferenceEntered: nil)
    #expect(seen.values == [0.3, 1.0])
  }

  @Test("a refused call clears the observer and a failed run fabricates no completion")
  func observerIsolationOnRefusalAndFailure() async throws {
    let driver = FakeWhisperDriver()
    let backend = Self.makeBackend(driver)
    let seen = Recorder<Double>()
    await backend.setTranscriptionProgressObserver { seen.append($0) }
    await #expect(throws: ASRError.self) {
      _ = try await backend.transcribe(
        audioSamples: [Float](repeating: 0.1, count: 16_000), options: .default,
        onInferenceEntered: nil)
    }
    try await backend.prepare()
    driver.progressScript = [(40, 100)]
    _ = try await backend.transcribe(
      audioSamples: [Float](repeating: 0.1, count: 16_000), options: .default,
      onInferenceEntered: nil)
    #expect(seen.values.isEmpty, "the refused call's observer must not reach a later decode")

    await backend.setTranscriptionProgressObserver { seen.append($0) }
    driver.progressScript = [(40, 100)]
    driver.runOutcome = { _, _ in throw TranscribeCppError(rawStatus: 7) }
    await #expect(throws: TranscribeCppWhisperError.runFailed(status: 7)) {
      _ = try await backend.transcribe(
        audioSamples: [Float](repeating: 0.1, count: 16_000), options: .default,
        onInferenceEntered: nil)
    }
    #expect(seen.values == [0.4], "a failed run never reports completion")
  }

  @Test(
    "a cancelled decode returns only after its native call ends, and stays in flight until then")
  func cancellationAndDrain() async throws {
    let driver = FakeWhisperDriver()
    let backend = Self.makeBackend(driver)
    try await backend.prepare()
    driver.holdRuns()
    let take = Task {
      try await backend.transcribe(
        audioSamples: [Float](repeating: 0.1, count: 16_000), options: .default,
        onInferenceEntered: nil)
    }
    await driver.waitForLog("enter 1 lang=nil samples=24000")
    take.cancel()
    // The executor released the caller; the backend now waits for the aborted native run.
    await driver.waitForLog("drain-wait 1")
    #expect(await backend.operationCountsForTesting.inFlight == 1)
    driver.releaseRuns()
    await #expect(throws: CancellationError.self) { try await driver.bounded(take) }
    #expect(await backend.operationCountsForTesting.inFlight == 0)
  }

  // MARK: - LID

  @Test("LID keeps the window plan and maps observations, failures and cancellation")
  func lidOutcomes() async throws {
    let driver = FakeWhisperDriver()
    let backend = Self.makeBackend(driver)
    try await backend.prepare()
    let samples = [Float](repeating: 0.1, count: 16_000 * 13)
    let expectedWindows = Backend.lidWindows(samples: samples, maxWindows: 4)
    #expect(expectedWindows.count == 4)

    driver.lidOutcome = { _ in TranscribeCppLanguageObservation(code: "de", logProb: -0.2) }
    guard case .observations(let obs) = await backend.observeLID(samples: samples, maxWindows: 4)
    else {
      Issue.record("expected observations")
      return
    }
    #expect(obs == Array(repeating: RawLIDObservation(argmaxLang: "de", logProb: -0.2), count: 4))
    #expect(driver.lidSampleCounts == expectedWindows.map(\.count))

    driver.lidOutcome = { _ in throw TranscribeCppError(rawStatus: 7) }
    guard case .error = await backend.observeLID(samples: samples, maxWindows: 4) else {
      Issue.record("expected error")
      return
    }
    driver.lidOutcome = { _ in throw TranscribeCppExecutor.ExecutorError.cancelled }
    guard case .cancelled = await backend.observeLID(samples: samples, maxWindows: 4) else {
      Issue.record("expected cancelled")
      return
    }
    guard case .noWindows = await backend.observeLID(samples: [], maxWindows: 4) else {
      Issue.record("expected noWindows")
      return
    }
  }

  @Test("LID before load is unavailable")
  func lidUnavailable() async {
    let backend = Self.makeBackend(FakeWhisperDriver())
    guard case .unavailable = await backend.observeLID(samples: [0.1], maxWindows: 1) else {
      Issue.record("expected unavailable")
      return
    }
  }

  // MARK: - Memory pressure

  @Test("memory pressure while idle unloads through the authorized path")
  func pressureIdleUnloads() async throws {
    let driver = FakeWhisperDriver()
    let claims = Counter()
    let backend = Self.makeBackend(
      driver,
      authorize: { teardown in
        claims.increment()
        _ = await teardown()
        return true
      })
    try await backend.prepare()
    await backend.handleMemoryPressure()
    #expect(claims.value == 1)
    #expect(driver.log.last == "unload 1")
    #expect(await backend.isReady == false)
  }

  @Test("a refused authorization leaves the model ready and loaded")
  func pressureRefusalPreservesReadiness() async throws {
    let driver = FakeWhisperDriver()
    let backend = Self.makeBackend(driver, authorize: { _ in false })
    try await backend.prepare()
    await backend.handleMemoryPressure()
    #expect(await backend.isReady)
    #expect(!driver.log.contains("unload 1"))
    #expect(await backend.operationCountsForTesting.pressurePending == false)
  }

  @Test("memory pressure during a decode is deferred until the decode ends, then unloads")
  func pressureDeferredDuringDecode() async throws {
    let driver = FakeWhisperDriver()
    let backend = Self.makeBackend(
      driver,
      authorize: { teardown in
        _ = await teardown()
        return true
      })
    try await backend.prepare()
    driver.holdRuns()
    let take = Task {
      try await backend.transcribe(
        audioSamples: [Float](repeating: 0.1, count: 16_000), options: .default,
        onInferenceEntered: nil)
    }
    await driver.waitForLog("enter 1 lang=nil samples=24000")
    // Bounded: a pressure call that tears down under a running decode waits for it to drain, so
    // awaiting it inline would hang the suite instead of failing this test.
    let pressure = Task { await backend.handleMemoryPressure() }
    try await driver.bounded(pressure)
    #expect(!driver.log.contains("unload 1"), "never while a decode runs")
    #expect(await backend.operationCountsForTesting.pressurePending)
    driver.releaseRuns()
    _ = try await driver.bounded(take)
    await driver.waitForLog("unload 1")
    #expect(await backend.isReady == false)
  }

  @Test("memory pressure without an authorizer never unloads")
  func pressureWithoutAuthorizer() async throws {
    let driver = FakeWhisperDriver()
    let backend = Self.makeBackend(driver)
    try await backend.prepare()
    await backend.handleMemoryPressure()
    #expect(await backend.isReady)
    #expect(!driver.log.contains("unload 1"))
  }

  @Test("a prepare during a teardown is refused, and concurrent unloads share one teardown")
  func prepareDuringTeardown() async throws {
    let driver = FakeWhisperDriver()
    let backend = Self.makeBackend(driver)
    await Self.observe(backend, into: driver)
    try await backend.prepare()
    driver.holdUnloads()
    let first = Task { await backend.unloadAndSettle() }
    await driver.waitForLog("unloading 1")
    await #expect(throws: ASRError.self) { try await backend.prepare() }
    let second = Task { await backend.unloadAndSettle() }
    await driver.waitForLog("event joinedUnload")
    driver.releaseUnloads()
    let receipt = UnloadReceipt(freed: 1, remaining: 0)
    #expect(try await driver.bounded(first) == receipt)
    #expect(try await driver.bounded(second) == receipt, "a joined caller gets the one receipt")
    #expect(driver.log.filter { $0.hasPrefix("unload") } == ["unloading 1", "unload 1"])
    #expect(driver.log.filter { $0.hasPrefix("load ") }.count == 1, "no replacement load ran")
    // Admission reopens after the teardown.
    try await backend.prepare()
    #expect(await backend.isReady)
  }

  // MARK: - Engine switch park (#3849)

  @Test(
    "the engine selected at launch decides whether Whisper may warm; unpark admits it",
    arguments: [true, false])
  func initialParkDecidesPrepare(initiallyParked: Bool) async throws {
    let driver = FakeWhisperDriver()
    let backend = Self.makeBackend(driver, initiallyParked: initiallyParked)
    if initiallyParked {
      await #expect(throws: ASRError.self) { try await backend.prepare() }
      #expect(driver.log.isEmpty, "a parked engine never reaches the native load")
      await backend.unpark()
    }
    try await backend.prepare()
    #expect(await backend.isReady)
  }

  @Test("park refuses a warm waiting for the pressure binding when that wait ends")
  func parkRefusesDelayedPrepare() async throws {
    let driver = FakeWhisperDriver()
    let backend = Self.makeBackend(driver, loadsAfterPressureBinding: true)
    await Self.observe(backend, into: driver)
    let prepare = Task { try await backend.prepare() }
    await driver.waitForLog("event waitingForPressureBinding")
    #expect(await backend.park() == UnloadReceipt(freed: 0, remaining: 0))
    await backend.bindMemoryPressure(authorizer: { _ in false })
    await #expect(throws: ASRError.self) { try await driver.bounded(prepare) }
    #expect(!driver.log.contains("load turbo.gguf"))
  }

  @Test("park refuses a warm scheduled before it and entered after it; parking outlives unload")
  func parkRefusesPreviouslyScheduledPrepare() async throws {
    let driver = FakeWhisperDriver()
    let backend = Self.makeBackend(driver)
    try await backend.prepare()
    let gate = AsyncGate(open: false)
    let warm = Task {
      await gate.wait()
      try await backend.prepare()
    }
    #expect(await backend.park() == UnloadReceipt(freed: 1, remaining: 0))
    gate.open()
    await #expect(throws: ASRError.self) { try await driver.bounded(warm) }
    // A later ordinary unload completes without reopening a parked engine.
    await backend.unload()
    await #expect(throws: ASRError.self) { try await backend.prepare() }
    #expect(driver.log.filter { $0.hasPrefix("load ") }.count == 1)
    await backend.unpark()
    try await backend.prepare()
    #expect(await backend.isReady, "unpark reopens loading")
  }

  @Test("a park during an unload already running joins it and keeps Whisper parked")
  func concurrentUnloadReceipts() async throws {
    let driver = FakeWhisperDriver()
    let backend = Self.makeBackend(driver)
    await Self.observe(backend, into: driver)
    try await backend.prepare()
    driver.holdUnloads()
    let unload = Task { await backend.unloadAndSettle() }
    await driver.waitForLog("unloading 1")
    let park = Task { await backend.park() }
    await driver.waitForLog("event joinedUnload")
    driver.releaseUnloads()
    #expect(try await driver.bounded(unload) == UnloadReceipt(freed: 1, remaining: 0))
    #expect(try await driver.bounded(park) == UnloadReceipt(freed: 1, remaining: 0))
    await #expect(throws: ASRError.self, "the teardown's end does not clear the park") {
      try await backend.prepare()
    }
  }

  @Test("pressure that arrives during the load is serviced once the model is ready")
  func pressureDuringLoad() async throws {
    let driver = FakeWhisperDriver()
    driver.holdLoad("turbo.gguf")
    let backend = Self.makeBackend(
      driver,
      authorize: { teardown in
        _ = await teardown()
        return true
      })
    let prepare = Task { try await backend.prepare() }
    await driver.waitForLog("load turbo.gguf")
    await backend.handleMemoryPressure()
    #expect(await backend.operationCountsForTesting.pressurePending)
    driver.releaseLoad("turbo.gguf")
    try await driver.bounded(prepare)
    await driver.waitForLog("unload 1")
    #expect(await backend.isReady == false)
  }

  @Test("pressure deferred by a timed-out warm-up is serviced when that warm-up physically returns")
  func pressureAfterTimedOutWarmup() async throws {
    let driver = FakeWhisperDriver()
    driver.holdRuns()
    let backend = Self.makeBackend(
      driver,
      authorize: { teardown in
        _ = await teardown()
        return true
      }, warmupDeadline: 0.2)
    try await backend.prepare()  // fail-open ready after the warm-up ceiling
    #expect(await backend.isReady)
    await backend.handleMemoryPressure()
    #expect(!driver.log.contains("unloading 1"), "never while the orphan warm-up runs")
    driver.releaseRuns()
    await driver.waitForLog("unload 1")
    #expect(await backend.isReady == false)
  }

  @Test("progress stops when the caller leaves, even while native work continues")
  func progressStopsAfterCancellation() async throws {
    let driver = FakeWhisperDriver()
    let backend = Self.makeBackend(driver)
    try await backend.prepare()
    let seen = Recorder<Double>()
    await backend.setTranscriptionProgressObserver { seen.append($0) }
    driver.progressScript = [(10, 100)]
    driver.progressAfterRelease = [(90, 100), (100, 100)]
    driver.holdRuns()
    let take = Task {
      try await backend.transcribe(
        audioSamples: [Float](repeating: 0.1, count: 16_000), options: .default,
        onInferenceEntered: nil)
    }
    await driver.waitForLog("progress 10/100")
    take.cancel()
    await driver.waitForLog("drain-wait 1")
    driver.releaseRuns()
    await #expect(throws: CancellationError.self) { try await driver.bounded(take) }
    #expect(seen.values == [0.1])
  }

  @Test("after an unmatched segment, text that repeats ahead is ambiguous and left untimed")
  func ambiguousAfterUnmatched() {
    let bound = Backend.bindSegments(
      [
        TranscribeCppSegment(startMs: 0, endMs: 300, text: "alpha"),
        TranscribeCppSegment(startMs: 300, endMs: 600, text: "missing"),
        TranscribeCppSegment(startMs: 600, endMs: 900, text: "beta"),
        TranscribeCppSegment(startMs: 900, endMs: 1_200, text: "gamma"),
      ], text: "alpha beta beta gamma", envelope: 0..<32_000, originalSampleCount: 32_000)
    #expect(bound.map(\.range) == [0..<5, 16..<21])
  }

  // MARK: - Native text repair

  @Test("invalid UTF-8 from the engine is repaired by dropping only the broken bytes")
  func utf8Repair() {
    let bytes: [UInt8] = Array("नम".utf8) + [0xE0, 0xA4] + Array(" ok".utf8) + [0]
    let repaired = bytes.withUnsafeBufferPointer { buffer in
      buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
        TranscribeCppSession.repairedString($0)
      }
    }
    #expect(repaired == "नम ok")
    #expect(TranscribeCppSession.repairedString(nil) == "")
  }

  @Test("the bounded wait gives up on a task that never completes (deadline control)")
  func boundedDeadlineControl() async {
    let driver = FakeWhisperDriver()
    let never = Task<Int, any Error> {
      try await Task.sleep(for: .seconds(600))  // deadline-fallback: a subject that never finishes
      return 1
    }
    defer { never.cancel() }
    await withKnownIssue("the task never completes, so the bounded wait must expire") {
      await #expect(throws: BackendDeadlineExpired.self) {
        _ = try await driver.bounded(never, deadline: .milliseconds(200))
      }
    }
  }

  // MARK: - #4254 meeting speech detection

  /// 5 s of run: speech (0.3) at [16,000, 32,000) and [48,000, 56,000), exact zeros elsewhere.
  fileprivate static let meetingRun: [Float] = (0..<80_000).map {
    (16_000..<32_000).contains($0) || (48_000..<56_000).contains($0) ? 0.3 : 0
  }
  fileprivate static let meetingSpans = [16_000..<32_000, 48_000..<56_000]

  private func meetingEngine(
    _ driver: FakeWhisperDriver, detect: @escaping MeetingSpeechSpans
  ) async throws -> MeetingWhisperEngine<FakeWhisperDriver> {
    let engine = MeetingWhisperEngine(driver: driver, detectSpeech: detect)
    try await engine.load(modelPath: "turbo.gguf")
    return engine
  }

  @Test("#4254: a run with no speech is an empty success and the decoder is never entered")
  func meetingConfirmedSilence() async throws {
    let driver = FakeWhisperDriver()
    let engine = try await meetingEngine(driver) { _ in [] }
    let result = try await engine.transcribe(samples: Self.meetingRun, language: "en")
    #expect(result.text == "")
    #expect(result.meetingSpeechPreparation == .confirmedSilence)
    #expect(result.segmentTimings == [])
    #expect(driver.log.filter { $0.hasPrefix("enter ") }.isEmpty, "no native call")
  }

  @Test("#4254: speech with a short pause is one group, decoded as recorded; times come back")
  func meetingOneGroup() async throws {
    let driver = FakeWhisperDriver()
    let seen = LockedBox<[[Float]]>([])
    driver.runOutcome = { input, _ in
      seen.set(seen.get() + [input])
      // Group-relative times: the group starts at 1 s of the run.
      return TranscribeCppRunResult(
        text: " one two", detectedLanguage: nil,
        segments: [
          TranscribeCppSegment(startMs: 0, endMs: 1_000, text: " one"),
          TranscribeCppSegment(startMs: 2_000, endMs: 2_500, text: " two"),
        ])
    }
    // Spans 1-2 s and 3-3.5 s: a 1 s pause, under the 8 s grouping gap.
    let engine = try await meetingEngine(driver) { _ in Self.meetingSpans }
    let result = try await engine.transcribe(samples: Self.meetingRun, language: "en")
    let inputs = seen.get()
    #expect(inputs.count == 1, "one native call for one group")
    #expect(inputs.first.map { Array($0[0..<40_000]) } == Array(Self.meetingRun[16_000..<56_000]), "the pause is kept as recorded")
    #expect(inputs.first.map { $0.count } == 40_000 + 8_000)
    #expect(result.meetingSpeechPreparation == .protectedSpeech)
    #expect(result.text == "one two")
    #expect(result.segmentTimings?.map { [$0.startMs, $0.endMs] } == [[1_000, 2_000], [3_000, 3_500]])
    #expect(result.duration == 5)
  }

  /// 20 s of run: speech (0.3) at 1-2 s and 12-13 s, zeros elsewhere: a 10 s silence.
  fileprivate static let twoGroupRun: [Float] = (0..<320_000).map {
    (16_000..<32_000).contains($0) || (192_000..<208_000).contains($0) ? 0.3 : 0
  }

  @Test("#4254: a silence of 8 s or more separates groups; each is decoded alone, results combine in order")
  func meetingTwoGroups() async throws {
    let driver = FakeWhisperDriver()
    let calls = LockedBox<[Int]>([])
    driver.runOutcome = { input, language in
      let n = calls.get().count
      calls.set(calls.get() + [input.count])
      return TranscribeCppRunResult(
        text: n == 0 ? " hello there" : " bye now", detectedLanguage: language == nil ? "de" : nil,
        segments: [TranscribeCppSegment(startMs: 0, endMs: 900, text: n == 0 ? " hello there" : " bye now")])
    }
    let engine = try await meetingEngine(driver) { _ in [16_000..<32_000, 192_000..<208_000] }
    let result = try await engine.transcribe(samples: Self.twoGroupRun, language: nil)
    #expect(calls.get() == [16_000 + 8_000, 16_000 + 8_000], "two calls; the 10 s silence never decoded")
    #expect(result.text == "hello there bye now")
    #expect(result.segmentTimings?.map(\.range) == [0..<11, 12..<19], "ranges shifted past the inserted space")
    #expect(result.segmentTimings?.map { [$0.startMs, $0.endMs] } == [[1_000, 1_900], [12_000, 12_900]])
    #expect(result.language == "de", "the first group's language")
    #expect(driver.lastLanguage == "de", "carried to the later group")
    #expect(result.duration == 20)
  }

  @Test("#4254: a failure in a later group returns nothing and drains; no partial result")
  func meetingAtomicFailure() async throws {
    struct Broken: Error {}
    let driver = FakeWhisperDriver()
    let calls = LockedBox(0)
    driver.runOutcome = { _, _ in
      calls.set(calls.get() + 1)
      if calls.get() == 2 { throw TranscribeCppExecutor.ExecutorError.preempted }
      return TranscribeCppRunResult(text: " one", detectedLanguage: nil, segments: [])
    }
    let engine = try await meetingEngine(driver) { _ in [16_000..<32_000, 192_000..<208_000] }
    await #expect(throws: MeetingEngineYield.self) {
      _ = try await engine.transcribe(samples: Self.twoGroupRun, language: "en")
    }
    #expect(calls.get() == 2)
  }

  @Test("#4254: admission lost after the first group yields before the next native call")
  func meetingAdmissionPerGroup() async throws {
    let driver = FakeWhisperDriver()
    let calls = LockedBox(0)
    driver.runOutcome = { _, _ in
      calls.set(calls.get() + 1)
      return TranscribeCppRunResult(text: " one", detectedLanguage: nil, segments: [])
    }
    let handle = try await driver.load(modelPath: "turbo.gguf", lane: .preview)
    let checks = LockedBox(0)
    await #expect(throws: MeetingEngineYield.self) {
      _ = try await Backend.meetingDecode(
        driver: driver, handle: handle, samples: Self.twoGroupRun, language: "en", route: "test",
        detectSpeech: { _ in [16_000..<32_000, 192_000..<208_000] },
        isAdmitted: {
          checks.set(checks.get() + 1)
          return checks.get() == 1
        })
    }
    #expect(checks.get() == 2, "admission is checked before each group")
    #expect(calls.get() == 1, "the second group never reached native work")
    await driver.unload(handle)
  }

  @Test("#4254: cancellation during detection that finds no speech is cancellation")
  func meetingCancelledSilentDetection() async throws {
    let driver = FakeWhisperDriver()
    let engine = try await meetingEngine(driver) { _ in
      withUnsafeCurrentTask { $0?.cancel() }
      return []
    }
    await #expect(throws: CancellationError.self) {
      _ = try await engine.transcribe(samples: Self.meetingRun, language: "en")
    }
  }

  @Test("#4254: a quiet genuine ending after a long silence keeps its words")
  func meetingQuietEndingKept() async throws {
    // Loud speech early, a long silence, then a quiet but voiced ending at 4.5-5 s.
    let run: [Float] = (0..<80_000).map {
      if (0..<16_000).contains($0) { return 0.3 }
      if (72_000..<80_000).contains($0) { return 0.05 }
      return 0
    }
    let driver = FakeWhisperDriver()
    driver.runOutcome = { _, _ in
      TranscribeCppRunResult(
        text: " hello bye", detectedLanguage: nil,
        segments: [
          TranscribeCppSegment(startMs: 0, endMs: 1_000, text: " hello"),
          TranscribeCppSegment(startMs: 4_500, endMs: 5_000, text: " bye"),
        ])
    }
    let engine = try await meetingEngine(driver) { _ in [0..<16_000, 72_000..<80_000] }
    let result = try await engine.transcribe(samples: run, language: "en")
    #expect(result.text == "hello bye")
    #expect(result.segmentTimings?.map { [$0.startMs, $0.endMs] } == [[0, 1_000], [4_500, 5_000]])
  }

  @Test("#4254: a detector that cannot run decodes the whole run, marked unavailable")
  func meetingDetectorUnavailable() async throws {
    struct Broken: Error {}
    let driver = FakeWhisperDriver()
    let engine = try await meetingEngine(driver) { _ in throw Broken() }
    let result = try await engine.transcribe(samples: Self.meetingRun, language: "en")
    #expect(result.meetingSpeechPreparation == .detectionUnavailable)
    #expect(driver.lastSampleCount == 80_000 + 8_000)
  }

  @Test("#4254: cancellation during detection is cancellation, never an unfiltered decode")
  func meetingCancelledDuringDetection() async throws {
    let driver = FakeWhisperDriver()
    let engine = try await meetingEngine(driver) { _ in throw CancellationError() }
    await #expect(throws: CancellationError.self) {
      _ = try await engine.transcribe(samples: Self.meetingRun, language: "en")
    }
    #expect(driver.log.filter { $0.hasPrefix("enter ") }.isEmpty)
  }

  @Test("#4254: a model unloaded during detection yields before the native call")
  func meetingAdmissionLostDuringDetection() async throws {
    let driver = FakeWhisperDriver()
    let box = LockedBox<MeetingWhisperEngine<FakeWhisperDriver>?>(nil)
    let engine = try await meetingEngine(driver) { _ in
      await box.get()?.unload()
      return Self.meetingSpans
    }
    box.set(engine)
    await #expect(throws: MeetingEngineYield.self) {
      _ = try await engine.transcribe(samples: Self.meetingRun, language: "en")
    }
    #expect(driver.log.filter { $0.hasPrefix("enter ") }.isEmpty)
  }
}

/// A value shared with a `@Sendable` closure.
private final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value
  init(_ value: Value) { self.value = value }
  func get() -> Value { lock.withLock { value } }
  func set(_ new: Value) { lock.withLock { value = new } }
}

// MARK: - Helpers

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() { lock.withLock { count += 1 } }
  var value: Int { lock.withLock { count } }
}

private final class Recorder<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [T] = []
  func append(_ item: T) { lock.withLock { items.append(item) } }
  var values: [T] { lock.withLock { items } }
}

private struct BackendDeadlineExpired: Error {}

/// A one-shot async gate: `wait()` returns once `open()` has been called.
private final class AsyncGate: @unchecked Sendable {
  private let lock = NSLock()
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(open: Bool) { isOpen = open }

  func open() {
    let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      isOpen = true
      defer { waiters = [] }
      return waiters
    }
    for waiter in ready { waiter.resume() }
  }

  func close() { lock.withLock { isOpen = false } }

  func wait() async {
    await withCheckedContinuation { continuation in
      let proceed = lock.withLock { () -> Bool in
        if isOpen { return true }
        waiters.append(continuation)
        return false
      }
      if proceed { continuation.resume() }
    }
  }
}

/// A value set at most once; the first `fulfil` wins.
private final class FirstResult<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value?
  private var waiter: CheckedContinuation<Value, Never>?

  /// Returns whether this value won.
  @discardableResult
  func fulfil(_ value: Value) -> Bool {
    let (won, waiting) = lock.withLock { () -> (Bool, CheckedContinuation<Value, Never>?) in
      guard stored == nil else { return (false, nil) }
      stored = value
      defer { waiter = nil }
      return (true, waiter)
    }
    waiting?.resume(returning: value)
    return won
  }

  func value() async -> Value {
    await withCheckedContinuation { continuation in
      let ready = lock.withLock { () -> Value? in
        if let stored { return stored }
        waiter = continuation
        return nil
      }
      if let ready { continuation.resume(returning: ready) }
    }
  }
}

/// A fake executor driver. Native work runs in its own task: a cancelled caller is released
/// at once with `.cancelled` (as the real executor does) while the "native" call keeps running
/// until the test releases it, and `waitForDrain` waits for that return. A native open whose
/// caller left is freed when it returns ("orphan-free"), and `awaitSettled` waits until no open
/// runs and no opened model is alive, as the executor's registry does (#3849).
private final class FakeWhisperDriver: WhisperExecutorDriving, @unchecked Sendable {
  typealias Handle = Int

  private let lock = NSLock()
  private var _log: [String] = []
  private var nextHandle = 1
  private var loadGates: [String: AsyncGate] = [:]
  /// Holds a load before it reaches the executor (still travelling from the backend).
  private var arrivalGates: [String: AsyncGate] = [:]
  private var opening = 0
  private var live: Set<Int> = []
  private var settleWaiters: [CheckedContinuation<Int, Never>] = []
  private var runsIgnoreCancel = false
  private var runGate = AsyncGate(open: true)
  private var unloadGate = AsyncGate(open: true)
  private var nativeRunning: [Int: Int] = [:]
  private var drainWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
  private var logWaiters: [(String, CheckedContinuation<Void, Never>)] = []
  private var _lastLanguage: String??
  private var _lastSampleCount = 0
  private var _lidSampleCounts: [Int] = []

  var failLoad: (any Error)? {
    get { lock.withLock { _failLoad } }
    set { lock.withLock { _failLoad = newValue } }
  }
  private var _failLoad: (any Error)?

  var runOutcome: @Sendable ([Float], String?) throws -> TranscribeCppRunResult {
    get { lock.withLock { _runOutcome } }
    set { lock.withLock { _runOutcome = newValue } }
  }
  private var _runOutcome: @Sendable ([Float], String?) throws -> TranscribeCppRunResult = {
    _, _ in TranscribeCppRunResult(text: "ok", detectedLanguage: "en", segments: [])
  }

  var lidOutcome: @Sendable ([Float]) throws -> TranscribeCppLanguageObservation {
    get { lock.withLock { _lidOutcome } }
    set { lock.withLock { _lidOutcome = newValue } }
  }
  private var _lidOutcome: @Sendable ([Float]) throws -> TranscribeCppLanguageObservation = { _ in
    TranscribeCppLanguageObservation(code: "en", logProb: -0.01)
  }

  var progressScript: [(Int64, Int64)] {
    get { lock.withLock { _progressScript } }
    set { lock.withLock { _progressScript = newValue } }
  }
  private var _progressScript: [(Int64, Int64)] = []

  var log: [String] { lock.withLock { _log } }
  var lastLanguage: String? { lock.withLock { _lastLanguage ?? nil } }
  var lastSampleCount: Int { lock.withLock { _lastSampleCount } }
  var lidSampleCounts: [Int] { lock.withLock { _lidSampleCounts } }

  func holdLoad(_ path: String) { lock.withLock { loadGates[path] = AsyncGate(open: false) } }
  func releaseLoad(_ path: String) { lock.withLock { loadGates[path] }?.open() }
  func holdArrival(_ path: String) { lock.withLock { arrivalGates[path] = AsyncGate(open: false) } }
  func releaseArrival(_ path: String) { lock.withLock { arrivalGates[path] }?.open() }
  /// `ignoringCancel`: a cancelled caller stays until the run returns (records the cancel).
  func holdRuns(ignoringCancel: Bool = false) {
    lock.withLock {
      runGate = AsyncGate(open: false)
      runsIgnoreCancel = ignoringCancel
    }
  }
  func holdUnloads() { lock.withLock { unloadGate = AsyncGate(open: false) } }
  func releaseUnloads() { lock.withLock { unloadGate }.open() }

  /// Seeks the native run reports after the test releases it (after a caller may have left).
  var progressAfterRelease: [(Int64, Int64)] {
    get { lock.withLock { _progressAfterRelease } }
    set { lock.withLock { _progressAfterRelease = newValue } }
  }
  private var _progressAfterRelease: [(Int64, Int64)] = []
  func releaseRuns() { lock.withLock { runGate }.open() }

  func record(_ line: String) {
    let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      _log.append(line)
      let matched = logWaiters.filter { _log.contains($0.0) }.map(\.1)
      logWaiters.removeAll { _log.contains($0.0) }
      return matched
    }
    for waiter in ready { waiter.resume() }
  }

  func waitForLog(_ line: String, sourceLocation: SourceLocation = #_sourceLocation) async {
    let task = Task {
      await withCheckedContinuation { continuation in
        let present = lock.withLock { () -> Bool in
          if _log.contains(line) { return true }
          logWaiters.append((line, continuation))
          return false
        }
        if present { continuation.resume() }
      }
    }
    do {
      try await bounded(task, sourceLocation: sourceLocation)
    } catch {
      // Release the parked waiter so the test ends instead of hanging.
      let parked = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
        defer { logWaiters.removeAll { $0.0 == line } }
        return logWaiters.filter { $0.0 == line }.map(\.1)
      }
      for waiter in parked { waiter.resume() }
    }
  }

  // MARK: WhisperExecutorDriving

  // Every `withTaskCancellationHandler` here passes `isolation: nil`. The default overload is
  // emitted into each module; in the Release test lane this -Onone file's copy (80-byte frame)
  // was linked with an -O module's frame size (64 bytes), so the frame overran and the task
  // allocator aborted with "freed pointer was not the last allocation" (#3849;
  // swiftlang/swift#86204). The `isolation:` overload has no -O copy in this link (#3925).

  func load(modelPath: String, lane: TranscribeCppExecutor.Lane) async throws -> Int {
    if let arrival = lock.withLock({ arrivalGates[modelPath] }) {
      record("travelling \(modelPath)")
      await withTaskCancellationHandler(
        operation: { await arrival.wait() },
        onCancel: { self.record("cancel-seen \(modelPath)") },
        isolation: nil)
      record("arrived \(modelPath)")
    }
    let gate = lock.withLock { () -> AsyncGate? in
      opening += 1
      return loadGates[modelPath]
    }
    record("load \(modelPath)")
    let result = FirstResult<Result<Int, any Error>>()
    Task {
      if let gate { await gate.wait() }
      let opened: Result<Int, any Error> = lock.withLock {
        opening -= 1
        if let failure = _failLoad { return .failure(failure) }
        defer { nextHandle += 1 }
        live.insert(nextHandle)
        return .success(nextHandle)
      }
      if !result.fulfil(opened), case .success(let handle) = opened {
        lock.withLock { _ = live.remove(handle) }
        self.record("orphan-free \(handle)")
      }
      self.lifetimeChanged()
    }
    return try await withTaskCancellationHandler(
      operation: { try await result.value().get() },
      onCancel: { result.fulfil(.failure(TranscribeCppExecutor.ExecutorError.cancelled)) },
      isolation: nil)
  }

  func detectLanguage(
    _ handle: Int, samples: [Float], lane: TranscribeCppExecutor.Lane
  ) async throws -> TranscribeCppLanguageObservation {
    lock.withLock { _lidSampleCounts.append(samples.count) }
    return try lidOutcome(samples)
  }

  func transcribe(
    _ handle: Int, samples: [Float], language: String?, lane: TranscribeCppExecutor.Lane,
    onInferenceEntered: (@Sendable () -> Void)?, onProgress: (@Sendable (Int64, Int64) -> Void)?
  ) async throws -> TranscribeCppRunResult {
    if Task.isCancelled { throw TranscribeCppExecutor.ExecutorError.cancelled }
    onInferenceEntered?()
    let (gate, script, late, outcome) = lock.withLock {
      () -> (AsyncGate, [(Int64, Int64)], [(Int64, Int64)], _) in
      _lastLanguage = .some(language)
      _lastSampleCount = samples.count
      nativeRunning[handle, default: 0] += 1
      return (runGate, _progressScript, _progressAfterRelease, _runOutcome)
    }
    record("enter \(handle) lang=\(language ?? "nil") samples=\(samples.count)")
    let result = FirstResult<Result<TranscribeCppRunResult, any Error>>()
    Task {
      for (advanced, total) in script {
        onProgress?(advanced, total)
        self.record("progress \(advanced)/\(total)")
      }
      await gate.wait()
      for (advanced, total) in late { onProgress?(advanced, total) }
      let value = Result { try outcome(samples, language) }
      self.endNative(handle)
      result.fulfil(value)
    }
    let ignoresCancel = lock.withLock { runsIgnoreCancel }
    return try await withTaskCancellationHandler(
      operation: { try await result.value().get() },
      onCancel: {
        if ignoresCancel {
          self.record("run-cancel-seen \(handle)")
        } else {
          result.fulfil(.failure(TranscribeCppExecutor.ExecutorError.cancelled))
        }
      },
      isolation: nil)
  }

  private func endNative(_ handle: Int) {
    let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      nativeRunning[handle, default: 1] -= 1
      guard nativeRunning[handle] == 0 else { return [] }
      nativeRunning[handle] = nil
      return drainWaiters.removeValue(forKey: handle) ?? []
    }
    for waiter in ready { waiter.resume() }
  }

  func waitForDrain(_ handle: Int) async {
    await withCheckedContinuation { continuation in
      let idle = lock.withLock { () -> Bool in
        guard nativeRunning[handle, default: 0] > 0 else { return true }
        drainWaiters[handle, default: []].append(continuation)
        return false
      }
      if idle {
        continuation.resume()
      } else {
        record("drain-wait \(handle)")
      }
    }
  }

  func unload(_ handle: Int) async {
    record("unloading \(handle)")
    await lock.withLock { unloadGate }.wait()
    // The real executor aborts running work first; here the test's held run is released.
    if lock.withLock({ nativeRunning[handle, default: 0] > 0 }) {
      record("abort \(handle)")
      releaseRuns()
    }
    await waitForDrain(handle)
    lock.withLock { _ = live.remove(handle) }
    record("unload \(handle)")
    lifetimeChanged()
  }

  /// Every test load runs on the heart lane, so one registry stands for it.
  func awaitSettled(openedOn lane: TranscribeCppExecutor.Lane) async -> Int {
    await withCheckedContinuation { continuation in
      let settled = lock.withLock { () -> Bool in
        if opening == 0, live.isEmpty { return true }
        settleWaiters.append(continuation)
        return false
      }
      if settled {
        continuation.resume(returning: 0)
      } else {
        record("settle-wait")
      }
    }
  }

  private func lifetimeChanged() {
    let ready = lock.withLock { () -> [CheckedContinuation<Int, Never>] in
      guard opening == 0, live.isEmpty else { return [] }
      defer { settleWaiters = [] }
      return settleWaiters
    }
    for waiter in ready { waiter.resume(returning: 0) }
  }

  // MARK: Bounded waits

  /// Awaits a task with a deadline that does not depend on the task finishing.
  func bounded<T: Sendable, F: Error>(
    _ task: Task<T, F>, deadline: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws -> T {
    let first = FirstResult<Result<T, any Error>>()
    let watch = Task { first.fulfil(await task.result.mapError { $0 as any Error }) }
    let timeout = Task {
      try? await Task.sleep(for: deadline)  // deadline-fallback: bounds the subject's own completion
      first.fulfil(.failure(BackendDeadlineExpired()))
    }
    let outcome = await first.value()
    watch.cancel()
    timeout.cancel()
    if case .failure(let error) = outcome, error is BackendDeadlineExpired {
      Issue.record("the task never completed", sourceLocation: sourceLocation)
      releaseRuns()
      releaseUnloads()
      for gate in lock.withLock({ Array(loadGates.values) + Array(arrivalGates.values) }) {
        gate.open()
      }
    }
    return try outcome.get()
  }
}
