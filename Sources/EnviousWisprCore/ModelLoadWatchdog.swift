import Foundation

/// Issue #445: shared constants and types for the model-load watchdog.
///
/// the dictation kernel (Parakeet) wraps its model-load `await` in
/// `raceWithSignalWatcher` against a `LoadProgressWatcher`, surfaces a
/// Sentry/PostHog event on wedge, and triggers service-level recovery via
/// `asrManager.cancelInFlightLoad()` (XPC connection invalidate, host task
/// cancel, fresh helper on next press).
///
/// The wall-clock `deadlineMs` constant from the prior design is gone; the
/// trigger is now signal-based (`LoadProgressWatcher`). `WedgeError` remains
/// because the recovery surface (Sentry event + the user-visible retry
/// overlay) is unchanged. #1558 removed the `userMessage` copy constant: a
/// wedge now maps to the typed `TerminalNoticeReason.modelWedged`, and the
/// AppKit presenter authors the sentence.
public enum ModelLoadWatchdog {
  /// Synthetic error type used when capturing the wedge to Sentry.
  /// The wedge is silent (no thrown error from the underlying call); we
  /// fabricate one so the existing `SentryBreadcrumb.captureError(...)` API
  /// can record the event with a stable type and category.
  public struct WedgeError: Error, CustomStringConvertible {
    public let stage: String
    public init(stage: String = "model_load") {
      self.stage = stage
    }
    public var description: String { "model load wedged at stage=\(stage)" }
  }
}

// MARK: - Sentry identity

/// Pins `WedgeError`'s Sentry grouping key to the exact string it has been
/// sending in production, so a future second case/shape can never renumber
/// it (#1525 PR B). Not derived — measured against shipping code and
/// cross-checked against the live Sentry issue title (ENVIOUSWISPR-30,
/// `docs/sentry-identity-refactor/BIBLE.md` §2.5.5). `WedgeError` has one
/// shape today, so there is nothing to reorder yet; this pin closes the
/// latent risk before a second shape is ever added, mirroring
/// `HeartPathError`'s shipped pattern (#1524).
extension ModelLoadWatchdog.WedgeError: StableSentryErrorIdentity {
  public var sentryFingerprintDescriptor: String {
    "EnviousWisprCore.ModelLoadWatchdog.WedgeError#1"
  }

  public var sentrySemanticID: String { "modelload.wedge" }
}

/// #1388 step 1: thrown from `loadModel()` when the in-flight load was
/// deliberately cancelled — a user Cancel during onboarding install, or the
/// wedge guard's teardown (both route through `cancelInFlightLoad()`).
/// Deliberately NOT a transport error: the adapter's one-shot transport
/// retry (`ParakeetEngineAdapter.loadModelWithTransportRecovery`) retries any
/// transport error, which would silently restart a load the user just
/// cancelled. The two causes share this resume vehicle but never an outcome:
/// `KernelDictationDriver.ensureEngineWarm` classifies a guard fire
/// (`didFire`) as `WedgeError`/`.failed` FIRST; only a user-initiated cancel
/// maps to `EngineWarmupOutcome.cancelled`. Lives in Core beside `WedgeError`
/// so the ASR layer (thrower) and the pipeline driver (classifier) share it
/// without a new cross-module import.
public struct ASRLoadCancelledError: Error, Equatable {
  public init() {}
}
