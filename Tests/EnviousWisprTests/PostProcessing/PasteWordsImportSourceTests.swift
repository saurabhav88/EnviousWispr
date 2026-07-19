import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #1681 (PR-P1) — pasted-text parsing.
///
/// The parser's job is to be conservative. A missed split costs the user one
/// edit; a wrong split silently invents words they never typed and quietly
/// corrupts their dictionary, so the non-separator cases matter more than the
/// separator ones.
@Suite("PasteWordsParser")
struct PasteWordsImportSourceTests {

  // MARK: - Separators

  @Test(
    "each supported separator splits",
    arguments: [
      ("Kubernetes,Anthropic", ["Kubernetes", "Anthropic"]),
      ("Kubernetes\nAnthropic", ["Kubernetes", "Anthropic"]),
      ("Kubernetes\r\nAnthropic", ["Kubernetes", "Anthropic"]),
      ("Kubernetes\rAnthropic", ["Kubernetes", "Anthropic"]),
      ("Kubernetes, Anthropic,\n Qualtrics", ["Kubernetes", "Anthropic", "Qualtrics"]),
    ])
  func supportedSeparatorsSplit(input: String, expected: [String]) throws {
    #expect(try PasteWordsParser.parse(input) == expected)
  }

  @Test(
    "nothing else splits",
    arguments: [
      // A space is not a separator: multi-word terms are the common case.
      ("Envious Labs", ["Envious Labs"]),
      ("Visual Studio Code", ["Visual Studio Code"]),
      // Punctuation that lives INSIDE real terms.
      ("C++", ["C++"]),
      ("C#", ["C#"]),
      (".NET", [".NET"]),
      ("Anand-Vaish", ["Anand-Vaish"]),
      ("and/or", ["and/or"]),
      ("Smith; Jones", ["Smith; Jones"]),
      ("node.js", ["node.js"]),
    ])
  func nonSeparatorsAreLeftIntact(input: String, expected: [String]) throws {
    #expect(try PasteWordsParser.parse(input) == expected)
  }

  // MARK: - Trimming and empties

  @Test("surrounding whitespace is trimmed, inner spacing is kept")
  func whitespaceIsTrimmedButNotCollapsed() throws {
    #expect(try PasteWordsParser.parse("  Envious Labs  ") == ["Envious Labs"])
  }

  @Test("empty and whitespace-only pieces are dropped")
  func emptyPiecesAreDropped() throws {
    #expect(
      try PasteWordsParser.parse("Kubernetes,,  ,\n\n,Anthropic") == ["Kubernetes", "Anthropic"])
  }

  @Test(
    "input with no words yields nothing rather than a blank row",
    arguments: ["", "   ", "\n\n", ",,,", " , \n , "])
  func inputWithoutWordsYieldsNothing(input: String) throws {
    #expect(try PasteWordsParser.parse(input).isEmpty)
  }

  /// The bug this freezes (cloud review, #1683): padding is not part of the
  /// word, but the scan buffer counted it, so whitespace alone could exceed a
  /// LENGTH ceiling and fail the whole paste as "too long". Spaces are not
  /// separators — they have to survive inside a term like "Claude Code" — so
  /// they accumulated. Every case here is padding a trim would erase.
  @Test("padding is never mistaken for word length")
  func paddingIsNotCountedTowardWordLength() throws {
    let farPastTheCeiling = CustomWordsImportLimits.maximumStoredValueScalars * 6

    // Whitespace alone imports nothing; it must not throw.
    #expect(try PasteWordsParser.parse(String(repeating: " ", count: farPastTheCeiling)).isEmpty)

    // A short word keeps its meaning however it is padded.
    let pad = String(repeating: " ", count: farPastTheCeiling)
    #expect(try PasteWordsParser.parse(pad + "Kubernetes") == ["Kubernetes"])
    #expect(try PasteWordsParser.parse("Kubernetes" + pad) == ["Kubernetes"])
    #expect(try PasteWordsParser.parse(pad + "Kubernetes" + pad) == ["Kubernetes"])
    #expect(
      try PasteWordsParser.parse(pad + "Claude Code" + pad + ",\n" + pad + "Anthropic")
        == ["Claude Code", "Anthropic"])
  }

  /// The ceiling still applies to real content, so relaxing the padding rule
  /// cannot become "no limit at all" — including when interior spacing is what
  /// carries the entry past it.
  @Test("a genuinely over-long entry is still refused")
  func overLongEntryStillThrows() throws {
    let tooLong = String(
      repeating: "x", count: CustomWordsImportLimits.maximumStoredValueScalars + 1)
    #expect(throws: (any Error).self) { try PasteWordsParser.parse(tooLong) }

    let spacedOut = (0...CustomWordsImportLimits.maximumStoredValueScalars)
      .map { _ in "x" }
      .joined(separator: " ")
    #expect(throws: (any Error).self) { try PasteWordsParser.parse(spacedOut) }
  }

  // MARK: - Deduplication

  @Test("a repeated word appears once, in its first spelling")
  func withinPasteDedupPreservesFirstSpelling() throws {
    #expect(try PasteWordsParser.parse("GitHub\ngithub\nGITHUB") == ["GitHub"])
  }

  @Test("dedup uses the same normalization the compare engine uses")
  func dedupMatchesCompareEngineNormalization() throws {
    // Both collapse to one key in the engine, so they must collapse here too;
    // otherwise the review screen would show two rows that persistence would
    // then refuse as duplicates.
    let parsed = try PasteWordsParser.parse("Claude Code\nClaude  Code")
    #expect(parsed == ["Claude Code"])
  }

  @Test("distinct words are all kept, in paste order")
  func distinctWordsKeepPasteOrder() throws {
    #expect(
      try PasteWordsParser.parse("Qualtrics\nKubernetes\nAnthropic")
        == ["Qualtrics", "Kubernetes", "Anthropic"])
  }

  // MARK: - Source contract

  @Test("the source produces candidates with no authority over any field")
  func sourceLeavesEveryAuthorityFieldUnspecified() async throws {
    let batch = try await PasteWordsImportSource(text: "Kubernetes").loadCandidates()
    let candidate = try #require(batch.candidates.first)

    // Pasted text carries no alias data and no opinions, so a Replace built
    // from it must never claim authority over a hand-tuned value.
    #expect(candidate.aliases == .unspecified)
    #expect(candidate.category == .unspecified)
    #expect(candidate.priority == .unspecified)
    #expect(candidate.forceReplace == .unspecified)
    #expect(candidate.caseSensitive == .unspecified)
    #expect(candidate.minSimilarityOverride == .unspecified)
    // v1 ships no on-device suggestions; the channel exists but stays empty.
    #expect(candidate.suggestedAliases.isEmpty)
  }

  @Test("the source reports a stable id and carries no notices in v1")
  func sourceReportsStableIdentityAndNoNotices() async throws {
    let batch = try await PasteWordsImportSource(text: "Kubernetes, Anthropic")
      .loadCandidates()
    #expect(batch.sourceID == "paste")
    #expect(batch.candidates.map(\.canonical) == ["Kubernetes", "Anthropic"])
    // Notices exist for the suggestion stage; with no AI call there is nothing
    // to report, and an empty list is the honest answer rather than a
    // placeholder notice.
    #expect(batch.notices.isEmpty)
  }

  @Test("empty pasted text produces an empty batch, not an error")
  func emptyTextProducesAnEmptyBatch() async throws {
    let batch = try await PasteWordsImportSource(text: "   \n  ").loadCandidates()
    #expect(batch.candidates.isEmpty)
  }

  @Test("each candidate gets its own identity")
  func candidatesHaveDistinctIdentities() async throws {
    let batch = try await PasteWordsImportSource(text: "Kubernetes\nAnthropic\nQualtrics")
      .loadCandidates()
    #expect(Set(batch.candidates.map(\.id)).count == 3)
  }
}
