@preconcurrency import AVFoundation
import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM
@testable import EnviousWisprServices
@testable import EnviousWisprStorage

/// The per-orphan `RecoverySpoolReplayer` (#1063 PR2): decrypt → transcribe →
/// polish → save a non-auto-pasting "Recovered" transcript, ONE attempt with a
/// crash-loop marker, and a generation guard that drops a discarded-but-in-flight
/// result before saving. Driven against a real encrypted spool on disk + a fake
/// batch ASR.
@MainActor
@Suite("Recovery spool replayer (#1063 PR2)")
struct RecoverySpoolReplayerTests {

  /// Minimal batch-ASR fake: returns a canned result, counts calls, and runs an
  /// optional hook when `transcribe` is entered (to simulate a mid-flight Discard).
  final class FakeBatchASR: ASRManagerInterface {
    var activeBackendType: ASRBackendType = .parakeet
    var isModelLoaded = false
    var isStreaming = false
    var downloadProgress: Double = 0
    var downloadPhase = "idle"
    var downloadDetail = ""
    var onServiceInterrupted: (() -> Void)?
    var loadProgressTickReporter: (@MainActor @Sendable (Date?, String) -> Void)?

    var transcribeCallCount = 0
    var cannedText = "hello recovered world"
    var onTranscribe: (() -> Void)?
    var onLoadModel: (() -> Void)?

    func loadModel() async throws {
      isModelLoaded = true
      onLoadModel?()
    }
    func unloadModel() async {}
    func setInitialBackendType(_ type: ASRBackendType) { activeBackendType = type }
    func switchBackend(to type: ASRBackendType) async { activeBackendType = type }
    var activeBackendSupportsStreaming: Bool { get async { false } }
    func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult
    {
      transcribeCallCount += 1
      onTranscribe?()
      return ASRResult(
        text: cannedText, language: options.language, duration: 1, processingTime: 1,
        backendType: activeBackendType)
    }
    func startStreaming(options: TranscriptionOptions) async throws {}
    func feedAudio(_ buffer: AVAudioPCMBuffer) async throws {}
    func finalizeStreaming() async throws -> ASRResult {
      ASRResult(text: "", language: nil, duration: 0, processingTime: 0, backendType: .parakeet)
    }
    func cancelStreaming() async {}
    func noteTranscriptionComplete(policy: ModelUnloadPolicy) {}
    func cancelIdleTimer() {}
    func cancelInFlightLoad() {}
  }

  private static func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-replayer-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private static func key(_ byte: UInt8 = 7) -> Data {
    Data(repeating: byte, count: RecoveryConstants.aesKeyByteCount)
  }

  /// Offline snapshot — no polish provider, deterministic chain.
  private static func snapshot() -> RecordingSettingsSnapshot {
    RecordingSettingsSnapshot(
      backendType: .parakeet,
      backendSupportsLanguageDetection: false,
      languageMode: .auto,
      wordCorrectionEnabled: false,
      fillerRemovalEnabled: false,
      emojiFormatterEnabled: false,
      customWordsVersion: nil,
      llmProvider: "none",
      llmModel: "",
      polishPromptVersion: nil)
  }

  private struct Harness {
    let replayer: RecoverySpoolReplayer
    let asr: FakeBatchASR
    let spoolStore: RecoverySpoolStore
    let keyStore: RecoveryKeyStore
    let transcriptStore: TranscriptStore
    let transcriptCoordinator: TranscriptCoordinator
  }

  private static func makeHarness() -> Harness {
    let spoolDir = tempDir()
    let keyStore = RecoveryKeyStore(backend: .file, fileDirectory: tempDir())
    let transcriptStore = TranscriptStore(directory: tempDir())
    let transcriptCoordinator = TranscriptCoordinator(store: transcriptStore)
    let asr = FakeBatchASR()
    let replayer = RecoverySpoolReplayer(
      asrManager: asr,
      keyStore: keyStore,
      makeSpoolStore: { RecoverySpoolStore(directory: spoolDir) },
      transcriptStore: transcriptStore,
      transcriptCoordinator: transcriptCoordinator,
      keychainManager: KeychainManager(),
      outputClassifierHolder: OutputClassifierHolder(),
      currentVocabulary: { (.empty, .empty) })
    return Harness(
      replayer: replayer, asr: asr,
      spoolStore: RecoverySpoolStore(directory: spoolDir), keyStore: keyStore,
      transcriptStore: transcriptStore, transcriptCoordinator: transcriptCoordinator)
  }

  /// Write a real encrypted spool + store its key, so the replayer can decrypt it.
  private static func seedSpool(_ h: Harness, id: String, samples: [Float]) async throws {
    let keyData = key()
    try h.keyStore.store(keyData: keyData, for: id)
    let cipher = RecoverySpoolCipher(mode: .aesGcm256, keyData: keyData)
    let writer = RecoverySpoolWriter(
      recoverySessionID: id, spoolURL: h.spoolStore.spoolURL(for: id),
      cipher: cipher, settings: snapshot(), appVersion: "1.0.0",
      createdAt: Date(timeIntervalSince1970: 0))
    writer.start()
    writer.append(samples)
    await withCheckedContinuation { c in writer.finalize(reason: .cleanFinalized) { c.resume() } }
  }

  @Test("happy path: orphan recovered → saved as isRecovered, spool + key deleted")
  func happyPath() async throws {
    let h = Self.makeHarness()
    let id = "ok-\(UUID().uuidString)"
    try await Self.seedSpool(h, id: id, samples: [0.1, 0.2, 0.3])
    let outcome = await h.replayer.replay(recoverySessionID: id, isAborted: { false })
    #expect(outcome == .recovered)
    #expect(h.asr.transcribeCallCount == 1)
    let saved = h.transcriptCoordinator.transcripts
    #expect(saved.count == 1)
    #expect(saved.first?.isRecovered == true)
    #expect(saved.first?.recoverySessionID == id)
    #expect(saved.first?.displayText.contains("hello") == true)
    #expect(!FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: id).path))
    #expect(throws: RecoveryKeyStoreError.notFound) { try h.keyStore.retrieve(for: id) }
  }

  @Test("one-attempt guard: a marker present on entry ABANDONS (no transcribe, deleted)")
  func markerPresentAbandons() async throws {
    let h = Self.makeHarness()
    let id = "loop-\(UUID().uuidString)"
    try await Self.seedSpool(h, id: id, samples: [0.4])
    // Simulate a prior attempt that crashed the app: its marker survived.
    try h.spoolStore.writeAttemptMarker(for: id)
    let outcome = await h.replayer.replay(recoverySessionID: id, isAborted: { false })
    #expect(outcome == .abandoned)
    #expect(h.asr.transcribeCallCount == 0, "never re-transcribe a recording that crashed us")
    #expect(h.transcriptCoordinator.transcripts.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: id).path))
  }

  @Test("the attempt marker is written BEFORE transcribe (crash-loop guard armed)")
  func markerWrittenBeforeTranscribe() async throws {
    let h = Self.makeHarness()
    let id = "armed-\(UUID().uuidString)"
    try await Self.seedSpool(h, id: id, samples: [0.5])
    var markerPresentAtTranscribe = false
    h.asr.onTranscribe = { [spoolStore = h.spoolStore] in
      markerPresentAtTranscribe = spoolStore.hasAttemptMarker(for: id)
    }
    _ = await h.replayer.replay(recoverySessionID: id, isAborted: { false })
    #expect(markerPresentAtTranscribe, "marker must exist before the risky transcribe runs")
  }

  @Test("decrypt fail (missing key) → failed, deleted, no transcribe")
  func missingKeyFails() async throws {
    let h = Self.makeHarness()
    let id = "nokey-\(UUID().uuidString)"
    try await Self.seedSpool(h, id: id, samples: [0.6])
    // Destroy the key so decrypt fails closed.
    try h.keyStore.delete(for: id)
    let outcome = await h.replayer.replay(recoverySessionID: id, isAborted: { false })
    #expect(outcome == .failed)
    #expect(h.asr.transcribeCallCount == 0)
    #expect(h.transcriptCoordinator.transcripts.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: id).path))
  }

  @Test("Discard during transcribe drops the result — nothing saved (generation guard, R2)")
  func discardDuringTranscribeDropsResult() async throws {
    let h = Self.makeHarness()
    let id = "disc-\(UUID().uuidString)"
    try await Self.seedSpool(h, id: id, samples: [0.7])
    // The user hits Discard WHILE transcribe runs: flip the abort flag mid-flight.
    var discarded = false
    h.asr.onTranscribe = { discarded = true }
    let outcome = await h.replayer.replay(recoverySessionID: id, isAborted: { discarded })
    #expect(outcome == .aborted)
    #expect(h.transcriptCoordinator.transcripts.isEmpty, "a discarded result never saves")
  }

  @Test("Discard during loadModel skips the expensive transcribe (P2)")
  func discardDuringLoadSkipsTranscribe() async throws {
    let h = Self.makeHarness()
    let id = "loaddisc-\(UUID().uuidString)"
    try await Self.seedSpool(h, id: id, samples: [0.9])
    // The user hits Discard while the model is still loading.
    var discarded = false
    h.asr.onLoadModel = { discarded = true }
    let outcome = await h.replayer.replay(recoverySessionID: id, isAborted: { discarded })
    #expect(outcome == .aborted)
    #expect(h.asr.transcribeCallCount == 0, "no transcribe runs after Discard during load")
    #expect(h.transcriptCoordinator.transcripts.isEmpty)
  }

  @Test("a recovered transcript with NO polish output carries no provider/model stamp (#1305)")
  func nilPolishCarriesNoProviderStamp() async throws {
    // The snapshot's llmProvider/llmModel describe what was CONFIGURED at
    // record time, not what ran. This spool's snapshot disables polish
    // (provider "none"), so `polishedText` is nil — the saved transcript must
    // not be labeled with any provider, matching the live path's
    // no-stamp-on-skip contract. Pre-#1305 the replayer stamped the snapshot
    // values unconditionally.
    let h = Self.makeHarness()
    let id = "stamp-\(UUID().uuidString)"
    try await Self.seedSpool(h, id: id, samples: [0.3, 0.2])
    let outcome = await h.replayer.replay(recoverySessionID: id, isAborted: { false })
    #expect(outcome == .recovered)
    let saved = try #require(h.transcriptCoordinator.transcripts.first)
    #expect(saved.polishedText == nil)
    #expect(saved.llmProvider == nil)
    #expect(saved.llmModel == nil)
  }
}
