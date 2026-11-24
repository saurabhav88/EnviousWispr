@preconcurrency import AVFoundation
import EnviousWisprCore
import EnviousWisprStorage
import Foundation
import Testing
import os

@testable import EnviousWisprAudio
import EnviousWisprAppKitTestSupport

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
  //
  // #2594: every test pins the low-disk preflight to `true`. Arming has one
  // machine-dependent early return: `hasSufficientDiskSpace`, the configured
  // low-disk watermark (`RecoveryConstants.lowDiskWatermarkBytes`) on the spool
  // volume, and this suite writes under the temp directory. A CI failure of all five within milliseconds, writer never
  // created, matched that preflight returning false, although runner capacity
  // was not measured; a re-run on another VM passed. It was first read as a
  // race on the feed task's start, which it cannot be — the task handle is
  // assigned synchronously before arming returns. The watermark branch itself
  // is test 5 below, driven through the same seam.
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
        emojiFormatterEnabled: false, spokenPunctuationEnabled: false, spokenPunctuationStartWords: nil, spokenPunctuationEnglishPeriodWord: nil,
        customWordsVersion: nil,
        llmProvider: "none", llmModel: "none", egOneSize: nil, polishPromptVersion: nil, s1Control: nil,
        englishSpelling: nil, casualModeEnabled: nil)
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
      let dir = TestTemporaryDirectory.url
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
      manager.installDiskSpaceCheckForTesting { _ in true }
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
      manager.installDiskSpaceCheckForTesting { _ in true }
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
      manager.installDiskSpaceCheckForTesting { _ in true }
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
      manager.installDiskSpaceCheckForTesting { _ in true }
      manager.isCapturing = true

      manager.armRecoverySpoolingForTesting(payload: try Self.payload(sessionID: "tail", dir: dir))
      let writer = try #require(manager.debugRecoverySpoolWriter)
      // Audio arrives but the 1s poll has not run, so none of it is fed yet.
      manager.ingestSamples([0.5, -0.5, 0.25, -0.25], level: 0.5)
      #expect(manager.capturedSamples.count == 4, "precondition: samples are pending, unfed")

      manager.armRecoverySpoolingForTesting(payload: try Self.payload(sessionID: "next", dir: dir))
      await Self.drain(writer)

      let recovered = try RecoverySpoolStore(directory: dir).recover(
        recoverySessionID: "tail",
        cipher: RecoverySpoolCipher(mode: .aesGcm256, keyData: Self.key()))
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
      manager.installDiskSpaceCheckForTesting { _ in true }
      let stub = StopFenceStub()
      manager.installSourceFactoryForTesting { _ in stub }
      try await manager.startEnginePhase(startDeadline: MicrophoneStartBudget.deadline(from: .now))

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

    // MARK: - 5. The low-disk preflight arms nothing — and still retires (#2594)
    //
    // The branch whose outcome matches the observed CI failure shape. It had no
    // test: a user on a nearly full disk silently records with no recovery
    // spool, which is the documented design, and the predecessor must still be
    // closed on that path because retirement runs before the preflight.

    private static func awaitPublish(
      on cache: VolumeSpaceCache,
      label: String,
      timeout: Duration = .seconds(5),
      trigger: () throws -> Void
    ) async rethrows {
      let state = OSAllocatedUnfairLock<(done: Bool, timedOut: Bool, waiter: CheckedContinuation<Void, Never>?)>(
        initialState: (false, false, nil))
      cache.installPublishHookForTesting { _, _ in
        let cont = state.withLock { s -> CheckedContinuation<Void, Never>? in
          s.done = true
          let c = s.waiter
          s.waiter = nil
          return c
        }
        cont?.resume()
      }
      defer { cache.installPublishHookForTesting(nil) }
      try trigger()
      let net = Task {
        try? await Task.sleep(for: timeout)
        let cont = state.withLock { s -> CheckedContinuation<Void, Never>? in
          guard !s.done else { return nil }
          s.timedOut = true
          let c = s.waiter
          s.waiter = nil
          return c
        }
        if let cont {
          Issue.record("VolumeSpaceCache publish timed out: \(label)")
          cont.resume()
        }
      }
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        enum Disposition { case done, timedOut, parked }
        let disposition = state.withLock { s -> Disposition in
          if s.timedOut { return .timedOut }
          if s.done { return .done }
          s.waiter = c
          return .parked
        }
        switch disposition {
        case .done: c.resume()
        case .timedOut:
          Issue.record("VolumeSpaceCache publish timed out: \(label)")
          c.resume()
        case .parked: break
        }
      }
      net.cancel()
    }

    @Test("start below plain watermark arms anyway, retires predecessor, and requests refresh (#4893)")
    func lowPlainPreflightStillArmsAndRetiresPredecessor() async throws {
      let dir = try Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let manager = AudioCaptureManager()
      manager.isCapturing = true

      let plainBytes = OSAllocatedUnfairLock(initialState: Int64(RecoveryConstants.lowDiskWatermarkBytes + 1))
      let importantCalls = OSAllocatedUnfairLock(initialState: 0)
      let cache = VolumeSpaceCache(
        readPlain: { _ in plainBytes.withLock { $0 } },
        readImportant: { _ in
          importantCalls.withLock { $0 += 1 }
          return 100
        })
      manager.installVolumeSpaceCacheForTesting(cache)

      manager.armRecoverySpoolingForTesting(
        payload: try Self.payload(sessionID: "before", dir: dir))
      let liveWriter = try #require(manager.debugRecoverySpoolWriter)
      #expect(importantCalls.withLock { $0 } == 0, "healthy plain skips importantUsage")

      plainBytes.withLock { $0 = 100 }
      let lowPayload = try Self.payload(sessionID: "low-plain", dir: dir)
      try await Self.awaitPublish(on: cache, label: "low-plain refresh") {
        manager.armRecoverySpoolingForTesting(payload: lowPayload)
        #expect(manager.debugRecoverySpoolWriter != nil, "start below plain watermark must still arm")
        #expect(manager.debugHasLiveRecoveryFeedTask, "feed loop stays live without blocking start")
      }
      #expect(importantCalls.withLock { $0 } == 1, "low plain requested background refresh")

      await Self.drain(liveWriter)
      #expect(try Self.terminationReason(of: "before", in: dir) == .interrupted)
    }

    // MARK: - 6. #1807 (§C) — `onRecoveryWriterQuiescent` ack firing

    @Test(
      "beginCapturePhase throwing before it ever reaches startRecoverySpooling still acks (round 2)"
    )
    func beginCapturePhaseThrowBeforeSpoolingStillAcks() async throws {
      // No `startEnginePhase()` call, so `activeSource` is nil and
      // `beginCapturePhase` throws before EVER reaching `startRecoverySpooling`
      // — the exact gap Codex chunk-2 review round 2 found: a session that
      // armed via `makeDirective` but whose capture-start failed before Audio
      // ever spooled anything left its `pendingSessions` entry waiting on a
      // writer ack that could never arrive from inside `startRecoverySpooling`
      // itself (nothing in there ever runs).
      let manager = AudioCaptureManager()
      var acked: [String] = []
      manager.onRecoveryWriterQuiescent = { acked.append($0) }

      await #expect(throws: (any Error).self) {
        _ = try await manager.beginCapturePhase(
          recoverySessionID: "no-source-take", recoveryPayload: nil)
      }

      #expect(
        acked == ["no-source-take"],
        "beginCapturePhase's own defer must ack when it exits before startRecoverySpooling")
    }

    @Test("a decode failure fires the no-writer ack, using the separately-supplied id")
    func decodeFailureFiresNoWriterAck() async throws {
      let manager = AudioCaptureManager()
      manager.installDiskSpaceCheckForTesting { _ in true }
      var acked: [String] = []
      manager.onRecoveryWriterQuiescent = { acked.append($0) }

      manager.armRecoverySpoolingForTesting(
        recoverySessionID: "undecodable-take", payload: Data([0xFF, 0x00, 0x01]))

      #expect(manager.debugRecoverySpoolWriter == nil, "no writer is created on decode failure")
      #expect(
        acked == ["undecodable-take"],
        "the ack must fire using the id supplied independently of the payload, since decoding it is what failed"
      )
    }

    @Test("a disabled directive fires the no-writer ack")
    func disabledDirectiveFiresNoWriterAck() async throws {
      let dir = try Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let manager = AudioCaptureManager()
      manager.installDiskSpaceCheckForTesting { _ in true }
      var acked: [String] = []
      manager.onRecoveryWriterQuiescent = { acked.append($0) }
      let directive = RecoverySpoolDirective(
        enabled: false, recoverySessionID: "disabled-take",
        spoolPath: dir.appendingPathComponent("disabled-take.\(RecoveryConstants.fileExtension)")
          .path,
        keyData: nil, settingsSnapshot: Self.snapshot())
      let payload = try JSONEncoder().encode(directive)

      manager.armRecoverySpoolingForTesting(recoverySessionID: "disabled-take", payload: payload)

      #expect(manager.debugRecoverySpoolWriter == nil)
      #expect(acked == ["disabled-take"])
    }

    @Test("3 s check stops on current-recording short importantUsage and acks once (#4893)")
    func feedCheckStopsOnShortImportantAndAcksOnce() async throws {
      let dir = try Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let manager = AudioCaptureManager()
      manager.isCapturing = true
      let cache = VolumeSpaceCache(readPlain: { _ in 100 }, readImportant: { _ in 100 })
      manager.installVolumeSpaceCacheForTesting(cache)

      let ackState = OSAllocatedUnfairLock<(ids: [String], waiter: CheckedContinuation<Void, Never>?)>(
        initialState: ([], nil))
      manager.onRecoveryWriterQuiescent = { id in
        let cont = ackState.withLock { s -> CheckedContinuation<Void, Never>? in
          s.ids.append(id)
          let c = s.waiter
          s.waiter = nil
          return c
        }
        cont?.resume()
      }

      let spoolPath = dir.appendingPathComponent("starved-take.\(RecoveryConstants.fileExtension)").path
      let payload = try Self.payload(sessionID: "starved-take", dir: dir)
      await Self.awaitPublish(on: cache, label: "starved-take initial refresh") {
        manager.armRecoverySpoolingForTesting(recoverySessionID: "starved-take", payload: payload)
      }

      let ackTimeout = Task {
        try? await Task.sleep(for: .seconds(5))
        let cont = ackState.withLock { s -> CheckedContinuation<Void, Never>? in
          guard s.ids.isEmpty else { return nil }
          let c = s.waiter
          s.waiter = nil
          return c
        }
        if let cont {
          Issue.record("Timed out waiting for onRecoveryWriterQuiescent")
          cont.resume()
        }
      }
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let already = ackState.withLock { s -> Bool in
          if !s.ids.isEmpty { return true }
          s.waiter = continuation
          return false
        }
        if already {
          continuation.resume()
        } else {
          manager.stepRecoveryFeedFlushForTesting(spoolPath: spoolPath)
        }
      }
      ackTimeout.cancel()
      let acked = ackState.withLock { $0.ids }

      #expect(acked == ["starved-take"])
      #expect(manager.debugRecoverySpoolWriter == nil)
      #expect(!manager.debugHasLiveRecoveryFeedTask)
      #expect(try Self.terminationReason(of: "starved-take", in: dir) == .lowDiskWatermark)
    }

    @Test("3 s check continues when importantUsage is unknown and ignores prior recording (#4893)")
    func feedCheckIgnoresPriorRecordingAndContinuesWhenUnknown() async throws {
      let dir = try Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let manager = AudioCaptureManager()
      manager.isCapturing = true
      let gate = DispatchSemaphore(value: 0)
      defer { gate.signal() }
      let (secondEnteredStream, secondEnteredCont) = AsyncStream.makeStream(of: Void.self)
      var secondEnteredIter = secondEnteredStream.makeAsyncIterator()
      let reads = OSAllocatedUnfairLock(initialState: 0)

      let cache = VolumeSpaceCache(
        readPlain: { _ in 100 },
        readImportant: { _ in
          let n = reads.withLock { s in s += 1; return s }
          if n == 1 { return 100 }
          if n == 2 {
            secondEnteredCont.yield()
            gate.wait()
          }
          return 100
        })
      manager.installVolumeSpaceCacheForTesting(cache)

      // Earlier recording completes a short refresh; second recording's refresh stays hung ("unknown").
      let firstPayload = try Self.payload(sessionID: "first-take", dir: dir)
      await Self.awaitPublish(on: cache, label: "first-take short refresh") {
        manager.armRecoverySpoolingForTesting(payload: firstPayload)
      }

      let secondPath = dir.appendingPathComponent("second-take.\(RecoveryConstants.fileExtension)").path
      var acked: [String] = []
      manager.onRecoveryWriterQuiescent = { acked.append($0) }
      let firstWriter = manager.debugRecoverySpoolWriter
      manager.armRecoverySpoolingForTesting(
        recoverySessionID: "second-take",
        payload: try Self.payload(sessionID: "second-take", dir: dir))
      await Self.drain(firstWriter)
      let enterGuard = Task {
        try? await Task.sleep(for: .seconds(5))
        secondEnteredCont.finish()
      }
      let secondEntered = await secondEnteredIter.next() != nil
      enterGuard.cancel()
      #expect(secondEntered, "second recording refresh never entered")

      manager.stepRecoveryFeedFlushForTesting(spoolPath: secondPath)
      #expect(manager.debugRecoverySpoolWriter != nil, "prior recording short answer must be ignored")
      #expect(!acked.contains("second-take"), "unknown importantUsage keeps spooling")
    }

    @Test("fresh passing plain check clears recording generation floor (#4893)")
    func passingPlainCheckClearsRecordingFloor() async throws {
      let dir = try Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let manager = AudioCaptureManager()
      // Keep the background 3 s poll task from racing ahead of the test's explicit flush steps.
      manager.isCapturing = false
      let plainVal = OSAllocatedUnfairLock(initialState: Int64(100))
      let gate = DispatchSemaphore(value: 0)
      defer { gate.signal() }
      let reads = OSAllocatedUnfairLock(initialState: 0)
      let cache = VolumeSpaceCache(
        readPlain: { _ in plainVal.withLock { $0 } },
        readImportant: { _ in
          let n = reads.withLock { s in s += 1; return s }
          if n == 1 { return 100 }
          if n == 2 { gate.wait() }
          return RecoveryConstants.lowDiskWatermarkBytes + 1_000
        })
      manager.installVolumeSpaceCacheForTesting(cache)

      let spoolPath = dir.appendingPathComponent("recovering-take.\(RecoveryConstants.fileExtension)").path
      let payload = try Self.payload(sessionID: "recovering-take", dir: dir)
      await Self.awaitPublish(on: cache, label: "recovering-take initial refresh") {
        manager.armRecoverySpoolingForTesting(recoverySessionID: "recovering-take", payload: payload)
      }

      // Space recovers: plain >= watermark clears recoveryMinDiskGeneration.
      plainVal.withLock { $0 = RecoveryConstants.lowDiskWatermarkBytes + 1 }
      manager.stepRecoveryFeedFlushForTesting(spoolPath: spoolPath)
      #expect(manager.debugRecoverySpoolWriter != nil)

      // Plain dips again: must request a fresh generation instead of tripping on old gen-1 100.
      plainVal.withLock { $0 = 100 }
      manager.stepRecoveryFeedFlushForTesting(spoolPath: spoolPath)
      #expect(manager.debugRecoverySpoolWriter != nil)
    }

    @Test(
      "predecessor retirement acks the PREDECESSOR's id, never the successor's — closes the stale-completion hazard"
    )
    func predecessorRetirementAcksThePredecessorID() async throws {
      let dir = try Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let manager = AudioCaptureManager()
      manager.installDiskSpaceCheckForTesting { _ in true }
      manager.isCapturing = true
      var acked: [String] = []

      manager.armRecoverySpoolingForTesting(
        recoverySessionID: "predecessor",
        payload: try Self.payload(sessionID: "predecessor", dir: dir))
      #expect(acked.isEmpty, "the first arm alone must not ack anything yet")

      let successorPayload = try Self.payload(sessionID: "successor", dir: dir)
      // #1807 round-2 correction (Codex chunk-2 review, finding 5): the
      // writer's own `finalize` completion (what `Self.drain` awaits) fires
      // on the writer's write queue; the ACK fires from a SEPARATE MainActor
      // task hop the `notifying:` adapter schedules on top of it (see
      // `RecoverySpoolWriter.finalize(reason:notifying:)`). Draining the
      // writer queue alone races that second hop. Wait on the ack ITSELF.
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        manager.onRecoveryWriterQuiescent = {
          acked.append($0)
          continuation.resume()
        }
        manager.armRecoverySpoolingForTesting(
          recoverySessionID: "successor", payload: successorPayload)
      }

      #expect(
        acked == ["predecessor"],
        "retirement must ack the PREDECESSOR's captured id — never the successor's, and never twice"
      )
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
      resolutionSource: "system_default", inputChannel: 0)
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
