import Foundation
import Testing

@testable import EnviousWisprCore

/// The crash-recovery spool cipher + frame codec (#1063 PR0). Proves the
/// encrypted, append-only frame format round-trips, authenticates its metadata,
/// and degrades safely on corruption — the foundation everything else builds on.
@Suite("Recovery spool codec (#1063)")
struct RecoverySpoolCodecTests {

  private static func key(_ byte: UInt8 = 7) -> Data {
    Data(repeating: byte, count: RecoveryConstants.aesKeyByteCount)
  }

  private static let sampleChunk: [Float] = [0.0, 0.1, -0.25, 0.5, -1.0, 0.333_25]

  private func snapshot() -> RecordingSettingsSnapshot {
    RecordingSettingsSnapshot(
      backendType: .parakeet,
      backendSupportsLanguageDetection: false,
      languageMode: .auto,
      wordCorrectionEnabled: true,
      fillerRemovalEnabled: true,
      emojiFormatterEnabled: false,
      customWordsVersion: "v3",
      llmProvider: "appleIntelligence",
      llmModel: "apple-intelligence",
      useExtendedThinking: true,
      polishPromptVersion: "v38")
  }

  @Test("an audio frame round-trips bit-exact under AES-GCM")
  func audioFrameRoundTrips() throws {
    let cipher = RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key())
    let frame = try cipher.encodeAudioFrame(
      samples: Self.sampleChunk, chunkIndex: 3, startSample: 48_000, nonceCounter: 4)
    let decoded = try #require(try cipher.decodeFrame(from: frame, at: 0))
    #expect(decoded.frame.kind == .audio)
    #expect(decoded.frame.samples == Self.sampleChunk)
    #expect(decoded.frame.chunkIndex == 3)
    #expect(decoded.frame.startSample == 48_000)
    #expect(decoded.frame.sampleCount == UInt32(Self.sampleChunk.count))
    #expect(decoded.nextOffset == frame.count)
  }

  @Test("a marker frame round-trips its termination reason")
  func markerFrameRoundTrips() throws {
    let cipher = RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key())
    let frame = try cipher.encodeMarkerFrame(
      reason: .diskFull, chunkIndex: 9, startSample: 1_000, nonceCounter: 10)
    let decoded = try #require(try cipher.decodeFrame(from: frame, at: 0))
    #expect(decoded.frame.kind == .marker)
    #expect(decoded.frame.terminationReason == .diskFull)
  }

  @Test("the unencrypted format affordance also round-trips")
  func noneModeRoundTrips() throws {
    let cipher = RecoverySpoolCipher(mode: .none, keyData: nil)
    let frame = try cipher.encodeAudioFrame(
      samples: Self.sampleChunk, chunkIndex: 0, startSample: 0, nonceCounter: 1)
    let decoded = try #require(try cipher.decodeFrame(from: frame, at: 0))
    #expect(decoded.frame.samples == Self.sampleChunk)
  }

  @Test("tampering with authenticated metadata fails decryption")
  func tamperedMetadataFailsAuth() throws {
    let cipher = RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key())
    var frame = try cipher.encodeAudioFrame(
      samples: Self.sampleChunk, chunkIndex: 0, startSample: 0, nonceCounter: 1)
    // Byte 6 lies inside the metadata block (the AAD), after the 4-byte length.
    frame[frame.startIndex + 6] ^= 0xFF
    #expect(throws: RecoverySpoolCipherError.authenticationFailed) {
      _ = try cipher.decodeFrame(from: frame, at: 0)
    }
  }

  @Test("a frame written under one key does not open under another")
  func wrongKeyFailsAuth() throws {
    let writer = RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key(1))
    let reader = RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key(2))
    let frame = try writer.encodeAudioFrame(
      samples: Self.sampleChunk, chunkIndex: 0, startSample: 0, nonceCounter: 1)
    #expect(throws: RecoverySpoolCipherError.authenticationFailed) {
      _ = try reader.decodeFrame(from: frame, at: 0)
    }
  }

  @Test("a `.none` cipher refuses an encrypted (nonzero-tag) frame")
  func noneCipherRejectsEncryptedFrame() throws {
    // Defense-in-depth for the header-unreadable path the store cannot guard:
    // an encrypted frame carries a real GCM tag, so a `.none` decode must fail
    // closed instead of reinterpreting ciphertext as raw samples.
    let aes = RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key())
    let frame = try aes.encodeAudioFrame(
      samples: Self.sampleChunk, chunkIndex: 0, startSample: 0, nonceCounter: 1)
    let none = RecoverySpoolCipher(mode: .none, keyData: nil)
    #expect(throws: RecoverySpoolCipherError.authenticationFailed) {
      _ = try none.decodeFrame(from: frame, at: 0)
    }
  }

  @Test("a torn tail frame decodes to nil, not an error")
  func tornTailReturnsNil() throws {
    let cipher = RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key())
    var frame = try cipher.encodeAudioFrame(
      samples: Self.sampleChunk, chunkIndex: 0, startSample: 0, nonceCounter: 1)
    frame.removeLast(3)  // a partially-flushed final frame
    let decoded = try cipher.decodeFrame(from: frame, at: 0)
    #expect(decoded == nil)
  }

  @Test("missing key surfaces as a typed error, never a crash")
  func missingKeyThrows() {
    let cipher = RecoverySpoolCipher(mode: .aesGcm256, keyData: nil)
    #expect(throws: RecoverySpoolCipherError.missingKey) {
      _ = try cipher.encodeAudioFrame(
        samples: Self.sampleChunk, chunkIndex: 0, startSample: 0, nonceCounter: 1)
    }
  }

  @Test("the header settings block round-trips and is key-bound")
  func settingsBlockRoundTrips() throws {
    let cipher = RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key())
    let sealed = try #require(try cipher.sealSettings(snapshot()))
    let opened = try cipher.openSettings(sealed)
    #expect(opened == snapshot())

    let wrongReader = RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key(99))
    #expect(throws: RecoverySpoolCipherError.authenticationFailed) {
      _ = try wrongReader.openSettings(sealed)
    }
  }

  @Test("the file header round-trips and locates the frames")
  func fileHeaderRoundTrips() throws {
    let header = RecoverySpoolHeader(
      cipher: .aesGcm256,
      recoverySessionID: "session-abc",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      appVersion: "1.2.3",
      encryptedSettings: Data([1, 2, 3]))
    let encoded = try RecoverySpoolFileFormat.encodeHeader(header)
    let decoded = try RecoverySpoolFileFormat.decodeHeader(from: encoded)
    #expect(decoded.header == header)
    #expect(decoded.framesOffset == encoded.count)
  }

  @Test("a non-spool file is rejected as notASpool")
  func nonSpoolRejected() {
    let garbage = Data(repeating: 0xAB, count: 64)
    #expect(throws: RecoverySpoolFileError.notASpool) {
      _ = try RecoverySpoolFileFormat.decodeHeader(from: garbage)
    }
  }
}
