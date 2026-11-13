import EnviousWisprCore
import Foundation
import Observation
import SwiftUI

/// Speech pick/Compare's facts and choice rules (#4528 D2, plan M76). Every fact comes from an
/// existing owner: the flow's recommendation, `LanguageLockOptions` for language support and
/// `EngineChoicePresentation` for names, coverage, times and download sizes.
enum SetupSpeech {
  static let engines: [ASRBackendType] = [.parakeet, .whisper]

  /// Whether `engine` can dictate `language` (nil or Auto: both can).
  static func supports(_ engine: ASRBackendType, _ language: LanguageMode?) -> Bool {
    guard case .locked(let code)? = language,
      let codes = LanguageLockOptions.lockableCodes(for: engine)
    else { return true }
    let base = code.split(separator: "-").first.map(String.init) ?? code
    return codes.contains(base)
  }

  /// The engine the screen shows and "Use <model>" commits: the pending pick, else a compatible
  /// committed pick, else the recommendation, never an engine the language rules out.
  static func displayed(
    draft: ASRBackendType?, committed: ASRBackendType?, recommended: ASRBackendType,
    language: LanguageMode?
  ) -> ASRBackendType {
    for candidate in [draft, committed, recommended] {
      if let candidate, supports(candidate, language) { return candidate }
    }
    return engines.first { supports($0, language) } ?? .whisper
  }

  /// The model name a person sees: the Parakeet model this Mac presents, or Whisper.
  static func name(_ engine: ASRBackendType, parakeetModel: String) -> String {
    switch engine {
    case .parakeet: parakeetModel
    case .whisper: "Whisper"
    }
  }

  static func presentation(_ engine: ASRBackendType, parakeetModel: String)
    -> EngineChoicePresentation.Choice
  {
    EngineChoicePresentation.choice(for: engine, parakeetModel: parakeetModel)
  }

  /// The download size for the model the card names (manifest-pinned in EngineChoicePresentation).
  static func downloadBytes(_ engine: ASRBackendType, parakeetModel: String) -> Int64 {
    switch engine {
    case .parakeet: EngineChoicePresentation.fastDownloadBytes(parakeetModel: parakeetModel)
    case .whisper: EngineChoicePresentation.whisperDownloadBytes
    }
  }

  /// The chosen language's name in the interface language, or nil under Auto or before a pick.
  static func languageName(_ language: LanguageMode?) -> String? {
    guard case .locked(let code)? = language else { return nil }
    return LanguageCatalog.entry(for: code).displayName
  }

  /// Whisper's cycling greeting (mockup `worldGreets`): the language's own hello first, then a
  /// fixed tour of languages, each once.
  static func worldGreetings(for language: LanguageMode?) -> [SetupLanguage.Greeting] {
    var codes: [String] = []
    if case .locked(let code)? = language { codes.append(code) }
    codes += ["en", "ja", "hi", "es", "ar", "ko", "fr"].filter { !codes.contains($0) }
    return codes.compactMap(SetupLanguage.greeting(for:))
  }

  /// Seconds each world greeting stays (mockup `startModelTicker`).
  static let worldGreetingSeconds: Double = 1.4
}

/// Whisper's greeting tour on the speech screens: which greeting shows, advanced every
/// `interval` while the task runs. The screen restarts `run` whenever the engine or Reduce Motion
/// changes (its task id), so turning Reduce Motion on stops the tour and turning it off restarts it
/// on the same mounted screen.
@MainActor
@Observable
final class SetupGreetingTour {
  private(set) var index = 0
  @ObservationIgnored let interval: Duration

  init(interval: Duration = .seconds(SetupSpeech.worldGreetingSeconds)) {
    self.interval = interval
  }

  /// Shows the first greeting, then (Whisper, motion allowed) advances until cancelled.
  func run(engine: ASRBackendType, reduceMotion: Bool) async {
    index = 0
    guard engine == .whisper, !reduceMotion else { return }
    while !Task.isCancelled {
      try? await Task.sleep(for: interval)
      guard !Task.isCancelled else { return }
      index += 1  // mockup: the text swaps in place; only the bubble's first appearance fades
    }
  }
}
