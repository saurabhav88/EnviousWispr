@preconcurrency import AVFoundation
@testable import EnviousWisprASR
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
/// guarded attempt, and a generation guard that drops a discarded-but-in-flight
/// result before saving. #1464: the replayer NO LONGER destroys the spool/key —
/// the coordinator (sole destructor) does that after `replay()` returns — so
/// these tests assert the outcome + typed telemetry + that the spool/key REMAIN.
/// #1740: a History-save failure now LEAVES the attempt marker committed, so a
/// second replay abandons before ASR; the marker is cleared only where no ASR
/// ran (the transient-Keychain deferral).
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
      spokenPunctuationEnabled: false,
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

  /// `now` is injectable so the #2087 expiry guard can be exercised without
  /// waiting 24 hours or depending on the wall clock. Defaults to real time, so
  /// every pre-existing test keeps its exact behaviour.
  private static func makeHarness(
    transcriptDir: URL? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
  ) -> Harness {
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
      now: now,
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
    let saved = h.transcriptCoordinator.visibleTranscripts
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
    #expect(
      h.asr.transcribeCallCount == 0, "never re-transcribe a spool whose attempt already began")
    #expect(h.transcriptCoordinator.visibleTranscripts.isEmpty)
    // The coordinator deletes on `.abandoned`; the replayer leaves the spool.
    #expect(FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: id).path))
  }

  // MARK: - Escape Recovery provenance (#2087)

  /// A crash between "user pressed cancel" and "finalization finished" must not
  /// upgrade a cancelled dictation into a permanent History row wearing the
  /// crash-Recovered badge. The marker carries the provenance across the crash.
  @Test("a valid escape marker makes replay produce a PENDING row, not permanent History")
  func escapeMarkerProducesPendingRow() async throws {
    // Replay happens one minute after the cancel — inside the 24-hour window.
    // The clock is injected rather than real, because the expiry guard below
    // measures against it and a wall-clock test would start failing the moment
    // the fixed `triggeredAt` aged past a day.
    let triggered = Date(timeIntervalSince1970: 1_755_300_000)
    let h = Self.makeHarness(now: { triggered.addingTimeInterval(60) })
    let id = "esc-\(UUID().uuidString)"
    try await Self.seedSpool(h, id: id, samples: [0.1, 0.2])
    try h.spoolStore.writeEscapeMarker(
      EscapeRecoveryMarker(recoverySessionID: id, triggeredAt: triggered, takeID: "take-42"))

    let outcome = await h.replayer.replay(recoverySessionID: id, isAborted: { false })

    #expect(outcome == .recovered)
    // Invisible to ordinary History: `loadAll` enumerates one level and never
    // sees the `pending/` child, so an un-updated build cannot show this row.
    #expect(try await h.transcriptStore.loadAll().isEmpty, "must NOT land in ordinary History")
    let pending = try await h.transcriptStore.loadPending(now: triggered.addingTimeInterval(60))
    #expect(pending.count == 1)
    #expect(
      pending.first?.isRecovered != true,
      "the crash-rescue badge would misdescribe a deliberate cancel")
    #expect(
      pending.first?.escapeRecoveredAt == triggered,
      "the 24-hour clock runs from the keypress, not from replay")
    #expect(pending.first?.escapeRecoveryTakeID == "take-42", "the funnel join key survives")
  }

  /// #2087: a recovery whose 24 hours elapsed while the Mac was off is born
  /// expired, and must be refused BEFORE the engine runs.
  ///
  /// The wasted-work assertion is the point. Read-time expiry would hide the row
  /// anyway, so transcribing it burns the engine — and on a BYOK provider spends
  /// the user's own money — to produce something they can never see. Asserting
  /// only "no row was saved" would pass even if the whole pipeline had run.
  ///
  /// Boundary chosen deliberately at exactly `+24h`: the guard is `>=`, so the
  /// instant the window closes is already expired. A test at `+25h` would pass
  /// against an off-by-one that lets the boundary itself through.
  @Test("an escape recovery already past 24 hours is refused before any ASR work")
  func expiredEscapeMarkerIsRefusedBeforeTranscribe() async throws {
    let triggered = Date(timeIntervalSince1970: 1_755_300_000)
    let h = Self.makeHarness(
      now: { triggered.addingTimeInterval(AppConstants.pendingTranscriptRetention) })
    let id = "stale-\(UUID().uuidString)"
    try await Self.seedSpool(h, id: id, samples: [0.9])
    try h.spoolStore.writeEscapeMarker(
      EscapeRecoveryMarker(recoverySessionID: id, triggeredAt: triggered))

    let outcome = await h.replayer.replay(recoverySessionID: id, isAborted: { false })

    #expect(outcome == .failed(.unrecoverable))
    #expect(h.asr.transcribeCallCount == 0, "no engine work for a row nobody can ever see")
    #expect(
      !h.spoolStore.hasAttemptMarker(for: id),
      "refused before the attempt marker — an expired row must not spend the one attempt")
    #expect(try await h.transcriptStore.loadAll().isEmpty)
    #expect(try await h.transcriptStore.loadPending(now: triggered).isEmpty)
  }

  /// The half the first version of the pre-ASR gate MISSED.
  ///
  /// It checked elapsed time only, so a future-dated marker — a skewed clock, a
  /// hand-edited file — sailed through, spent the engine, and produced a row the
  /// store then refused as corrupt. Both halves of the admission rule now come
  /// from one place, and this pins the half that was absent.
  ///
  /// Reported as `malformed`, not `expired`: a nonsensical clock is our problem,
  /// while an elapsed window is just a Mac that was switched off.
  @Test("a future-dated escape marker is refused before any ASR work")
  func futureDatedEscapeMarkerIsRefusedBeforeTranscribe() async throws {
    let nowStamp = Date(timeIntervalSince1970: 1_755_300_000)
    let h = Self.makeHarness(now: { nowStamp })
    let id = "future-\(UUID().uuidString)"
    try await Self.seedSpool(h, id: id, samples: [0.7])
    // Comfortably beyond the tolerated forward skew.
    try h.spoolStore.writeEscapeMarker(
      EscapeRecoveryMarker(
        recoverySessionID: id,
        triggeredAt: nowStamp.addingTimeInterval(AppConstants.pendingClockSkewTolerance + 60)))

    let outcome = await h.replayer.replay(recoverySessionID: id, isAborted: { false })

    #expect(outcome == .failed(.unrecoverable))
    #expect(h.asr.transcribeCallCount == 0, "a marker the store would reject must not cost ASR")
    #expect(!h.spoolStore.hasAttemptMarker(for: id))
    #expect(try await h.transcriptStore.loadAll().isEmpty)
    #expect(try await h.transcriptStore.loadPending(now: nowStamp).isEmpty)
  }

  /// The fail-closed direction, and it is the one that matters: a marker that
  /// cannot be trusted must NOT fall back to ordinary crash recovery, because
  /// that produces a permanent row for a dictation the user cancelled.
  ///
  /// Also asserts the refusal happens BEFORE transcribe — the check is at the
  /// entry guard, so a corrupt marker costs no ASR work.
  @Test("a malformed escape marker fails closed before transcribe, saving nothing")
  func malformedEscapeMarkerFailsClosed() async throws {
    let h = Self.makeHarness()
    let id = "bad-\(UUID().uuidString)"
    try await Self.seedSpool(h, id: id, samples: [0.3])
    try Data("not a marker".utf8).write(
      to: h.spoolStore.directoryURL.appendingPathComponent(
        "\(id).\(RecoveryConstants.escapeMarkerFileExtension)"))

    let outcome = await h.replayer.replay(recoverySessionID: id, isAborted: { false })

    #expect(outcome == .failed(.unrecoverable), "the coordinator deletes on every .failed")
    #expect(h.asr.transcribeCallCount == 0, "refused at the entry guard, before any ASR work")
    #expect(try await h.transcriptStore.loadAll().isEmpty, "no permanent row for a cancelled take")
    #expect(
      try await h.transcriptStore.loadPending(now: Date()).isEmpty, "and no pending row either")
  }

  /// The control that keeps the two tests above honest: with NO marker, replay
  /// is byte-for-byte today's behaviour. Without this, a change that treated
  /// every spool as an escape recovery would still pass both tests above.
  @Test("no escape marker leaves ordinary crash recovery exactly as it was")
  func absentEscapeMarkerIsOrdinaryRecovery() async throws {
    let h = Self.makeHarness()
    let id = "plain-\(UUID().uuidString)"
    try await Self.seedSpool(h, id: id, samples: [0.4])

    let outcome = await h.replayer.replay(recoverySessionID: id, isAborted: { false })

    #expect(outcome == .recovered)
    let saved = try await h.transcriptStore.loadAll()
    #expect(saved.count == 1, "ordinary History, as today")
    #expect(saved.first?.isRecovered == true, "the crash badge is correct here")
    #expect(saved.first?.escapeRecoveredAt == nil)
    #expect(try await h.transcriptStore.loadPending(now: Date()).isEmpty)
  }

  @Test("the attempt marker is written BEFORE transcribe (one-attempt guard armed)")
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
    #expect(h.transcriptCoordinator.visibleTranscripts.isEmpty)
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
      #expect(h.transcriptCoordinator.visibleTranscripts.isEmpty)
      // Bypass, not failure: no ASR ran, so the attempt is UNSPENT. The spool +
      // key are retained and the marker is cleared so a later attempt remains
      // eligible instead of being abandoned as already spent.
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
    #expect(h.transcriptCoordinator.visibleTranscripts.isEmpty, "a discarded result never saves")
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
    #expect(h.transcriptCoordinator.visibleTranscripts.isEmpty)
  }

  @Test("a recovered transcript with NO polish output carries no provider/model stamp (#1305)")
  func nilPolishCarriesNoProviderStamp() async throws {
    let h = Self.makeHarness()
    let id = "stamp-\(UUID().uuidString)"
    try await Self.seedSpool(h, id: id, samples: [0.3, 0.2])
    let outcome = await h.replayer.replay(recoverySessionID: id, isAborted: { false })
    #expect(outcome == .recovered)
    let saved = try #require(h.transcriptCoordinator.visibleTranscripts.first)
    #expect(saved.polishedText == nil)
    #expect(saved.llmProvider == nil)
    #expect(saved.llmModel == nil)
  }

  // MARK: - #1740 save failure is a SPENT attempt: marker stays committed

  @Test("save failure KEEPS the spent-attempt marker and cannot run ASR twice")
  func saveFailureKeepsSpentAttemptMarkerAndCannotRunASRTwice() async throws {
    let h = Self.makeHarness(transcriptDir: try Self.unwritableTranscriptDir())
    let id = "savefail-\(UUID().uuidString)"
    try await Self.seedSpool(h, id: id, samples: [0.2, 0.4])

    let first = await h.replayer.replay(recoverySessionID: id, isAborted: { false })
    #expect(first == .failed(.save(.other)))
    #expect(h.asr.transcribeCallCount == 1)
    // #1740: the marker is NOT cleared. It used to be, so that a later launch
    // would replay; that retry is exactly what the one-attempt rule removes.
    #expect(
      h.spoolStore.hasAttemptMarker(for: id),
      "the spent attempt's marker must stay committed")

    // The coordinator deletes on `.failed(.save)`, but deletion is best-effort.
    // Simulate a failed cleanup by leaving the spool in place and replaying
    // again: the committed marker must abandon BEFORE ASR, so one attempt does
    // not depend on the deletion having succeeded.
    let second = await h.replayer.replay(recoverySessionID: id, isAborted: { false })
    #expect(second == .abandoned)
    #expect(h.asr.transcribeCallCount == 1, "a surviving spool must never transcribe twice")
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

    /// #2087: the two non-live admission verdicts must reach DIFFERENT channels,
    /// and the reason is what carries that difference.
    ///
    /// This is the assertion that makes the classification real rather than
    /// decorative. An earlier version of the verdict branch emitted its own
    /// breadcrumb and never called `captureError`, so future-skew was documented
    /// as alerting, carried an alerting category, sat in the alert inventory —
    /// and produced no Sentry error at all. Everything about it looked correct
    /// except what it did.
    ///
    /// Asserted end to end through the replayer, not by calling the classifier:
    /// the classifier was already right in that broken version.
    @Test("expiry and future-skew emit different reasons, so they alert differently")
    func telemetryAdmissionVerdictsRouteSeparately() async throws {
      let stamp = Date(timeIntervalSince1970: 1_755_300_000)

      // Elapsed window — the world being ordinary. Counted, never alerted.
      let expired = Self.makeHarness(now: { stamp })
      let expiredID = "tel-exp-\(UUID().uuidString)"
      try await Self.seedSpool(expired, id: expiredID, samples: [0.6])
      try expired.spoolStore.writeEscapeMarker(
        EscapeRecoveryMarker(
          recoverySessionID: expiredID,
          triggeredAt: stamp.addingTimeInterval(-AppConstants.pendingTranscriptRetention)))
      let expiredBox = await Self.capturingTelemetry {
        _ = await expired.replayer.replay(recoverySessionID: expiredID, isAborted: { false })
      }
      let expiredEvent = try #require(expiredBox.recoveryEvents().first)
      #expect(expiredEvent.stringProps["reason"] == "escape_recovery_expired")
      #expect(
        RecoverySpoolReplayer.isCountedNotAlerted(.escapeRecoveryExpired),
        "a Mac left off is not a defect of ours")

      // A clock we cannot reason about — ours. Alerts.
      let skewed = Self.makeHarness(now: { stamp })
      let skewedID = "tel-skew-\(UUID().uuidString)"
      try await Self.seedSpool(skewed, id: skewedID, samples: [0.6])
      try skewed.spoolStore.writeEscapeMarker(
        EscapeRecoveryMarker(
          recoverySessionID: skewedID,
          triggeredAt: stamp.addingTimeInterval(AppConstants.pendingClockSkewTolerance + 60)))
      let skewedBox = await Self.capturingTelemetry {
        _ = await skewed.replayer.replay(recoverySessionID: skewedID, isAborted: { false })
      }
      let skewedEvent = try #require(skewedBox.recoveryEvents().first)
      #expect(skewedEvent.stringProps["reason"] == "malformed_escape_marker")
      #expect(
        !RecoverySpoolReplayer.isCountedNotAlerted(.malformedEscapeMarker),
        "a marker we wrote that will not read back IS our defect")
    }

    /// The assertions above are NOT sufficient, and it is worth being exact about
    /// why: the bug they were written for — hand-emitting the right telemetry
    /// reason while never calling `captureError` — passes every one of them. The
    /// reason was correct in the broken version. The classifier was correct in
    /// the broken version. The only thing that was wrong was whether Sentry was
    /// ever told, and nothing above observes that.
    ///
    /// So this watches the actual channel. `captureErrorDelegate` fires only on
    /// the alerting path, so its absence and presence ARE the classification.
    @Test("expiry never captures; future-skew captures exactly once, in its own category")
    func admissionVerdictsReachTheRightSentryChannel() async throws {
      final class CaptureSpy: @unchecked Sendable {
        var categories: [SentryBreadcrumb.ErrorCategory] = []
      }
      let spy = CaptureSpy()
      let prior = SentryBreadcrumb.captureErrorDelegate
      SentryBreadcrumb.captureErrorDelegate = { _, category, _, _ in
        spy.categories.append(category)
      }
      defer { SentryBreadcrumb.captureErrorDelegate = prior }

      let stamp = Date(timeIntervalSince1970: 1_755_300_000)

      // Elapsed window: counted only. A capture here would page someone because
      // a Mac was switched off.
      let expired = Self.makeHarness(now: { stamp })
      let expiredID = "chan-exp-\(UUID().uuidString)"
      try await Self.seedSpool(expired, id: expiredID, samples: [0.6])
      try expired.spoolStore.writeEscapeMarker(
        EscapeRecoveryMarker(
          recoverySessionID: expiredID,
          triggeredAt: stamp.addingTimeInterval(-AppConstants.pendingTranscriptRetention)))
      _ = await expired.replayer.replay(recoverySessionID: expiredID, isAborted: { false })

      #expect(spy.categories.isEmpty, "an expired window must never raise a Sentry error")

      // A clock we cannot reason about: ours, and it must actually alert.
      let skewed = Self.makeHarness(now: { stamp })
      let skewedID = "chan-skew-\(UUID().uuidString)"
      try await Self.seedSpool(skewed, id: skewedID, samples: [0.6])
      try skewed.spoolStore.writeEscapeMarker(
        EscapeRecoveryMarker(
          recoverySessionID: skewedID,
          triggeredAt: stamp.addingTimeInterval(AppConstants.pendingClockSkewTolerance + 60)))
      _ = await skewed.replayer.replay(recoverySessionID: skewedID, isAborted: { false })

      #expect(
        spy.categories == [.recoveryMalformedEscapeMarker],
        "exactly one capture, in its own category — not the decrypt catch-all, not silence")
    }

    /// #2132 — THE DATA-LOSS GUARD. Measured on the dev machine 2026-08-01 and
    /// 2026-08-18: a replay failed in the same second it was attempted, with no
    /// engine activity in between, and the recording was DELETED because an
    /// instant refusal spent the single permitted attempt. `ASRError.notReady`
    /// is that refusal — `ParakeetBackend.transcribe`'s entry guard — and
    /// `loadModelSucceedsWhileBackendIsNotReady` proves the real `ASRManager`
    /// can reach it after reporting a successful load.
    ///
    /// If this test ever goes red because the outcome is `.failed`, a recording
    /// that was never decoded is being destroyed again.
    @Test("an engine that was never ready keeps the recording and gives the attempt back")
    func notReadyEngineDefersInsteadOfDeletingTheRecording() async throws {
      let h = Self.makeHarness()
      let id = "tel-notready-\(UUID().uuidString)"
      try await Self.seedSpool(h, id: id, samples: [0.1, 0.2, 0.3])
      h.asr.transcribeError = ASRError.notReady

      // ONE replay only: a second call would meet the one-attempt guard and
      // measure that instead of this fix.
      var outcome: RecoveryReplayOutcome?
      let box = await Self.capturingTelemetry {
        outcome = await h.replayer.replay(recoverySessionID: id, isAborted: { false })
      }

      #expect(
        outcome == .deferred,
        "the engine never looked at the audio, so the attempt is not spent")
      #expect(
        !h.spoolStore.hasAttemptMarker(for: id),
        "marker cleared, so the next launch retries instead of abandoning")
      let e = try #require(box.recoveryEvents().first)
      #expect(e.stringProps["outcome"] == "deferred")
      #expect(e.stringProps["failure_class"] == "not_ready")
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
    /// #2132 UPDATE: these now classify as `.xpc_transport` rather than
    /// `.other`. The protection this test exists for is UNCHANGED and is the
    /// reason it must not be deleted: a bare `is XPCASRTransportError` check
    /// would call all six "unreachable", and the assertion below still fails if
    /// anyone reintroduces that. The expected label is simply more specific now.
    @Test(
      "the new XPCASRTransportError cases are transport, never .xpcUnreachable",
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
      #expect(e.stringProps["failure_class"] == "xpc_transport")
      #expect(
        e.stringProps["failure_class"] != "xpc_unreachable",
        "the narrowing regression this test was written for (#1525 PR I-B)")
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
