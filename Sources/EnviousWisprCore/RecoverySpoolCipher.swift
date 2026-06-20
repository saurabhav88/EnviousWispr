import CryptoKit
import Foundation

// MARK: - Crash-recovery spool cipher + frame codec (#1063 PR0)
//
// The on-disk `.ewrec` format is an append-only sequence of self-delimiting,
// self-identifying frames. Recovery can rebuild the valid continuous prefix
// from the FRAMES ALONE even if the header/index is damaged: each frame carries
// its own length, ordering metadata, nonce, and auth tag. Any torn tail frame,
// or any frame failing AES-GCM authentication, ends the valid prefix and is
// discarded.
//
// Frame layout (big-endian fixed fields; ciphertext is the encrypted payload):
//
//   [payloadLength : UInt32]   bytes that follow this field = 25 + 16 + N
//   [kind          : UInt8 ]   ┐
//   [chunkIndex    : UInt32]   │ 25-byte fixed metadata block, authenticated
//   [startSample   : UInt64]   │ as AES-GCM Additional Authenticated Data so
//   [sampleCount   : UInt32]   │ reordering or tampering fails decryption
//   [nonceCounter  : UInt64]   ┘
//   [tag           : 16    ]   AES-GCM auth tag (zeros when cipher == .none)
//   [ciphertext    : N     ]   encrypted payload (== plaintext when .none)
//
// Audio payload = little-endian Float32 samples (4 * sampleCount bytes).
// Marker payload = one byte: `RecoverySpoolTerminationReason.rawValue`.
//
// Nonce uniqueness: each frame's 96-bit GCM nonce is derived from a per-session
// monotonic `nonceCounter`, never reused under the session key (GCM nonce reuse
// under one key is catastrophic). The header's settings block reserves
// counter 0; audio/marker frames start at 1.

/// Failure modes the writer and store map onto "drop recovery, never audio" /
/// "discard this frame and end the valid prefix".
public enum RecoverySpoolCipherError: Error, Equatable {
  case missingKey
  case invalidKeySize(Int)
  case truncatedFrame
  case malformedFrame
  case authenticationFailed
  case unsupportedFrameKind(UInt8)
}

/// Encrypts/decrypts spool frames and the header settings block. Value type so
/// it can cross to the writer's dedicated queue and the store's background task
/// freely; it holds only the raw key bytes and rebuilds the `SymmetricKey` per
/// call (cheap), which keeps it unconditionally `Sendable`.
public struct RecoverySpoolCipher: Sendable {
  public let mode: RecoverySpoolCipherMode
  private let keyData: Data?

  /// Fixed metadata block size: kind(1) + chunkIndex(4) + startSample(8)
  /// + sampleCount(4) + nonceCounter(8).
  private static let metaSize = 25
  private static let tagSize = 16
  /// Minimum on-disk payload (empty audio frame): meta + tag + zero ciphertext.
  private static let minPayloadLength = metaSize + tagSize

  /// AAD label binding the header settings block to this format/purpose.
  private static let settingsAAD = Data("ewrec-settings-v1".utf8)

  public init(mode: RecoverySpoolCipherMode, keyData: Data?) {
    self.mode = mode
    self.keyData = keyData
  }

  /// Build a cipher from a directive (mode follows whether a key is present).
  public init(directive: RecoverySpoolDirective) {
    self.init(mode: directive.cipherMode, keyData: directive.keyData)
  }

  private func symmetricKey() throws -> SymmetricKey {
    guard let keyData else { throw RecoverySpoolCipherError.missingKey }
    guard keyData.count == RecoveryConstants.aesKeyByteCount else {
      throw RecoverySpoolCipherError.invalidKeySize(keyData.count)
    }
    return SymmetricKey(data: keyData)
  }

  // MARK: Frame encoding

  /// Encode an audio chunk into a complete on-disk frame.
  public func encodeAudioFrame(
    samples: [Float],
    chunkIndex: UInt32,
    startSample: UInt64,
    nonceCounter: UInt64
  ) throws -> Data {
    try encodeFrame(
      kind: .audio,
      chunkIndex: chunkIndex,
      startSample: startSample,
      sampleCount: UInt32(samples.count),
      nonceCounter: nonceCounter,
      plaintext: Self.serializeSamples(samples))
  }

  /// Encode the terminal marker frame recording why writing stopped.
  public func encodeMarkerFrame(
    reason: RecoverySpoolTerminationReason,
    chunkIndex: UInt32,
    startSample: UInt64,
    nonceCounter: UInt64
  ) throws -> Data {
    try encodeFrame(
      kind: .marker,
      chunkIndex: chunkIndex,
      startSample: startSample,
      sampleCount: 0,
      nonceCounter: nonceCounter,
      plaintext: Data([reason.rawValue]))
  }

  private func encodeFrame(
    kind: RecoveryFrameKind,
    chunkIndex: UInt32,
    startSample: UInt64,
    sampleCount: UInt32,
    nonceCounter: UInt64,
    plaintext: Data
  ) throws -> Data {
    var meta = Data(capacity: Self.metaSize)
    meta.append(kind.rawValue)
    meta.appendBigEndian(chunkIndex)
    meta.appendBigEndian(startSample)
    meta.appendBigEndian(sampleCount)
    meta.appendBigEndian(nonceCounter)

    let tag: Data
    let ciphertext: Data
    switch mode {
    case .none:
      tag = Data(repeating: 0, count: Self.tagSize)
      ciphertext = plaintext
    case .aesGcm256:
      let key = try symmetricKey()
      let sealed = try AES.GCM.seal(
        plaintext, using: key, nonce: Self.nonce(nonceCounter), authenticating: meta)
      tag = sealed.tag
      ciphertext = sealed.ciphertext
    }

    let payloadLength = UInt32(Self.metaSize + Self.tagSize + ciphertext.count)
    var frame = Data(capacity: 4 + Int(payloadLength))
    frame.appendBigEndian(payloadLength)
    frame.append(meta)
    frame.append(tag)
    frame.append(ciphertext)
    return frame
  }

  // MARK: Frame decoding

  /// Decode the frame beginning at `offset`. Returns the decoded frame and the
  /// offset of the next frame, or `nil` when the remaining bytes are a torn
  /// tail (the valid prefix ends here). Throws `authenticationFailed` /
  /// `malformedFrame` for a present-but-corrupt frame, which also ends the
  /// valid prefix.
  public func decodeFrame(from data: Data, at offset: Int) throws -> (
    frame: RecoveryFrame, nextOffset: Int
  )? {
    // `Data` slices keep their parent's indices; normalize to a 0-based view.
    let base = data.startIndex
    let absolute = base + offset
    guard absolute <= data.endIndex else { return nil }
    let remaining = data.distance(from: absolute, to: data.endIndex)
    if remaining < 4 { return nil }  // not even a length prefix: torn tail

    let payloadLength = Int(data.readBigEndianUInt32(at: absolute))
    if payloadLength < Self.minPayloadLength { throw RecoverySpoolCipherError.malformedFrame }
    if remaining - 4 < payloadLength { return nil }  // partial frame: torn tail

    let payloadStart = absolute + 4
    let meta = data.subdata(in: payloadStart..<payloadStart + Self.metaSize)
    let tagStart = payloadStart + Self.metaSize
    let tag = data.subdata(in: tagStart..<tagStart + Self.tagSize)
    let cipherStart = tagStart + Self.tagSize
    let ciphertext = data.subdata(in: cipherStart..<payloadStart + payloadLength)

    // Parse the fixed metadata block (also the AAD).
    let kindRaw = meta[meta.startIndex]
    guard let kind = RecoveryFrameKind(rawValue: kindRaw) else {
      throw RecoverySpoolCipherError.unsupportedFrameKind(kindRaw)
    }
    let chunkIndex = meta.readBigEndianUInt32(at: meta.startIndex + 1)
    let startSample = meta.readBigEndianUInt64(at: meta.startIndex + 5)
    let sampleCount = meta.readBigEndianUInt32(at: meta.startIndex + 13)
    let nonceCounter = meta.readBigEndianUInt64(at: meta.startIndex + 17)

    let plaintext: Data
    switch mode {
    case .none:
      // A `.none` frame is written with an all-zero tag. A nonzero tag means
      // this is actually an ENCRYPTED frame being decoded without its key (e.g.
      // a damaged-header spool the store could not cipher-match) — fail closed
      // rather than reinterpret ciphertext as raw samples (Codex PR0 P2).
      guard tag.allSatisfy({ $0 == 0 }) else {
        throw RecoverySpoolCipherError.authenticationFailed
      }
      plaintext = ciphertext
    case .aesGcm256:
      let key = try symmetricKey()
      do {
        let box = try AES.GCM.SealedBox(
          nonce: Self.nonce(nonceCounter), ciphertext: ciphertext, tag: tag)
        plaintext = try AES.GCM.open(box, using: key, authenticating: meta)
      } catch {
        // Any GCM failure (bad tag, tampered metadata, wrong key) ends the
        // valid prefix; recovery discards this frame and everything after.
        throw RecoverySpoolCipherError.authenticationFailed
      }
    }

    let frame: RecoveryFrame
    switch kind {
    case .audio:
      let samples = Self.deserializeSamples(plaintext, expectedCount: Int(sampleCount))
      frame = RecoveryFrame(
        kind: .audio, chunkIndex: chunkIndex, startSample: startSample,
        sampleCount: sampleCount, nonceCounter: nonceCounter, samples: samples,
        terminationReason: nil)
    case .marker:
      let reason = plaintext.first.flatMap(RecoverySpoolTerminationReason.init(rawValue:))
      frame = RecoveryFrame(
        kind: .marker, chunkIndex: chunkIndex, startSample: startSample,
        sampleCount: 0, nonceCounter: nonceCounter, samples: [],
        terminationReason: reason)
    }
    return (frame, offset + 4 + payloadLength)
  }

  // MARK: Settings block (header)

  /// Seal the record-time settings snapshot for the header. Returns nil for
  /// `.none` (the header carries no settings block when unencrypted).
  public func sealSettings(_ snapshot: RecordingSettingsSnapshot) throws -> Data? {
    switch mode {
    case .none:
      return nil
    case .aesGcm256:
      let key = try symmetricKey()
      let json = try JSONEncoder().encode(snapshot)
      let sealed = try AES.GCM.seal(
        json, using: key,
        nonce: Self.nonce(RecoveryConstants.settingsNonceCounter),
        authenticating: Self.settingsAAD)
      // `combined` is nonce || ciphertext || tag.
      guard let combined = sealed.combined else {
        throw RecoverySpoolCipherError.authenticationFailed
      }
      return combined
    }
  }

  /// Open the header settings block. Throws on auth failure / decode failure so
  /// recovery can fall back to current settings.
  public func openSettings(_ data: Data) throws -> RecordingSettingsSnapshot {
    let key = try symmetricKey()
    let box: AES.GCM.SealedBox
    let plaintext: Data
    do {
      box = try AES.GCM.SealedBox(combined: data)
      plaintext = try AES.GCM.open(box, using: key, authenticating: Self.settingsAAD)
    } catch {
      throw RecoverySpoolCipherError.authenticationFailed
    }
    return try JSONDecoder().decode(RecordingSettingsSnapshot.self, from: plaintext)
  }

  // MARK: Primitives

  /// 96-bit GCM nonce derived from a monotonic counter: four zero bytes then
  /// the 64-bit big-endian counter. Deterministic + unique under a fresh
  /// per-session key.
  private static func nonce(_ counter: UInt64) -> AES.GCM.Nonce {
    var bytes = Data(repeating: 0, count: 4)
    bytes.appendBigEndian(counter)
    // Exactly 12 bytes by construction (4 + 8); AES.GCM.Nonce(data:) only
    // throws on a wrong size, so this cannot fail.
    return try! AES.GCM.Nonce(data: bytes)
  }

  static func serializeSamples(_ samples: [Float]) -> Data {
    var data = Data(capacity: samples.count * 4)
    for sample in samples {
      data.appendLittleEndian(sample.bitPattern)
    }
    return data
  }

  static func deserializeSamples(_ data: Data, expectedCount: Int) -> [Float] {
    let available = data.count / 4
    let count = min(expectedCount, available)
    guard count > 0 else { return [] }
    var samples = [Float]()
    samples.reserveCapacity(count)
    var index = data.startIndex
    for _ in 0..<count {
      let bits = data.readLittleEndianUInt32(at: index)
      samples.append(Float(bitPattern: bits))
      index += 4
    }
    return samples
  }
}

// MARK: - Big/little-endian Data helpers (private to the spool codec)

extension Data {
  fileprivate mutating func appendBigEndian(_ value: UInt32) {
    Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
  }
  fileprivate mutating func appendBigEndian(_ value: UInt64) {
    Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
  }
  fileprivate mutating func appendLittleEndian(_ value: UInt32) {
    Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
  }

  fileprivate func readBigEndianUInt32(at index: Index) -> UInt32 {
    var value: UInt32 = 0
    for offset in 0..<4 {
      value = (value << 8) | UInt32(self[index + offset])
    }
    return value
  }
  fileprivate func readBigEndianUInt64(at index: Index) -> UInt64 {
    var value: UInt64 = 0
    for offset in 0..<8 {
      value = (value << 8) | UInt64(self[index + offset])
    }
    return value
  }
  fileprivate func readLittleEndianUInt32(at index: Index) -> UInt32 {
    var value: UInt32 = 0
    for offset in 0..<4 {
      value |= UInt32(self[index + offset]) << (8 * offset)
    }
    return value
  }
}
