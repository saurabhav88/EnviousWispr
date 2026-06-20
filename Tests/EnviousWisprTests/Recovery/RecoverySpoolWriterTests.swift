import EnviousWisprAudio
import EnviousWisprCore
import Foundation
import Testing

/// The helper-side `RecoverySpoolWriter` (#1063 PR0) is a strict limb: every
/// failure path drops recovery and leaves the caller (the audio path)
/// untouched. These tests drive the fail-open and load-shedding behavior with
/// controllable sinks — no real-time sleeps (`tests-no-real-time-scheduling`).
@Suite("Recovery spool writer (#1063)")
struct RecoverySpoolWriterTests {

  private static func key() -> Data {
    Data(repeating: 5, count: RecoveryConstants.aesKeyByteCount)
  }

  private func snapshot() -> RecordingSettingsSnapshot {
    RecordingSettingsSnapshot(
      backendType: .parakeet, backendSupportsLanguageDetection: false, languageMode: .auto,
      wordCorrectionEnabled: false, fillerRemovalEnabled: false,
      emojiFormatterEnabled: false, customWordsVersion: nil,
      llmProvider: "none", llmModel: "none", polishPromptVersion: nil)
  }

  /// Fails the Nth write (1 = header). Lets us simulate a disk-full mid-spool.
  private final class ThrowingSink: RecoverySpoolFileSink, @unchecked Sendable {
    private let failOnWrite: Int
    private let lock = NSLock()
    private var writes = 0
    init(failOnWrite: Int) { self.failOnWrite = failOnWrite }
    func open() throws {}
    func write(_ data: Data) throws {
      lock.lock()
      writes += 1
      let current = writes
      lock.unlock()
      if current == failOnWrite { throw RecoverySpoolWriterError.syncFailed(28) }
    }
    func sync() throws {}
    func close() {}
  }

  /// Counts every write so a test can assert how many frames hit the sink.
  private final class CountingSink: RecoverySpoolFileSink, @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    var count: Int {
      lock.lock()
      defer { lock.unlock() }
      return writes
    }
    func open() throws {}
    func write(_ data: Data) throws {
      lock.lock()
      writes += 1
      lock.unlock()
    }
    func sync() throws {}
    func close() {}
  }

  /// Blocks inside `open()` until released, so the write queue stalls and
  /// pending bytes accumulate deterministically.
  private final class GatedSink: RecoverySpoolFileSink, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    func release() { gate.signal() }
    func open() throws { gate.wait() }
    func write(_ data: Data) throws {}
    func sync() throws {}
    func close() {}
  }

  private func awaitFinalize(_ writer: RecoverySpoolWriter, reason: RecoverySpoolTerminationReason)
    async
  {
    await withCheckedContinuation { continuation in
      writer.finalize(reason: reason) { continuation.resume() }
    }
  }

  @Test("an audio write failure stops spooling without throwing to the caller")
  func writeFailureStopsSpoolFailOpen() async {
    let writer = RecoverySpoolWriter(
      recoverySessionID: "fail-open",
      cipher: RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key()),
      settings: snapshot(),
      sink: ThrowingSink(failOnWrite: 2))  // header ok, first audio frame throws
    writer.start()
    writer.append([0.1, 0.2])  // triggers the failing write — must not throw
    await awaitFinalize(writer, reason: .cleanFinalized)
    #expect(writer.isHealthy == false)
  }

  @Test("finalize is idempotent — a second finalize writes no second terminal marker")
  func finalizeIsIdempotent() async {
    // #1063 PR1 can race a clean-stop finalize against a best-effort
    // XPC-invalidation finalize; the second must not write another marker.
    let sink = CountingSink()
    let writer = RecoverySpoolWriter(
      recoverySessionID: "idem",
      cipher: RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key()),
      settings: snapshot(),
      sink: sink)
    writer.start()
    await awaitFinalize(writer, reason: .cleanFinalized)
    await awaitFinalize(writer, reason: .interrupted)
    // header (1) + exactly one terminal marker (1) = 2 writes. A non-idempotent
    // finalize would write a second marker (3) and break the single-terminal
    // contract the valid-prefix reader relies on.
    #expect(sink.count == 2)
  }

  @Test("backpressure sheds recovery when the queue backs up, never the caller")
  func backpressureShedsLoad() async {
    let gate = GatedSink()
    let writer = RecoverySpoolWriter(
      recoverySessionID: "backpressure",
      cipher: RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key()),
      settings: snapshot(),
      sink: gate,
      maxPendingBytes: 8)  // one 2-sample chunk fits; a second overflows
    writer.start()  // queue blocks inside open()
    writer.append([0.1, 0.2])  // 8 bytes — admitted, queued behind the gate
    writer.append([0.3])  // would push pending to 12 > 8 — dropped, spool stops
    #expect(writer.isHealthy == false)
    gate.release()
    await awaitFinalize(writer, reason: .cleanFinalized)
  }

  @Test("a clean spool to a real file reports healthy")
  func cleanSpoolStaysHealthy() async {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ewrec-writer-\(UUID().uuidString).ewrec")
    let writer = RecoverySpoolWriter(
      recoverySessionID: "healthy",
      spoolURL: url,
      cipher: RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key()),
      settings: snapshot())
    writer.start()
    writer.append([0.1, 0.2, 0.3])
    await awaitFinalize(writer, reason: .cleanFinalized)
    #expect(writer.isHealthy)
    try? FileManager.default.removeItem(at: url)
  }
}
