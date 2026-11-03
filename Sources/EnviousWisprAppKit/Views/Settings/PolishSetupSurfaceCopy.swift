import EnviousWisprCore
import EnviousWisprLLM
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
        return AppleIntelligenceSetupCopy.current.title
      }
      return String(
        localized: "Apple Intelligence isn't available on this Mac",
        comment: "Short reason, no full stop. Apple Intelligence is a product name.")
    case .appleModelNotReady:
      return String(
        localized: "Apple Intelligence isn't ready yet",
        comment: "AI Polish, notice when leaving the page. Apple Intelligence is a product name.")
    case .cloudNoModel(let provider):
      return String(
        localized: "\(provider.displayName) needs a model",
        comment:
          "Short reason, no full stop: a cloud AI provider is chosen but no model is. %@ is a provider name, such as OpenAI."
      )
    case .cloudModelUnavailable(_, let model):
      return String(
        localized: "\(model) no longer works",
        comment:
          "Short reason, no full stop: the chosen cloud AI model stopped working. %@ is a model id, such as gpt-4o-mini; keep it as is."
      )
    case .localEngineStoppedOutside(let provider, _):
      // Never shown by the setup surfaces (#3988 keeps this problem off them); here so the
      // switch stays exhaustive and any defensive reader gets true words.
      return String(
        localized: "\(provider.displayName) stopped and starts again on your next dictation",
        comment:
          "Short reason, no full stop: a local AI model was stopped outside the app and restarts on the next dictation. %@ is a model name, such as EG-1."
      )
    }
  }

  // MARK: - A cloud model to choose (#4353 D4, founder decision 4)

  /// The card's title for a cloud provider with no model.
  static func chooseModelTitle(_ provider: LLMProvider) -> String {
    String(
      localized: "Choose a model for \(provider.displayName).",
      comment:
        "Card after a dictation, title: a cloud AI provider is chosen but no model is. %@ is a provider name, such as OpenAI."
    )
  }

  /// The card's title for a chosen cloud model that stopped working.
  static func modelNoLongerWorksTitle(_ model: String) -> String {
    String(
      localized: "\(model) no longer works.",
      comment:
        "Card after a dictation, title: the chosen cloud AI model stopped working. %@ is a model id, such as gpt-4o-mini; keep it as is."
    )
  }

  /// The one sentence a surface shows outside the card: what broke and what to do.
  static func modelNoLongerWorksNotice(_ model: String) -> String {
    CloudModelNoticeCopy.noLongerWorks(model)
  }

  /// The button that opens that screen's model menu.
  static var selectNewCloudModel: String {
    String(
      localized: "Select a new cloud model",
      comment: "Button: opens AI Polish with the model menu open, to pick another cloud AI model.")
  }

  /// The model field when nothing is chosen.
  static var chooseAModel: String {
    String(
      localized: "Choose a model",
      comment: "AI Polish model menu, closed: no cloud model is chosen yet.")
  }

  /// Under the model row after a key is saved and no model is chosen yet.
  static var chooseModelGuidance: String {
    String(
      localized: "Choose a model to turn on AI Polish. Dictation still works until you do.",
      comment:
        "AI Polish, under the model menu after an API key is saved and no model is chosen. AI Polish names a feature."
    )
  }

  /// Under the model row when live discovery confirmed the chosen model unavailable.
  static func modelUnavailableWithKey(_ model: String) -> String {
    String(
      localized: "\(model) is no longer available with your key. Choose another.",
      comment:
        "AI Polish, under the model menu: the chosen cloud AI model is not available for the saved API key. %@ is a model id, such as gpt-4o-mini; keep it as is."
    )
  }

  /// The leave pop-up's reason for a cloud provider with no model.
  static func chooseProviderModel(_ provider: LLMProvider, _ scope: PolishSetupScope) -> String {
    switch scope {
    case .dictation:
      return String(
        localized: "Choose a \(provider.displayName) model to use AI polish.",
        comment: "AI Polish, leave pop-up reason. %@ is a provider name, such as OpenAI.")
    case .meetingSummary:
      return String(
        localized: "Choose a \(provider.displayName) model to write meeting summaries.",
        comment: "Meeting summaries, leave pop-up reason. %@ is a provider name, such as OpenAI.")
    }
  }

  // MARK: - A local model stopped outside the app (#3988)

  /// The first notice's title: what happened to the dictation, in plain words. No engine
  /// name; that is kept for the repeat notice.
  static var outsideStopTitle: String {
    String(
      localized: "AI polish skipped",
      comment:
        "Notice after a dictation, title: the local AI model was stopped outside the app, so this dictation was pasted without AI polish."
    )
  }

  /// The repeat notice's body (#3988, founder-approved 2026-10-23): it names the engine, keeps
  /// the memory sentence to warning or critical, suggests no particular engine, and says the
  /// notice is now quiet for 24 hours.
  static func outsideStopEscalation(_ stop: OutsideStopContext) -> String {
    let engine = stop.provider.displayName
    switch stop.memoryPressure {
    case .warning?, .critical?:
      return String(
        localized:
          "\(engine) stopped again. Your Mac was low on memory at the time. A lighter polish engine, or turning polish off, may work better on this Mac. We won't show this again for 24 hours.",
        comment:
          "Notice after a dictation, when the local AI model was stopped outside the app again within a day, while memory was low. %@ is a model name, such as EG-1."
      )
    case .normal?, nil:
      return String(
        localized:
          "\(engine) stopped again. A lighter polish engine, or turning polish off, may work better on this Mac. We won't show this again for 24 hours.",
        comment:
          "Notice after a dictation, when the local AI model was stopped outside the app again within a day. %@ is a model name, such as EG-1."
      )
    }
  }

  /// The repeat notice's button: opens AI Polish, where the person picks an engine.
  static var chooseEngine: String {
    String(
      localized: "Choose engine",
      comment: "Notice after a dictation, button: opens AI Polish settings to pick another engine."
    )
  }

  /// The one owner of the stopped-from-outside notice body. The memory sentence appears only
  /// when the app saw warning or critical memory pressure as it handled the stop: context,
  /// never a claimed cause, and never shown when the level is normal or unknown.
  static func outsideStopNotice(_ stop: OutsideStopContext) -> String {
    switch stop.memoryPressure {
    case .warning?, .critical?:
      return String(
        localized:
          "This dictation was pasted without AI polish. Your Mac was low on memory at the time. We'll try again automatically.",
        comment:
          "Notice after a dictation: the local AI model was stopped outside the app while memory was low, so this dictation was not polished. The app restarts the model by itself."
      )
    case .normal?, nil:
      return String(
        localized: "This dictation was pasted without AI polish. We'll try again automatically.",
        comment:
          "Notice after a dictation: the local AI model was stopped outside the app, so this dictation was not polished. The app restarts the model by itself."
      )
    }
  }
}
