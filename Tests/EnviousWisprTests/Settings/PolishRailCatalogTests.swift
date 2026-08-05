import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #1914: the provider RAIL's grouping and copy policy — the vertical engine
/// list in AI Polish settings, not the model picker beside it (that is
/// `OllamaModelPickerPresentationTests`).
///
/// **What this suite does NOT prove, stated first because it is what a reader
/// will assume wrongly.** These are pure-policy assertions over
/// `PolishRailGroup` and `PolishRailCatalog`. They do not prove SwiftUI renders
/// three group headings, renders them in this order, places the detail privacy
/// line anywhere, or that VoiceOver speaks the accessibility phrase. No unit
/// seam here reaches the rendered hierarchy. Chunk 10 Live UAT owns that proof.
///
/// **Why the suite exists at all.** Before #1914, one binary
/// local-versus-cloud classification drove the group heading, spoken
/// accessibility phrase, and detail privacy line. Ollama was classified as
/// local, so a user running a hosted model was told "Nothing you dictate leaves
/// this Mac". The approved plan named only two of those three consumers, so the
/// false privacy line survived the earlier reviews and seven built chunks.
///
/// The fix centralizes the three presentation values on an exhaustive group
/// enum. This suite freezes the approved policy while Live UAT verifies its
/// SwiftUI and VoiceOver wiring.
@Suite("Provider rail grouping and copy (#1914)")
struct PolishRailCatalogTests {

  // MARK: - Group policy

  /// Order is render order, and the rail derives its headings from
  /// `allCases`, so reordering the enum silently reorders the screen.
  @Test("the three groups are declared in render order")
  func groupOrderIsFrozen() {
    #expect(PolishRailGroup.allCases == [.onThisMac, .yourOwnSetup, .cloud])
  }

  @Test(
    "each group's heading, accessibility phrase and privacy line are exact",
    arguments: [
      (
        PolishRailGroup.onThisMac, "On this Mac", "on this Mac",
        "Nothing you dictate leaves this Mac"
      ),
      (
        PolishRailGroup.yourOwnSetup, "Your own setup", "your own setup",
        "Uses your selected Ollama model, local or hosted"
      ),
      (PolishRailGroup.cloud, "Cloud", "cloud", "Sends transcribed text, never audio"),
    ])
  func groupCopyIsExact(
    group: PolishRailGroup, heading: String, phrase: String, privacy: String
  ) {
    #expect(group.heading == heading)
    #expect(group.accessibilityPhrase == phrase)
    #expect(group.privacyLine == privacy)
  }

  /// The specific regression. `.yourOwnSetup` must not claim dictation stays on
  /// the Mac because this provider-level policy does not inspect the armed
  /// Ollama model.
  ///
  /// Assert the exact approved string and reject common device-boundary claims,
  /// so an equally false rewording also fails.
  @Test("the Ollama group never claims dictation stays on this Mac")
  func yourOwnSetupMakesNoDeviceBoundaryClaim() {
    let line = PolishRailGroup.yourOwnSetup.privacyLine
    #expect(line == "Uses your selected Ollama model, local or hosted")
    let lowered = line.lowercased()
    #expect(lowered.contains("leaves this mac") == false)
    #expect(lowered.contains("leaves your device") == false)
    #expect(lowered.contains("stays on") == false)
    #expect(lowered.contains("never leaves") == false)
    // And it does say the thing that IS true either way.
    #expect(lowered.contains("local or hosted"))
  }

  /// Freeze the two previously correct privacy lines so adding the third policy
  /// does not rewrite their copy.
  @Test("the on-Mac and cloud privacy lines are unchanged from before #1914")
  func untouchedGroupsKeepTheirExactCopy() {
    #expect(PolishRailGroup.onThisMac.privacyLine == "Nothing you dictate leaves this Mac")
    #expect(PolishRailGroup.cloud.privacyLine == "Sends transcribed text, never audio")
  }

  // MARK: - Catalog membership

  @Test(
    "each group contains exactly its approved providers, in order",
    arguments: [
      (PolishRailGroup.onThisMac, [LLMProvider.egOne, .appleIntelligence]),
      (PolishRailGroup.yourOwnSetup, [LLMProvider.ollama]),
      (PolishRailGroup.cloud, [LLMProvider.openAI, .gemini, .claude]),
    ])
  func groupMembershipIsFrozen(group: PolishRailGroup, expected: [LLMProvider]) {
    #expect(PolishRailCatalog.providers(in: group).map(\.provider) == expected)
  }

  /// Both halves matter and fail differently: a missing selectable provider
  /// vanishes from the rail, while a duplicated provider renders twice.
  @Test("every selectable provider appears exactly once across the three groups")
  func everyProviderAppearsExactlyOnce() {
    let flattened = PolishRailGroup.allCases.flatMap {
      PolishRailCatalog.providers(in: $0).map(\.provider)
    }
    let selectable = Set(LLMProvider.allCases.filter { $0 != .none })

    #expect(Set(flattened).count == flattened.count, "a provider is in two groups")
    #expect(Set(flattened) == selectable, "a selectable provider is missing")
    #expect(flattened.count == selectable.count)
    #expect(flattened == PolishRailCatalog.all.map(\.provider))
  }

  /// `.none` is the "polish off" sentinel, not an engine. A row for it would
  /// offer the user a provider that cannot polish anything.
  @Test("the polish-off sentinel is not a rail row")
  func noneIsNotARow() {
    #expect(PolishRailCatalog.all.contains { $0.provider == .none } == false)
    #expect(PolishRailCatalog.entry(for: .none) == nil)
  }

  @Test("the flattened catalog order is the render order the groups produce")
  func flattenedOrderMatchesGroupOrder() {
    let byGroup = PolishRailGroup.allCases.flatMap { PolishRailCatalog.providers(in: $0) }
    #expect(byGroup.map(\.provider) == PolishRailCatalog.all.map(\.provider))
  }

  // MARK: - Row copy

  @Test("the Ollama row is renamed and its tagline names both locations")
  func ollamaRowCopyIsExact() throws {
    let ollama = try #require(PolishRailCatalog.entry(for: .ollama))
    #expect(ollama.name == "Ollama")
    #expect(ollama.tagline == "Any open model, local or hosted")
    #expect(ollama.group == .yourOwnSetup)
    #expect(ollama.recommended == false)
    // The old name is gone. "Local" was a claim, not a label, and it stopped
    // being true when Ollama began hosting models.
    #expect(ollama.name.contains("Local") == false)
  }

  @Test("EG-1 is still the only recommended row")
  func egOneIsTheSoleRecommendation() {
    let recommended = PolishRailCatalog.all.filter(\.recommended).map(\.provider)
    #expect(recommended == [.egOne])
  }

  @Test(
    "the five untouched rows keep their exact names and taglines",
    arguments: [
      (LLMProvider.egOne, "EG-1", "Our tuned model"),
      (LLMProvider.appleIntelligence, "Apple Intelligence", "Built into macOS"),
      (LLMProvider.openAI, "OpenAI", "Your API key"),
      (LLMProvider.gemini, "Google Gemini", "Your API key"),
      (LLMProvider.claude, "Claude", "Your API key"),
    ])
  func untouchedRowCopyIsUnchanged(provider: LLMProvider, name: String, tagline: String) throws {
    let entry = try #require(PolishRailCatalog.entry(for: provider))
    #expect(entry.name == name)
    #expect(entry.tagline == tagline)
  }

  @Test("entry(for:) returns the catalog's own row for every listed provider")
  func entryLookupMatchesTheCatalog() throws {
    for expected in PolishRailCatalog.all {
      let found = try #require(PolishRailCatalog.entry(for: expected.provider))
      #expect(found == expected)
    }
  }

  // MARK: - Copy hygiene

  /// Rule 6 covers every human-facing string. Swept across all three groups and
  /// all six rows rather than only the strings this chunk added, because the
  /// check costs nothing and a later edit is what usually introduces one.
  @Test("no rail string uses an em dash or an en dash")
  func noFancyDashesInRailCopy() {
    var strings: [String] = []
    for group in PolishRailGroup.allCases {
      strings += [group.heading, group.accessibilityPhrase, group.privacyLine]
    }
    for entry in PolishRailCatalog.all {
      strings += [entry.name, entry.tagline]
    }
    for value in strings {
      #expect(!value.contains("\u{2014}"), "em-dash in \(value)")
      #expect(!value.contains("\u{2013}"), "en-dash in \(value)")
    }
  }
}
