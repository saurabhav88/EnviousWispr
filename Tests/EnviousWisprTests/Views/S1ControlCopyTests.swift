import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// The writing-style card's copy (#2649). Two frozen properties: the in-app
/// strings carry no em or en dash (house rule for every user-facing string),
/// and the model is credited under its licence-bound name and maker.
@Suite("S1-mini writing-style card copy (#2649)", .tags(.driftGuard))
struct S1ControlCopyTests {

  static var everyString: [String] {
    [
      S1ControlCopy.cardLabel, S1ControlCopy.intro,
      S1ControlCopy.stylingLabel, S1ControlCopy.stylingHint, S1ControlCopy.stylingShort,
      S1ControlCopy.structureLabel, S1ControlCopy.structureHint, S1ControlCopy.structureShort,
      S1ControlCopy.contextLabel, S1ControlCopy.contextHint, S1ControlCopy.contextShort,
    ]
      + S1Styling.allCases.map(S1ControlCopy.label(for:))
      + S1Structure.allCases.map(S1ControlCopy.label(for:))
      + S1Context.allCases.map(S1ControlCopy.label(for:))
  }

  @Test("compact style descriptions keep the approved short copy")
  func shortCopy() {
    #expect(S1ControlCopy.stylingShort == "Choose how formal your text sounds.")
    #expect(S1ControlCopy.structureShort == "Keep sentences or turn spoken items into lists.")
    #expect(S1ControlCopy.contextShort == "Format dictated greetings and sign-offs as email.")
    #expect(ProviderCompactCopy.short(for: .appleIntelligence) == "On-device polish on supported Macs with macOS 26+.")
    for provider in LLMProvider.allCases {
      #expect(ProviderCompactCopy.short(for: provider).count <= 60)
      #expect(ProviderCompactCopy.keyShort(for: provider).count <= 60)
    }
  }

  @Test("no string on the card carries an em or en dash")
  func noDashes() {
    for text in Self.everyString {
      #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}"), Comment(rawValue: text))
      #expect(!text.isEmpty)
    }
  }

  /// The licence requires exactly "S1-mini" by "Superwhisper" wherever the
  /// model is identified. The intro is where this card identifies it.
  @Test("the intro credits the maker under the licensed spelling")
  func introCreditsTheMaker() {
    #expect(S1ControlCopy.intro.contains("Superwhisper"))
    #expect(S1ControlCopy.intro.contains(LLMProvider.s1Mini.displayName))
    #expect(!S1ControlCopy.intro.contains("SuperWhisper"))
  }

  /// Who sees the card (#2649 cloud review P2). An S1-mini pulled into Ollama
  /// gets the same control line from the same picks, so it must get the same
  /// card; every other engine must not, or a picker would appear for a model
  /// that ignores it.
  @Test("the card shows for the managed engine and for an Ollama S1-mini, and nowhere else")
  func cardVisibility() {
    #expect(S1ControlCardVisibility.shows(provider: .s1Mini, effectiveModel: "s1-mini"))
    #expect(
      S1ControlCardVisibility.shows(
        provider: .ollama, effectiveModel: "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"))
    #expect(!S1ControlCardVisibility.shows(provider: .ollama, effectiveModel: "qwen2.5:3b"))
    #expect(!S1ControlCardVisibility.shows(provider: .ollama, effectiveModel: "eg-1"))
    for provider in [LLMProvider.egOne, .appleIntelligence, .openAI, .gemini, .claude, .none] {
      #expect(
        !S1ControlCardVisibility.shows(provider: provider, effectiveModel: "s1-mini"),
        Comment(rawValue: provider.rawValue))
    }
  }

  /// Every segment label is a distinct word, so two options can never render
  /// as the same pill.
  @Test("option labels are distinct within each axis")
  func labelsAreDistinct() {
    #expect(
      Set(S1Styling.allCases.map(S1ControlCopy.label(for:))).count == S1Styling.allCases.count)
    #expect(
      Set(S1Structure.allCases.map(S1ControlCopy.label(for:))).count == S1Structure.allCases.count)
    #expect(
      Set(S1Context.allCases.map(S1ControlCopy.label(for:))).count == S1Context.allCases.count)
  }
}
