import EnviousWisprLLM
import EnviousWisprServices
import Foundation

/// Joins the on-device concern split (LLM) to the help check (Services) for #3275. Services does
/// not import LLM and LLM does not import Services, so the translation lives here.
enum HelpCheckWiring {
  /// At launch: the live check on the shared submission, its split prepared before Send (#3739),
  /// and its one terminal usage event. `prepareSplit` is the decomposer's own preparation in the
  /// app.
  @MainActor
  static func install(
    on submission: FeedbackSubmission, settings: SettingsManager,
    prepareSplit: @escaping @Sendable () async -> (any Sendable)? = {
      await HelpConcernDecomposer.prepareSession()
    }
  ) {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    submission.helpCheck = make(appVersion: version)
    submission.prepareSplit = prepareSplit
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

  /// The on-device split as the help check calls it: the message, the session prepared before
  /// Send (#3739), and the callback the split runs when it uses that session.
  typealias Split =
    @Sendable (String, (any Sendable)?, @escaping @Sendable () -> Void) async
    -> HelpConcernDecomposer.Outcome

  /// The live check: Apple's on-device split, then enviouswispr.com. `split` is the decomposer
  /// itself in the app; the prepared session and the callback pass through unchanged.
  static func make(
    appVersion: String,
    split: @escaping Split = { message, prepared, onConsumed in
      await HelpConcernDecomposer.decompose(message, prepared: prepared, onConsumed: onConsumed)
    }
  ) -> HelpCheck {
    HelpCheck(
      decompose: { message, prepared, onConsumed in
        decomposition(await split(message, prepared, onConsumed))
      },
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
