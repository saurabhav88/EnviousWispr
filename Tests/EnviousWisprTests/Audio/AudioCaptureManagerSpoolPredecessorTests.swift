@preconcurrency import AVFoundation
import EnviousWisprCore
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprAudio

// Uses the manager's `#if DEBUG` arming seam, so the whole suite is DEBUG-only.
#if DEBUG

  // MARK: - #1579 defect 1b — arming a spool must RETIRE its predecessor.
  //
  // `startRecoverySpooling` used to nil `recoverySpoolWriter` and leave
  // `recoveryFeedTask` running. That task retains its writer and guards only on
  // `isCapturing` + `writer.isHealthy`, both true again once a new session arms,
  // so it would wake and append the NEW session's audio into the OLD session's
  // encrypted spool — and advance the shared `recoveryFedSampleCount` so the new
  // writer skipped that same range. A crash could then hand the user a recording
  // spliced from two dictations, or one silently missing a chunk.
  //
  // These tests assert on the REAL spool files on disk, not manager internals:
  // the user-visible property is "the previous recording's file is properly
  // closed", and that is what the replayer reads.
  @MainActor
  @Suite("AudioCaptureManager recovery-spool predecessor retirement (#1579)")
  struct AudioCaptureManagerSpoolPredecessorTests {

    private static func key() -> Data {
      Data(repeating: 7, count: RecoveryConstants.aesKeyByteCount)
    }

    private static func snapshot() -> RecordingSettingsSnapshot {
      RecordingSettingsSnapshot(
        backendType: .parakeet, backendSupportsLanguageDetection: false, languageMode: .auto,
        wordCorrectionEnabled: false, fillerRemovalEnabled: false,
        emojiFormatterEnabled: false, spokenPunctuationEnabled: false,
        customWordsVersion: nil,
        llmProvider: "none", llmModel: "none", polishPromptVersion: nil)
    }

    /// A directive pointing at a fresh file inside `dir`, encoded exactly as the
    /// kernel encodes it (the manager decodes this same JSON in production).
    private static func payload(sessionID: String, dir: URL) throws -> Data {
      let directive = RecoverySpoolDirective(
        enabled: true,
        recoverySessionID: sessionID,
        spoolPath: dir.appendingPathComponent("\(sessionID).\(RecoveryConstants.fileExtension)")
          .path,
        keyData: key(),
        settingsSnapshot: snapshot())
      return try JSONEncoder().encode(directive)
    }

    private static func makeTempDir() throws -> URL {
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ew-1579-spool-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir
    }

    private static func terminationReason(of sessionID: String, in dir: URL) throws
      -> RecoverySpoolTerminationReason?
    {
      let store = RecoverySpoolStore(directory: dir)
      return try store.recover(
        recoverySessionID: sessionID, cipher: RecoverySpoolCipher(mode: .aesGcm256, keyData: key())
      ).terminationReason
    }


    /// Barrier on a writer's serial write queue. `finalize` is idempotent and
    /// ALWAYS invokes `completion` — including on the already-finalized path — so
    /// this cannot hang; it simply queues behind whatever the manager already
    /// submitted. Without it these tests race the writer's async file I/O and pass
    /// or fail on timing. Same pattern as `RecoverySpoolWriterTests.awaitFinalize`.
    private static func drain(_ writer: RecoverySpoolWriter?) async {
      guard let writer else { return }
      await withCheckedContinuation { continuation in
        writer.finalize(reason: .cleanFinalized) { continuation.resume() }
      }
    }

    // MARK: - 1. Arming a successor retires the predecessor

    @Test("arming a second spool finalizes the first as .interrupted and leaves no live feed")
    func armingRetiresThePredecessor() async throws {
      let dir = try Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let manager = AudioCaptureManager()
      manager.isCapturing = true  // the feed loop's guard, armed without hardware

      manager.armRecoverySpoolingForTesting(payload: try Self.payload(sessionID: "first", dir: dir))
      // Precondition: the first arm really did start a feed. Without this the
      // retirement assertion below would pass against nothing.
      #expect(manager.debugHasLiveRecoveryFeedTask)
      let firstWriter = manager.debugRecoverySpoolWriter

      // The successor arms with no intervening stop. This is the 1b scenario.
      manager.armRecoverySpoolingForTesting(
        payload: try Self.payload(sessionID: "second", dir: dir))
      await Self.drain(firstWriter)

      #expect(
        try Self.terminationReason(of: "first", in: dir) == .interrupted,
        "the predecessor's file is properly closed, not abandoned unmarked")
      #expect(
        manager.debugHasLiveRecoveryFeedTask,
        "the SUCCESSOR's feed is live (the first one's was cancelled and replaced)")
    }

    // MARK: - 2. Control: a first arm does not write a spurious terminal marker
    //
    // Without this control, a bug that finalized EVERY arm — including the first
    // — would still pass the test above while destroying live recovery.

    @Test("a first arm with no predecessor retires nothing and leaves its feed live")
    func firstArmDoesNotFinalizeAnything() async throws {
      let dir = try Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let manager = AudioCaptureManager()
      manager.isCapturing = true

      manager.armRecoverySpoolingForTesting(payload: try Self.payload(sessionID: "only", dir: dir))

      // Deliberately NOT asserting `terminationReason == nil` here. The writer's
      // file I/O is async, so an unmarked read is indistinguishable from a file
      // that simply has not been written yet — it would pass for the wrong reason,
      // and the only available barrier (`finalize`) would itself write the marker.
      // The live feed task IS deterministic and is the real control: a bug that
      // finalized every arm, including the first, would cancel this feed and fail
      // here while still passing the retirement test above.
      #expect(manager.debugHasLiveRecoveryFeedTask, "its own feed is running, not retired")
      // Deterministic oracle rather than a directory read: `writer.start()`
      // creates the file asynchronously, so listing the directory here can come
      // back empty under load even though arming succeeded (whole-diff review P2).
      #expect(manager.debugRecoverySpoolWriter != nil, "its own writer is armed")
    }

    // MARK: - 3. Disabled directive still retires a live predecessor
    //
    // The early `return` for a disabled/undecodable directive sits AFTER the
    // retirement block. If retirement had been placed after that guard instead,
    // turning recovery off mid-session would strand the previous writer forever.

    @Test("arming with recovery DISABLED still retires a live predecessor")
    func disabledDirectiveStillRetiresPredecessor() async throws {
      let dir = try Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let manager = AudioCaptureManager()
      manager.isCapturing = true

      manager.armRecoverySpoolingForTesting(payload: try Self.payload(sessionID: "live", dir: dir))
      #expect(manager.debugHasLiveRecoveryFeedTask)
      let liveWriter = manager.debugRecoverySpoolWriter

      manager.armRecoverySpoolingForTesting(payload: nil)  // recovery off for the next take
      await Self.drain(liveWriter)

      #expect(
        try Self.terminationReason(of: "live", in: dir) == .interrupted,
        "the predecessor is closed even though the successor arms nothing")
      #expect(
        manager.debugHasLiveRecoveryFeedTask == false,
        "and no feed task survives into a session that has no spool")
    }

    // MARK: - 3b. A superseded spool keeps the audio the poll loop never reached
    //
    // Cloud review P2. The feed task polls about once a second, so a predecessor
    // retired mid-poll has unfed samples sitting in `capturedSamples`. If
    // retirement runs after that buffer is cleared — which is where it originally
    // sat, despite a comment claiming otherwise — those samples are gone from the
    // spool forever. Recovery would then hand back a recording missing its ending.

    @Test("retiring a predecessor writes the samples its poll loop had not consumed")
    func retirementPreservesTheUnfedTail() async throws {
      let dir = try Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let manager = AudioCaptureManager()
      manager.isCapturing = true

      manager.armRecoverySpoolingForTesting(payload: try Self.payload(sessionID: "tail", dir: dir))
      let writer = try #require(manager.debugRecoverySpoolWriter)
      // Audio arrives but the 1s poll has not run, so none of it is fed yet.
      manager.ingestSamples([0.5, -0.5, 0.25, -0.25], level: 0.5)
      #expect(manager.capturedSamples.count == 4, "precondition: samples are pending, unfed")

      manager.armRecoverySpoolingForTesting(payload: try Self.payload(sessionID: "next", dir: dir))
      await Self.drain(writer)

      let recovered = try RecoverySpoolStore(directory: dir).recover(
        recoverySessionID: "tail", cipher: RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key()))
      #expect(recovered.terminationReason == .interrupted, "marked superseded, not clean")
      #expect(
        recovered.samples == [0.5, -0.5, 0.25, -0.25],
        "the pending tail reached the spool before the successor cleared the buffer")
    }

    // MARK: - 4. Defect 1c — the no-active-source stop still closes its spool
    //
    // Production ingress, reached through real code rather than by installing the
    // end state: an engine interruption clears `isCapturing` while leaving
    // `activeSource` alive, the user switches "Keep engine warm" off, and the
    // manager's OWN `reconcileWarmEnginePolicy` tears the source down. The
    // kernel's stop then lands on the nil-source early return, which used to
    // return without ever finalizing the spool.

    @Test("stop with no active source finalizes its spool instead of abandoning it")
    func nilSourceStopStillFinalizesTheSpool() async throws {
      let dir = try Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let manager = AudioCaptureManager()
      let stub = StopFenceStub()
      manager.installSourceFactoryForTesting { _ in stub }
      try await manager.startEnginePhase()

      manager.armRecoverySpoolingForTesting(
        payload: try Self.payload(sessionID: "interrupted-take", dir: dir))
      manager.isCapturing = true
      #expect(manager.debugHasLiveRecoveryFeedTask, "precondition: the spool is armed and live")
      let takeWriter = manager.debugRecoverySpoolWriter

      // The interruption's observable effect: capture stops, the source survives.
      manager.isCapturing = false
      // The user's setting change, driving the manager's real reconciliation into
      // `performEngineTeardown()` — this is what actually nils `activeSource`.
      manager.warmEnginePolicy = .off

      let result = await manager.stopCapture(sessionID: manager.currentCaptureSessionID)
      await Self.drain(takeWriter)

      #expect(result.samples.isEmpty, "no audio was ingested in this test")
      // THE 1c fix: the spool is closed with a terminal marker, so a later launch
      // cannot replay it as a truncated recording.
      #expect(try Self.terminationReason(of: "interrupted-take", in: dir) == .cleanFinalized)
      #expect(
        manager.debugHasLiveRecoveryFeedTask == false, "and its feed task is cancelled")
    }
  }

  /// Local stub for the teardown ingress above. Mirrors the stop-fence suite's
  /// stub; kept separate because that one is nested in its own suite.
  private final class StopFenceStub: AudioInputSource {
    var onSamples: (@Sendable ([Float], Float) -> Void)?
    var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onInterrupted: ((EngineInterruptionCause) -> Void)?
    var onLifecycleSignal: (@Sendable (String) -> Void)?
    var onCaptureStalled: ((CaptureStallContext) -> Void)?
    var captureGeneration: UInt64 = 0

    /// #1810: stubs drain no pre-roll. A stored var rather than a literal so a
    /// test can set a value — including a negative, to prove the clamp.
    var drainedPreRollSampleCount: Int = 0
    let captureSourceType = "stub"
    var running = true
    var isCapturing = false
    var isRunning: Bool { running }
    #if DEBUG
      var debugZeroFillController: DebugZeroFillController?
      var wakeDiagnostic: (firstNonZeroRoutedIndex: Int?, routedCountAtActivation: Int?) {
        (nil, nil)
      }
    #endif
    /// #1714: the undefaulted protocol witness. This suite never fires it;
    /// declaring it explicitly is exactly what the undefaulted requirement is for.
    var onInputResolutionAttemptFinalized: ((FinalizedInputResolutionAttempt) -> Void)?
    var boundToReturn = BoundInputDevice(
      deviceID: 1, deviceUID: "stub-uid", transportLabel: "stub",
      resolutionSource: "system_default")
    func prepare() async throws -> BoundInputDevice { boundToReturn }
    func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
      AsyncStream { $0.finish() }
    }
    func stop() async -> [Float] {
      running = false
      return []
    }
    func deactivateCapture() {}
    func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async
      -> Bool
    { true }
    func abortPrepare() {}
    func rebuild() { running = false }
  }

#endif
