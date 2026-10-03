import EnviousWisprServices
import Foundation
import Observation

/// The "Include diagnostics" state of the Send Feedback form (#3269). The box is the user's
/// consent for this one report: it starts at the "Share usage metrics" switch each time the form
/// opens, is never remembered, and resets if that switch changes while the form is open. A
/// ticked report sends exactly the snapshot the preview shows; an unticked one sends none.
@MainActor
@Observable
final class FeedbackFormModel {
  enum Diagnostics: Equatable {
    case loading
    case ready(FeedbackDiagnosticsSnapshot)
    case unavailable
  }

  /// What Send should do with the current state.
  enum SendDecision: Equatable {
    /// Send, with this attachment (nil for none).
    case send(FeedbackDiagnosticsSnapshot?)
    /// Do not send: the metrics switch changed under the form and the user has to look again.
    case metricsChanged
    /// Do not send yet: the box is ticked and its snapshot is still loading.
    case waitingForDiagnostics
  }

  private(set) var includeDiagnostics = false
  private(set) var diagnostics: Diagnostics = .loading
  /// The metrics value the current consent default came from.
  private(set) var metricsDefault = false

  private let loadSnapshot: @MainActor () async -> FeedbackDiagnosticsSnapshot?
  /// Bumped on every open, metrics change and form close; a load that finishes under an older value
  /// is dropped, so a slow load can never bring back old bytes or an old choice.
  private var generation = 0
  private(set) var loadTask: Task<Void, Never>?

  init(loadSnapshot: @escaping @MainActor () async -> FeedbackDiagnosticsSnapshot?) {
    self.loadSnapshot = loadSnapshot
  }

  /// The form opened: default the box from the switch and load a fresh snapshot.
  func open(usageMetrics: Bool) {
    reset(usageMetrics: usageMetrics)
  }

  /// The metrics switch changed while the form is open: drop the choice and the snapshot.
  func usageMetricsChanged(to usageMetrics: Bool) {
    reset(usageMetrics: usageMetrics)
  }

  /// The form went away: nothing pending may land afterwards. Named for the form, not "close",
  /// because `OverlayRetainedWindowTests` reads any close call in this module as a window close.
  func formDidClose() {
    generation += 1
    loadTask?.cancel()
    loadTask = nil
  }

  /// The user's click on the box. Ignored while no snapshot is available.
  func setIncludeDiagnostics(_ include: Bool) {
    guard diagnostics != .unavailable else { return }
    includeDiagnostics = include
  }

  /// The snapshot the preview shows: only when the box is ticked and the bytes are ready.
  var previewSnapshot: FeedbackDiagnosticsSnapshot? {
    guard includeDiagnostics, case .ready(let snapshot) = diagnostics else { return nil }
    return snapshot
  }

  /// A ticked box waits for its snapshot; an unticked report never does.
  var isWaitingForDiagnostics: Bool {
    includeDiagnostics && diagnostics == .loading
  }

  /// Rechecks the live switch at the click. A change the observer has not delivered yet resets
  /// the form instead of sending, so the user never sends a file they did not see.
  func decideSend(currentUsageMetrics: Bool) -> SendDecision {
    guard currentUsageMetrics == metricsDefault else {
      reset(usageMetrics: currentUsageMetrics)
      return .metricsChanged
    }
    guard !isWaitingForDiagnostics else { return .waitingForDiagnostics }
    return .send(includeDiagnostics ? previewSnapshot : nil)
  }

  private func reset(usageMetrics: Bool) {
    generation += 1
    loadTask?.cancel()
    metricsDefault = usageMetrics
    includeDiagnostics = usageMetrics
    diagnostics = .loading
    let expected = generation
    loadTask = Task { @MainActor [weak self, loadSnapshot] in
      let snapshot = await loadSnapshot()
      guard let self, self.generation == expected else { return }
      if let snapshot {
        self.diagnostics = .ready(snapshot)
      } else {
        self.diagnostics = .unavailable
        self.includeDiagnostics = false
      }
    }
  }
}
