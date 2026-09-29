import EnviousWisprLLM
import EnviousWisprServices
import Foundation

/// Joins the on-device concern split (LLM) to the help check (Services) for #3275. Services does
/// not import LLM and LLM does not import Services, so the translation lives here.
enum HelpCheckWiring {
  /// At launch: the live check on the shared submission, and its one terminal usage event.
  @MainActor
  static func install(on submission: FeedbackSubmission, settings: SettingsManager) {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    submission.helpCheck = make(appVersion: version)
    submission.onHelpTerminal = terminalSink(
      usageMetrics: { settings.shareUsageMetrics },
      emit: { TelemetryService.shared.helpCheckTerminal($0) })
  }

  /// The terminal event's gate: "Share usage metrics" is read when the check ENDS, so a switch
  /// turned off while a check runs sends nothing. The report itself never depends on it.
  @MainActor
  static func terminalSink(
    usageMetrics: @escaping @MainActor () -> Bool,
    emit: @escaping @MainActor (HelpCheckTerminal) -> Void
  ) -> @MainActor (HelpCheckTerminal) -> Void {
    { terminal in
      guard usageMetrics() else { return }
      emit(terminal)
    }
  }

  /// The live check: Apple's on-device split, then enviouswispr.com.
  static func make(appVersion: String) -> HelpCheck {
    HelpCheck(
      decompose: { message in decomposition(await HelpConcernDecomposer.decompose(message)) },
      decompositionVersion: HelpConcernDecomposer.version, appVersion: appVersion)
  }

  /// Maps the split's outcome to the check's input. A concern with an unknown kind is kept as
  /// `other`: dropping it could hide a concern.
  static func decomposition(_ outcome: HelpConcernDecomposer.Outcome) -> HelpCheckDecomposition {
    switch outcome {
    case .concerns(let concerns, let hitCap):
      return .concerns(
        concerns.map {
          HelpCheckConcern(
            summary: $0.summary, evidence: $0.evidence,
            kind: HelpCheckConcern.Kind(rawValue: $0.kind) ?? .other)
        }, hitCap: hitCap)
    case .failed(let failure):
      switch failure {
      case .unavailable, .unsupportedLanguage, .tooLong: return .unavailable(.afmUnavailable)
      case .refused: return .unavailable(.afmRefused)
      case .error: return .unavailable(.afmError)
      }
    }
  }
}
