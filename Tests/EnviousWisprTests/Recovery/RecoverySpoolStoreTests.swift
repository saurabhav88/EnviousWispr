import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprStorage
import Foundation
import Testing

/// The host-side `RecoverySpoolStore` (#1063 PR0): reading a writer-produced
/// spool back, reconstructing the valid continuous prefix, decoding the
/// settings block, and the scan/delete lifecycle.
@Suite("Recovery spool store (#1063)")
struct RecoverySpoolStoreTests {

  private static func key(_ byte: UInt8 = 11) -> Data {
    Data(repeating: byte, count: RecoveryConstants.aesKeyByteCount)
  }

  private func makeStore() -> RecoverySpoolStore {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ewrec-tests-\(UUID().uuidString)", isDirectory: true)
    return RecoverySpoolStore(directory: dir)
  }

  private func snapshot() -> RecordingSettingsSnapshot {
    RecordingSettingsSnapshot(
      backendType: .whisperKit,
      backendSupportsLanguageDetection: true,
      languageMode: .locked("es"),
      wordCorrectionEnabled: false,
      fillerRemovalEnabled: true,
      emojiFormatterEnabled: false,
      customWordsVersion: nil,
      llmProvider: "openAI",
      llmModel: "gpt-4o-mini",
      polishPromptVersion: nil)
  }

  /// Drive the real writer to disk and await the serial queue draining.
  private func writeSpool(
    store: RecoverySpoolStore,
    sessionID: String,
    cipher: RecoverySpoolCipher,
    chunks: [[Float]],
    reason: RecoverySpoolTerminationReason
  ) async {
    let writer = RecoverySpoolWriter(
      recoverySessionID: sessionID,
      spoolURL: store.spoolURL(for: sessionID),
      cipher: cipher,
      settings: snapshot(),
      appVersion: "1.0.0",
      createdAt: Date(timeIntervalSince1970: 0))
    writer.start()
    for chunk in chunks { writer.append(chunk) }
    await withCheckedContinuation { continuation in
      writer.finalize(reason: reason) { continuation.resume() }
    }
  }

  @Test("a writer-produced spool round-trips through the store")
  func writerOutputRoundTrips() async throws {
    let store = makeStore()
    let cipher = RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key())
    let chunks: [[Float]] = [[0.1, 0.2], [-0.3, 0.4, 0.5], [0.6]]
    await writeSpool(
      store: store, sessionID: "round-trip", cipher: cipher, chunks: chunks,
      reason: .cleanFinalized)

    let recovered = try store.recover(recoverySessionID: "round-trip", cipher: cipher)
    #expect(recovered.samples == chunks.flatMap { $0 })
    #expect(recovered.frameCount == chunks.count)
    #expect(recovered.terminationReason == .cleanFinalized)
    #expect(recovered.truncated == false)
    #expect(recovered.settings == snapshot())
  }

  @Test("recovery keeps the valid prefix when a later frame is corrupt")
  func recoverKeepsValidPrefix() throws {
    let store = makeStore()
    let cipher = RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key())
    let c0: [Float] = [0.1, 0.2, 0.3]
    let c1: [Float] = [0.4, 0.5]
    let c2: [Float] = [0.6, 0.7, 0.8]

    var data = try RecoverySpoolFileFormat.encodeHeader(
      RecoverySpoolHeader(
        cipher: .aesGcm256, recoverySessionID: "prefix",
        createdAt: Date(timeIntervalSince1970: 0), appVersion: "1.0",
        encryptedSettings: try cipher.sealSettings(snapshot())))
    data.append(
      try cipher.encodeAudioFrame(samples: c0, chunkIndex: 0, startSample: 0, nonceCounter: 1))
    data.append(
      try cipher.encodeAudioFrame(samples: c1, chunkIndex: 1, startSample: 3, nonceCounter: 2))
    var corrupt = try cipher.encodeAudioFrame(
      samples: c2, chunkIndex: 2, startSample: 5, nonceCounter: 3)
    corrupt[corrupt.startIndex + 6] ^= 0xFF  // tamper a metadata byte → auth fails
    data.append(corrupt)
    try data.write(to: store.spoolURL(for: "prefix"))

    let recovered = try store.recover(recoverySessionID: "prefix", cipher: cipher)
    #expect(recovered.samples == c0 + c1)
    #expect(recovered.frameCount == 2)
    #expect(recovered.truncated)
  }

  /// #1464 §3.3 — a crash spool is torn BY DEFINITION. The existing tests tamper a
  /// full final frame or gap the marker; this covers a LITERALLY truncated final
  /// frame (the process died mid-write, leaving only the first bytes of the last
  /// frame). Recovery must keep the valid prefix and report `truncated`.
  @Test("a literally truncated final frame keeps the valid prefix (crash mid-write)")
  func recoverKeepsPrefixOnTruncatedFinalFrame() throws {
    let store = makeStore()
    let cipher = RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key())
    let c0: [Float] = [0.1, 0.2, 0.3]
    let c1: [Float] = [0.4, 0.5]
    let c2: [Float] = [0.6, 0.7, 0.8]

    var data = try RecoverySpoolFileFormat.encodeHeader(
      RecoverySpoolHeader(
        cipher: .aesGcm256, recoverySessionID: "torn",
        createdAt: Date(timeIntervalSince1970: 0), appVersion: "1.0",
        encryptedSettings: try cipher.sealSettings(snapshot())))
    data.append(
      try cipher.encodeAudioFrame(samples: c0, chunkIndex: 0, startSample: 0, nonceCounter: 1))
    data.append(
      try cipher.encodeAudioFrame(samples: c1, chunkIndex: 1, startSample: 3, nonceCounter: 2))
    // The crash cut the final frame mid-write: append only its first few bytes.
    let full = try cipher.encodeAudioFrame(
      samples: c2, chunkIndex: 2, startSample: 5, nonceCounter: 3)
    data.append(full.prefix(4))
    try data.write(to: store.spoolURL(for: "torn"))

    let recovered = try store.recover(recoverySessionID: "torn", cipher: cipher)
    #expect(recovered.samples == c0 + c1)
    #expect(recovered.frameCount == 2)
    #expect(recovered.truncated)
  }

  @Test("an out-of-sequence terminal marker is truncation, not a clean stop")
  func outOfSequenceMarkerIsTruncation() throws {
    let store = makeStore()
    let cipher = RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key())
    let c0: [Float] = [0.1, 0.2, 0.3]

    var data = try RecoverySpoolFileFormat.encodeHeader(
      RecoverySpoolHeader(
        cipher: .aesGcm256, recoverySessionID: "gap-marker",
        createdAt: Date(timeIntervalSince1970: 0), appVersion: "1.0",
        encryptedSettings: try cipher.sealSettings(snapshot())))
    data.append(
      try cipher.encodeAudioFrame(samples: c0, chunkIndex: 0, startSample: 0, nonceCounter: 1))
    // A readable marker that claims a position past a missing middle frame.
    data.append(
      try cipher.encodeMarkerFrame(
        reason: .cleanFinalized, chunkIndex: 5, startSample: 999, nonceCounter: 2))
    try data.write(to: store.spoolURL(for: "gap-marker"))

    let recovered = try store.recover(recoverySessionID: "gap-marker", cipher: cipher)
    #expect(recovered.samples == c0)
    #expect(recovered.frameCount == 1)
    #expect(recovered.truncated)
    #expect(recovered.terminationReason == nil)  // NOT reported as a clean finalize
  }

  @Test("the wrong key yields an empty prefix, never a crash")
  func wrongKeyEmptyPrefix() async throws {
    let store = makeStore()
    let writeCipher = RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key(1))
    await writeSpool(
      store: store, sessionID: "badkey", cipher: writeCipher, chunks: [[0.1, 0.2]],
      reason: .cleanFinalized)

    let readCipher = RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key(2))
    let recovered = try store.recover(recoverySessionID: "badkey", cipher: readCipher)
    #expect(recovered.samples.isEmpty)
    #expect(recovered.truncated)
  }

  @Test("a markerless crash spool is reported as truncated, not complete")
  func markerlessCrashSpoolIsTruncated() throws {
    let store = makeStore()
    let cipher = RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key())
    let c0: [Float] = [0.1, 0.2]
    let c1: [Float] = [0.3, 0.4]

    var data = try RecoverySpoolFileFormat.encodeHeader(
      RecoverySpoolHeader(
        cipher: .aesGcm256, recoverySessionID: "crash",
        createdAt: Date(timeIntervalSince1970: 0), appVersion: "1.0",
        encryptedSettings: try cipher.sealSettings(snapshot())))
    data.append(
      try cipher.encodeAudioFrame(samples: c0, chunkIndex: 0, startSample: 0, nonceCounter: 1))
    data.append(
      try cipher.encodeAudioFrame(samples: c1, chunkIndex: 1, startSample: 2, nonceCounter: 2))
    // No terminal marker: the app died before finalize ran — the common crash
    // case this whole feature exists for.
    try data.write(to: store.spoolURL(for: "crash"))

    let recovered = try store.recover(recoverySessionID: "crash", cipher: cipher)
    #expect(recovered.samples == c0 + c1)
    #expect(recovered.frameCount == 2)
    #expect(recovered.truncated)  // ended abnormally — not a clean finalize
    #expect(recovered.terminationReason == nil)
  }

  @Test("decoding an encrypted spool with the wrong cipher mode fails closed")
  func cipherModeMismatchFailsClosed() async throws {
    let store = makeStore()
    let aesCipher = RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key())
    await writeSpool(
      store: store, sessionID: "mismatch", cipher: aesCipher, chunks: [[0.1, 0.2, 0.3]],
      reason: .cleanFinalized)

    // A caller that lost the key and fell back to `.none` must get NOTHING, not
    // ciphertext reinterpreted as raw samples.
    let noneCipher = RecoverySpoolCipher(mode: .none, keyData: nil)
    let recovered = try store.recover(recoverySessionID: "mismatch", cipher: noneCipher)
    #expect(recovered.samples.isEmpty)
    #expect(recovered.truncated)
  }

  @Test("scan finds written spools; delete removes them idempotently")
  func scanAndDelete() async throws {
    let store = makeStore()
    let cipher = RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key())
    await writeSpool(
      store: store, sessionID: "alpha", cipher: cipher, chunks: [[0.1]],
      reason: .cleanFinalized)
    await writeSpool(
      store: store, sessionID: "beta", cipher: cipher, chunks: [[0.2]],
      reason: .cleanFinalized)

    #expect(try store.listSpoolSessionIDs() == ["alpha", "beta"])
    try store.delete(recoverySessionID: "alpha")
    #expect(try store.listSpoolSessionIDs() == ["beta"])
    // Idempotent: deleting a missing spool is success.
    try store.delete(recoverySessionID: "alpha")
  }

  // MARK: - One-attempt crash-loop marker (#1063 PR2)

  @Test("attempt marker: write makes it present, delete removes it (idempotent)")
  func attemptMarkerLifecycle() throws {
    let store = makeStore()
    let id = "marked-\(UUID().uuidString)"
    #expect(!store.hasAttemptMarker(for: id))
    try store.writeAttemptMarker(for: id)
    #expect(store.hasAttemptMarker(for: id), "present after write — crash-loop guard armed")
    try store.deleteAttemptMarker(for: id)
    #expect(!store.hasAttemptMarker(for: id))
    // Idempotent.
    try store.deleteAttemptMarker(for: id)
  }

  @Test("deleting a spool also clears its attempt marker")
  func deleteSpoolClearsMarker() async throws {
    let store = makeStore()
    let cipher = RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key())
    await writeSpool(
      store: store, sessionID: "gamma", cipher: cipher, chunks: [[0.3]], reason: .cleanFinalized)
    try store.writeAttemptMarker(for: "gamma")
    #expect(store.hasAttemptMarker(for: "gamma"))
    try store.delete(recoverySessionID: "gamma")
    #expect(!store.hasAttemptMarker(for: "gamma"), "spool delete cleared the marker")
    #expect(try store.listSpoolSessionIDs() == [])
  }

  @Test("a marker file is not mistaken for a spool by the scan")
  func markerNotListedAsSpool() throws {
    let store = makeStore()
    try store.writeAttemptMarker(for: "lonely-marker")
    #expect(try store.listSpoolSessionIDs().isEmpty, "scan lists only .ewrec spools")
  }
}
