import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprPipeline
@testable import EnviousWisprTranscribeCpp

/// #3735 §3.11 qualification runner: Faster Transcription (the rolling session) against batch on
/// the same locked audio. Not a product test: it measures, and it runs only when a shard is
/// named (`TEST_RUNNER_EW_STREAM_QUAL_SHARD`), so the ordinary lane reports it skipped.
///
/// Per clip, on one backend shared by the process (`TranscribeCppWhisperBackend` over
/// `LiveWhisperExecutorDriver` and the approved turbo Q8_0 GGUF, fingerprinted before any clip):
/// - batch: one `transcribe` of the whole frozen PCM with the clip's language forced; its
///   stop-to-text is that decode's time (batch starts at stop).
/// - streaming: a rolling session vended exactly as the adapter vends it. A feeder appends the
///   PCM in 100 ms chunks on the recording clock (chunk i at start + i x 100 ms, independent of
///   any decode), so the session sees audio arrive as a microphone delivers it. At the last
///   chunk (the actual recording end) the stop instant is taken, `noteStopRequested` and
///   `finalize` run, and stop-to-text is measured from that instant. A result the adapter would
///   not accept (`accepted == false`) is followed by the batch fallback the adapter would run,
///   and its time is added; the row records the fallback.
/// A decode that throws is an error row, never `ok`.
@MainActor
@Suite(
  "Whisper streaming qualification runner (#3735, measurement only)", .serialized,
  .tags(.harnessContract))
struct WhisperStreamingQualificationRunner {

  nonisolated private static var environment: [String: String] {
    ProcessInfo.processInfo.environment
  }
  nonisolated static var shardIsNamed: Bool { environment["EW_STREAM_QUAL_SHARD"] != nil }

  static let chunkSamples = 1_600  // 100 ms

  @Test("runs one shard of the frozen qualification set", .enabled(if: shardIsNamed))
  func runShard() async throws {
    let env = Self.environment
    let shard = try #require(env["EW_STREAM_QUAL_SHARD"])
    let outPath = try #require(env["EW_STREAM_QUAL_OUT"])
    try #require(
      !FileManager.default.fileExists(atPath: outPath), "refusing to overwrite \(outPath)")
    let gguf = try #require(env["EW_TRANSCRIBECPP_TURBO_GGUF"])
    let fingerprint = try WhisperLIDParityRunner.modelFingerprint(atPath: gguf)
    let expected = try #require(env["EW_STREAM_QUAL_EXPECTED_MODEL_SHA256"])
    try #require(fingerprint == expected, "model fingerprint \(fingerprint) != \(expected)")

    let backend = TranscribeCppWhisperBackend(
      driver: LiveWhisperExecutorDriver(), modelVariant: "q8_0", admittedModelPath: { gguf })
    try await backend.prepare()

    var out = Data()
    func emit(_ object: [String: Any]) throws {
      out.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
      out.append(0x0A)
    }
    try emit([
      "kind": "header", "model_path": gguf, "model_sha256": fingerprint,
      "chunk_ms": 100, "cadence_s": 1,
    ])

    let rows = try String(contentsOfFile: shard, encoding: .utf8).split(separator: "\n")
    for line in rows where !line.isEmpty {
      let row = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      let id = row["id"] as? String ?? "?"
      do {
        let samples = try WhisperLIDParityRunner.loadFrozenPCM(row)
        try emit(try await Self.runClip(id: id, row: row, samples: samples, backend: backend))
      } catch {
        try emit(["kind": "row", "id": id, "status": "error", "error": String(describing: error)])
      }
    }
    await backend.unload()
    try out.write(to: URL(filePath: outPath), options: .withoutOverwriting)
  }

  /// The growing capture buffer the session's provider reads.
  final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    func append(_ chunk: ArraySlice<Float>) { lock.withLock { samples += chunk } }
    var provider: @Sendable () async -> (samples: [Float], count: Int) {
      { [self] in
        let s = lock.withLock { samples }
        return (s, s.count)
      }
    }
  }

  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func hit() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
  }

  static func runClip(
    id: String, row: [String: Any], samples: [Float],
    backend: TranscribeCppWhisperBackend<LiveWhisperExecutorDriver>
  ) async throws -> [String: Any] {
    let language = try #require(row["language"] as? String)
    let options = TranscriptionOptions(language: language)

    // Batch arm.
    let batchStart = ContinuousClock.now
    let batch = try await backend.transcribe(audioSamples: samples, options: options)
    let batchMs = (ContinuousClock.now - batchStart) / .milliseconds(1)

    // Streaming arm, paced by the recording clock (§3.11: audio arrives at the normal capture
    // cadence, independent of decode completion). Nothing here waits for the subject.
    let occupancy = VendorDecodeOccupancy()
    let entries = Counter()
    let session = try #require(
      await backend.makeStreamingSession(
        options: options, vendorDecodeOccupancy: occupancy, onDecode: { entries.hit() }),
      "no session vended")
    let capture = Capture()
    await session.start(audioSamplesProvider: capture.provider)
    let recordStart = ContinuousClock.now
    var index = 0
    var chunk = 0
    while index < samples.count {
      let end = min(samples.count, index + chunkSamples)
      capture.append(samples[index..<end])
      index = end
      chunk += 1
      try await Task.sleep(until: recordStart + .milliseconds(100 * chunk), clock: .continuous)  // settle: recording-clock pacing is the measured condition, not a wait for the subject
    }
    let stop = ContinuousClock.now
    let entriesAtStop = entries.value
    await session.noteStopRequested()
    let streamed = await session.finalize(finalSamples: [], speechSegments: [])
    var stopToTextMs = (ContinuousClock.now - stop) / .milliseconds(1)
    var finalText = (streamed.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    var fellBack = false
    if !streamed.accepted || finalText.isEmpty {
      // What the adapter does next: the clean batch decode of the whole recording.
      fellBack = true
      let fallback = try await backend.transcribe(audioSamples: samples, options: options)
      finalText = fallback.text
      stopToTextMs = (ContinuousClock.now - stop) / .milliseconds(1)
    }
    return [
      "kind": "row", "id": id, "status": "ok", "language": language,
      "bucket": row["bucket"] as? String ?? "", "metric": row["metric"] as? String ?? "",
      "seconds": row["seconds"] as? Double ?? 0,
      "batch_text": batch.text, "batch_ms": batchMs,
      "stream_text": finalText, "stream_accepted": streamed.accepted,
      "stream_strategy": streamed.strategy, "stream_fell_back": fellBack,
      "stream_stop_to_text_ms": stopToTextMs, "stream_tail_decode_ms": streamed.tailDecodeMs,
      "stream_decodes_during_take": entriesAtStop, "stream_decodes_total": entries.value,
      "stream_stop_mid_decode": streamed.stopWhileDecodeInFlight,
      "decoded_pcm_sha256": row["decoded_pcm_sha256"] as? String ?? "",
    ]
  }
}
