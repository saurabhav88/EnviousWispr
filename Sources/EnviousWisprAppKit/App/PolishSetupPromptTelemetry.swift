import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation

// MARK: - `polish_setup.prompt` (#3438 M2)

/// What a warning was about when it was shown: its problem and the provider that had it, taken
/// together at that moment. A surface keeps this and reports with it, so a row stays true when
/// the person changes model or finishes the setup before pressing a button.
struct PolishSetupPromptSubject: Hashable {
  let problem: PolishSetupProblem
  let provider: LLMProvider
}

/// One row of `polish_setup.prompt`: a setup warning was shown, or a person pressed one of its
/// buttons. Closed values only, so the row can never carry a key, a model name or any text.
struct PolishSetupPromptEvent: Equatable {
  /// The surfaces that report. The sidebar tag is not a prompt and has no button.
  enum Surface: String, CaseIterable {
    case leaveDialog = "leave_dialog"
    case card
    case banner
    case menu
  }

  enum Action: String, CaseIterable {
    case shown
    case finishSetup = "finish_setup"
    case goBack = "go_back"
    case leaveAnyway = "leave_anyway"
    case notNow = "not_now"
    case closed
    case openSystemSettings = "open_system_settings"
    case ok
  }

  let surface: Surface
  let action: Action
  let subject: PolishSetupPromptSubject
  /// Card rows only: the take whose skipped polish raised the card.
  let takeID: UUID?

  private var problem: PolishSetupProblem { subject.problem }
  private var provider: LLMProvider { subject.provider }

  /// Sends the row to PostHog and leaves the same content-free trail in Sentry.
  @MainActor func send() {
    TelemetryService.shared.polishSetupPrompt(
      surface: surface.rawValue, action: action.rawValue, problem: problem.telemetryTag,
      provider: provider.rawValue, takeID: takeID?.uuidString)
    SentryBreadcrumb.add(
      stage: "polish_setup",
      message: "prompt_\(action.rawValue)",
      data: [
        "surface": surface.rawValue, "problem": problem.telemetryTag,
        "provider": provider.rawValue,
      ])
  }
}

extension PolishSetupProblem {
  /// The closed `problem` value. The provider travels in its own field, so a tag names only
  /// the kind of problem. Exhaustive, so a new problem cannot ship without a tag.
  var telemetryTag: String {
    switch self {
    case .cloudKeyMissing: return "cloud_key_missing"
    case .cloudKeyRejected: return "cloud_key_rejected"
    case .ollamaNotInstalled: return "ollama_not_installed"
    case .ollamaNotRunning: return "ollama_not_running"
    case .ollamaNoModel: return "ollama_no_model"
    case .ollamaModelNotInstalled: return "ollama_model_not_installed"
    case .localEngineNotDownloaded: return "local_not_downloaded"
    case .localEngineDownloadPaused: return "local_download_paused"
    case .localEngineUpdatePaused: return "local_update_paused"
    case .localEngineFailed: return "local_download_failed"
    case .localEngineDownloading: return "local_downloading"
    case .localEngineVerifying: return "local_verifying"
    case .appleUnavailable(let reason):
      return reason == .appleIntelligenceDisabled ? "apple_turned_off" : "apple_unavailable"
    case .appleModelNotReady: return "apple_not_ready"
    }
  }
}

extension PolishSetupLeaveAction {
  /// The leave dialog's button, as reported. "Go back to" reports no provider of its own: the
  /// row's provider is the one being left.
  var promptAction: PolishSetupPromptEvent.Action {
    switch self {
    case .finishSetup: return .finishSetup
    case .goBack: return .goBack
    case .leaveAnyway: return .leaveAnyway
    case .ok: return .ok
    case .openSystemSettings: return .openSystemSettings
    }
  }
}
