import EnviousWisprLLM
import EnviousWisprServices
import Foundation

/// Joins the on-device concern split (LLM) to the help check (Services) for #3275. Services does
/// not import LLM and LLM does not import Services, so the translation lives here.
enum HelpCheckWiring {
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
