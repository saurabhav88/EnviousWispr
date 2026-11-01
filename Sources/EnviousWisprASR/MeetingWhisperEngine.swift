import EnviousWisprCore
import EnviousWisprTranscribeCpp
import Foundation

extension TranscribeCppWhisperBackend {
  /// #3973 C3: the meeting decode on `handle` at preview priority, with dictation's batch
  /// conditioning (silence padding, the silent-tail filter, segment binding with timestamps).
  ///
  /// #4254 (plan §17): a fresh speech detector reads the run first (`detectSpeech`). No speech:
  /// an empty, successful result and no native call. Speech: each group
  /// (`MeetingWhisperPreparation.groups`, a contiguous original slice) is decoded on its own,
  /// in order, with the look-ahead; its segment times stay group-relative, the silent-tail filter
  /// reads the ORIGINAL run with the group's offset and end, and binding applies the group's
  /// offset once. The result is returned only after every group succeeded; any failure drains
  /// and propagates, and nothing partial is returned. A detector that cannot run decodes the
  /// whole run as before, marked unavailable; its cancellation is cancellation. Before each
  /// native call, admission is checked and then cancellation.
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
    let elapsed = { Double((ContinuousClock.now - start) / .milliseconds(1)) / 1000 }
    try Task.checkCancellation()
    // Pairs this decode's detection start with its outcome line (counts only). Clock readings
    // are taken at the events themselves, never when the logger writes.
    let token = UInt32.random(in: 1...UInt32.max)
    #if DEBUG
      let startedNs = MeetingSpeechDetectionActivity.begin(token)
    #else
      let startedNs = meetingDetectionUptimeNanos()
    #endif
    await AppLogger.shared.log(
      "whisper_meeting_vad_start token=\(token) route=\(route) run_samples=\(samples.count) uptime_raw_ns=\(startedNs)",
      level: .info, category: "TranscribeCppWhisper")
    let detected: Result<[Range<Int>], any Error>
    do {
      detected = .success(try await detectSpeech(samples))
    } catch {
      detected = .failure(error)
    }
    // Detection is over on every path before anything else runs.
    #if DEBUG
      let endedNs = MeetingSpeechDetectionActivity.end(token)
    #else
      let endedNs = meetingDetectionUptimeNanos()
    #endif
    let groups: [Range<Int>]
    let provenance: MeetingSpeechPreparation
    switch detected {
    case .success(let spans):
      groups = MeetingWhisperPreparation.groups(spans: spans, count: samples.count)
      provenance = .protectedSpeech
    case .failure(let error):
      if error is CancellationError || Task.isCancelled { throw CancellationError() }
      groups = [0..<samples.count]
      provenance = .detectionUnavailable
    }
    // Detection took time: the pass may have been cancelled meanwhile, even with no speech.
    try Task.checkCancellation()
    let speech = groups.reduce(0) { $0 + $1.count }
    await logVAD(
      groups.isEmpty ? "vad_skipped_all" : provenance == .protectedSpeech ? "vad_ok" : "vad_unavailable",
      token: token, route: route, total: samples.count, speech: speech, groups: groups.count,
      uptimeNs: endedNs)
    guard !groups.isEmpty else {
      return ASRResult(
        text: "", language: language, duration: Double(samples.count) / Double(sampleRate),
        processingTime: elapsed(), backendType: .whisper, segmentTimings: [],
        meetingSpeechPreparation: .confirmedSilence)
    }

    var text = ""
    var segments: [ASRSegmentTiming] = []
    var dropped = 0
    var groupLanguage = language
    var reportedLanguage = language
    for (index, group) in groups.enumerated() {
      // The pass or this route's admission may have ended since the last native call.
      guard await isAdmitted() else { throw MeetingEngineYield() }
      try Task.checkCancellation()
      var input = Array(samples[group])
      input.append(contentsOf: [Float](repeating: 0, count: silencePaddingSamples))
      let run: TranscribeCppRunResult
      do {
        run = try await driver.transcribe(
          handle, samples: input, language: groupLanguage, lane: .preview, onInferenceEntered: nil,
          onProgress: nil)
      } catch {
        await driver.waitForDrain(handle)
        if Task.isCancelled { throw CancellationError() }
        throw meetingError(error)
      }
      // Times stay group-relative: the filter and binding each apply the group's offset once.
      let tail = WhisperSilentTailFilter.filter(
        run, statsSamples: samples, segmentOffsetSamples: group.lowerBound,
        realEndSample: group.upperBound)
      dropped += tail.dropped
      let part = mapResult(
        tail.result, languageHint: groupLanguage, envelope: group,
        originalSampleCount: samples.count, processingTime: 0, enableTimestamps: true)
      if index == 0, language == nil, let detected = part.language {
        // One run keeps one language, as the single decode did. Only the first group decides;
        // when it detects none, later calls stay automatic and no language is reported.
        groupLanguage = detected
        reportedLanguage = detected
      }
      guard !part.text.isEmpty else { continue }
      if !text.isEmpty { text += " " }
      let shift = text.utf16.count
      text += part.text
      segments += (part.segmentTimings ?? []).map {
        ASRSegmentTiming(
          range: ($0.range.lowerBound + shift)..<($0.range.upperBound + shift),
          startMs: $0.startMs, endMs: $0.endMs)
      }
    }
    await logSilentTail(dropped, route: "meeting")
    return ASRResult(
      text: text, language: reportedLanguage, duration: Double(samples.count) / Double(sampleRate),
      processingTime: elapsed(), backendType: .whisper, segmentTimings: segments,
      silentTailDropped: dropped, meetingSpeechPreparation: provenance)
  }

  /// One counts-only line per meeting decode: route, outcome, detector version, and sample
  /// counts. No audio and no text.
  static func logVAD(
    _ outcome: String, token: UInt32, route: String, total: Int, speech: Int, groups: Int,
    uptimeNs: UInt64
  ) async {
    await AppLogger.shared.log(
      "whisper_meeting_vad outcome=\(outcome) token=\(token) route=\(route) detector=\(MeetingWhisperPreparation.detectorVersion) run_samples=\(total) group_samples=\(speech) groups=\(groups) uptime_raw_ns=\(uptimeNs)",
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
