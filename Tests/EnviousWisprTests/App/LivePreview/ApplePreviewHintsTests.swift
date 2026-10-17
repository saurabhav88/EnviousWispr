import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprLivePreview

@Suite("Apple preview word hints", .tags(.productOutcome))
struct ApplePreviewHintsTests {
  @Test("saved and learned canonicals precede builtins; packs and mishearings are excluded")
  func eligibleSourcesAndProvenance() {
    let words = [
      CustomWord(canonical: "Builtin", aliases: ["built in"], source: .builtin),
      CustomWord(canonical: "Saved", aliases: ["save it"]),
      CustomWord(canonical: "Learned", aliases: ["learn it"], learnedAliases: ["learn it"],
        learnedAt: Date(timeIntervalSince1970: 1)),
      CustomWord(canonical: "Saved WithAlias", aliases: ["old sound"],
        learnedAliases: ["old sound"]),
      CustomWord(canonical: "Pack", source: .pack),
    ]
    #expect(ApplePreviewHints.build(from: words) == ["Saved", "Learned", "Saved WithAlias", "Builtin"])
  }

  @Test("a library containing only self-learned words produces hints")
  func learnedOnlyLibrary() {
    let words = [CustomWord(canonical: "LearnedOnly", learnedAt: Date(timeIntervalSince1970: 1))]
    #expect(ApplePreviewHints.build(from: words) == ["LearnedOnly"])
  }

  @Test("brief canonicals normalize whitespace and deduplicate without changing casing")
  func phraseShapeAndDedupe() {
    let words = [
      CustomWord(canonical: "  Two\t\nWords  "),
      CustomWord(canonical: "two words"),
      CustomWord(canonical: ""),
      CustomWord(canonical: " \n\t"),
      CustomWord(canonical: "One"),
      CustomWord(canonical: "Three Whole Words"),
      CustomWord(canonical: "Two\u{00a0}Words", source: .builtin),
      CustomWord(canonical: "Café"),
      CustomWord(canonical: "CAFE\u{0301}"),
    ]
    #expect(ApplePreviewHints.build(from: words) == ["Two Words", "One", "Café"])
    #expect(ApplePreviewHints.build(from: []) == [])
  }

  @Test("the hundred-phrase cap gives saved and learned user words priority over builtins")
  func capAndOrdering() {
    let builtins = (0..<4).map { CustomWord(canonical: "Builtin\($0)", source: .builtin) }
    let users = (0..<99).map { CustomWord(canonical: "User\($0)") }
    let learned = CustomWord(canonical: "LearnedLast", learnedAt: Date(timeIntervalSince1970: 1))
    let expected = (0..<99).map { "User\($0)" } + ["LearnedLast"]
    #expect(ApplePreviewHints.build(from: builtins + users + [learned]) == expected)
    #expect(ApplePreviewHints.build(from: users + [learned]) == expected)
    #expect(ApplePreviewHints.build(from: users + [learned, CustomWord(canonical: "Overflow")]) == expected)
  }

  @Test("Apple's application flag disables hints and correction without erasing original inputs")
  func applicationGatePreservesUniversalInputs() {
    let lookups = WordCorrector.buildLookups(words: [CustomWord(canonical: "Saved")])
    let off = LivePreviewVocabulary(
      lookups: lookups, contextualPhrases: ["Saved", "Learned"], dictionaryEnabled: false)
    let disabled = ApplePreviewHints.inputs(for: off)
    #expect(disabled.lookups == nil)
    #expect(disabled.phrases == [])
    #expect(off.lookups != nil, "Universal still receives the original correcting snapshot")
    #expect(off.contextualPhrases == ["Saved", "Learned"])
    let on = LivePreviewVocabulary(
      lookups: lookups, contextualPhrases: ["Saved", "Learned"], dictionaryEnabled: true)
    let enabled = ApplePreviewHints.inputs(for: on)
    #expect(enabled.lookups?.canonicals == ["Saved"])
    #expect(enabled.phrases == ["Saved", "Learned"])
  }
}
