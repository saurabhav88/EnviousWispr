@preconcurrency import AVFoundation
import EnviousWisprCore
import Foundation

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

/// Thrown by `ActiveEngineOperation.load` when the load returned NORMALLY and the
/// engine's own readiness projection is still false (#2207). `ASRManager.loadModel()`
/// RECORDS readiness rather than requiring it (`ASRManager.swift:175-177`), so a
/// returning load has never meant "ready"; every caller nonetheless assumed it did.
///
/// Semantics: FAILURE, TRANSIENT. It means only "the load returned and the
/// postcondition was false" — deliberately NOT a claim about WHY. Readiness may
/// never have arrived, or may have been lost between the load's final internal
/// generation check and this one. Recovery gives either shape the same bounded
/// retry, so the distinction would buy nothing and asserting it would be a
/// causal claim the call site cannot observe.
///
/// Distinct from `ASRLoadSupersededError`, which means a supersede was detected
/// INSIDE the load. Conflating them is the #2132 trap: supersession classifies as
/// `.cancelled`, which recovery treats as terminal and DELETES the recording.
public struct ASREngineNotReadyAfterLoadError: Error, LocalizedError, Equatable {
  public init() {}

  /// Rendered to the user by the Diagnostics benchmark, which shows
  /// `error.localizedDescription`. Without this they would read Foundation's
  /// generated type-and-domain string. Every sibling error in this module
  /// already conforms; this one was the outlier.
  public var errorDescription: String? {
    "The engine finished loading but was not ready to use."
  }

  /// The same sentence in the app's language, for the Diagnostics benchmark (#3142).
  /// `errorDescription` stays fixed English: logs and recovery read it.
  public var displayMessage: String {
    String(
      localized: "The engine finished loading but was not ready to use.",
      comment: "Settings > Diagnostics, speed test: why loading the speech engine failed.")
  }
}

/// #1525 PR G. Pinned defensively at introduction rather than retrofitted: this
/// type IS reachable from a Sentry capture path on day one, via the recovery
/// replayer's unrecoverable branch. NEVER change this string once shipped.
extension ASREngineNotReadyAfterLoadError: StableSentryErrorIdentity {
  public var sentryFingerprintDescriptor: String {
    "EnviousWisprASR.ASREngineNotReadyAfterLoadError#1"
  }

  public var sentrySemanticID: String { "asr.engine_not_ready_after_load" }
}

/// Thrown when the ASR manager is asked to load or transcribe on an engine it
/// does not own (#1386 PR-2: WhisperKit). WhisperKit runs in-process behind its
/// relocation gate via `WhisperEngineAdapter`; the manager and its XPC helper
/// are Parakeet-only. This exists so the retired route fails loudly instead of
/// quietly doing nothing — or mapping a model the gate never saw.
package struct ASRManagerNotOwnedError: Error, Equatable {
  package let backend: ASRBackendType
  package init(backend: ASRBackendType) {
    self.backend = backend
  }
}

/// #1525 identity pin: a fixed wire identity, chosen (not measured — this type
/// is new in #1386 PR-2) so any future capture site inherits a stable
/// fingerprint. NEVER change this string once shipped.
extension ASRManagerNotOwnedError: StableSentryErrorIdentity {
  public var sentryFingerprintDescriptor: String {
    "EnviousWisprASR.ASRManagerNotOwnedError#1"
  }

  public var sentrySemanticID: String { "asr.manager_backend_not_owned" }
}

// #1388: `ASRLoadCancelledError` (the deliberate-cancel resume for
// `cancelInFlightLoad()`) lives in EnviousWisprCore beside
// `ModelLoadWatchdog.WedgeError` — the pipeline driver classifies on it and
// does not import this module.

/// #1908: thrown when a Parakeet load attempt would rewrite FluidAudio's
/// process-global `ModelHub.offlineMode` to a value DIFFERENT from what an
/// already-admitted, still-in-flight attempt is using. `ModelHub.offlineMode`
/// is not scoped to any one `ParakeetBackend` instance — fresh-backend-per-
/// attempt (see `ASRManager`) closes the per-instance race but not this one,
/// so a conflicting-mode attempt is refused outright rather than allowed to
/// race the shared write. A same-mode attempt is never refused.
package struct ParakeetOfflineModeConflictError: Error, Equatable {
  package init() {}
}

extension ParakeetOfflineModeConflictError: StableSentryErrorIdentity {
  public var sentryFingerprintDescriptor: String {
    "EnviousWisprASR.ParakeetOfflineModeConflictError#1"
  }

  public var sentrySemanticID: String { "asr.offline_mode_conflict" }
}

/// #3546 §3.7 T1: observation only. Called SYNCHRONOUSLY at the native-call boundary, after
/// the last cancellation check and with no suspension before the vendor call, so a recorded
/// entry always means the vendor call was made. Passed WITH the call it observes, never
/// installed on a shared object. It must not block, await or throw.
public typealias ASRInferenceEntryObserver = @Sendable () -> Void

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
  /// #3546 §3.7 T1: the identity of the model published READY right now, or
  /// `nil` when nothing is loaded. Telemetry sends `nil` as an absent model,
  /// never as a guessed one.
  var publishedModelIdentity: ASRModelIdentity? { get }

  // Download progress (0.0–1.0), phase description, and detail string.
  // Updated during loadModel() when model download is in progress.
  // periphery:ignore:all - read via existential type in OnboardingV2View progress polling
  var downloadProgress: Double { get }
  var downloadPhase: String { get }
  var downloadDetail: String { get }

  // Model lifecycle
  // #3546: the Parakeet load request (cache-only mode and install directory)
  // is no longer two settable members here. It is one package-visible
  // `ParakeetModelSelection` read from the `ParakeetSelectionProvider` injected
  // into `ASRManager`; the reasons these two members carried moved with them to
  // `ASRManager.parakeetSelection`.
  func loadModel() async throws
  func unloadModel() async  // periphery:ignore - called via existential type (ASRManager idle timer)
  func setInitialBackendType(_ type: ASRBackendType)
  func switchBackend(to type: ASRBackendType) async

  // Capability
  var activeBackendSupportsStreaming: Bool { get async }

  // Batch transcription
  /// #3546 §3.7 T1: passed with THIS call and invoked synchronously by the backend at its
  /// vendor-call boundary, after readiness, preparatory work and the last cancellation check.
  /// A refused call never invokes it. `nil` for a caller with no take to attribute.
  func transcribe(
    audioSamples: [Float], options: TranscriptionOptions,
    onInferenceEntered: ASRInferenceEntryObserver?
  ) async throws -> ASRResult

  /// #2787: whether a vendor decode (`transcribe` / `finalizeStreaming`) is
  /// still running, independent of whether any session is still waiting for
  /// it. No protocol default on purpose: a conformer that answered "idle"
  /// by omission would let a record press mint a session on top of a decode
  /// that never returned, which is the exact state this exists to expose.
  var vendorDecodeOccupancy: VendorDecodeOccupancy { get }

  /// #2787: observation only — see `ASRManager.onVendorDecodeChunkScheduled`.
  var onVendorDecodeChunkScheduled: (@MainActor @Sendable () -> Void)? { get set }
  /// #2918: observation only — see `ASRManager.onTranscriptionProgress`.
  var onTranscriptionProgress: (@MainActor @Sendable (Double) -> Void)? { get set }

  // Streaming transcription
  /// Create a fresh `attemptID` before scheduling the call and its deadline —
  /// `cancelInFlightStreamingStart(attemptID:)` needs it to name exactly
  /// this attempt (#1908 round 11).
  /// #3546 §3.7 T1: `onWindowInferenceEntered` is handed to the vendor's streaming manager,
  /// which calls it synchronously immediately before each window's model call. Observation
  /// only; it changes no start, stop or cancel decision. `nil` for a caller with no take.
  func startStreaming(
    options: TranscriptionOptions, attemptID: UUID,
    onWindowInferenceEntered: ASRInferenceEntryObserver?
  ) async throws
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

  /// #1908: the HEAVY half of issue #445 wedge recovery, called ONLY after
  /// `cancelInFlightLoad()`. In-process, a deadline-bounded, fail-open attempt
  /// to unload the currently-published backend — WhisperKit's
  /// `recoverFromWedge()` pattern, ported. `ASRManagerProxy`'s XPC connection
  /// invalidation already does the equivalent job, so it keeps the protocol
  /// extension's no-op default rather than overriding.
  func attemptWedgeRecoveryUnload() async

  /// #1908 Codex review (chunk A+B rounds 4-5, revised round 11): invalidate
  /// an in-flight `startStreaming()` attempt that a caller has given up
  /// waiting on (e.g. a deadline expiry), so its late completion cannot
  /// resurrect streaming state behind the caller's back — the exact class
  /// `cancelInFlightLoad()` exists for on the load side. Unlike
  /// `cancelInFlightLoad()`, this fires even when `isStreaming` is still
  /// `false` (the attempt never got that far), so it cannot be expressed as
  /// an ordinary `cancelStreaming()` call, which guards on `isStreaming`.
  ///
  /// Pass the SAME `attemptID` given to `startStreaming(options:attemptID:)`.
  /// A no-op if that id is not the currently tracked attempt — this must
  /// never invalidate a NEWER attempt that has already replaced it.
  ///
  /// SYNCHRONOUS, not `async` — round 5's finding: a caller that awaits an
  /// `async` invalidation before proceeding still leaves a window where the
  /// abandoned vendor call can complete and publish first. A synchronous
  /// method is callable from `withMainActorOrderedDeadline`'s non-async `onTimeout`,
  /// which guarantees it runs BEFORE the timed-out caller resumes.
  ///
  /// #1908 round 12: returns the backend's own reclaim `Task` (or `nil` if
  /// there was nothing to invalidate) so an `async` caller that CAN await —
  /// unlike the synchronous `onTimeout` this method primarily exists for —
  /// can wait for the SAME cancellation instead of racing a redundant one of
  /// its own (`ASRManager.cancelStreaming()`,
  /// `ParakeetEngineAdapter.discardSession()`). `@discardableResult` so
  /// `onTimeout` keeps compiling unchanged.
  @discardableResult
  func cancelInFlightStreamingStart(attemptID: UUID) -> Task<Void, Never>?

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

  #if DEBUG
    // #1908: #1707 Phase 2 batch-decode fault oracle. Both conformers already
    // implement these; declared on the protocol so `BatchDecodeFaultController`
    // (`EnviousWisprPipeline`) can reach whichever is live through the
    // existential instead of downcasting to `ASRManagerProxy` specifically —
    // that downcast is what silently went dark the moment the proxy stopped
    // being constructed (#1908 grounded review).
    func armBatchDecodeHold(trialID: String) async
    func releaseBatchDecode(trialID: String) async
    func clearBatchDecodeFault() async
  #endif
}

extension ASRManagerInterface {
  /// #3546 safe default for test doubles, which publish no delivered model:
  /// no identity, so telemetry omits the model rather than naming a wrong one.
  /// `ASRManager` overrides it with its published request.
  public var publishedModelIdentity: ASRModelIdentity? { nil }


  /// #1339 safe default: managers do NOT feed the shared progress file unless
  /// they explicitly opt in (`ASRManagerProxy` does).
  public var feedsSharedProgressFile: Bool { false }

  /// #1908 safe default: a conformer with no HEAVY wedge-recovery step (today,
  /// `ASRManagerProxy` — its `cancelInFlightLoad()` XPC connection invalidation
  /// already does the equivalent job) does nothing extra here.
  public func attemptWedgeRecoveryUnload() async {}

  /// #1908 safe default: a test double has no real background vendor Task
  /// whose late completion could corrupt state, so there is nothing to
  /// invalidate. `ASRManager` overrides with the real implementation;
  /// `ASRManagerProxy` relies on this same no-op — its own
  /// `withASRXPCOperationSignal` watchdog already fully recovers a wedged
  /// `startStreaming()` (invalidates the connection), so the caller-abandoned
  /// gap this method exists to close never opens there.
  @discardableResult
  public func cancelInFlightStreamingStart(attemptID: UUID) -> Task<Void, Never>? { nil }

  #if DEBUG
    /// #1908 safe defaults for test doubles: a mock backend has no real
    /// decode to fault-inject against, so arming/releasing/clearing is a
    /// no-op. Both production conformers (`ASRManager`, `ASRManagerProxy`)
    /// declare real implementations, so their witnesses win.
    public func armBatchDecodeHold(trialID: String) async {}
    public func releaseBatchDecode(trialID: String) async {}
    public func clearBatchDecodeFault() async {}
  #endif
}

/// Thrown when a Parakeet load is asked for before anything has said WHERE the
/// model lives (#2697).
///
/// Its existence is the point. The previous shape answered an assumed directory
/// instead, so a caller that skipped the host's assignment loaded from a location
/// nobody had verified, and a refusal from the location seam looked exactly like
/// a working path.
package struct ParakeetModelDirectoryUnsetError: Error, Equatable {
  package init() {}
}
