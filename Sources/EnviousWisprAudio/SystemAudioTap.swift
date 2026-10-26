@preconcurrency import AVFoundation
@preconcurrency import CoreAudio
import EnviousWisprCore
import Foundation
import os

/// Captures what the Mac plays, digitally, through a Core Audio process tap (#3972 §3.2, R2).
///
/// Known recipe (Apple "Capturing system audio with Core Audio taps"; insidegui/AudioCap;
/// Chromium `catap_audio_input_stream.mm`; Codex consult r1): a global stereo tap that
/// EXCLUDES our own process object (so EnviousWispr's start/stop cues are never recorded) →
/// a private aggregate device holding the tap → an IOProc. Because the sound is taken before it
/// reaches any output device, AirPods, wired headphones and speakers all give the same track
/// (founder F2).
///
/// **Ownership.** Every lifecycle step (start, stop, the rebuild after an output-device or
/// format change) runs on this tap's own serial queue, so stop and a queued rebuild can never
/// wait on each other, and nothing restarts after `stop`. Core Audio listeners deliver on a
/// separate queue that only forwards to it. The real-time IOProc only down-mixes into storage
/// reserved at start (`CallSoundPipeline`); a timer on the tap queue drains, resamples and
/// hands samples to the owner.
///
/// **Teardown order** (Codex r1 KNOWN-FIX): stop accepting → `AudioDeviceStop` →
/// `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` →
/// `AudioHardwareDestroyProcessTap`. Synchronous, so the quit path can call `stop()`.
@available(macOS 14.2, *)
public final class SystemAudioTap: @unchecked Sendable {
  public typealias SampleHandler = CallSoundPipeline.SampleHandler

  public enum Event: Sendable {
    /// The output device, the aggregate's rate or the buffer layout changed and capture was
    /// rebuilt. A completed rebuild, not yet a verified recovery.
    case rebuilt
    /// A rebuild failed; capture has stopped. Carries the failure's description.
    case rebuildFailed(String)
  }

  /// #4117: what a fresh reading found different from the capture's commitment.
  public enum RebuildReason: String, Sendable, CaseIterable {
    case outputDevice
    case nominalRate
    case layout
    /// The reading itself failed. Never taken as "unchanged": the rebuild reads again and
    /// reports a failure if it still cannot.
    case unreadable
    /// A required watch could not follow a new stream (or the stream list could not be read):
    /// the rebuild installs every watch again, or fails.
    case watchFailed
    /// The buffers' own timing disagreed with the configured rate for three qualified windows.
    case rateMismatch
  }

  public enum TapError: Error, Equatable {
    case status(operation: String, value: OSStatus)
    case unusableFormat
    case alreadyStarted
    case stopped
  }

  /// Counters for status and telemetry. Content-free.
  public struct Health: Sendable, Equatable {
    public var pipeline = CallSoundPipeline.Health()
    public var rebuilds = 0
    /// #4117: completed rebuilds, by what changed.
    public var rebuildReasons: [RebuildReason: Int] = [:]
    public var rebuildFailures = 0
    /// Core Audio calls in a teardown or listener change that returned an error.
    public var teardownFailures = 0
    public var listenerFailures = 0
    /// #4117: sustained mismatches whose rebuild the 5 s recovery interval held back; mismatch
    /// rebuilds confirmed by a later qualified window that agreed; and mismatches that remained
    /// after a mismatch rebuild, which stopped the call-sound track.
    public var suppressedMismatchRecoveries = 0
    public var verifiedRecoveries = 0
    public var persistentMismatches = 0
  }

  private let backend: CallSoundBackend
  private let pipeline: CallSoundPipeline
  private let queue = DispatchQueue(
    label: "com.enviouswispr.meeting.systemtap", qos: .userInitiated)
  private let listenerQueue = DispatchQueue(
    label: "com.enviouswispr.meeting.systemtap.listener", qos: .userInitiated)
  private let drainInterval: DispatchTimeInterval
  private let counters = OSAllocatedUnfairLock(initialState: Health())
  private let onEvent: @Sendable (Event) -> Void
  /// Content-free `CALL_SOUND` diagnostic lines (#4117), written on the tap queue.
  private let log: @Sendable (String) -> Void
  /// #4117: seconds on a monotonic clock, for the mismatch recovery interval; a parameter only
  /// so a test can move it.
  private let now: @Sendable () -> TimeInterval
  /// Provisional (plan §3.5): at most one mismatch rebuild per this many seconds.
  static let mismatchRecoveryInterval: TimeInterval = 5

  // Queue-confined.
  private var running = false
  private var stopped = false
  private var listening = false
  private var timer: DispatchSourceTimer?
  /// #4117: one per successful build, so every diagnostic line names the capture it describes.
  private var generation = 0
  private var diagnostics = CallSoundCaptureDiagnostics()
  /// What this generation was built against (#4117): output device, rate and buffer layout.
  /// Kept apart from live diagnostics; only a build sets it.
  private var committed: CallSoundCapture?
  private var configuredRate: Double { committed?.format.sampleRate ?? 0 }
  /// The generation with a change check, or a layout rebuild, already queued (#4117), so
  /// duplicate notices and repeated refusals queue one each.
  private var checkQueuedFor: Int?
  private var rebuildQueuedFor: Int?
  #if DEBUG
    private var idleWaitersForTesting: [DispatchSemaphore] = []
  #endif
  /// The measured-rate windows already reported for this generation.
  private var reportedWindows = 0
  /// An invalid-only measurement status was already reported for this generation.
  private var reportedInvalidOnly = false
  /// #4117 mismatch recovery. Kept across rebuilds: no build resets them, so a rebuild (for a
  /// mismatch or a notice) can neither erase the recovery interval nor verify a recovery.
  private var lastMismatchRecovery: TimeInterval?
  /// The generation that requested a mismatch rebuild not yet confirmed by a qualified window
  /// that agrees in a later generation.
  private var mismatchRecoveryFrom: Int?
  /// A suppressed request was already logged for this generation.
  private var reportedSuppressed = false

  public convenience init(
    onSamples: @escaping SampleHandler, onEvent: @escaping @Sendable (Event) -> Void
  ) {
    self.init(
      backend: CoreAudioCallSoundBackend(), onSamples: onSamples, onEvent: onEvent,
      drainInterval: .milliseconds(20))
  }

  init(
    backend: CallSoundBackend, onSamples: @escaping SampleHandler,
    onEvent: @escaping @Sendable (Event) -> Void, drainInterval: DispatchTimeInterval,
    handoffSeconds: Double = 2,
    log: @escaping @Sendable (String) -> Void = SystemAudioTap.appLog,
    now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.backend = backend
    self.pipeline = CallSoundPipeline(onSamples: onSamples, handoffSeconds: handoffSeconds)
    self.onEvent = onEvent
    self.drainInterval = drainInterval
    self.log = log
    self.now = now
  }

  static let appLog: @Sendable (String) -> Void = { line in
    Task { await AppLogger.shared.log(line, level: .info, category: "Meetings") }
  }

  /// RMS of the latest callback, 0...1, for the meter.
  public var currentLevel: Float { pipeline.currentLevel }

  public var health: Health {
    var health = counters.withLock { $0 }
    health.pipeline = pipeline.health
    return health
  }

  /// Starts capture. Throws, with everything released, when any step fails. Must not be called
  /// on the tap's queue.
  public func start() throws {
    dispatchPrecondition(condition: .notOnQueue(queue))
    try queue.sync {
      guard !stopped else { throw TapError.stopped }
      guard !running else { throw TapError.alreadyStarted }
      try buildOnQueue(trigger: "start")
      let notice: @Sendable (CallSoundNotice) -> Void = { [weak self] notice in
        self?.queue.async { self?.noteNotification(notice) }
      }
      if backend.installListeners(queue: listenerQueue, onNotice: notice) {
        listening = true
        // #4117: the build line was read before any listener existed; this one says which
        // notifications are actually watched.
        diagnostics = backend.captureDiagnostics()
        log("CALL_SOUND observed gen=\(generation) trigger=installed " + diagnostics.describe())
        // The first commitment was read before any listener existed, so a change in between
        // sent no notice: compare once now, inside start, so a capture that cannot follow the
        // change makes start throw instead of failing after start reported success.
        try revalidateAtStart()
      } else {
        counters.withLock { $0.listenerFailures += 1 }
        teardownOnQueue()
        throw TapError.status(operation: "install_listeners", value: -1)
      }
    }
  }

  /// Stops capture for good: no rebuild queued before or after this call restarts it. Hands
  /// over the audio already captured, including the converter's tail, before returning. Must
  /// not be called on the tap's queue. Repeatable.
  public func stop() {
    dispatchPrecondition(condition: .notOnQueue(queue))
    queue.sync { stopOnQueue() }
  }

  private func stopOnQueue() {
    #if DEBUG
      defer { signalIdleForTesting() }
    #endif
    guard !stopped else { return }
    stopped = true
    if listening {
      if !backend.removeListeners() { counters.withLock { $0.listenerFailures += 1 } }
      listening = false
    }
    teardownOnQueue()
  }

  // MARK: - Queue work

  private func buildOnQueue(trigger: String) throws {
    pipeline.setAccepting(false)
    do {
      let capture = try backend.start(ingest: pipeline.ingestBlock)
      try pipeline.configure(capture.format)
      committed = capture
      pipeline.setAccepting(true)
    } catch {
      teardownOnQueue()
      throw error
    }
    running = true
    generation += 1
    reportedWindows = 0
    reportedInvalidOnly = false
    reportedSuppressed = false
    diagnostics = backend.captureDiagnostics()
    log(
      "CALL_SOUND build gen=\(generation) trigger=\(trigger) configuredRate=\(CallSoundPipeline.rateText(configuredRate)) "
        + diagnostics.describe())
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + drainInterval, repeating: drainInterval)
    timer.setEventHandler { [weak self] in self?.drainOnQueue() }
    timer.resume()
    self.timer = timer
  }

  /// Tap queue: hands audio over, then reports what this capture is observed to deliver (#4117).
  /// Diagnostics only: nothing here changes the rate, the runs or recovery.
  private func drainOnQueue() {
    pipeline.drain()
    guard running else { return }
    if let layout = pipeline.takeNewLayout() {
      log(
        "CALL_SOUND buffers gen=\(generation) count=\(layout.buffers) channels=\(layout.channels) "
          + "mapping=\(diagnostics.mapping(to: layout))")
    }
    // #4117 §3.1: callbacks without the committed layout were refused in `ingest`, so none of
    // their samples were kept. When a fresh reading differs from the commitment (another
    // layout, device or rate) or cannot be read, rebuild for it, queued after this drain; a
    // rebuild that cannot use it fails as below. When the reading still matches, the callbacks
    // have a shape nothing describes: stop the call-sound track through the existing failure
    // path (the microphone track goes on) rather than record audio of unknown shape.
    if let refused = pipeline.takeRefusedLayout() {
      let committedChannels = committed?.format.bufferChannels
      let current = try? backend.currentCapture()
      let reason: RebuildReason? =
        if let current { committed?.change(to: current) } else { .unreadable }
      log(
        "CALL_SOUND refused gen=\(generation) callbacks=\(refused.callbacks) "
          + "count=\(refused.layout.buffers) channels=\(refused.layout.channels) "
          + "committed=\(committedChannels.map { "\($0)" } ?? "any") "
          + "reported=\(current.flatMap { $0.format.bufferChannels }.map { "\($0)" } ?? "unreadable") "
          + "action=\(reason.map { "rebuild:\($0.rawValue)" } ?? "stop")")
      if let reason {
        queueRebuild(reason: reason)
        return
      }
      teardownOnQueue()
      counters.withLock { $0.rebuildFailures += 1 }
      onEvent(.rebuildFailed("call-sound buffer layout \(refused.layout.channels)"))
      return
    }
    // The observation belongs to this generation only (reset at configure).
    let observation = pipeline.inputRateObservation
    // #4117 §3.5: outcomes in the order the buffers were acquired, so a mismatch that remained
    // after a rebuild is met before any later agreement. A mismatch rebuild is verified only by
    // a qualified window that agrees, in a generation after the one that asked for it; invalid
    // or missing timing proves nothing.
    for outcome in pipeline.takeRateOutcomes() {
      switch outcome {
      case .agreement:
        guard let from = mismatchRecoveryFrom, generation > from else { continue }
        mismatchRecoveryFrom = nil
        counters.withLock { $0.verifiedRecoveries += 1 }
        log(
          "CALL_SOUND verified gen=\(generation) configured=\(CallSoundPipeline.rateText(configuredRate))")
      case .sustainedMismatch(let measured):
        handleSustainedMismatch(measured: measured)
      }
      guard running else { return }
    }
    let windows = observation.windowsMeasured
    let invalid = observation.invalidTimestamp + observation.nonIncreasing + observation.inputLoss
    // The first window of each capture, then about every 30 s of valid measurement; or, once,
    // that nothing measurable has arrived yet.
    let firstOrPeriodic =
      windows > reportedWindows && (reportedWindows == 0 || windows - reportedWindows >= 60)
    let invalidOnly = windows == 0 && invalid > 0 && !reportedInvalidOnly
    guard firstOrPeriodic || invalidOnly else { return }
    if invalidOnly { reportedInvalidOnly = true } else { reportedWindows = windows }
    let measured = observation.lastRate.map { CallSoundPipeline.rateText($0) } ?? "unavailable"
    log(
      "CALL_SOUND measured gen=\(generation) rate=\(measured) configured=\(CallSoundPipeline.rateText(configuredRate)) "
        + "windows=\(windows) invalid=\(observation.invalidTimestamp)/\(observation.nonIncreasing)/"
        + "\(observation.inputLoss) discontinuitiesTotal=\(pipeline.health.discontinuities) "
        + "qualified=\(observation.windowsQualified) rejected=\(observation.windowsRejected)")
  }

  /// Tap queue, after a drain: the buffers' timing disagreed with the configured rate for three
  /// qualified windows. Once per recovery interval it queues a rebuild, which reads the
  /// aggregate's nominal rate again (never the measured one). A mismatch that remains after
  /// such a rebuild stops the call-sound track (the microphone track goes on) instead of
  /// rebuilding without end.
  private func handleSustainedMismatch(measured: Double) {
    let line =
      "CALL_SOUND mismatch gen=\(generation) measured=\(CallSoundPipeline.rateText(measured)) "
      + "configured=\(CallSoundPipeline.rateText(configuredRate))"
    if let from = mismatchRecoveryFrom, generation > from {
      log(line + " action=stop reason=persistent")
      teardownOnQueue()
      counters.withLock { $0.persistentMismatches += 1 }
      onEvent(
        .rebuildFailed(
          "call-sound rate mismatch persists: measured \(CallSoundPipeline.rateText(measured)) "
            + "configured \(CallSoundPipeline.rateText(configuredRate))"))
      return
    }
    let time = now()
    if let last = lastMismatchRecovery, time - last < Self.mismatchRecoveryInterval {
      counters.withLock { $0.suppressedMismatchRecoveries += 1 }
      if !reportedSuppressed {
        reportedSuppressed = true
        log(line + " action=suppressed reason=interval")
      }
      return
    }
    lastMismatchRecovery = time
    mismatchRecoveryFrom = generation
    log(line + " action=rebuild")
    queueRebuild(reason: .rateMismatch)
  }

  /// Tap queue: a Core Audio property notification arrived (#4117). Logs where it came from,
  /// then re-reads the formats (and re-watches a changed stream list) so the line after it
  /// shows the state it announced. A notice from a capture already torn down is ignored. Any
  /// other queues one comparison with the commitment; the notice itself never rebuilds.
  private func noteNotification(_ notice: CallSoundNotice) {
    log(
      "CALL_SOUND notify gen=\(generation) \(notice.describe()) currentBuild=\(diagnostics.build) "
        + "running=\(running)")
    guard running, !stopped, let committed else { return }
    // Build 0 is the system object, which outlives every capture.
    guard notice.build == 0 || notice.build == committed.build else {
      log("CALL_SOUND ignored gen=\(generation) build=\(notice.build) reason=retired")
      return
    }
    let watching = backend.reconcileWatch()
    diagnostics = backend.captureDiagnostics()
    log("CALL_SOUND observed gen=\(generation) " + diagnostics.describe())
    // A stream nothing watches could change format unseen: rebuild rather than go on.
    guard watching else {
      rebuildOnQueue(reason: .watchFailed)
      return
    }
    queueChangeCheck()
  }

  /// Tap queue, inside `start`: the comparison `checkForChange` makes, done before `start`
  /// returns. A difference (or an unreadable reading) builds again at once; when that build
  /// fails, every listener goes and `start` throws. No event is sent: `start` reports it.
  private func revalidateAtStart() throws {
    guard let committed else { return }
    let reason: RebuildReason?
    do {
      reason = committed.change(to: try backend.currentCapture())
    } catch {
      reason = .unreadable
    }
    guard let reason else { return }
    log("CALL_SOUND revalidate gen=\(generation) reason=\(reason.rawValue)")
    teardownOnQueue()
    do {
      try buildOnQueue(trigger: "start reason=\(reason.rawValue)")
    } catch {
      if !backend.removeListeners() { counters.withLock { $0.listenerFailures += 1 } }
      listening = false
      throw error
    }
  }

  /// Queues one comparison for this generation, after any notices already queued, so a burst
  /// (the nominal rate, then the stream format) is read once, in its final state.
  private func queueChangeCheck() {
    guard checkQueuedFor != generation else { return }
    checkQueuedFor = generation
    let queued = generation
    queue.async { [weak self] in self?.checkForChange(queuedFor: queued) }
  }

  /// Tap queue: re-reads the output device, the aggregate's nominal rate and the validated
  /// buffer layout, and rebuilds when any differs from the commitment. A stream's virtual rate
  /// is not compared: it kept reading 48 kHz while AirPods delivered 24 kHz.
  private func checkForChange(queuedFor queued: Int) {
    #if DEBUG
      defer { signalIdleForTesting() }
    #endif
    if checkQueuedFor == queued { checkQueuedFor = nil }
    guard !stopped, running, queued == generation, let committed else { return }
    let reason: RebuildReason
    do {
      guard let changed = committed.change(to: try backend.currentCapture()) else { return }
      reason = changed
    } catch {
      reason = .unreadable
    }
    rebuildOnQueue(reason: reason)
  }

  /// Queues a rebuild for this generation, run after the current drain, never inside it.
  private func queueRebuild(reason: RebuildReason) {
    guard rebuildQueuedFor != generation else { return }
    rebuildQueuedFor = generation
    let queued = generation
    queue.async { [weak self] in
      guard let self else { return }
      #if DEBUG
        defer { self.signalIdleForTesting() }
      #endif
      if self.rebuildQueuedFor == queued { self.rebuildQueuedFor = nil }
      guard queued == self.generation else { return }
      self.rebuildOnQueue(reason: reason)
    }
  }

  /// Releases the Core Audio objects, then hands over what was already captured with the old
  /// converter (its tail included), so a rebuild never mixes two formats in one run.
  private func teardownOnQueue() {
    pipeline.setAccepting(false)
    timer?.cancel()
    timer = nil
    let failures = backend.stop()
    if failures > 0 { counters.withLock { $0.teardownFailures += failures } }
    pipeline.drain()
    pipeline.finishRun()
    running = false
  }

  /// The only full rebuild: retires this generation (admission off, its listeners and objects
  /// gone, its accepted audio and converter tail handed over), then builds and commits the next.
  private func rebuildOnQueue(reason: RebuildReason) {
    guard !stopped, running else { return }
    teardownOnQueue()
    do {
      try buildOnQueue(trigger: "rebuild reason=\(reason.rawValue)")
      counters.withLock {
        $0.rebuilds += 1
        $0.rebuildReasons[reason, default: 0] += 1
      }
      onEvent(.rebuilt)
    } catch {
      counters.withLock { $0.rebuildFailures += 1 }
      log("CALL_SOUND rebuildFailed gen=\(generation) reason=\(reason.rawValue)")
      onEvent(.rebuildFailed(String(describing: error)))
    }
  }

  #if DEBUG
    /// Runs one drain on the tap queue and returns after it.
    func drainForTesting() { queue.sync { drainOnQueue() } }
    /// Signals waiters once no change check or rebuild is still queued. Tap queue only; each
    /// exit of a queued check, rebuild or stop calls it.
    private func signalIdleForTesting() {
      guard checkQueuedFor == nil, rebuildQueuedFor == nil else { return }
      let ready = idleWaitersForTesting
      idleWaitersForTesting.removeAll()
      for waiter in ready { waiter.signal() }
    }

    /// True once the tap signals that no change check or rebuild is queued; false when it has
    /// not by `deadline` (a hang guard, not a latency bound), even if the queue is blocked.
    func settleForTesting(deadline seconds: TimeInterval = 10) -> Bool {
      dispatchPrecondition(condition: .notOnQueue(queue))
      let finished = DispatchSemaphore(value: 0)
      queue.async { [self] in
        idleWaitersForTesting.append(finished)
        signalIdleForTesting()
      }
      return finished.wait(timeout: .now() + seconds) == .success
    }
    /// Blocks the tap queue until the returned release runs, so a test can queue work in a
    /// known order behind it.
    func holdQueueForTesting() -> @Sendable () -> Void {
      let gate = DispatchSemaphore(value: 0)
      queue.async { gate.wait() }
      return { gate.signal() }
    }
    /// Queues `stop` behind whatever is already queued, as a caller on another thread would.
    func enqueueStopForTesting() { queue.async { [self] in stopOnQueue() } }
    /// Queues one drain behind whatever is already queued, as the drain timer does.
    func enqueueDrainForTesting() { queue.async { [self] in drainOnQueue() } }
  #endif
}

// MARK: - Pipeline

/// The tap's data path, free of Core Audio objects so it can be driven with synthetic buffers
/// (#3972 C2b): IOProc buffers → mono, under a lock, into storage reserved at configure time →
/// (tap queue) resample to 16 kHz → the owner, with each run's acquisition host time.
///
/// Each IOProc buffer keeps its own `mHostTime`. Buffers whose times do not continue one
/// another (a dropped buffer, a full handoff, an output-device change) end the current run:
/// the converter's tail is handed over and the next run starts at its own time, so audio is
/// never stamped with another buffer's clock.
public final class CallSoundPipeline: @unchecked Sendable {
  /// `startsNewRun` is true for the first samples of each run after the first: they do not
  /// continue what was handed over before, and the consumer must not join them to it.
  public typealias SampleHandler = @Sendable (
    _ samples: UnsafeBufferPointer<Float>, _ hostTime: UInt64, _ startsNewRun: Bool
  ) -> Void

  public struct Health: Sendable, Equatable {
    public var framesCaptured = 0
    public var framesDelivered = 0
    /// Frames the handoff had no room for.
    public var droppedFrames = 0
    /// IOProc buffers with no data pointer or no channels.
    public var unreadableBuffers = 0
    public var conversionFailures = 0
    /// Runs ended because the next buffer's time did not continue the last one.
    public var discontinuities = 0
    /// #4117: sustained disagreements found: three consecutive qualified windows, each more
    /// than 5% from the configured rate and within 5% of their shared median.
    public var rateMismatches = 0
  }

  struct InputFormat: Equatable, Sendable {
    let sampleRate: Double
    /// #4117: the buffer layout this capture committed to (each buffer's channel count, any
    /// number of buffers). A callback with any other layout is refused before its samples are
    /// kept.
    /// Nil admits any readable layout (tests and callers that commit none).
    var bufferChannels: [UInt32]? = nil
  }

  /// #4117: the input rate measured from the buffers' own acquisition times. Independent of the
  /// converter, its priming and tails, and of run breaks, so it still measures when every buffer
  /// is a discontinuity.
  struct InputRateObservation: Sendable, Equatable {
    /// The last completed window's frames per second in this generation; nil until one completes.
    var lastRate: Double?
    var windowsMeasured = 0
    /// Completed windows whose timing qualified them as a rate, and those rejected (too few
    /// intervals, a timing outlier, or a cadence that disagrees with the window's rate).
    var windowsQualified = 0
    var windowsRejected = 0
    /// Qualified windows within 5% of the configured rate.
    var windowsAgreeing = 0
    /// Observations abandoned, by reason: no valid acquisition time, a time at or before the
    /// previous one, and input lost or cut short before the handoff.
    var invalidTimestamp = 0
    var nonIncreasing = 0
    var inputLoss = 0
  }

  /// The buffer layout `ingest` read: buffer count and each buffer's channels (first eight).
  struct BufferLayout: Equatable, Sendable {
    var buffers: Int
    var channels: [UInt32]
  }

  /// Frames over acquisition time, windowed. For buffer starts H0...Hn it compares the frames of
  /// buffers 0...n-1 with Hn - H0: the last buffer's frames are excluded because its duration is
  /// not known yet. The buffer that closes a window starts the next, so no frame counts twice.
  ///
  /// #4117 R3: a window is a rate only when its own timing is regular. Each interval's step per
  /// frame, qi = (Hi+1 - Hi) / Ni, uses the earlier buffer's full frame count, so buffers of
  /// different lengths do not upset it. A window needs three intervals, no step above four times
  /// the median step (a startup gap read 5,374 Hz on the founder's AirPods), and a window rate
  /// within 5% of 1 / median step (smaller recurring gaps bias the rate without being outliers).
  /// None of this uses the configured rate. The bounds are provisional (plan §3.5).
  struct InputRateMeter {
    static let minimumIntervals = 3
    static let outlierFactor = 4.0
    static let cadenceTolerance = 0.05

    enum Rejection: String, Sendable { case tooFewIntervals, timingOutlier, cadenceDisagrees }

    /// One completed window: its frames-per-second rate and whether its timing qualified it.
    struct Window: Equatable, Sendable {
      var rate: Double
      var intervals: Int
      var rejection: Rejection?
      var qualified: Bool { rejection == nil }
    }

    /// What one buffer did, in acquisition order: an invalidation before it, a window it
    /// completed, an invalidation after it (a truncated closing buffer).
    struct Event: Equatable, Sendable {
      var invalidatedBefore = false
      var window: Window?
      var invalidatedAfter = false
    }

    let windowSeconds: Double
    private(set) var observation = InputRateObservation()
    private var startHost: UInt64?
    private var lastHost: UInt64 = 0
    private var framesBeforeLast = 0
    private var lastFrames = 0
    /// Seconds per frame of each interval in the current window; tap queue only.
    private var steps: [Double] = []

    init(windowSeconds: Double = 0.5) {
      self.windowSeconds = windowSeconds
      steps.reserveCapacity(256)
    }

    /// Starts over, keeping the counters: a new capture generation or an invalid observation.
    mutating func reset() {
      startHost = nil
      framesBeforeLast = 0
      lastFrames = 0
      steps.removeAll(keepingCapacity: true)
    }

    mutating func observe(
      frames: Int, hostTime: UInt64, valid: Bool, afterLoss: Bool, truncated: Bool
    ) -> Event {
      var event = Event()
      guard valid else {
        observation.invalidTimestamp += 1
        reset()
        event.invalidatedBefore = true
        return event
      }
      if afterLoss {
        observation.inputLoss += 1
        reset()
        event.invalidatedBefore = true
      }
      if let start = startHost {
        guard hostTime > lastHost else {
          observation.nonIncreasing += 1
          reset()
          event.invalidatedBefore = true
          // A truncated buffer may not anchor the next window either.
          if truncated {
            observation.inputLoss += 1
            event.invalidatedAfter = true
          } else {
            begin(frames: frames, hostTime: hostTime)
          }
          return event
        }
        if lastFrames > 0 {
          steps.append(CallSoundPipeline.seconds(hostTime - lastHost) / Double(lastFrames))
        }
        framesBeforeLast += lastFrames
        let span = CallSoundPipeline.seconds(hostTime - start)
        if span >= windowSeconds {
          let window = Self.qualify(frames: framesBeforeLast, span: span, steps: steps)
          observation.lastRate = window.rate
          observation.windowsMeasured += 1
          if window.qualified {
            observation.windowsQualified += 1
          } else {
            observation.windowsRejected += 1
          }
          event.window = window
          // This buffer starts the next window.
          startHost = hostTime
          framesBeforeLast = 0
          steps.removeAll(keepingCapacity: true)
        }
        lastHost = hostTime
        lastFrames = frames
      } else {
        begin(frames: frames, hostTime: hostTime)
      }
      if truncated {
        // Part of this buffer never reached the handoff; it may not anchor a measurement.
        observation.inputLoss += 1
        reset()
        event.invalidatedAfter = true
      }
      return event
    }

    /// The window rule, pure: `steps` are the intervals' seconds per frame.
    static func qualify(frames: Int, span: Double, steps: [Double]) -> Window {
      let rate = Double(frames) / span
      guard steps.count >= minimumIntervals else {
        return Window(rate: rate, intervals: steps.count, rejection: .tooFewIntervals)
      }
      let median = Self.median(steps)
      guard median > 0, !steps.contains(where: { $0 > outlierFactor * median }) else {
        return Window(rate: rate, intervals: steps.count, rejection: .timingOutlier)
      }
      let cadence = 1 / median
      guard abs(rate - cadence) / cadence <= cadenceTolerance else {
        return Window(rate: rate, intervals: steps.count, rejection: .cadenceDisagrees)
      }
      return Window(rate: rate, intervals: steps.count, rejection: nil)
    }

    static func median(_ values: [Double]) -> Double {
      let sorted = values.sorted()
      let middle = sorted.count / 2
      return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// A qualified window agreed with the configured rate (counted by the pipeline, which knows
    /// that rate).
    mutating func noteAgreement() { observation.windowsAgreeing += 1 }

    private mutating func begin(frames: Int, hostTime: UInt64) {
      startHost = hostTime
      lastHost = hostTime
      framesBeforeLast = 0
      lastFrames = frames
      steps.removeAll(keepingCapacity: true)
    }
  }

  /// #4117 §3.4: consecutive qualified windows that disagree with the configured rate. Three in
  /// a row, each more than 5% from the configured rate and all within 5% of their shared median,
  /// are a sustained mismatch. A healthy window, a rejected window or an invalidation clears it;
  /// a mismatching window that does not agree with the others starts a new streak. The bounds
  /// are provisional (plan §3.5).
  struct MismatchStreak {
    static let required = 3
    static let disagreement = 0.05
    static let agreement = 0.05

    enum Outcome: Equatable, Sendable {
      case agrees
      case mismatch(count: Int)
      /// The streak's shared median rate; the streak starts over after it.
      case sustained(Double)
    }

    private(set) var rates: [Double] = []

    mutating func clear() { rates.removeAll(keepingCapacity: true) }

    mutating func add(_ rate: Double, configured: Double) -> Outcome {
      guard abs(rate - configured) / configured > Self.disagreement else {
        clear()
        return .agrees
      }
      let candidate = rates + [rate]
      let median = InputRateMeter.median(candidate)
      rates =
        candidate.allSatisfy({ abs($0 - median) / median <= Self.agreement }) ? candidate : [rate]
      guard rates.count >= Self.required else { return .mismatch(count: rates.count) }
      let shared = InputRateMeter.median(rates)
      clear()
      return .sustained(shared)
    }
  }

  private struct Chunk {
    var offset: Int
    var frames: Int
    var hostTime: UInt64
    /// #4117: the IOProc's acquisition time was valid (not the fallback clock).
    var hostTimeValid = true
    /// Input was lost (unreadable or no room) since the previous chunk.
    var afterLoss = false
    /// This buffer did not fit whole.
    var truncated = false
    /// The buffer's own frame count before any truncation.
    var inputFrames = 0
  }

  private struct Handoff {
    var samples: [Float] = []
    var chunks: [Chunk] = []
    var capacity = 0
    var maxChunks = 0
    var accepting = false
    var droppedFrames = 0
    var unreadableBuffers = 0
    var framesCaptured = 0
    var level: Float = 0
    /// #4117: input lost since the last accepted chunk.
    var lossPending = false
    /// The latest buffer layout seen since configure, held without allocating; `layoutChanged`
    /// marks a new one not yet reported.
    var layoutSeen = false
    var layoutChanged = false
    var layoutBuffers = 0
    var layoutChannels = SIMD8<UInt32>()
    /// #4117: the committed layout (`expectedBuffers` < 0 admits any) and the callbacks refused
    /// because they did not have it, with the first refused layout.
    var expectedBuffers = -1
    /// Filled at configure (allocation happens there); the callback only reads it.
    var expectedChannels: [UInt32] = []
    var refusedCallbacks = 0
    var refusedBuffers = 0
    var refusedChannels = SIMD8<UInt32>()
  }

  private let onSamples: SampleHandler
  private let handoffSeconds: Double
  private let handoff = OSAllocatedUnfairLock(initialState: Handoff())
  private let stats = OSAllocatedUnfairLock(initialState: Health())

  // Tap-queue-confined (configure, drain, finishRun).
  private var scratchSamples: [Float] = []
  private var scratchChunks: [Chunk] = []
  private var sampleRate: Double = 0
  private var converter: AVAudioConverter?
  private var inputFormat: AVAudioFormat?
  private var runStartHost: UInt64?
  private var runExpectedHost: UInt64 = 0
  private var runOutputFrames = 0
  /// The next delivery is the first of a run that follows an earlier run.
  private var runBreakPending = false
  private var deliveredAnyRun = false
  private var meter = InputRateMeter()
  private var streak = MismatchStreak()
  /// #4117: what recovery needs from this generation's windows, in acquisition order, not yet
  /// taken by the tap.
  private var rateOutcomes: [RateOutcome] = []
  private let rateObservation = OSAllocatedUnfairLock(initialState: InputRateObservation())

  init(onSamples: @escaping SampleHandler, handoffSeconds: Double = 2) {
    self.onSamples = onSamples
    self.handoffSeconds = handoffSeconds
  }

  var currentLevel: Float { handoff.withLock { $0.level } }

  /// #4117: what the input-rate meter has observed in the current generation.
  var inputRateObservation: InputRateObservation { rateObservation.withLock { $0 } }

  /// Tap queue: the first callback layout refused since configure (with the refused count), or
  /// nil when every callback had the committed layout. The layout lists the first eight
  /// buffers' channels; `buffers` is the full count.
  func takeRefusedLayout() -> (layout: BufferLayout, callbacks: Int)? {
    let refused = handoff.withLock { state -> (Int, SIMD8<UInt32>, Int)? in
      state.refusedCallbacks > 0
        ? (state.refusedBuffers, state.refusedChannels, state.refusedCallbacks) : nil
    }
    guard let refused else { return nil }
    let count = min(refused.0, 8)
    return (
      BufferLayout(buffers: refused.0, channels: (0..<count).map { refused.1[$0] }), refused.2
    )
  }

  /// Tap queue: the buffer layout `ingest` read, when it is new since configure or changed since
  /// last reported.
  func takeNewLayout() -> BufferLayout? {
    let seen = handoff.withLock { state -> (Int, SIMD8<UInt32>)? in
      guard state.layoutChanged else { return nil }
      state.layoutChanged = false
      return (state.layoutBuffers, state.layoutChannels)
    }
    guard let seen else { return nil }
    let count = min(seen.0, 8)
    return BufferLayout(buffers: seen.0, channels: (0..<count).map { seen.1[$0] })
  }

  public var health: Health {
    var health = stats.withLock { $0 }
    let live = handoff.withLock { ($0.droppedFrames, $0.unreadableBuffers, $0.framesCaptured) }
    health.droppedFrames += live.0
    health.unreadableBuffers += live.1
    health.framesCaptured += live.2
    return health
  }

  /// Prepares for `format`: reserves the handoff for `handoffSeconds` of audio at its rate and
  /// builds the converter. Call with accepting off, after the previous run was finished.
  func configure(_ format: InputFormat) throws {
    guard format.sampleRate > 0,
      let input = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1,
        interleaved: false),
      let output = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: MeetingAudioFormat.sampleRate, channels: 1,
        interleaved: false),
      let converter = AVAudioConverter(from: input, to: output)
    else { throw SystemAudioTapFormatError.unusable }
    let capacity = max(1, Int(format.sampleRate * handoffSeconds))
    let maxChunks = max(16, capacity / 64)
    // Allocation happens here, never in the IOProc.
    handoff.withLock { state in
      state.samples = []
      state.samples.reserveCapacity(capacity)
      state.chunks = []
      state.chunks.reserveCapacity(maxChunks)
      state.capacity = capacity
      state.maxChunks = maxChunks
      state.lossPending = false
      state.layoutSeen = false
      state.layoutChanged = false
      state.refusedCallbacks = 0
      if let committed = format.bufferChannels {
        state.expectedBuffers = committed.count
        state.expectedChannels = committed
      } else {
        state.expectedBuffers = -1
        state.expectedChannels = []
      }
    }
    scratchSamples = []
    scratchSamples.reserveCapacity(capacity)
    scratchChunks = []
    scratchChunks.reserveCapacity(maxChunks)
    self.sampleRate = format.sampleRate
    self.converter = converter
    self.inputFormat = input
    runStartHost = nil
    // #4117: a new capture generation measures afresh, and says so at once.
    meter = InputRateMeter()
    streak.clear()
    rateOutcomes.removeAll(keepingCapacity: true)
    rateOutcomes.reserveCapacity(64)
    rateObservation.withLock { $0 = InputRateObservation() }
  }

  /// #4117: a qualified window that agreed with the configured rate, or a sustained mismatch
  /// (its shared median rate).
  enum RateOutcome: Equatable, Sendable {
    case agreement
    case sustainedMismatch(Double)
  }

  /// Tap queue: the agreements and sustained mismatches found since the last call in this
  /// generation, in acquisition order. Taking them is what reports them; reading observations
  /// never does.
  func takeRateOutcomes() -> [RateOutcome] {
    defer { rateOutcomes.removeAll(keepingCapacity: true) }
    return rateOutcomes
  }

  func setAccepting(_ accepting: Bool) { handoff.withLock { $0.accepting = accepting } }

  /// The IOProc's work, for the backend to call from the real-time thread. The flag says the
  /// host time is the buffer's valid acquisition time rather than the fallback clock.
  var ingestBlock: @Sendable (UnsafePointer<AudioBufferList>, UInt64, Bool) -> Void {
    { [self] list, hostTime, valid in ingest(list, hostTime: hostTime, hostTimeValid: valid) }
  }

  /// Real-time thread. Down-mixes every channel of every buffer (each buffer's own channel
  /// count and byte size; nothing past a buffer's end is read) into reserved storage. No
  /// allocation, logging, conversion or dispatch.
  func ingest(
    _ list: UnsafePointer<AudioBufferList>, hostTime: UInt64, hostTimeValid: Bool = true
  ) {
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
    var frames = Int.max
    var totalChannels = 0
    var readable = buffers.count > 0
    var layoutChannels = SIMD8<UInt32>()
    for (index, buffer) in buffers.enumerated() {
      if index < 8 { layoutChannels[index] = buffer.mNumberChannels }
      let channels = Int(buffer.mNumberChannels)
      guard buffer.mData != nil, channels > 0 else {
        readable = false
        break
      }
      totalChannels += channels
      frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
    }
    handoff.withLockUnchecked { state in
      guard state.accepting else { return }
      if !state.layoutSeen || state.layoutBuffers != buffers.count
        || state.layoutChannels != layoutChannels
      {
        state.layoutSeen = true
        state.layoutChanged = true
        state.layoutBuffers = buffers.count
        state.layoutChannels = layoutChannels
      }
      guard readable else {
        state.unreadableBuffers += 1
        state.lossPending = true
        return
      }
      // #4117: a callback without the committed layout is refused whole, before any sample is
      // kept: its channels cannot be read at the committed rate and format.
      var matchesCommitted = state.expectedBuffers < 0 || buffers.count == state.expectedBuffers
      if matchesCommitted, state.expectedBuffers >= 0 {
        for (index, buffer) in buffers.enumerated()
        where buffer.mNumberChannels != state.expectedChannels[index] {
          matchesCommitted = false
          break
        }
      }
      if !matchesCommitted {
        if state.refusedCallbacks == 0 {
          state.refusedBuffers = buffers.count
          state.refusedChannels = layoutChannels
        }
        state.refusedCallbacks += 1
        state.lossPending = true
        return
      }
      guard frames > 0, frames != Int.max else { return }
      state.framesCaptured += frames
      let room = state.capacity - state.samples.count
      guard room > 0, state.chunks.count < state.maxChunks else {
        state.droppedFrames += frames
        state.lossPending = true
        return
      }
      let take = min(room, frames)
      state.chunks.append(
        Chunk(
          offset: state.samples.count, frames: take, hostTime: hostTime,
          hostTimeValid: hostTimeValid, afterLoss: state.lossPending, truncated: take < frames,
          inputFrames: frames))
      state.lossPending = false
      var sumSquares: Float = 0
      let scale = 1 / Float(totalChannels)
      for f in 0..<take {
        var sum: Float = 0
        for buffer in buffers {
          let channels = Int(buffer.mNumberChannels)
          let p = buffer.mData!.assumingMemoryBound(to: Float.self)
          for c in 0..<channels { sum += p[f * channels + c] }
        }
        let mono = sum * scale
        state.samples.append(mono)
        sumSquares += mono * mono
      }
      state.droppedFrames += frames - take
      state.level = min(1, (sumSquares / Float(take)).squareRoot() * 4)
    }
  }

  /// Tap queue. Swaps the filled handoff for the empty one (no copy, no allocation under the
  /// lock), then resamples and delivers outside it.
  func drain() {
    handoff.withLockUnchecked { state in
      swap(&state.samples, &scratchSamples)
      swap(&state.chunks, &scratchChunks)
    }
    defer {
      scratchSamples.removeAll(keepingCapacity: true)
      scratchChunks.removeAll(keepingCapacity: true)
    }
    guard !scratchChunks.isEmpty else { return }
    defer { rateObservation.withLock { $0 = meter.observation } }
    // Two buffers continue one another when the later one starts within 4 ms of where the
    // earlier one ends.
    let tolerance = Self.ticks(seconds: 0.004)
    for chunk in scratchChunks {
      // #4117: measured before, and independently of, the run logic below, so the run breaks a
      // genuine mismatch causes never invalidate its windows.
      evaluate(
        meter.observe(
          frames: chunk.inputFrames, hostTime: chunk.hostTime, valid: chunk.hostTimeValid,
          afterLoss: chunk.afterLoss, truncated: chunk.truncated))
      if runStartHost != nil {
        let gap =
          chunk.hostTime > runExpectedHost
          ? chunk.hostTime - runExpectedHost : runExpectedHost - chunk.hostTime
        if gap > tolerance {
          finishRun()
          stats.withLock { $0.discontinuities += 1 }
        }
      }
      if runStartHost == nil {
        runStartHost = chunk.hostTime
        runOutputFrames = 0
        runBreakPending = deliveredAnyRun
      }
      runExpectedHost = chunk.hostTime &+ Self.ticks(seconds: Double(chunk.frames) / sampleRate)
      scratchSamples.withUnsafeBufferPointer { all in
        convert(UnsafeBufferPointer(rebasing: all[chunk.offset..<(chunk.offset + chunk.frames)]))
      }
    }
  }

  /// #4117: one buffer's meter event against the streak, in acquisition order.
  private func evaluate(_ event: InputRateMeter.Event) {
    if event.invalidatedBefore { streak.clear() }
    if let window = event.window {
      if !window.qualified {
        streak.clear()
      } else {
        switch streak.add(window.rate, configured: sampleRate) {
        case .agrees:
          meter.noteAgreement()
          rateOutcomes.append(.agreement)
        case .mismatch: break
        case .sustained(let rate):
          rateOutcomes.append(.sustainedMismatch(rate))
          stats.withLock { $0.rateMismatches += 1 }
        }
      }
    }
    if event.invalidatedAfter { streak.clear() }
  }

  /// Ends the current run: the converter's held-back tail is delivered and the converter reset,
  /// so the next run starts clean at its own time.
  func finishRun() {
    guard runStartHost != nil else { return }
    convert(nil)
    converter?.reset()
    runStartHost = nil
  }

  /// Feeds `input` (nil = end of stream) and delivers whatever comes out. A converter that
  /// holds frames back while priming produces less now and the rest later; that is not loss.
  private func convert(_ input: UnsafeBufferPointer<Float>?) {
    guard let converter, let inputFormat, let start = runStartHost else { return }
    var inBuffer: AVAudioPCMBuffer?
    if let input, !input.isEmpty {
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(input.count))
      else {
        stats.withLock { $0.conversionFailures += 1 }
        return
      }
      buffer.frameLength = AVAudioFrameCount(input.count)
      buffer.floatChannelData![0].update(from: input.baseAddress!, count: input.count)
      inBuffer = buffer
    } else if input != nil {
      return
    }
    let ratio = MeetingAudioFormat.sampleRate / inputFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(input?.count ?? 0) * ratio + 256)
    var fed = false
    // Pull until the converter has nothing more to give: one output buffer may not hold all
    // it releases, above all at a flush, and whatever stays inside would be lost at `reset`.
    while true {
      guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity)
      else {
        stats.withLock { $0.conversionFailures += 1 }
        return
      }
      var error: NSError?
      let status = converter.convert(to: out, error: &error) { _, outStatus in
        if let inBuffer, !fed {
          fed = true
          outStatus.pointee = .haveData
          return inBuffer
        }
        outStatus.pointee = inBuffer == nil ? .endOfStream : .noDataNow
        return nil
      }
      if status == .error || error != nil {
        stats.withLock { $0.conversionFailures += 1 }
        return
      }
      let produced = Int(out.frameLength)
      if produced > 0, let data = out.floatChannelData {
        let host =
          start &+ Self.ticks(seconds: Double(runOutputFrames) / MeetingAudioFormat.sampleRate)
        runOutputFrames += produced
        stats.withLock { $0.framesDelivered += produced }
        let startsNewRun = runBreakPending
        runBreakPending = false
        deliveredAnyRun = true
        onSamples(UnsafeBufferPointer(start: data[0], count: produced), host, startsNewRun)
      }
      // `.haveData`: the buffer filled and more output is ready. Anything else (input ran
      // dry, end of stream) means the converter holds nothing more for now.
      guard status == .haveData, produced > 0 else { return }
    }
  }

  static func ticks(seconds: Double) -> UInt64 {
    AudioConvertNanosToHostTime(UInt64(max(0, seconds) * 1_000_000_000))
  }

  /// A rate for a diagnostic line (#4117).
  static func rateText(_ value: Double) -> String { String(format: "%.1f", value) }

  static func seconds(_ ticks: UInt64) -> Double {
    Double(AudioConvertHostTimeToNanos(ticks)) / 1_000_000_000
  }
}

enum SystemAudioTapFormatError: Error {
  case unusable
}

// MARK: - Core Audio backend

/// The Core Audio objects behind a tap. A protocol so the tap's lifecycle can be driven without
/// them in tests.
protocol CallSoundBackend: AnyObject {
  /// Creates and starts the tap, aggregate and IOProc, delivering buffers to `ingest` with
  /// whether the host time is the buffer's valid acquisition time. Returns what this capture
  /// commits to. Once listeners are installed, it watches the new objects too, and throws when
  /// a required watch cannot be registered. On a throw, everything it created is already
  /// released.
  func start(
    ingest: @escaping @Sendable (UnsafePointer<AudioBufferList>, UInt64, Bool) -> Void
  ) throws -> CallSoundCapture
  /// Stops and releases everything in Apple's order, removing the listeners on each object
  /// before destroying it. Returns how many calls failed. Repeatable.
  func stop() -> Int
  /// Watches the default output device (for the life of the tap) and, per build, the tap's
  /// format, the aggregate's nominal rate and input-stream list, and each input stream's
  /// virtual format. False, with every registration rolled back, when any cannot be
  /// registered. `onNotice` names the property, on `queue`; it never rebuilds by itself.
  func installListeners(
    queue: DispatchQueue, onNotice: @escaping @Sendable (CallSoundNotice) -> Void
  ) -> Bool
  func removeListeners() -> Bool
  /// #4117: what a capture built now would commit to: the default output device now, and the
  /// running aggregate's nominal rate and validated layout. Throws when any cannot be read or
  /// used. Tap queue only.
  func currentCapture() throws -> CallSoundCapture
  /// #4117: what the running capture reports about its formats. Never throws; a value it could
  /// not read is nil.
  func captureDiagnostics() -> CallSoundCaptureDiagnostics
  /// #4117: re-watches the aggregate's current input streams (a changed stream list). False
  /// when the list cannot be read or a stream's format watch cannot be registered: a stream
  /// nobody watches could change format unseen. Tap queue only.
  func reconcileWatch() -> Bool
}

/// #4117: what one capture was built against. `outputUID` is the device the aggregate was
/// built around, never re-read from the current default; `format` is the rate and layout
/// committed from the aggregate. A fresh reading that differs in any of the three rebuilds.
struct CallSoundCapture: Equatable, Sendable {
  /// The backend build that produced it; notices from other builds are retired.
  var build: Int
  var outputUID: String
  var format: CallSoundPipeline.InputFormat

  /// What differs in `current`, the device first; nil when nothing does.
  @available(macOS 14.2, *)
  func change(to current: CallSoundCapture) -> SystemAudioTap.RebuildReason? {
    if current.outputUID != outputUID { return .outputDevice }
    if current.format.sampleRate != format.sampleRate { return .nominalRate }
    if current.format.bufferChannels != format.bufferChannels { return .layout }
    return nil
  }
}

/// #4117: one Core Audio notification, as it was registered: the backend build it belongs to
/// (0 for the system object, which outlives builds), the object, selector and scope.
struct CallSoundNotice: Equatable, Sendable {
  var build: Int
  var object: UInt32
  var selector: UInt32
  var scope: UInt32
  var name: String

  func describe() -> String {
    "build=\(build) object=\(object) selector=\(CallSoundCaptureDiagnostics.fourCC(selector)) "
      + "scope=\(CallSoundCaptureDiagnostics.fourCC(scope)) property=\(name)"
  }
}

/// #4117: the formats one capture generation reports, for the `CALL_SOUND build` line. Read on
/// the tap queue after start; never used to choose the rate in this revision.
struct CallSoundCaptureDiagnostics: Equatable, Sendable {
  struct Stream: Equatable, Sendable {
    var id: UInt32
    /// Nil when the stream's virtual format could not be read (`readStatus` says why).
    var sampleRate: Double?
    var readStatus: Int32 = 0
    var formatID: UInt32
    var formatFlags: UInt32
    var channels: UInt32
    var bitsPerChannel: UInt32
    var bytesPerFrame: UInt32
  }
  /// The backend build these were read from (counts every start).
  var build = 0
  var tapRate: Double?
  var aggregateNominalRate: Double?
  /// The aggregate's input streams and their virtual formats, in the device's order; nil when
  /// the list could not be read.
  var inputStreams: [Stream]?
  /// Diagnostic listeners that failed to register, and reads that failed, so a missing
  /// notification is never mistaken for one Core Audio did not send. One entry per distinct
  /// problem, with how often it happened and whether it still holds.
  var watchProblems: [WatchProblem] = []

  struct WatchProblem: Equatable, Sendable {
    var text: String
    var count: Int
    var current: Bool
  }

  func describe() -> String {
    let tap = tapRate.map { CallSoundPipeline.rateText($0) } ?? "unreadable"
    let nominal = aggregateNominalRate.map { CallSoundPipeline.rateText($0) } ?? "unreadable"
    let streams =
      inputStreams.map { list in
        "["
          + list.map { s in
            let rate =
              s.sampleRate.map { CallSoundPipeline.rateText($0) + "Hz" }
              ?? "unreadable(\(s.readStatus))"
            return "\(s.id):\(rate)/\(s.channels)ch/\(Self.fourCC(s.formatID))"
              + "/flags=\(s.formatFlags)/bits=\(s.bitsPerChannel)/bpf=\(s.bytesPerFrame)"
          }.joined(separator: ",") + "]"
      } ?? "unreadable"
    let watch =
      watchProblems.isEmpty
      ? "ok"
      : "["
        + watchProblems.map { "\($0.text) x\($0.count) \($0.current ? "current" : "resolved")" }
        .joined(separator: "; ") + "]"
    return "build=\(build) tapRate=\(tap) aggregateNominalRate=\(nominal) inputStreams=\(streams) "
      + "watch=\(watch)"
  }

  /// Whether the buffers `ingest` read have the input streams' layout (count and channels in
  /// order, every format readable). A matching layout is evidence, not proof that the tap's
  /// audio is what those streams carry; anything else is unresolved.
  func mapping(to layout: CallSoundPipeline.BufferLayout) -> String {
    guard let streams = inputStreams else { return "unresolved(streams-unreadable)" }
    guard !streams.isEmpty else { return "unresolved(no-input-streams)" }
    guard streams.count == layout.buffers else {
      return "unresolved(streams=\(streams.count) buffers=\(layout.buffers))"
    }
    if let unreadable = streams.first(where: { $0.sampleRate == nil }) {
      return "unresolved(format-unreadable \(unreadable.id))"
    }
    guard streams.count <= 8, streams.map(\.channels) == layout.channels else {
      return "unresolved(channels-differ)"
    }
    let rates = Set(streams.compactMap(\.sampleRate))
    return rates.count == 1
      ? "layoutMatches(rate=\(CallSoundPipeline.rateText(rates.first!)))"
      : "layoutMatches(mixed-rates)"
  }

  static func fourCC(_ value: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
    guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return String(value) }
    return String(decoding: bytes, as: UTF8.self)
  }
}

@available(macOS 14.2, *)
final class CoreAudioCallSoundBackend: CallSoundBackend {
  typealias ListenerCall = (
    AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>, DispatchQueue?,
    @escaping AudioObjectPropertyListenerBlock
  ) -> OSStatus

  private let addListener: ListenerCall
  private let removeListener: ListenerCall
  private let streamLister: (AudioObjectID) -> [AudioObjectID]?

  /// The listener calls and the stream lister are parameters only so a test can make one fail
  /// or change.
  init(
    addListener: @escaping ListenerCall = AudioObjectAddPropertyListenerBlock,
    removeListener: @escaping ListenerCall = AudioObjectRemovePropertyListenerBlock,
    streamLister: @escaping (AudioObjectID) -> [AudioObjectID]? = CoreAudioCallSoundBackend
      .inputStreams(of:),
    tapRateReader: @escaping (AudioObjectID) -> Double? = { tap in
      try? CoreAudioCallSoundBackend.readTapFormat(tap).mSampleRate
    },
    nominalRateReader: @escaping (AudioObjectID) -> Double? = CoreAudioCallSoundBackend
      .nominalRate(of:),
    streamFormatReader: @escaping (AudioObjectID) -> (OSStatus, AudioStreamBasicDescription) =
      CoreAudioCallSoundBackend.virtualFormat(of:)
  ) {
    self.addListener = addListener
    self.removeListener = removeListener
    self.streamLister = streamLister
    self.tapRateReader = tapRateReader
    self.nominalRateReader = nominalRateReader
    self.streamFormatReader = streamFormatReader
  }

  /// Records a problem once, counting repeats; it holds until `resolve`.
  private func noteProblem(_ text: String) {
    if let index = watchProblems.firstIndex(where: { $0.text == text }) {
      watchProblems[index].count += 1
      watchProblems[index].current = true
    } else {
      watchProblems.append(.init(text: text, count: 1, current: true))
    }
  }

  private func resolveProblem(_ text: String) {
    if let index = watchProblems.firstIndex(where: { $0.text == text }) {
      watchProblems[index].current = false
    }
  }

  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var ioProcID: AudioDeviceIOProcID?
  private var deviceStarted = false
  private var listeners:
    [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
  private var listenerQueue: DispatchQueue?
  private var onNotice: (@Sendable (CallSoundNotice) -> Void)?
  /// #4117: counts starts; notices and diagnostics carry it.
  private var build = 0
  private var watchProblems: [CallSoundCaptureDiagnostics.WatchProblem] = []
  /// Reads the tap's format now; a parameter only so a test can change it.
  private let tapRateReader: (AudioObjectID) -> Double?
  /// #4117 R3: the aggregate's nominal rate and each input stream's virtual format; parameters
  /// only so a test can stage what the hardware reported.
  private let nominalRateReader: (AudioObjectID) -> Double?
  private let streamFormatReader: (AudioObjectID) -> (OSStatus, AudioStreamBasicDescription)
  /// The aggregate's input streams this generation watches, so their listeners go before the
  /// aggregate is destroyed.
  private var watchedStreams: [AudioObjectID] = []

  func start(
    ingest: @escaping @Sendable (UnsafePointer<AudioBufferList>, UInt64, Bool) -> Void
  ) throws -> CallSoundCapture {
    guard tapID == kAudioObjectUnknown, aggregateID == kAudioObjectUnknown else {
      throw SystemAudioTap.TapError.alreadyStarted
    }
    do {
      let ownProcess = try Self.processObject(for: getpid())
      let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
      description.uuid = UUID()
      description.name = "EnviousMeet call sound"
      description.isPrivate = true
      description.muteBehavior = .unmuted
      try Self.check(AudioHardwareCreateProcessTap(description, &tapID), "create_process_tap")

      let format = try Self.readTapFormat(tapID)
      build += 1
      watchProblems = []
      guard format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate > 0,
        format.mChannelsPerFrame > 0, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
        format.mBitsPerChannel == 32
      else { throw SystemAudioTap.TapError.unusableFormat }

      let outputUID = try Self.deviceUID(try Self.defaultOutputDevice())
      let aggregate: [String: Any] = [
        kAudioAggregateDeviceNameKey: "EnviousMeet capture",
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceMainSubDeviceKey: outputUID,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceTapListKey: [
          [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
        ],
      ]
      try Self.check(
        AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
        "create_aggregate")
      let block: AudioDeviceIOBlock = { _, input, inputTime, _, _ in
        // #4117: the fallback clock keeps the existing stamping, but is reported as such so it
        // never counts as an acquisition time.
        let valid = inputTime.pointee.mFlags.contains(.hostTimeValid)
        let host = valid ? inputTime.pointee.mHostTime : mach_absolute_time()
        ingest(input, host, valid)
      }
      try Self.check(
        AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil, block), "create_io_proc")
      try Self.check(AudioDeviceStart(aggregateID, ioProcID), "start_aggregate")
      deviceStarted = true
      // A rebuilt tap and aggregate are new objects: once listeners are installed, watch them
      // too, before the commitment below is read, so no change after it goes unnoticed.
      if onNotice != nil, !addBuildWatch() {
        throw SystemAudioTap.TapError.status(operation: "install_build_listeners", value: -1)
      }
      // #4117 R3: the rate comes from the aggregate's nominal rate, read now that it runs. The
      // tap format (checked above for a usable PCM layout) and the input streams' virtual
      // formats kept reading 48 kHz while AirPods in the call profile delivered 24 kHz. The
      // output identity is the one the aggregate was built around.
      return CallSoundCapture(
        build: build, outputUID: outputUID, format: try committedCaptureFormat())
    } catch {
      _ = stop()
      throw error
    }
  }

  func stop() -> Int {
    // #4117: listeners naming the tap, the aggregate or its streams go before those objects do.
    var failures = removeBuildListeners()
    if aggregateID != kAudioObjectUnknown {
      if deviceStarted {
        if AudioDeviceStop(aggregateID, ioProcID) != noErr { failures += 1 }
        deviceStarted = false
      }
      if let proc = ioProcID {
        if AudioDeviceDestroyIOProcID(aggregateID, proc) != noErr { failures += 1 }
        ioProcID = nil
      }
      if AudioHardwareDestroyAggregateDevice(aggregateID) != noErr { failures += 1 }
      aggregateID = AudioObjectID(kAudioObjectUnknown)
    }
    if tapID != kAudioObjectUnknown {
      if AudioHardwareDestroyProcessTap(tapID) != noErr { failures += 1 }
      tapID = AudioObjectID(kAudioObjectUnknown)
    }
    return failures
  }

  func installListeners(
    queue: DispatchQueue, onNotice: @escaping @Sendable (CallSoundNotice) -> Void
  ) -> Bool {
    listenerQueue = queue
    self.onNotice = onNotice
    let system = AudioObjectID(kAudioObjectSystemObject)
    // Build 0: the system object outlives every build, so its notices are never retired.
    var installed = watch(
      system, Self.address(kAudioHardwarePropertyDefaultOutputDevice), "defaultOutput",
      build: 0)
    if installed { installed = addBuildWatch() }
    if !installed {
      // Roll back every registration that succeeded, so a failed install leaves none behind.
      _ = removeListeners()
    }
    return installed
  }

  func removeListeners() -> Bool {
    var failures = 0
    for (object, address, block) in listeners {
      var address = address
      if removeListener(object, &address, listenerQueue, block) != noErr { failures += 1 }
    }
    listeners.removeAll()
    watchedStreams = []
    onNotice = nil
    return failures == 0
  }

  /// Removes every listener on this build's objects (streams, aggregate, tap), keeping the
  /// system object's. Returns how many removals failed.
  func removeBuildListeners() -> Int {
    var failures = 0
    for stream in watchedStreams { failures += removeListeners(on: stream) }
    watchedStreams = []
    if aggregateID != kAudioObjectUnknown { failures += removeListeners(on: aggregateID) }
    if tapID != kAudioObjectUnknown { failures += removeListeners(on: tapID) }
    return failures
  }

  private func removeListeners(on object: AudioObjectID) -> Int {
    var failures = 0
    listeners.removeAll { entry in
      guard entry.0 == object else { return false }
      var address = entry.1
      if removeListener(object, &address, listenerQueue, entry.2) != noErr { failures += 1 }
      return true
    }
    return failures
  }

  /// #4117: the watches on this build's objects, all required: the tap's format, the
  /// aggregate's nominal rate and input-stream list, and each input stream's virtual format
  /// (a stream can change sample representation with the same buffer layout, which the
  /// callback layout check cannot see). Removed with their objects.
  private func addBuildWatch() -> Bool {
    if tapID != kAudioObjectUnknown,
      !watch(tapID, Self.address(kAudioTapPropertyFormat), "tapFormat")
    {
      return false
    }
    guard aggregateID != kAudioObjectUnknown else { return true }
    guard
      watch(
        aggregateID, Self.address(kAudioDevicePropertyNominalSampleRate), "aggregateNominalRate",
      ),
      watch(
        aggregateID,
        Self.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput),
        "aggregateInputStreams")
    else { return false }
    return reconcileStreamWatch()
  }

  /// Watches exactly the aggregate's current input streams: drops listeners on streams that
  /// left, adds them on streams that arrived. False, with the problem recorded, when the list
  /// cannot be read or a new stream's watch cannot be registered.
  private func reconcileStreamWatch() -> Bool {
    guard onNotice != nil, aggregateID != kAudioObjectUnknown else { return true }
    guard let current = streamLister(aggregateID) else {
      noteProblem("inputStreams unreadable")
      return false
    }
    resolveProblem("inputStreams unreadable")
    for gone in watchedStreams where !current.contains(gone) {
      if removeListeners(on: gone) > 0 { noteProblem("unwatch stream \(gone) failed") }
    }
    watchedStreams.removeAll { !current.contains($0) }
    var complete = true
    for stream in current where !watchedStreams.contains(stream) {
      if watch(stream, Self.address(kAudioStreamPropertyVirtualFormat), "streamVirtualFormat") {
        watchedStreams.append(stream)
      } else {
        complete = false
      }
    }
    return complete
  }

  /// One listener: reports its notice on the listener queue and nothing else; the tap decides
  /// what a notice means. `build` defaults to the current build. A watch that fails is
  /// recorded and returns false, for the caller to roll back or rebuild.
  private func watch(
    _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ name: String,
    build: Int? = nil
  ) -> Bool {
    guard let onNotice, let listenerQueue else { return false }
    let notice = CallSoundNotice(
      build: build ?? self.build, object: object, selector: address.mSelector,
      scope: address.mScope, name: name)
    let status = register(object, address, queue: listenerQueue) { onNotice(notice) }
    let problem = "register \(name) object=\(object) failed"
    if status { resolveProblem(problem) } else { noteProblem(problem) }
    return status
  }

  private func register(
    _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, queue: DispatchQueue,
    _ action: @escaping @Sendable () -> Void
  ) -> Bool {
    var address = address
    let block: AudioObjectPropertyListenerBlock = { _, _ in action() }
    guard addListener(object, &address, queue, block) == noErr else { return false }
    listeners.append((object, address, block))
    return true
  }

  /// #4117 R3: the capture configuration this generation commits to, rate and buffer layout
  /// from one snapshot: the aggregate's nominal rate, after its input streams are confirmed to
  /// be the Float32 PCM `ingest` reads. Throws rather than fall back to any other rate. Later
  /// diagnostic reads never change it.
  func committedCaptureFormat() throws -> CallSoundPipeline.InputFormat {
    let observed = captureDiagnostics()
    return try Self.captureFormat(
      nominalRate: observed.aggregateNominalRate, inputStreams: observed.inputStreams)
  }

  /// The single rule behind `committedCaptureFormat`, pure so every disposition is testable.
  static func captureFormat(
    nominalRate: Double?, inputStreams: [CallSoundCaptureDiagnostics.Stream]?
  ) throws -> CallSoundPipeline.InputFormat {
    guard let rate = nominalRate, rate.isFinite, rate > 0 else {
      throw SystemAudioTap.TapError.status(operation: "read_nominal_rate", value: -1)
    }
    guard let streams = inputStreams, !streams.isEmpty else {
      throw SystemAudioTap.TapError.unusableFormat
    }
    // What `ingest` reads: native-endian 32-bit Float samples, packed with no padding;
    // interleaved streams arrive as one buffer of all channels, non-interleaved ones as one
    // single-channel buffer per channel. Several streams are mixed, as before (#4117 ruling:
    // stream selection is a separate question).
    var bufferChannels: [UInt32] = []
    for stream in streams {
      let flags = stream.formatFlags
      let nonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
      let bytesPerFrame = nonInterleaved ? UInt32(4) : 4 * stream.channels
      guard stream.sampleRate != nil, stream.formatID == kAudioFormatLinearPCM,
        flags & kAudioFormatFlagIsFloat != 0, flags & kAudioFormatFlagIsBigEndian == 0,
        stream.bitsPerChannel == 32, stream.channels > 0, stream.bytesPerFrame == bytesPerFrame
      else { throw SystemAudioTap.TapError.unusableFormat }
      bufferChannels +=
        nonInterleaved
        ? Array(repeating: 1, count: Int(stream.channels)) : [stream.channels]
    }
    return CallSoundPipeline.InputFormat(sampleRate: rate, bufferChannels: bufferChannels)
  }

  func reconcileWatch() -> Bool { reconcileStreamWatch() }

  func currentCapture() throws -> CallSoundCapture {
    let outputUID = try Self.deviceUID(try Self.defaultOutputDevice())
    return CallSoundCapture(
      build: build, outputUID: outputUID, format: try committedCaptureFormat())
  }

  func captureDiagnostics() -> CallSoundCaptureDiagnostics {
    // The tap's format is read now, never the start-time value (#4117: a refresh after a
    // tap-format notice must show the new one). The converter keeps its configured rate.
    let tapRate = tapID == kAudioObjectUnknown ? nil : tapRateReader(tapID)
    var result = CallSoundCaptureDiagnostics(
      build: build, tapRate: tapRate, watchProblems: watchProblems)
    guard aggregateID != kAudioObjectUnknown else { return result }
    result.aggregateNominalRate = nominalRateReader(aggregateID)
    result.inputStreams = streamLister(aggregateID).map { ids in
      ids.map { id in
        let (status, format) = streamFormatReader(id)
        return .init(
          id: id, sampleRate: status == noErr ? format.mSampleRate : nil, readStatus: status,
          formatID: format.mFormatID, formatFlags: format.mFormatFlags,
          channels: format.mChannelsPerFrame, bitsPerChannel: format.mBitsPerChannel,
          bytesPerFrame: format.mBytesPerFrame)
      }
    }
    return result
  }

  #if DEBUG
    /// Pretends an aggregate exists, so its listeners can be driven without one.
    func setAggregateObjectForTesting(_ id: AudioObjectID) { aggregateID = id }
  #endif

  static func nominalRate(of device: AudioObjectID) -> Double? {
    var nominal = Float64(0)
    var size = UInt32(MemoryLayout<Float64>.size)
    var property = address(kAudioDevicePropertyNominalSampleRate)
    guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &nominal) == noErr else {
      return nil
    }
    return nominal
  }

  static func virtualFormat(of stream: AudioObjectID) -> (OSStatus, AudioStreamBasicDescription) {
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var property = address(kAudioStreamPropertyVirtualFormat)
    let status = AudioObjectGetPropertyData(stream, &property, 0, nil, &size, &format)
    return (status, format)
  }

  /// The device's input streams, in its order; nil when the list cannot be read.
  static func inputStreams(of device: AudioObjectID) -> [AudioObjectID]? {
    var property = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr else {
      return nil
    }
    var ids = [AudioObjectID](
      repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard !ids.isEmpty else { return [] }
    guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &ids) == noErr else {
      return nil
    }
    return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
  }

  #if DEBUG
    /// Pretends a tap object exists, so listener installation can be driven without one.
    func setTapObjectForTesting(_ id: AudioObjectID) { tapID = id }
    var listenerCountForTesting: Int { listeners.count }
  #endif

  // MARK: - Core Audio helpers

  private static func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
      throw SystemAudioTap.TapError.status(operation: operation, value: status)
    }
  }

  private static func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  private static func processObject(for processID: pid_t) throws -> AudioObjectID {
    var pid = processID
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var property = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    let status = withUnsafePointer(to: &pid) { pointer in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &property, UInt32(MemoryLayout<pid_t>.size),
        pointer, &size, &object)
    }
    try check(status, "translate_own_pid")
    guard object != kAudioObjectUnknown else {
      throw SystemAudioTap.TapError.status(operation: "translate_own_pid", value: -1)
    }
    return object
  }

  private static func defaultOutputDevice() throws -> AudioObjectID {
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var property = address(kAudioHardwarePropertyDefaultOutputDevice)
    try check(
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &object),
      "read_default_output")
    guard object != kAudioObjectUnknown else {
      throw SystemAudioTap.TapError.status(operation: "read_default_output", value: -1)
    }
    return object
  }

  private static func deviceUID(_ device: AudioObjectID) throws -> String {
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var property = address(kAudioDevicePropertyDeviceUID)
    try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, &uid), "read_output_uid")
    guard let value = uid?.takeRetainedValue() else {
      throw SystemAudioTap.TapError.status(operation: "read_output_uid", value: -1)
    }
    return value as String
  }

  static func readTapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
    var result = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var property = address(kAudioTapPropertyFormat)
    try check(AudioObjectGetPropertyData(tap, &property, 0, nil, &size, &result), "read_tap_format")
    return result
  }
}
