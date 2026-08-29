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
/// (the validated output of the pack-production pipeline). Downstream,
/// `WordCorrector` matches pack terms via a length-gated fuzzy tier that runs
/// only after every non-pack pass misses, so user/builtin words always win (#992).
///
/// Fail-open: any load/decode failure logs and yields no terms, so a corrupt or
/// missing pack file can never poison the corrector vocabulary wiring. This is
/// upstream of the runner-level step fail-open.
public enum VocabularyPackID: String, CaseIterable, Sendable, Codable, Identifiable {
  case tech, medical, legal, brands, names

  public var id: String { rawValue }

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
  public let terms: [CustomWord]
}

public final class VocabularyPackStore: Sendable {
  private let bundle: Bundle
  private static let logger = Logger(subsystem: "com.enviouswispr", category: "VocabularyPackStore")

  /// Decoded packs, kept after the first read.
  ///
  /// **A pack's bytes are a bundled resource: they cannot change while the app
  /// runs, so decoding them more than once is pure waste.** Without this,
  /// `load(_:)` re-read the file and re-ran `JSONDecoder` on every call, and
  /// the settings UI calls it from inside SwiftUI `body` evaluations — a
  /// single render of the pack list costs about twenty decodes, because
  /// `rowDetail` asks for both a count and examples per pack and `ViewThatFits`
  /// builds the row twice (measured 2026-08-29: 4.62 ms per body evaluation,
  /// 0.354 ms per `load(medical)`).
  ///
  /// **This is a real waste and it is NOT what made the tab beachball.** Single-
  /// digit milliseconds cannot stall the main thread visibly; the stall is the
  /// view tree the detail pane builds. Fixing this does not close that, and
  /// nobody should read the cache as the answer to the lag.
  ///
  /// A lock rather than a `lazy`: the type is `Sendable` and reachable from any
  /// thread, so an unsynchronised stored dictionary would be a data race. The
  /// decode runs OUTSIDE the lock, so a slow read never blocks another pack's
  /// lookup; two threads racing the same miss both decode and the second store
  /// wins, which is harmless because the result is a pure function of bytes
  /// that cannot change.
  private let decoded = OSAllocatedUnfairLock(
    initialState: [VocabularyPackID: VocabularyPack]())

  /// Production: loads from this module's `Bundle.module`.
  public init() {
    self.bundle = .module
  }

  /// Pack IDs whose JSON resolves in the bundle. Fail-open: unresolved packs
  /// are simply absent.
  public func availablePackIDs() -> [VocabularyPackID] {
    VocabularyPackID.allCases.filter { resourceURL(for: $0) != nil }
  }

  /// Load one pack's terms, or nil if the resource is missing/corrupt.
  ///
  /// Memoized — see `decoded`. A MISSING or CORRUPT pack is deliberately not
  /// cached: the failure is logged each time rather than silently answered from
  /// a remembered `nil`, and a fail-open path that has genuinely nothing to
  /// return costs one bundle lookup, not a decode.
  public func load(_ id: VocabularyPackID) -> VocabularyPack? {
    if let hit = decoded.withLock({ $0[id] }) { return hit }

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
    let pack = VocabularyPack(terms: terms)
    decoded.withLock { $0[id] = pack }
    return pack
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
