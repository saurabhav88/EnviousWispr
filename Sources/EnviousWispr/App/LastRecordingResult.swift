import EnviousWisprCore
import Foundation
import Observation

/// PR7 of epic #763. Owns post-recording polish/error state — the single
/// observable fact "did the last polish fail, and with what message" — for
/// views to render an error banner after a recording completes.
///
/// **Lifetime.** Constructed once at app launch as `@State` on
/// `EnviousWisprApp`; lives for the entire process lifetime.
///
/// **Push model.** the former root state's existing Parakeet and WhisperKit
/// state-change closures (the former root-state file, `:548-572`) push to
/// `polishError` on every state transition. `toggleRecording` resets it
/// to `nil` on a new recording start. The full reset / cancel / failure
/// matrix is locked in the PR7 plan.
///
/// Replaces the pre-PR7 root-state getter.
///
/// **No imports of `EnviousWisprASR`, `EnviousWisprPipeline`, etc.** is
/// intentional. This home is observable storage, not a derivation surface;
/// keeping its import set narrow prevents callers from drifting it toward
/// pipeline-specific knowledge as PR9/PR11 dissolve the former root state.
@Observable @MainActor
final class LastRecordingResult {
  /// `nil` when polish succeeded (or never ran); a non-empty message when
  /// the last completed polish failed. Verbatim from the pipeline's
  /// `lastPolishError` — no rewrap. Cleared on the next recording start.
  var polishError: String?

  init() {
    self.polishError = nil
  }
}

// CI build-gate trigger for #804 (cache-first CI-speedup PR): a CI-workflow-only
// change otherwise sets needs_build=false and skips the build steps, so this PR
// could not self-test. This inert line forces needs_build=true. Safe to remove.
