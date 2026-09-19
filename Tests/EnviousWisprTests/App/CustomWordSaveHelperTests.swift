import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #996 §4: the shared save helper lifted from Quick Add. The Quick Add
/// entrypoint and the write-then-confirm keep their exact pre-lift behaviour
/// (the Quick Add suites are the regression oracle); `proposalTarget` is the
/// corrected-string entrypoint the proposal coordinator will use.
@MainActor
@Suite("CustomWordSaveHelper (#996)", .tags(.driftGuard))
struct CustomWordSaveHelperTests {
  typealias H = CustomWordSaveHelper

  private static func candidate(_ word: CustomWord) -> QuickAddRanker.Candidate {
    QuickAddRanker.Candidate(word: word, score: 1, alreadyHasHeardSpelling: false)
  }

  private static func isolatedCoordinator() -> CustomWordsCoordinator {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-save-helper-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return CustomWordsCoordinator(
      manager: CustomWordsManager(fileURL: dir.appendingPathComponent("custom-words.json")))
  }

  // MARK: quickAddTarget (Quick Add's resolver, unchanged)

  @Test(
    "a live user candidate resolves to the CURRENT entry, edits made while the panel sat open included"
  )
  func liveCandidateCarriesCurrentEntry() {
    let snapshot = CustomWord(canonical: "Codex", aliases: ["codecs"])
    let edited = CustomWord(
      id: snapshot.id, canonical: "Codex CLI", aliases: ["codecs", "kodex"], category: .brand)
    #expect(H.quickAddTarget(for: Self.candidate(snapshot), in: [edited]) == .live(edited))
  }

  @Test("a deleted user candidate is gone, even when another word now reuses its canonical")
  func deletedCandidateStaysRefused() {
    let deleted = CustomWord(canonical: "Codex")
    let impostor = CustomWord(canonical: "Codex")
    #expect(H.quickAddTarget(for: Self.candidate(deleted), in: [impostor]) == .gone)
    #expect(H.quickAddTarget(for: Self.candidate(deleted), in: []) == .gone)
  }

  @Test(
    "a pack candidate resolves live by id first, then by canonical, then converts to an override")
  func packCandidateOrder() {
    let pack = CustomWord(canonical: "Kubernetes", source: .pack)
    // Overridden while open: same id now lives in the user library.
    let overridden = CustomWord(
      id: pack.id, canonical: "Kubernetes", aliases: ["cube"], source: .user)
    #expect(H.quickAddTarget(for: Self.candidate(pack), in: [overridden]) == .live(overridden))
    // Same canonical under a DIFFERENT id: merge into the user's own entry.
    let sameName = CustomWord(canonical: "kubernetes", aliases: ["k8s"])
    #expect(H.quickAddTarget(for: Self.candidate(pack), in: [sameName]) == .live(sameName))
    // Nothing in the user library: a user-owned override keeping the pack's id.
    guard case .override(let converted) = H.quickAddTarget(for: Self.candidate(pack), in: []) else {
      Issue.record("expected override")
      return
    }
    #expect(
      converted.id == pack.id && converted.source == .user && converted.canonical == "Kubernetes")
  }

  // MARK: proposalTarget (the corrected-string entrypoint)

  @Test(
    "proposalTarget: user canonical first, then enabled pack term as an override, else new; no id minted"
  )
  func proposalTargetOrder() {
    let user = CustomWord(canonical: "Saira", aliases: ["sarah"])
    let pack = CustomWord(canonical: "saira", source: .pack)
    #expect(H.proposalTarget(for: "saira", in: [user], packTerms: [pack]) == .existing(user))
    #expect(H.proposalTarget(for: " Saira ", in: [user], packTerms: []) == .existing(user))
    guard
      case .packOverride(let converted) = H.proposalTarget(for: "SAIRA", in: [], packTerms: [pack])
    else {
      Issue.record("expected packOverride")
      return
    }
    #expect(converted.id == pack.id && converted.source == .user)
    #expect(H.proposalTarget(for: "Sairah", in: [user], packTerms: [pack]) == .new)
    #expect(H.proposalTarget(for: "", in: [user], packTerms: [pack]) == .new)
  }

  @Test("proposalTarget matches the filter's normalisation: NFC and casefold, never aliases")
  func proposalTargetNormalisation() {
    let user = CustomWord(canonical: "Müller", aliases: ["mueller"])
    // Decomposed spelling of the same name.
    #expect(H.proposalTarget(for: "Mu\u{0308}ller", in: [user], packTerms: []) == .existing(user))
    // An alias is not a canonical: the corrected spelling must be the word itself.
    #expect(H.proposalTarget(for: "mueller", in: [user], packTerms: []) == .new)
  }

  // MARK: saveAndConfirm (write, then prove the spelling landed)
  //
  // A fresh manager seeds the built-in defaults, so counts are read against
  // that baseline and words are found by id, never by position.

  private static func word(_ id: UUID, in coordinator: CustomWordsCoordinator) -> CustomWord? {
    coordinator.customWords.first { $0.id == id }
  }

  @Test("a new word is added, an existing one updated, and nil is returned only when the spelling is on the word")
  func saveRoutesAndConfirms() {
    let coordinator = Self.isolatedCoordinator()
    let baseline = coordinator.customWords.count
    let word = CustomWord(canonical: "Saira", aliases: ["sarah"])
    #expect(H.saveAndConfirm(word, carrying: " sarah ", through: coordinator) == nil)
    #expect(coordinator.customWords.count == baseline + 1)
    #expect(Self.word(word.id, in: coordinator)?.aliases == ["sarah"])

    var updated = word
    updated.aliases.append("sara")
    #expect(H.saveAndConfirm(updated, carrying: "sara", through: coordinator) == nil)
    #expect(coordinator.customWords.count == baseline + 1, "update, not a second add")
    #expect(Self.word(word.id, in: coordinator)?.aliases == ["sarah", "sara"])
  }

  @Test("a refusal from the coordinator is propagated as its message")
  func refusalPropagates() {
    let coordinator = Self.isolatedCoordinator()
    let baseline = coordinator.customWords.count
    let tooLong = CustomWord(canonical: String(repeating: "x", count: 600))
    let message = H.saveAndConfirm(tooLong, carrying: "x", through: coordinator)
    #expect(message != nil)
    #expect(coordinator.customWords.count == baseline && Self.word(tooLong.id, in: coordinator) == nil)
  }

  @Test("a silent non-write is caught by the landed check: the spelling is not on the word, so the save is reported as not saved")
  func silentNonWriteIsReported() {
    let coordinator = Self.isolatedCoordinator()
    let existing = CustomWord(canonical: "Codex")
    #expect(coordinator.add(existing) == nil)
    let baseline = coordinator.customWords.count
    // Same canonical under a new id: `add` refuses silently (returns nil) and
    // writes nothing, so the spelling never lands and the helper says so.
    let twin = CustomWord(canonical: "Codex", aliases: ["kodex"])
    let message = H.saveAndConfirm(twin, carrying: "kodex", through: coordinator)
    #expect(message == QuickAddPanelCopy.newWordNotSaved)
    #expect(coordinator.customWords.count == baseline)
    #expect(Self.word(existing.id, in: coordinator)?.aliases == [])
    #expect(Self.word(twin.id, in: coordinator) == nil)
  }
}
