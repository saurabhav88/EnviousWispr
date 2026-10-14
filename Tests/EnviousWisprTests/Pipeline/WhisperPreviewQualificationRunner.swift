import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprLivePreview
@testable import EnviousWisprTranscribeCpp
@testable import EnviousWisprWhisperPreviewAdapter

/// #3735 §3.5 measurement runner: the Universal Live Preview on transcribe.cpp whisper-small,
/// fed on the recording clock. Not a product test: it measures, and it runs only when a shard
/// is named (`TEST_RUNNER_EW_PREVIEW_QUAL_SHARD`), so the ordinary lane reports it skipped.
///
/// Per clip, through the engine the coordinator drives (`WhisperPreviewRecognizer` over
/// `TranscribeCppPreviewRuntime`, the clip's language locked, no Custom Words) and the shared
/// executor:
/// - a feeder hands the session the frozen PCM in 100 ms chunks on the recording clock (chunk i
///   at start + i x 100 ms, independent of any decode), as the coordinator's feed loop does;
/// - every preview decode records its executor queue wait (submit to native entry), native time
///   (entry to return) and outcome (ok, refused because the heart was busy, preempted,
///   cancelled);
/// - at the recording end, as the app does at Stop, the heart's batch decode of the whole clip
///   (turbo, heart lane) is submitted and the preview session ended at the same instant. The row
///   records how long the heart waited to enter native code, how long the preview's teardown
///   took to return, and whether a preview decode was running at Stop.
/// A clip that throws is an error row, never `ok`.
@MainActor
@Suite(
  "Whisper preview qualification runner (#3735, measurement only)", .serialized,
  .tags(.harnessContract))
struct WhisperPreviewQualificationRunner {

  nonisolated private static var environment: [String: String] {
    ProcessInfo.processInfo.environment
  }
  nonisolated static var shardIsNamed: Bool { environment["EW_PREVIEW_QUAL_SHARD"] != nil }

  static let chunkSamples = 1_600  // 100 ms

  @Test("runs one shard of the frozen preview set", .enabled(if: shardIsNamed))
  func runShard() async throws {
    let env = Self.environment
    let shard = try #require(env["EW_PREVIEW_QUAL_SHARD"])
    let outPath = try #require(env["EW_PREVIEW_QUAL_OUT"])
    try #require(
      !FileManager.default.fileExists(atPath: outPath), "refusing to overwrite \(outPath)")
    let small = try #require(env["EW_TRANSCRIBECPP_SMALL_GGUF"])
    let turbo = try #require(env["EW_TRANSCRIBECPP_TURBO_GGUF"])
    let smallPrint = try WhisperLIDParityRunner.modelFingerprint(atPath: small)
    let turboPrint = try WhisperLIDParityRunner.modelFingerprint(atPath: turbo)
    try #require(
      smallPrint == env["EW_PREVIEW_QUAL_EXPECTED_SMALL_SHA256"],
      "small model fingerprint \(smallPrint) is not the approved one")
    try #require(
      turboPrint == env["EW_PREVIEW_QUAL_EXPECTED_TURBO_SHA256"],
      "turbo model fingerprint \(turboPrint) is not the approved one")

    let heart = TranscribeCppWhisperBackend(
      driver: LiveWhisperExecutorDriver(), modelVariant: "q8_0", admittedModelPath: { turbo })
    try await heart.prepare()

    var out = Data()
    func emit(_ object: [String: Any]) throws {
      out.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
      out.append(0x0A)
    }
    try emit([
      "kind": "header", "small_model_path": small, "small_model_sha256": smallPrint,
      "turbo_model_sha256": turboPrint, "chunk_ms": 100, "cadence_s": 1,
      "retention_limit": LivePreviewTextBound.maxCharacters,
    ])

    let rows = try String(contentsOfFile: shard, encoding: .utf8).split(separator: "\n")
    for line in rows where !line.isEmpty {
      let row = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      let id = row["id"] as? String ?? "?"
      do {
        let samples = try WhisperLIDParityRunner.loadFrozenPCM(row)
        let residency = TranscribeCppPreviewResidency()
        var result = try await Self.runClip(
          id: id, row: row, samples: samples, small: small, heart: heart, residency: residency)
        // Every holder of the clip's preview engine is gone now: its model must be freed.
        let freeStart = ContinuousClock.now
        await residency.waitUntilNoneLoaded()
        result["preview_free_after_release_ms"] = MeasuringDriver.ms(ContinuousClock.now - freeStart)
        try emit(result)
      } catch {
        try emit(["kind": "row", "id": id, "status": "error", "error": String(describing: error)])
      }
    }
    await heart.unload()
    try out.write(to: URL(filePath: outPath), options: .withoutOverwriting)
  }

  /// One preview decode as the executor saw it.
  struct Decode: Sendable {
    var queueMs: Double?
    var nativeMs: Double?
    var totalMs: Double
    var outcome: String
  }

  /// The live driver, timing every preview call.
  final class MeasuringDriver: WhisperExecutorDriving, @unchecked Sendable {
    typealias Handle = TranscribeCppExecutor.ModelHandle
    private let live = LiveWhisperExecutorDriver()
    private let lock = NSLock()
    private var decodes: [Decode] = []
    private var running = 0
    var recorded: [Decode] { lock.withLock { decodes } }
    var isDecoding: Bool { lock.withLock { running > 0 } }

    func load(modelPath: String, lane: TranscribeCppExecutor.Lane) async throws -> Handle {
      try await live.load(modelPath: modelPath, lane: lane)
    }
    func detectLanguage(_ handle: Handle, samples: [Float], lane: TranscribeCppExecutor.Lane)
      async throws -> TranscribeCppLanguageObservation
    {
      try await live.detectLanguage(handle, samples: samples, lane: lane)
    }
    func transcribe(
      _ handle: Handle, samples: [Float], language: String?, lane: TranscribeCppExecutor.Lane,
      onInferenceEntered: (@Sendable () -> Void)?, onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> TranscribeCppRunResult {
      let submitted = ContinuousClock.now
      let entered = EntryClock()
      lock.withLock { running += 1 }
      defer { lock.withLock { running -= 1 } }
      do {
        let result = try await live.transcribe(
          handle, samples: samples, language: language, lane: lane,
          onInferenceEntered: {
            entered.mark()
            onInferenceEntered?()
          }, onProgress: onProgress)
        record(submitted, entered, outcome: "ok")
        return result
      } catch {
        let outcome: String
        switch error {
        case TranscribeCppExecutor.ExecutorError.heartBusy: outcome = "heart_busy"
        case TranscribeCppExecutor.ExecutorError.preempted: outcome = "preempted"
        case TranscribeCppExecutor.ExecutorError.cancelled, is CancellationError:
          outcome = "cancelled"
        default: outcome = "failed"
        }
        record(submitted, entered, outcome: outcome)
        throw error
      }
    }
    func waitForDrain(_ handle: Handle) async { await live.waitForDrain(handle) }
    func unload(_ handle: Handle) async { await live.unload(handle) }

    private func record(
      _ submitted: ContinuousClock.Instant, _ entered: EntryClock, outcome: String
    ) {
      let now = ContinuousClock.now
      let entry = entered.instant
      lock.withLock {
        decodes.append(
          Decode(
            queueMs: entry.map { Self.ms($0 - submitted) },
            nativeMs: entry.map { Self.ms(now - $0) },
            totalMs: Self.ms(now - submitted), outcome: outcome))
      }
    }
    static func ms(_ d: Duration) -> Double { Double(d / .microseconds(1)) / 1000 }
  }

  /// The instant native work entered, set on the executor's queue.
  final class EntryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var at: ContinuousClock.Instant?
    func mark() { lock.withLock { at = ContinuousClock.now } }
    var instant: ContinuousClock.Instant? { lock.withLock { at } }
  }

  /// What the pill was handed.
  final class Shown: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    private var firstAt: ContinuousClock.Instant?
    func append(_ text: String) {
      lock.withLock {
        if firstAt == nil { firstAt = ContinuousClock.now }
        texts.append(text)
      }
    }
    var all: [String] { lock.withLock { texts } }
    var first: ContinuousClock.Instant? { lock.withLock { firstAt } }
  }

  static func runClip(
    id: String, row: [String: Any], samples: [Float], small: String,
    heart: TranscribeCppWhisperBackend<LiveWhisperExecutorDriver>,
    residency: TranscribeCppPreviewResidency
  ) async throws -> [String: Any] {
    let language = try #require(row["language"] as? String)
    let driver = MeasuringDriver()
    let recognizer = WhisperPreviewRecognizer(
      runtime: TranscribeCppPreviewRuntime(
        driver: driver, modelPath: small, isAdmitted: { true }, residency: residency),
      language: language)
    let prepareStart = ContinuousClock.now
    try await recognizer.prepare()
    let prepareMs = MeasuringDriver.ms(ContinuousClock.now - prepareStart)

    let shown = Shown()
    let session = try await recognizer.openSession(lookups: nil, onText: shown.append)
    let recordStart = ContinuousClock.now
    var index = 0
    var chunk = 0
    while index < samples.count {
      let end = min(samples.count, index + chunkSamples)
      await session.feed(Array(samples[index..<end]))
      index = end
      chunk += 1
      try await Task.sleep(until: recordStart + .milliseconds(100 * chunk), clock: .continuous)  // settle: recording-clock pacing is the measured condition, not a wait for the subject
    }

    // Stop, as the app does it: the heart's decode starts and the preview is ended at once.
    let previewDecodingAtStop = driver.isDecoding
    let decodesBeforeStop = driver.recorded.count
    let heartEntered = EntryClock()
    let stop = ContinuousClock.now
    let heartTask = Task {
      try await heart.transcribe(
        audioSamples: samples, options: TranscriptionOptions(language: language),
        onInferenceEntered: { heartEntered.mark() })
    }
    let endStart = ContinuousClock.now
    await session.end()
    let previewEndMs = MeasuringDriver.ms(ContinuousClock.now - endStart)
    let heartResult = try await heartTask.value
    let heartTotalMs = MeasuringDriver.ms(ContinuousClock.now - stop)
    let heartWaitMs = heartEntered.instant.map { MeasuringDriver.ms($0 - stop) }

    let decodes = driver.recorded
    let texts = shown.all
    return [
      "kind": "row", "id": id, "status": "ok", "language": language,
      "bucket": row["bucket"] as? String ?? "", "metric": row["metric"] as? String ?? "",
      "seconds": row["seconds"] as? Double ?? 0,
      "decoded_pcm_sha256": row["decoded_pcm_sha256"] as? String ?? "",
      "prepare_ms": prepareMs,
      "first_text_after_start_ms": shown.first.map { MeasuringDriver.ms($0 - recordStart) } as Any,
      "decodes": decodes.map { d -> [String: Any] in
        [
          "queue_ms": d.queueMs as Any, "native_ms": d.nativeMs as Any, "total_ms": d.totalMs,
          "outcome": d.outcome,
        ]
      },
      "decodes_before_stop": decodesBeforeStop,
      "publications": texts.count,
      "max_published_chars": texts.map(\.count).max() ?? 0,
      "last_published": texts.last ?? "",
      "preview_decoding_at_stop": previewDecodingAtStop,
      "preview_end_ms": previewEndMs,
      "heart_wait_ms": heartWaitMs as Any,
      "heart_total_ms": heartTotalMs,
      "heart_text": heartResult.text,
    ]
  }
}
