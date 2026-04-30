import Foundation

/// Sendable raw observation from a single WhisperKit `detectLangauge` window.
///
/// `WhisperKit.detectLangauge` returns a single-entry `langProbs` map of the form
/// `{detectedLanguage: logProb}` — i.e. the argmax language for that window plus
/// its log-softmax score. Per-window aggregation (vote counting + mean probability)
/// happens in `LanguageDetector` against a batch of these.
///
/// This is the Sendable surface that crosses the `WhisperKitBackend` actor boundary.
/// The non-Sendable `WhisperKit` reference itself never leaves the backend.
package struct RawLIDObservation: Sendable, Equatable {
  package let argmaxLang: String
  package let logProb: Double

  package init(argmaxLang: String, logProb: Double) {
    self.argmaxLang = argmaxLang
    self.logProb = logProb
  }
}

/// Outcome of a backend-side LID observation pass. Distinguishes Bypass
/// (`.unavailable`, `.noWindows`) from Failure (`.error`) and Success
/// (`.observations`) so the classifier can map each to the matching abstain reason.
///
/// Cancellation is a separate Bypass: the user hotkey-cancelled mid-flight; the
/// classifier should NOT touch session memory in this case (matches today's
/// behavior in `LanguageDetector.detect` cancellation branch).
package enum LIDObservationBatch: Sendable {
  /// Backend not ready (WhisperKit handle is nil — model unloaded). Caller
  /// abstains; pipeline passes nil language to `WhisperKit.transcribe`, letting
  /// WhisperKit's internal LID run during transcribe.
  case unavailable

  /// User hotkey-cancelled during the LID window pass. Caller abstains
  /// without touching session memory.
  ///
  /// Note: cancellation responsiveness is slightly faster than the previous
  /// inline implementation. The old `LanguageDetector.runMultiWindowLID`
  /// caught `CancellationError` thrown from inside `whisperKit.detectLangauge`
  /// in the same try/catch as other errors and continued to the next window
  /// (cancellation only took effect at the next pre-window
  /// `Task.checkCancellation()`). This implementation surfaces inner
  /// cancellation immediately. The downstream classifier behavior is
  /// unchanged (clean abstain, no memory touch).
  case cancelled

  /// Voiced audio insufficient to construct any usable window. Caller
  /// abstains with reason `too_short` (matches today's empty-result branch).
  case noWindows

  /// All attempted windows failed (WhisperKit threw on every one). Caller
  /// abstains with reason `internal_error` and records the abstain in
  /// session memory.
  case error(reason: String)

  /// One or more usable observations. Caller runs the multi-window
  /// classifier (vote-count + mean-prob aggregation, then five-layer
  /// classifier).
  case observations([RawLIDObservation])
}
