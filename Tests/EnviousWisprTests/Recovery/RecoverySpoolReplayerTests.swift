@preconcurrency import AVFoundation
import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import Foundation
import Security
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM
@testable import EnviousWisprServices
@testable import EnviousWisprStorage

/// The per-orphan `RecoverySpoolReplayer` (#1063 PR2 / #1464): decrypt →
/// transcribe → polish → save a non-auto-pasting "Recovered" transcript, ONE
/// attempt with a crash-loop marker, and a generation guard that drops a
/// discarded-but-in-flight result before saving. #1464: the replayer NO LONGER
/// destroys the spool/key — the coordinator (sole destructor) does that after
/// `replay()` returns — so these tests assert the outcome + typed telemetry + that
/// the spool/key REMAIN. The one exception is the §3.3 save-failure fix: the
/// replayer clears its OWN attempt marker so a retained spool replays next launch.
/// `.serialized` — the telemetry tests set the process-global `testEventHook`.
@MainActor
@Suite("Recovery spool replayer (#1063 PR2, #1464)", .serialized)
struct RecoverySpoolReplayerTests {

  /// Minimal batch-ASR fake: returns a canned result, counts calls, runs an
  /// optional hook when `transcribe`/`loadModel` is entered (to simulate a
  /// mid-flight Discard or a filesystem flip), and can throw a scripted error.
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
    /// When set, `transcribe` throws it instead of returning a result.
    var transcribeError: (any Error)?

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
      if let transcribeError { throw transcribeError }
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

  #if DEBUG
    /// Thread-safe telemetry capture (the hook is `@Sendable`, process-global).
    /// `CapturedTelemetryEvent` + `testEventHook` are DEBUG-only, so everything that
    /// touches them is gated — the Release test-target compile (build-check,
    /// ENABLE_TESTABILITY without DEBUG) must not reference them.
    final class TelemetryBox: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: [CapturedTelemetryEvent] = []
      func add(_ e: CapturedTelemetryEvent) { lock.withLock { stored.append(e) } }
      func recoveryEvents() -> [CapturedTelemetryEvent] {
        lock.withLock { stored.filter { $0.name == "recovery.completed" } }
      }
    }
  #endif

  private static func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-replayer-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// A transcript directory whose PARENT is a regular FILE, so `TranscriptStore
  /// .save` can never open its temp file — a deterministic save failure with no
  /// timing (#1464 §3.3 tests).
  private static func unwritableTranscriptDir() throws -> URL {
    let blocker = tempDir().appendingPathComponent("blocker")
    try Data([0]).write(to: blocker)
    return blocker.appendingPathComponent("transcripts", isDirectory: true)
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
    let spoolDir: URL
    let keyStore: RecoveryKeyStore
    let transcriptStore: TranscriptStore
    let transcriptCoordinator: TranscriptCoordinator
  }

  private static func makeHarness(transcriptDir: URL? = nil) -> Harness {
    let spoolDir = tempDir()
    let keyStore = RecoveryKeyStore(backend: .file, fileDirectory: tempDir())
    let transcriptStore = TranscriptStore(directory: transcriptDir ?? tempDir())
    let transcriptCoordinator = TranscriptCoordinator(store: transcriptStore)
    let asr = FakeBatchASR()
    let replayer = RecoverySpoolReplayer(
      activeEngine: ActiveEngineOperation(
        isLoaded: { asr.isModelLoaded },
        load: { try await asr.loadModel() },
        transcribe: { samples, options in
          try await asr.transcribe(audioSamples: samples, options: options)
        },
        hardCancel: {}),
      keyStore: keyStore,
      makeSpoolStore: { RecoverySpoolStore(directory: spoolDir) },
      transcriptStore: transcriptStore,
      transcriptCoordinator: transcriptCoordinator,
      keychainManager: KeychainManager(),
      outputClassifierHolder: OutputClassifierHolder(),
      currentVocabulary: { (.empty, .empty) })
    return Harness(
      replayer: replayer, asr: asr,
      spoolStore: RecoverySpoolStore(directory: spoolDir), spoolDir: spoolDir, keyStore: keyStore,
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

  #if DEBUG
    /// Set the process-global telemetry hook for the duration of `body`, capturing
    /// every emission. Restores the hook after (the suite is `.serialized`).
    private static func capturingTelemetry(
      _ body: () async throws -> Void
    ) async rethrows -> TelemetryBox {
      let box = TelemetryBox()
      TelemetryService.shared.testEventHook = { @Sendable e in box.add(e) }
      defer { TelemetryService.shared.testEventHook = nil }
      try await body()
      return box
    }
  #endif

  @Test("happy path: orphan recovered → saved as isRecovered; replayer does NOT delete")
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
    #expect(saved.first?.displayText == "hello recovered world")
    // #1464: the replayer no longer destroys — the coordinator deletes after this
    // returns, so the spool + key are STILL PRESENT here.
    #expect(FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: id).path))
    #expect((try? h.keyStore.retrieve(for: id)) != nil)
  }

  @Test("one-attempt guard: a marker present on entry ABANDONS (no transcribe, no delete)")
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
    // The coordinator deletes on `.abandoned`; the replayer leaves the spool.
    #expect(FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: id).path))
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

  @Test("missing key → failed(.unrecoverable), no transcribe, spool retained")
  func missingKeyFails() async throws {
    let h = Self.makeHarness()
    let id = "nokey-\(UUID().uuidString)"
    try await Self.seedSpool(h, id: id, samples: [0.6])
    // Destroy the key so decrypt fails closed.
    try h.keyStore.delete(for: id)
    let outcome = await h.replayer.replay(recoverySessionID: id, isAborted: { false })
    #expect(outcome == .failed(.unrecoverable))
    #expect(h.asr.transcribeCallCount == 0)
    #expect(h.transcriptCoordinator.transcripts.isEmpty)
    #expect(FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: id).path))
  }

  // MARK: - #1707 Phase 3 §3.3: Keychain transient-vs-terminal

  #if DEBUG
    @Test(
      "a transient Keychain read status defers WITHOUT treating it as unrecoverable — spool retained, marker cleared"
    )
    func transientKeyReadDefers() async throws {
      let h = Self.makeHarness()
      let id = "transient-\(UUID().uuidString)"
      try await Self.seedSpool(h, id: id, samples: [0.6])
      DebugRecoveryKeyFaultController.shared.arm(
        status: errSecInteractionNotAllowed, forSessionID: id)
      let outcome = await h.replayer.replay(recoverySessionID: id, isAborted: { false })
      #expect(outcome == .deferred)
      #expect(h.asr.transcribeCallCount == 0, "never reaches transcribe on a deferred key read")
      #expect(h.transcriptCoordinator.transcripts.isEmpty)
      // Bypass, not failure: the spool + key are retained for a retry, and the
      // marker is cleared so a later attempt does not misread this as a
      // crashed attempt (the exact regression this fix prevents).
      #expect(FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: id).path))
      #expect(
        (try? h.keyStore.retrieve(for: id)) != nil, "the ARMED fault is one-shot and consumed")
      #expect(!h.spoolStore.hasAttemptMarker(for: id), "marker cleared so a retry does not abandon")
    }

    @Test(
      "a SECOND replay after a transient-deferred first attempt does NOT see a surviving marker (the exact regression this fix prevents)"
    )
    func secondReplayAfterTransientDeferralDoesNotAbandon() async throws {
      let h = Self.makeHarness()
      let id = "transient-retry-\(UUID().uuidString)"
      try await Self.seedSpool(h, id: id, samples: [0.6])
      DebugRecoveryKeyFaultController.shared.arm(
        status: errSecInteractionNotAllowed, forSessionID: id)
      let first = await h.replayer.replay(recoverySessionID: id, isAborted: { false })
      #expect(first == .deferred)
      // No fault armed this time — the retry reads the REAL stored key.
      let second = await h.replayer.replay(recoverySessionID: id, isAborted: { false })
      #expect(
        second == .recovered, "a clean retry succeeds — the marker never survived to abandon it")
    }

    @Test(
      "errSecAuthFailed / errSecUserCanceled stay terminal — not treated as transient (§3.3's explicit exclusion)",
      arguments: [errSecAuthFailed, errSecUserCanceled]
    )
    func excludedStatusesStayTerminal(status: OSStatus) async throws {
      let h = Self.makeHarness()
      let id = "terminal-\(UUID().uuidString)"
      try await Self.seedSpool(h, id: id, samples: [0.6])
      DebugRecoveryKeyFaultController.shared.arm(status: status, forSessionID: id)
      let outcome = await h.replayer.replay(recoverySessionID: id, isAborted: { false })
      #expect(
        outcome == .failed(.unrecoverable),
        "excluded statuses fall through to the existing terminal path")
      #expect(h.asr.transcribeCallCount == 0)
    }

    @Test(
      "a Keychain-transient marker-clear FAILURE returns .deferredMarkerClearFailed, distinct from plain .deferred"
    )
    func transientKeyReadWithMarkerClearFailure() async throws {
      let h = Self.makeHarness()
      let id = "transient-markerfail-\(UUID().uuidString)"
      try await Self.seedSpool(h, id: id, samples: [0.3])
      defer { _ = chmod(h.spoolDir.path, 0o700) }  // restore so temp cleanup/GC can proceed
      DebugRecoveryKeyFaultController.shared.arm(
        status: errSecInteractionNotAllowed, forSessionID: id)
      // Deterministic ordering via a real signal, not a poll (GitHub cloud
      // review, PR #1732): a poll on `hasAttemptMarker` raced the replayer's
      // own detached Keychain-read task and could miss the narrow true→false
      // window entirely (empirically ~2/3 runs, not a rare edge case).
      // `onAttemptMarkerWritten` fires SYNCHRONOUSLY on the replayer's own
      // MainActor turn, right after the marker write and before the
      // `Task.detached` retrieve is even created — revoking write access from
      // inside it is guaranteed to land before any clear attempt, no race
      // window to catch.
      h.replayer.onAttemptMarkerWritten = { [spoolDir = h.spoolDir] in
        _ = chmod(spoolDir.path, 0o500)
      }
      let outcome = await h.replayer.replay(recoverySessionID: id, isAborted: { false })
      #expect(outcome == .deferredMarkerClearFailed)
      #expect(FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: id).path))
      #expect((try? h.keyStore.retrieve(for: id)) != nil)
    }
  #endif

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

  // MARK: - #1464 §3.3 save-failure retains + clears marker

  @Test("save failure RETAINS the spool + key and clears the marker → .failed(.save)")
  func saveFailureRetainsAndClearsMarker() async throws {
    let h = Self.makeHarness(transcriptDir: try Self.unwritableTranscriptDir())
    let id = "savefail-\(UUID().uuidString)"
    try await Self.seedSpool(h, id: id, samples: [0.2, 0.4])
    let outcome = await h.replayer.replay(recoverySessionID: id, isAborted: { false })
    #expect(outcome == .failed(.save(.other)))
    // The audio is still good — RETAIN it for a next-launch retry, and the marker
    // must be cleared so the retained spool replays (not read as abandoned).
    #expect(FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: id).path))
    #expect((try? h.keyStore.retrieve(for: id)) != nil)
    #expect(!h.spoolStore.hasAttemptMarker(for: id), "marker cleared so next launch replays")
  }

  @Test("save failure whose marker-clear ALSO throws → .failed(.saveMarkerClearFailed), retained")
  func saveFailureMarkerClearAlsoFails() async throws {
    let h = Self.makeHarness(transcriptDir: try Self.unwritableTranscriptDir())
    let id = "markerfail-\(UUID().uuidString)"
    try await Self.seedSpool(h, id: id, samples: [0.5])
    defer { _ = chmod(h.spoolDir.path, 0o700) }  // restore so temp cleanup/GC can proceed
    // The marker is written before transcribe; flip the spool dir read-only DURING
    // transcribe so the post-save `deleteAttemptMarker` (removeItem) throws EACCES.
    h.asr.onTranscribe = { _ = chmod(h.spoolDir.path, 0o500) }
    let outcome = await h.replayer.replay(recoverySessionID: id, isAborted: { false })
    #expect(outcome == .failed(.saveMarkerClearFailed(.other)))
    // Retained THIS launch even though next-launch durability is not guaranteed.
    #expect(FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: id).path))
    #expect((try? h.keyStore.retrieve(for: id)) != nil)
  }

  // MARK: - #1464 root-cause telemetry
  // Gated on DEBUG: these read emissions through `testEventHook` (DEBUG-only), so
  // the Release test-target compile (build-check) never references it.
  #if DEBUG

    @Test("missing-key failure emits key_missing and OMITS audio_decrypted / camp_b_candidate")
    func telemetryKeyMissingOmitsDecrypt() async throws {
      let h = Self.makeHarness()
      let id = "tel-nokey-\(UUID().uuidString)"
      try await Self.seedSpool(h, id: id, samples: [0.6])
      try h.keyStore.delete(for: id)
      let box = await Self.capturingTelemetry {
        _ = await h.replayer.replay(recoverySessionID: id, isAborted: { false })
      }
      let e = try #require(box.recoveryEvents().first)
      #expect(e.stringProps["outcome"] == "failed")
      #expect(e.stringProps["reason"] == "key_missing")
      #expect(
        e.boolProps["audio_decrypted"] == nil, "not reconstructed ⇒ never emit audio_decrypted")
      #expect(e.boolProps["camp_b_candidate"] == nil)
      #expect(e.stringProps["spool_seconds_bucket"] == nil)
    }

    @Test("transcribe failure on good audio is a Camp B candidate with a failure class")
    func telemetryTranscribeFailIsCampBCandidate() async throws {
      let h = Self.makeHarness()
      let id = "tel-xpc-\(UUID().uuidString)"
      try await Self.seedSpool(h, id: id, samples: [0.1, 0.2, 0.3])
      h.asr.transcribeError = XPCASRTransportError.serviceUnreachable
      let box = await Self.capturingTelemetry {
        _ = await h.replayer.replay(recoverySessionID: id, isAborted: { false })
      }
      let e = try #require(box.recoveryEvents().first)
      #expect(e.stringProps["outcome"] == "failed")
      #expect(e.stringProps["reason"] == "transcribe_error")
      #expect(e.stringProps["failure_class"] == "xpc_unreachable")
      #expect(e.boolProps["audio_decrypted"] == true, "reconstruction succeeded ⇒ audio_decrypted")
      #expect(
        e.boolProps["camp_b_candidate"] == true, "good audio, failed transcribe ⇒ camp B candidate")
      #expect(
        e.stringProps["spool_seconds_bucket"] != nil, "bucket derived from reconstructed count")
      // Privacy: never a raw NSError domain/code/description on the wire.
      #expect(e.stringProps["domain"] == nil && e.intProps["code"] == nil)
      #expect(e.stringProps.values.allSatisfy { !$0.contains("serviceUnreachable") })
    }

    /// #1525 PR I-B narrowing-regression: `XPCASRTransportError`'s 6 new
    /// codec/transport cases are NOT "XPC unreachable" — a bare `is
    /// XPCASRTransportError` type-check would have misclassified them,
    /// corrupting recovery telemetry.
    @Test(
      "the new XPCASRTransportError cases classify as .other, not .xpcUnreachable",
      arguments: [
        XPCASRTransportError.requestEncodingFailed("x"),
        .invalidSamplePayload("x"),
        .requestDecodingFailed("x"),
        .modelNotLoaded,
        .responseEncodingFailed("x"),
        .responseDecodingFailed("x"),
      ]
    )
    func telemetryNewTransportCasesClassifyAsOther(error: XPCASRTransportError) async throws {
      let h = Self.makeHarness()
      let id = "tel-xpc-new-\(UUID().uuidString)"
      try await Self.seedSpool(h, id: id, samples: [0.1, 0.2, 0.3])
      h.asr.transcribeError = error
      let box = await Self.capturingTelemetry {
        _ = await h.replayer.replay(recoverySessionID: id, isAborted: { false })
      }
      let e = try #require(box.recoveryEvents().first)
      #expect(e.stringProps["failure_class"] == "other")
    }

    @Test("deferred (attempt-marker write failed) emits marker_write_failed")
    func telemetryDeferredEmitsMarkerWriteFailed() async throws {
      // A spool dir whose PARENT is a regular FILE: the store's re-enforced mkdir is a
      // soft no-op, but `writeAttemptMarker` can't open its temp file → the replay
      // defers BEFORE any risky work, so no seeded spool is needed. (chmod-based
      // read-only can't force this — the store re-chmods the dir to 0700 on init.)
      let blocker = Self.tempDir().appendingPathComponent("blocker")
      try Data([0]).write(to: blocker)
      let badSpoolDir = blocker.appendingPathComponent("spools", isDirectory: true)
      let transcriptStore = TranscriptStore(directory: Self.tempDir())
      let inlineASR = FakeBatchASR()
      let replayer = RecoverySpoolReplayer(
        activeEngine: ActiveEngineOperation(
          isLoaded: { inlineASR.isModelLoaded },
          load: { try await inlineASR.loadModel() },
          transcribe: { samples, options in
            try await inlineASR.transcribe(audioSamples: samples, options: options)
          },
          hardCancel: {}),
        keyStore: RecoveryKeyStore(backend: .file, fileDirectory: Self.tempDir()),
        makeSpoolStore: { RecoverySpoolStore(directory: badSpoolDir) },
        transcriptStore: transcriptStore,
        transcriptCoordinator: TranscriptCoordinator(store: transcriptStore),
        keychainManager: KeychainManager(),
        outputClassifierHolder: OutputClassifierHolder(),
        currentVocabulary: { (.empty, .empty) })
      let id = "tel-defer-\(UUID().uuidString)"
      let box = await Self.capturingTelemetry {
        let outcome = await replayer.replay(recoverySessionID: id, isAborted: { false })
        #expect(outcome == .deferred)
      }
      let e = try #require(box.recoveryEvents().first)
      #expect(e.stringProps["outcome"] == "deferred")
      #expect(e.stringProps["reason"] == "marker_write_failed")
    }

  #endif
}
