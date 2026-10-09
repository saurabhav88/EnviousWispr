import EnviousWisprCore
import Foundation

/// The push-to-talk record gesture: press, release, double-press lock, triple-press cancel, lock
/// cooldown and the lone-tap stop decision (#3544 P1, moved verbatim out of `HotkeyService`).
///
/// A pure value. It reads no clock, starts no task, calls no callback and logs nothing: every
/// input carries the times it needs, and every decision comes back as a value the caller acts on.
/// `RecordGestureEngine` drives this value under its lock from key ingress and its timer queue.
package struct RecordGesture: Sendable {

  // MARK: - Hands-Free (Double-Press Lock) State

  /// The record key is physically held, as far as this gesture has seen. Duplicate presses are
  /// absorbed against it and a release with no press is ignored.
  package private(set) var isHeld = false

  /// True when recording is locked into hands-free mode.
  /// When locked, key releases are suppressed and recording continues
  /// until the next key press or cancel.
  package private(set) var isLocked = false

  /// Timestamp of the key-down that started the current recording session.
  /// Used for the 500ms double-press detection window.
  package private(set) var start: InputTime? = nil

  /// #1631 — identifies one start attempt, incremented only when a fresh press
  /// stamps a new one, so a late result can prove which press it belongs to.
  ///
  /// (#3544: `stateGeneration` below is now `generation`.)
  /// Deliberately NOT `stateGeneration`: that is bumped by every unlocked release
  /// too, so a generation captured at press time is already stale in exactly the
  /// press → release → press sequence this fix exists for.
  package private(set) var attemptID: UInt64 = 0

  /// #3544: the Task cancellation rationale below is historical; token and generation checks
  /// now protect the one-shot timer.
  /// Monotonically increasing counter incremented on every state-changing event
  /// (press, release, cleanup). Debounce callbacks compare their captured
  /// generation to the current value — if they differ, the callback is stale
  /// and must not fire. This is the primary guard against Task.isCancelled
  /// races where cancellation hasn't propagated before the closure executes.
  package private(set) var generation: UInt64 = 0

  /// Timestamp when hands-free lock was activated. Used as a cooldown guard:
  /// presses within 500ms of locking are ignored to prevent accidental
  /// finger-bounce from immediately stopping the locked recording.
  private var lockAt: InputTime? = nil

  // MARK: - #3534 Stop-timer race measurement (diagnostic only)

  /// #3544: the original service invalidation now delegates to `invalidateDiagnostics()` below.
  /// Bumped by `invalidateQuickTapDiagnostics()`, the one owner of the measurement's lifecycle
  /// (plan §3.3). An attempt and a stop marker remember the epoch they were made in; a cleanup,
  /// a mode or binding change, or a monitor teardown in between voids their claim. Nothing here
  /// changes what a press or the timer does.
  private var diagnosticEpoch: UInt64 = 0

  /// What a recording attempt started under, captured with `start`.
  package struct DiagnosticOrigin: Sendable {
    let binding: ShortcutBinding
    let mode: RecordingMode
    let epoch: UInt64
  }
  private var attemptOrigin: DiagnosticOrigin?

  /// The lone-tap timer's stop request, kept so the NEXT press can tell whether it was
  /// physically pressed before that stop was requested: a timer that ran before a queued valid
  /// second press. A stop REQUEST, not a confirmed end of recording.
  private struct QuickTapStop: Sendable {
    let start: InputTime
    let binding: ShortcutBinding
    let mode: RecordingMode
    /// The epoch AFTER the timer's own cleanup, so only a later invalidation voids it.
    let epoch: UInt64
    let stoppedAtUptime: TimeInterval
  }
  private var lastQuickTapStop: QuickTapStop?

  package init() {}

  // MARK: - Input time

  /// One record-key input (#3534): when this service HANDLED it, and when the OS
  /// says it HAPPENED, if that time passed acceptance.
  ///
  /// Why both. NSEvent monitor handlers and the Carbon handler run on the main
  /// thread, and right after a first press starts a recording the main thread is
  /// busy for 100-700 ms (measured on a loaded Mac, #3534). The release or second
  /// press is then HANDLED late, so a window judged by handling time reads a fast
  /// double tap as slow and a fast tap as a hold. Occurrence timestamps
  /// distinguish these captured misses. Their accuracy under heavy load remains
  /// unverified; the microphone check ran only while calm.
  package struct InputTime: Sendable {
    package let handled: TimeInterval
    package let occurred: TimeInterval?

    /// Stamp one record-key input with the caller's clock reading, keeping the OS time
    /// only if it is plausible.
    package static func accepting(stamp: TimeInterval?, handled: TimeInterval) -> InputTime {
      guard let stamp, stamp > 0,
        stamp <= handled + RecordGesture.occurrenceFutureTolerance,
        stamp >= handled - RecordGesture.occurrenceMaxAge
      else { return InputTime(handled: handled, occurred: nil) }
      return InputTime(handled: handled, occurred: stamp)
    }
  }

  /// The double-press window, the lone-tap wait and the lock cooldown.
  package static var window: TimeInterval {
    Double(TimingConstants.handsFreeDebounceDelayMs) / 1000.0
  }

  /// Acceptance bounds for an OS timestamp, relative to its handling time.
  /// 50 ms of future tolerates clock-read jitter (undelayed events agree within
  /// about 1 ms). 2 s of age is 2.9x the largest lag measured (695 ms); an older
  /// or zero stamp (synthetic events, sleep) is treated as unknown.
  static let occurrenceFutureTolerance: TimeInterval = 0.05
  static let occurrenceMaxAge: TimeInterval = 2.0

  /// The single owner of which clock compares two inputs (#3534): OS occurrence
  /// times when both inputs have one and they are in order, otherwise both
  /// handling times. Never one of each, so a rejected stamp is never subtracted
  /// from an accepted one. `elapsed` and the lone-tap deadline both call this.
  package static func clockPair(from a: InputTime, to b: InputTime)
    -> (start: TimeInterval, end: TimeInterval, usesOccurrence: Bool)
  {
    if let ao = a.occurred, let bo = b.occurred, bo >= ao { return (ao, bo, true) }
    return (a.handled, b.handled, false)
  }

  /// Seconds from one record-key input to a later one.
  package static func elapsed(from a: InputTime, to b: InputTime) -> TimeInterval {
    let pair = clockPair(from: a, to: b)
    return pair.end - pair.start
  }

  /// `window_timing` for a lock intent (#3534): `rescued` when the occurrence
  /// clock put the second press inside the window but the handling clock would
  /// not have, `on_time` otherwise.
  static func lockWindowTiming(from start: InputTime, to input: InputTime) -> String {
    let pair = clockPair(from: start, to: input)
    let handledGap = input.handled - start.handled
    return pair.usesOccurrence && handledGap > Self.window ? "rescued" : "on_time"
  }

  // MARK: - Lifecycle

  /// The gesture half of `HotkeyService.performCleanup()`: reset all hands-free state.
  /// Deliberately leaves `isHeld` alone, exactly as before: cleanup ends an attempt, not a hold.
  package mutating func cleanup() {
    generation &+= 1
    isLocked = false
    start = nil
    lockAt = nil
    attemptOrigin = nil
    invalidateDiagnostics()
  }

  /// #3544: `HotkeyService.invalidateQuickTapDiagnostics()` and `cleanup()` delegate here.
  /// #3534 §3.3: the one place the stop-timer measurement is voided. Called from
  /// `performCleanup`, actual mode and binding changes, and `removeModifierMonitors` (which
  /// every monitor install, cancel rebind, app-shortcut rebind and `suspend()` pass through).
  package mutating func invalidateDiagnostics() {
    diagnosticEpoch &+= 1
    lastQuickTapStop = nil
  }

  /// Forget the held key without a release: `stop()` and `resume()`.
  package mutating func forgetHeld() {
    isHeld = false
  }

  /// Whether this identity names the gesture's live attempt; used by attempt-scoped reset.
  package func isLiveAttempt(_ id: UInt64) -> Bool {
    id == attemptID && start != nil
  }

  // MARK: - Press

  /// The first half of a press: the duplicate guard, then the one offer of the stop marker.
  package enum PressAdmission: Sendable {
    /// Already held: a duplicate press event, ignored.
    case duplicate
    /// Admitted. `afterStopTimer` is non-nil when this press was physically pressed before the
    /// lone-tap timer requested its stop (milliseconds after the saved first press).
    case admitted(afterStopTimerMs: Int?)
  }

  /// Guard against a duplicate press, then offer the stop marker once (#3534 §3.3), BEFORE the
  /// caller's processing guard, so a refused press can carry it.
  package mutating func admitPress(
    _ input: InputTime, binding: ShortcutBinding, mode: RecordingMode
  ) -> PressAdmission {
    // Guard: if already held (duplicate press event), ignore
    guard !isHeld else { return .duplicate }
    isHeld = true
    return .admitted(afterStopTimerMs: consumeQuickTapStop(input, binding: binding, mode: mode))
  }

  /// What an admitted, unrefused press means.
  package enum PressDecision: Sendable {
    /// Not recording → start fresh. The caller starts the attempt with this identity.
    case start(attemptID: UInt64)
    /// Within the window while locked: triple press → cancel. The caller cleans up and cancels.
    case tripleCancel
    /// Within the window, unlocked: double press → lock into hands-free. State is already set;
    /// the caller publishes. `windowTiming` is computed BEFORE publication (#3534), whose
    /// rejection cleanup clears `start`.
    case lockIntent(windowTiming: String, elapsedMs: Int, usesOccurrence: Bool)
    /// Locked, inside the lock cooldown: ignored. The caller emits telemetry while the key still
    /// reads as held, then calls `forgetHeld()`, the base order.
    case ignoredCooldown(sinceLockMs: Int)
    /// Single press while locked (after cooldown) → stop. The caller cleans up and stops.
    case stopLocked
    /// #3534: unlocked, a lone-tap stop pending, and this press came after the window.
    case lateAfterWindow(afterFirstMs: Int)
  }

  package mutating func classifyPress(
    _ input: InputTime, binding: ShortcutBinding, mode: RecordingMode
  ) -> PressDecision {
    guard let start else {
      // Not recording → start fresh
      generation &+= 1
      isLocked = false
      start = input
      attemptOrigin = DiagnosticOrigin(binding: binding, mode: mode, epoch: diagnosticEpoch)
      // #1631: a fresh attempt owns a fresh identity, and inherits no acceptance.
      attemptID &+= 1
      return .start(attemptID: attemptID)
    }
    if Self.elapsed(from: start, to: input) <= Self.window {
      // Within 500ms window
      if isLocked {
        // Triple press → cancel
        isHeld = false
        return .tripleCancel
      } else {
        // Double press → lock into hands-free
        // #3534: computed BEFORE publication, whose rejection cleanup clears `recordingStart`
        // (#3544: now `start`).
        let windowTiming = Self.lockWindowTiming(from: start, to: input)
        let pair = Self.clockPair(from: start, to: input)
        isLocked = true
        lockAt = input
        return .lockIntent(
          windowTiming: windowTiming, elapsedMs: Int((pair.end - pair.start) * 1000),
          usesOccurrence: pair.usesOccurrence)
      }
    } else if isLocked {
      // Lock cooldown: ignore presses within 500ms of locking.
      // Prevents accidental finger-bounce on modifier keys from
      // immediately stopping a just-locked recording.
      if let lt = lockAt, Self.elapsed(from: lt, to: input) <= Self.window {
        return .ignoredCooldown(sinceLockMs: Int(Self.elapsed(from: lt, to: input) * 1000))
      }
      // Single press while locked (after cooldown) → stop
      isHeld = false
      return .stopLocked
    } else {
      // #3534: unlocked, a lone-tap stop pending, and this press came after the
      // window. No state change, exactly as before: the pending stop and its
      // generation stay, and this press's release takes the stop path. Before
      // this branch the press left no log line and no row.
      return .lateAfterWindow(afterFirstMs: Int(Self.elapsed(from: start, to: input) * 1000))
    }
  }

  // MARK: - Release

  /// What a release means.
  package enum ReleaseDecision: Sendable {
    /// Not held, or not recording → ignore.
    case ignored
    /// Locked → suppress release entirely.
    case suppressedLocked
    /// Quick release (within 500ms) → debounce, wait for double-press. The caller waits until
    /// `deadline` and then asks `checkLoneTap(capturedGeneration:...)`.
    case quick(QuickRelease)
    /// Normal PTT release (held > 500ms) → stop immediately. The caller cleans up and stops.
    case hold
  }

  package struct QuickRelease: Sendable {
    package let capturedGeneration: UInt64
    package let deadline: TimeInterval
    package let usesOccurrence: Bool
    /// `pair.end + window`: the occurrence-only deadline the handling floor replaced (trace).
    package let eventDeadline: TimeInterval
  }

  package mutating func release(_ input: InputTime) -> ReleaseDecision {
    guard isHeld else { return .ignored }
    isHeld = false

    let isRecording = start != nil

    // Not recording → ignore
    guard isRecording else { return .ignored }

    // Locked → suppress release entirely
    if isLocked { return .suppressedLocked }

    // Quick release (within 500ms) → debounce, wait for double-press
    if let start, Self.elapsed(from: start, to: input) <= Self.window {
      generation &+= 1
      // #3534: retain at least 500 ms from release handling. An occurrence-only
      // deadline could expire before a second press that the old classification
      // would accept. This floor preserves that handling-time grace period;
      // classification still uses `clockPair`. It does not reproduce extra delay
      // from the legacy task starting late. Compute the remaining wait when this
      // task runs; request no further wait if the deadline has passed.
      let pair = Self.clockPair(from: start, to: input)
      return .quick(
        QuickRelease(
          capturedGeneration: generation, deadline: max(pair.end, input.handled) + Self.window,
          usesOccurrence: pair.usesOccurrence, eventDeadline: pair.end + Self.window))
    }
    // Normal PTT release (held > 500ms) → stop immediately
    return .hold
  }

  // MARK: - Lone-tap timer

  /// What the lone-tap timer finds when its wait ends.
  package enum LoneTapCheck: Sendable {
    /// Stale or no longer applicable: do nothing.
    case stale
    /// Timer fired: the engine cleans up and records the stop marker before queuing delivery.
    /// Main logs the request and queues the recording stop.
    case stop(LoneTapStop)
  }

  /// The #3534 §3.3 step (1) snapshot, taken before cleanup.
  package struct LoneTapStop: Sendable {
    fileprivate let attempt: InputTime?
    fileprivate let origin: DiagnosticOrigin?
    package let attributable: Bool
  }

  package func checkLoneTap(
    capturedGeneration: UInt64, binding: ShortcutBinding, mode: RecordingMode
  ) -> LoneTapCheck {
    // Stale check: if any state-changing event occurred during sleep,
    // this callback is outdated and must not fire.
    guard generation == capturedGeneration else { return .stale }
    // Timer fired — user didn't double-press. Stop as normal PTT.
    guard start != nil, !isLocked else { return .stale }
    // #3534 §3.3, in this order. (1) Snapshot, and decide whether this stop may be
    // attributed: nothing has voided the attempt since its first press.
    let attributable =
      attemptOrigin.map {
        $0.epoch == diagnosticEpoch && $0.binding == binding && $0.mode == mode
      } ?? false
    return .stop(LoneTapStop(attempt: start, origin: attemptOrigin, attributable: attributable))
  }

  /// (3) Only an attributable stop leaves a marker, stamped with the post-cleanup epoch.
  /// Called AFTER the caller's cleanup, with the time read after it.
  package mutating func recordQuickTapStop(_ stop: LoneTapStop, stoppedAt: TimeInterval) {
    if stop.attributable, let attempt = stop.attempt, let origin = stop.origin {
      lastQuickTapStop = QuickTapStop(
        start: attempt, binding: origin.binding, mode: origin.mode,
        epoch: diagnosticEpoch, stoppedAtUptime: stoppedAt)
    }
  }

  /// #3534 §3.3: offer the stop marker to this press, once. Returns how long after the saved first
  /// press this press HAPPENED when it was physically pressed before the lone-tap timer requested
  /// its stop, inside the window, and nothing has voided the measurement; nil otherwise. Missing
  /// or rejected OS times mean unknown, never a claim.
  private mutating func consumeQuickTapStop(
    _ input: InputTime, binding: ShortcutBinding, mode: RecordingMode
  ) -> Int? {
    guard let stop = lastQuickTapStop else { return nil }
    lastQuickTapStop = nil
    guard stop.epoch == diagnosticEpoch, stop.binding == binding, stop.mode == mode
    else { return nil }
    let pair = Self.clockPair(from: stop.start, to: input)
    guard pair.usesOccurrence, pair.end - pair.start <= Self.window,
      pair.end <= stop.stoppedAtUptime, stop.stoppedAtUptime <= input.handled
    else { return nil }
    return Int((pair.end - pair.start) * 1000)
  }
}
