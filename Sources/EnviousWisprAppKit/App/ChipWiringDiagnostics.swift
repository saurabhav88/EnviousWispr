import EnviousWisprCore
import Foundation

/// Codex grounded review 2026-05-18 Finding 5: DEBUG-only one-shot warning if
/// the former root state receives a chip event before `attachLanguageSuggestionPresenter` is
/// called. Should not happen in production (AppDelegate's instance-init wires
/// the setter synchronously before the async chip-handler is registered with
/// the LanguageDetector), but a degenerate test harness or future refactor
/// could trip it — the warning makes that visible without runtime cost in
/// production builds.
///
/// Lives in its own file so the former root-state file line count stays bounded under the
/// migration's evolving ceiling.
enum ChipWiringDiagnostics {
  #if DEBUG
    private nonisolated(unsafe) static var didWarn = false

    static func warnIfPresenterMissing(_ presenter: LanguageSuggestionPresenter?) {
      guard presenter == nil else { return }
      guard !didWarn else { return }
      didWarn = true
      // AppLogger is an actor; hop into it asynchronously. One-shot per process
      // so the unstructured Task is bounded.
      Task {
        await AppLogger.shared.log(
          "[ChipWiring] chip event arrived before LanguageSuggestionPresenter was attached "
            + "— chip will not surface for this event (one-shot, DEBUG only)",
          level: .debug,
          category: "ChipWiring"
        )
      }
    }
  #else
    @inline(__always) static func warnIfPresenterMissing(_: LanguageSuggestionPresenter?) {}
  #endif
}
