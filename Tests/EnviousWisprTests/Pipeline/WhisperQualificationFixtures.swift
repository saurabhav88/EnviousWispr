import CryptoKit
import Foundation

/// #3735: shared inputs for the Whisper qualification runners (streaming, Chunk 8; preview,
/// Chunk 9). Kept from the retired language-detection parity runner, whose measurement is
/// recorded in `docs/audits/3735-swap/`: the model fingerprint every shard header names, and
/// the frozen #3705 decoded PCM, verified against its manifest row before use.
enum WhisperQualificationFixtures {

  enum FixtureError: Error {
    case badRow
    case sizeMismatch(Int, Int)
    case hashMismatch
    case missingModel(String)
  }

  /// SHA-256 of a model file. `shasum -a 256` reproduces it.
  static func modelFingerprint(atPath path: String) throws -> String {
    guard FileManager.default.fileExists(atPath: path) else {
      throw FixtureError.missingModel(path)
    }
    let data = try Data(contentsOf: URL(filePath: path), options: .alwaysMapped)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Loads the frozen Float32 PCM and verifies its byte count and SHA-256 against the manifest.
  static func loadFrozenPCM(_ row: [String: Any]) throws -> [Float] {
    guard let path = row["decoded_pcm_path"] as? String,
      let expectedSHA = row["decoded_pcm_sha256"] as? String,
      let count = row["decoded_sample_count"] as? Int
    else { throw FixtureError.badRow }
    let data = try Data(contentsOf: URL(filePath: path))
    guard data.count == count * 4 else { throw FixtureError.sizeMismatch(data.count, count * 4) }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard digest == expectedSHA else { throw FixtureError.hashMismatch }
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  }
}
