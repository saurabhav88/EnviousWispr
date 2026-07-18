import Foundation

/// Navigation state for the Custom Words import sheet (#1657, epic #1619 PR-F1).
///
/// The shell every import source plugs into: it owns only which screen the
/// sheet shows and which method the user picked. No source adapters, no
/// compare logic, no persistence, no telemetry — those arrive in later PRs
/// (F2a compare, F2b commit, F2c review UI, then the real sources), which
/// drive `showReview()` / `beginWork(_:)` / `showResult(_:)` from real work.
/// In F1 those transitions are exercised by tests and the DEBUG-only
/// "Preview import" fixture walk.
///
/// Invariant: `selectedMethod` is non-nil exactly while a method's flow is
/// active; returning to `.methodPicker` (via `goBack()` or `reset()`) clears it.
@MainActor @Observable
final class CustomWordsImportFlowModel {
  enum Step: Equatable {
    case methodPicker
    case paste
    case upload
    case smartImportAppPicker
    case review
    case working(Work)
    case result(Result)
  }

  enum Work: Equatable {
    case loadingCandidates
    case comparing
    case committing
  }

  enum Result: Equatable {
    case completed(added: Int, replaced: Int)
    case nothingFound
    case failed(message: String)
  }

  enum Method: String, CaseIterable, Identifiable, Sendable {
    case paste
    case upload
    case smartImport

    var id: Self { self }

    /// The input screen this method starts on.
    var inputStep: Step {
      switch self {
      case .paste: return .paste
      case .upload: return .upload
      case .smartImport: return .smartImportAppPicker
      }
    }
  }

  private(set) var step: Step = .methodPicker
  private(set) var selectedMethod: Method?

  /// True exactly where `goBack()` does something — the three input screens
  /// and review. The sheet's Back button reads this instead of keeping its
  /// own copy of the per-screen table.
  var canGoBack: Bool {
    switch step {
    case .paste, .upload, .smartImportAppPicker, .review: return true
    case .methodPicker, .working, .result: return false
    }
  }

  /// Method picker → the picked method's input screen. Ignored anywhere else:
  /// picking a method is only meaningful on the picker.
  func select(_ method: Method) {
    guard step == .methodPicker else { return }
    selectedMethod = method
    step = method.inputStep
  }

  /// An input screen or an in-flight working step → review. Ignored until a
  /// method is selected, so `.review` can always answer "back to where?".
  func showReview() {
    guard selectedMethod != nil else { return }
    switch step {
    case .paste, .upload, .smartImportAppPicker, .working:
      step = .review
    case .methodPicker, .review, .result:
      break
    }
  }

  /// An input screen, review, or another working phase → `.working(work)`.
  /// Ignored on the picker (no method context) and on a result (terminal).
  func beginWork(_ work: Work) {
    switch step {
    case .paste, .upload, .smartImportAppPicker, .review, .working:
      step = .working(work)
    case .methodPicker, .result:
      break
    }
  }

  /// A working step → its terminal result. Results only ever come out of
  /// work, so this is ignored on every other screen.
  func showResult(_ result: Result) {
    guard case .working = step else { return }
    step = .result(result)
  }

  /// Explicit per-screen table (adopted plan, PR-F1):
  /// input screens → `.methodPicker`; `.review` → the selected method's input
  /// screen; `.working` → no-op (Back is disabled); `.result` → no-op (no
  /// Back, Done dismisses); `.methodPicker` → no-op.
  func goBack() {
    switch step {
    case .paste, .upload, .smartImportAppPicker:
      selectedMethod = nil
      step = .methodPicker
    case .review:
      // `showReview()` guarantees a selected method, but stay deterministic
      // rather than trap if a future caller breaks that assumption.
      step = selectedMethod?.inputStep ?? .methodPicker
    case .methodPicker, .working, .result:
      break
    }
  }

  /// Fresh model state: back to the picker with no method selected.
  func reset() {
    selectedMethod = nil
    step = .methodPicker
  }
}
