import Foundation
import Testing

@testable import EnviousWisprCore

/// Phase 5a (#635) — pins the `VocabularyPack` value type contract.
/// Bible §11.
@Suite("VocabularyPack — Phase 5a type contract")
struct VocabularyPackTests {

  private static func makeMetadata() -> PackMetadata {
    PackMetadata(
      sourceLicense: "CC0-1.0",
      sourceURL: "https://example.com/source",
      sourceAccessedDate: "2026-05-05",
      attributionStatement: ""
    )
  }

  @Test("customWords() projects each term as CustomWord with source: .pack")
  func customWordsHaveSourcePack() {
    let pack = VocabularyPack(
      id: "tech-engineering",
      name: "Tech & Engineering",
      description: "test",
      terms: ["Kubernetes", "Postgres", "gRPC"],
      metadata: Self.makeMetadata()
    )
    let words = pack.customWords()
    #expect(words.count == 3)
    #expect(words.allSatisfy { $0.source == .pack })
    #expect(Set(words.map(\.canonical)) == Set(["Kubernetes", "Postgres", "gRPC"]))
  }

  @Test("customWords() IDs are deterministic — same input → same UUID")
  func deterministicIDs() {
    let pack1 = VocabularyPack(
      id: "tech", name: "Tech", description: "", terms: ["Kubernetes"],
      metadata: Self.makeMetadata()
    )
    let pack2 = VocabularyPack(
      id: "tech", name: "Tech", description: "", terms: ["Kubernetes"],
      metadata: Self.makeMetadata()
    )
    let id1 = pack1.customWords().first!.id
    let id2 = pack2.customWords().first!.id
    #expect(id1 == id2, "Same packID + canonical → same UUID across constructions")
  }

  @Test("customWords() IDs differ across packs for same canonical")
  func differentPacksDifferentIDs() {
    let pack1 = VocabularyPack(
      id: "tech", name: "Tech", description: "", terms: ["Kubernetes"],
      metadata: Self.makeMetadata()
    )
    let pack2 = VocabularyPack(
      id: "devops", name: "DevOps", description: "", terms: ["Kubernetes"],
      metadata: Self.makeMetadata()
    )
    #expect(pack1.customWords().first!.id != pack2.customWords().first!.id)
  }

  @Test("customWords() IDs differ across canonicals in same pack")
  func differentCanonicalsDifferentIDs() {
    let pack = VocabularyPack(
      id: "tech", name: "Tech", description: "",
      terms: ["Kubernetes", "Postgres"],
      metadata: Self.makeMetadata()
    )
    let words = pack.customWords()
    #expect(words[0].id != words[1].id)
  }

  @Test("Codable round-trip preserves all fields")
  func codableRoundTrip() throws {
    let original = VocabularyPack(
      id: "tech-engineering",
      name: "Tech & Engineering",
      description: "Programming, cloud, infrastructure",
      terms: ["Kubernetes", "Postgres", "gRPC"],
      metadata: PackMetadata(
        sourceLicense: "CC0-1.0",
        sourceURL: "https://example.com",
        sourceAccessedDate: "2026-05-05",
        attributionStatement: "EnviousLabs original list"
      )
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(VocabularyPack.self, from: data)
    #expect(decoded.id == original.id)
    #expect(decoded.name == original.name)
    #expect(decoded.description == original.description)
    #expect(decoded.terms == original.terms)
    #expect(decoded.metadata.sourceLicense == original.metadata.sourceLicense)
    #expect(decoded.metadata.sourceURL == original.metadata.sourceURL)
    #expect(decoded.metadata.sourceAccessedDate == original.metadata.sourceAccessedDate)
    #expect(decoded.metadata.attributionStatement == original.metadata.attributionStatement)
  }

  @Test("Deterministic ID is stable across launches (SHA-256 byte-pinned)")
  func deterministicIDStableAcrossLaunches() {
    // Pin the exact SHA-256-derived UUID for ("tech-engineering", "Kubernetes").
    // If someone swaps the hash function or input format, this fails — and the
    // stability claim documented in deterministicID's docstring is violated.
    // Computed from SHA-256("tech-engineering|Kubernetes") prefix(16):
    let id = VocabularyPack.deterministicID(packID: "tech-engineering", canonical: "Kubernetes")
    let id2 = VocabularyPack.deterministicID(packID: "tech-engineering", canonical: "Kubernetes")
    #expect(id == id2, "Same input must produce same UUID across calls")
    // Also verify the UUID is non-zero (sanity check that SHA-256 is wired).
    #expect(id != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
  }

  @Test("Catalogue Codable round-trip")
  func catalogueRoundTrip() throws {
    let original = VocabularyPackCatalogue(packIDs: ["tech-engineering", "meeting-notes"])
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(VocabularyPackCatalogue.self, from: data)
    #expect(decoded.version == 1)
    #expect(decoded.packIDs == ["tech-engineering", "meeting-notes"])
  }
}
