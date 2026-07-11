import Foundation

/// On-device safety classifier for Apple Intelligence polish output.
///
/// `score` returns the sigmoid probability that the polished output is a
/// composed artifact (instruction-execution) rather than a cleaned dictation.
/// Probability `>= OutputClassifierManifest.discardThreshold` ⇒ discard the
/// polish and fall back to the raw transcript.
///
/// The classifier is a LIMB, never the heart: every failure mode (missing
/// resources, contract mismatch, load failure, inference error, timeout, NaN)
/// fails open. `score` may throw; callers treat any throw as "keep the polish".
public protocol OutputClassifierProtocol: Sendable {
  func score(input: String, polished: String) async throws -> Double
}

/// Outcome of one `OutputClassifierHolder.beginLoadIfNeeded` call. Drives
/// whether the caller alerts Sentry, counts a PostHog event, or does nothing
/// (`OutputClassifierEmissionPolicy.forOutcome`, `WisprBootstrapper.swift`).
public enum OutputClassifierAttemptOutcome: Sendable, Equatable {
  case skippedAlreadyReady
  case skippedLoadInProgress
  case skippedPermanentlyDisabled(reason: OutputClassifierDisabledReason)
  case succeeded
  case failedFirstTime(reason: OutputClassifierDisabledReason)
  case failedRetryable(errorCategory: String)
}

/// Reference holder so the async-prewarmed classifier becomes visible to the
/// per-polish construction site once loading completes.
///
/// The classifier loads off the heart path AFTER the dictation factory and the
/// app composition root have already wired `LLMPolishStep`. `LLMPolishStep`
/// constructs `AppleIntelligenceConnector` per polish call (on the main actor),
/// reading `classifier` at that moment — so a value set after prewarm is picked
/// up by the next polish. `@MainActor` matches the `makePolisher` isolation;
/// no lock needed (set on main from the prewarm hop, read on main at polish).
/// Mirrors the `CoordinatorHolder` pattern (swift-patterns nsapp-delegate-env).
@MainActor
public final class OutputClassifierHolder {
  private enum LoadState {
    case notStarted
    case loading
    case ready(OutputClassifierProtocol)
    case disabled(OutputClassifierDisabledReason)
  }

  private var state: LoadState

  /// Read-only view for the one existing consumer (`LLMPolishStep`);
  /// non-nil only in `.ready`. Preserves the exact pre-existing read contract.
  public var classifier: OutputClassifierProtocol? {
    guard case .ready(let classifier) = state else { return nil }
    return classifier
  }

  public init(classifier: OutputClassifierProtocol? = nil) {
    state = classifier.map(LoadState.ready) ?? .notStarted
  }

  /// Single entry point for both trigger sites. Coalesces concurrent callers
  /// (state-gate-over-recheck: `.loading` is set BEFORE the `await`, so a
  /// second caller arriving during the suspension sees `.loading` and no-ops
  /// — no re-check window). `OutputClassifierError` (the closed, typed set
  /// `CoreMLOutputClassifier.load` maps every known failure into) is the only
  /// thing that permanently disables the holder for the rest of this process.
  /// `CancellationError` and any other unmapped error reset to `.notStarted`
  /// so a later trigger may retry — neither is evidence the classifier itself
  /// is broken.
  public func beginLoadIfNeeded(
    loader: @Sendable () async throws -> OutputClassifierProtocol
  ) async -> OutputClassifierAttemptOutcome {
    switch state {
    case .ready: return .skippedAlreadyReady
    case .loading: return .skippedLoadInProgress
    case .disabled(let reason): return .skippedPermanentlyDisabled(reason: reason)
    case .notStarted: state = .loading
    }
    do {
      let classifier = try await loader()
      state = .ready(classifier)
      return .succeeded
    } catch let error as OutputClassifierError {
      state = .disabled(error.reason)
      return .failedFirstTime(reason: error.reason)
    } catch is CancellationError {
      state = .notStarted
      return .failedRetryable(errorCategory: "cancelled")
    } catch {
      state = .notStarted
      return .failedRetryable(errorCategory: "unknown_load_error")
    }
  }
}
