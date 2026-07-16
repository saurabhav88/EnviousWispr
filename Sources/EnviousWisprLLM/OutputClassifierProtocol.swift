import CoreML
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

  /// #1226: true when this instance loaded via the `.cpuAndGPU` fallback path
  /// (the default-compute-units attempt failed its fixture self-test) rather
  /// than the default `.all` (ANE+GPU+CPU). A provenance flag, not a
  /// Failure/Bypass/Fallback signal itself — tags runtime `score()` telemetry
  /// so a load-time "succeeded via fallback" is not mistaken for "the runtime
  /// scoring budget is also fine on this compute path."
  var usedFallbackCompute: Bool { get }
}

/// Outcome of one `OutputClassifierHolder.beginLoadIfNeeded` call. Drives
/// whether the caller alerts Sentry, counts a PostHog event, or does nothing
/// (`OutputClassifierEmissionPolicy.forOutcome`, `WisprBootstrapper.swift`).
public enum OutputClassifierAttemptOutcome: Sendable, Equatable {
  case skippedAlreadyReady
  case skippedLoadInProgress
  case skippedPermanentlyDisabled(reason: OutputClassifierDisabledReason)
  case succeeded
  /// #1226: the `.all` (default compute units) attempt failed
  /// `fixtureSelfTestFailed`, and the bounded `.cpuAndGPU` retry succeeded.
  /// Fallback, not Failure — the classifier is active, just on a different
  /// compute path.
  case succeededViaFallback(primaryReason: OutputClassifierDisabledReason)
  /// Renamed from `.failedFirstTime` (#1226): failed on the FIRST attempt
  /// with a reason that is NOT retry-eligible (a packaging defect — contract
  /// hash, tokenizer, shape, missing file) — no `.cpuAndGPU` retry was
  /// attempted, since a different compute path cannot change the outcome.
  case failedNoRetry(reason: OutputClassifierDisabledReason)
  /// #1226: both the `.all` attempt AND the bounded `.cpuAndGPU` retry failed.
  /// Preserves BOTH reasons distinctly (never collapsed to "last reason
  /// wins") so triage can tell "still the same self-test failure" from
  /// "a different failure surfaced on the fallback path."
  case failedAfterFallback(
    primaryReason: OutputClassifierDisabledReason,
    fallbackReason: OutputClassifierDisabledReason
  )
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
  ///
  /// #1226: retry orchestration lives HERE, inside this one existing
  /// state-machine method — the loader closure widens to accept the compute
  /// units to load with, and a `fixtureSelfTestFailed` failure on `.all`
  /// (Mac17,x/M5) triggers exactly one bounded `.cpuAndGPU` retry before
  /// terminal failure. State stays `.loading` across both internal attempts
  /// (no re-check window opens for a concurrent caller mid-retry).
  public func beginLoadIfNeeded(
    loader: @Sendable (MLComputeUnits) async throws -> OutputClassifierProtocol
  ) async -> OutputClassifierAttemptOutcome {
    switch state {
    case .ready: return .skippedAlreadyReady
    case .loading: return .skippedLoadInProgress
    case .disabled(let reason): return .skippedPermanentlyDisabled(reason: reason)
    case .notStarted: state = .loading
    }
    do {
      let classifier = try await loader(.all)
      state = .ready(classifier)
      return .succeeded
    } catch let error as OutputClassifierError {
      guard error.reason.isRetryEligibleForComputeFallback else {
        state = .disabled(error.reason)
        return .failedNoRetry(reason: error.reason)
      }
      do {
        let classifier = try await loader(.cpuAndGPU)
        state = .ready(classifier)
        return .succeededViaFallback(primaryReason: error.reason)
      } catch let fallbackError as OutputClassifierError {
        state = .disabled(fallbackError.reason)
        return .failedAfterFallback(
          primaryReason: error.reason, fallbackReason: fallbackError.reason)
      } catch is CancellationError {
        state = .notStarted
        return .failedRetryable(errorCategory: "cancelled")
      } catch {
        state = .notStarted
        return .failedRetryable(errorCategory: "unknown_load_error")
      }
    } catch is CancellationError {
      state = .notStarted
      return .failedRetryable(errorCategory: "cancelled")
    } catch {
      state = .notStarted
      return .failedRetryable(errorCategory: "unknown_load_error")
    }
  }
}
