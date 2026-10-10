import Foundation
import Testing

@testable import EnviousWisprModelDelivery

/// Contract §4d (v1.5, #3546): a File may declare ordered transport `parts`, and a
/// source may declare `servesParts`. When this fails, a user's model download either
/// admits a malformed delivery plan or refuses a valid one.
@Suite(.tags(.productOutcome))
struct DeliveryManifestPartsTests {

  private static let hexA = String(repeating: "a", count: 64)
  private static let hexB = String(repeating: "b", count: 64)

  /// A one-file manifest whose single file claims `size` bytes, with `parts` attached
  /// to it and `servesParts` on `our_copy`. Sizes are declared, not backed by bytes:
  /// structure is checked here, never content.
  private static func manifestJSON(
    size: Int64 = 10,
    parts: [PartSpec]?,
    servesParts: Bool? = true,
    asOptional: Bool = false
  ) throws -> Data {
    try ManifestFixture.manifestJSON(files: [("weights.bin", Data("x".utf8), "weights.bin")]) {
      object in
      var file = (object["files"] as! [[String: Any]])[0]
      file["sizeBytes"] = size
      if let parts { file["parts"] = parts.map(\.json) }
      if asOptional {
        let carrier: [String: Any] = [
          "path": "carrier.bin", "sizeBytes": 1, "sha256": hexB, "component": "carrier.bin",
        ]
        object["files"] = [carrier]
        object["optionalFiles"] = [file]
        object["totalBytes"] = 1
      } else {
        object["files"] = [file]
        object["totalBytes"] = size
      }
      var sources = object["sources"] as! [[String: Any]]
      if let servesParts { sources[0]["servesParts"] = servesParts }
      object["sources"] = sources
    }
  }

  /// A Sendable part spec, so the refusal table can be a test argument list.
  struct PartSpec: Sendable {
    let path: String
    let size: Int64
    let sha: String
    var json: [String: Any] { ["path": path, "sizeBytes": size, "sha256": sha] }
  }

  private static func part(_ path: String, _ size: Int64, _ sha: String = hexA) -> PartSpec {
    PartSpec(path: path, size: size, sha: sha)
  }

  @Test func legacyManifestWithoutPartFieldsDecodesAsWholeFileDelivery() throws {
    let manifest = try ManifestFixture.manifest(files: ManifestFixture.smallFiles)
    #expect(manifest.files.allSatisfy { $0.parts == nil })
    #expect(manifest.sources.allSatisfy { $0.servesParts == nil })
    for source in manifest.sources {
      for file in manifest.files {
        #expect(source.deliversParts(of: file) == false)
      }
    }
  }

  @Test func orderedPartsDecodeUnchangedAndSelectTheServingSource() throws {
    let manifest = try DeliveryManifest.load(
      from: Self.manifestJSON(
        parts: [Self.part("weights.bin.part-2", 4, Self.hexB), Self.part("weights.bin.part-1", 6)]))
    let file = try #require(manifest.files.first)
    #expect(file.parts?.map(\.path) == ["weights.bin.part-2", "weights.bin.part-1"])
    #expect(file.parts?.map(\.sizeBytes) == [4, 6])
    #expect(file.parts?.map(\.sha256) == [Self.hexB, Self.hexA])
    #expect(manifest.sources[0].servesParts == true)
    #expect(manifest.sources[0].deliversParts(of: file))
    // The backup declares nothing, so it delivers the whole file.
    #expect(manifest.sources[1].servesParts == nil)
    #expect(manifest.sources[1].deliversParts(of: file) == false)
  }

  @Test func explicitFalseServesPartsDeliversTheWholeFile() throws {
    let manifest = try DeliveryManifest.load(
      from: Self.manifestJSON(
        parts: [Self.part("p1", 6), Self.part("p2", 4)], servesParts: false))
    let file = try #require(manifest.files.first)
    #expect(manifest.sources[0].deliversParts(of: file) == false)
  }

  @Test(
    "malformed parts declarations are refused",
    arguments: [
      ("empty list", [PartSpec]()),
      ("zero size", [part("p1", 0), part("p2", 10)]),
      ("negative size", [part("p1", -1), part("p2", 11)]),
      ("uppercase hex", [part("p1", 10, String(repeating: "A", count: 64))]),
      ("short hex", [part("p1", 10, String(repeating: "a", count: 63))]),
      ("full-width digits", [part("p1", 10, String(repeating: "\u{FF10}", count: 64))]),
      ("absolute locator", [part("/etc/p1", 10)]),
      ("traversal locator", [part("a/../p1", 10)]),
      ("empty locator", [part("", 10)]),
      ("duplicate locator", [part("p1", 5), part("p1", 5)]),
      ("locator equals a file path", [part("weights.bin", 10)]),
      ("sum below size", [part("p1", 4), part("p2", 5)]),
      ("sum above size", [part("p1", 6), part("p2", 5)]),
      ("sum overflows", [part("p1", Int64.max), part("p2", 1)]),
    ] as [(String, [PartSpec])])
  func malformedPartsAreRefused(label: String, parts: [PartSpec]) throws {
    let data = try Self.manifestJSON(parts: parts)
    // Refused by the PARTS contract, not by some unrelated check on the fixture.
    let error = #expect(throws: DeliveryManifest.ManifestError.self, "\(label)") {
      try DeliveryManifest.load(from: data)
    }
    guard case .structurallyInvalid(let reason) = error else {
      Issue.record("\(label): expected structurallyInvalid, got \(String(describing: error))")
      return
    }
    #expect(reason.contains("part"), "\(label): refused for an unrelated reason: \(reason)")
  }

  @Test func optionalFilesAreHeldToTheSamePartsContract() throws {
    let good = try Self.manifestJSON(
      parts: [Self.part("p1", 6), Self.part("p2", 4)], asOptional: true)
    #expect(try DeliveryManifest.load(from: good).optionalFiles.first?.parts?.count == 2)
    let bad = try Self.manifestJSON(
      parts: [Self.part("p1", 6), Self.part("p2", 3)], asOptional: true)
    let error = #expect(throws: DeliveryManifest.ManifestError.self) {
      try DeliveryManifest.load(from: bad)
    }
    guard case .structurallyInvalid(let reason) = error else {
      Issue.record("expected structurallyInvalid, got \(String(describing: error))")
      return
    }
    #expect(reason.hasPrefix("parts sum"))
  }
}
