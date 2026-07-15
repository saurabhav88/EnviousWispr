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
  /// adds the `time_since_last_successful_recording_ms` key.
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
      "capture.time_since_last_successful_recording_ms"
    ])

  private static func stallContext(sessionID: UInt64 = 42) -> CaptureStallContext {
    CaptureStallContext(
      sessionID: sessionID,
      armedAtUptimeNs: 1_000,
      firedAtUptimeNs: 2_000,
      route: "built_in_mic",
      sourceType: "hal_device_input",
      engineStartedSuccessfully: true,
      tapInstalled: true,
      formatMismatchObserved: false,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: "BuiltInMicrophoneDevice",
      failureMode: .noBuffers
    )
  }

  private static func noAudioContext(sessionID: UInt64 = 42) -> NoAudioContext {
    NoAudioContext(
      sessionID: sessionID,
      durationMs: 1234,
      wasStreaming: false,
      route: "built_in_mic",
      isActivelyCapturing: false,
      captureSourceType: "hal_device_input",
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
      captureSourceType: "hal_device_input",
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

  // #1543: the `xpcReplyFailed` emit + its dedup path are gone with the audio
  // boundary — the emitter no longer has that method.

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
    // #1523: an unstamped no-audio terminal omits the channel-count key.
    #expect(captured.extra["capture.native_channel_count"] == nil)
  }

  @Test("#1523: a stamped channel count rides the no-audio captureError extras")
  func noAudioCarriesChannelCount() {
    let recorder = Recorder()
    let emitter = Self.makeEmitter(backend: .parakeet, recorder: recorder)

    var ctx = Self.noAudioContext(sessionID: 5)
    ctx.captureNativeChannelCount = 8
    emitter.noAudioCaptured(ctx: ctx)

    #expect(recorder.errors.count == 1)
    #expect(recorder.errors[0].extra["capture.native_channel_count"] as? Int == 8)
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

    _ = emitter.stallFired(ctx: Self.stallContext(sessionID: 9), isActivelyCapturing: true)
    emitter.noAudioCaptured(ctx: Self.noAudioContext(sessionID: 9))

    #expect(recorder.breadcrumbs.count == 1)
    #expect(recorder.breadcrumbs[0].message == "No audio captured (WhisperKit, deduped)")
    #expect(recorder.breadcrumbs[0].data["deduped_from"] as? String == "audio_capture_stalled")
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
    emitter.noAudioCaptured(ctx: Self.noAudioContext(sessionID: 4))
    _ = emitter.zombieZeroPeak(ctx: Self.zeroPeakContext(sessionID: 5))

    #expect(recorder.errors.count == 3)

    guard let stallErr = recorder.errors[0].error as? HeartPathError,
      case .audioCaptureStalled(let stallSession, _) = stallErr
    else {
      Issue.record("expected .audioCaptureStalled, got \(recorder.errors[0].error)")
      return
    }
    #expect(stallSession == 1)

    guard let noAudioErr = recorder.errors[1].error as? HeartPathError,
      case .noAudioCaptured(let naSession, let durationMs, let wasStreaming, let route) = noAudioErr
    else {
      Issue.record("expected .noAudioCaptured, got \(recorder.errors[1].error)")
      return
    }
    #expect(naSession == 4)
    #expect(durationMs == 1234)
    #expect(!wasStreaming)
    #expect(route == "built_in_mic")

    guard let zombieErr = recorder.errors[2].error as? HeartPathError,
      case .zombieEngineZeroPeak(let zSession, _, let zRoute, let sampleCount) = zombieErr
    else {
      Issue.record("expected .zombieEngineZeroPeak, got \(recorder.errors[2].error)")
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
    captureTelemetry.recordSuccessfulRecording(recoveryTransport: "builtin", sessionID: 1)
    let emitter = Self.makeEmitter(
      backend: .parakeet, captureTelemetry: captureTelemetry, recorder: recorder)

    _ = emitter.zombieZeroPeak(ctx: Self.zeroPeakContext())

    #expect(recorder.errors.count == 1)
    let actualKeys = Set(recorder.errors[0].extra.keys)
    #expect(
      actualKeys == Self.zombieExtraKeys,
      "zombie extras key-set drift: \(actualKeys.symmetricDifference(Self.zombieExtraKeys))")
  }

  // MARK: - Dead-mic telemetry (#1520 heartpath 5b)
  //
  // Assert the FEATURE, not the absence of a crash (verify-the-feature-not-the-crash):
  // each method must add exactly one content-free Sentry breadcrumb (NOT a
  // standalone captureError — no new issue/alert) AND emit one PostHog event
  // with the full prop set. The PostHog side is observed via the DEBUG
  // `testEventHook`, so these two tests are `#if DEBUG`-gated
  // (swift-testing-debug-seam-needs-if-debug — the Release test lane must not
  // reference the DEBUG-only hook).
  #if DEBUG
    @Test("deadMicRetireAttempted adds one breadcrumb AND one PostHog event with full props")
    func deadMicRetireAttemptedFansOut() {
      let recorder = Recorder()
      let emitter = Self.makeEmitter(backend: .parakeet, recorder: recorder)

      let box = CapturedEventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { box.event = event }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      emitter.deadMicRetireAttempted(
        ctx: DeadMicRetireAttemptContext(
          transport: "bluetooth",
          selectedTransport: "bluetooth",
          failureShape: "all_zero_from_start",
          healthGuessRefused: true,
          warmPolicy: "seconds30",
          retireAction: "retired",
          routeFallbackReason: nil))

      #expect(recorder.breadcrumbs.count == 1)
      #expect(recorder.breadcrumbs.first?.message == "Dead mic retire attempted")
      #expect(recorder.breadcrumbs.first?.data["transport"] as? String == "bluetooth")
      #expect(recorder.breadcrumbs.first?.data["retire_action"] as? String == "retired")
      // The breadcrumb carries the full diagnostic payload (parity with PostHog).
      #expect(recorder.breadcrumbs.first?.data["selected_transport"] as? String == "bluetooth")
      #expect(recorder.breadcrumbs.first?.data["health_guess_refused"] as? Bool == true)
      #expect(recorder.errors.isEmpty)  // breadcrumb only, no standalone Sentry event

      let captured = box.event
      #expect(captured?.name == "audio.dead_mic_retire_attempted")
      #expect(captured?.stringProps["transport"] == "bluetooth")
      #expect(captured?.stringProps["failure_shape"] == "all_zero_from_start")
      #expect(captured?.stringProps["warm_policy"] == "seconds30")
      #expect(captured?.stringProps["retire_action"] == "retired")
      #expect(captured?.boolProps["health_guess_refused"] == true)
    }

    @Test("deadMicRecovered adds one breadcrumb AND one PostHog event with full props")
    func deadMicRecoveredFansOut() {
      let recorder = Recorder()
      let emitter = Self.makeEmitter(backend: .parakeet, recorder: recorder)

      let box = CapturedEventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { box.event = event }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      emitter.deadMicRecovered(
        outcome: DeadMicRecoveryOutcome(
          retireShape: "all_zero_from_start",
          retireTransport: "bluetooth",
          recovered: true,
          resolution: "later_success",
          recoveryTransport: "bluetooth",
          transportChanged: false,
          gapMs: 1_200))

      #expect(recorder.breadcrumbs.count == 1)
      #expect(recorder.breadcrumbs.first?.message == "Dead mic recovery observed")
      #expect(recorder.breadcrumbs.first?.data["recovered"] as? Bool == true)
      // The breadcrumb carries retire_shape + gap_ms (parity with PostHog).
      #expect(recorder.breadcrumbs.first?.data["retire_shape"] as? String == "all_zero_from_start")
      #expect(recorder.breadcrumbs.first?.data["gap_ms"] as? Int == 1_200)
      #expect(recorder.errors.isEmpty)

      let captured = box.event
      #expect(captured?.name == "audio.dead_mic_recovery")
      #expect(captured?.boolProps["recovered"] == true)
      #expect(captured?.stringProps["resolution"] == "later_success")
      #expect(captured?.intProps["gap_ms"] == 1_200)
    }

    /// Sendable-safe capture box for the DEBUG `testEventHook` (a `@Sendable`
    /// closure): a `@MainActor` class is implicitly Sendable, mutated via
    /// `MainActor.assumeIsolated` since the emit is synchronous on the main actor.
    @MainActor
    private final class CapturedEventBox {
      var event: CapturedTelemetryEvent?
    }
  #endif
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
