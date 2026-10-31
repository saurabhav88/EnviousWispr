import EnviousWisprCore
import EnviousWisprTranscribeCpp
import Foundation

extension TranscribeCppWhisperBackend {
  /// #3973 C3: the meeting decode on `handle` at preview priority, with dictation's batch
  /// conditioning (silence padding, the silent-tail filter, segment binding with timestamps).
  ///
  /// #4254: a fresh speech detector reads the run first (`detectSpeech`). No speech: an empty,
  /// successful result and no native call. Speech: only the padded stretches, joined, reach the
  /// decoder in ONE run, and segment times are restored onto the original run before the
  /// silent-tail filter, which reads the original samples. A detector that cannot run decodes
  /// the whole run as before, marked unavailable; its cancellation is cancellation. After
  /// detection, cancellation and `isAdmitted` are checked again before the native call.
  ///
  /// Every native exit is joined before this returns. A cancelled pass throws
  /// `CancellationError`; preemption, a refusal while dictation's work runs, an aborted run, a
  /// model gone under it and a lost admission throw `MeetingEngineYield`; any other native
  /// failure is a run failure the job counts.
  static func meetingDecode(
    driver: Driver, handle: Driver.Handle, samples: [Float], language: String?,
    route: String, detectSpeech: MeetingSpeechSpans,
    isAdmitted: @Sendable () async -> Bool
  ) async throws -> ASRResult {
    let start = ContinuousClock.now
    try Task.checkCancellation()
    var preparation: MeetingWhisperPreparation?
    let provenance: MeetingSpeechPreparation
    do {
      let spans = try await detectSpeech(samples)
      guard
        let prepared = MeetingWhisperPreparation(
          samples: samples, stretches: spans, lookAhead: silencePaddingSamples)
      else {
        await logVAD(
          "vad_skipped_all", route: route, total: samples.count, speech: 0, stretches: 0)
        return ASRResult(
          text: "", language: language, duration: Double(samples.count) / Double(sampleRate),
          processingTime: Double((ContinuousClock.now - start) / .milliseconds(1)) / 1000,
          backendType: .whisper, segmentTimings: [], meetingSpeechPreparation: .confirmedSilence)
      }
      preparation = prepared
      provenance = .protectedSpeech
      await logVAD(
        "vad_ok", route: route, total: samples.count, speech: prepared.speechSamples,
        stretches: prepared.stretches.count)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if Task.isCancelled { throw CancellationError() }
      provenance = .detectionUnavailable
      await logVAD(
        "vad_unavailable", route: route, total: samples.count, speech: samples.count,
        stretches: 1)
    }
    var input: [Float]
    if let preparation {
      input = preparation.input
    } else {
      input = samples
      input.append(contentsOf: [Float](repeating: 0, count: silencePaddingSamples))
    }
    // Detection took time: the pass or this route's admission may have ended meanwhile.
    try Task.checkCancellation()
    guard await isAdmitted() else { throw MeetingEngineYield() }
    let run: TranscribeCppRunResult
    do {
      run = try await driver.transcribe(
        handle, samples: input, language: language, lane: .preview, onInferenceEntered: nil,
        onProgress: nil)
    } catch {
      await driver.waitForDrain(handle)
      if Task.isCancelled { throw CancellationError() }
      throw meetingError(error)
    }
    input = []
    // Restore first, then filter against the ORIGINAL run (§16.1): its statistics never come
    // from the joined speech, and look-ahead segments stay past the real end.
    let restored = preparation?.restore(run) ?? run
    let envelope = 0..<samples.count
    let tail = WhisperSilentTailFilter.filter(
      restored, statsSamples: samples, segmentOffsetSamples: 0, realEndSample: samples.count)
    await logSilentTail(tail.dropped, route: "meeting")
    var filtered = tail.result
    filtered.silentTailDropped = tail.dropped
    var result = mapResult(
      filtered, languageHint: language, envelope: envelope, originalSampleCount: samples.count,
      processingTime: Double((ContinuousClock.now - start) / .milliseconds(1)) / 1000,
      enableTimestamps: true)
    result.meetingSpeechPreparation = provenance
    return result
  }

  /// One counts-only line per meeting decode: route, outcome, detector version, and sample
  /// counts. No audio and no text.
  static func logVAD(_ outcome: String, route: String, total: Int, speech: Int, stretches: Int)
    async
  {
    await AppLogger.shared.log(
      "meeting_whisper_vad outcome=\(outcome) route=\(route) detector=\(MeetingWhisperPreparation.detectorVersion) run_samples=\(total) speech_samples=\(speech) stretches=\(stretches)",
      level: .info, category: "TranscribeCppWhisper")
  }

  /// A meeting decode's error once its run has ended (the caller was not cancelled).
  static func meetingError(_ error: any Error) -> any Error {
    switch error {
    case TranscribeCppExecutor.ExecutorError.preempted,
      TranscribeCppExecutor.ExecutorError.heartBusy,
      TranscribeCppExecutor.ExecutorError.cancelled,
      TranscribeCppExecutor.ExecutorError.modelUnavailable,
      is CancellationError:
      return MeetingEngineYield()
    case let native as TranscribeCppError where native.isAborted:
      return MeetingEngineYield()
    case let native as TranscribeCppError:
      return TranscribeCppWhisperError.runFailed(status: native.status)
    default:
      return error
    }
  }
}

/// #3973 C3: EnviousMeet's own Whisper Large v3 Turbo, used only while dictation runs another
/// engine (when dictation runs Whisper the meeting decodes on dictation's loaded model instead,
/// so one copy is resident). Loaded and decoded at PREVIEW priority, so it never blocks
/// dictation's Whisper teardown, which waits only for sessions opened on the heart lane.
///
/// The route loads it for one engine operation and unloads it after, so a switch of dictation
/// into Whisper waits for one operation, never the whole pass. Every session goes through the
/// one process-wide executor, so quit's executor teardown frees it whatever state it is in.
package actor MeetingWhisperEngine<Driver: WhisperExecutorDriving> {
  private let driver: Driver
  private var handle: Driver.Handle?
  /// Bumped by every unload, so a load that was in flight across it frees its own result
  /// instead of keeping a model the unload already promised was gone.
  private var generation = 0
  private var loadsInFlight = 0
  private var drainWaiters: [CheckedContinuation<Void, Never>] = []
  /// The latest model free, kept so every unload waits for one already running (the route's
  /// own unload, then Remove's) instead of returning while the model is still being freed.
  private var teardown: Task<Void, Never>?
  /// Closed by `closeForRemoval()` until `reopenAfterRemoval()`: no load starts while Remove
  /// deletes the model files.
  private var isClosed = false
  /// Tests only: told, on the engine, the moment `closeForRemoval()` is about to return.
  private var removalObserver: (@Sendable () -> Void)?

  /// #4254: the speech detector each decode creates fresh; tests pass their own.
  private let detectSpeech: MeetingSpeechSpans

  package init(driver: Driver, detectSpeech: @escaping MeetingSpeechSpans = MeetingWhisperPreparation.bundled) {
    self.driver = driver
    self.detectSpeech = detectSpeech
  }

  package var isLoaded: Bool { handle != nil }

  /// Whether `handle` is still this engine's loaded model (no unload or Remove since).
  private func holds(_ loaded: Driver.Handle) -> Bool {
    !isClosed && handle.map { $0 == loaded } == true
  }
  package var isClosedForRemoval: Bool { isClosed }

  /// Loads the model at `modelPath`. A load refused or preempted because dictation's engine
  /// work came first, a load during Remove, and a load an unload overtook throw
  /// `MeetingEngineYield`; nothing is then held.
  package func load(modelPath: String) async throws {
    guard handle == nil else { return }
    guard !isClosed else { throw MeetingEngineYield() }
    let startGeneration = generation
    loadsInFlight += 1
    defer { finishLoad() }
    let loaded: Driver.Handle
    do {
      loaded = try await driver.load(modelPath: modelPath, lane: .preview)
    } catch {
      if Task.isCancelled { throw CancellationError() }
      switch error {
      case TranscribeCppExecutor.ExecutorError.preempted,
        TranscribeCppExecutor.ExecutorError.heartBusy:
        throw MeetingEngineYield()
      default:
        throw error
      }
    }
    guard generation == startGeneration else {
      await driver.unload(loaded)
      throw MeetingEngineYield()
    }
    // A second load that overlapped this one already holds a model: keep that one.
    guard handle == nil else {
      await driver.unload(loaded)
      return
    }
    handle = loaded
  }

  package func transcribe(samples: [Float], language: String?) async throws -> ASRResult {
    guard let handle else { throw MeetingEngineYield() }
    return try await TranscribeCppWhisperBackend<Driver>.meetingDecode(
      driver: driver, handle: handle, samples: samples, language: language, route: "own_model",
      detectSpeech: detectSpeech, isAdmitted: { await self.holds(handle) })
  }

  /// Aborts and drains any run, frees the model, and waits until every free already running
  /// and every load in flight has ended (a late load frees its own result). Repeatable.
  package func unload() async {
    generation &+= 1
    if let handle {
      self.handle = nil
      let previous = teardown
      let driver = driver
      teardown = Task {
        await previous?.value
        await driver.unload(handle)
      }
    }
    await teardown?.value
    while loadsInFlight > 0 {
      await withCheckedContinuation { drainWaiters.append($0) }
    }
  }

  /// Remove's step before the model files go: no new load starts, and `unload()` has freed
  /// every copy, in flight or held.
  package func closeForRemoval() async {
    isClosed = true
    await unload()
    removalObserver?()
  }

  package func setRemovalObserver(_ observer: (@Sendable () -> Void)?) {
    removalObserver = observer
  }

  /// Remove's step after the deletion (successful or not): loads may start again.
  package func reopenAfterRemoval() {
    isClosed = false
  }

  private func finishLoad() {
    loadsInFlight -= 1
    guard loadsInFlight == 0 else { return }
    let waiters = drainWaiters
    drainWaiters = []
    for waiter in waiters { waiter.resume() }
  }
}

package typealias LiveMeetingWhisperEngine = MeetingWhisperEngine<LiveWhisperExecutorDriver>
