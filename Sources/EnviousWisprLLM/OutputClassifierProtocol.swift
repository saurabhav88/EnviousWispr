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
  /// #3853: `release()` ran while this load was in flight, so its result (classifier or error)
  /// was dropped and the holder stays as the release left it.
  case discardedAfterRelease
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
  /// #3853: bumped by `release()`. A load compares it after its `await` and drops its result when
  /// it moved, so a classifier nobody needs any more is never published.
  private var generation: UInt64 = 0

  /// #3853: read synchronously when a load is REQUESTED and passed back as `requestedAt`, so a
  /// request still queued when `release()` runs is refused rather than loading for no consumer.
  public var releaseGeneration: UInt64 { generation }

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
  /// `requestedAt`: `releaseGeneration` when the caller decided to load; a release since then
  /// returns `.discardedAfterRelease` without loading (#3853). Nil skips that check.
  public func beginLoadIfNeeded(
    requestedAt: UInt64? = nil,
    loader: @Sendable () async throws -> OutputClassifierProtocol
  ) async -> OutputClassifierAttemptOutcome {
    if let requestedAt, requestedAt != generation { return .discardedAfterRelease }
    switch state {
    case .ready: return .skippedAlreadyReady
    case .loading: return .skippedLoadInProgress
    case .disabled(let reason): return .skippedPermanentlyDisabled(reason: reason)
    case .notStarted: state = .loading
    }
    let generationAtStart = generation
    do {
      let classifier = try await loader()
      guard generation == generationAtStart else { return .discardedAfterRelease }
      state = .ready(classifier)
      return .succeeded
    } catch let error as OutputClassifierError {
      guard generation == generationAtStart else { return .discardedAfterRelease }
      state = .disabled(error.reason)
      return .failedFirstTime(reason: error.reason)
    } catch is CancellationError {
      guard generation == generationAtStart else { return .discardedAfterRelease }
      state = .notStarted
      return .failedRetryable(errorCategory: "cancelled")
    } catch {
      guard generation == generationAtStart else { return .discardedAfterRelease }
      state = .notStarted
      return .failedRetryable(errorCategory: "unknown_load_error")
    }
  }

  /// #3853: drops the classifier when no consumer needs it, so its `MLModel` frees by ARC once
  /// any polish already holding it returns. A load in flight is abandoned: the state returns to
  /// `.notStarted` NOW (a renewed demand starts a fresh load instead of waiting on the abandoned
  /// one) and the generation bump makes the abandoned load drop whatever it completes with.
  /// `.disabled` stays: release is not evidence the classifier was fixed. The generation moves
  /// in `.notStarted` too, so a load requested but not yet started is refused.
  /// Returns whether anything was released, for the caller's log line.
  @discardableResult
  public func release() -> Bool {
    switch state {
    case .ready, .loading:
      generation &+= 1
      state = .notStarted
      return true
    case .notStarted:
      generation &+= 1
      return false
    case .disabled:
      return false
    }
  }
}
