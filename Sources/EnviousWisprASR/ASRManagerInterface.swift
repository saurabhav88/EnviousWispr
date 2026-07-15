@preconcurrency import AVFoundation
import EnviousWisprCore

/// Thrown by `loadModel()` when the load it was running was superseded mid-flight
/// by a `cancelInFlightLoad()` (wedge recovery), an `unloadModel()`, or a real
/// `switchBackend(to:)` — detected via the manager's monotonic `loadGeneration`
/// token (#959). The completion does NOT mark the model loaded; surfacing it as a
/// throw (rather than a silent no-op) keeps `warmUp()` / `ensureEngineWarm()` from
/// reporting a false "warm-up succeeded" on a model that is no longer resident.
public struct ASRLoadSupersededError: Error, Equatable {
  public init() {}
}

/// #1525 PR G. Pins this struct's exact measured current wire identity
/// (`docs/audits/2026-07-14-1525-pr-g-preflight.md` §1) — a fixed string,
/// not a switch (this struct has no stored fields at all). Traced through
/// every production `warmUp()` caller: no currently reachable Sentry
/// capture path exists today (sessionless prewarm logs only; the launch/
/// prewarm classifier routes to non-Sentry telemetry; the session-owned
/// path's 3 supersession sources — cancelInFlightLoad(), unloadModel(), a
/// real switchBackend(to:) — are each already absorbed by earlier guards or
/// structurally deferred). This type represents an EXPECTED supersede
/// outcome, not necessarily a real failure, and it is pinned defensively so
/// a future capture site or topology change inherits a stable identity
/// rather than a runtime-assigned constant. NEVER change this string once
/// shipped.
extension ASRLoadSupersededError: StableSentryErrorIdentity {
  public var sentryFingerprintDescriptor: String {
    "EnviousWisprASR.ASRLoadSupersededError#1"
  }

  public var sentrySemanticID: String { "asr.load_superseded" }
}

// #1388: `ASRLoadCancelledError` (the deliberate-cancel resume for
// `cancelInFlightLoad()`) lives in EnviousWisprCore beside
// `ModelLoadWatchdog.WedgeError` — the pipeline driver classifies on it and
// does not import this module.

/// Abstraction over ASR management — enables swapping between in-process and XPC implementations.
///
/// `ASRManager` (in-process) and `ASRManagerProxy` (XPC) both conform to this protocol.
/// Pipelines and the former root state interact through this interface only.
@MainActor
public protocol ASRManagerInterface: AnyObject {
  // Observable state
  var activeBackendType: ASRBackendType { get }
  var isModelLoaded: Bool { get }
  var isStreaming: Bool { get }  // periphery:ignore - read via existential type (ASRManagerProxy)

  // Download progress (0.0–1.0), phase description, and detail string.
  // Updated during loadModel() when model download is in progress.
  // periphery:ignore:all - read via existential type in OnboardingV2View progress polling
  var downloadProgress: Double { get }
  var downloadPhase: String { get }
  var downloadDetail: String { get }

  // Model lifecycle
  /// #1348 Phase 2: when true, Parakeet loads are delivery-managed cache-only
  /// (the host admits verified bytes first; the load layer may never
  /// download). Set by `ParakeetEngineAdapter` from the delivery flag before
  /// each warm-up. Both conformers honor it on their Parakeet prepare path.
  var parakeetCacheOnly: Bool { get set }
  func loadModel() async throws
  func unloadModel() async  // periphery:ignore - called via existential type (ASRManager idle timer)
  func setInitialBackendType(_ type: ASRBackendType)
  func switchBackend(to type: ASRBackendType) async

  // Capability
  var activeBackendSupportsStreaming: Bool { get async }

  // Batch transcription
  func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult

  // Streaming transcription
  func startStreaming(options: TranscriptionOptions) async throws
  func feedAudio(_ buffer: AVAudioPCMBuffer) async throws
  func finalizeStreaming() async throws -> ASRResult
  func cancelStreaming() async

  // Pipeline lifecycle hooks
  func noteTranscriptionComplete(policy: ModelUnloadPolicy)
  func cancelIdleTimer()

  /// Issue #445: cancel a wedged in-flight model load and trigger service-level
  /// reset. Called by pipeline watchdog when `loadModel()` exceeds the recovery
  /// deadline. For in-process `ASRManager` this just cancels the host task;
  /// for `ASRManagerProxy` (XPC, production) this invalidates the connection
  /// to terminate the service-side load. Equivalent to manual app restart.
  func cancelInFlightLoad()

  /// Issue #445: per-tick callback for the load-progress polling stream.
  /// Set by the dictation kernel for the duration of one `loadModel()`
  /// call so the pipeline-owned `LoadProgressWatcher` receives mtime + phase
  /// observations from the proxy's existing 8Hz timer. Cleared after the
  /// load resolves. Closure-callback shape matches `swift-patterns.md` hot-
  /// path guidance (closure beats `any Protocol` existential dispatch).
  var loadProgressTickReporter: (@MainActor @Sendable (Date?, String) -> Void)? { get set }

  /// #1339: whether this manager's `loadModel()` progress lands in the shared
  /// progress file (`ProgressFile.shared`). Only the XPC proxy does — the
  /// in-process `ASRManager` reports through its own callback and never
  /// touches the file. The sessionless warm-up wedge guard polls that file,
  /// so it must arm ONLY over a file-backed load; arming over an in-process
  /// load would read permanent silence and cancel a healthy long first-run
  /// download at the deadline (Codex PR-1 r1 P2). Defaults to `false` — a
  /// manager must opt IN to file-backed stall detection.
  var feedsSharedProgressFile: Bool { get }

  // Crash notification — fires when XPC ASR service dies during an active session.
  // Wired by the App-side router to route to the active pipeline (same pattern as
  // the capture manager's `onEngineInterrupted`).
  var onServiceInterrupted: (() -> Void)? { get set }
}

extension ASRManagerInterface {
  /// #1339 safe default: managers do NOT feed the shared progress file unless
  /// they explicitly opt in (`ASRManagerProxy` does).
  public var feedsSharedProgressFile: Bool { false }

  /// #1348 safe default for test doubles: no delivery mode. BOTH production
  /// conformers (`ASRManager`, `ASRManagerProxy`) declare real storage, so
  /// their witnesses win; a mock that ignores writes is semantically correct
  /// (mocks never download).
  public var parakeetCacheOnly: Bool {
    get { false }
    set {}
  }
}
