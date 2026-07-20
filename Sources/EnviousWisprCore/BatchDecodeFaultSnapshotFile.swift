import Foundation

/// #1707 Phase 2: cross-process snapshot for the Parakeet shared-backend
/// overlap Live UAT oracle (§3.2a-i). Mirrors `XPCOperationSignalFile`'s own
/// established pattern (atomic PropertyList write, shared `/tmp` path) for
/// the identical reason its doc comment states: "XPC replies serialize
/// behind the pending request, so a proxy cannot ask the service for
/// progress while it is already waiting for that request's reply." A
/// `query_batch_decode_fault` cannot ask the ASR service for backend
/// timestamps over the same connection while a `transcribeSamples` reply is
/// still pending (the held decode) — so `ParakeetBackend` (inside the ASR
/// service process) writes ONLY its own four backend-side timestamps here,
/// keyed by the externally-supplied trial ID; `BatchDecodeFaultController`
/// (app process) reads them directly, off XPC, and merges them with its own
/// locally-held two kernel-side timestamps.
///
/// DEBUG-only in practice: only `ParakeetBackend`'s `#if DEBUG` fault seam
/// ever writes to this file, and only `BatchDecodeFaultController` (itself
/// constructed only for a Live UAT run) ever reads it — but the type itself
/// is not `#if DEBUG`-gated, matching `XPCOperationSignalFile`'s own shape,
/// so no caller needs its own conditional-compilation seam just to hold a
/// reference to it.
public final class BatchDecodeFaultSnapshotFile: Sendable {
  public static let shared = BatchDecodeFaultSnapshotFile(
    filePath: "/tmp/com.enviouswispr.batch-decode-fault-snapshot")

  private let filePath: String

  private init(filePath: String) {
    self.filePath = filePath
  }

  public func write(_ state: BatchDecodeFaultSnapshotState) {
    guard let data = try? PropertyListEncoder().encode(state) else { return }
    do {
      try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
    } catch {
      // Signal write failure is non-fatal — a Live UAT poll that never
      // observes the expected field simply reports "not observed yet" and
      // eventually times out (§11.2), it does not hang.
    }
  }

  /// Returns the current snapshot, or `nil` if no snapshot has been written
  /// yet, the file is unreadable, or the plist is malformed — every one of
  /// these means "not observed yet," never a crash.
  public func read() -> BatchDecodeFaultSnapshotState? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else { return nil }
    return try? PropertyListDecoder().decode(BatchDecodeFaultSnapshotState.self, from: data)
  }

  public func clear() {
    try? FileManager.default.removeItem(atPath: filePath)
  }
}

/// The four Parakeet backend-side timestamps (epoch seconds), keyed by the
/// externally-supplied trial ID so a stale snapshot from a PRIOR trial can
/// never be mistaken for the current one. All four are optional — absence
/// means "not observed yet," not failure (Grounded Review r10).
public struct BatchDecodeFaultSnapshotState: Codable, Sendable {
  public let trialID: String
  public var heldDecodeEntryEpochSec: Double?
  public var heldDecodeCompletionEpochSec: Double?
  public var newSessionEntryEpochSec: Double?
  public var newSessionCompletionEpochSec: Double?

  public init(trialID: String) {
    self.trialID = trialID
  }
}
