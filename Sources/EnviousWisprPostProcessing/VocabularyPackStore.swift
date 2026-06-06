import EnviousWisprCore
import Foundation
import os

#if canImport(CryptoKit)
  import CryptoKit
#endif

/// Loads bundled ASR-mined vocabulary packs (#633 Phase 9) into `CustomWord`
/// terms tagged `source: .pack`.
///
/// Each pack ships as `Resources/Packs/<id>.json` shaped `{canonical: [aliases]}`
/// (the validated output of the pack-production pipeline). Terms are EXACT-MATCH
/// ONLY downstream — `WordCorrector.buildLookups` keeps `.pack` aliases out of
/// every fuzzy/compound pass.
///
/// Fail-open: any load/decode failure logs and yields no terms, so a corrupt or
/// missing pack file can never poison the corrector vocabulary wiring. This is
/// upstream of the runner-level step fail-open.
public enum VocabularyPackID: String, CaseIterable, Sendable, Codable {
  case tech, medical, legal, brands, names

  public var displayName: String {
    switch self {
    case .tech: return "Tech"
    case .medical: return "Medical"
    case .legal: return "Legal"
    case .brands: return "Brands"
    case .names: return "Names"
    }
  }

  public var blurb: String {
    switch self {
    case .tech: return "Programming, cloud, and developer tools."
    case .medical: return "Medications, conditions, and clinical terms."
    case .legal: return "Litigation, contract, and court terminology."
    case .brands: return "Company, product, and app names."
    case .names: return "Common first names and surnames."
    }
  }
}

public struct VocabularyPack: Sendable {
  public let id: VocabularyPackID
  public let terms: [CustomWord]
}

public final class VocabularyPackStore: Sendable {
  private let bundle: Bundle
  private static let logger = Logger(subsystem: "com.enviouswispr", category: "VocabularyPackStore")

  /// Production: loads from this module's `Bundle.module`.
  public init() {
    self.bundle = .module
  }

  /// Test seam: inject a fixture bundle.
  package init(bundle: Bundle) {
    self.bundle = bundle
  }

  /// Pack IDs whose JSON resolves in the bundle. Fail-open: unresolved packs
  /// are simply absent.
  public func availablePackIDs() -> [VocabularyPackID] {
    VocabularyPackID.allCases.filter { resourceURL(for: $0) != nil }
  }

  /// Load one pack's terms, or nil if the resource is missing/corrupt.
  public func load(_ id: VocabularyPackID) -> VocabularyPack? {
    guard let raw = loadRaw(id) else { return nil }
    let terms = raw.map { canonical, aliases in
      CustomWord(
        id: Self.deterministicID(packID: id, canonical: canonical),
        canonical: canonical,
        aliases: aliases,
        caseSensitive: false,
        source: .pack
      )
    }
    return VocabularyPack(id: id, terms: terms)
  }

  /// Flattened terms for every enabled pack (deterministic order). Missing
  /// packs are skipped (fail-open).
  public func terms(for enabled: Set<VocabularyPackID>) -> [CustomWord] {
    enabled
      .sorted { $0.rawValue < $1.rawValue }
      .compactMap { load($0) }
      .flatMap(\.terms)
  }

  // MARK: - Bundle resolution (subdirectory then flat, per Tuist flattening)

  private func resourceURL(for id: VocabularyPackID) -> URL? {
    bundle.url(forResource: id.rawValue, withExtension: "json", subdirectory: "Packs")
      ?? bundle.url(forResource: id.rawValue, withExtension: "json")
  }

  private func loadRaw(_ id: VocabularyPackID) -> [String: [String]]? {
    guard let url = resourceURL(for: id) else {
      Self.logger.error("Vocabulary pack '\(id.rawValue, privacy: .public)' not found in bundle")
      return nil
    }
    do {
      let data = try Data(contentsOf: url)
      return try JSONDecoder().decode([String: [String]].self, from: data)
    } catch {
      Self.logger.error(
        "Vocabulary pack '\(id.rawValue, privacy: .public)' failed to load: \(error.localizedDescription, privacy: .public)"
      )
      return nil
    }
  }

  // MARK: - Deterministic identity

  /// Stable UUID derived from the pack id + canonical so replacement
  /// attribution / telemetry is consistent across launches. SHA-256 of the seed
  /// → 16 bytes, with RFC-4122 version/variant bits set for well-formedness.
  package static func deterministicID(packID: VocabularyPackID, canonical: String) -> UUID {
    let seed = "pack:\(packID.rawValue):\(canonical.lowercased())"
    #if canImport(CryptoKit)
      let digest = SHA256.hash(data: Data(seed.utf8))
      var b = Array(digest.prefix(16))
      b[6] = (b[6] & 0x0F) | 0x50  // version 5
      b[8] = (b[8] & 0x3F) | 0x80  // RFC-4122 variant
      return UUID(
        uuid: (
          b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
          b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
        ))
    #else
      return UUID()
    #endif
  }
}
