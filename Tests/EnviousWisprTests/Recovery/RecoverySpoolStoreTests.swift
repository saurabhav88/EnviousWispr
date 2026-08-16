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
      spokenPunctuationEnabled: false,
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

  // MARK: - One-attempt marker (#1063 PR2; broader meaning since #1740)

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

  // MARK: - Escape Recovery marker (#2087)

  @Test("escape marker: round-trips with its clock and take id intact")
  func escapeMarkerRoundTrips() throws {
    let store = makeStore()
    let id = "esc-\(UUID().uuidString)"
    // A whole number of seconds: the encoder uses ISO8601, which does not carry
    // sub-second precision, so a `Date()` here would fail on a rounding artefact
    // and teach nothing about the code.
    let triggered = Date(timeIntervalSince1970: 1_755_300_000)

    #expect(store.readEscapeMarker(for: id) == .absent, "no marker before one is written")

    try store.writeEscapeMarker(
      EscapeRecoveryMarker(recoverySessionID: id, triggeredAt: triggered, takeID: "take-7"))

    guard case .valid(let marker) = store.readEscapeMarker(for: id) else {
      Issue.record("expected a valid marker")
      return
    }
    #expect(marker.recoverySessionID == id)
    #expect(marker.triggeredAt == triggered, "the user's clock survives the round trip")
    #expect(marker.takeID == "take-7", "the telemetry join key survives")
    #expect(marker.version == EscapeRecoveryMarker.currentVersion)
  }

  /// Each of these is a marker we cannot trust, and every one must read as
  /// `.malformed` rather than `.absent`.
  ///
  /// The distinction is the whole point: `.absent` means "an ordinary crash
  /// rescue", which produces a PERMANENT History row. A marker that exists but
  /// cannot be read is positive evidence the take was a cancel, so collapsing it
  /// into `.absent` would keep a dictation the user deliberately discarded — the
  /// exact outcome the marker exists to prevent.
  @Test("escape marker: every untrustworthy shape reads as malformed, never absent")
  func escapeMarkerFailsClosed() throws {
    let store = makeStore()
    let dir = store.directoryURL

    func write(_ id: String, _ bytes: Data) throws {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try bytes.write(
        to: dir.appendingPathComponent(
          "\(id).\(RecoveryConstants.escapeMarkerFileExtension)"))
    }

    // 1. Not JSON at all.
    try write("corrupt", Data("not json".utf8))
    #expect(store.readEscapeMarker(for: "corrupt") == .malformed)

    // 2. Valid JSON, wrong shape.
    try write("wrongshape", Data(#"{"hello":"world"}"#.utf8))
    #expect(store.readEscapeMarker(for: "wrongshape") == .malformed)

    // 3. A version this build does not know. Fails closed rather than guessing
    //    at fields a future format may have moved or redefined.
    try write(
      "future",
      Data(
        #"{"version":99,"recoverySessionID":"future","triggeredAt":"2026-08-16T00:00:00Z"}"#.utf8))
    #expect(store.readEscapeMarker(for: "future") == .malformed)

    // 4. The id inside disagrees with the filename. The filename is the
    //    authority for WHICH spool this belongs to; honouring the contents would
    //    apply one session's clock to another session's audio.
    try write(
      "mismatch",
      Data(
        #"{"version":1,"recoverySessionID":"someone-else","triggeredAt":"2026-08-16T00:00:00Z"}"#
          .utf8))
    #expect(store.readEscapeMarker(for: "mismatch") == .malformed)
  }

  @Test("escape marker: delete is idempotent, and a spool delete takes it too")
  func escapeMarkerDeletion() async throws {
    let store = makeStore()
    let cipher = RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key())
    await writeSpool(
      store: store, sessionID: "delta", cipher: cipher, chunks: [[0.4]], reason: .cleanFinalized)
    try store.writeEscapeMarker(
      EscapeRecoveryMarker(recoverySessionID: "delta", triggeredAt: Date()))
    guard case .valid = store.readEscapeMarker(for: "delta") else {
      Issue.record("marker should be present before the delete")
      return
    }

    // A marker outliving its spool would tell the next launch that audio which
    // no longer exists was an escape recovery.
    try store.delete(recoverySessionID: "delta")
    #expect(store.readEscapeMarker(for: "delta") == .absent, "spool delete cleared the marker")

    // Idempotent — a missing marker is success, not an error.
    try store.deleteEscapeMarker(for: "delta")
  }

  /// The repair for "one sidecar deletion failing skips the other".
  ///
  /// Chaining the two with `try` looks equivalent and is not: by this point the
  /// spool is already gone, so nothing will ever rescan that id, and a sidecar
  /// skipped because its predecessor threw is orphaned permanently.
  ///
  /// The attempt marker is made undeletable by being a directory whose contents
  /// cannot be removed (0500 parent), which leaves the escape marker — an
  /// ordinary file in the still-writable spool directory — perfectly removable.
  /// A permissions trick on the spool directory itself would break both and
  /// prove nothing about the ordering.
  @Test("a failing sidecar deletion does not prevent the other, and still surfaces")
  func sidecarDeletionIsAttemptedForBoth() throws {
    let store = makeStore()
    let id = "stuck"
    let fm = FileManager.default
    try fm.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)

    // An undeletable `<id>.attempt`: a directory with a child, then sealed.
    let attemptDir = store.directoryURL.appendingPathComponent(
      "\(id).\(RecoveryConstants.attemptFileExtension)")
    try fm.createDirectory(at: attemptDir, withIntermediateDirectories: true)
    try Data([0]).write(to: attemptDir.appendingPathComponent("child"))
    try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: attemptDir.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: attemptDir.path) }

    try store.writeEscapeMarker(
      EscapeRecoveryMarker(recoverySessionID: id, triggeredAt: Date()))

    var threw = false
    do { try store.delete(recoverySessionID: id) } catch { threw = true }

    #expect(threw, "the failure must surface, not be swallowed")
    #expect(
      store.readEscapeMarker(for: id) == .absent,
      "the escape marker was still attempted after the attempt marker failed")
  }

  // MARK: - prepareEscapeRecovery, the kernel's one-call connector (#2087)

  @Test("prepare succeeds: the marker is readable afterwards")
  func prepareEscapeRecoverySucceeds() async throws {
    let store = makeStore()
    let cipher = RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key())
    await writeSpool(
      store: store, sessionID: "prep", cipher: cipher, chunks: [[0.2]], reason: .cleanFinalized)
    let at = Date(timeIntervalSince1970: 1_755_300_000)

    #expect(store.prepareEscapeRecovery(recoverySessionID: "prep", triggeredAt: at, takeID: "t-9"))

    guard case .valid(let marker) = store.readEscapeMarker(for: "prep") else {
      Issue.record("expected the marker to be committed")
      return
    }
    #expect(marker.triggeredAt == at)
    #expect(marker.takeID == "t-9")
    #expect(try store.listSpoolSessionIDs() == ["prep"], "the audio is untouched on success")
  }

  /// FAIL CLOSED, and this is the assertion that makes the word mean something.
  ///
  /// Returning `false` alone would not be enough: a spool left on disk with no
  /// readable marker is replayed at the next launch as an ordinary crash rescue,
  /// producing a PERMANENT History row for a dictation the user cancelled. So the
  /// failure path must also DESTROY the spool — which costs the user exactly what
  /// pressing cancel already costs them, and is what the caller falls back to.
  @Test("prepare fails: returns false AND destroys the spool, leaving nothing to replay")
  func prepareEscapeRecoveryFailsClosed() async throws {
    let store = makeStore()
    let cipher = RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key())
    await writeSpool(
      store: store, sessionID: "doomed", cipher: cipher, chunks: [[0.3]], reason: .cleanFinalized)

    // Block the marker write at its FIRST step: the temp path is already a
    // directory, so `open(…, O_CREAT | O_WRONLY)` fails with EISDIR.
    //
    // An earlier version of this test blocked the DESTINATION instead and proved
    // nothing — macOS `replaceItemAt` happily replaces a non-empty directory with
    // a file, so the write succeeded and the assertion caught my wrong assumption
    // about the filesystem rather than a defect. The spool directory itself stays
    // writable on purpose: sealing it would break the cleanup too, and then the
    // test could not observe the destruction it exists to check.
    let tmpBlocker = store.directoryURL.appendingPathComponent(
      ".doomed.\(RecoveryConstants.escapeMarkerFileExtension).tmp")
    try FileManager.default.createDirectory(at: tmpBlocker, withIntermediateDirectories: true)

    let ok = store.prepareEscapeRecovery(
      recoverySessionID: "doomed", triggeredAt: Date(), takeID: nil)

    #expect(ok == false, "the caller must be told to perform an ordinary cancel")
    #expect(
      try store.listSpoolSessionIDs() == [],
      "the spool is destroyed — a survivor with no marker replays as permanent History")
  }

  @Test("escape marker: written 0600 and never listed as a spool")
  func escapeMarkerPermissionsAndScan() throws {
    let store = makeStore()
    try store.writeEscapeMarker(
      EscapeRecoveryMarker(recoverySessionID: "perm", triggeredAt: Date()))

    #expect(try store.listSpoolSessionIDs().isEmpty, "scan lists only .ewrec spools")

    let url = store.directoryURL.appendingPathComponent(
      "perm.\(RecoveryConstants.escapeMarkerFileExtension)")
    let mode =
      try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
      as? NSNumber
    #expect(mode?.int16Value == 0o600, "owner-only, matching the attempt marker and the spool")
  }
}
