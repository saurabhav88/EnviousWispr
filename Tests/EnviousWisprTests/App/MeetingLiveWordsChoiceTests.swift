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

  /// #4325: the Apple tag a meeting may use while Universal is not downloaded must already be on
  /// this Mac; a supported-but-missing region would start a meeting with no live words.
  @Test("The Apple stand-in for a Universal language is an installed tag, or none")
  func appleStandInIsInstalled() async {
    var inventory = Self.inventory
    inventory.macRegion = "CA"
    #expect(
      await Choice.installedAppleStandIn(
        forUniversal: "fr", inventory: inventory, appleEquivalent: Self.equivalent) == "fr-CA")
    #expect(
      await Choice.installedAppleStandIn(
        forUniversal: "en", inventory: Self.inventory, appleEquivalent: Self.equivalent)
        == "en-US")
    #expect(
      await Choice.installedAppleStandIn(
        forUniversal: "de", inventory: Self.inventory, appleEquivalent: Self.equivalent) == nil,
      "German is supported but not installed")
    #expect(
      await Choice.installedAppleStandIn(
        forUniversal: "nl", inventory: Self.inventory, appleEquivalent: Self.equivalent) == nil)
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

  /// #4813: Auto now guesses the Mac's own language, so a Traditional Chinese Mac with Region
  /// United States guesses `zh-Hant-US`. Apple maps that full tag to `zh-TW` but the bare `zh`
  /// to `zh-CN` (measured), so stripping to the base first saved Simplified Chinese as the
  /// meeting default when both packs were installed.
  @Test("A regional guess Apple does not list exactly keeps its script through Apple's match")
  func regionalGuessKeepsItsScript() async {
    var chinese = Self.inventory
    chinese.appleSupportedTags = ["zh-CN", "zh-HK", "zh-TW"]
    chinese.appleInstalledTags = ["zh-CN", "zh-TW"]
    chinese.macRegion = "US"
    let equivalent: @Sendable (String) async -> String? = { code in
      ["zh-Hant-US": "zh-TW", "zh": "zh-CN"][code]
    }
    #expect(
      await Choice.language(
        for: .apple, from: "zh-Hant-US", inventory: chinese, appleEquivalent: equivalent)
        == "zh-TW", "Traditional Chinese, not the bare code's Simplified match")
    #expect(
      await Choice.language(
        for: .apple, from: "zh", inventory: chinese, appleEquivalent: equivalent) == "zh-CN",
      "a bare code keeps Apple's own match for it")

    // A Simplified Chinese Mac in Taiwan: the Mac-region tag (`zh-TW`) is the other script.
    var taiwan = chinese
    taiwan.macRegion = "TW"
    let simplified: @Sendable (String) async -> String? = { code in
      ["zh-Hans-TW": "zh-CN", "zh": "zh-CN"][code]
    }
    #expect(
      await Choice.language(
        for: .apple, from: "zh-Hans-TW", inventory: taiwan, appleEquivalent: simplified)
        == "zh-CN", "Apple's match for the full tag beats the Mac-region tag of another script")

    // Same Mac with only the Traditional pack installed: no fallback to the other script; the
    // Simplified download is offered instead (so a ready Universal model can win).
    var traditionalOnly = taiwan
    traditionalOnly.appleInstalledTags = ["zh-TW"]
    #expect(
      await Choice.language(
        for: .apple, from: "zh-Hans-TW", inventory: traditionalOnly, appleEquivalent: simplified)
        == "zh-CN", "the right script's download, never the installed other script")

    // A Traditional Chinese Mac with Region United Kingdom guesses `zh-GB` (no written script;
    // Traditional by likely subtags). Only the Simplified pack installed: offer Traditional.
    var britain = chinese
    britain.macRegion = "GB"
    britain.appleInstalledTags = ["zh-CN"]
    let traditional: @Sendable (String) async -> String? = { code in
      ["zh-GB": "zh-TW", "zh": "zh-CN"][code]
    }
    #expect(
      await Choice.language(
        for: .apple, from: "zh-GB", inventory: britain, appleEquivalent: traditional)
        == "zh-TW", "a regional tag's implied script counts too")
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
    #expect(picks == ["fr-FR"], "Apple's equivalent is installed, so it wins every time")
  }

  /// #4320 (founder report): switching from Universal ("en") back to Apple on a US Mac gave
  /// English (Australia), the alphabetically first installed English.
  @Test("Switching back to Apple keeps the Mac's region, then Apple's own region")
  func switchingBackKeepsTheMacRegion() async {
    var installed = Self.inventory
    installed.appleSupportedTags = ["en-AU", "en-GB", "en-US", "fr-CA", "fr-FR"]
    installed.appleInstalledTags = ["en-AU", "en-GB", "en-US", "fr-CA"]
    func switched(_ current: String, region: String?) async -> String? {
      var inventory = installed
      inventory.macRegion = region
      return await Choice.switchedLanguage(
        to: .apple, from: current, inventory: inventory, appleEquivalent: Self.equivalent)
    }
    #expect(await switched("en", region: "US") == "en-US", "the Mac's region")
    #expect(await switched("en", region: "GB") == "en-GB", "the Mac's region, not Apple's")
    #expect(await switched("en", region: nil) == "en-US", "Apple's own equivalent, installed")
    #expect(await switched("en", region: "IN") == "en-US", "no en-IN installed: Apple's equivalent")
    // fr-FR (Apple's equivalent) is not installed: the installed fr-CA, not a download.
    #expect(await switched("fr", region: "US") == "fr-CA")
  }

  @Test("Partial choices keep what the user stored")
  func partialChoices() async {
    // Engine only (a switch cleared the language): not set up until a language is picked; a
    // guessed language never runs behind "Choose a language".
    #expect(await resolve(.universal, nil) == .notSetUp(suggestion: nil))
    #expect(await resolve(.apple, nil) == .notSetUp(suggestion: nil))
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
    #expect(
      !Choice.languagesDiffer(liveWords: "nb-NO", transcript: .locked("no")),
      "Norwegian Bokmal on the Mac and the catalogue's Norwegian are one language")
  }

  @Test("A Mac in Norwegian Bokmal guesses the catalogue's Norwegian for Universal")
  func aliasedMacLanguageReachesUniversal() async {
    var inventory = Self.inventory
    inventory.universalCodes.insert("no")
    inventory.universalInstalled = true
    #expect(
      await resolve(nil, nil, guess: .locked("nb-NO"), inventory: inventory)
        == .ready(engine: .universal, language: "no"))
    #expect(
      await resolve(.universal, "nb-NO", inventory: inventory)
        == .ready(engine: .universal, language: "no"), "a stored alias reads the same way")
    #expect(
      await Choice.switchedLanguage(
        to: .universal, from: "nb-NO", inventory: inventory, appleEquivalent: Self.equivalent)
        == "no", "switching from Apple's Bokmal keeps Norwegian")
  }
}
