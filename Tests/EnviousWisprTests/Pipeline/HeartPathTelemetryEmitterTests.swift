import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// Unit tests for `HeartPathTelemetryEmitter` (#290 R5).
///
/// Two responsibilities under test:
/// 1. Per-session dedup contract for stall + XPC + no-audio interactions.
/// 2. Sentry payload shape preservation. Categories, stages, and load-bearing
///    extras keys must match the prior in-pipeline implementations exactly so
///    the live triage Routine continues filing GitHub issues with stable
///    grouping.
///
/// Tests use injected closure sinks (no real Sentry SDK calls); the recording
/// closure captures `(error, category, stage, extra)` tuples for assertion.
@MainActor
@Suite("HeartPathTelemetryEmitter — dedup + payload preservation")
struct HeartPathTelemetryEmitterTests {

  // MARK: - Test recorder

  final class Recorder {
    struct CapturedError {
      /// The actual error value passed through. Codex code-review feedback
      /// (2026-04-30): without capturing this, tests cannot detect a wrong
      /// `HeartPathError` case being emitted.
      let error: any Error
      let category: SentryBreadcrumb.ErrorCategory
      let stage: String
      let extra: [String: Any]
    }
    struct CapturedBreadcrumb {
      let stage: String
      let message: String
      let data: [String: Any]
    }
    var errors: [CapturedError] = []
    var breadcrumbs: [CapturedBreadcrumb] = []
  }

  private static func makeEmitter(
    backend: ASRBackendType,
    captureTelemetry: CaptureTelemetryState = CaptureTelemetryState(),
    recorder: Recorder
  ) -> HeartPathTelemetryEmitter {
    HeartPathTelemetryEmitter(
      backend: backend,
      captureTelemetry: captureTelemetry,
      captureError: { error, category, stage, extra in
        recorder.errors.append(
          .init(error: error, category: category, stage: stage, extra: extra ?? [:])
        )
      },
      addBreadcrumb: { stage, message, data in
        recorder.breadcrumbs.append(
          .init(stage: stage, message: message, data: data ?? [:])
        )
      }
    )
  }

  /// Expected key-set for every captureError that flows through
  /// `SentryAudioExtras.buildCaptureExtras` with no optional add-ons.
  /// Tests assert the full key-set matches so a forgotten/added extras key
  /// trips the suite immediately. Stall, no-audio, and zombie events all
  /// share this baseline; stall adds the `capture.stall.*` keys; zombie
  /// adds the `time_since_last_successful_recording_ms` /
  /// `config_change_count_since_launch` keys.
  private static let baselineCaptureExtraKeys: Set<String> = [
    "capture.source_type",
    "capture.route",
    "capture.failure_mode",
    "capture.is_actively_capturing",
    "capture_session_id",
    "capture.input_device_uid_preferred",
    "capture.input_device_uid_system_default",
    "capture.preferred_input_set",
    "capture.input_device_divergence",
  ]

  private static let stallExtraKeys: Set<String> =
    baselineCaptureExtraKeys.union([
      "capture.stall.armed_at_uptime_ns",
      "capture.stall.fired_at_uptime_ns",
      "capture.stall.window_ms",
      "capture.engine_started_successfully",
      "capture.tap_installed",
      "capture.format_mismatch",
    ])

  private static let zombieExtraKeys: Set<String> =
    baselineCaptureExtraKeys.union([
      "capture.time_since_last_successful_recording_ms",
      "capture.config_change_count_since_launch",
    ])

  private static let xpcExtraKeys: Set<String> = [
    "xpc.reply_stage", "xpc.error_domain", "xpc.error_code", "capture_session_id",
  ]

  private static let interruptionBaseExtraKeys: Set<String> = [
    "capture_session.kind",
    "capture_session.reason_code",
    "capture_session.reason_label",
    "capture_session.error_domain",
    "capture_session.error_code",
    // #1095: capture_session.error_description (raw OS string) no longer emitted.
    "capture.is_actively_capturing",
    "capture_session_id",
  ]

  private static func stallContext(sessionID: UInt64 = 42) -> CaptureStallContext {
    CaptureStallContext(
      sessionID: sessionID,
      armedAtUptimeNs: 1_000,
      firedAtUptimeNs: 2_000,
      route: "built_in_mic",
      sourceType: "av_audio_engine",
      engineStartedSuccessfully: true,
      tapInstalled: true,
      formatMismatchObserved: false,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: "BuiltInMicrophoneDevice",
      failureMode: .noBuffers
    )
  }

  private static func xpcContext(sessionID: UInt64 = 42) -> XPCReplyFailureContext {
    XPCReplyFailureContext(
      replyStage: "stopCapture",
      errorDomain: "NSCocoaErrorDomain",
      errorCode: 4099,
      errorDescription: "interrupted",
      sessionID: sessionID
    )
  }

  private static func interruptionContext(
    sessionID: UInt64 = 42
  ) -> CaptureSessionInterruptionContext {
    CaptureSessionInterruptionContext(
      kind: .runtimeError,
      reasonCode: 1,
      reasonLabel: nil,
      errorDomain: "AVFoundationErrorDomain",
      errorCode: -11800,
      errorDescription: "operation could not be completed",
      sessionID: sessionID,
      isActivelyCapturing: true
    )
  }

  private static func noAudioContext(sessionID: UInt64 = 42) -> NoAudioContext {
    NoAudioContext(
      sessionID: sessionID,
      durationMs: 1234,
      wasStreaming: false,
      route: "built_in_mic",
      isActivelyCapturing: false,
      captureSourceType: "av_audio_engine",
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: "BuiltInMicrophoneDevice"
    )
  }

  private static func zeroPeakContext(sessionID: UInt64 = 99) -> ZeroPeakContext {
    ZeroPeakContext(
      sessionID: sessionID,
      durationMs: 2000,
      route: "bt_headset",
      sampleCount: 32_000,
      isActivelyCapturing: false,
      captureSourceType: "av_capture_session",
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: "BuiltInMicrophoneDevice"
    )
  }

  // MARK: - Stall dedup

  @Test("stallFired emits once per session and returns true the first time")
  func stallFiresOnce() {
    let recorder = Recorder()
    let emitter = Self.makeEmitter(backend: .parakeet, recorder: recorder)
    let ctx = Self.stallContext(sessionID: 7)

    let firstFired = emitter.stallFired(ctx: ctx, isActivelyCapturing: true)
    let secondFired = emitter.stallFired(ctx: ctx, isActivelyCapturing: true)

    #expect(firstFired)
    #expect(!secondFired)
    #expect(recorder.errors.count == 1)
    let captured = recorder.errors[0]
    #expect(captured.category == .audioCaptureStalled)
    #expect(captured.stage == "recording")
    #expect(captured.extra["capture_session_id"] as? Int == 7)
    #expect(captured.extra["capture.failure_mode"] as? String == "stall_window_elapsed")
  }

  @Test("stallFired re-arms after a session-id change")
  func stallReArmsOnSessionChange() {
    let recorder = Recorder()
    let emitter = Self.makeEmitter(backend: .whisperKit, recorder: recorder)

    _ = emitter.stallFired(ctx: Self.stallContext(sessionID: 1), isActivelyCapturing: true)
    _ = emitter.stallFired(ctx: Self.stallContext(sessionID: 1), isActivelyCapturing: true)
    _ = emitter.stallFired(ctx: Self.stallContext(sessionID: 2), isActivelyCapturing: true)

    #expect(recorder.errors.count == 2)
    let firstSession = recorder.errors[0].extra["capture_session_id"] as? Int
    let secondSession = recorder.errors[1].extra["capture_session_id"] as? Int
    #expect(firstSession == 1)
    #expect(secondSession == 2)
  }

  // MARK: - XPC reply

  @Test("xpcReplyFailed always emits and pins the payload shape")
  func xpcEmitsExpectedExtras() {
    let recorder = Recorder()
    let emitter = Self.makeEmitter(backend: .parakeet, recorder: recorder)

    emitter.xpcReplyFailed(ctx: Self.xpcContext(sessionID: 12))

    #expect(recorder.errors.count == 1)
    let captured = recorder.errors[0]
    #expect(captured.category == .xpcServiceError)
    #expect(captured.stage == "audio")
    #expect(captured.extra["xpc.reply_stage"] as? String == "stopCapture")
    #expect(captured.extra["xpc.error_domain"] as? String == "NSCocoaErrorDomain")
    #expect(captured.extra["xpc.error_code"] as? Int == 4099)
    #expect(captured.extra["capture_session_id"] as? Int == 12)
  }

  // MARK: - captureSessionInterrupted backend asymmetry

  @Test("captureSessionInterrupted omits backend extra for Parakeet")
  func interruptionParakeetOmitsBackend() {
    let recorder = Recorder()
    let emitter = Self.makeEmitter(backend: .parakeet, recorder: recorder)

    emitter.captureSessionInterrupted(ctx: Self.interruptionContext())

    #expect(recorder.errors.count == 1)
    let captured = recorder.errors[0]
    #expect(captured.category == .audioCaptureFailed)
    #expect(captured.stage == "audio")
    #expect(captured.extra["backend"] == nil)
    #expect(captured.extra["capture_session.kind"] as? String == "runtimeError")
  }

  @Test("captureSessionInterrupted includes backend extra for WhisperKit")
  func interruptionWhisperKitIncludesBackend() {
    let recorder = Recorder()
    let emitter = Self.makeEmitter(backend: .whisperKit, recorder: recorder)

    emitter.captureSessionInterrupted(ctx: Self.interruptionContext())

    #expect(recorder.errors.count == 1)
    #expect(recorder.errors[0].extra["backend"] as? String == "whisperKit")
  }

  // MARK: - noAudioCaptured dedup paths

  @Test("noAudioCaptured emits a captureError when no prior stall or XPC fired")
  func noAudioFiresFreshSession() {
    let recorder = Recorder()
    let emitter = Self.makeEmitter(backend: .parakeet, recorder: recorder)

    emitter.noAudioCaptured(ctx: Self.noAudioContext(sessionID: 5))

    #expect(recorder.errors.count == 1)
    #expect(recorder.breadcrumbs.isEmpty)
    let captured = recorder.errors[0]
    #expect(captured.category == .audioCaptureFailed)
    #expect(captured.stage == "recording")
    #expect(captured.extra["capture.failure_mode"] as? String == "no_audio_captured")
  }

  @Test("noAudioCaptured dedups to a breadcrumb after a stall in the same session")
  func noAudioDedupsAfterStall() {
    let recorder = Recorder()
    let emitter = Self.makeEmitter(backend: .parakeet, recorder: recorder)

    _ = emitter.stallFired(ctx: Self.stallContext(sessionID: 9), isActivelyCapturing: true)
    emitter.noAudioCaptured(ctx: Self.noAudioContext(sessionID: 9))

    // Stall captureError fired; noAudio dedup fired only as breadcrumb.
    #expect(recorder.errors.count == 1)
    #expect(recorder.errors[0].category == .audioCaptureStalled)
    #expect(recorder.breadcrumbs.count == 1)
    let crumb = recorder.breadcrumbs[0]
    #expect(crumb.message == "No audio captured (deduped)")
    #expect(crumb.data["deduped_from"] as? String == "audio_capture_stalled")
    #expect(crumb.data["capture_session_id"] as? Int == 9)
  }

  @Test("noAudioCaptured dedup breadcrumb for WhisperKit carries WhisperKit-tagged message")
  func noAudioDedupBreadcrumbWhisperKitTag() {
    let recorder = Recorder()
    let emitter = Self.makeEmitter(backend: .whisperKit, recorder: recorder)

    emitter.xpcReplyFailed(ctx: Self.xpcContext(sessionID: 9))
    emitter.noAudioCaptured(ctx: Self.noAudioContext(sessionID: 9))

    #expect(recorder.breadcrumbs.count == 1)
    #expect(recorder.breadcrumbs[0].message == "No audio captured (WhisperKit, deduped)")
    #expect(recorder.breadcrumbs[0].data["deduped_from"] as? String == "xpc_reply_failed")
  }

  @Test("noAudioCaptured re-arms after session-id change")
  func noAudioReArmsOnSessionChange() {
    let recorder = Recorder()
    let emitter = Self.makeEmitter(backend: .parakeet, recorder: recorder)

    _ = emitter.stallFired(ctx: Self.stallContext(sessionID: 1), isActivelyCapturing: true)
    emitter.noAudioCaptured(ctx: Self.noAudioContext(sessionID: 2))

    // Different session — neither dedup flag applies.
    #expect(recorder.errors.count == 2)  // stall (s=1), noAudio (s=2)
    #expect(recorder.errors[1].category == .audioCaptureFailed)
    #expect(recorder.errors[1].extra["capture.failure_mode"] as? String == "no_audio_captured")
    #expect(recorder.breadcrumbs.isEmpty)
  }

  // MARK: - Zombie zero-peak

  @Test("zombieZeroPeak fires when CaptureTelemetryState allows")
  func zombieZeroPeakFires() {
    let recorder = Recorder()
    let captureTelemetry = CaptureTelemetryState()
    let emitter = Self.makeEmitter(
      backend: .parakeet,
      captureTelemetry: captureTelemetry,
      recorder: recorder
    )

    let fired = emitter.zombieZeroPeak(ctx: Self.zeroPeakContext())

    #expect(fired)
    #expect(recorder.errors.count == 1)
    let captured = recorder.errors[0]
    #expect(captured.category == .audioCaptureFailed)
    #expect(captured.stage == "recording")
    #expect(captured.extra["capture.failure_mode"] as? String == "zombie_engine_zero_peak")
    #expect(captured.extra["capture_session_id"] as? Int == 99)
  }

  @Test("zombieZeroPeak suppresses repeat within the dedup window")
  func zombieZeroPeakDedups() {
    let recorder = Recorder()
    let captureTelemetry = CaptureTelemetryState()
    let emitter = Self.makeEmitter(
      backend: .whisperKit,
      captureTelemetry: captureTelemetry,
      recorder: recorder
    )

    let firstFired = emitter.zombieZeroPeak(ctx: Self.zeroPeakContext())
    let secondFired = emitter.zombieZeroPeak(ctx: Self.zeroPeakContext(sessionID: 100))

    #expect(firstFired)
    #expect(!secondFired)
    #expect(recorder.errors.count == 1)
  }

  // MARK: - Codex code-review additions (2026-04-30)

  /// Time-based probe that distinguishes "old mark still active" from
  /// "suppressed call refreshed the window". `CaptureTelemetryState`
  /// exposes a caller-specified window on `shouldEmitZombie(route:window:)`,
  /// so we can use a SHORT probe window after advancing a fake clock to
  /// test the invariant without widening the production API:
  ///
  ///   1. Emit once — fires (returns true), marks at T₀.
  ///   2. Advance fake clock past the probe window.
  ///   3. Call `zombieZeroPeak` again — suppressed by the emitter's 30s
  ///      dedup window (still well within 30s of T₀).
  ///   4. Probe `shouldEmitZombie(route:, window: 1s)`.
  ///
  /// If the suppressed path correctly called `markZombieEmitted`: the
  /// mark is fresh on the fake clock and `shouldEmitZombie` returns FALSE.
  ///
  /// If the suppressed path skipped `markZombieEmitted` (the regression
  /// we are guarding against): the mark stays at T₀, the fake clock is
  /// past the 1s probe window, and `shouldEmitZombie` returns TRUE —
  /// the assertion fails.
  ///
  /// Migrated from a 1.1s real-time `Task.sleep` to a fake clock in
  /// PR for issue #784 (2026-05-18). Same diagnostic power, ~0ms cost.
  @Test("zombieZeroPeak refreshes the dedup window on every observation, not just emits")
  func zombieZeroPeakSuppressedRefreshesWindow() {
    let clock = ManualInstantClock()
    let recorder = Recorder()
    let captureTelemetry = CaptureTelemetryState(currentInstant: { clock.now })
    let emitter = Self.makeEmitter(
      backend: .parakeet, captureTelemetry: captureTelemetry, recorder: recorder)

    // T₀: first emit — fires, marks at T₀.
    let firstFired = emitter.zombieZeroPeak(ctx: Self.zeroPeakContext())
    #expect(firstFired)

    // Advance past the 1s probe window (still well inside the emitter's 30s dedup).
    clock.advance(by: .milliseconds(1_100))

    // Second emit on same route — suppressed by emitter's 30s dedup.
    let secondFired = emitter.zombieZeroPeak(ctx: Self.zeroPeakContext(sessionID: 100))
    #expect(!secondFired)

    // Probe with a 1s window. If the suppressed call advanced the mark
    // (correct behavior), mark is at T₀+1.1s, clock is at T₀+1.1s,
    // elapsed = 0 < 1s → shouldEmit returns false.
    // If it didn't advance (regression), mark stays at T₀, elapsed = 1.1s
    // ≥ 1s window → shouldEmit returns true and the assertion fails.
    let shouldEmitNow = captureTelemetry.shouldEmitZombie(
      route: "bt_headset", window: .seconds(1))
    #expect(
      !shouldEmitNow,
      "suppressed zombieZeroPeak failed to refresh dedup window — `markZombieEmitted` may have been gated by `shouldEmit`"
    )
  }

  /// Codex code-review gap #2: assert the actual `HeartPathError` case
  /// emitted for each event so a regression that picks the wrong case
  /// trips the suite. Recorder discards-the-error pattern was the gap.
  @Test("each event emits the matching HeartPathError case")
  func eachEventEmitsExpectedHeartPathErrorCase() {
    let recorder = Recorder()
    let emitter = Self.makeEmitter(backend: .whisperKit, recorder: recorder)

    _ = emitter.stallFired(ctx: Self.stallContext(sessionID: 1), isActivelyCapturing: true)
    emitter.xpcReplyFailed(ctx: Self.xpcContext(sessionID: 2))
    emitter.captureSessionInterrupted(ctx: Self.interruptionContext(sessionID: 3))
    emitter.noAudioCaptured(ctx: Self.noAudioContext(sessionID: 4))
    _ = emitter.zombieZeroPeak(ctx: Self.zeroPeakContext(sessionID: 5))

    #expect(recorder.errors.count == 5)

    guard let stallErr = recorder.errors[0].error as? HeartPathError,
      case .audioCaptureStalled(let stallSession, _) = stallErr
    else {
      Issue.record("expected .audioCaptureStalled, got \(recorder.errors[0].error)")
      return
    }
    #expect(stallSession == 1)

    guard let xpcErr = recorder.errors[1].error as? HeartPathError,
      case .xpcReplyFailed(let xpcCtx) = xpcErr
    else {
      Issue.record("expected .xpcReplyFailed, got \(recorder.errors[1].error)")
      return
    }
    #expect(xpcCtx.sessionID == 2)

    guard let interruptionErr = recorder.errors[2].error as? HeartPathError,
      case .captureSessionInterrupted(let intCtx) = interruptionErr
    else {
      Issue.record("expected .captureSessionInterrupted, got \(recorder.errors[2].error)")
      return
    }
    #expect(intCtx.sessionID == 3)

    guard let noAudioErr = recorder.errors[3].error as? HeartPathError,
      case .noAudioCaptured(let naSession, let durationMs, let wasStreaming, let route) = noAudioErr
    else {
      Issue.record("expected .noAudioCaptured, got \(recorder.errors[3].error)")
      return
    }
    #expect(naSession == 4)
    #expect(durationMs == 1234)
    #expect(!wasStreaming)
    #expect(route == "built_in_mic")

    guard let zombieErr = recorder.errors[4].error as? HeartPathError,
      case .zombieEngineZeroPeak(let zSession, _, let zRoute, let sampleCount) = zombieErr
    else {
      Issue.record("expected .zombieEngineZeroPeak, got \(recorder.errors[4].error)")
      return
    }
    #expect(zSession == 5)
    #expect(zRoute == "bt_headset")
    #expect(sampleCount == 32_000)
  }

  /// Codex code-review gap #1 (stall): assert the COMPLETE extras key-set
  /// for the stall event, not just selected keys. A forgotten or added key
  /// trips the suite.
  @Test("stallFired extras key-set matches the stall payload contract exactly")
  func stallFiredExtrasKeySetExact() {
    let recorder = Recorder()
    let emitter = Self.makeEmitter(backend: .parakeet, recorder: recorder)

    _ = emitter.stallFired(ctx: Self.stallContext(sessionID: 7), isActivelyCapturing: true)

    #expect(recorder.errors.count == 1)
    let actualKeys = Set(recorder.errors[0].extra.keys)
    #expect(
      actualKeys == Self.stallExtraKeys,
      "stall extras key-set drift: \(actualKeys.symmetricDifference(Self.stallExtraKeys))")
  }

  /// Codex code-review gap #1 (xpc): exact key-set for the XPC event.
  @Test("xpcReplyFailed extras key-set matches the xpc payload contract exactly")
  func xpcReplyFailedExtrasKeySetExact() {
    let recorder = Recorder()
    let emitter = Self.makeEmitter(backend: .parakeet, recorder: recorder)

    emitter.xpcReplyFailed(ctx: Self.xpcContext(sessionID: 12))

    #expect(recorder.errors.count == 1)
    let actualKeys = Set(recorder.errors[0].extra.keys)
    #expect(
      actualKeys == Self.xpcExtraKeys,
      "xpc extras key-set drift: \(actualKeys.symmetricDifference(Self.xpcExtraKeys))")
  }

  /// Codex code-review gap #1 (interruption + backend asymmetry): exact
  /// key-set for both backends. Parakeet omits `backend`; WhisperKit adds
  /// it. The full set is otherwise identical.
  @Test("captureSessionInterrupted extras key-set is exact per backend")
  func captureSessionInterruptedExtrasKeySetExact() {
    let parakeetRec = Recorder()
    let parakeet = Self.makeEmitter(backend: .parakeet, recorder: parakeetRec)
    parakeet.captureSessionInterrupted(ctx: Self.interruptionContext())
    let parakeetKeys = Set(parakeetRec.errors[0].extra.keys)
    #expect(
      parakeetKeys == Self.interruptionBaseExtraKeys,
      "parakeet interruption key drift: \(parakeetKeys.symmetricDifference(Self.interruptionBaseExtraKeys))"
    )

    let whisperRec = Recorder()
    let whisper = Self.makeEmitter(backend: .whisperKit, recorder: whisperRec)
    whisper.captureSessionInterrupted(ctx: Self.interruptionContext())
    let whisperKeys = Set(whisperRec.errors[0].extra.keys)
    let expectedWhisperKeys = Self.interruptionBaseExtraKeys.union(["backend"])
    #expect(
      whisperKeys == expectedWhisperKeys,
      "whisperKit interruption key drift: \(whisperKeys.symmetricDifference(expectedWhisperKeys))")
  }

  /// Codex code-review gap #1 (noAudio fresh): exact key-set when no prior
  /// dedup hit.
  @Test("noAudioCaptured extras key-set matches the no-audio payload contract exactly")
  func noAudioCapturedExtrasKeySetExact() {
    let recorder = Recorder()
    let emitter = Self.makeEmitter(backend: .parakeet, recorder: recorder)

    emitter.noAudioCaptured(ctx: Self.noAudioContext(sessionID: 5))

    #expect(recorder.errors.count == 1)
    let actualKeys = Set(recorder.errors[0].extra.keys)
    #expect(
      actualKeys == Self.baselineCaptureExtraKeys,
      "noAudio extras key-set drift: \(actualKeys.symmetricDifference(Self.baselineCaptureExtraKeys))"
    )
  }

  /// Codex code-review gap #1 (zombie): exact key-set, including the two
  /// zombie-only enrichment keys.
  @Test("zombieZeroPeak extras key-set matches the zombie payload contract exactly")
  func zombieZeroPeakExtrasKeySetExact() {
    let recorder = Recorder()
    let captureTelemetry = CaptureTelemetryState()
    // Pre-seed a successful recording so the
    // `time_since_last_successful_recording_ms` key is non-nil. In
    // production at least one successful recording will have happened
    // before the zombie code path can fire.
    captureTelemetry.recordSuccessfulRecording()
    let emitter = Self.makeEmitter(
      backend: .parakeet, captureTelemetry: captureTelemetry, recorder: recorder)

    _ = emitter.zombieZeroPeak(ctx: Self.zeroPeakContext())

    #expect(recorder.errors.count == 1)
    let actualKeys = Set(recorder.errors[0].extra.keys)
    #expect(
      actualKeys == Self.zombieExtraKeys,
      "zombie extras key-set drift: \(actualKeys.symmetricDifference(Self.zombieExtraKeys))")
  }
}

/// Fake monotonic instant clock for tests that need deterministic
/// `ContinuousClock.Instant` arithmetic without real wall-clock sleeps.
/// Snapshots `.now` at construction; subsequent `advance(by:)` calls move
/// the snapshot forward via `.advanced(by:)`. Same shape duplicated in
/// `CaptureTelemetryStateTests.swift` per #784 PR1 plan — DRY violation is
/// cheaper than introducing a shared test-utilities target for 5 lines.
@MainActor
private final class ManualInstantClock {
  private(set) var now: ContinuousClock.Instant = .now
  func advance(by duration: Duration) {
    now = now.advanced(by: duration)
  }
}
