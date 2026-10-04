import EnviousWisprCore
import Foundation

/// The words of the AI polish setup reminders (#3438, plan §17 C4 to C6): the menu bar line, the
/// History banner, the sidebar tag, and the short reasons the banner (and later the card) name.
/// One owner, so a reason reads the same on every surface.
enum PolishSetupSurfaceCopy {
  static var menuLine: String {
    String(
      localized: "Finish setting up AI polish",
      comment: "Menu bar menu: opens Settings on AI Polish, whose chosen model is not set up.")
  }

  static var sidebarTag: String {
    String(
      localized: "Set up",
      comment:
        "Settings sidebar: a small tag beside AI Polish when its chosen model is not set up. Keep it very short."
    )
  }

  static var sidebarTagSpoken: String {
    String(
      localized: "Needs setup",
      comment: "Settings sidebar, VoiceOver: AI Polish's chosen model is not set up.")
  }

  /// "AI polish isn't set up: <reason>." The banner owns the final full stop.
  static func banner(reason: String) -> String {
    String(
      localized: "AI polish isn't set up: \(reason).",
      comment:
        "History page banner. %@ is a short reason without a full stop, such as OpenAI needs an API key."
    )
  }

  static var bannerClose: String {
    String(
      localized: "Close the AI polish setup notice",
      comment: "History page banner, VoiceOver and tooltip: the close button.")
  }

  // MARK: - The card after a dictation (plan §17 C3)

  static var cardTitle: String {
    String(
      localized: "Finish setting up AI polish",
      comment:
        "Card after a dictation whose AI polish did not run because its chosen model is not set up: the title."
    )
  }

  /// "<Short reason>. Pasted without AI polish." The reason starts the line, so its first
  /// letter is raised here (the fragments may start lower case after a colon elsewhere).
  static func cardLine(reason: String) -> String {
    let sentence = reason.prefix(1).uppercased() + reason.dropFirst()
    return String(
      localized: "\(sentence). Pasted without AI polish.",
      comment:
        "Card after a dictation: %@ is a short reason without a full stop, such as OpenAI needs an API key."
    )
  }

  static var cardNotNow: String {
    String(
      localized: "Not now",
      comment: "Card after a dictation: closes the card and leaves the setup for later.")
  }

  /// What VoiceOver reads when the card appears.
  static func cardAnnouncement(line: String) -> String {
    "\(cardTitle). \(line)"
  }

  /// The short reason: a fragment, no final punctuation, built from the problem itself (never
  /// from an error message).
  static func shortReason(_ problem: PolishSetupProblem) -> String {
    switch problem {
    case .cloudKeyMissing(let provider):
      return String(
        localized: "\(provider.displayName) needs an API key",
        comment:
          "Short reason, no full stop: a cloud model has no saved API key. %@ is a provider name, such as OpenAI."
      )
    case .cloudKeyRejected(let provider):
      return String(
        localized: "\(provider.displayName) did not accept your API key",
        comment: "Short reason, no full stop. %@ is a provider name, such as OpenAI.")
    case .ollamaNotInstalled:
      return String(
        localized: "Ollama is not installed",
        comment: "Short reason, no full stop. Ollama is a product name; keep it.")
    case .ollamaNotRunning:
      return String(
        localized: "Ollama is not running",
        comment: "Short reason, no full stop. Ollama is a product name; keep it.")
    case .ollamaNoModel:
      return String(
        localized: "Ollama needs a model",
        comment:
          "Short reason, no full stop: no model is chosen or Ollama has no installed models. Ollama is a product name; keep it."
      )
    case .ollamaModelNotInstalled:
      return String(
        localized: "the chosen Ollama model is not downloaded",
        comment:
          "Short reason, no full stop, starts lower case after a colon. Ollama is a product name; keep it."
      )
    case .localEngineNotDownloaded(let provider):
      return String(
        localized: "\(provider.displayName) is not downloaded yet",
        comment: "Short reason, no full stop. %@ is a model name, such as EG-1.")
    case .localEngineDownloadPaused(let provider):
      return String(
        localized: "the \(provider.displayName) download is paused",
        comment:
          "Short reason, no full stop, starts lower case after a colon. %@ is a model name, such as EG-1."
      )
    case .localEngineUpdatePaused(let provider):
      return String(
        localized: "the \(provider.displayName) update is paused",
        comment:
          "Short reason, no full stop, starts lower case after a colon. %@ is a model name, such as EG-1."
      )
    case .localEngineFailed(let provider):
      return String(
        localized: "the \(provider.displayName) download did not finish",
        comment:
          "Short reason, no full stop, starts lower case after a colon. %@ is a model name, such as EG-1."
      )
    case .localEngineDownloading(let provider):
      return String(
        localized: "\(provider.displayName) is still downloading",
        comment: "Short reason, no full stop. %@ is a model name, such as EG-1.")
    case .localEngineVerifying(let provider):
      return String(
        localized: "\(provider.displayName) is being checked",
        comment: "Short reason, no full stop. %@ is a model name, such as EG-1.")
    case .appleUnavailable(let reason):
      if reason == .appleIntelligenceDisabled {
        return String(
          localized: "Apple Intelligence is turned off",
          comment: "Setup notice title when Apple Intelligence is off in System Settings.")
      }
      return String(
        localized: "Apple Intelligence isn't available on this Mac",
        comment: "Short reason, no full stop. Apple Intelligence is a product name.")
    case .appleModelNotReady:
      return String(
        localized: "Apple Intelligence isn't ready yet",
        comment: "AI Polish, notice when leaving the page. Apple Intelligence is a product name.")
    }
  }
}
