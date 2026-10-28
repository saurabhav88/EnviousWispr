import EnviousWisprCore
import EnviousWisprTranscribeCpp
import Foundation

extension TranscribeCppWhisperBackend {
  /// #3973 C3: the meeting decode on `handle` at preview priority, with dictation's batch
  /// conditioning (silence padding, the silent-tail filter, segment binding with timestamps).
  /// The whole input is speech for a meeting run, so there is no envelope.
  ///
  /// Every native exit is joined before this returns. A cancelled pass throws
  /// `CancellationError`; preemption, a refusal while dictation's work runs, an aborted run and
  /// a model gone under it throw `MeetingEngineYield`; any other native failure is a run
  /// failure the job counts.
  static func meetingDecode(
    driver: Driver, handle: Driver.Handle, samples: [Float], language: String?
  ) async throws -> ASRResult {
    var input = samples
    input.append(contentsOf: [Float](repeating: 0, count: silencePaddingSamples))
    let start = ContinuousClock.now
    try Task.checkCancellation()
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
    let envelope = 0..<samples.count
    let tail = WhisperSilentTailFilter.filter(
      run, statsSamples: samples, segmentOffsetSamples: 0, realEndSample: samples.count)
    await logSilentTail(tail.dropped, route: "meeting")
    var filtered = tail.result
    filtered.silentTailDropped = tail.dropped
    return mapResult(
      filtered, languageHint: language, envelope: envelope, originalSampleCount: samples.count,
      processingTime: Double((ContinuousClock.now - start) / .milliseconds(1)) / 1000,
      enableTimestamps: true)
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

  package init(driver: Driver) {
    self.driver = driver
  }

  package var isLoaded: Bool { handle != nil }
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
      driver: driver, handle: handle, samples: samples, language: language)
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
