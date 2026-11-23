import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// #3973 C3 (decision 19): EnviousMeet > Models' Transcript engine row. Parakeet or Whisper
/// Large v3 Turbo, either selectable downloaded or not (#4578); each card's status line is the
/// shared `SpeechEngineStatusRow` (one model per engine for dictation and meetings, never a
/// second download). Owns the transcript language list too, which follows the engine.
@MainActor
@Observable
final class MeetingTranscriptEngineRowModel {
  struct Environment {
    let settings: SettingsManager
    /// The shared Whisper setup (`WhisperSetupService`): its state, Download and Cancel.
    let whisperSetup: WhisperSetupService
  }

  @ObservationIgnored private let environment: Environment

  init(environment: Environment) {
    self.environment = environment
  }

  var selectedEngine: MeetingEngineChoice { environment.settings.meetingTranscriptEngine }

  /// Refreshes the Whisper state when the row appears (the shared status line reads it).
  func appear() async {
    await environment.whisperSetup.detectState()
  }

  /// #4578: saves `engine`, downloaded or not (the uniform rule of both Settings tabs). A
  /// missing engine's card says Set up model, and a meeting uses the other downloaded engine
  /// until it is back.
  func select(_ engine: MeetingEngineChoice) {
    environment.settings.meetingTranscriptEngine = engine
  }

  /// The warning when meetings and dictation use different engines (decisions 8 and 10), unless
  /// dictation is already turned off during meetings. Nil when they match.
  var engineMismatch: MeetingEngineChoice? {
    let settings = environment.settings
    guard !settings.meetingTurnsOffDictation,
      selectedEngine.backendType != settings.selectedBackend
    else { return nil }
    return selectedEngine
  }

  // MARK: - Transcript language

  /// The chosen engine's lockable languages (`LanguageLockOptions`); Auto is offered beside
  /// these. No English (UK): it is dictation's British spelling choice, not a language.
  var transcriptLanguageOptions: [LanguageCatalog.Entry] {
    LanguageLockOptions.pickerRows(
      lockableCodes: LanguageLockOptions.lockableCodes(for: selectedEngine.backendType),
      query: "", offersEnglishUK: false)
  }

  /// The locked transcript language when the chosen engine cannot decode it (a new meeting then
  /// runs with Auto), or nil.
  var unsupportedTranscriptLanguage: String? {
    guard case .locked(let code) = environment.settings.meetingLanguageMode,
      !MeetingWiring.engineSupports(selectedEngine, code)
    else { return nil }
    return code
  }
}
