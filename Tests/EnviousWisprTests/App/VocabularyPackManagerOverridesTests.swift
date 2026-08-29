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
}
