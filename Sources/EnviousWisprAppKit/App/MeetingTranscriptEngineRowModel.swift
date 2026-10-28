import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// #3973 C3 (decision 19): EnviousMeet > Models' Transcript engine row. Parakeet or Whisper
/// Large v3 Turbo; Whisper is selectable only while its model is ready, and its Download,
/// Resume and Cancel are the shared Whisper delivery's (one model for dictation and meetings,
/// never a second download). Owns the transcript language list too, which follows the engine.
@MainActor
@Observable
final class MeetingTranscriptEngineRowModel {
  struct Environment {
    let settings: SettingsManager
    /// The shared Whisper setup (`WhisperSetupService`): its state, Download and Cancel.
    let whisperSetup: WhisperSetupService
    /// A meeting records or processes (`MeetingCoordinator.isMeetingActive`).
    let isMeetingActive: @MainActor () -> Bool
  }

  @ObservationIgnored private let environment: Environment

  init(environment: Environment) {
    self.environment = environment
  }

  var selectedEngine: MeetingEngineChoice { environment.settings.meetingTranscriptEngine }

  var whisperState: WhisperSetupState { environment.whisperSetup.setupState }

  var isWhisperReady: Bool { whisperState == .ready }

  /// Refreshes the Whisper state when the row appears.
  func appear() async {
    await environment.whisperSetup.detectState()
  }

  /// Saves `engine`. Whisper is saved only when its model is ready now (checked again, not the
  /// row's cached state); Parakeet always.
  func select(_ engine: MeetingEngineChoice) async {
    if engine == .whisper {
      await environment.whisperSetup.forceDetectState()
      guard isWhisperReady else { return }
    }
    environment.settings.meetingTranscriptEngine = engine
  }

  /// Why Download cannot start now, or nil (`MeetingDownloadAdmission`).
  var downloadRefusal: String? {
    MeetingDownloadAdmission.canStart(meetingActive: environment.isMeetingActive())
      ? nil : MeetingDownloadAdmission.refusal
  }

  /// Download or Resume. Refused while a meeting records or processes, in the same step.
  func download() {
    guard MeetingDownloadAdmission.canStart(meetingActive: environment.isMeetingActive()) else {
      return
    }
    environment.whisperSetup.downloadModel()
  }

  func cancelDownload() {
    environment.whisperSetup.cancelDownload()
  }

  /// Whisper is chosen but its model is no longer ready: meetings fall back to Parakeet.
  var isChosenWhisperGone: Bool {
    guard selectedEngine == .whisper else { return false }
    switch whisperState {
    case .notDownloaded, .paused, .error: return true
    case .checking, .downloading, .ready: return false
    }
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
