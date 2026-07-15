import Foundation

/// A caller-supplied descriptor of a zero-signal take whose source was actually
/// retired (`ZeroSignalRetireResult.retired`). The state stamps the arm time
/// itself, so the kernel supplies only the classification. Heartpath 5b (#1520).
public struct DeadMicRetireWatch: Sendable, Equatable {
  /// `all_zero_from_start` / `became_zero_mid_capture`.
  public let shape: String
  /// Effective transport at retire time (`bluetooth` / `builtin` / …).
  public let transport: String

  public init(shape: String, transport: String) {
    self.shape = shape
    self.transport = transport
  }
}

/// The resolved outcome of a pending `DeadMicRetireWatch`: whether a LATER take
/// recovered (audio flowed again) or retired again. Emitted as the
/// `audio.dead_mic_recovery` event. Heartpath 5b (#1520).
public struct DeadMicRecoveryOutcome: Sendable, Equatable {
  public let retireShape: String
  public let retireTransport: String
  public let recovered: Bool
  /// `later_success` / `later_retire` — an intervening take can leave the watch
  /// unresolved, so this is a LATER resolution, not strictly the next take.
  public let resolution: String
  public let recoveryTransport: String
  /// Transport CLASS change only (two Bluetooth devices both read `bluetooth`).
  public let transportChanged: Bool
  public let gapMs: Int

  public init(
    retireShape: String, retireTransport: String, recovered: Bool, resolution: String,
    recoveryTransport: String, transportChanged: Bool, gapMs: Int
  ) {
    self.retireShape = retireShape
    self.retireTransport = retireTransport
    self.recovered = recovered
    self.resolution = resolution
    self.recoveryTransport = recoveryTransport
    self.transportChanged = transportChanged
    self.gapMs = gapMs
  }
}

/// App-wide telemetry state for audio capture diagnostics. Owns dedupe state
/// for zombie-engine zero-peak events (#302) and the cross-take dead-mic
/// recovery watch (#1520 heartpath 5b).
///
/// Shared across both pipelines so a Parakeet-to-WhisperKit switch does not
/// reset dedupe, and so `timeSinceLastSuccessfulRecordingMs` is an app-level
/// baseline rather than pipeline-local. The SAME instance must be handed to the
/// recording kernel (arm-on-retire) and the lifecycle sink (resolve-on-success)
/// or the watch cannot correlate across takes.
@MainActor
public final class CaptureTelemetryState {
  private var lastZombieEmittedAt: ContinuousClock.Instant?
  private var lastZombieRoute: String?
  private var lastSuccessfulRecordingAt: ContinuousClock.Instant?

  /// The single in-flight dead-mic recovery watch (#1520). In-memory only: a
  /// relaunch drops it, lowering recovery-observation coverage but never
  /// manufacturing an outcome. `armedSessionID` is the capture session that
  /// retired — only a DIFFERENT (later) session may resolve the watch, so a
  /// take that both arms and self-completes cannot fake its own recovery.
  private var pendingDeadMicWatch:
    (watch: DeadMicRetireWatch, armedAt: ContinuousClock.Instant, armedSessionID: UInt64)?

  private let currentInstant: @MainActor () -> ContinuousClock.Instant

  public init(
    currentInstant: @escaping @MainActor () -> ContinuousClock.Instant = { .now }
  ) {
    self.currentInstant = currentInstant
  }

  /// Called at transcript save (not paste end) so clipboard-only users are
  /// covered. Resets zombie dedupe so a successful recording sandwiched
  /// between two zombie events still surfaces the second event. Also resolves a
  /// pending dead-mic watch as `recovered=true` (audio flowed again on a later
  /// take); returns that outcome for the caller to emit, or nil if none pending.
  @discardableResult
  public func recordSuccessfulRecording(recoveryTransport: String, sessionID: UInt64)
    -> DeadMicRecoveryOutcome?
  {
    let now = currentInstant()
    lastSuccessfulRecordingAt = now
    lastZombieEmittedAt = nil
    lastZombieRoute = nil
    // Only a LATER take proves recovery. A `becameZeroMidCapture` take arms the
    // watch at stop AND then completes successfully by salvaging its non-zero
    // prefix — that same session must NOT resolve its own watch (a false
    // `recovered=true` that would inflate the metric). Resolve only from a
    // different session; a same-session completion leaves the watch pending.
    guard let pending = pendingDeadMicWatch, pending.armedSessionID != sessionID else {
      return nil
    }
    pendingDeadMicWatch = nil
    return resolve(
      pending, recovered: true, resolution: "later_success",
      recoveryTransport: recoveryTransport, now: now)
  }

  /// Arm a dead-mic recovery watch for a take (identified by `sessionID`) whose
  /// source was actually retired. If a watch is already pending from a DIFFERENT
  /// earlier session, the previous retire's later take has itself retired:
  /// resolve the prior watch as `recovered=false` (`later_retire`) and return
  /// that outcome for the caller to emit, then store the new watch.
  @discardableResult
  public func armDeadMicWatch(_ watch: DeadMicRetireWatch, sessionID: UInt64)
    -> DeadMicRecoveryOutcome?
  {
    let now = currentInstant()
    var priorOutcome: DeadMicRecoveryOutcome?
    if let pending = pendingDeadMicWatch, pending.armedSessionID != sessionID {
      priorOutcome = resolve(
        pending, recovered: false, resolution: "later_retire",
        recoveryTransport: watch.transport, now: now)
    }
    pendingDeadMicWatch = (watch, now, sessionID)
    return priorOutcome
  }

  private func resolve(
    _ pending: (
      watch: DeadMicRetireWatch, armedAt: ContinuousClock.Instant, armedSessionID: UInt64
    ),
    recovered: Bool, resolution: String, recoveryTransport: String,
    now: ContinuousClock.Instant
  ) -> DeadMicRecoveryOutcome {
    DeadMicRecoveryOutcome(
      retireShape: pending.watch.shape,
      retireTransport: pending.watch.transport,
      recovered: recovered,
      resolution: resolution,
      recoveryTransport: recoveryTransport,
      transportChanged: pending.watch.transport != recoveryTransport,
      gapMs: millisecondsBetween(pending.armedAt, and: now))
  }

  /// Returns true if a zombie event on `route` should emit to Sentry now.
  /// False when a prior event fired less than `window` ago on the same route
  /// with no intervening successful recording.
  public func shouldEmitZombie(route: String, window: Duration) -> Bool {
    guard let last = lastZombieEmittedAt, lastZombieRoute == route else {
      return true
    }
    return currentInstant() - last >= window
  }

  /// Marks that a zombie event was observed (regardless of whether it emitted
  /// to Sentry). The 30s window is relative to the most recent observation,
  /// not the most recent emission, so rapid retries stay suppressed.
  public func markZombieEmitted(route: String) {
    lastZombieEmittedAt = currentInstant()
    lastZombieRoute = route
  }

  /// Milliseconds since the last successful recording. Nil if the app session
  /// has never produced a successful recording yet.
  public func timeSinceLastSuccessfulRecordingMs() -> Int? {
    guard let last = lastSuccessfulRecordingAt else { return nil }
    return millisecondsBetween(last, and: currentInstant())
  }

  private func millisecondsBetween(
    _ start: ContinuousClock.Instant, and end: ContinuousClock.Instant
  ) -> Int {
    let elapsed = end - start
    let (seconds, attoseconds) = elapsed.components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
  }
}
