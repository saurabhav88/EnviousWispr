import EnviousWisprTranscribeCpp
import Foundation
import os

/// The ONE place that loads and decodes with the Universal Live Preview model on transcribe.cpp
/// (#3735 plan §3.5; live-preview.md RULE: universal-preview-engine-safety).
///
/// Separate from `TranscribeCppWhisperBackend` because the two serve different masters: the
/// backend's turbo model writes the user's document and owns the heart lane, occupancy and the
/// app's model attribution; this whisper-small model only draws pixels. So this runtime:
/// - loads and decodes on the executor's PREVIEW lane only, which heart work preempts and which
///   refuses while heart work is queued or running (`TranscribeCppExecutor`);
/// - never touches `VendorDecodeOccupancy`, the heart's model scope or its telemetry;
/// - receives a resolved model path and an admission ANSWER, never a fetch capability, so a
///   display limb cannot start a download.
///
/// **The executor, not ARC, owns the loaded model.** Dropping the retired WhisperKit runtime
/// freed its model; a transcribe.cpp model stays in the executor until someone unloads it. So the
/// model is unloaded exactly once when this runtime is released (every holder dropped it), and
/// `TranscribeCppPreviewResidency` lets Remove wait for that free before it deletes the file.
package actor TranscribeCppPreviewRuntime {

  /// Why a preview load refused. The adapter maps these to reasons; this module owns no text.
  package enum LoadFailure: Error, Equatable {
    /// Delivery has not admitted the artifact. Never a download trigger.
    case notAdmitted
    /// transcribe.cpp refused the model, or heart work held the executor at load time.
    case modelLoadFailed(String)
  }

  /// One loaded model, as closures over the driver's own handle type.
  struct LoadedModel: Sendable {
    /// One preview-lane decode. A cancelled or preempted call returns only after the native
    /// run physically ended.
    let transcribe: @Sendable ([Float], String?) async throws -> TranscribeCppRunResult
    /// Aborts and drains any work on the model, then frees it.
    let unload: @Sendable () async -> Void
  }

  private let modelPath: String
  private let isAdmitted: @Sendable () async -> Bool
  private let loadModel: @Sendable (String) async throws -> LoadedModel
  private let cadence: Duration

  private var loaded: LoadedModel?
  /// The one load in flight; concurrent callers (prepare, then a session) share it, so the
  /// actor's reentrancy can never load the model twice.
  private var loading: Task<LoadedModel, Error>?

  package init(modelPath: String, isAdmitted: @escaping @Sendable () async -> Bool) {
    self.init(driver: LiveWhisperExecutorDriver(), modelPath: modelPath, isAdmitted: isAdmitted)
  }

  init<Driver: WhisperExecutorDriving>(
    driver: Driver, modelPath: String, isAdmitted: @escaping @Sendable () async -> Bool,
    cadence: Duration = .seconds(1), residency: TranscribeCppPreviewResidency = .shared
  ) {
    self.modelPath = modelPath
    self.isAdmitted = isAdmitted
    self.cadence = cadence
    self.loadModel = { path in
      let handle = try await driver.load(modelPath: path, lane: .preview)
      residency.didLoad()
      return LoadedModel(
        transcribe: { samples, language in
          var input = samples
          // The heart's look-ahead padding: without it abruptly-ending audio loses its last
          // words. Segments starting in it are dropped by the rolling session.
          input.append(
            contentsOf: [Float](
              repeating: 0, count: LiveTranscribeCppWhisperBackend.silencePaddingSamples))
          let run: TranscribeCppRunResult
          do {
            run = try await driver.transcribe(
              handle, samples: input, language: language, lane: .preview,
              onInferenceEntered: nil, onProgress: nil)
          } catch {
            // The executor releases a cancelled caller at once; a preempted one after the
            // native return. Either way, return only once nothing runs on this model, so a
            // finished teardown means the native run is over.
            if LiveTranscribeCppWhisperBackend.mapRunError(error) is CancellationError {
              await driver.waitForDrain(handle)
            }
            throw error
          }
          // #3801: preview hypotheses pass the same silent-tail filter as heart decodes.
          let tail = WhisperSilentTailFilter.filter(
            run, statsSamples: samples, segmentOffsetSamples: 0, realEndSample: samples.count)
          await LiveTranscribeCppWhisperBackend.logSilentTail(tail.dropped, route: "preview")
          return tail.result
        },
        unload: {
          await driver.unload(handle)
          residency.didUnload()
        })
    }
  }

  deinit {
    // Every holder let go: the cached slot, sessions and preparations. Free the model now;
    // nothing can decode on it any more, because each decode holds this runtime.
    if let loaded {
      Task { await loaded.unload() }
    }
  }

  /// Loads once and keeps it. Throws rather than downloading: an unadmitted artifact is refused
  /// before anything touches the file.
  package func ensureLoaded() async throws {
    _ = try await model()
  }

  private func model() async throws -> LoadedModel {
    if let loaded { return loaded }
    if let loading { return try await loading.value }
    guard await isAdmitted() else { throw LoadFailure.notAdmitted }
    if let loaded { return loaded }
    if let loading { return try await loading.value }
    let load = loadModel
    let path = modelPath
    let task = Task {
      do {
        return try await load(path)
      } catch {
        throw LoadFailure.modelLoadFailed(String(describing: error))
      }
    }
    loading = task
    defer { loading = nil }
    let model = try await task.value
    loaded = model
    return model
  }

  /// A preview session over the loaded model, publishing bounded text through `onHypothesis`.
  ///
  /// `language` nil is native detection (Auto): this model detects language itself, and must
  /// never inherit Apple's system-locale guess. The session holds this runtime through its
  /// decode closure, so the model stays loaded while any session can still decode.
  package func makeSession(
    language: String?,
    hypothesisRetentionLimit: Int,
    onHypothesis: @escaping @Sendable (String) -> Void
  ) async throws -> any WhisperIncrementalSession {
    let model = try await model()
    return TranscribeCppRollingSession(
      decode: { [self] samples in
        _ = self  // the session keeps the model's owner alive while it can decode
        return try await model.transcribe(samples, language)
      },
      cadence: cadence,
      publication: .init(retentionLimit: hypothesisRetentionLimit, onHypothesis: onHypothesis))
  }

  /// Whether a model is currently held. Lets a caller assert residency rather than infer it.
  package var isLoaded: Bool { loaded != nil }
}

/// How many preview models are loaded in the executor right now (`shared`: process-wide).
///
/// Removing the preview model must free the model before its file is deleted. Holders release
/// the runtime synchronously, but the free itself is asynchronous (the executor drains running
/// work first), so Remove waits here after the holders are gone. Tests use their own instance.
package final class TranscribeCppPreviewResidency: Sendable {
  package static let shared = TranscribeCppPreviewResidency()

  private struct State {
    var loaded = 0
    var waiters: [CheckedContinuation<Void, Never>] = []
  }
  private let state = OSAllocatedUnfairLock(initialState: State())

  init() {}

  func didLoad() { state.withLock { $0.loaded += 1 } }

  func didUnload() {
    let ready = state.withLock { s -> [CheckedContinuation<Void, Never>] in
      s.loaded = max(0, s.loaded - 1)
      guard s.loaded == 0 else { return [] }
      defer { s.waiters = [] }
      return s.waiters
    }
    for waiter in ready { waiter.resume() }
  }

  package var loadedCount: Int { state.withLock { $0.loaded } }

  /// Returns once no preview model is loaded.
  package func waitUntilNoneLoaded() async {
    await withCheckedContinuation { continuation in
      let now = state.withLock { s -> Bool in
        if s.loaded == 0 { return true }
        s.waiters.append(continuation)
        return false
      }
      if now { continuation.resume() }
    }
  }
}
