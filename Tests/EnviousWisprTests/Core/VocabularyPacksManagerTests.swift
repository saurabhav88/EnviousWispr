import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// Phase 5a (#635) — pins the `VocabularyPacksManager` skeleton.
/// Bible §11.
@MainActor
@Suite("VocabularyPacksManager — Phase 5a skeleton")
struct VocabularyPacksManagerTests {

  private static func makeMetadata() -> PackMetadata {
    PackMetadata(
      sourceLicense: "CC0-1.0",
      sourceURL: "https://example.com",
      sourceAccessedDate: "2026-05-05",
      attributionStatement: ""
    )
  }

  private static func makePack(id: String, terms: [String]) -> VocabularyPack {
    VocabularyPack(id: id, name: id, description: "", terms: terms, metadata: makeMetadata())
  }

  @Test("Empty default init yields empty available + installed")
  func emptyDefault() {
    let manager = VocabularyPacksManager()
    #expect(manager.availablePacks.isEmpty)
    #expect(manager.installedPackIDs.isEmpty)
    #expect(manager.installedTerms().isEmpty)
  }

  @Test("Test-init exposes injected packs")
  func testInitExposesPacks() {
    let pack = Self.makePack(id: "tech", terms: ["Kubernetes"])
    let manager = VocabularyPacksManager(availablePacks: [pack])
    #expect(manager.availablePacks.count == 1)
    #expect(manager.pack(id: "tech")?.terms == ["Kubernetes"])
  }

  @Test("install adds to installed set")
  func installAdds() {
    let pack = Self.makePack(id: "tech", terms: ["Kubernetes"])
    let manager = VocabularyPacksManager(availablePacks: [pack])
    manager.install("tech")
    #expect(manager.isInstalled("tech"))
    #expect(manager.installedPackIDs == ["tech"])
  }

  @Test("install is no-op for unknown pack ID")
  func installUnknownNoOp() {
    let manager = VocabularyPacksManager(availablePacks: [])
    manager.install("nonexistent")
    #expect(manager.installedPackIDs.isEmpty)
  }

  @Test("install is idempotent")
  func installIdempotent() {
    let pack = Self.makePack(id: "tech", terms: ["Kubernetes"])
    let manager = VocabularyPacksManager(availablePacks: [pack])
    manager.install("tech")
    manager.install("tech")
    #expect(manager.installedPackIDs.count == 1)
  }

  @Test("uninstall removes from installed set")
  func uninstallRemoves() {
    let pack = Self.makePack(id: "tech", terms: ["Kubernetes"])
    let manager = VocabularyPacksManager(availablePacks: [pack], installedPackIDs: ["tech"])
    manager.uninstall("tech")
    #expect(!manager.isInstalled("tech"))
  }

  @Test("uninstall is no-op when not installed")
  func uninstallNotInstalled() {
    let manager = VocabularyPacksManager(availablePacks: [])
    manager.uninstall("tech")  // no crash
    #expect(manager.installedPackIDs.isEmpty)
  }

  @Test("installedTerms() returns merged customWords from installed packs only")
  func installedTermsMerged() {
    let tech = Self.makePack(id: "tech", terms: ["Kubernetes", "Postgres"])
    let medical = Self.makePack(id: "medical", terms: ["Acetaminophen"])
    let manager = VocabularyPacksManager(
      availablePacks: [tech, medical],
      installedPackIDs: ["tech"]
    )
    let terms = manager.installedTerms()
    #expect(terms.count == 2)
    #expect(terms.allSatisfy { $0.source == .pack })
    let canonicals = Set(terms.map(\.canonical))
    #expect(canonicals == ["Kubernetes", "Postgres"])
    #expect(!canonicals.contains("Acetaminophen"))
  }

  @Test("onInstalledPacksChanged fires on install")
  func callbackFiresOnInstall() {
    let pack = Self.makePack(id: "tech", terms: ["Kubernetes"])
    let manager = VocabularyPacksManager(availablePacks: [pack])
    var fired = 0
    manager.onInstalledPacksChanged = { fired += 1 }
    manager.install("tech")
    #expect(fired == 1)
    manager.install("tech")  // idempotent
    #expect(fired == 1, "No callback on no-op install")
  }

  @Test("onInstalledPacksChanged fires on uninstall")
  func callbackFiresOnUninstall() {
    let pack = Self.makePack(id: "tech", terms: ["Kubernetes"])
    let manager = VocabularyPacksManager(
      availablePacks: [pack], installedPackIDs: ["tech"]
    )
    var fired = 0
    manager.onInstalledPacksChanged = { fired += 1 }
    manager.uninstall("tech")
    #expect(fired == 1)
    manager.uninstall("tech")  // already uninstalled
    #expect(fired == 1)
  }
}
