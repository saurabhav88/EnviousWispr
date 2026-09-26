import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprModelDelivery
import Foundation

/// The bundled local engines that have a learned-word checker (#3105). One
/// table for delivery (manifest, folder, host prefix), eligibility and the
/// Debug adapter door, so the two engines cannot drift apart. Exhaustive: an
/// engine added here must state every row.
enum LearnedWordCheckerEngine: CaseIterable, Sendable {
  case egOne, s1Mini

  init?(provider: LLMProvider) {
    switch provider {
    case .egOne: self = .egOne
    case .s1Mini: self = .s1Mini
    case .openAI, .gemini, .claude, .ollama, .appleIntelligence, .none: return nil
    }
  }

  var provider: LLMProvider {
    switch self {
    case .egOne: .egOne
    case .s1Mini: .s1Mini
    }
  }

  var checkerFamily: ModelFamily {
    switch self {
    case .egOne: .egOneChecker
    case .s1Mini: .s1MiniChecker
    }
  }

  /// The bundled, signed delivery manifest (`Project.swift` lists each one).
  var manifestResource: String {
    switch self {
    case .egOne: "eg1-checker-delivery-manifest"
    case .s1Mini: "s1-checker-delivery-manifest"
    }
  }

  /// Beside the base's own folder under `Application Support/EnviousWispr`.
  var installFolder: String {
    switch self {
    case .egOne: "Models/eg-1-checker"
    case .s1Mini: "Models/s1-mini-checker"
    }
  }

  /// The R2 custom domain's prefix the base model already downloads from.
  var hostPathPrefix: String {
    switch self {
    case .egOne: "/eg1/"
    case .s1Mini: "/s1/"
    }
  }

  func promptStyle(language: String?) -> EGOneLearnedWordChecker.PromptStyle {
    switch self {
    case .egOne: .egOne
    case .s1Mini: .s1Mini(language: language)
    }
  }
}
