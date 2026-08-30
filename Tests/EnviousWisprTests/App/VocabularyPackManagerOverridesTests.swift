import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2495 — per-word pack overrides (toggle, alias edit, restore), against the
/// REAL bundled Tech pack rather than a fake one. `VocabularyPackManager` has
/// no injectable pack store seam and none is warranted here: overlaying
/// overrides onto whatever the pack actually ships is exactly the behavior
/// worth proving, and the real pack is small and stable.
@Suite("VocabularyPackManager — per-word overrides (#2495)", .tags(.productOutcome))
@MainActor
struct VocabularyPackManagerOverridesTests {

  private func makeManager() -> (VocabularyPackManager, String) {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("vpo-mgr-test-\(UUID().uuidString).json")
    let manager = VocabularyPackManager(overridesStore: VocabularyPackOverridesStore(fileURL: url))
    manager.setEnabled(.tech, true)
    guard let firstWord = manager.packWords(.tech).first else {
      Issue.record("Tech pack loaded no words — bundle problem")
      return (manager, "")
    }
    return (manager, firstWord.canonical)
  }

  @Test("An untouched word is enabled, unedited, and shows its shipped aliases")
  func untouchedWordIsUnedited() {
    let (manager, canonical) = makeManager()
    let word = manager.packWords(.tech).first { $0.canonical == canonical }
    #expect(word?.isEnabled == true)
    #expect(word?.isEdited == false)
    #expect(word?.aliases == word?.shippedAliases)
  }

  @Test("Disabling a word marks it disabled and edited, without touching its aliases")
  func disablingMarksEditedWithoutTouchingAliases() {
    let (manager, canonical) = makeManager()
    let before = manager.packWords(.tech).first { $0.canonical == canonical }!

    manager.setWordEnabled(.tech, canonical: canonical, enabled: false)

    let after = manager.packWords(.tech).first { $0.canonical == canonical }!
    #expect(after.isEnabled == false)
    #expect(after.isEdited == true)
    #expect(after.aliases == before.aliases)
  }

  @Test("Disabled words are dropped from enabledPackTerms, but stay listed in packWords")
  func disabledWordDroppedFromCorrectionLaneNotFromTheList() {
    let (manager, canonical) = makeManager()
    manager.setWordEnabled(.tech, canonical: canonical, enabled: false)

    #expect(!manager.enabledPackTerms().contains { $0.canonical == canonical })
    #expect(manager.packWords(.tech).contains { $0.canonical == canonical })
  }

  @Test("Editing aliases replaces the effective list and reaches enabledPackTerms")
  func editingAliasesReachesCorrectionLane() {
    let (manager, canonical) = makeManager()
    let newAliases = ["a totally new mishearing"]

    manager.setWordAliases(.tech, canonical: canonical, aliases: newAliases)

    let word = manager.packWords(.tech).first { $0.canonical == canonical }!
    #expect(word.aliases == newAliases)
    #expect(word.isEdited == true)
    let corrected = manager.enabledPackTerms().first { $0.canonical == canonical }
    #expect(corrected?.aliases == newAliases)
  }

  @Test("Restore clears BOTH the enabled and alias overrides in one action")
  func restoreClearsBothOverrides() {
    let (manager, canonical) = makeManager()
    let shipped = manager.packWords(.tech).first { $0.canonical == canonical }!.shippedAliases
    manager.setWordEnabled(.tech, canonical: canonical, enabled: false)
    manager.setWordAliases(.tech, canonical: canonical, aliases: ["edited alias"])

    manager.restoreWord(.tech, canonical: canonical)

    let word = manager.packWords(.tech).first { $0.canonical == canonical }!
    #expect(word.isEnabled == true)
    #expect(word.isEdited == false)
    #expect(word.aliases == shipped)
  }

  @Test("Overrides persist across a fresh manager reading the same file")
  func overridesPersistAcrossRelaunch() {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("vpo-mgr-persist-\(UUID().uuidString).json")
    let first = VocabularyPackManager(overridesStore: VocabularyPackOverridesStore(fileURL: url))
    first.setEnabled(.tech, true)
    guard let canonical = first.packWords(.tech).first?.canonical else {
      Issue.record("Tech pack loaded no words — bundle problem")
      return
    }
    first.setWordEnabled(.tech, canonical: canonical, enabled: false)

    let second = VocabularyPackManager(overridesStore: VocabularyPackOverridesStore(fileURL: url))
    let word = second.packWords(.tech).first { $0.canonical == canonical }
    #expect(word?.isEnabled == false)
  }

  @Test("Overrides are scoped per pack — a word disabled in one pack stays untouched in another")
  func overridesAreScopedPerPack() {
    let (manager, techCanonical) = makeManager()
    manager.setEnabled(.medical, true)
    guard let medicalCanonical = manager.packWords(.medical).first?.canonical else {
      Issue.record("Medical pack loaded no words — bundle problem")
      return
    }

    manager.setWordEnabled(.tech, canonical: techCanonical, enabled: false)

    let medicalWord = manager.packWords(.medical).first { $0.canonical == medicalCanonical }
    #expect(medicalWord?.isEnabled == true)
    #expect(medicalWord?.isEdited == false)
  }

  @Test("An override affects only one of two packs carrying the same canonical")
  func duplicateCanonicalOverridesStayPackScoped() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("vpo-mgr-duplicate-\(UUID().uuidString).json")
    let manager = VocabularyPackManager(overridesStore: VocabularyPackOverridesStore(fileURL: url))
    manager.setEnabled(.tech, true)
    manager.setEnabled(.brands, true)

    // "OpenAI" ships in both the real Tech and Brands packs — the exact
    // shape the corrector's own duplicate-canonical test (VocabularyPackTests
    // "duplicate pack canonicals across packs do NOT self-compete") exists for.
    let techWord = try #require(
      manager.packWords(.tech).first {
        $0.canonical.caseInsensitiveCompare("OpenAI") == .orderedSame
      }
    )
    let brandsWord = try #require(
      manager.packWords(.brands).first {
        $0.canonical.caseInsensitiveCompare("OpenAI") == .orderedSame
      })

    manager.setWordAliases(.tech, canonical: techWord.canonical, aliases: ["tech-only alias"])

    var matching = manager.enabledPackTerms().filter {
      $0.canonical.caseInsensitiveCompare("OpenAI") == .orderedSame
    }
    #expect(matching.count == 2)
    #expect(matching.first { $0.id == techWord.id }?.aliases == ["tech-only alias"])
    #expect(matching.first { $0.id == brandsWord.id }?.aliases == brandsWord.aliases)

    manager.setWordEnabled(.tech, canonical: techWord.canonical, enabled: false)

    matching = manager.enabledPackTerms().filter {
      $0.canonical.caseInsensitiveCompare("OpenAI") == .orderedSame
    }
    #expect(matching.map(\.id) == [brandsWord.id])
  }

  @Test("Returning aliases to the shipped list clears the edited state")
  func returningToShippedAliasesClearsEditedState() {
    let (manager, canonical) = makeManager()
    let shipped = manager.packWords(.tech).first { $0.canonical == canonical }!.shippedAliases

    manager.setWordAliases(.tech, canonical: canonical, aliases: shipped + ["temporary alias"])
    manager.setWordAliases(.tech, canonical: canonical, aliases: shipped)

    let word = manager.packWords(.tech).first { $0.canonical == canonical }
    #expect(word?.aliases == shipped)
    #expect(word?.isEdited == false)
  }

  @Test("Restoring a word that was never edited is a no-op, not an error")
  func restoringUneditedWordIsNoOp() {
    let (manager, canonical) = makeManager()
    manager.restoreWord(.tech, canonical: canonical)
    let word = manager.packWords(.tech).first { $0.canonical == canonical }
    #expect(word?.isEnabled == true)
    #expect(word?.isEdited == false)
    #expect(manager.persistenceError == nil)
  }

  // MARK: - Memoization (2026-08-29)
  //
  // `packWords` is now cached per pack, because the detail screen calls it from
  // inside `body` and its search box filters the result — so every keystroke
  // was rebuilding and re-sorting every row in the pack. The risk a cache adds
  // is showing a STALE row after an edit, which is what these bind.

  @Test("An edit is visible in the very next read — the row cache cannot go stale")
  func packWordsReflectsAnEditImmediately() {
    let (manager, canonical) = makeManager()
    // Prime the cache first. Without this read the test would pass against a
    // cache that never populated, which is not the thing being checked.
    let primed = manager.packWords(.tech).first { $0.canonical == canonical }!
    #expect(primed.isEnabled == true)

    manager.setWordEnabled(.tech, canonical: canonical, enabled: false)

    let after = manager.packWords(.tech).first { $0.canonical == canonical }!
    #expect(after.isEnabled == false, "a cached row survived an edit that should have cleared it")
  }

  @Test("Editing one pack does not leave another pack's cached rows stale")
  func editingOnePackDoesNotStrandAnother() {
    let (manager, canonical) = makeManager()
    // Prime BOTH packs, then edit only Tech. Medical's rows must still be
    // correct afterwards — this fails if invalidation is keyed too narrowly
    // AND if it is keyed too widely in a way that drops correctness.
    let medicalBefore = manager.packWords(.medical)
    #expect(medicalBefore.isEmpty == false)

    manager.setWordEnabled(.tech, canonical: canonical, enabled: false)

    let medicalAfter = manager.packWords(.medical)
    #expect(medicalAfter.map(\.canonical) == medicalBefore.map(\.canonical))
    #expect(
      medicalAfter.allSatisfy { $0.isEnabled }, "an unrelated pack was altered by a Tech edit")
  }

  // MARK: - Display order is separate from stored order
  //
  // `displayAliases` is sorted for the chip row; `aliases` keeps its stored
  // order because `setWordAliases` compares it against the shipped array to
  // decide whether an edit has returned to the default. Sorting the wrong one
  // makes a word read EDITED forever after an add-then-remove round trip.

  @Test("displayAliases is sorted while aliases keeps its stored order")
  func displayOrderIsSeparateFromStoredOrder() {
    let (manager, _) = makeManager()
    // Pick a word with enough aliases for order to be observable at all.
    guard let word = manager.packWords(.tech).first(where: { $0.aliases.count > 1 }) else {
      Issue.record("Tech pack has no word with two or more aliases — fixture assumption broken")
      return
    }
    let expected = word.aliases.sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
    #expect(word.displayAliases == expected)
    #expect(Set(word.displayAliases) == Set(word.aliases), "display dropped or invented an alias")
  }

  @Test("Add then remove the same alias returns the word to unedited")
  func addThenRemoveReturnsToUnedited() {
    let (manager, canonical) = makeManager()
    let before = manager.packWords(.tech).first { $0.canonical == canonical }!
    #expect(before.isEdited == false)

    manager.setWordAliases(.tech, canonical: canonical, aliases: before.aliases + ["zzz probe"])
    manager.setWordAliases(.tech, canonical: canonical, aliases: before.aliases)

    let after = manager.packWords(.tech).first { $0.canonical == canonical }!
    #expect(
      after.isEdited == false,
      "the word stayed marked edited — the stored alias order was not preserved")
  }

  // MARK: - Merged pack metadata

  @Test("summary reports the shipped pack size and its first examples")
  func summaryMatchesTheShippedPack() {
    let (manager, _) = makeManager()
    let summary = manager.summary(.tech)
    #expect(summary.termCount == manager.packWords(.tech).count)
    #expect(summary.termCount == manager.termCount(.tech))
    #expect(summary.examples.count <= 3)
    #expect(summary.examples == summary.examples.sorted())
    // Repeating the call must not change the answer — it is memoized.
    #expect(manager.summary(.tech) == summary)
    // The example count is a constant, so a call that arrives AFTER
    // `termCount` primed the memo still sees the full set. This is the shape
    // the cloud review caught while `summary` still took an `exampleLimit`
    // the memo was not keyed on.
    _ = manager.termCount(.medical)
    #expect(manager.summary(.medical).examples.count == min(3, manager.packWords(.medical).count))
  }
}
