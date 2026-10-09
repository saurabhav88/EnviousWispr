import CoreGraphics
import EnviousWisprServices
import Foundation
import os

/// The keyboard listener: one active session event tap on its own thread (#3544 P2).
///
/// **Why its own thread.** An active tap holds each event until the callback returns, system-wide.
/// On the main thread a busy app would delay every modifier key on the Mac, and our own key
/// handling would wait behind recording start (#3534). Here the callback runs on a dedicated
/// `userInteractive` thread whose run loop does nothing else.
///
/// **What the callback may do.** Decode primitive fields, call the sink synchronously, return the
/// event. Nothing that can wait: no main hop, no `Task`, no logging, no formatting. In P2 the event
/// is always returned unchanged whatever the sink says (shadow mode, plan §3.4); `.swallow` is
/// honoured from P5. Mask is `flagsChanged` only until P4 (plan §3.1).
///
/// **Recovery.** The OS disables a tap whose callback runs too long, or on some user input. The
/// callback and a 2 s watchdog both notice; the listener re-enables and reports `.tapReenabled`
/// only once the tap is confirmed enabled again. Five disable episodes within 60 s is a storm: the
/// installation stops for good and reports why (`terminalReason`); a replacement and its cooldown
/// belong to the owner (plan §7, cooldown still to be measured). Both numbers are the plan's
/// provisional baselines (§14), to be checked against P2 live measurements.
///
/// **Not produced yet.** `.secureInputChanged` (detection and policy are P3, plan §3.5; a disable
/// is never read as Secure Input, #3544 P0) and `isOurs` (the shared self-event marker is P3).
///
/// **`@unchecked Sendable`, and why that is true.** Everything shared between threads lives in
/// `state`, behind one lock. The tap, run loop source, watchdog timer and callback context are
/// created, used and released only on the worker thread; `start` and `stop` touch them through
/// `state` (the run loop handle, whose stop and wake-up calls are thread-safe) and never directly.
final class LiveKeyboardListener: @unchecked Sendable {

  enum TerminalReason: Equatable {
    case removed
    case startFailed
    case disableStorm
  }

  /// Provisional baselines from the plan (§14): storm = this many disable episodes ...
  static let stormEpisodes = 5
  /// ... within this window.
  static let stormWindow: TimeInterval = 60
  static let watchdogInterval: TimeInterval = 2
  /// Bound on waiting for the worker to acknowledge start or stop. An administrative hang guard,
  /// not a keyboard latency budget; same shape as the bounded waits in `LiveMediaRemoteAdapter`.
  /// Adequacy NOT VERIFIED until P2 live measurement.
  static let lifecycleWait: TimeInterval = 1

  private struct State {
    var stopRequested = false
    /// False once cleanup begins, so no event reaches the sink after removal starts.
    var delivering = false
    var started: Bool?
    var cleanedUp = false
    var terminalReason: TerminalReason?
    var runLoop: CFRunLoop?
    /// Start times of disable episodes inside the storm window, oldest first, at most
    /// `stormEpisodes` long.
    var episodeStarts: [TimeInterval] = []
    var inDisabledEpisode = false
    var disableEpisodes = 0
    var reenables = 0
    #if DEBUG
      var cost = CostHistogram()
    #endif
  }

  private let sink: @Sendable (KeyEventValue) -> ListenerVerdict
  private let state = OSAllocatedUnfairLock(uncheckedState: State())
  private let startedSignal = DispatchSemaphore(value: 0)
  private let finishedSignal = DispatchSemaphore(value: 0)

  // Worker-thread only (see the type comment).
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var watchdog: CFRunLoopTimer?
  private var context: Unmanaged<CallbackContext>?

  init(sink: @escaping @Sendable (KeyEventValue) -> ListenerVerdict) {
    self.sink = sink
  }

  var terminalReason: TerminalReason? { state.withLock { $0.terminalReason } }

  // MARK: - Lifecycle

  /// Start the worker and wait for it to install and enable the tap. False when the tap could not
  /// be created (no Accessibility) or the worker did not answer in time; in the second case the
  /// worker finds the stop latched when it does run, and cleans up instead of activating.
  func start() -> Bool {
    #if DEBUG
      // Calibrate the recording cost now, not lazily during a report.
      _ = Self.recordingNanoseconds
    #endif
    let thread = Thread { [self] in run() }
    thread.name = "EnviousWispr.KeyboardListener"
    thread.qualityOfService = .userInteractive
    thread.start()
    if startedSignal.wait(timeout: .now() + Self.lifecycleWait) == .timedOut {
      state.withLock { s in
        s.stopRequested = true
        s.terminalReason = s.terminalReason ?? .startFailed
      }
      // Wake a worker that published after the wait gave up, so it does not run unowned.
      _ = stop()
      return false
    }
    return state.withLock { $0.started == true }
  }

  /// Stop for good and wait for the worker to finish cleanup. False when cleanup did not finish in
  /// time: the caller keeps its token and may call again; the callback context stays alive until
  /// the worker releases it. Safe to call twice.
  func stop() -> Bool {
    // `withLockUnchecked`: `CFRunLoop` is not `Sendable`, and the only calls made on it off the
    // worker are `CFRunLoopStop` and `CFRunLoopWakeUp`, which are thread-safe.
    let runLoop: CFRunLoop? = state.withLockUnchecked { s in
      if s.terminalReason == nil { s.terminalReason = .removed }
      s.stopRequested = true
      s.delivering = false
      return s.cleanedUp ? nil : s.runLoop
    }
    if state.withLock({ $0.cleanedUp }) { return true }
    if let runLoop {
      // `CFRunLoopStop` only stops a run that is in progress, so a stop sent between the worker's
      // latch check and its next run would be lost. A queued block runs inside the next run and
      // stops that one.
      CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
        CFRunLoopStop(CFRunLoopGetCurrent())
      }
      CFRunLoopWakeUp(runLoop)
    }
    if finishedSignal.wait(timeout: .now() + Self.lifecycleWait) == .timedOut {
      return state.withLock { $0.cleanedUp }
    }
    return true
  }

  // MARK: - Worker

  private func run() {
    let context = Unmanaged.passRetained(CallbackContext(listener: self))
    let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: mask, callback: keyboardTapCallback, userInfo: context.toOpaque())
    else {
      context.release()
      state.withLock { s in
        s.started = false
        s.terminalReason = s.terminalReason ?? .startFailed
        s.cleanedUp = true
      }
      startedSignal.signal()
      finishedSignal.signal()
      return
    }
    self.tap = tap
    self.context = context
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    self.source = source
    let runLoop: CFRunLoop = CFRunLoopGetCurrent()
    CFRunLoopAddSource(runLoop, source, .commonModes)
    let watchdog = CFRunLoopTimerCreateWithHandler(
      kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + Self.watchdogInterval,
      Self.watchdogInterval, 0, 0
    ) { [unowned self] _ in
      if let tap = self.tap, !CGEvent.tapIsEnabled(tap: tap) { self.recoverFromDisable() }
    }
    self.watchdog = watchdog
    CFRunLoopAddTimer(runLoop, watchdog, .commonModes)

    // Every explicit enable happens under the lifecycle lock with the stop latch checked in the
    // same critical section, so a removal or start timeout can never be followed by an enable.
    // `withLockUnchecked`: `CFMachPort` is not `Sendable`; it is used only on this thread.
    let enabled = state.withLockUnchecked { s -> Bool in
      guard !s.stopRequested else { return false }
      CGEvent.tapEnable(tap: tap, enable: true)
      return CGEvent.tapIsEnabled(tap: tap)
    }
    guard enabled else {
      state.withLock { s in
        s.started = false
        s.terminalReason = s.terminalReason ?? .startFailed
      }
      cleanUp(runLoop: runLoop)
      startedSignal.signal()
      return
    }

    // Publish, unless a start that timed out already latched the stop.
    let proceed = state.withLockUnchecked { s -> Bool in
      guard !s.stopRequested else { return false }
      s.runLoop = runLoop
      s.delivering = true
      s.started = true
      return true
    }
    startedSignal.signal()
    if proceed {
      // `stop()` sets the latch, then queues a block that stops the run from inside it, so every
      // exit re-reads the latch and a stop that lands between the check and the run still ends it.
      while !state.withLock({ $0.stopRequested }) {
        CFRunLoopRunInMode(.defaultMode, 3600, false)
      }
    }
    cleanUp(runLoop: runLoop)
  }

  /// Teardown on the worker, in an order where no callback can reach a released context.
  private func cleanUp(runLoop: CFRunLoop) {
    state.withLock { $0.delivering = false }
    if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    if let watchdog { CFRunLoopTimerInvalidate(watchdog) }
    if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
    if let tap { CFMachPortInvalidate(tap) }
    // Callbacks run only on this thread's run loop, which is no longer running and no longer has
    // the source: nothing can read the context after this point.
    context?.release()
    context = nil
    watchdog = nil
    source = nil
    tap = nil
    state.withLock { s in
      s.runLoop = nil
      s.cleanedUp = true
    }
    finishedSignal.signal()
  }

  // MARK: - Callback paths (worker thread)

  fileprivate func deliver(_ event: CGEvent) {
    // Removal closes admission under the lock. An event admitted just before removal may still
    // finish its sink call outside the lock; a successful removal waits for worker cleanup, which
    // runs only after this callback returns.
    guard state.withLock({ $0.delivering && !$0.stopRequested }) else { return }
    let value = KeyEventValue(
      kind: .flagsChanged,
      keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
      rawFlags: event.flags.rawValue,
      timestamp: TimeInterval(event.timestamp) / 1_000_000_000,
      isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
    _ = sink(value)
  }

  #if DEBUG
    /// Record one whole callback's duration (any event type, recovery and reconciliation
    /// included), excluding this increment itself.
    fileprivate func recordCallbackDuration(_ duration: UInt64) {
      state.withLock { $0.cost.record(duration) }
    }
  #endif

  /// Called for a disable notification and by the watchdog. One episode per disable, however many
  /// times it is noticed; a storm stops the installation.
  fileprivate func recoverFromDisable() {
    guard let tap else { return }
    let now = ProcessInfo.processInfo.systemUptime
    let storm = state.withLock { s -> Bool? in
      guard !s.stopRequested else { return nil }
      if !s.inDisabledEpisode {
        s.inDisabledEpisode = true
        s.disableEpisodes += 1
        s.episodeStarts.removeAll { now - $0 > Self.stormWindow }
        s.episodeStarts.append(now)
        if s.episodeStarts.count >= Self.stormEpisodes {
          s.terminalReason = .disableStorm
          s.stopRequested = true
          return true
        }
      }
      return false
    }
    guard let storm else { return }
    if storm {
      CFRunLoopStop(CFRunLoopGetCurrent())
      return
    }
    // Same rule as startup: enable only inside the lock, with the latch checked. A failed
    // re-enable leaves the episode open and the watchdog tries again.
    let report = state.withLockUnchecked { s -> Bool in
      guard !s.stopRequested else { return false }
      CGEvent.tapEnable(tap: tap, enable: true)
      guard CGEvent.tapIsEnabled(tap: tap) else { return false }
      s.inDisabledEpisode = false
      s.reenables += 1
      return s.delivering
    }
    if report {
      _ = sink(
        KeyEventValue(
          kind: .tapReenabled, keyCode: 0, rawFlags: 0,
          timestamp: ProcessInfo.processInfo.systemUptime))
    }
  }

  // MARK: - Health

  /// The listener's content-free state; the cost is DEBUG only.
  func health() -> KeyboardListenerHealth {
    let (terminal, episodes, reenables) = state.withLock {
      ($0.terminalReason, $0.disableEpisodes, $0.reenables)
    }
    let mapped: KeyboardListenerHealth.Terminal? =
      switch terminal {
      case .removed: .removed
      case .startFailed: .startFailed
      case .disableStorm: .disableStorm
      case nil: nil
      }
    #if DEBUG
      let cost = costReport()
    #else
      let cost: KeyboardListenerCost? = nil
    #endif
    return KeyboardListenerHealth(
      terminal: mapped, disableEpisodes: episodes, reenables: reenables, cost: cost)
  }

  // MARK: - Callback cost (DEBUG)

  #if DEBUG
    /// The uncontended mean cost of one histogram increment under the lock, measured once when
    /// the first listener starts, so the report can state what callback durations exclude. A mean
    /// without contention, not a bound on the excluded cost of any one callback.
    private static let recordingNanoseconds: UInt64 = {
      let lock = OSAllocatedUnfairLock(initialState: CostHistogram())
      let rounds: UInt64 = 10_000
      let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
      for i in 0..<rounds { lock.withLock { $0.record(i & 1023) } }
      return (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- start) / rounds
    }()

    /// Every callback's duration so far; the copy is a fixed-size value taken under the lock.
    func costReport() -> KeyboardListenerCost? {
      // An independent copy of the counts: returning the stored value would share its storage,
      // and the next callback's write would then copy it (allocate) inside the callback.
      let histogram = state.withLock { s -> CostHistogram in
        var copy = CostHistogram()
        copy.counts = s.cost.counts.withUnsafeBufferPointer { Array($0) }
        copy.total = s.cost.total
        copy.maximum = s.cost.maximum
        return copy
      }
      guard histogram.total > 0 else { return nil }
      let (lower, upper) = histogram.percentileBounds(0.99)
      return KeyboardListenerCost(
        samples: Int(histogram.total), maxNanoseconds: histogram.maximum,
        p99LowerNanoseconds: lower, p99UpperNanoseconds: upper,
        recordingNanoseconds: Self.recordingNanoseconds)
    }
  #endif
}

#if DEBUG
  /// Callback durations in quarter-octave buckets: bucket `i` holds durations below
  /// 2^((i + 1) / 4) ns, the last bucket everything longer. Recording is one array increment
  /// into fixed storage; nothing is ever dropped.
  struct CostHistogram: Sendable {
    static let buckets = 112  // up to 2^28 ns, about 268 ms, then the overflow bucket
    var counts = [UInt64](repeating: 0, count: buckets)
    var total: UInt64 = 0
    var maximum: UInt64 = 0

    static func bucket(_ nanoseconds: UInt64) -> Int {
      guard nanoseconds > 0 else { return 0 }
      let index = Int((log2(Double(nanoseconds)) * 4).rounded(.down))
      return min(max(index, 0), buckets - 1)
    }

    static func lowerBound(_ bucket: Int) -> UInt64 {
      bucket == 0 ? 0 : UInt64(pow(2, Double(bucket) / 4))
    }

    static func upperBound(_ bucket: Int) -> UInt64 {
      bucket == buckets - 1 ? .max : UInt64(pow(2, Double(bucket + 1) / 4).rounded(.up))
    }

    mutating func record(_ nanoseconds: UInt64) {
      counts[Self.bucket(nanoseconds)] &+= 1
      total &+= 1
      if nanoseconds > maximum { maximum = nanoseconds }
    }

    /// The bucket bounds holding the given percentile of all samples.
    func percentileBounds(_ p: Double) -> (lower: UInt64, upper: UInt64) {
      let target = UInt64((Double(total) * p).rounded(.up))
      var seen: UInt64 = 0
      for (i, count) in counts.enumerated() {
        seen += count
        if seen >= max(target, 1) { return (Self.lowerBound(i), Self.upperBound(i)) }
      }
      return (Self.lowerBound(Self.buckets - 1), .max)
    }
  }
#endif

/// What the C callback's user-data pointer addresses: retained by the worker from tap creation
/// until cleanup, never by the policy object (same contract as `CarbonHandlerBox`).
private final class CallbackContext {
  unowned let listener: LiveKeyboardListener
  init(listener: LiveKeyboardListener) { self.listener = listener }
}

private func keyboardTapCallback(
  proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  #if DEBUG
    let entered = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
  #endif
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  let listener = Unmanaged<CallbackContext>.fromOpaque(userInfo).takeUnretainedValue().listener
  #if DEBUG
    defer { listener.recordCallbackDuration(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- entered) }
  #endif
  switch type {
  case .flagsChanged:
    listener.deliver(event)
  case .tapDisabledByTimeout, .tapDisabledByUserInput:
    listener.recoverFromDisable()
  default:
    break
  }
  // P2: always pass the event through, whatever the sink said (shadow mode).
  return Unmanaged.passUnretained(event)
}
