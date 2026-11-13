import CryptoKit
import Foundation

/// The defined content fingerprint of an imported file (#3147 PR3, plan §17 R2): enough to
/// refuse a different recording at the original's path, never a tamper-proof or full-content
/// check. The value and its format live here; reading a file is the Audio reader's job.
///
/// `v1` digest: SHA-256 over the byte count (UInt64, big-endian), the rounded duration in
/// milliseconds (UInt64, big-endian), the first `min(size, 1 MiB)` bytes, then the last
/// `min(size, 1 MiB)` bytes. A file under 2 MiB contributes overlapping bytes twice, on purpose.
public struct ImportedSourceIdentity: Sendable, Equatable {
  public static let version = "v1"
  /// Bytes hashed from each end of the file.
  public static let edgeBytes = 1 << 20

  public let byteCount: Int64
  public let durationMs: Int64
  /// Lowercase SHA-256 hex.
  public let digest: String

  public init(byteCount: Int64, durationMs: Int64, digest: String) {
    self.byteCount = byteCount
    self.durationMs = durationMs
    self.digest = digest
  }

  /// "v1:<byteCount>:<durationMs>:<digest>".
  public var fingerprint: String {
    "\(Self.version):\(byteCount):\(durationMs):\(digest)"
  }

  /// The identity for already-read edge bytes.
  public static func make(byteCount: Int64, durationMs: Int64, head: Data, tail: Data)
    -> ImportedSourceIdentity
  {
    var hasher = SHA256()
    withUnsafeBytes(of: UInt64(byteCount).bigEndian) { hasher.update(bufferPointer: $0) }
    withUnsafeBytes(of: UInt64(max(0, durationMs)).bigEndian) { hasher.update(bufferPointer: $0) }
    hasher.update(data: head)
    hasher.update(data: tail)
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return ImportedSourceIdentity(byteCount: byteCount, durationMs: durationMs, digest: digest)
  }

  /// How a stored fingerprint compares with this identity.
  public enum Match: Equatable, Sendable {
    case same
    case different
    /// A fingerprint version this build does not understand: never read as "no fingerprint".
    case unsupported
  }

  public func match(_ stored: String) -> Match {
    guard stored.hasPrefix(Self.version + ":") else { return .unsupported }
    return stored == fingerprint ? .same : .different
  }
}
