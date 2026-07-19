import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #1680 (PR-E1) — the portable backup format and its writer.
@MainActor
@Suite("CustomWordsTransferDocument")
struct CustomWordsTransferDocumentTests {

  private func word(
    _ canonical: String,
    aliases: [String] = [],
    category: WordCategory = .general,
    priority: Int = 0,
    forceReplace: Bool = false,
    caseSensitive: Bool = false,
    source: WordSource = .user,
    frequencyUsed: Int = 0,
    lastUsed: Date? = nil,
    minSimilarityOverride: Double? = nil
  ) -> CustomWord {
    CustomWord(
      canonical: canonical, aliases: aliases, category: category, priority: priority,
      forceReplace: forceReplace, caseSensitive: caseSensitive, source: source,
      frequencyUsed: frequencyUsed, lastUsed: lastUsed,
      minSimilarityOverride: minSimilarityOverride)
  }

  // MARK: - Round trip

  @Test("every portable field survives an export and re-decode")
  func exportRoundTripPreservesEveryPortableField() throws {
    let original = word(
      "Kubernetes", aliases: ["k8s", "kube"], category: .brand, priority: 3,
      forceReplace: true, caseSensitive: true, minSimilarityOverride: 0.8)
    let data = try CustomWordsTransferDocument(words: [original]).encoded()
    let decoded = try CustomWordsTransferDocument(data: data)

    let restored = try #require(decoded.words.first)
    #expect(restored.canonical == "Kubernetes")
    #expect(restored.aliases == ["k8s", "kube"])
    #expect(restored.category == .brand)
    #expect(restored.priority == 3)
    #expect(restored.forceReplace == true)
    #expect(restored.caseSensitive == true)
    #expect(restored.minSimilarityOverride == 0.8)
    #expect(restored.id == original.id)
  }

  @Test("usage history never leaves this Mac")
  func exportOmitsUsageHistoryAndRuntimeSource() throws {
    let used = word("Kubernetes", frequencyUsed: 42, lastUsed: Date(timeIntervalSince1970: 1))
    let data = try CustomWordsTransferDocument(words: [used]).encoded()
    let json = try #require(String(data: data, encoding: .utf8))

    #expect(!json.contains("frequencyUsed"))
    #expect(!json.contains("lastUsed"))
    #expect(!json.contains("source"))
  }

  @Test("an empty word list is a valid backup, not an error")
  func emptyWordListIsAValidBackup() throws {
    let data = try CustomWordsTransferDocument(words: []).encoded()
    let decoded = try CustomWordsTransferDocument(data: data)
    #expect(decoded.words.isEmpty)
    #expect(decoded.format == CustomWordsTransferDocument.formatIdentifier)
    #expect(decoded.version == CustomWordsTransferDocument.currentVersion)
  }

  // MARK: - Decode rejection

  @Test("a JSON file that isn't ours is rejected by name, not called damaged")
  func decoderRejectsWrongFormatIdentifier() throws {
    let foreign = Data(#"{"format":"com.example.other","version":1,"words":[]}"#.utf8)
    #expect(throws: CustomWordsTransferError.notAnEnviousWisprBackup) {
      _ = try CustomWordsTransferDocument(data: foreign)
    }
  }

  @Test("a backup from a newer app version is refused rather than guessed at")
  func decoderRejectsUnsupportedFutureVersion() throws {
    let future = Data(
      #"{"format":"com.enviouswispr.custom-words","version":99,"words":[]}"#.utf8)
    #expect(throws: CustomWordsTransferError.unsupportedVersion(99)) {
      _ = try CustomWordsTransferDocument(data: future)
    }
  }

  @Test("a version below the first supported format is refused")
  func decoderRejectsVersionBelowTheFirstSupportedFormat() throws {
    // Version 1 is the first format; nothing earlier ever existed, so a file
    // claiming 0 is malformed or tampered rather than merely old (review r2).
    let ancient = Data(
      #"{"format":"com.enviouswispr.custom-words","version":0,"words":[]}"#.utf8)
    #expect(throws: CustomWordsTransferError.unsupportedVersion(0)) {
      _ = try CustomWordsTransferDocument(data: ancient)
    }
  }

  @Test("a future version is reported as newer, not as damaged")
  func futureVersionWithUnknownPayloadReportsVersionNotDamage() throws {
    // The header is judged before the payload (review r3), so a future format
    // that changed a word field still gets the honest "update the app"
    // message instead of "your backup is damaged".
    let future = Data(
      """
      {"format":"com.enviouswispr.custom-words","version":99,
       "words":[{"somethingNew":true}]}
      """.utf8)
    #expect(throws: CustomWordsTransferError.unsupportedVersion(99)) {
      _ = try CustomWordsTransferDocument(data: future)
    }
  }

  @Test("damaged bytes read as damaged")
  func decoderRejectsMalformedData() throws {
    #expect(throws: CustomWordsTransferError.malformed) {
      _ = try CustomWordsTransferDocument(data: Data("not json at all {{{".utf8))
    }
  }

  // MARK: - Import handoff

  @Test("candidates supply all six authority fields, including both clears")
  func candidatesForImportSupplyAllSixAuthorityFieldsIncludingClears() throws {
    // A word with no aliases and no per-term strictness. Backup is the only
    // source that can say "genuinely none" rather than "no opinion", and on a
    // Replace that difference decides whether hand-tuned values are cleared.
    let bare = word("Kubernetes", aliases: [], minSimilarityOverride: nil)
    let candidates = CustomWordsTransferDocument(words: [bare]).candidatesForImport()
    let candidate = try #require(candidates.first)

    #expect(candidate.aliases == .supplied([]))
    #expect(candidate.minSimilarityOverride == .supplied(nil))
    #expect(candidate.category == .supplied(.general))
    #expect(candidate.priority == .supplied(0))
    #expect(candidate.forceReplace == .supplied(false))
    #expect(candidate.caseSensitive == .supplied(false))
  }

  @Test("candidates carry no usage history and no AI suggestions")
  func candidatesForImportResetsUsageHistory() throws {
    let used = word("Kubernetes", frequencyUsed: 9, lastUsed: Date())
    let candidate = try #require(
      CustomWordsTransferDocument(words: [used]).candidatesForImport().first)
    // The candidate type structurally cannot carry usage history; this asserts
    // the suggestion channel is also empty, so nothing machine-generated rides
    // in on a restore.
    #expect(candidate.suggestedAliases.isEmpty)
  }

  @Test("a candidate never carries the exported persistence id")
  func candidatesForImportMintsFreshReviewIdentities() throws {
    let original = word("Kubernetes")
    let data = try CustomWordsTransferDocument(words: [original]).encoded()
    let candidate = try #require(
      try CustomWordsTransferDocument(data: data).candidatesForImport().first)

    // Restoring onto the Mac that wrote the backup would otherwise make the
    // candidate id equal the live word's id, and the collision detector would
    // report each word's own aliases as colliding with itself (code review).
    #expect(candidate.id != original.id)
  }

  @Test("two candidates from one backup have distinct review identities")
  func candidatesForImportGivesEachRowItsOwnIdentity() throws {
    let candidates = CustomWordsTransferDocument(
      words: [word("Kubernetes"), word("Anthropic")]
    ).candidatesForImport()
    #expect(Set(candidates.map(\.id)).count == 2)
  }

  // MARK: - Built-in tagging (the export-scope prerequisite)

  @Test("every built-in is constructed tagged as built-in")
  func builtinDefaultsAreAllConstructedWithBuiltinSource() {
    #expect(CustomWordsManager.builtinDefaults.isEmpty == false)
    for builtin in CustomWordsManager.builtinDefaults {
      #expect(
        builtin.word.source == .builtin,
        "built-in '\(builtin.id)' is untagged and would export as a user word")
    }
  }

  @Test("re-tagging a built-in as user-owned preserves every other field")
  func ownedByUserPreservesEveryOtherField() {
    let builtin = word(
      "GitHub", aliases: ["git hub"], category: .brand, priority: 2,
      forceReplace: true, caseSensitive: true, source: .builtin,
      frequencyUsed: 7, lastUsed: Date(timeIntervalSince1970: 5),
      minSimilarityOverride: 0.9)
    let owned = builtin.ownedByUser()

    #expect(owned.source == .user)
    #expect(owned.id == builtin.id)
    #expect(owned.canonical == builtin.canonical)
    #expect(owned.aliases == builtin.aliases)
    #expect(owned.category == builtin.category)
    #expect(owned.priority == builtin.priority)
    #expect(owned.forceReplace == builtin.forceReplace)
    #expect(owned.caseSensitive == builtin.caseSensitive)
    #expect(owned.frequencyUsed == builtin.frequencyUsed)
    #expect(owned.lastUsed == builtin.lastUsed)
    #expect(owned.minSimilarityOverride == builtin.minSimilarityOverride)
  }

  @Test("re-tagging an already-user word returns it unchanged")
  func ownedByUserIsANoOpForUserWords() {
    let user = word("Kubernetes", source: .user)
    #expect(user.ownedByUser() == user)
  }
}
