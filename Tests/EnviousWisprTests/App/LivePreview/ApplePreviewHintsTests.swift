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
    #expect(
      ApplePreviewHints.build(from: users + [learned, CustomWord(canonical: "Overflow")])
        == (1..<99).map { "User\($0)" } + ["LearnedLast", "Overflow"])
  }

  @Test("overflow gives a newly saved or learned word the same hundred-addition window")
  func newWordInclusionAndExpiry() {
    let oldWords = (0..<100).map { CustomWord(canonical: "User\($0)") }
    let laterWords = (0..<100).map { CustomWord(canonical: "Later\($0)") }
    for newWord in [
      CustomWord(canonical: "NewWord"),
      CustomWord(canonical: "NewWord", learnedAt: Date(timeIntervalSince1970: 1)),
    ] {
      #expect(
        ApplePreviewHints.build(from: oldWords + [newWord])
          == (1..<100).map { "User\($0)" } + ["NewWord"])
      #expect(
        ApplePreviewHints.build(from: oldWords + [newWord] + laterWords.prefix(99))
          == ["NewWord"] + (0..<99).map { "Later\($0)" })
      #expect(
        ApplePreviewHints.build(from: oldWords + [newWord] + laterWords)
          == (0..<100).map { "Later\($0)" })
    }
  }

  @Test("duplicates and ineligible additions never refresh or consume a hint slot")
  func overflowDedupeKeepsFirstOccurrence() {
    let users = [CustomWord(canonical: "Café"), CustomWord(canonical: "Two Words")]
      + (0..<100).map { CustomWord(canonical: "User\($0)") }
    let ignored = [
      CustomWord(canonical: "CAFE\u{0301}"),
      CustomWord(canonical: " two\twords "),
      CustomWord(canonical: "USER99"),
      CustomWord(canonical: " "),
      CustomWord(canonical: "Three Whole Words"),
      CustomWord(canonical: "PackTail", source: .pack),
    ]
    let builtins = (0..<110).map { CustomWord(canonical: "Builtin\($0)", source: .builtin) }
    #expect(
      ApplePreviewHints.build(from: builtins + users + ignored)
        == (0..<100).map { "User\($0)" })

    let newWord = CustomWord(canonical: "Newest", aliases: ["AliasOnly"])
    #expect(
      ApplePreviewHints.build(from: users + ignored + [newWord])
        == (1..<100).map { "User\($0)" } + ["Newest"])
  }

  @Test("builtin overflow keeps its original prefix and fills only unused user slots")
  func builtinOverflowAndSmallLibraryParity() {
    let builtins = (0..<110).map { CustomWord(canonical: "Builtin\($0)", source: .builtin) }
    #expect(ApplePreviewHints.build(from: builtins) == (0..<100).map { "Builtin\($0)" })
    let users = [CustomWord(canonical: "Builtin0"), CustomWord(canonical: "Saved")]
    #expect(
      ApplePreviewHints.build(from: builtins + users)
        == ["Builtin0", "Saved"] + (1..<99).map { "Builtin\($0)" })
    #expect(
      ApplePreviewHints.build(from: Array(builtins.prefix(3)) + users)
        == ["Builtin0", "Saved", "Builtin1", "Builtin2"])
  }

  @Test("large imports roll the window without ranking metadata or promoting edited positions")
  func importAndMetadataDoNotChangeAdditionOrder() {
    var words = (0..<250).map { CustomWord(canonical: "Imported\($0)") }
    words[0].canonical = "EditedOld"
    words[0].aliases = ["NewMishearing"]
    words[0].learnedAliases = ["NewMishearing"]
    words[0].frequencyUsed = 10_000
    words[0].lastUsed = Date(timeIntervalSince1970: 100)
    words[0].learnedAt = Date(timeIntervalSince1970: 100)
    words[0].priority = 10_000
    #expect(ApplePreviewHints.build(from: words) == (150..<250).map { "Imported\($0)" })

    let learned = (0..<101).map {
      CustomWord(canonical: "Learned\($0)", learnedAt: Date(timeIntervalSince1970: Double($0)))
    }
    #expect(ApplePreviewHints.build(from: learned) == (1..<101).map { "Learned\($0)" })
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
