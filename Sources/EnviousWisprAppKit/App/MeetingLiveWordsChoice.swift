import EnviousWisprCore
import EnviousWisprLivePreview
import EnviousWisprServices
import Foundation

/// Which engine and language EnviousMeet's live words use (#4105, decisions file item 18), and the
/// one place that decides it. The Live words row, meeting Start and the DEBUG door all read this.
///
/// Rules the founder set: meetings never use Apple's dictation module; the engines are Apple's
/// meeting module (`SpeechTranscriber`) or Universal; a stored choice is the user's and is never
/// silently swapped for another engine or language; nothing downloads by itself. With nothing
/// stored, the dictation language is the guess, and an engine already installed for it is
/// pre-selected (Apple first, then Universal). A guess is saved only once it is ready, by
/// `Initializer`, and after that dictation's language is never consulted again.
enum MeetingLiveWordsChoice {

  /// What this Mac has, read by the caller and handed in, so the policy stays pure.
  struct Inventory: Sendable, Equatable {
    /// Apple's meeting module can run here: macOS 26 and `SpeechTranscriber.isAvailable`.
    var appleAvailable: Bool
    /// Exact BCP-47 tags the meeting module supports, and those installed (runtime lists).
    var appleSupportedTags: [String]
    var appleInstalledTags: [String]
    /// The Universal model is downloaded.
    var universalInstalled: Bool
    /// The base language codes Universal transcribes (`LanguageCatalog`).
    var universalCodes: Set<String>
  }

  /// The outcome a caller acts on. `language` is what the engine would run in; for a choice that
  /// is not stored yet it is the guess.
  enum Resolution: Equatable, Sendable {
    /// Ready to run now.
    case ready(engine: LivePreviewEngineChoice, language: String)
    /// Chosen and supported, but its model is not on this Mac: the row offers Download.
    case notDownloaded(engine: LivePreviewEngineChoice, language: String)
    /// Nothing usable is chosen. `suggestion` is the engine and language the row pre-selects,
    /// when one exists; nothing is downloaded or stored for it.
    case notSetUp(suggestion: Suggestion?)
  }

  struct Suggestion: Equatable, Sendable {
    let engine: LivePreviewEngineChoice
    let language: String
  }

  /// The base language of a tag or code: `en-US` and `en` are both `en`.
  static func baseCode(_ tag: String) -> String {
    Locale(identifier: tag).language.languageCode?.identifier.lowercased() ?? tag.lowercased()
  }

  // MARK: - Resolution

  /// The choice for these stored values. `guess` is dictation's language (Auto means the Mac's
  /// language); it fills only what is not stored and is never written here.
  /// `appleEquivalent` is Apple's own regional equivalence for the meeting module
  /// (`SpeechTranscriber.supportedLocale(equivalentTo:)`), returning an exact tag or nil.
  static func resolve(
    engine storedEngine: LivePreviewEngineChoice?, language storedLanguage: String?,
    guess: LanguageMode, inventory: Inventory,
    appleEquivalent: @Sendable (String) async -> String?
  ) async -> Resolution {
    switch (storedEngine, storedLanguage) {
    case (let engine?, let language?):
      // An explicit choice: exact, never swapped.
      return explicit(engine: engine, language: language, inventory: inventory)
    case (_?, nil):
      // Engine chosen, language not (a switch cleared one the new engine lacks): not set up
      // until the user picks one. Running a guessed language here would show "Choose a
      // language" while meetings used another (second-pass review #4105).
      return .notSetUp(suggestion: nil)
    case (nil, let language?):
      // Language chosen, engine not: the first engine that has it, Apple first.
      return await firstEngine(
        for: language, exact: true, inventory: inventory, appleEquivalent: appleEquivalent)
    case (nil, nil):
      return await firstEngine(
        for: guessCode(guess), exact: false, inventory: inventory,
        appleEquivalent: appleEquivalent)
    }
  }

  /// A stored engine and language as they stand: ready, waiting for a download, or not set up
  /// when the engine cannot run here or does not have that language.
  static func explicit(
    engine: LivePreviewEngineChoice, language: String, inventory: Inventory
  ) -> Resolution {
    switch engine {
    case .apple:
      guard inventory.appleAvailable, inventory.appleSupportedTags.contains(language) else {
        return .notSetUp(suggestion: nil)
      }
      return inventory.appleInstalledTags.contains(language)
        ? .ready(engine: .apple, language: language)
        : .notDownloaded(engine: .apple, language: language)
    case .universal:
      let code = baseCode(language)
      guard inventory.universalCodes.contains(code) else { return .notSetUp(suggestion: nil) }
      return inventory.universalInstalled
        ? .ready(engine: .universal, language: code)
        : .notDownloaded(engine: .universal, language: code)
    }
  }

  /// The language `engine` would use for `code`, or nil when it has none. The policy for both
  /// guessing and switching engines (plan R2.2):
  /// - Apple, from a bare language or another engine's code: an installed region first, chosen
  ///   by `satisfyingTag` (stable: the same inventory gives the same tag), else Apple's equivalent
  ///   supported tag as the download target.
  /// - Apple, from an exact tag Apple supports: that tag, unchanged.
  /// - Universal: the base code, when Universal has it.
  static func language(
    for engine: LivePreviewEngineChoice, from code: String, inventory: Inventory,
    appleEquivalent: @Sendable (String) async -> String?
  ) async -> String? {
    switch engine {
    case .apple:
      guard inventory.appleAvailable else { return nil }
      if Locale(identifier: code).region != nil, inventory.appleSupportedTags.contains(code) {
        return code
      }
      let base = baseCode(code)
      let resolved = await appleEquivalent(base)
      if let installed = ApplePreviewEngineResolver.satisfyingTag(
        requestedCode: base, resolvedTag: resolved ?? base,
        installedTags: inventory.appleInstalledTags)
      {
        return installed
      }
      guard let resolved, inventory.appleSupportedTags.contains(resolved) else { return nil }
      return resolved
    case .universal:
      let base = baseCode(code)
      return inventory.universalCodes.contains(base) ? base : nil
    }
  }

  /// The language to keep when the user switches the row to `engine`, or nil to clear it. The
  /// same policy as guessing, from the current language.
  static func switchedLanguage(
    to engine: LivePreviewEngineChoice, from current: String?, inventory: Inventory,
    appleEquivalent: @Sendable (String) async -> String?
  ) async -> String? {
    guard let current else { return nil }
    return await language(
      for: engine, from: baseCode(current), inventory: inventory, appleEquivalent: appleEquivalent)
  }

  /// The first engine, Apple then Universal, that can run `code` now; else the first that has it
  /// as a suggestion. `exact` keeps a stored Apple tag as it is.
  private static func firstEngine(
    for code: String, exact: Bool, inventory: Inventory,
    appleEquivalent: @Sendable (String) async -> String?
  ) async -> Resolution {
    var candidates: [Resolution] = []
    for engine in [LivePreviewEngineChoice.apple, .universal] {
      let language: String?
      if exact, engine == .apple {
        language = inventory.appleSupportedTags.contains(code) ? code : nil
      } else {
        language = await self.language(
          for: engine, from: code, inventory: inventory, appleEquivalent: appleEquivalent)
      }
      guard let language else { continue }
      candidates.append(explicit(engine: engine, language: language, inventory: inventory))
    }
    if let ready = candidates.first(where: { if case .ready = $0 { true } else { false } }) {
      return ready
    }
    for candidate in candidates {
      if case .notDownloaded(let engine, let language) = candidate {
        return .notSetUp(suggestion: Suggestion(engine: engine, language: language))
      }
    }
    return .notSetUp(suggestion: nil)
  }

  /// Dictation's language as a code: a locked code, or the Mac's full locale under Auto (the same
  /// guess Apple's engine makes, `ApplePreviewEngineResolver.languageCode(for:)`).
  static func guessCode(_ mode: LanguageMode) -> String {
    ApplePreviewEngineResolver.languageCode(for: mode)
  }

  /// This Mac's inventory, read live (#4105): Apple's meeting module lists from LivePreview
  /// (enumeration only, no claim, no download) and Universal's admission and languages.
  static func liveInventory(universalAdmitted: @Sendable () async -> Bool) async -> Inventory {
    var apple = (available: false, supported: [String](), installed: [String]())
    if #available(macOS 26.0, *), AppleTranscriberFactory.isAvailable(.meeting) {
      apple.available = true
      apple.supported = await AppleTranscriberFactory.supportedLocales(.meeting).map {
        $0.identifier(.bcp47)
      }
      apple.installed = await AppleTranscriberFactory.installedLocales(.meeting).map {
        $0.identifier(.bcp47)
      }
    }
    return Inventory(
      appleAvailable: apple.available, appleSupportedTags: apple.supported,
      appleInstalledTags: apple.installed, universalInstalled: await universalAdmitted(),
      universalCodes: Set(LanguageCatalog.all.map(\.code)))
  }

  /// Apple's equivalent meeting-module tag for a code, or nil (`supportedLocale(equivalentTo:)`).
  static let liveAppleEquivalent: @Sendable (String) async -> String? = { code in
    guard #available(macOS 26.0, *) else { return nil }
    return await AppleTranscriberFactory.supportedLocale(.meeting, equivalentTo: Locale(identifier: code))?
      .identifier(.bcp47)
  }

  /// The resolution as one log field: engine, language code and readiness; never text.
  static func logDescription(_ resolution: Resolution) -> String {
    switch resolution {
    case .ready(let engine, let language): "engine=\(engine.rawValue) language=\(language) state=ready"
    case .notDownloaded(let engine, let language):
      "engine=\(engine.rawValue) language=\(language) state=notDownloaded"
    case .notSetUp(let suggestion):
      "state=notSetUp"
        + (suggestion.map { " suggestion=\($0.engine.rawValue):\($0.language)" } ?? "")
    }
  }

  /// Whether the "different languages" note shows (plan R2.4): only when the transcript language
  /// is locked and its base language differs from the live words language. Auto never shows it.
  static func languagesDiffer(liveWords: String?, transcript: LanguageMode) -> Bool {
    guard let liveWords, case .locked(let code) = transcript else { return false }
    return baseCode(liveWords) != baseCode(code)
  }
}

// MARK: - Saving the first ready guess

extension MeetingLiveWordsChoice {

  /// The only writer of a guessed choice (plan R3). The Live words row and meeting Start share
  /// one instance and both call `materializeIfUnset()`.
  ///
  /// A guess is computed across suspensions (Apple's locale lookup), so the user can change the
  /// row meanwhile. The settings generation, advanced by every write to either key, is snapshot
  /// before the lookup; the guess is committed, both keys together, only if both are still unset
  /// and the generation has not moved. Otherwise the newer stored choice wins. Concurrent callers
  /// share one lookup.
  @MainActor
  final class Initializer {
    struct Environment {
      let settings: SettingsManager
      /// Reads this Mac's inventory; may suspend.
      let inventory: @MainActor () async -> Inventory
      let appleEquivalent: @Sendable (String) async -> String?
    }

    private let environment: Environment
    private var inFlight: Task<Resolution, Never>?

    init(environment: Environment) {
      self.environment = environment
    }

    /// The choice now, saving the dictation-language guess first when nothing is stored and the
    /// guess is ready.
    func materializeIfUnset() async -> Resolution {
      if let inFlight { return await inFlight.value }
      let task = Task { await self.run() }
      inFlight = task
      let result = await task.value
      inFlight = nil
      return result
    }

    private func run() async -> Resolution {
      let settings = environment.settings
      let generation = settings.meetingLiveWordsChoiceGeneration
      let inventory = await environment.inventory()
      let resolution = await MeetingLiveWordsChoice.resolve(
        engine: settings.meetingLiveWordsEngine, language: settings.meetingLiveWordsLanguage,
        guess: settings.languageMode, inventory: inventory,
        appleEquivalent: environment.appleEquivalent)
      // No suspension from here to the commit.
      guard settings.meetingLiveWordsEngine == nil, settings.meetingLiveWordsLanguage == nil else {
        return await current(inventory: inventory)
      }
      guard settings.meetingLiveWordsChoiceGeneration == generation else {
        return await current(inventory: inventory)
      }
      if case .ready(let engine, let language) = resolution {
        settings.commitMeetingLiveWordsChoice(engine: engine, language: language)
      }
      return resolution
    }

    /// This Mac's inventory and Apple's equivalence lookup, the same ones Start resolves with, so
    /// the Live words row lists and switches with exactly what a meeting would use (#4105).
    func inventory() async -> Inventory { await environment.inventory() }
    var appleEquivalent: @Sendable (String) async -> String? { environment.appleEquivalent }

    /// The stored values and what they resolve to, read together.
    struct Snapshot {
      let storedEngine: LivePreviewEngineChoice?
      let storedLanguage: String?
      let resolution: Resolution
    }

    /// The choice now, without saving anything (the DEBUG status door). The stored values and
    /// the resolution come from the same settings generation (Codex chunk 4 review).
    func peek() async -> Snapshot {
      await snapshot(inventory: await environment.inventory())
    }

    /// The DEBUG door's forced engine for one meeting: the stored language, else the guess,
    /// matched to that engine by the shared policy. Saves nothing and never downloads.
    func resolve(forcing engine: LivePreviewEngineChoice) async -> Resolution {
      let settings = environment.settings
      let inventory = await environment.inventory()
      let from = settings.meetingLiveWordsLanguage ?? MeetingLiveWordsChoice.guessCode(settings.languageMode)
      guard
        let language = await MeetingLiveWordsChoice.language(
          for: engine, from: from, inventory: inventory,
          appleEquivalent: environment.appleEquivalent)
      else { return .notSetUp(suggestion: nil) }
      return MeetingLiveWordsChoice.explicit(engine: engine, language: language, inventory: inventory)
    }

    /// The stored choice as it resolves now (a user change that landed during the lookup).
    /// Resolving can suspend again, so it repeats until no write landed during it: the result
    /// always describes the latest stored choice (Codex chunk 3 review).
    private func current(inventory: Inventory) async -> Resolution {
      await snapshot(inventory: inventory).resolution
    }

    private func snapshot(inventory: Inventory) async -> Snapshot {
      let settings = environment.settings
      while true {
        let generation = settings.meetingLiveWordsChoiceGeneration
        let engine = settings.meetingLiveWordsEngine
        let language = settings.meetingLiveWordsLanguage
        let resolution = await MeetingLiveWordsChoice.resolve(
          engine: engine, language: language, guess: settings.languageMode,
          inventory: inventory, appleEquivalent: environment.appleEquivalent)
        if settings.meetingLiveWordsChoiceGeneration == generation {
          return Snapshot(storedEngine: engine, storedLanguage: language, resolution: resolution)
        }
      }
    }
  }
}
