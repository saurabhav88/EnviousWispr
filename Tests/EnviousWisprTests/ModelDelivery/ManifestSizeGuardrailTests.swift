import Foundation
import Testing

@testable import EnviousWisprModelDelivery

/// Contract §4d size guardrail (#3546, #1405). Every object one of OUR sources
/// serves must fit the edge cache: fail above the cache ceiling and warn
/// above 450,000,000 bytes.
///
/// Drift guard, not product coverage: it freezes an authoring policy.
/// Source.deliversParts(of:) owns which transport representation is measured.
///
/// The authoring ceiling conservatively interprets 512 MB as 512,000,000 bytes.
@Suite(.tags(.driftGuard))
struct ManifestSizeGuardrailTests {

  static let cacheCeilingBytes: Int64 = 512_000_000
  static let warnBytes: Int64 = 450_000_000

  enum Verdict: Equatable { case fits, aboveWarnLine, exceedsCeiling }

  /// The single size decision every assertion below uses.
  static func verdict(_ sizeBytes: Int64) -> Verdict {
    if sizeBytes > cacheCeilingBytes { return .exceedsCeiling }
    if sizeBytes > warnBytes { return .aboveWarnLine }
    return .fits
  }

  struct ServedObject: Equatable {
    let sourceID: String
    let locator: String
    let sizeBytes: Int64
  }

  /// What every own-copy source actually serves: each part when the source serves
  /// parts and the file declares them, otherwise the whole file. Backup and pinned
  /// third-party sources are not held to our cache ceiling.
  static func ownCopyServedObjects(_ manifest: DeliveryManifest) -> [ServedObject] {
    manifest.sources.filter { $0.id == "our_copy" }.flatMap { source in
      (manifest.files + manifest.optionalFiles).flatMap { file -> [ServedObject] in
        if source.deliversParts(of: file), let parts = file.parts {
          return parts.map {
            ServedObject(sourceID: source.id, locator: $0.path, sizeBytes: $0.sizeBytes)
          }
        }
        return [ServedObject(sourceID: source.id, locator: file.path, sizeBytes: file.sizeBytes)]
      }
    }
  }

  // MARK: - Bundled inventory

  /// Every bundled delivery manifest, plus the retired Parakeet v3 manifest once it
  /// exists (#3546 PR-B), loaded through the production validator.
  static func bundledManifests() throws -> [(name: String, manifest: DeliveryManifest)] {
    let dir = RepoRoot.sourceURL("Sources/EnviousWispr/Resources")
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
      .filter {
        $0.hasSuffix("-delivery-manifest.json") || $0 == "parakeet-v3-retired-manifest.json"
      }
      .sorted()
    try #require(
      names.count >= 5, "found only \(names) under \(dir.path); the guard lost its subject")
    return try names.map { name in
      (name, try DeliveryManifest.load(from: Data(contentsOf: dir.appendingPathComponent(name))))
    }
  }

  @Test func everyBundledOwnCopyObjectFitsTheEdgeCache() throws {
    var checked = 0
    for (name, manifest) in try Self.bundledManifests() {
      for object in Self.ownCopyServedObjects(manifest) {
        checked += 1
        let verdict = Self.verdict(object.sizeBytes)
        #expect(
          verdict != .exceedsCeiling,
          "\(name) \(object.locator): \(object.sizeBytes) bytes exceeds the edge-cache ceiling")
        if verdict == .aboveWarnLine {
          print(
            "WARNING: \(name) \(object.locator): \(object.sizeBytes) bytes is above the 450,000,000-byte line"
          )
        }
      }
    }
    #expect(checked > 0)
  }

  // MARK: - Representation and boundaries (fixtures)

  private static let hexA = String(repeating: "a", count: 64)

  private static func manifest(
    size: Int64, parts: [Int64]?, servesParts: Bool?
  ) throws -> DeliveryManifest {
    try DeliveryManifest.load(
      from: ManifestFixture.manifestJSON(files: [("big.bin", Data("x".utf8), "big.bin")]) {
        object in
        var file = (object["files"] as! [[String: Any]])[0]
        file["sizeBytes"] = size
        if let parts {
          file["parts"] = parts.enumerated().map {
            ["path": "big.bin.part-\($0.offset + 1)", "sizeBytes": $0.element, "sha256": hexA]
          }
        }
        object["files"] = [file]
        object["totalBytes"] = size
        var sources = object["sources"] as! [[String: Any]]
        if let servesParts { sources[0]["servesParts"] = servesParts }
        object["sources"] = sources
      })
  }

  @Test(
    "the ceiling and warn line are inclusive limits",
    arguments: [
      (Int64(512_000_000), Verdict.aboveWarnLine),
      (Int64(512_000_001), Verdict.exceedsCeiling),
      (Int64(450_000_000), Verdict.fits),
      (Int64(450_000_001), Verdict.aboveWarnLine),
    ])
  func boundaries(size: Int64, expected: Verdict) throws {
    let objects = Self.ownCopyServedObjects(
      try Self.manifest(size: size, parts: nil, servesParts: nil))
    #expect(objects == [ServedObject(sourceID: "our_copy", locator: "big.bin", sizeBytes: size)])
    #expect(Self.verdict(size) == expected)
  }

  @Test func aLargeFileServedAsPartsIsMeasuredPerPart() throws {
    // Parakeet Ultra's encoder shape: 594,211,328 bytes as two 297,105,664-byte parts.
    let objects = Self.ownCopyServedObjects(
      try Self.manifest(
        size: 594_211_328, parts: [297_105_664, 297_105_664], servesParts: true))
    #expect(objects.map(\.sizeBytes) == [297_105_664, 297_105_664])
    #expect(objects.map(\.locator) == ["big.bin.part-1", "big.bin.part-2"])
    #expect(objects.allSatisfy { Self.verdict($0.sizeBytes) == .fits })
  }

  @Test func theSameFileServedWholeByOurCopyIsMeasuredWhole() throws {
    // Parts declared, but our_copy does not serve parts: it serves the whole file,
    // which is over the ceiling. Backup is never measured.
    let objects = Self.ownCopyServedObjects(
      try Self.manifest(
        size: 594_211_328, parts: [297_105_664, 297_105_664], servesParts: nil))
    #expect(
      objects == [ServedObject(sourceID: "our_copy", locator: "big.bin", sizeBytes: 594_211_328)])
    #expect(Self.verdict(objects[0].sizeBytes) == .exceedsCeiling)
  }
}
