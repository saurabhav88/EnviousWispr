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
      spokenPunctuationEnabled: false,
      customWordsVersion: "v3",
      llmProvider: "appleIntelligence",
      llmModel: "apple-intelligence",
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

  // MARK: - Legacy spool compatibility (#1831)

  /// #1831 removed `useExtendedThinking` from `RecordingSettingsSnapshot`. A
  /// spool written by the PREVIOUS build carries that key, and a user who
  /// crashes on the old build and relaunches on the new one must still recover.
  ///
  /// TWO ARMS, because one alone would not answer the question.
  ///
  /// Arm 1 runs the whole production seam — `sealSettings` -> `openSettings`
  /// (`RecoverySpoolCipher.swift:235`, `:256`) — proving the seam still works
  /// after the field removal.
  ///
  /// Arm 2 supplies plaintext carrying the retired key and decodes it with the
  /// exact expression `openSettings` uses at `RecoverySpoolCipher.swift:266`:
  /// `JSONDecoder().decode(RecordingSettingsSnapshot.self, from: plaintext)`.
  /// It is NOT a hand-built decoder — it is that call, with the AES wrapper
  /// omitted because the private nonce and AAD are file-scoped and unreachable
  /// from a test. STATED LIMIT rather than hidden: the wrapper produces the
  /// plaintext and cannot change how that plaintext decodes, so nothing about
  /// key tolerance lives in the arm this cannot reach.
  ///
  /// The tolerance is a property of the PAIR — synthesized `Decodable` requests
  /// only the properties it declares, and `JSONDecoder` ignores keys nobody
  /// asked for. Neither half alone implies it, which is why a future
  /// hand-written `init(from:)` could break this silently. The mutation control
  /// for that is in the plan's `test-hardening` recipe: a custom `init(from:)`
  /// using a DYNAMIC coding-key type, which can enumerate keys actually present
  /// and throw on the retired one. A fixed `CodingKeys` enum cannot express
  /// that control — a case with no matching property defeats `Codable`
  /// synthesis and fails to COMPILE, which would prove the build broke rather
  /// than that this guard detects unknown-key rejection.
  @Test("a spool written before #1831 still decodes, retired key and all")
  func legacySpoolWithRetiredKeyStillDecodes() throws {
    // Arm 1: the real seam, end to end.
    let cipher = RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key())
    let sealed = try #require(try cipher.sealSettings(snapshot()))
    #expect(try cipher.openSettings(sealed) == snapshot())

    // Arm 2: plaintext from the OLD build, carrying the retired key.
    //
    // DERIVED from the real encoder, never hand-written. A literal JSON fixture
    // would encode this author's GUESS at the wire shape of every field —
    // `LanguageMode`'s enum representation above all — and a wrong guess fails
    // for the wrong reason while a lucky one silently stops matching the real
    // format the next time an unrelated field changes. Encoding the live
    // snapshot and inserting only the retired key isolates the one difference
    // this test is about.
    let current = try JSONEncoder().encode(snapshot())
    var fields = try #require(
      try JSONSerialization.jsonObject(with: current) as? [String: Any])
    #expect(
      fields["useExtendedThinking"] == nil,
      "the retired key must be absent from a NEW snapshot, or arm 2 tests nothing")
    fields["useExtendedThinking"] = true
    let legacy = try JSONSerialization.data(withJSONObject: fields)

    // Positive control on the fixture itself: if the injection had not landed,
    // this would pass while proving nothing.
    #expect(String(decoding: legacy, as: UTF8.self).contains("useExtendedThinking"))

    let decoded = try JSONDecoder().decode(RecordingSettingsSnapshot.self, from: legacy)
    // Every surviving field must arrive intact — not merely "it did not throw".
    #expect(decoded == snapshot())
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
