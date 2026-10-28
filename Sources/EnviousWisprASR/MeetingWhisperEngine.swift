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

  package init(driver: Driver) {
    self.driver = driver
  }

  package var isLoaded: Bool { handle != nil }

  /// Loads the model at `modelPath`. A load refused or preempted because dictation's engine
  /// work came first throws `MeetingEngineYield`; nothing is then held.
  package func load(modelPath: String) async throws {
    guard handle == nil else { return }
    do {
      handle = try await driver.load(modelPath: modelPath, lane: .preview)
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
  }

  package func transcribe(samples: [Float], language: String?) async throws -> ASRResult {
    guard let handle else { throw MeetingEngineYield() }
    return try await TranscribeCppWhisperBackend<Driver>.meetingDecode(
      driver: driver, handle: handle, samples: samples, language: language)
  }

  /// Aborts and drains any run, then frees the model. Repeatable.
  package func unload() async {
    guard let handle else { return }
    self.handle = nil
    await driver.unload(handle)
  }
}

package typealias LiveMeetingWhisperEngine = MeetingWhisperEngine<LiveWhisperExecutorDriver>
