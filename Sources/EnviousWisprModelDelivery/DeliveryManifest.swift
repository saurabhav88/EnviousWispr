import CryptoKit
import Foundation

/// Schema-v1 delivery manifest (contract §4, D2 §2): the exhaustive, closed
/// list of files one `ModelIdentity` needs, with per-file SHA-256 + size,
/// ordered sources, and admission rules. Bundled in the signed app — the
/// trust root (contract §4a): source ORDER is runtime-overridable (D5 flags);
/// expected hashes/sizes are immutable outside a trusted app update.
///
/// No listing call exists in the protocol at all (invariant 4): the fetcher
/// downloads exactly `sources[i].baseURL + files[j].path`.
public struct DeliveryManifest: Codable, Sendable, Equatable {
  public struct File: Codable, Sendable, Equatable {
    public let path: String
    public let sizeBytes: Int64
    public let sha256: String
    /// The repair/atomicity unit this file belongs to (a `.mlmodelc` dir name
    /// or the loose file itself) — the grain validation deletes and re-fetches
    /// at (D2 §2, parked-validator precedent).
    public let component: String
  }

  public struct Source: Codable, Sendable, Equatable {
    public let id: String
    public let baseURL: URL
  }

  public struct Admission: Codable, Sendable, Equatable {
    public let layout: String
    public let installLocation: String
    /// STRING in the schema, deliberately: JSON floats canonicalize
    /// differently across serializers (Python json.dumps "2.2" vs
    /// JSONSerialization "2.2000000000000002"), which would break the
    /// cross-implementation manifestDigest — the golden fixture test caught
    /// exactly this. Integers and strings are canonicalization-safe.
    public let diskHeadroomFactor: String
    public let evictPreviousRevisions: Bool

    public var headroomFactor: Double { Double(diskHeadroomFactor) ?? 2.2 }
  }

  public let schemaVersion: Int
  public let identity: ModelIdentity
  public let files: [File]
  public let optionalFiles: [File]
  public let totalBytes: Int64
  public let sources: [Source]
  public let admission: Admission
  public let manifestDigest: String

  /// The only supported schema version. A manifest with any other version is
  /// REFUSED (fail closed — forward tolerance covers additive fields, never
  /// unknown versions; D2 §2.2).
  public static let supportedSchemaVersion = 1

  public enum ManifestError: Error, Equatable {
    case resourceMissing(String)
    case unsupportedSchemaVersion(Int)
    case digestMismatch(declared: String, computed: String)
    case structurallyInvalid(String)
  }

  /// Loads and VALIDATES a bundled manifest: decode, schema-version gate,
  /// structural checks, and canonical-digest recompute. Any failure throws —
  /// callers map to `unknown`/`manifest_invalid` (plan §14 Q1); the bundled
  /// resource is release-asserted by a unit test so this is a can't-happen
  /// guard, not a runtime feature.
  public static func loadBundled(resource: String, bundle: Bundle = .main) throws
    -> DeliveryManifest
  {
    guard let url = bundle.url(forResource: resource, withExtension: "json") else {
      throw ManifestError.resourceMissing(resource)
    }
    let data = try Data(contentsOf: url)
    return try load(from: data)
  }

  public static func load(from data: Data) throws -> DeliveryManifest {
    let manifest = try JSONDecoder().decode(DeliveryManifest.self, from: data)
    guard manifest.schemaVersion == supportedSchemaVersion else {
      throw ManifestError.unsupportedSchemaVersion(manifest.schemaVersion)
    }
    try manifest.validateStructure()
    let computed = try Self.canonicalDigest(of: data)
    guard computed == manifest.manifestDigest else {
      throw ManifestError.digestMismatch(declared: manifest.manifestDigest, computed: computed)
    }
    return manifest
  }

  private func validateStructure() throws {
    guard !files.isEmpty else { throw ManifestError.structurallyInvalid("files[] empty") }
    guard totalBytes == files.reduce(0, { $0 + $1.sizeBytes }) else {
      throw ManifestError.structurallyInvalid("totalBytes != sum(files)")
    }
    guard let first = sources.first, first.id == "our_copy" else {
      throw ManifestError.structurallyInvalid("sources[0] must be our_copy")
    }
    for file in files {
      guard file.sha256.count == 64, file.sha256.allSatisfy({ "0123456789abcdef".contains($0) })
      else { throw ManifestError.structurallyInvalid("bad sha256 for \(file.path)") }
      guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains("..") else {
        throw ManifestError.structurallyInvalid("unsafe path \(file.path)")
      }
      guard !file.component.isEmpty else {
        throw ManifestError.structurallyInvalid("missing component for \(file.path)")
      }
    }
    for source in sources {
      guard source.baseURL.scheme == "https", source.baseURL.absoluteString.hasSuffix("/") else {
        throw ManifestError.structurallyInvalid("source \(source.id) must be https ending in /")
      }
    }
    guard let factor = Double(admission.diskHeadroomFactor), factor >= 1.0 else {
      throw ManifestError.structurallyInvalid("diskHeadroomFactor must parse as a number >= 1.0")
    }
  }

  /// Canonical digest per D2 §2: SHA-256 over the canonical JSON (sorted keys,
  /// no insignificant whitespace) of the manifest EXCLUDING `manifestDigest`.
  ///
  /// Mirrors `scripts/validate-delivery-manifest.py` byte-for-byte — the
  /// Swift↔Python golden fixture test locks the two implementations together.
  /// Canonicalization re-serializes the raw JSON object (not this Codable
  /// struct) so unknown ADDITIVE fields still participate in the digest
  /// exactly as the authoring tool computed it.
  static func canonicalDigest(of rawJSON: Data) throws -> String {
    guard var object = try JSONSerialization.jsonObject(with: rawJSON) as? [String: Any] else {
      throw ManifestError.structurallyInvalid("top level is not an object")
    }
    object.removeValue(forKey: "manifestDigest")
    let canonical = try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
  }

  /// Files grouped by their repair/atomicity component, in stable path order.
  public var filesByComponent: [(component: String, files: [File])] {
    var order: [String] = []
    var groups: [String: [File]] = [:]
    for file in files {
      if groups[file.component] == nil { order.append(file.component) }
      groups[file.component, default: []].append(file)
    }
    return order.map { ($0, groups[$0]!) }
  }
}
