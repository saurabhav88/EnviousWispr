import CryptoKit
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprPipeline

/// #3735 §11 / P2: the language-detection parity runner. Not a product test: it measures, and
/// it runs only when a shard is named (`TEST_RUNNER_EW_LID_PARITY_SHARD`), so the ordinary lane
/// reports it skipped.
///
/// Per clip it drives the REAL `WhisperEngineAdapter` (fresh per clip) over one backend shared
/// by the process: the adapter's own LID preparation, window-count decision,
/// `LanguageDetector.detect(..., mode: .auto)` and the decode that follows with the accepted
/// hint or nil. A recording proxy captures the raw `observeLID` batch the detector saw.
///
/// Input contract (stated, identical for both engines): the frozen #3705 decoded PCM, one
/// speech range covering the whole clip (no VAD), so voiced duration is the clip duration.
/// Each clip gets a fresh detector with private defaults and a fixed clock.
///
/// Engines: `wk` = the shipped `WhisperKitBackend` over the installed model and bundled
/// tokenizer; `tc` = `TranscribeCppWhisperBackend` over `LiveWhisperExecutorDriver` and the
/// approved turbo Q8_0 GGUF.
@MainActor
@Suite("Whisper LID parity runner (#3735, measurement only)", .serialized, .tags(.harnessContract))
struct WhisperLIDParityRunner {

  nonisolated private static var environment: [String: String] {
    ProcessInfo.processInfo.environment
  }
  nonisolated static var shardIsNamed: Bool { environment["EW_LID_PARITY_SHARD"] != nil }

  @Test("runs one shard of the frozen parity set", .enabled(if: shardIsNamed))
  func runShard() async throws {
    let env = Self.environment
    let shard = try #require(env["EW_LID_PARITY_SHARD"])
    let engine = try #require(env["EW_LID_PARITY_ENGINE"])
    let outPath = try #require(env["EW_LID_PARITY_OUT"])
    try #require(
      !FileManager.default.fileExists(atPath: outPath), "refusing to overwrite \(outPath)")

    let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let base: any WhisperBackendDriving
    let identity: [String: String]
    switch engine {
    case "wk":
      let folder = try #require(env["EW_LID_PARITY_WK_MODEL"])
      let tokenizer = repoRoot.appending(path: "Sources/EnviousWisprASR/Resources/WhisperTokenizer")
      base = WhisperKitBackend(
        admittedModelFolder: { folder }, tokenizerFolderURL: tokenizer)
      identity = ["model_folder": folder, "variant": WhisperKitBackend.defaultModelVariant()]
    case "tc":
      let gguf = try #require(env["EW_TRANSCRIBECPP_TURBO_GGUF"])
      base = TranscribeCppWhisperBackend(
        driver: LiveWhisperExecutorDriver(), modelVariant: "whisper-large-v3-turbo-Q8_0",
        admittedModelPath: { gguf })
      identity = ["model_path": gguf, "variant": "whisper-large-v3-turbo-Q8_0"]
    default:
      Issue.record("unknown engine \(engine)")
      return
    }
    let proxy = RecordingWhisperBackend(base: base)
    let loadStart = ContinuousClock.now
    try await proxy.prepare()
    let loadMs = (ContinuousClock.now - loadStart) / .milliseconds(1)

    var out = Data()
    func emit(_ object: [String: Any]) throws {
      out.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
      out.append(0x0A)
    }
    try emit(["kind": "header", "engine": engine, "identity": identity, "load_ms": loadMs])

    let rows = try String(contentsOfFile: shard, encoding: .utf8).split(separator: "\n")
    for line in rows where !line.isEmpty {
      let row = try #require(
        JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      let id = row["id"] as? String ?? "?"
      do {
        let samples = try Self.loadFrozenPCM(row)
        try emit(try await Self.runClip(id: id, row: row, samples: samples, proxy: proxy))
      } catch {
        try emit(["kind": "row", "id": id, "status": "error", "error": String(describing: error)])
      }
    }
    await proxy.unload()
    try out.write(to: URL(filePath: outPath), options: .withoutOverwriting)
  }

  /// Loads the frozen Float32 PCM and verifies its byte count and SHA-256 against the manifest.
  static func loadFrozenPCM(_ row: [String: Any]) throws -> [Float] {
    guard let path = row["decoded_pcm_path"] as? String,
      let expectedSHA = row["decoded_pcm_sha256"] as? String,
      let count = row["decoded_sample_count"] as? Int
    else { throw ParityError.badRow }
    let data = try Data(contentsOf: URL(filePath: path))
    guard data.count == count * 4 else { throw ParityError.sizeMismatch(data.count, count * 4) }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard digest == expectedSHA else { throw ParityError.hashMismatch }
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  }

  static func runClip(
    id: String, row: [String: Any], samples: [Float], proxy: RecordingWhisperBackend
  ) async throws -> [String: Any] {
    let suite = "ew-lid-parity-\(UUID().uuidString)"
    // The detector owns its private defaults; the domain is removed through a separate handle.
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let detector = Self.makeDetector(suite: suite)
    let adapter = WhisperEngineAdapter(
      backend: proxy, engineMutationScope: .alwaysAllowedForTesting, languageDetector: detector)
    try await adapter.warmUp(modelReceipt: nil)
    await proxy.resetRecording()

    let start = ContinuousClock.now
    try await adapter.beginSession(
      SessionID(), options: TranscriptionOptions(language: nil), streaming: false)
    adapter.observeSpeechSegments(
      [SpeechSegment(startSample: 0, endSample: samples.count)], rawCaptureSamples: samples)
    let outcome = await adapter.finalize(batchSamples: nil)
    let elapsedMs = (ContinuousClock.now - start) / .milliseconds(1)
    let recorded = await proxy.recording

    var result: [String: Any] = [
      "kind": "row", "id": id, "status": "ok",
      "language": row["language"] as? String ?? "", "bucket": row["bucket"] as? String ?? "",
      "elapsed_ms": elapsedMs, "lid_batch": recorded.batch,
      "decode_language_hints": recorded.decodeLanguages.map { hint -> Any in hint ?? NSNull() },
    ]
    if let lid = adapter.lastLanguageDetection {
      result["lid_result"] = [
        "lang": lid.lang ?? NSNull(), "confidence": lid.confidence, "margin": lid.margin,
        "tier": lid.tier.rawValue, "abstained": lid.abstained, "voiced": lid.voicedDuration,
        "used_session_prior": lid.usedSessionPrior,
      ]
    }
    switch outcome {
    case .transcript(let asr):
      result["outcome"] = "transcript"
      result["text"] = asr.text
      result["result_language"] = asr.language ?? NSNull()
    case .empty(let evidence):
      result["outcome"] = "empty"
      result["had_speech_evidence"] = evidence
    case .cancelled:
      result["outcome"] = "cancelled"
    case .failed(let error):
      result["outcome"] = "failed"
      result["error"] = String(describing: error)
    }
    return result
  }

  /// Built off the main actor, so the private defaults never cross an isolation boundary.
  nonisolated static func makeDetector(suite: String) -> LanguageDetector {
    LanguageDetector(clock: FixedParityClock(), defaults: UserDefaults(suiteName: suite) ?? .init())
  }

  enum ParityError: Error {
    case badRow
    case sizeMismatch(Int, Int)
    case hashMismatch
  }
}

struct FixedParityClock: LanguageDetectorClock {
  func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
}

/// Forwards every call to the real backend and records what the detector and decode saw.
actor RecordingWhisperBackend: WhisperBackendDriving {
  struct Recording: Sendable {
    var batch: [String: any Sendable] = [:]
    var decodeLanguages: [String?] = []
  }

  private let base: any WhisperBackendDriving
  private(set) var recording = Recording()

  init(base: any WhisperBackendDriving) { self.base = base }

  func resetRecording() { recording = Recording() }

  // The protocol reads these synchronously; mirrored from the base after each prepare/unload.
  private(set) var isReady = false
  private(set) var modelVariantName = ""
  private(set) var lastWarmupInferenceMs: Int?

  func prepare() async throws {
    try await base.prepare()
    isReady = await base.isReady
    modelVariantName = await base.modelVariantName
    lastWarmupInferenceMs = await base.lastWarmupInferenceMs
  }

  func transcribe(
    audioSamples: [Float], options: TranscriptionOptions,
    onInferenceEntered: ASRInferenceEntryObserver?
  ) async throws -> ASRResult {
    recording.decodeLanguages.append(options.language)
    return try await base.transcribe(
      audioSamples: audioSamples, options: options, onInferenceEntered: onInferenceEntered)
  }

  func observeLID(samples: [Float], maxWindows: Int) async -> LIDObservationBatch {
    let batch = await base.observeLID(samples: samples, maxWindows: maxWindows)
    var record: [String: any Sendable] = ["max_windows": maxWindows, "samples": samples.count]
    switch batch {
    case .unavailable: record["kind"] = "unavailable"
    case .cancelled: record["kind"] = "cancelled"
    case .noWindows: record["kind"] = "no_windows"
    case .error(let reason):
      record["kind"] = "error"
      record["reason"] = reason
    case .observations(let observations):
      record["kind"] = "observations"
      record["windows"] = observations.map { observation -> [String: any Sendable] in
        ["lang": observation.argmaxLang, "log_prob": observation.logProb]
      }
    }
    recording.batch = record
    return batch
  }

  func makeStreamingSession(
    options: TranscriptionOptions, vendorDecodeOccupancy: VendorDecodeOccupancy,
    onDecode: ASRInferenceEntryObserver?
  ) async -> (any WhisperKitIncrementalSession)? {
    nil
  }

  func unload() async {
    await base.unload()
    isReady = await base.isReady
  }
}
