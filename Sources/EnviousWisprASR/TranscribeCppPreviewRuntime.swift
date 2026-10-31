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
/// A meeting owner frees it explicitly instead, and learns when it is gone, through
/// `releaseAndDrain()` (#3973).
package actor TranscribeCppPreviewRuntime {

  /// Why a preview load refused. The adapter maps these to reasons; this module owns no text.
  package enum LoadFailure: Error, Equatable {
    /// Delivery has not admitted the artifact. Never a download trigger.
    case notAdmitted
    /// transcribe.cpp refused the model.
    case modelLoadFailed(String)
    /// #3973: heart work held the executor at load time (refused, or the load was preempted).
    /// Temporary: a later load can succeed.
    case heartBusy
    /// #3973: `releaseAndDrain()` began. This runtime never loads, opens or decodes again.
    case released
  }

  /// One loaded model, as closures over the driver's own handle type.
  struct LoadedModel: Sendable {
    /// One preview-lane decode of a window from a sample offset into it (#4254: a meeting
    /// window's leading silence is trimmed; 0 everywhere else). Segment times are relative to
    /// that offset. A cancelled or preempted call returns only after the native run
    /// physically ended.
    let transcribe: @Sendable ([Float], Int, String?) async throws -> TranscribeCppRunResult
    /// Aborts and drains any work on the model, then frees it.
    let unload: @Sendable () async -> Void
  }

  private let modelPath: String
  private let isAdmitted: @Sendable () async -> Bool
  private let loadModel: @Sendable (String) async throws -> LoadedModel
  private let cadence: Duration
  /// Test observation only (#3973): a caller is about to wait on a load or release another
  /// caller started. Never changes behaviour.
  private let observe: @Sendable (Join) -> Void
  enum Join: Sendable { case load, release }

  private var loaded: LoadedModel?
  /// The one load in flight; concurrent callers (prepare, then a session) share it, so the
  /// actor's reentrancy can never load the model twice.
  private var loading: Task<LoadedModel, Error>?

  /// #3973, meeting ownership. Set by `releaseAndDrain()` before its first suspension; every
  /// load, open and decode checks it after each of its own suspensions.
  private var closed = false
  /// The one physical release; concurrent and later callers join it.
  private var releasing: Task<Void, Never>?
  /// Decodes admitted into native work that have not returned. A session holds a use of the
  /// model only while one of its decodes is inside (`enterNativeDecode` to
  /// `nativeDecodeReturned`); between decodes it holds nothing, and after `closed` it can never
  /// enter again, so a retained or never-ended session cannot decode against a freed model.
  private var decodesInside = 0
  private var drainWaiters: [CheckedContinuation<Void, Never>] = []

  package init(modelPath: String, isAdmitted: @escaping @Sendable () async -> Bool) {
    self.init(driver: LiveWhisperExecutorDriver(), modelPath: modelPath, isAdmitted: isAdmitted)
  }

  init<Driver: WhisperExecutorDriving>(
    driver: Driver, modelPath: String, isAdmitted: @escaping @Sendable () async -> Bool,
    cadence: Duration = .seconds(1), residency: TranscribeCppPreviewResidency = .shared,
    observe: @escaping @Sendable (Join) -> Void = { _ in }
  ) {
    self.observe = observe
    self.modelPath = modelPath
    self.isAdmitted = isAdmitted
    self.cadence = cadence
    self.loadModel = { path in
      let handle = try await driver.load(modelPath: path, lane: .preview)
      residency.didLoad()
      return LoadedModel(
        transcribe: { samples, from, language in
          var input = Array(samples[min(from, samples.count)...])
          // The heart's look-ahead padding: without it abruptly-ending audio loses its last
          // words. Segments starting in it are dropped by the rolling session.
          input.append(
            contentsOf: [Float](
              repeating: 0, count: LiveTranscribeCppWhisperBackend.silencePaddingSamples))
          do {
            let run = try await driver.transcribe(
              handle, samples: input, language: language, lane: .preview,
              onInferenceEntered: nil, onProgress: nil)
            // #3801: preview hypotheses pass the same silent-tail filter as heart decodes.
            // Nothing below throws, so the catch still sees only the native call's errors.
            // #4254: loudness is read on the whole retained window, never the trimmed input.
            let tail = WhisperSilentTailFilter.filter(
              run, statsSamples: samples, segmentOffsetSamples: from, realEndSample: samples.count)
            await LiveTranscribeCppWhisperBackend.logSilentTail(tail.dropped, route: "preview")
            return tail.result
          } catch {
            // The executor releases a cancelled caller at once; a preempted one after the
            // native return. Either way, return only once nothing runs on this model, so a
            // finished teardown means the native run is over.
            if LiveTranscribeCppWhisperBackend.mapRunError(error) is CancellationError {
              await driver.waitForDrain(handle)
            }
            throw error
          }
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
  /// #3973: whether a load failure is only the heart holding the executor, so the same load
  /// may be tried again later.
  package static func isTemporary(_ error: any Error) -> Bool {
    (error as? LoadFailure) == .heartBusy
  }

  package func ensureLoaded() async throws {
    _ = try await model()
  }

  private func model() async throws -> LoadedModel {
    guard !closed else { throw LoadFailure.released }
    if let loaded { return loaded }
    if let loading { return try await joined(loading) }
    guard await isAdmitted() else { throw LoadFailure.notAdmitted }
    guard !closed else { throw LoadFailure.released }
    if let loaded { return loaded }
    if let loading { return try await joined(loading) }
    let load = loadModel
    let path = modelPath
    let task = Task {
      do {
        return try await load(path)
      } catch TranscribeCppExecutor.ExecutorError.heartBusy,
        TranscribeCppExecutor.ExecutorError.preempted
      {
        throw LoadFailure.heartBusy
      } catch {
        throw LoadFailure.modelLoadFailed(String(describing: error))
      }
    }
    loading = task
    defer { loading = nil }
    let model = try await task.value
    // A release that began during the load frees this model itself; it is never published.
    guard !closed else { throw LoadFailure.released }
    loaded = model
    return model
  }

  /// Another caller's load: its model, unless a release began while it loaded.
  private func joined(_ load: Task<LoadedModel, Error>) async throws -> LoadedModel {
    observe(.load)
    let model = try await load.value
    guard !closed else { throw LoadFailure.released }
    return model
  }

  /// A preview session over the loaded model, publishing bounded text through `onHypothesis`
  /// and reporting through `onAudioReleased` the audio its owner may drop (#2117).
  ///
  /// `language` nil is native detection (Auto): this model detects language itself, and must
  /// never inherit Apple's system-locale guess. The session holds this runtime through its
  /// decode closure, so the model stays loaded while any session can still decode.
  ///
  /// #3973, for EnviousMeet's live words: `onTranscript` receives the session's lossless
  /// transcript events (`Publication.onTranscript`). `admitDecode` is asked before every decode
  /// of this session, after the window is cut and before native work starts; throwing refuses
  /// that decode, which the rolling loop treats like any refused decode: the audio stays, and
  /// the next cycle tries again. Both default to today's behaviour.
  ///
  /// #4254: `liveSpeechDetector`, passed only for a meeting transcript session, turns on that
  /// session's speech detection (one fresh detector per run). Nil everywhere else.
  package func makeSession(
    language: String?,
    hypothesisRetentionLimit: Int,
    onHypothesis: @escaping @Sendable (String) -> Void,
    onAudioReleased: @escaping @Sendable (Int) -> Void,
    onTranscript: (@Sendable (TranscriptEvent) -> Void)? = nil,
    admitDecode: @escaping @Sendable () async throws -> Void = {},
    liveSpeechDetector: (@Sendable () -> any LiveSpeechDetecting)? = nil
  ) async throws -> any WhisperIncrementalSession {
    let model = try await model()
    var publication = TranscribeCppRollingSession.Publication(
      retentionLimit: hypothesisRetentionLimit, onHypothesis: onHypothesis,
      onAudioReleased: onAudioReleased)
    publication.onTranscript = onTranscript
    let decodeFrom: TranscribeCppRollingSession.DecodeFrom = { [self] samples, from in
      // The session keeps the model's owner alive while it can decode.
      try await admitDecode()
      // A session cancelled while its admission waited never starts native work.
      try Task.checkCancellation()
      try await enterNativeDecode()
      do {
        let result = try await model.transcribe(samples, from, language)
        await nativeDecodeReturned()
        return result
      } catch {
        await nativeDecodeReturned()
        throw error
      }
    }
    return TranscribeCppRollingSession(
      decode: { samples in try await decodeFrom(samples, 0) },
      cadence: cadence,
      publication: publication,
      meetingSpeech: liveSpeechDetector.map {
        TranscribeCppRollingSession.MeetingSpeech(makeDetector: $0, decodeFrom: decodeFrom)
      })
  }

  /// Whether a model is currently held. Lets a caller assert residency rather than infer it.
  package var isLoaded: Bool { loaded != nil }

  // MARK: - #3973: meeting release

  /// Frees this runtime's model for good, for an owner that must know when it is physically gone
  /// (EnviousMeet's live words, plan §3.3 "Native model release"). Before its first suspension
  /// it refuses every later load, open and decode. It then joins a load already in flight
  /// (freeing a model that arrives late, never publishing it), waits until no decode is inside
  /// native code, and returns only after the driver's unload returned. Idempotent: every caller
  /// joins one release and the model is freed once. A caller's cancellation does not shorten the
  /// wait or stop the release; an unload or decode that never returns keeps it waiting.
  ///
  /// Per runtime: completion says nothing about other runtimes (dictation's may stay loaded), so
  /// it never reads `TranscribeCppPreviewResidency`. Dictation never calls this; its runtime is
  /// still freed by `deinit` when its last holder lets go, and after a release `deinit` finds
  /// nothing to free.
  package func releaseAndDrain() async {
    await beginRelease().value
  }

  /// `releaseAndDrain()` without the wait: on return every later load, open and decode is
  /// already refused; the task completes when the model is physically freed.
  package func beginRelease() -> Task<Void, Never> {
    if let releasing {
      observe(.release)
      return releasing
    }
    closed = true
    let pending = loading
    let release = Task { await self.finishRelease(pending: pending) }
    releasing = release
    return release
  }

  private func finishRelease(pending: Task<LoadedModel, Error>?) async {
    // A pending load means nothing was published yet; its model, if it arrives, is freed here.
    var model = loaded
    if let pending { model = try? await pending.value }
    if decodesInside > 0 {
      await withCheckedContinuation { drainWaiters.append($0) }
    }
    loaded = nil
    await model?.unload()
  }

  private func enterNativeDecode() throws {
    guard !closed else { throw LoadFailure.released }
    decodesInside += 1
  }

  private func nativeDecodeReturned() {
    decodesInside -= 1
    guard decodesInside == 0 else { return }
    let waiters = drainWaiters
    drainWaiters = []
    for waiter in waiters { waiter.resume() }
  }
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
