import CryptoKit
import EnviousWisprCore
import Foundation

/// Verifies the SHA-256 checksum of the downloaded Parakeet encoder model.
///
/// Heart bootstrap helper. `ParakeetBackend` downloads the model via FluidAudio
/// directly and calls
/// `verifyChecksum()` afterward as defense-in-depth. A mismatch logs a warning
/// but never blocks — a corrupted model is surfaced, not fatally gated.
enum ModelDownloadManager {

  // MARK: - Configuration

  /// SHA-256 checksum of the Encoder.mlmodelc/model.mlmodel file (the largest, most critical file).
  /// Empty string = verification skipped (checksum not yet computed for current model version).
  /// To compute: `shasum -a 256 ~/Library/Application\ Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml/Encoder.mlmodelc/model.mlmodel`
  private static let encoderChecksum = ""

  /// FluidAudio's expected cache directory for Parakeet v3 models.
  private static let modelCacheDir: URL = {
    let appSupport = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/FluidAudio/Models")
    return appSupport.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml")
  }()

  // MARK: - Checksum Verification

  /// Verify the SHA-256 checksum of the encoder model file.
  /// Logs a warning if verification fails but does NOT block — the model may still work.
  /// This is a defense-in-depth measure, not a hard gate.
  /// Static because it only reads from disk — no instance state needed.
  static func verifyChecksum() {
    guard !Self.encoderChecksum.isEmpty else { return }

    let encoderModel = Self.modelCacheDir
      .appendingPathComponent("Encoder.mlmodelc")
      .appendingPathComponent("model.mlmodel")

    guard let data = try? Data(contentsOf: encoderModel) else { return }
    let hash = SHA256.hash(data: data)
    let hexHash = hash.map { String(format: "%02x", $0) }.joined()

    if hexHash != Self.encoderChecksum {
      Task {
        await AppLogger.shared.log(
          "[ModelDownloadManager] Checksum mismatch — expected: \(Self.encoderChecksum), got: \(hexHash). Model may be corrupted.",
          level: .info, category: "ASR"
        )
      }
    }
  }
}
