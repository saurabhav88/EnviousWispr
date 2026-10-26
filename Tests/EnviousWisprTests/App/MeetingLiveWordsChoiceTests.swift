import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4105: which engine and language EnviousMeet's live words use.
///
/// **What the user sees when this fails:** a meeting quietly runs in a language or engine they
/// did not pick, Apple asks for a download for a language already installed in another region,
/// the region flips between meetings, an older Mac offers Apple speech it cannot run, or the
/// "different languages" note shows when the languages are the same.
@Suite("Meeting live words choice (#4105)", .tags(.productOutcome))
struct MeetingLiveWordsChoiceTests {
  typealias Choice = MeetingLiveWordsChoice

  static let inventory = Choice.Inventory(
    appleAvailable: true,
    appleSupportedTags: ["en-US", "en-GB", "fr-FR", "fr-CA", "de-DE", "ja-JP"],
    appleInstalledTags: ["en-US", "fr-CA"],
    universalInstalled: false,
    universalCodes: ["en", "fr", "de", "ja", "nl", "pl"])

  /// Apple's equivalence, as measured shapes: a bare code maps to a region.
  static let equivalent: @Sendable (String) async -> String? = { code in
    ["en": "en-US", "fr": "fr-FR", "de": "de-DE", "ja": "ja-JP"][Choice.baseCode(code)]
  }

  func resolve(
    _ engine: LivePreviewEngineChoice?, _ language: String?, guess: LanguageMode = .locked("en"),
    inventory: Choice.Inventory = inventory
  ) async -> Choice.Resolution {
    await Choice.resolve(
      engine: engine, language: language, guess: guess, inventory: inventory,
      appleEquivalent: Self.equivalent)
  }

  @Test("A stored choice is used exactly, and never swapped for another engine or language")
  func storedChoiceIsExact() async {
    #expect(await resolve(.apple, "en-US") == .ready(engine: .apple, language: "en-US"))
    #expect(await resolve(.apple, "en-GB") == .notDownloaded(engine: .apple, language: "en-GB"))
    // Apple does not have Dutch: not set up, not quietly Universal.
    #expect(await resolve(.apple, "nl-NL") == .notSetUp(suggestion: nil))
    #expect(await resolve(.universal, "nl") == .notDownloaded(engine: .universal, language: "nl"))
    var universalReady = Self.inventory
    universalReady.universalInstalled = true
    #expect(
      await resolve(.universal, "nl", inventory: universalReady)
        == .ready(engine: .universal, language: "nl"))
  }

  @Test("Apple speech is never offered where it cannot run")
  func appleUnavailable() async {
    var older = Self.inventory
    older.appleAvailable = false
    older.universalInstalled = true
    #expect(await resolve(.apple, "en-US", inventory: older) == .notSetUp(suggestion: nil))
    #expect(
      await resolve(nil, nil, inventory: older) == .ready(engine: .universal, language: "en"))
  }

  @Test("With nothing stored, an installed Apple region is guessed first, then Universal")
  func guessPrefersReadyEngines() async {
    #expect(await resolve(nil, nil) == .ready(engine: .apple, language: "en-US"))
    // French is installed as fr-CA only: the guess uses it instead of asking for fr-FR.
    #expect(
      await resolve(nil, nil, guess: .locked("fr")) == .ready(engine: .apple, language: "fr-CA"))
    // German: supported, not installed anywhere; Universal not downloaded either.
    #expect(
      await resolve(nil, nil, guess: .locked("de"))
        == .notSetUp(suggestion: .init(engine: .apple, language: "de-DE")))
    // Dutch: no Apple; Universal has it but is not downloaded.
    #expect(
      await resolve(nil, nil, guess: .locked("nl"))
        == .notSetUp(suggestion: .init(engine: .universal, language: "nl")))
    var universalReady = Self.inventory
    universalReady.universalInstalled = true
    #expect(
      await resolve(nil, nil, guess: .locked("nl"), inventory: universalReady)
        == .ready(engine: .universal, language: "nl"))
  }

  @Test("The same inventory picks the same installed region every time")
  func regionIsStable() async {
    var two = Self.inventory
    two.appleInstalledTags = ["fr-FR", "fr-CA"]
    var picks: Set<String> = []
    for _ in 0..<5 {
      if case .ready(_, let language) = await resolve(
        nil, nil, guess: .locked("fr"), inventory: two)
      {
        picks.insert(language)
      }
    }
    #expect(picks == ["fr-CA"], "sorted installed tags, the existing satisfyingTag policy")
  }

  @Test("Partial choices keep what the user stored")
  func partialChoices() async {
    // Engine only: the guess in that engine's terms; the engine stays Universal.
    #expect(await resolve(.universal, nil) == .notDownloaded(engine: .universal, language: "en"))
    // Language only: the first engine that has it, the tag kept exact.
    #expect(await resolve(nil, "en-US") == .ready(engine: .apple, language: "en-US"))
    #expect(
      await resolve(nil, "nl")
        == .notSetUp(suggestion: .init(engine: .universal, language: "nl")))
  }

  @Test("Switching engines keeps a language the new engine has, else clears it")
  func switchingEngines() async {
    func switched(_ engine: LivePreviewEngineChoice, _ current: String?) async -> String? {
      await Choice.switchedLanguage(
        to: engine, from: current, inventory: Self.inventory, appleEquivalent: Self.equivalent)
    }
    #expect(await switched(.universal, "fr-CA") == "fr")
    #expect(await switched(.apple, "fr") == "fr-CA", "an installed region first")
    #expect(await switched(.apple, "de") == "de-DE", "else Apple's own equivalent to download")
    #expect(await switched(.apple, "nl") == nil, "Apple has no Dutch: cleared")
    #expect(await switched(.apple, nil) == nil)
  }

  @Test("The different-languages note shows only for a locked, different transcript language")
  func differNote() {
    #expect(!Choice.languagesDiffer(liveWords: "en-US", transcript: .auto))
    #expect(!Choice.languagesDiffer(liveWords: "en-US", transcript: .locked("en")))
    #expect(Choice.languagesDiffer(liveWords: "en-US", transcript: .locked("de")))
    #expect(!Choice.languagesDiffer(liveWords: nil, transcript: .locked("de")))
  }
}
