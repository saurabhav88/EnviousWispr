import CryptoKit
import Foundation

/// Phase 5a (#635) — value type representing one vocabulary pack. Bible §11.
///
/// Catalogue files live at `Resources/VocabularyPacks/<id>.json` (Phase 5b
/// adds the actual JSON content + SPM resource bundling). This type is the
/// API surface Phase 5b's content + UI work targets.
///
/// Pack terms reach `WordCorrector` only, not the polish prompt — enforced
/// by Phase 0's typed-lane `LanePartitioner.split` filtering on
/// `CustomWord.source == .pack`. Bible §2.2.
public struct VocabularyPack: Codable, Identifiable, Sendable, Hashable {
  /// Stable pack identifier (e.g. `"tech-engineering"`, `"meeting-notes"`,
  /// `"medical"`, `"legal"`). Used as the JSON filename and the persisted
  /// installed-state key.
  public let id: String
  /// Display name shown in the Vocab Packs settings section.
  public let name: String
  /// Brief description for the pack detail row.
  public let description: String
  /// Term canonicals only — no aliases, no definitions. Bible §11.2.1
  /// "terms only, not definitions".
  public let terms: [String]
  /// License + sourcing metadata. Surfaced in the UI under "View sources".
  public let metadata: PackMetadata

  public init(
    id: String,
    name: String,
    description: String,
    terms: [String],
    metadata: PackMetadata
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.terms = terms
    self.metadata = metadata
  }

  /// Build the runtime `[CustomWord]` projection of this pack. Each term
  /// becomes a `CustomWord` with `source: .pack` so the propagator's
  /// `LanePartitioner.split` routes it to the corrector lane only.
  ///
  /// IDs are deterministic per pack-id + canonical so re-installing a pack
  /// produces stable IDs across launches (matters for Phase 8 telemetry
  /// dedup).
  public func customWords() -> [CustomWord] {
    terms.map { canonical in
      CustomWord(
        id: Self.deterministicID(packID: id, canonical: canonical),
        canonical: canonical,
        source: .pack
      )
    }
  }

  /// Deterministic UUID derived from packID + canonical via UUIDv5-style
  /// hashing of the input string. Same input → same UUID across launches.
  /// Used so pack-sourced CustomWords carry stable IDs even though they
  /// are constructed in-memory and never persisted.
  static func deterministicID(packID: String, canonical: String) -> UUID {
    // Codex P2 fix 2026-05-05: previous implementation used Swift's `Hasher`
    // which is randomly seeded per-process for security. That meant
    // "deterministic" only within a single launch — pack term IDs would
    // silently change on every restart, breaking telemetry dedup (Phase 8)
    // and any future persisted references keyed by pack CustomWord.id.
    // SHA-256 is stable across launches and machines.
    let input = "\(packID)|\(canonical)"
    let digest = SHA256.hash(data: Data(input.utf8))
    let bytes = Array(digest.prefix(16))
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
}

/// Sourcing + license metadata for a `VocabularyPack`. Bible §11.2.1.
/// Surfaced in the UI under the pack detail row.
public struct PackMetadata: Codable, Sendable, Hashable {
  /// SPDX-style license identifier (e.g. `"CC0-1.0"`, `"CC-BY-NC-SA-4.0"`)
  /// or a short string for proprietary licenses.
  public let sourceLicense: String
  /// URL to the original source (canonical reference).
  public let sourceURL: String
  /// ISO-8601 date the source was accessed for curation.
  public let sourceAccessedDate: String
  /// Required attribution statement that must appear in the UI when the
  /// pack is installed. Empty string for CC0 / public-domain sources.
  public let attributionStatement: String

  public init(
    sourceLicense: String,
    sourceURL: String,
    sourceAccessedDate: String,
    attributionStatement: String
  ) {
    self.sourceLicense = sourceLicense
    self.sourceURL = sourceURL
    self.sourceAccessedDate = sourceAccessedDate
    self.attributionStatement = attributionStatement
  }
}

/// Catalogue index. Phase 5b loads this from `Resources/VocabularyPacks/catalogue.json`
/// at app launch to discover available packs. Each entry references a pack
/// JSON file by ID; the manager loads the pack on demand.
public struct VocabularyPackCatalogue: Codable, Sendable {
  public let version: Int
  public let packIDs: [String]

  public init(version: Int = 1, packIDs: [String]) {
    self.version = version
    self.packIDs = packIDs
  }
}
