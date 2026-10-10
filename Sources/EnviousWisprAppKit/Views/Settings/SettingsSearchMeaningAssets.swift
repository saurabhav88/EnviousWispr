import CryptoKit
import Foundation

// periphery:ignore - meaning pass core for the Settings search UI chunk (#3482); tests drive it until then
/// The bundled meaning-model assets for Settings search (#3482 plan §3.7a): a precompiled Core ML
/// query encoder, its compact tokenizer, the place vectors and `manifest.json`. They live in
/// `Sources/EnviousWispr/Resources/SettingsSearchMeaning/` and ride the APP target as a folder
/// reference (like the output classifier and the speaker models), so they resolve through
/// `Bundle.main`. Project.swift keeps them out of AppKit's own resource bundle because Tuist's
/// resource glob cannot place a Core ML model inside a static framework.
///
/// Pinned together by ONE value, `pinnedManifestSHA256`: `manifest.json` records the SHA-256 of the
/// tokenizer files, the place vectors and their index, the encoder tree, and the map and vocabulary
/// fingerprints the vectors were built from. `scripts/settings-map/meaning-assets.py` writes it.
struct SettingsSearchMeaningAssets: Sendable {
  static let folderName = "SettingsSearchMeaning"
  static let manifestName = "manifest.json"

  /// SHA-256 of the committed `manifest.json`. Regenerating any asset changes the manifest and so
  /// this line; `SettingsSearchMeaningAssetsTests` names the new value.
  static let pinnedManifestSHA256 =
    "a1b01eaa6f9cb8bb0bc2233d74504472ae94edbdb897f40fdbe983e7e44f6714"

  let directory: URL

  /// The assets inside the running app, or nil when the bundle has no such folder.
  static func bundled(in bundle: Bundle = .main) -> SettingsSearchMeaningAssets? {
    guard
      let url = bundle.resourceURL?.appendingPathComponent(folderName, isDirectory: true),
      FileManager.default.fileExists(atPath: url.path)
    else { return nil }
    return SettingsSearchMeaningAssets(directory: url)
  }

  func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

  // MARK: - Manifest

  struct FileEntry: Decodable, Equatable, Sendable {
    let sha256: String
    let bytes: Int
  }

  struct Manifest: Decodable, Sendable {
    struct Encoder: Decodable, Sendable {
      let directory: String
      let treeSHA256: String
      let sequenceLength: Int
      let queryPrefix: String
      let padTokenID: Int
      let dimension: Int
      let inputs: [String]
      let output: String
      /// The converted `.mlpackage` this model was compiled from (provenance, not read at load).
      let sourcePackageSHA256: String
      let sourcePackageBytes: Int
    }
    struct Tokenizer: Decodable, Sendable {
      /// The compact file the app reads (`tokenizer.unigram`).
      let file: String
      let sha256: String
      let bytes: Int
      /// The Hugging Face files it was built from; provenance only, not shipped.
      let source: [String: FileEntry]

      var entry: FileEntry { FileEntry(sha256: sha256, bytes: bytes) }
    }
    struct PlaceVectors: Decodable, Sendable {
      let bin: FileEntry
      let index: FileEntry
      let textsSHA256: String
      let rows: Int
      let dimension: Int
      let dtype: String
    }
    struct SelfTest: Decodable, Sendable {
      let query: String
      let vector: [Float]
    }
    struct Sources: Decodable, Equatable, Sendable {
      let mapSHA256: String
      let vocabularySHA256: String
      let uiCatalogSHA256: String
    }

    let schema: String
    let version: Int
    let encoder: Encoder
    let tokenizer: Tokenizer
    let placeVectors: PlaceVectors
    let selfTest: [SelfTest]
    let sources: Sources
  }

  enum AssetError: Error, Equatable, CustomStringConvertible {
    case missing(String)
    case unreadable(String)
    case hashMismatch(String)
    case malformed(String)

    var description: String {
      switch self {
      case .missing(let name): "meaning asset \(name) is missing"
      case .unreadable(let reason): "meaning asset unreadable: \(reason)"
      case .hashMismatch(let name): "meaning asset \(name) does not match its pinned hash"
      case .malformed(let reason): "meaning assets malformed: \(reason)"
      }
    }
  }

  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// A file's bytes, memory-mapped, checked against its manifest entry. Never trusts a size or
  /// hash it has not computed.
  func verifiedData(_ name: String, against entry: FileEntry) throws -> Data {
    let file = url(name)
    guard FileManager.default.fileExists(atPath: file.path) else { throw AssetError.missing(name) }
    let data: Data
    do {
      data = try Data(contentsOf: file, options: .alwaysMapped)
    } catch {
      throw AssetError.unreadable("\(name): \(error.localizedDescription)")
    }
    guard data.count == entry.bytes, Self.sha256Hex(data) == entry.sha256 else {
      throw AssetError.hashMismatch(name)
    }
    return data
  }

  /// The manifest, only when its bytes are the pinned ones.
  func loadManifest(pinnedSHA256: String = Self.pinnedManifestSHA256) throws -> Manifest {
    let file = url(Self.manifestName)
    guard FileManager.default.fileExists(atPath: file.path) else {
      throw AssetError.missing(Self.manifestName)
    }
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch {
      throw AssetError.unreadable("\(Self.manifestName): \(error.localizedDescription)")
    }
    guard Self.sha256Hex(data) == pinnedSHA256 else {
      throw AssetError.hashMismatch(Self.manifestName)
    }
    do {
      let manifest = try JSONDecoder().decode(Manifest.self, from: data)
      guard manifest.schema == "settings-search-meaning-assets", manifest.version == 1 else {
        throw AssetError.malformed("unknown schema or version")
      }
      return manifest
    } catch let error as AssetError {
      throw error
    } catch {
      throw AssetError.malformed("\(Self.manifestName): \(error.localizedDescription)")
    }
  }

  /// Checks the files the app reads at load: the tokenizer files and the place vectors with their
  /// index. The encoder tree is checked against the committed sources by the tests, because its
  /// bytes are what the bundle copied verbatim and a hash of 88 MB would be paid on every launch.
  func verifyLoadedFiles(_ manifest: Manifest) throws {
    _ = try verifiedData(manifest.tokenizer.file, against: manifest.tokenizer.entry)
    guard FileManager.default.fileExists(atPath: url(manifest.encoder.directory).path) else {
      throw AssetError.missing(manifest.encoder.directory)
    }
  }
}
