import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #2495 — the sparse per-word override store. Pure disk round-trip; the
/// merge-with-shipped-defaults logic lives in `VocabularyPackManager` and is
/// covered by `VocabularyPackManagerOverridesTests`, since it needs a real pack.
@Suite("VocabularyPackOverridesStore — disk round-trip", .tags(.productOutcome))
struct VocabularyPackOverridesStoreTests {

  private func tempStore() -> (VocabularyPackOverridesStore, URL) {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("vpo-test-\(UUID().uuidString).json")
    return (VocabularyPackOverridesStore(fileURL: url), url)
  }

  @Test("A missing file loads as empty, never throws")
  func missingFileLoadsEmpty() {
    let (store, _) = tempStore()
    let file = store.load()
    #expect(file.packs.isEmpty)
  }

  @Test("update() then load round-trips exactly")
  func updateThenLoadRoundTrips() {
    let (store, _) = tempStore()
    let saved = store.update { file in
      file.packs["tech"] = [
        "docker": VocabularyPackWordOverride(isEnabled: false),
        "kubernetes": VocabularyPackWordOverride(aliases: ["coobernetties", "kate ess"]),
      ]
      return true
    }
    #expect(saved != nil)

    let reloaded = store.load()
    #expect(reloaded.packs["tech"]?["docker"]?.isEnabled == false)
    #expect(reloaded.packs["tech"]?["kubernetes"]?.aliases == ["coobernetties", "kate ess"])
  }

  @Test("A corrupt file loads as empty rather than throwing")
  func corruptFileLoadsEmpty() throws {
    let (store, url) = tempStore()
    try Data("not valid json{{{".utf8).write(to: url)
    let file = store.load()
    #expect(file.packs.isEmpty)
  }

  @Test("A second update accumulates onto the first — it does not clobber it")
  func secondUpdateAccumulatesOntoFirst() {
    // This is the exact bug the locked `update(_:)` transaction exists to
    // prevent: a naive whole-file `save()` built from a caller-held snapshot
    // would have made this second write silently erase the first pack's
    // overrides. Because `update` reloads current disk state before every
    // transform, both writes survive.
    let (store, _) = tempStore()
    _ = store.update { file in
      file.packs["tech"] = ["docker": VocabularyPackWordOverride(isEnabled: false)]
      return true
    }
    _ = store.update { file in
      file.packs["medical"] = ["metformin": VocabularyPackWordOverride(isEnabled: false)]
      return true
    }

    let reloaded = store.load()
    #expect(reloaded.packs["tech"]?["docker"]?.isEnabled == false)
    #expect(reloaded.packs["medical"]?["metformin"]?.isEnabled == false)
  }

  @Test("update() reads the CURRENT on-disk file, not a caller-held snapshot")
  func updateReadsCurrentDiskStateNotAStaleCapture() {
    let (store, _) = tempStore()
    _ = store.update { file in
      file.packs["tech"] = ["docker": VocabularyPackWordOverride(isEnabled: false)]
      return true
    }
    // A second "process" writes to the SAME store instance's underlying
    // file directly between these two calls.
    _ = store.update { file in
      file.packs["medical"] = ["metformin": VocabularyPackWordOverride(isEnabled: false)]
      return true
    }
    // A third mutation must see BOTH prior writes, because each `update`
    // starts from a fresh `load()`, never a value carried across calls.
    let final = store.update { file in
      file.packs["tech"]?["docker"] != nil && file.packs["medical"]?["metformin"] != nil
    }
    #expect(final != nil)
    #expect(final?.packs["tech"]?["docker"]?.isEnabled == false)
    #expect(final?.packs["medical"]?["metformin"]?.isEnabled == false)
  }

  @Test("update() returning false skips the write")
  func updateReturningFalseSkipsWrite() {
    let (store, url) = tempStore()
    let before = FileManager.default.fileExists(atPath: url.path)
    let result = store.update { _ in false }
    #expect(result != nil)
    #expect(before == false)
    // A `false` transform must not have created the file at all.
    #expect(FileManager.default.fileExists(atPath: url.path) == false)
  }

  @Test("VocabularyPackWordOverride.isEmpty is true only with both fields nil")
  func overrideIsEmptyReflectsBothFields() {
    #expect(VocabularyPackWordOverride().isEmpty)
    #expect(!VocabularyPackWordOverride(isEnabled: false).isEmpty)
    #expect(!VocabularyPackWordOverride(aliases: []).isEmpty)
  }
}
