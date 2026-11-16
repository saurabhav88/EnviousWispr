@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import EnviousWisprCore
import os

/// Cross-thread set-once latch for "did any buffer reach the delegate this
/// session." Mirrors the former capture-session source's `CaptureLivenessFlag` (a
/// private type per file, so not shared directly).
private final class HALCaptureLivenessFlag: Sendable {
  private let _lock = OSAllocatedUnfairLock(initialState: false)
  func markReceived() { _lock.withLock { $0 = true } }
  func wasReceived() -> Bool { _lock.withLock { $0 } }
  func reset() { _lock.withLock { $0 = false } }
}

/// Cross-thread stop latch the RT render callback checks before touching
/// anything else. Set from teardown paths; the callback bails immediately.
private final class HALStoppedFlag: Sendable {
  private let _lock = OSAllocatedUnfairLock(initialState: false)
  func set() { _lock.withLock { $0 = true } }
  func isSet() -> Bool { _lock.withLock { $0 } }
}

/// Fixed-capacity SPSC ring of pre-allocated raw sample chunks. The AUHAL
/// render callback (the real HAL IO thread — a harder real-time context than
/// the tap/delegate queues the other two conformers run on) pushes without
/// allocating; a queue we own drains and hands chunks to `PreRollForwarder`
/// off the IO thread. The locked region is a fixed-size memcpy only, matching
/// `keep-preroll-lock-minimal`. A lagging consumer drops the newest chunk
/// (ring full) rather than blocking the IO thread — matches the RT contract:
/// no allocation, no blocking, ever.
private final class HALSampleRing: @unchecked Sendable {
  private struct Slot {
    let storage: UnsafeMutablePointer<Float>
    var count: Int = 0
    var level: Float = 0
  }

  private var slots: [Slot]
  private let capacityPerSlot: Int
  private var writeIdx = 0
  private var readIdx = 0
  private var occupied = 0
  private let lock = OSAllocatedUnfairLock(initialState: ())

  init(slotCount: Int, capacityPerSlot: Int) {
    self.capacityPerSlot = capacityPerSlot
    self.slots = (0..<slotCount).map { _ in
      Slot(storage: .allocate(capacity: capacityPerSlot))
    }
  }

  deinit {
    for slot in slots { slot.storage.deallocate() }
  }

  /// RT-safe push. Called from the HAL IO thread inside the render callback.
  /// Returns false (dropped chunk) if the ring is full — never blocks.
  ///
  /// `withLockUnchecked` (not `withLock`) because the body captures
  /// `UnsafePointer<Float>`, which is not `Sendable`; safety here comes from
  /// the lock itself serializing the one RT producer against the one
  /// non-RT consumer, not from the compiler's Sendable check.
  @discardableResult
  func push(_ data: UnsafePointer<Float>, count: Int, level: Float) -> Bool {
    let n = min(count, capacityPerSlot)
    guard n > 0 else { return false }
    return lock.withLockUnchecked { _ in
      guard occupied < slots.count else { return false }
      slots[writeIdx].storage.update(from: data, count: n)
      slots[writeIdx].count = n
      slots[writeIdx].level = level
      writeIdx = (writeIdx + 1) % slots.count
      occupied += 1
      return true
    }
  }

  /// Non-RT drain of one chunk into a caller-owned, reused scratch buffer
  /// (must be at least `capacityPerSlot` long). The lock's critical section
  /// is a bounded memcpy only — same shape as `push()`'s. Building the final
  /// `[Float]`/`AVAudioPCMBuffer` the caller actually needs happens AFTER
  /// unlocking, in the caller. This lock is shared with the RT `push()`
  /// side, so any allocation done while holding it could block the render
  /// callback behind the consumer (Codex review r2 P2) — moving the
  /// allocation out is what closes that.
  func pop(into destination: inout [Float]) -> (count: Int, level: Float)? {
    lock.withLockUnchecked { _ -> (count: Int, level: Float)? in
      guard occupied > 0 else { return nil }
      let slot = slots[readIdx]
      destination.withUnsafeMutableBufferPointer { dst in
        dst.baseAddress!.update(from: slot.storage, count: slot.count)
      }
      readIdx = (readIdx + 1) % slots.count
      occupied -= 1
      return (slot.count, slot.level)
    }
  }
}

/// Per-session capture-health counters (#1434). Incremented from the RT render
/// callback (ring drops) and the consumer thread (converter errors / zero
/// output); read + reset from the MainActor source. A single unfair lock keeps
/// every touch a bounded few-instruction critical section — the same cost
/// class as `HALSampleRing`'s lock, which the RT contract already accepts.
private final class HALSessionCounters: Sendable {
  struct Snapshot {
    var ringDrops = 0
    var converterErrors = 0
    var zeroOutputs = 0
    var renderFailures = 0
    var oversizedSlices = 0
    var lostChunks = 0
  }
  private let state = OSAllocatedUnfairLock(initialState: Snapshot())
  func incrementRingDrop() { state.withLock { $0.ringDrops += 1 } }
  func incrementConverterError() { state.withLock { $0.converterErrors += 1 } }
  func incrementZeroOutput() { state.withLock { $0.zeroOutputs += 1 } }
  func incrementRenderFailure() { state.withLock { $0.renderFailures += 1 } }
  func incrementOversizedSlice() { state.withLock { $0.oversizedSlices += 1 } }
  /// A popped chunk that left `drainAndForward` without reaching `route` and
  /// without being a benign priming call. Deliberately a CATCH-ALL rather than one
  /// counter per cause: #1788 r3/r5/r7 each found another silent exit, so the
  /// bookkeeping is now at the single place a chunk can die instead of at each
  /// reason it might.
  func incrementLostChunk() { state.withLock { $0.lostChunks += 1 } }
  func snapshot() -> Snapshot { state.withLock { $0 } }
  /// Read and clear under ONE lock acquisition. A separate `snapshot()` then
  /// `reset()` leaves a window in which the RT and consumer threads can increment
  /// a counter that neither the returned snapshot nor the cleared state contains,
  /// so the gap is erased from both — the wake would then be labelled `exact`
  /// over a lossy stream (#1788 cloud review r5).
  func snapshotAndReset() -> Snapshot {
    state.withLock { current in
      let taken = current
      current = Snapshot()
      return taken
    }
  }
}

/// The RT-callback-reachable context, passed by raw pointer via `Unmanaged`
/// (an `AURenderCallback` is `@convention(c)` and cannot capture Swift state).
/// Holds only what the render callback and its off-IO-thread consumer need;
/// deliberately NOT `@MainActor` so neither hop requires actor isolation.
private final class HALRenderContext: @unchecked Sendable {
  let audioUnit: AudioUnit
  let scratch: UnsafeMutableAudioBufferListPointer
  /// Frame capacity `scratch` was allocated for. The render callback clamps
  /// every read to this (never to the hardware-reported `inNumberFrames`
  /// alone) — see the RT-safety comment on `halRenderProc` (Codex review r1
  /// P1: a larger-than-configured slice must never read past the allocation).
  let capacityFrames: Int
  let ring: HALSampleRing
  let stopped: HALStoppedFlag
  let liveness: HALCaptureLivenessFlag
  let forwarder: PreRollForwarder
  /// The device's OWN native rate (mono Float32 non-interleaved) — what the
  /// client format was set to, and what `ring` samples actually are. AUHAL
  /// input does NOT resample (Apple QA1777: "does not provide sample rate
  /// conversion" for input on macOS) — cloud review P2 caught the prior
  /// version assuming a silent 16kHz resample that only happened to work
  /// because the Bose's Bluetooth profile is already 16kHz natively.
  let nativeFormat: AVAudioFormat
  let targetFormat: AVAudioFormat
  /// Resamples `nativeFormat` → `targetFormat` on the consumer thread.
  let converter: AVAudioConverter
  /// #1434 capture-health counters — RT + consumer threads increment, the
  /// MainActor source snapshots at stop and resets per session.
  let counters = HALSessionCounters()
  /// Signaled once per rendered chunk; the dedicated consumer thread blocks
  /// on this instead of the render callback dispatching work (Codex review r1
  /// P2: `DispatchQueue.async` from the HAL IO thread can allocate/lock —
  /// signaling a semaphore is the RT-safe wake primitive).
  let semaphore = DispatchSemaphore(value: 0)
  #if DEBUG
    /// (#1540) DEBUG-only best-effort tripwire for the teardown lifetime
    /// assumption — NOT a formal proof. The render callback increments this on
    /// entry and `defer`-decrements on every exit; `HALUnitResources.retire()` reads it
    /// after AudioOutputUnitStop/Uninitialize/Dispose and before freeing
    /// `scratch`. A NONZERO reading is always a real fault (a callback was
    /// genuinely still running at free time = a use-after-free window) — there
    /// are no false positives. A zero reading is strong but not conclusive: a
    /// callback paused between resolving `inRefCon` and the increment below is
    /// briefly invisible (Codex r1 P2). Combined with the burn-in stress it is
    /// enough signal to catch the assumption breaking without a sanitizer; zero
    /// release cost (compiled out).
    let inFlightRenderCallbacks = OSAllocatedUnfairLock(initialState: 0)
    /// Set if a callback observed `stopped` already set on entry. Informational
    /// only — a callback that bails at the stop guard before touching `scratch`
    /// is SAFE by design; only a nonzero in-flight count at free time is a UAF.
    let callbackEnteredAfterStop = OSAllocatedUnfairLock(initialState: false)
  #endif
  #if DEBUG
    /// Test seam: runs on the consumer right before a chunk is routed. Set before any drain runs.
    nonisolated(unsafe) var debugBeforeRoute: (@Sendable () -> Void)?
  #endif
  /// Reused destination for `ring.pop(into:)` — sized once to `capacityFrames`
  /// so the drain's bounded memcpy (shared lock with the RT `push()` side)
  /// never allocates; the per-chunk `[Float]`/`AVAudioPCMBuffer` `forward()`
  /// needs is built AFTER that copy returns, outside the lock.
  private var popScratch: [Float]

  init(
    audioUnit: AudioUnit,
    scratch: UnsafeMutableAudioBufferListPointer,
    capacityFrames: Int,
    ring: HALSampleRing,
    stopped: HALStoppedFlag,
    liveness: HALCaptureLivenessFlag,
    forwarder: PreRollForwarder,
    nativeFormat: AVAudioFormat,
    targetFormat: AVAudioFormat,
    converter: AVAudioConverter
  ) {
    self.audioUnit = audioUnit
    self.scratch = scratch
    self.capacityFrames = capacityFrames
    self.ring = ring
    self.stopped = stopped
    self.liveness = liveness
    self.forwarder = forwarder
    self.nativeFormat = nativeFormat
    self.targetFormat = targetFormat
    self.converter = converter
    self.popScratch = [Float](repeating: 0, count: capacityFrames)
  }

  /// Drain everything currently in the ring and forward through
  /// `PreRollForwarder`, reconstructing an `AVAudioPCMBuffer` per chunk (a
  /// per-chunk allocation that here runs one hop off the true HAL IO thread
  /// instead of on it, since this function is called from the dedicated
  /// consumer thread,
  /// never directly from the render callback).
  func drainAndForward() {
    // #4601 §3.4: once the unit is handed off for retirement (stopped flag set on the main actor),
    // nothing more is forwarded, even if the consumer still holds buffered audio.
    while !stopped.isSet(), let (count, _) = ring.pop(into: &popScratch) {
      guard
        let nativeBuffer = AVAudioPCMBuffer(
          pcmFormat: nativeFormat, frameCapacity: AVAudioFrameCount(count))
      else {
        // A popped chunk that cannot be wrapped is lost audio (#1788 r7). Every
        // exit from this loop that is not `.routed` or `.benignZeroOutput` must
        // count, or the gap enumeration silently reopens.
        counters.incrementLostChunk()
        continue
      }
      nativeBuffer.frameLength = AVAudioFrameCount(count)
      if let channelData = nativeBuffer.floatChannelData {
        popScratch.withUnsafeBufferPointer { src in
          channelData[0].update(from: src.baseAddress!, count: count)
        }
      }
      // Liveness marks only once `forward` has actually converted AND routed
      // a buffer downstream — never on mere receipt of a native-rate chunk
      // (cloud review P2). Marking on receipt would let a converter that
      // silently fails on every call (e.g. an unexpected format edge case)
      // permanently defeat the "no audio detected" stall watchdog.
      // `markReceived()` is an idempotent latch, so marking on every routed
      // buffer is correct and cheap (one uncontended lock on this consumer
      // thread). `liveness` is the SINGLE authority — a former separate
      // `bufferSeenThisSession` dedup flag created a check-then-set race where a
      // session reset landing between the mark and the flag-set left the flag
      // true while liveness was reset false, falsely tripping the watchdog
      // (#1540, Codex r1 P2). Deleting the flag closes that race.
      switch forward(nativeBuffer: nativeBuffer) {
      case .routed:
        liveness.markReceived()
      case .benignZeroOutput:
        break  // priming: input is buffered and emitted next call, nothing lost
      case .lost:
        counters.incrementLostChunk()
      }
    }
  }

  /// What became of one popped chunk. A three-way result rather than `Bool`
  /// BECAUSE the enumeration kept reopening (#1788 r3, r5, r7 each found another
  /// silent `return false`): a bool lets a new early exit mean "not routed" without
  /// the author deciding whether audio was LOST, and the caller then cannot tell.
  /// Every exit from `forward` must now pick a case, and only `.benignZeroOutput`
  /// is loss-free.
  private enum ForwardOutcome {
    /// Converted samples reached `forwarder.route` — the only success.
    case routed
    /// Converter consumed the input and emitted no frames yet. Priming does this
    /// once; the input is buffered internally and emitted on the following call,
    /// so the output timeline stays continuous and nothing is lost.
    case benignZeroOutput
    /// The chunk is gone. Counts toward `inputTimelineGapCount`.
    case lost
  }

  /// Resample `nativeBuffer` (the device's real rate) to `targetFormat`
  /// (16kHz mono, what the pipeline expects) and forward the converted
  /// samples — never the raw native-rate ones (cloud review P2).
  private func forward(nativeBuffer: AVAudioPCMBuffer) -> ForwardOutcome {
    let ratio = targetFormat.sampleRate / nativeFormat.sampleRate
    let outputFrameCount = AVAudioFrameCount(Double(nativeBuffer.frameLength) * ratio) + 1
    guard outputFrameCount > 0,
      let convertedBuffer = AVAudioPCMBuffer(
        pcmFormat: targetFormat, frameCapacity: outputFrameCount)
    else {
      // Output-buffer allocation failed (memory pressure) — the chunk dies here,
      // and until #1788 r7 nothing recorded it.
      return .lost
    }

    var error: NSError?
    nonisolated(unsafe) var inputConsumed = false
    converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
      if inputConsumed {
        outStatus.pointee = .noDataNow
        return nil
      }
      inputConsumed = true
      outStatus.pointee = .haveData
      return nativeBuffer
    }
    // One-buffer-then-.noDataNow is the documented pull-style streaming idiom
    // (AVAudioConverter docs), and dropping a zero-frame output is REQUIRED —
    // forwarding an empty buffer duplicates a timestamp downstream. Both
    // branches are counted (#1434) so a converter that fails repeatedly is
    // fleet-visible instead of silent: priming legitimately yields one
    // zero-frame output; more than ~1 per session is a signal.
    if error != nil {
      counters.incrementConverterError()
      return .lost
    }
    guard convertedBuffer.frameLength > 0 else {
      counters.incrementZeroOutput()
      return .benignZeroOutput
    }

    let level = AudioBufferProcessor.calculateRMS(convertedBuffer)
    guard let channelData = convertedBuffer.floatChannelData else {
      // Converted frames exist but are unreadable — the chunk is lost exactly
      // like a converter error, so it counts as one rather than vanishing.
      counters.incrementConverterError()
      return .lost
    }
    let frameCount = Int(convertedBuffer.frameLength)
    let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
    #if DEBUG
      debugBeforeRoute?()
    #endif
    forwarder.route(samples: samples, level: level, buffer: convertedBuffer)
    return .routed
  }

}

/// AUHAL (`kAudioUnitSubType_HALOutput`) input-only audio capture source —
/// #1377 candidate D, reinstated 2026-07-08 to spike against candidate A
/// (the retired capture-session source) on real Bluetooth hardware. Opens ANY device
/// directly by `AudioDeviceID` (built-in, wired, or Bluetooth) via
/// `kAudioOutputUnitProperty_CurrentDevice`, without a capture session or
/// aggregate-device layer.
///
/// Format conversion is done EXPLICITLY, not by AUHAL: AUHAL input does NOT
/// resample (Apple QA1777 — "does not provide sample rate conversion" for
/// input on macOS), so the client format is set to the hardware's own native
/// rate (mono Float32), and an `AVAudioConverter` resamples to the pipeline's
/// 16kHz on the consumer thread.
///
/// RT-safety: the render callback (`halRenderProc`, true HAL IO thread) does
/// `AudioUnitRender` into a preallocated scratch buffer (every read clamped to
/// its actual capacity, never trusting `inNumberFrames` alone), then a
/// fixed-size memcpy into `HALSampleRing` (locked, bounded, no allocation) —
/// see `keep-preroll-lock-minimal`. It wakes a dedicated consumer thread via
/// `DispatchSemaphore.signal()` (RT-safe; `DispatchQueue.async` is NOT — it
/// can allocate/lock on the calling thread). The heavier work (building an
/// `AVAudioPCMBuffer`, calling `PreRollForwarder.route()`) happens on that
/// consumer thread, one hop off the IO thread, mirroring where the other two
/// conformers already do that same per-chunk allocation (their tap/delegate
/// callbacks, which are themselves not the literal IO thread).
@MainActor
final class HALDeviceInputSource: AudioInputSource {

  // MARK: - AudioInputSource callbacks

  var onSamples: (@Sendable (_ samples: [Float], _ audioLevel: Float) -> Void)?
  var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
  var onInterrupted: ((EngineInterruptionCause) -> Void)?
  var onLifecycleSignal: (@Sendable (String) -> Void)?
  var onCaptureStalled: ((CaptureStallContext) -> Void)?
  private(set) var captureGeneration: UInt64 = 0

  /// #1810: samples this session's activation drained out of the pre-roll ring.
  /// Cleared at the top of every `startCapture()` attempt that is committed to being
  /// a NEW session, so a throw between that point and the drain CANNOT leave the
  /// previous session's count visible to this one's ceiling. Protocol doc owns why
  /// this is capture policy rather than telemetry.
  private(set) var drainedPreRollSampleCount: Int = 0

  nonisolated let captureSourceType: String = "hal_device_input"

  private static let stallQueue = DispatchQueue(
    label: "com.enviouswispr.audio.capture-stall.hal"
  )
  private var stallWorkItem: DispatchWorkItem?
  /// #4601: the stall diagnostic's default input UID, read on the lane when the watchdog arms.
  private var stallDefaultInputUID: String?

  // MARK: - State

  private(set) var isCapturing = false
  var isRunning: Bool {
    #if DEBUG
      if let isRunningOverrideForTesting { return isRunningOverrideForTesting }
    #endif
    guard let audioUnit else { return false }
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioUnitGetProperty(
      audioUnit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running, &size)
    return status == noErr && running != 0
  }

  /// #4601 §3.5: the running check, asked on the audio-unit lane within `deadline` (and the read
  /// limit). A completed "not running", a timeout or a wedged lane all answer false: a unit that
  /// cannot be asked is not trusted for a take. Ordinary contention waits. A result for a unit
  /// replaced meanwhile answers false.
  func isRunningOnLane(deadline: ContinuousClock.Instant?) async -> Bool {
    #if DEBUG
      if let isRunningOverrideForTesting { return isRunningOverrideForTesting }
    #endif
    guard let resources = liveResources else { return false }
    let generation = resources.generation
    let probe = nativeCalls.isRunning
    #if DEBUG
      probeSnapshotTakenForTesting?()
    #endif
    // The owner crosses (single-owner hand-off type); the read only looks at its unit.
    // Checked ON the lane, just before the read: a retirement queued ahead of this probe has
    // already disposed the unit, so it must not be queried (§3.2).
    let outcome = await lane.run("running_probe", deadline: deadline) {
      resources.isRetired ? false : probe(resources.unit)
    }
    guard liveResources?.generation == generation, case .value(let running) = outcome else {
      return false
    }
    return running
  }

  /// Target capture device UID. Nil means follow the live system default input.
  var targetDeviceUID: String?

  /// #3972 R14: how many buffers the stream `startCapture()` returns may hold while nobody reads
  /// it. Dictation's default is unchanged (`.unbounded`, read by the kernel). An EnviousMeet
  /// recorder reads `onSamples` only and sets `.bufferingNewest(0)`, so hours of capture can
  /// never pile up in an unread stream.
  var captureStreamBufferingPolicy: AsyncStream<AVAudioPCMBuffer>.Continuation.BufferingPolicy =
    .unbounded

  /// #2664: per-device input-channel preference (device UID -> 0-based channel),
  /// copied from `AudioCaptureManager` at construction. Read ONCE, at cold
  /// `prepare()`, to choose the channel map; nothing else reads it. The
  /// warm-reuse predicate deliberately takes the MANAGER's current map as an
  /// argument instead, because this copy is stale by definition once the user
  /// changes the setting while the unit is warm.
  var inputChannelByDeviceUID: [String: Int] = [:]

  /// The single capture device-selection authority (#1714). Injected so the
  /// whole ladder — and the warm-compatibility projection below — is testable
  /// without hardware. This REPLACED two narrower seams
  /// (`resolveDeviceIDForUID`, `defaultInputDeviceIDProvider`) that let this
  /// file hold selection policy of its own.
  var inputDeviceResolver = InputDeviceResolver()

  /// Fires exactly once per COLD attempt, synchronously, before `prepare()`
  /// returns or throws. Never fires on warm reuse because a reused bind is not a
  /// new resolution. Nil changes nothing. `AudioCaptureManager` consumes this
  /// callback for lifetime ownership, then exposes a separate package projection
  /// to AppKit so `EnviousWisprAudio` never imports Services.
  var onInputResolutionAttemptFinalized: ((FinalizedInputResolutionAttempt) -> Void)?

  // MARK: - Private state

  /// #4601 §3.2: the ONE owner of the committed native unit and everything its
  /// callbacks can reach (render context, the unmanaged callback retain, scratch,
  /// the stopped flag, the consumer thread and the exact listener registrations).
  /// Set only at `prepare()`'s commit point; `teardownUnit()` takes it out and
  /// retires it. The two views below own nothing.
  private var liveResources: HALUnitResources?
  private var audioUnit: AudioUnit? { liveResources?.unit }
  private var renderContext: HALRenderContext? { liveResources?.context }
  /// Native calls retirement makes; `.live` in production. Test seam only.
  var nativeCalls = HALNativeCalls.live
  /// #4601 §3.1: where every audio-unit call of this source runs. The process-wide lane in
  /// production (dictation and meeting share its order); tests inject their own.
  var lane: AudioUnitLane = .shared
  /// #4601 §3a: the absolute deadline of the start this source is preparing for. The caller that
  /// owns the press sets it before `prepare()`; nil uses an INTERIM budget of the open limit from
  /// now (standalone callers until the press-origin chain is wired; not G2 evidence).
  var startDeadline: ContinuousClock.Instant?
  /// The cold attempt this source is waiting on, if any. Main-actor owned; cleared on every
  /// terminal path. Abort, a newer attempt and shutdown cancel it, which works before lane
  /// admission too (§5).
  private var pendingAttempt: AudioUnitLane.Attempt?
  /// The opened unit of the pending attempt, from the moment the native open produced it until
  /// exactly one party takes it: the main-actor commit, the lane's late disposal, or a quit.
  /// Cleanup never depends on the main actor resuming (§3.6).
  private var pendingHandoff: HALUnitNative.Handoff?
  /// Process-unique attempt keys: every source shares one lane, so per-source counters could
  /// collide.
  private static var nextAttemptID: UInt64 = 1
  #if DEBUG
    /// Test seam: replaces the native cold open (`HALUnitNative.open`) with injected work that
    /// still runs on the lane. Production never sets it.
    var openWorkForTesting: (@Sendable (HALUnitNative.OpenRequest) -> HALUnitNative.OpenResult)?
    /// Test seam: runs on the main actor right after the lane answers and before the attempt is
    /// revalidated, so a test can invalidate an attempt after transfer and before commit.
    var afterOpenReturnedForTesting: (@MainActor () -> Void)?
    /// Test seam: runs on the main actor after the attempt is owned and before the lane is asked,
    /// so a test can cancel an attempt before lane admission.
    var beforeOpenForTesting: (@MainActor () -> Void)?
    /// Test seam: runs after the running probe snapshots its unit and before it asks the lane.
    var probeSnapshotTakenForTesting: (@MainActor () -> Void)?
    /// Test oracle: called on the main actor for every device-vanished delivery, with whether
    /// its generation matched the committed unit.
    var listenerDeliveryObserverForTesting: (@MainActor (Bool) -> Void)?
    /// Test oracle: called when the vanish handler finishes after its liveness read, with
    /// whether it interrupted the capture.
    var vanishHandledObserverForTesting: (@MainActor (Bool) -> Void)?
    /// Test seam: delivers a device-vanished listener callback for `generation` through the real
    /// sink (main-actor hop and generation check included).
    func deliverListenerForTesting(generation: UInt64) {
      listenerSink.deviceMayHaveVanished(0, generation)
    }
    var liveGenerationForTesting: UInt64? { liveResources?.generation }
  #endif
  /// #1434: set (MainActor) when a format-change notification fired while
  /// capturing AND the re-read rate differs from the prepare-time rate.
  /// Log-and-telemetry only in v1 — never interrupts the recording. Reset
  /// per session in `startCapture()`.
  private var formatDivergenceObserved = false
  /// #1434 test seam: injectable native-rate reader (mirrors this file's other
  /// injected readers). Defaults to the real HAL property query.
  /// #4601: the device-alive read (#1408 three-valued), injectable for tests; run on the lane.
  var livenessReader: @Sendable (AudioDeviceID) -> DeviceLiveness = {
    CoreAudioDeviceLiveness.classify(deviceID: $0)
  }
  var nativeRateReader: @Sendable (AudioDeviceID) -> Double? = { deviceID in
    HALUnitNative.queryNativeStreamFormat(deviceID: deviceID)?.mSampleRate
  }
  private var forwarder: PreRollForwarder?

  #if DEBUG
    /// #1788: forward the forwarder's arrival-latched wake facts. Nil-safe — a
    /// source with no forwarder yet has measured nothing.
    var wakeDiagnostic: (firstNonZeroRoutedIndex: Int?, routedCountAtActivation: Int?) {
      forwarder?.wakeDiagnosticSnapshot() ?? (nil, nil)
    }
  #endif

  #if DEBUG
    var debugZeroFillController: DebugZeroFillController?
  #endif
  private let captureLiveness = HALCaptureLivenessFlag()
  private var isRecovering = false

  private var boundDeviceID: AudioDeviceID?
  private var boundUID: String?
  private var boundTransport: String?
  /// #1714: WHY this bind's device was chosen. Committed and cleared with the
  /// other three, so the four are one fact with one lifetime.
  private var boundResolutionSource: String?
  private var lastBindOK = true
  /// #1523: the bound device's total native input channel count, read once at
  /// prepare from the single channel-count authority
  /// (`AudioDeviceEnumerator.inputChannelCount`). A prepare-time constant of the
  /// bound device — not per-session health — so it survives warm-unit reuse and
  /// is cleared only in `teardownUnit()`. AUHAL down-mixes to mono by taking
  /// channel 0; this records how many channels the device actually exposed.
  private var boundNativeChannelCount: Int?
  /// #2664: the device input channel the committed unit ACTUALLY takes. 0 when
  /// no channel map was set (the default path, byte-for-byte today's behaviour)
  /// or when the map set was refused; otherwise the applied channel. Committed
  /// and cleared with the other bound fields, and carried on `BoundInputDevice`
  /// so the warm-reuse predicate can compare it to the current preference.
  private var boundInputChannel: Int?

  var actualBoundTransport: String? { boundTransport }

  #if DEBUG
    /// #2664 test seam: when non-nil, `isRunning` reports this instead of asking
    /// the real unit, so `AudioCaptureManager.resolveSource()`'s warm-reuse
    /// branch — which is HAL-typed and gated on `existing.isRunning` — can be
    /// driven with a committed bind and no `AudioUnit`. Production never sets it.
    var isRunningOverrideForTesting: Bool?
  #endif

  /// #1844: the committed bind, or nil before `prepare()` succeeded / after
  /// teardown. All five fields are assigned together in the cold commit block
  /// and cleared together in `teardownUnit()`, so this reads one fact, not five
  /// that could drift.
  private var currentBoundInputDevice: BoundInputDevice? {
    guard let boundDeviceID, let boundResolutionSource, let boundInputChannel else { return nil }
    return BoundInputDevice(
      deviceID: boundDeviceID, deviceUID: boundUID, transportLabel: boundTransport,
      resolutionSource: boundResolutionSource, inputChannel: boundInputChannel)
  }

  /// #1844: sets or clears ALL FIVE committed bind fields together, the way the
  /// cold commit block and `teardownUnit()` each do. `nativeChannelCount` is the
  /// prepare-time constant beside them (#2664: the warm-reuse channel predicate
  /// reads it), so a test staging a multi-input bind supplies it here too.
  ///
  /// This is the ONLY bind-setting seam. A partial-bind setter used to sit
  /// beside it, moving just the numeric id; #1714 deleted it once the warm
  /// predicate started reading the whole bind, because a test could otherwise
  /// pass on a correct id with a stale UID — and the UID is exactly what the
  /// health check's identity re-check depends on. Do not reintroduce one.
  func setBoundInputDeviceForTesting(_ bound: BoundInputDevice?, nativeChannelCount: Int? = nil) {
    boundDeviceID = bound?.deviceID
    boundUID = bound?.deviceUID
    boundTransport = bound?.transportLabel
    boundResolutionSource = bound?.resolutionSource
    boundInputChannel = bound?.inputChannel
    boundNativeChannelCount = nativeChannelCount
  }

  /// #1844: the warm-reuse DECISION, split from the hardware that answers
  /// "is a unit live" so it is testable without fabricating an `AudioUnit`.
  ///
  /// Non-nil ⇒ reuse the still-live bind. nil ⇒ cold preparation must run, and
  /// the caller falls through to it in the SAME call (no recursion).
  ///
  /// Verified on real hardware 2026-07-30: this path runs on EVERY dictation, not
  /// only on a second take — `preWarm()` opens the unit cold, then the recording's
  /// own `prepare()` reuses it (bt-route.log shows one "prepared with device" from
  /// pre-warm followed by "Reusing warm HALDeviceInput source" for the take). A
  /// wrong answer here would be SILENT: capture keeps working from the live unit
  /// and only the health-check identity would be wrong. Hot path plus silent
  /// failure is why this decision is unit-frozen rather than left to review.
  private func warmReuseBind(hasLiveUnit: Bool) -> BoundInputDevice? {
    guard hasLiveUnit else { return nil }
    if let bound = currentBoundInputDevice { return bound }
    // Unreachable today: `teardownUnit()` clears `audioUnit` and every bound
    // field in ONE block, so a live unit always has a bind. If the invariant is
    // ever broken, repairing costs one engine rebuild; publishing nil as a BIND
    // would silently disable the health check for every later take, and throwing
    // would kill a recording that would have worked. Heart path is sacred, so
    // repair and let the caller prepare cold.
    teardownUnit()
    return nil
  }

  /// #1844 test seam: drives `warmReuseBind` directly, so the decision that runs
  /// on every dictation is frozen without a real `AudioUnit`. Follows this file's
  /// existing `*ForTesting()` convention.
  func warmReuseBindForTesting(hasLiveUnit: Bool) -> BoundInputDevice? {
    warmReuseBind(hasLiveUnit: hasLiveUnit)
  }

  /// #1714: the POLICY moved to `InputDeviceResolver`; this stays as the narrow
  /// predicate `AudioCaptureManager` already calls, and only supplies the
  /// committed bind. HAL must not own selection rules — that was the defect
  /// that let a private selector drift from the cold ladder.
  func boundDeviceMatchesResolvedTargetForReuse() -> Bool {
    guard let bound = currentBoundInputDevice else { return false }
    return inputDeviceResolver.isWarmBindCompatible(bound, preferredUID: targetDeviceUID)
  }

  /// #2664: does the committed unit take the channel the CURRENT preference
  /// asks for? `preference` is the manager's live map, never this source's own
  /// construction-time copy. Resolved through the same pure function cold
  /// prepare applies, against the bound device's own channel count, so a
  /// preference the device cannot honour compares equal to the channel-0 bind
  /// it produced rather than forcing a rebuild that would land on channel 0
  /// again. False with no committed bind, like the device predicate above.
  func boundInputChannelMatches(preference: [String: Int]) -> Bool {
    guard let bound = currentBoundInputDevice else { return false }
    let wanted = InputChannelPreference.effectiveChannel(
      requested: InputChannelPreference.requested(for: bound.deviceUID, in: preference),
      availableChannels: boundNativeChannelCount)
    return wanted == bound.inputChannel
  }

  /// #1523: the last live stop-metadata, cached in `teardownUnit()` right before
  /// the render context + bound-device state are cleared. The device-vanish path
  /// (`handleDeviceMayHaveVanished`) tears the unit down BEFORE the manager reads
  /// `captureStopMetadata`, so without this cache a salvaged completion would
  /// lose EVERY capture-health fact (rate, counters, channel count), not just the
  /// new field. Reset when the next capture starts so a session never serves the
  /// prior session's metadata.
  private var cachedStopMetadata: CaptureStopMetadata?

  /// Gaps carried in from the idle pre-roll window, snapshotted at the top of
  /// `startCapture` before the per-session counter reset (#1788 r4). Assigned
  /// fresh every session, so it never accumulates across takes.
  private var preRollGapCount = 0

  private func computeStopMetadataFromLiveState() -> CaptureStopMetadata? {
    guard let context = renderContext else { return nil }
    let snap = context.counters.snapshot()
    return CaptureStopMetadata(
      nativeRateHz: context.nativeFormat.sampleRate,
      ringDropCount: snap.ringDrops,
      converterErrorCount: snap.converterErrors,
      zeroOutputCount: snap.zeroOutputs,
      renderFailureCount: snap.renderFailures,
      oversizedSliceCount: snap.oversizedSlices,
      preRollGapCount: preRollGapCount,
      lostChunkCount: snap.lostChunks,
      rateDivergenceDetected: formatDivergenceObserved,
      nativeChannelCount: boundNativeChannelCount,
      inputChannel: boundInputChannel
    )
  }

  /// #1434: stop-time capture-health facts. The manager snapshots this BEFORE
  /// deactivate/teardown and attaches it to `CaptureResult.metadata` — the one
  /// transport object for both the in-process and XPC stop paths. Serves live
  /// state while the unit is up, falling back to the pre-teardown cache so the
  /// device-vanish salvage (teardown-before-read) keeps its metadata (#1523).
  var captureStopMetadata: CaptureStopMetadata? {
    computeStopMetadataFromLiveState() ?? cachedStopMetadata
  }


  // MARK: - Lifecycle

  func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
    guard !isCapturing else { throw AudioError.alreadyCapturing }
    // #1810: cleared once this call is committed to being a NEW session — after
    // the already-capturing guard, which must leave the live session's count
    // intact, and before every remaining throw, so a failed attempt cannot leave
    // the previous session's drain count visible to the next one's ceiling.
    drainedPreRollSampleCount = 0
    guard let fwd = forwarder else {
      throw AudioError.formatCreationFailed(
        source: "HALDeviceInputSource.startCapture.missing_forwarder")
    }

    // Carry the idle pre-roll's gaps forward and clear the session counters in
    // ONE atomic step, BEFORE `fwd.activate(...)` drains the pre-roll (#1788
    // cloud review r4 + r5). Three things have to be true at once here:
    //   - clearing is right for #1434, whose counters must mean "this session";
    //   - the wake measurement begins inside retained pre-roll, so a gap in
    //     there is inside its window and must survive the clear;
    //   - read-then-clear as two calls leaves a window where the RT and consumer
    //     threads (still running) increment a counter that lands in neither, so
    //     the gap is erased from both and a wake reads `exact` over a lossy
    //     stream. Hence `snapshotAndReset`, and hence doing it before activate:
    //     every increment after this line belongs to the live session.
    preRollGapCount =
      renderContext.map {
        let s = $0.counters.snapshotAndReset()
        // Mirrors `CaptureStopMetadata.inputTimelineGapCount`: one addend per death
        // point, and `converterErrors` is excluded because it is a subset of
        // `lostChunks` (r8). If that sum changes, change this with it.
        return s.ringDrops + s.renderFailures + s.oversizedSlices + s.lostChunks
      } ?? 0

    let stream = makeCaptureStream()

    // #1810: `activate` returns the count it just pushed through `onSamples`, and
    // that batch reaches `DeadAirStreamingDetector` exactly like live audio. The
    // return value used to be discarded, which is what made the shipped all-zero
    // bar 1.0s MINUS the drained pre-roll instead of the 1.0s of live capture
    // `AudioConstants.minimumTranscriptionSamples` documents. Clamped at the
    // source as well as at the consumer: an unexpected negative must never widen
    // into an EARLIER abort.
    drainedPreRollSampleCount = max(
      0,
      fwd.activate(
        onSamples: self.onSamples,
        onBuffer: self.onBufferCaptured,
        continuation: self.streamContinuation,
        logPrefix: "HALDeviceInputSource"
      )
    )

    captureGeneration &+= 1
    captureLiveness.reset()
    // #1434: per-session capture-health state. The warm unit outlives sessions
    // (deactivateCapture keeps it pre-rolling), so an idle-time format change or
    // pre-roll ring drop must not bleed into the next recording's telemetry. The
    // counter half of that clear moved ABOVE `fwd.activate` as an atomic
    // snapshot-and-reset (#1788 r5); only the format flag is cleared here.
    formatDivergenceObserved = false
    // #1523: a fresh session must never serve the previous session's cached
    // stop-metadata; the live path repopulates it via teardownUnit().
    cachedStopMetadata = nil
    armCaptureStallWatchdog()

    isCapturing = true
    #if DEBUG
      logBenchCaptureEvidence()
    #endif
    return stream
  }

  private var streamContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

  /// The stream `startCapture()` returns, built with `captureStreamBufferingPolicy`; its
  /// continuation is the one the forwarder yields captured buffers into.
  func makeCaptureStream() -> AsyncStream<AVAudioPCMBuffer> {
    AsyncStream<AVAudioPCMBuffer>(bufferingPolicy: captureStreamBufferingPolicy) {
      continuation in
      self.streamContinuation = continuation
    }
  }

  #if DEBUG
    /// Yields `buffer` into the capture stream exactly as the forwarder does (#3972 C2b).
    @discardableResult
    func yieldToCaptureStreamForTesting(_ buffer: AVAudioPCMBuffer)
      -> AsyncStream<AVAudioPCMBuffer>.Continuation.YieldResult?
    {
      streamContinuation?.yield(buffer)
    }

    func finishCaptureStreamForTesting() { streamContinuation?.finish() }
  #endif

  #if DEBUG
    /// Capture-side actual-bound-device evidence (#1377 §3.5), same shape as
    /// the other two conformers so `capture_bakeoff.py` parses it unchanged.
    private func logBenchCaptureEvidence() {
      let evidenceBoundTransport = boundTransport ?? "unknown"
      AudioCaptureManager.btRouteLog(
        "CAPTURE_EVIDENCE backend=hal_device_input boundUID=\(boundUID ?? "unknown") boundDeviceID=\(boundDeviceID.map(String.init) ?? "nil") boundTransport=\(evidenceBoundTransport) bindOK=\(lastBindOK) requestedUID=\(targetDeviceUID ?? "system_default")"
      )
    }
  #endif

  private func armCaptureStallWatchdog() {
    stallWorkItem?.cancel()
    let armedSession = captureGeneration
    stallDefaultInputUID = nil
    Task { [weak self, lane] in
      let read = await lane.run("default_input_uid") { AudioDeviceEnumerator.defaultInputDeviceUID() }
      guard let self, self.captureGeneration == armedSession, case .value(let uid) = read else {
        return
      }
      self.stallDefaultInputUID = uid
    }
    let armedAtNs = DispatchTime.now().uptimeNanoseconds
    let item = Self.makeStallWorkItem(
      armedSession: armedSession, armedAtNs: armedAtNs, source: self)
    stallWorkItem = item
    Self.stallQueue.asyncAfter(
      deadline: .now() + .milliseconds(TimingConstants.audioCaptureStallWindowMs), execute: item)
  }

  nonisolated private static func makeStallWorkItem(
    armedSession: UInt64, armedAtNs: UInt64, source: HALDeviceInputSource
  ) -> DispatchWorkItem {
    return DispatchWorkItem { [weak source] in
      Task { @MainActor [weak source] in
        source?.captureStallWatchdogFired(armedSession: armedSession, armedAtNs: armedAtNs)
      }
    }
  }

  private func captureStallWatchdogFired(armedSession: UInt64, armedAtNs: UInt64) {
    guard captureGeneration == armedSession else { return }
    guard isCapturing else { return }
    guard !captureLiveness.wasReceived() else { return }

    let ctx = CaptureStallContext(
      sessionID: armedSession,
      armedAtUptimeNs: armedAtNs,
      firedAtUptimeNs: DispatchTime.now().uptimeNanoseconds,
      route: "hal_device_input",
      sourceType: "hal_device_input",
      // #4601 §3.5: no hardware read on the main actor here. "Started" is the committed unit's
      // own fact (its open started it); the default input UID is an optional diagnostic read on
      // the lane when the watchdog was armed, nil if that read has not answered.
      engineStartedSuccessfully: liveResources?.stage == .started,
      tapInstalled: true,
      formatMismatchObserved: false,
      inputDeviceUIDPreferred: targetDeviceUID,
      inputDeviceUIDSystemDefault: stallDefaultInputUID,
      failureMode: .noBuffers,
      // #1434: the stall fires BEFORE stopCapture(), so the source stamps its
      // own live rate/divergence here — the stop-time metadata object does
      // not exist yet. (The XPC proxy's host-side watchdog leaves these nil.)
      nativeRateHz: renderContext?.nativeFormat.sampleRate,
      rateDivergenceDetected: formatDivergenceObserved,
      nativeChannelCount: boundNativeChannelCount,
      inputChannel: boundInputChannel
    )
    onCaptureStalled?(ctx)
  }

  func deactivateCapture() {
    stallWorkItem?.cancel()
    stallWorkItem = nil
    forwarder?.returnToPreRoll()
    isCapturing = false
    streamContinuation = nil
    // #1434 session stats — dev-visible mirror of the CaptureStopMetadata the
    // manager reads via `captureStopMetadata` before this call.
    if let context = renderContext {
      let snap = context.counters.snapshot()
      AudioCaptureManager.btRouteLog(
        "HAL session stats: native=\(Int(context.nativeFormat.sampleRate)) "
          + "target=\(Int(context.targetFormat.sampleRate)) "
          + "ringDrops=\(snap.ringDrops) convErrors=\(snap.converterErrors) "
          + "zeroConvOut=\(snap.zeroOutputs) renderFails=\(snap.renderFailures) "
          + "oversizedSlices=\(snap.oversizedSlices) "
          + "lostChunks=\(snap.lostChunks) preRollGaps=\(preRollGapCount) "
          + "rateDivergence=\(formatDivergenceObserved)"
      )
    }
    AudioCaptureManager.btRouteLog(
      "HALDeviceInputSource deactivated — unit stays warm, pre-roll capturing")
  }

  func stop() async -> [Float] {
    stopSynchronously()
    // Source does not own samples — manager accumulates via onSamples callback.
    return []
  }

  /// `stop()`'s whole body, which never suspends. #3972: EnviousMeet's quit path must stop its
  /// own HAL client synchronously inside `applicationWillTerminate`; this is the same teardown
  /// authority, not a second copy of it.
  func stopSynchronously() {
    abandonPendingAttempt()
    forwarder?.stop()
    forwarder = nil
    streamContinuation = nil
    // teardownUnit() cancels stallWorkItem and drops isCapturing.
    teardownUnit()
  }

  /// #4601 §3.6, quit only: the same extraction, then a wait for the native retirement of at
  /// most `deadline` (the caller's own termination deadline, never a fresh budget). A pending open
  /// is cancelled first, so it can never commit. If the deadline passes, this returns while the
  /// queued retirement keeps the callback storage alive until it runs or the process exits. Never
  /// waits on the main actor and never waits without a bound. Returns whether the microphone's
  /// native retirement finished in time (true when there was nothing to retire).
  @discardableResult
  func stopSynchronously(deadline: ContinuousClock.Instant) -> Bool {
    abandonPendingAttempt()
    forwarder?.stop()
    forwarder = nil
    streamContinuation = nil
    teardownUnit()
    // Every release this source queued (the committed unit, any abandoned open's unit, earlier
    // cleanups) is ahead of this empty lane job, so waiting for it within the deadline waits for
    // all of them, without the main actor.
    return lane.retireAndWait(deadline: deadline) {}
  }

  /// Real settling check (#1434 — replaces a stub whose comment asserted the
  /// exact claim Apple QA1777 refutes: AUHAL does NOT resample input, so a
  /// device whose rate is still renegotiating DOES need waiting out).
  ///
  /// Two jobs, one contract:
  /// 1. SETTLED — poll the device's native rate until two consecutive reads
  ///    agree AND the agreed rate is usable (`> 0`; #1445, `isUsableRate`). Two-reads-agree shape; Apple forum 770232 documents
  ///    AirPods reporting a transient wrong rate corrected by a later
  ///    notification.
  /// 2. MATCHES — the settled rate must equal the rate this unit's converter
  ///    was built at in `prepare()`. A settled-but-DIVERGENT rate returns
  ///    false, which routes into the kernel's existing one-rebuild retry seam
  ///    (`RecordingSessionKernel` stabilization site) — `prepare()` then
  ///    re-reads the fresh rate and rebuilds the converter. The kernel makes
  ///    exactly one rebuild attempt; since #1445 it re-verifies stabilization
  ///    once after that rebuild (diagnostic only — a false result does not
  ///    trigger a second rebuild), and residual failure is owned by the stall
  ///    watchdog / ASR-empty paths.
  ///
  /// No bound device / no live unit → true (nothing to stabilize; matches the
  /// manager's no-active-source short-circuit).
  func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool {
    guard let deviceID = boundDeviceID, let context = renderContext,
      let generation = liveResources?.generation
    else { return true }
    let preparedRate = context.nativeFormat.sampleRate
    let stabStart = ContinuousClock.now
    // #4601 §3.5/§3a: each read runs on the audio-unit lane, bounded by the start's own deadline,
    // this stabilization's budget and the read limit (the lane applies the last). A read that
    // times out, meets a wedged lane, or answers for a unit replaced meanwhile is an UNUSABLE
    // rate, so the existing loop ends unstable and the kernel's one rebuild follows.
    let readDeadline = min(startDeadline ?? .now + .seconds(3600), stabStart + .seconds(maxWait))
    let outcome = await Self.settleNativeRate(
      preparedRate: preparedRate,
      maxWait: maxWait,
      pollInterval: pollInterval,
      readRate: { [weak self, lane, nativeRateReader] in
        let read = await lane.run("native_rate", deadline: readDeadline) {
          nativeRateReader(deviceID)
        }
        guard self?.liveResources?.generation == generation, case .value(let rate) = read else {
          return nil
        }
        return rate
      },
      sleep: { try? await Task.sleep(for: $0) },
      remaining: { readDeadline - ContinuousClock.now }
    )
    let elapsed = Self.stabMs(ContinuousClock.now - stabStart)
    let settledLabel = outcome.settledRate.map { String(Int($0)) } ?? "unstable"
    AudioCaptureManager.btRouteLog(
      "HAL formatStab: settled=\(settledLabel) prepared=\(Int(preparedRate)) "
        + "matches=\(outcome.matchesPrepared) polls=\(outcome.polls) ms=\(elapsed)"
    )
    return outcome.matchesPrepared
  }

  /// Pure settle loop (#1434) — separated from the instance so tests can
  /// drive it with an injected reader + no-op sleep (`test-timing`: assert on
  /// the returned value, never the wall clock).
  ///
  /// SETTLED = two consecutive reads agree AND the agreed rate is usable
  /// (`> 0`). During a device transition `nativeRateReader` can report a
  /// non-nil `0.0`; two agreeing invalid reads must not read as stable
  /// (`isUsableRate`, #1473). The result is
  /// `matchesPrepared` — a settled-but-DIVERGENT rate is deliberately false
  /// (routes into the kernel's one-rebuild retry seam).
  struct RateSettleOutcome: Equatable {
    let settledRate: Double?
    let matchesPrepared: Bool
    let polls: Int
  }

  /// A read only counts toward "settled" when it is non-nil and `> 0`.
  /// Rejects zero, negatives, and NaN
  /// (`Double.nan > 0` is false).
  nonisolated static func isUsableRate(_ rate: Double?) -> Bool {
    guard let rate else { return false }
    return rate > 0
  }

  static func settleNativeRate(
    preparedRate: Double,
    maxWait: TimeInterval,
    pollInterval: TimeInterval,
    readRate: () async -> Double?,
    sleep: (Duration) async -> Void,
    remaining: () -> Duration? = { nil }
  ) async -> RateSettleOutcome {
    func outcome(_ settled: Double?, polls: Int) -> RateSettleOutcome {
      RateSettleOutcome(
        settledRate: settled,
        matchesPrepared: settled == preparedRate,
        polls: polls)
    }
    // Fast path: two reads 10ms apart agree (the common already-settled case
    // returns in ~10ms, keeping the warm PTT path cheap).
    // #4601 §3a: ONE absolute deadline for reads and sleeps. `remaining` (nil = no deadline)
    // caps every sleep, and the loop ends when it reaches zero or the task is cancelled.
    func nap(_ wanted: Duration) -> Duration? {
      guard let left = remaining() else { return wanted }
      return left > .zero ? min(wanted, left) : nil
    }
    var lastRate = await readRate()
    guard let firstNap = nap(.milliseconds(10)) else { return outcome(nil, polls: 0) }
    await sleep(firstNap)
    var currentRate = await readRate()
    if isUsableRate(currentRate), currentRate == lastRate {
      return outcome(currentRate, polls: 0)
    }
    // Bounded poll loop — polls is the budget (not wall-clock, so an injected
    // no-op sleep terminates deterministically).
    let maxPolls = max(1, Int(maxWait / max(pollInterval, 0.001)))
    var polls = 0
    while polls < maxPolls, !Task.isCancelled, let pollNap = nap(.seconds(pollInterval)) {
      lastRate = currentRate
      await sleep(pollNap)
      polls += 1
      if let left = remaining(), left <= .zero { break }
      currentRate = await readRate()
      if isUsableRate(currentRate), currentRate == lastRate {
        return outcome(currentRate, polls: polls)
      }
    }
    // Never settled within the budget — unstable (false → rebuild seam).
    return outcome(nil, polls: polls)
  }

  /// Duration → ms for the stabilization log (file-local; the manager's
  /// equivalent helper is private to it).
  nonisolated private static func stabMs(_ d: Duration) -> Int {
    let (seconds, attoseconds) = d.components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
  }

  func abortPrepare() {
    // #4601 §5: a cold attempt still on the lane is abandoned there: its caller resumes at once
    // and a late success is retired by the lane, never committed.
    abandonPendingAttempt()
    guard audioUnit != nil, !isCapturing else { return }
    teardownUnit()
  }

  /// The ONE way a pending attempt is given up (abort, a newer attempt, stop, quit). It cancels
  /// the attempt and, in the same step, queues a lane job that retires the attempt's unit if
  /// nobody took it: that job runs after the open finishes (the lane is serial), so the unit has a
  /// cleanup owner at once, even when it was already handed to a main-actor continuation that has
  /// not resumed (§3.6).
  private func abandonPendingAttempt() {
    guard let attempt = pendingAttempt else { return }
    let handoff = pendingHandoff
    pendingAttempt = nil
    pendingHandoff = nil
    attempt.cancel()
    if let handoff { lane.retire { handoff.take()?.retire() } }
  }

  func rebuild() {
    teardownUnit()
  }

  // MARK: - Private: teardown


  /// #4601: what the native listener blocks call; each closure hops to the main
  /// actor before touching this source.
  /// #4601 §3.4: each delivery carries the generation of the unit whose listener fired; the
  /// handler acts only when it matches the CURRENT committed unit, so a late callback from a
  /// retired unit can never touch a newer one.
  private var listenerSink: HALUnitNative.ListenerSink {
    .init(
      deviceMayHaveVanished: { [weak self] deviceID, generation in
        Task { @MainActor [weak self] in
          guard let self else { return }
          let current = self.liveResources?.generation == generation
          #if DEBUG
            self.listenerDeliveryObserverForTesting?(current)
          #endif
          guard current else { return }
          await self.handleDeviceMayHaveVanished(deviceID: deviceID, generation: generation)
        }
      },
      formatMayHaveChanged: { [weak self] deviceID, selector, generation in
        Task { @MainActor [weak self] in
          guard let self, self.liveResources?.generation == generation else { return }
          await self.handleDeviceFormatMayHaveChanged(
            deviceID: deviceID, selector: selector, generation: generation)
        }
      })
  }

  // MARK: - Private: disconnect handling

  /// Runs the shared `CoreAudioDeviceLiveness` check — device-vanished is
  /// backend-independent per #1377 bake-off findings. Fires `onInterrupted()`;
  /// the manager keeps holding the accumulated
  /// `capturedSamples`, and #1408 made `RecordingSessionKernel` transcribe them at
  /// the recording exit. The kernel saves the partial dictation, not the manager.
  /// Registered by `HALUnitNative.registerDeviceIsAliveListener` (#4601).


  // MARK: - Private: format-change listeners (#1434)


  /// MainActor handler for either format-change selector. Guarded on
  /// `isCapturing` (idle/warm changes are the next prepare()'s problem — the
  /// per-session reset in `startCapture()` keeps them out of telemetry).
  private func handleDeviceFormatMayHaveChanged(
    deviceID: AudioDeviceID, selector: String, generation: UInt64
  ) async {
    guard isCapturing, let context = renderContext else { return }
    let preparedRate = context.nativeFormat.sampleRate
    let session = captureGeneration
    // #4601 §3.5: the rate read runs on the lane; a timed-out or refused read is "unknown".
    let read = await lane.run("native_rate") { [nativeRateReader] in nativeRateReader(deviceID) }
    // Revalidate after the await: same unit, same capture session, still capturing.
    guard liveResources?.generation == generation, captureGeneration == session, isCapturing
    else { return }
    let currentRate: Double? = if case .value(let rate) = read { rate } else { nil }
    let diverged = currentRate != nil && currentRate != preparedRate
    AudioCaptureManager.btRouteLog(
      "HAL format change (\(selector)) mid-capture: prepared=\(Int(preparedRate)) "
        + "now=\(currentRate.map { String(Int($0)) } ?? "unknown") diverged=\(diverged)"
    )
    if diverged {
      formatDivergenceObserved = true
    }
  }

  private func handleDeviceMayHaveVanished(deviceID: AudioDeviceID, generation: UInt64) async {
    guard isCapturing, !isRecovering else { return }
    let session = captureGeneration
    // #4601 §3.5: the liveness read runs on the lane; a timed-out or refused read is
    // `.unverified` (#1408: only a verified removal earns `.deviceRemoved`).
    let read = await lane.run("device_liveness") { [livenessReader] in livenessReader(deviceID) }
    let liveness: DeviceLiveness =
      if case .value(let answer) = read { answer } else { .unverified }
    // Revalidate after the await: a stale result must never tear down a replacement unit or end
    // a newer take.
    guard liveResources?.generation == generation, captureGeneration == session, isCapturing,
      !isRecovering
    else {
      #if DEBUG
        vanishHandledObserverForTesting?(false)
      #endif
      return
    }
    guard liveness != .alive else {
      #if DEBUG
        vanishHandledObserverForTesting?(false)
      #endif
      return
    }

    // #1408: `.removed` is Core Audio confirming the device is gone, and earns
    // the "Microphone disconnected" notice. `.unverified` means the read itself
    // failed for a reason that says nothing about the device — the capture is
    // still broken, so tear down and salvage exactly the same way, but report
    // the honest cause so we never badge a mic that never left.
    let cause: EngineInterruptionCause = liveness == .removed ? .deviceRemoved : .engineLost
    AudioCaptureManager.btRouteLog(
      "HALDeviceInputSource: device \(deviceID) \(liveness == .removed ? "went away" : "liveness unverified") — interrupting (\(cause.rawValue))"
    )
    // Tear down BEFORE firing onInterrupted (teardown-then-onInterrupted
    // order). Without this, `isRunning`
    // still reports true (we never called AudioOutputUnitStop), so the
    // manager's warm-reuse check would try to resume capture on a HAL unit
    // bound to a device that no longer exists on the NEXT recording instead
    // of rebuilding fresh (cloud review P2).
    teardownUnit()
    onInterrupted?(cause)
    #if DEBUG
      vanishHandledObserverForTesting?(true)
    #endif
  }

}

// MARK: - Lifecycle port (#4601 C1)

extension HALDeviceInputSource {
  func prepare() async throws -> BoundInputDevice {
    if let warm = warmReuseBind(hasLiveUnit: audioUnit != nil) {
      onLifecycleSignal?("hal_prepare_already_running")
      return warm
    }

    // #4601 §3.2: the cold open runs in `HALUnitNative.open` with a snapshot of
    // this source's inputs and touches no source state; only this function
    // commits. #1714: the attempt is finalised exactly once on EVERY cold exit
    // (resolution failure, bind failure, a later setup failure, or success),
    // here, from the record `open` returns.
    // #4601 §5: one attempt per cold prepare; a newer one abandons the older on the lane.
    abandonPendingAttempt()
    // Owned before the first suspension, so an abort that lands before lane admission still
    // cancels it (the lane then runs no native work).
    let attempt = AudioUnitLane.Attempt(id: Self.nextAttemptID)
    Self.nextAttemptID += 1
    pendingAttempt = attempt
    let progress = HALUnitNative.Progress()
    let handoff = HALUnitNative.Handoff()
    pendingHandoff = handoff
    // #3.8: the observer is captured at admission, so the attempt reports exactly once to the
    // owner that started it.
    let finalize = onInputResolutionAttemptFinalized
    var request = HALUnitNative.OpenRequest(
      targetDeviceUID: targetDeviceUID, resolver: inputDeviceResolver,
      inputChannelByDeviceUID: inputChannelByDeviceUID, captureLiveness: captureLiveness,
      lifecycleSignal: onLifecycleSignal, nativeCalls: nativeCalls, listenerSink: listenerSink,
      progress: progress)
    #if DEBUG
      request.debugZeroFillController = debugZeroFillController
      let openWork = openWorkForTesting ?? HALUnitNative.open
    #else
      let openWork = HALUnitNative.open
    #endif
    let snapshot = request
    let deadline = startDeadline ?? (ContinuousClock.now + AudioUnitLane.openLimit)
    #if DEBUG
      beforeOpenForTesting?()
    #endif
    let outcome = await lane.open(
      "microphone_start", attempt: attempt, deadline: deadline,
      // §3.8: the facts known at the FIRST terminal decision are frozen there.
      onTerminal: { progress.freeze() },
      {
        let result = openWork(snapshot)
        if case .opened(let opened) = result { handoff.put(opened.resources) }
        return result
      },
      disposeLate: { _ in
        // The caller left first: whoever has not taken the unit yet, the lane retires it now.
        handoff.take()?.retire()
      })
    #if DEBUG
      afterOpenReturnedForTesting?()
    #endif
    // §5, one rule for every outcome: an attempt invalidated while it waited (abort, a newer
    // attempt, shutdown, task cancellation) ends as abandoned, with no notice, whatever the lane
    // answered; a unit it was handed is retired here exactly once.
    let invalidated = pendingAttempt !== attempt || attempt.isCancelled || Task.isCancelled
    if pendingAttempt === attempt {
      pendingAttempt = nil
      pendingHandoff = nil
    }
    if invalidated {
      if let unit = handoff.take() { lane.retire { unit.retire() } }
      finalize?(progress.terminal(failedStep: "HALDeviceInputSource.prepare.abandoned"))
      throw CancellationError()
    }
    let result: HALUnitNative.OpenResult
    switch outcome {
    case .value(let value):
      result = value
    case .timedOut:
      let error = AudioError.microphoneNotResponding(source: "HALDeviceInputSource.prepare.timed_out")
      finalize?(progress.terminal(failedStep: "HALDeviceInputSource.prepare.timed_out"))
      throw error
    case .wedged:
      let error = AudioError.microphoneNotResponding(
        source: "HALDeviceInputSource.prepare.lane_wedged")
      finalize?(progress.terminal(failedStep: "HALDeviceInputSource.prepare.lane_wedged"))
      throw error
    case .abandoned:
      finalize?(progress.terminal(failedStep: "HALDeviceInputSource.prepare.abandoned"))
      throw CancellationError()
    }
    switch result {
    case .failed(let failure):
      if let bindOK = failure.bindOutcome { lastBindOK = bindOK }
      finalize?(failure.attempt.finalized(resolution: failure.resolution))
      throw failure.error
    case .opened(let opened):
      // Taken from the hand-off: a quit that already took it owns its retirement.
      guard handoff.take() != nil else {
        finalize?(progress.terminal(failedStep: "HALDeviceInputSource.prepare.abandoned"))
        throw CancellationError()
      }
      lastBindOK = true
      let facts = opened.facts
      // Committed — every fallible step succeeded, so this is the one place
      // `self` state is assigned for this attempt.
      self.forwarder = opened.forwarder
      self.liveResources = opened.resources

      boundDeviceID = facts.deviceID
      boundUID = facts.deviceUID
      boundTransport = facts.transportLabel
      // #1714: the fourth committed field, taken from the same switch that chose
      // the device — so there is no defaulted or optional path by which a bind
      // could claim a source this attempt did not actually use.
      boundResolutionSource = facts.resolutionSource
      // #1523: read the device's total native channel count once at prepare from
      // the single channel-count authority. We capture mono (client format
      // channels: 1 in `HALUnitNative.open`) and AUHAL down-mixes by TAKING CHANNEL 0 — so a device
      // whose meaningful audio is on a later channel would be captured as silence.
      // This value makes a >1-channel fleet population measurable; it does NOT
      // change what we capture; the SELECTOR #1523 deferred is the channel map
      // set in `HALUnitNative.open` (#2664), built once this telemetry showed both a >1-channel
      // population and a buried-audio report.
      boundNativeChannelCount = facts.nativeChannelCount
      // #2664: the sixth committed field — what the unit actually takes, from the
      // property set's own result, so telemetry and warm reuse never read the
      // requested channel as the recorded one.
      boundInputChannel = facts.inputChannel

      // #1844: the bind this attempt established, handed straight back to the
      // caller. Built from the same four fields committed above, so there is no
      // window in which a caller could observe a device this attempt did not open.
      finalize?(opened.attempt.finalized(resolution: opened.resolution))
      return BoundInputDevice(
        deviceID: facts.deviceID, deviceUID: boundUID, transportLabel: boundTransport,
        resolutionSource: facts.resolutionSource, inputChannel: facts.inputChannel)
    }
  }

  private func teardownUnit() {
    // #1523: snapshot the live stop-metadata BEFORE any state is cleared, so the
    // device-vanish salvage (which tears the unit down before the manager reads
    // `captureStopMetadata`) still has rate/counters/channel-count. Only cache a
    // non-nil compute so a double-teardown never overwrites a good snapshot.
    if let live = computeStopMetadataFromLiveState() { cachedStopMetadata = live }
    // Single authority for "this unit is going away" — every caller (normal
    // stop, abort, rebuild, AND device-vanish) must disarm the stall
    // watchdog and drop `isCapturing`. `isCapturing` flips false here, which
    // guards a late-fired watchdog.
    // Without this, a device-vanish mid-recording left the watchdog armed
    // and `isCapturing` stuck true — a late-firing watchdog could fire
    // `onCaptureStalled` after `onInterrupted` already handled the session,
    // and a same-second retry would see `alreadyCapturing` (cloud review P2).
    stallWorkItem?.cancel()
    stallWorkItem = nil
    isCapturing = false
    // #4601 §3.2: the resource owner sets the stopped flag, removes the exact
    // listener registrations, stops, uninitializes and disposes, wakes the
    // consumer, and frees callback storage only after a safe native retirement.
    // Taken out of `self` first so no second owner survives the hand-off.
    // #4601 §3.4: close forwarding admission BEFORE handing the unit to the lane. The forwarder's
    // own synchronized stop clears its callbacks and finishes its stream, so a consumer already
    // past its stopped-flag check and about to route a chunk delivers nothing. Then the source
    // drops its reference.
    forwarder?.stop()
    forwarder = nil
    if let resources = liveResources {
      liveResources = nil
      resources.markStopping()
      // #4601 §3.4: the native retirement runs on the audio-unit lane and the main actor never
      // waits for it; it stays ordered before any later open of this or any other source.
      lane.retire { resources.retire() }
    }
    boundDeviceID = nil
    boundUID = nil
    boundTransport = nil
    boundResolutionSource = nil
    boundNativeChannelCount = nil
    boundInputChannel = nil
  }
}

/// The AUHAL render callback — runs on the real HAL IO thread. Must not
/// allocate, lock for long, or log. `inRefCon` is the `HALRenderContext`
/// passed via `Unmanaged` from `prepare()`.
private func halRenderProc(
  inRefCon: UnsafeMutableRawPointer,
  ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
  inTimeStamp: UnsafePointer<AudioTimeStamp>,
  inBusNumber: UInt32,
  inNumberFrames: UInt32,
  ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
  let context = Unmanaged<HALRenderContext>.fromOpaque(inRefCon).takeUnretainedValue()
  #if DEBUG
    // (#1540) Count this callback as in-flight for the whole invocation so
    // `HALUnitResources.retire()` can assert quiescence before freeing `scratch`. The
    // `defer` guarantees the decrement on EVERY return path below.
    context.inFlightRenderCallbacks.withLock { $0 += 1 }
    defer { context.inFlightRenderCallbacks.withLock { $0 -= 1 } }
    if context.stopped.isSet() { context.callbackEnteredAfterStop.withLock { $0 = true } }
  #endif
  guard !context.stopped.isSet() else { return noErr }

  // Clamp BEFORE calling AudioUnitRender, not just after: if
  // `kAudioUnitProperty_MaximumFramesPerSlice` was ignored or the hardware
  // supplies more than `capacityFrames`, asking AudioUnitRender to write
  // `inNumberFrames` into a buffer only `capacityFrames` long is a write-side
  // overflow the post-render `min(...)` cannot undo (Codex review r2 P2 — the
  // read-side clamp alone was insufficient). Never render more than the
  // scratch buffer actually holds; a device that oversizes its slice loses
  // the excess of that one callback rather than overflowing.
  let clampedFrames = min(inNumberFrames, UInt32(context.capacityFrames))
  if inNumberFrames > UInt32(context.capacityFrames) {
    // The clamp above is a SAFETY behaviour that discards audio, and until
    // #1788 nothing recorded it (cloud review r3 named the class: every gap
    // between the microphone and the sample counter must be countable, or a
    // sample index silently stops being an elapsed time).
    context.counters.incrementOversizedSlice()
  }
  let byteCapacity = Int(clampedFrames) * MemoryLayout<Float>.size
  // Reset every render — `AudioUnitRender` can shrink `mDataByteSize` to the
  // actual bytes written, so a stale smaller value from a prior callback
  // would otherwise silently persist (Codex review r1 P1 context).
  context.scratch[0].mDataByteSize = UInt32(byteCapacity)

  let status = AudioUnitRender(
    context.audioUnit, ioActionFlags, inTimeStamp, 1, clampedFrames,
    context.scratch.unsafeMutablePointer)
  guard status == noErr else {
    // This callback's frames are gone — same gap class as a ring drop, and
    // likewise uncounted before #1788.
    context.counters.incrementRenderFailure()
    return status
  }
  guard !context.stopped.isSet() else { return noErr }

  guard let data = context.scratch[0].mData else { return noErr }
  // Clamp again to what AudioUnitRender reports it actually wrote — never
  // trust the requested frame count alone.
  let renderedFrames = Int(context.scratch[0].mDataByteSize) / MemoryLayout<Float>.size
  let frameCount = min(Int(clampedFrames), renderedFrames)
  // A SHORT RENDER IS NOT A GAP, and #1788 r9 proposed counting it as one.
  // `noErr` with a reduced `mDataByteSize` means the device had fewer frames than
  // the slice asked for — those frames never existed, so nothing was lost. Counting
  // them would inflate `inputTimelineGapCount` on healthy captures and mark every
  // reading `floor`, making the instrument worse rather than more honest. Declined
  // deliberately, not overlooked; revisit only with evidence that a short render
  // accompanies actual audio loss.
  guard frameCount > 0 else { return noErr }
  let floatPtr = data.assumingMemoryBound(to: Float.self)

  var sum: Float = 0
  for i in 0..<frameCount { sum += floatPtr[i] * floatPtr[i] }
  let level = (sum / Float(frameCount)).squareRoot()

  // Only wake the consumer when a chunk was actually enqueued — a dropped
  // push (ring full, consumer lagging) has nothing for `drainAndForward` to
  // do, so signaling anyway just spins the consumer thread on empty work
  // (cloud review P2).
  if context.ring.push(floatPtr, count: frameCount, level: level) {
    context.semaphore.signal()
  } else {
    // #1434: a dropped chunk is lost audio — count it (bounded lock-inc, same
    // RT cost class as the ring lock) so a bad recording can prove or rule
    // out ring overrun instead of the drop staying invisible.
    context.counters.incrementRingDrop()
  }

  return noErr
}

// MARK: - Native open (#4601 §3.2)

/// The cold open, with no source state: device resolution, unit creation and
/// configuration, native-format reads, channel application, initialize, start,
/// the consumer thread and listener registration. Every partial resource stays
/// local and is retired through `HALUnitResources` on failure. The caller (main
/// actor) commits the returned resources and facts, or throws the returned
/// failure, and finalizes the cold-attempt attribution exactly once.
///
/// Temporary boundary (#4601 C3): still called synchronously on the main actor.
/// `OpenRequest` carries `InputDeviceResolver` (plain closure fields), so it is
/// not `Sendable`; the chunk that moves `open` onto the audio-unit lane owns the
/// checked `Sendable` migration.
enum HALUnitNative {
  static let listenerQueue = DispatchQueue(
    label: "com.enviouswispr.audio.hal-device-listener"
  )

  static let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
  )!

  /// Frames per slice AUHAL is configured for; bounds the scratch buffer.
  static let maxFramesPerSlice: UInt32 = 4096
  static let ringSlotCount = 16

  /// Where listener blocks report. Each closure hops to the main actor before
  /// reading or mutating source state; native code never reads the source.
  struct ListenerSink: Sendable {
    let deviceMayHaveVanished: @Sendable (_ deviceID: AudioDeviceID, _ generation: UInt64) -> Void
    let formatMayHaveChanged:
      @Sendable (_ deviceID: AudioDeviceID, _ selector: String, _ generation: UInt64) -> Void
  }

  /// #4601 §3.8: the open's resolution and bind facts as soon as they exist, so a start that
  /// ends early (timed out, abandoned) freezes only what was really observed. Written on the
  /// lane, read on the main actor at the terminal decision; no hardware read fills a gap.
  /// One opened unit in transit; `take()` returns it to exactly one caller.
  final class Handoff: Sendable {
    private let held = OSAllocatedUnfairLock<HALUnitResources?>(initialState: nil)
    func put(_ resources: HALUnitResources) { held.withLock { $0 = resources } }
    func take() -> HALUnitResources? {
      held.withLock { held -> HALUnitResources? in
        defer { held = nil }
        return held
      }
    }
  }

  final class Progress: Sendable {
    private struct Facts {
      var resolution: InputDeviceResolution?
      var bind: InputBindOutcome?
      var frozen = false
    }
    private let state = OSAllocatedUnfairLock(initialState: Facts())
    func publish(resolution: InputDeviceResolution) {
      state.withLock { if !$0.frozen { $0.resolution = resolution } }
    }
    func publish(bind: InputBindOutcome) {
      state.withLock { if !$0.frozen { $0.bind = bind } }
    }
    /// Called at the first terminal decision: later publications are ignored.
    func freeze() { state.withLock { $0.frozen = true } }
    /// A terminal snapshot of what was published before the freeze, failed at `step`.
    func terminal(failedStep: String) -> FinalizedInputResolutionAttempt {
      let facts = state.withLock { $0 }
      return FinalizedInputResolutionAttempt(
        resolution: facts.resolution, bindOutcome: facts.bind, prepareOutcome: .failed,
        failedStep: failedStep)
    }
  }

  /// Everything the cold open reads, snapshotted on the main actor. `Sendable`: it crosses to
  /// the audio-unit lane (#4601).
  struct OpenRequest: Sendable {
    let targetDeviceUID: String?
    let resolver: InputDeviceResolver
    let inputChannelByDeviceUID: [String: Int]
    fileprivate let captureLiveness: HALCaptureLivenessFlag
    let lifecycleSignal: (@Sendable (String) -> Void)?
    let nativeCalls: HALNativeCalls
    let listenerSink: ListenerSink
    let progress: Progress
    #if DEBUG
      var debugZeroFillController: DebugZeroFillController? = nil
    #endif
  }

  /// The committed bind's facts, read once during the open.
  struct Facts: Sendable {
    let deviceID: AudioDeviceID
    let deviceUID: String?
    let transportLabel: String?
    let resolutionSource: String
    let nativeChannelCount: Int?
    let inputChannel: Int
  }

  struct Opened: Sendable {
    let resources: HALUnitResources
    let forwarder: PreRollForwarder
    let facts: Facts
    let resolution: InputDeviceResolution
    let attempt: InputResolutionAttemptState
  }

  struct Failure: Sendable {
    let error: AudioError
    let resolution: InputDeviceResolution
    let attempt: InputResolutionAttemptState
    /// The current-device bind result when the open reached it; nil otherwise.
    let bindOutcome: Bool?
  }

  enum OpenResult: Sendable {
    case opened(Opened)
    case failed(Failure)
  }

  /// The AUHAL running property. Lane only (#4601).
  static func isRunning(_ unit: AudioUnit) -> Bool {
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioUnitGetProperty(
      unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running, &size)
    return status == noErr && running != 0
  }

  static func open(_ request: OpenRequest) -> OpenResult {
    request.lifecycleSignal?("hal_find_device_entered")

    // #1714: the ONE resolution for this cold attempt. Nothing below re-reads
    // the default, the device list, a UID or a transport to decide WHICH device
    // to open — a second read would describe different hardware than the one
    // this attempt resolved against.
    let resolution = request.resolver.resolve(preferredUID: request.targetDeviceUID)
    request.progress.publish(resolution: resolution)

    // #1714: the attempt record every cold exit carries back to the caller, which
    // finalises it exactly once (success or failure). Warm reuse never calls
    // `open`, which is why a reused bind reports no new attempt.
    var attemptState = InputResolutionAttemptState()
    var bindOutcome: Bool?

    // #1851: the ONE place a setup failure is constructed. It builds the error
    // that is thrown, records the same step and status into the attempt record
    // the caller finalises, and returns that same value, so the thrown
    // error (Sentry) and the record (PostHog) cannot disagree. `status` is the
    // `OSStatus` the failing call returned; pass nil for a step with none.
    func setupFailure(_ step: String, _ status: OSStatus? = nil) -> AudioError {
      let error = AudioError.formatCreationFailed(source: step, osStatus: status)
      attemptState.recordFailure(of: error)
      return error
    }

    func body() throws(AudioError) -> (HALUnitResources, PreRollForwarder, Facts) {
      // Exhaustive on purpose: a `?? .noBuiltInMicrophoneFound` fallback here
      // would be a second, unreachable error authority that could go wrong
      // silently. The resolver already decided which error is truthful.
      let deviceID: AudioDeviceID
      let selectedSource: InputResolutionSource
      switch resolution.outcome {
      case .selected(let id, let source):
        deviceID = id
        selectedSource = source
      case .failed(let error):
        attemptState.recordFailure(of: error)
        throw error
      }
      request.lifecycleSignal?("hal_find_device_completed")

      request.lifecycleSignal?("hal_configure_entered")
      var desc = AudioComponentDescription(
        componentType: kAudioUnitType_Output,
        componentSubType: kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
      )
      guard let component = AudioComponentFindNext(nil, &desc) else {
        throw setupFailure("HALDeviceInputSource.prepare.find_component")
      }

      var unit: AudioUnit?
      var status = AudioComponentInstanceNew(component, &unit)
      guard status == noErr, let unit else {
        // The guard also fails on a nil unit with `noErr`: a successful call is
        // never named as the failure, so a zero status travels as nil.
        throw setupFailure(
          "HALDeviceInputSource.prepare.instance_new",
          AudioStatusFormatting.failingStatus(status))
      }

      // #4601 §3.2: from here on the unit has ONE owner. Every failure branch below
      // retires `resources` (dispose first; callback storage only after a safe
      // dispose) and throws the setup failure it was given. The cleanup calls' own
      // statuses go to the retirement report and never replace that step/status
      // (#1851).
      let resources = HALUnitResources(unit: unit, native: request.nativeCalls)
      func failOpen(_ step: String, _ status: OSStatus? = nil) -> AudioError {
        HALDeviceInputSource.failedOpenError(retiring: resources, failure: setupFailure(step, status))
      }

      // Enable input on element 1, disable output on element 0 — input-only.
      var enableIO: UInt32 = 1
      status = AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
        &enableIO, UInt32(MemoryLayout<UInt32>.size))
      guard status == noErr else {
        throw failOpen("HALDeviceInputSource.prepare.enable_input", status)
      }
      var disableIO: UInt32 = 0
      status = AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
        &disableIO, UInt32(MemoryLayout<UInt32>.size))
      guard status == noErr else {
        throw failOpen("HALDeviceInputSource.prepare.disable_output", status)
      }

      // Pin the device — this is the whole point: any device, no aggregate.
      var pinnedDevice = deviceID
      status = AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
        &pinnedDevice, UInt32(MemoryLayout<AudioDeviceID>.size))
      let bindOK = status == noErr
      bindOutcome = bindOK
      // #1714: recorded from the authoritative current-device result, BEFORE the
      // guard below can throw. Everything after this point that fails leaves
      // `bind_outcome = succeeded` with `prepare_outcome = failed`, which is what
      // separates "could not open the microphone" from "opened it, then a later
      // setup step failed".
      attemptState.recordBind(succeeded: bindOK)
      request.progress.publish(bind: bindOK ? .succeeded : .failed)
      guard bindOK else {
        throw failOpen("HALDeviceInputSource.prepare.set_device", status)
      }

      // #2664: the bound device's identity and channel count, read into LOCALS
      // here (both are plain property reads with no device-configuration side
      // effect) and committed to `self` only in the all-succeeded block below.
      // Which channel the mono capture should take is decided by the one pure
      // authority; an unusable preference falls to channel 0, today's behaviour,
      // and says so in the route log.
      let deviceUID = AudioDeviceEnumerator.inputDeviceUID(for: deviceID)
      let nativeChannelCount = AudioDeviceEnumerator.inputChannelCount(for: deviceID)
      let requestedChannel = InputChannelPreference.requested(
        for: deviceUID, in: request.inputChannelByDeviceUID)
      let channel = InputChannelPreference.effectiveChannel(
        requested: requestedChannel, availableChannels: nativeChannelCount)
      if let requestedChannel, requestedChannel != channel {
        AudioCaptureManager.btRouteLog(
          "HALDeviceInputSource: channel_pref_out_of_range requested=\(requestedChannel) "
            + "available=\(nativeChannelCount) — capturing channel 0")
      }

      // AUHAL input does NOT resample (Apple QA1777: "does not provide sample
      // rate conversion" for input on macOS) — query the HARDWARE's actual
      // native rate and set the client format to MATCH it (mono/Float32 is
      // still safely convertible; sample RATE is not). Resampling to the
      // pipeline's 16kHz happens explicitly via AVAudioConverter on the
      // consumer thread (cloud review P2 on PR #1418 — the prior version
      // assumed a silent resample that only worked by coincidence on the
      // Bose, whose Bluetooth profile happens to already be 16kHz).
      let nativeRead = readNativeStreamFormat(deviceID: deviceID)
      guard let nativeASBD = nativeRead.format else {
        // #1851: the HAL read's own status, not an earlier success.
        throw failOpen(
          "HALDeviceInputSource.prepare.query_native_format",
          AudioStatusFormatting.failingStatus(nativeRead.status))
      }
      guard
        let nativeFormat = AVAudioFormat(
          commonFormat: .pcmFormatFloat32, sampleRate: nativeASBD.mSampleRate, channels: 1,
          interleaved: false)
      else {
        throw failOpen("HALDeviceInputSource.prepare.native_format")
      }
      guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
        throw failOpen("HALDeviceInputSource.prepare.converter")
      }

      // Client format on the input element's OUTPUT scope — what our render
      // callback receives, at the hardware's own rate.
      var clientFormat = nativeFormat.streamDescription.pointee
      status = AudioUnitSetProperty(
        unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
        &clientFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
      guard status == noErr else {
        throw failOpen("HALDeviceInputSource.prepare.stream_format", status)
      }

      // #2664: the ONE capture change. With a mono client format AUHAL takes
      // device channel 0 and nothing else, so a microphone on any other input of a
      // multi-input interface recorded silence. `kAudioOutputUnitProperty_ChannelMap`
      // on the input element's OUTPUT scope is an `Int32` per client channel naming
      // the device channel it should carry (Apple TN2091), and it must be set AFTER
      // the client format and BEFORE `AudioUnitInitialize`. Channel 0 sets nothing,
      // so the default path is byte-for-byte what shipped before. A refused set is
      // a LIMB failure: log it, keep channel 0, and let the take proceed — the
      // committed `boundInputChannel` then says 0, never the channel asked for.
      var appliedChannel = 0
      if channel != 0 {
        var channelMap: [Int32] = [Int32(channel)]
        let mapStatus = AudioUnitSetProperty(
          unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1,
          &channelMap, UInt32(MemoryLayout<Int32>.size))
        if mapStatus == noErr {
          appliedChannel = channel
        } else {
          AudioCaptureManager.btRouteLog(
            "HALDeviceInputSource: channel_map_set_failed status=\(mapStatus) requested=\(channel) "
              + "— capturing channel 0")
        }
      }

      // Scratch/ring capacity scales with the native rate — a fixed 4096-frame
      // buffer sized for 16kHz would be too small at 44.1/48kHz. 300ms of
      // headroom at whatever rate the hardware actually runs.
      let capacityFrames = max(Int(maxFramesPerSlice), Int(nativeFormat.sampleRate * 0.3))
      var maxFrames = UInt32(capacityFrames)
      let maxFramesStatus = AudioUnitSetProperty(
        unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
        &maxFrames, UInt32(MemoryLayout<UInt32>.size))
      if maxFramesStatus != noErr {
        // Non-fatal: the render callback clamps every read to the scratch
        // buffer's actual capacity regardless, so a device that ignores this
        // property still can't overrun — it just silently drops any frames
        // beyond capacity per callback. Logged (not RT-path) so the bake-off
        // evidence shows it happened.
        AudioCaptureManager.btRouteLog(
          "HALDeviceInputSource: kAudioUnitProperty_MaximumFramesPerSlice set failed (status=\(maxFramesStatus)) — render callback still clamps to scratch capacity"
        )
      }

      let scratch = AudioBufferList.allocate(maximumBuffers: 1)
      let scratchStorage = UnsafeMutableRawPointer.allocate(
        byteCount: capacityFrames * MemoryLayout<Float>.size,
        alignment: MemoryLayout<Float>.alignment
      )
      scratch[0] = AudioBuffer(
        mNumberChannels: 1,
        mDataByteSize: UInt32(capacityFrames * MemoryLayout<Float>.size),
        mData: scratchStorage
      )

      let ring = HALSampleRing(slotCount: ringSlotCount, capacityPerSlot: capacityFrames)
      let stopped = HALStoppedFlag()
      let fwd = PreRollForwarder()
      #if DEBUG
        fwd.debugZeroFillController = request.debugZeroFillController
      #endif
      let context = HALRenderContext(
        audioUnit: unit, scratch: scratch, capacityFrames: capacityFrames,
        ring: ring, stopped: stopped, liveness: request.captureLiveness, forwarder: fwd,
        nativeFormat: nativeFormat, targetFormat: targetFormat, converter: converter)
      let unmanaged = Unmanaged.passRetained(context)
      resources.attachCallbackStorage(context: context, unmanaged: unmanaged)

      // Every failure branch below retires `resources`, which disposes `unit` and
      // only then (when the dispose is safe) releases `unmanaged` and deallocates
      // `scratch` (#4601 §3.2: the base order released callback storage BEFORE
      // dispose). The source is never touched here (it stays a fresh,
      // never-prepared instance until the caller commits), so a caller that retries
      // `prepare()` or calls `teardownUnit()` never double-releases state this
      // attempt never actually committed.

      var callbackStruct = AURenderCallbackStruct(
        inputProc: halRenderProc,
        inputProcRefCon: unmanaged.toOpaque()
      )
      status = AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
        &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
      guard status == noErr else {
        throw failOpen("HALDeviceInputSource.prepare.set_callback", status)
      }

      status = AudioUnitInitialize(unit)
      guard status == noErr else {
        throw failOpen("HALDeviceInputSource.prepare.initialize", status)
      }
      resources.markInitialized()
      request.lifecycleSignal?("hal_configure_completed")

      request.lifecycleSignal?("hal_start_entered")
      status = AudioOutputUnitStart(unit)
      guard status == noErr else {
        // `status` is the Mac's answer to "start the microphone", the one number
        // #1851 exists to keep. The retirement's uninitialize and dispose return
        // their own results, which go to its report and never replace it.
        throw failOpen("HALDeviceInputSource.prepare.start", status)
      }
      resources.markStarted()
      request.lifecycleSignal?("hal_start_completed")

      resources.attachConsumer(makeConsumerThread(context: context))
      registerDeviceIsAliveListener(
        deviceID: deviceID, resources: resources, sink: request.listenerSink)
      registerFormatChangeListeners(
        deviceID: deviceID, resources: resources, sink: request.listenerSink)
      let transportLabel = AudioDeviceEnumerator.transportLabel(for: deviceID)
      // #1434: the native rate + ratio in the prepare line is the per-recording
      // rate evidence D4 flagged as the highest-value instrumentation gap.
      let ratio = targetFormat.sampleRate / nativeFormat.sampleRate
      AudioCaptureManager.btRouteLog(
        "HALDeviceInputSource: prepared with device \(deviceID) (uid=\(deviceUID ?? "unknown")) "
          + "nativeRate=\(Int(nativeFormat.sampleRate)) targetRate=\(Int(targetFormat.sampleRate)) "
          + "ratio=\(String(format: "%.3f", ratio)) "
          + "nativeChannels=\(nativeChannelCount) "
          + "inputChannel=\(appliedChannel)"
      )
      // #1714: only NOW is the attempt a success — every fallible step above
      // returned; the caller's commit that follows cannot fail.
      attemptState.recordPrepareSucceeded()
      return (
        resources, fwd,
        Facts(
          deviceID: deviceID, deviceUID: deviceUID, transportLabel: transportLabel,
          resolutionSource: selectedSource.rawValue, nativeChannelCount: nativeChannelCount,
          inputChannel: appliedChannel)
      )
    }

    do {
      let (resources, forwarder, facts) = try body()
      return .opened(
        Opened(
          resources: resources, forwarder: forwarder, facts: facts, resolution: resolution,
          attempt: attemptState))
    } catch {
      return .failed(
        Failure(
          error: error, resolution: resolution, attempt: attemptState, bindOutcome: bindOutcome))
    }
  }

  /// A dedicated thread that blocks on `context.semaphore` and drains the
  /// ring off the HAL IO thread. Signaling a semaphore (not
  /// `DispatchQueue.async`) from the render callback is the RT-safe wake
  /// primitive (Codex review r1 P2) — `async` enqueue can allocate/lock on
  /// the calling (IO) thread. Exits on its own once `HALUnitResources.retire()`
  /// signals after the stopped flag is set — never joined, never needs to be. The
  /// closure retains `context` itself, so the thread may drain after retirement;
  /// it reads only ring-owned samples, never render `scratch` (#4601 §3.2).
  fileprivate static func makeConsumerThread(context: HALRenderContext) -> Thread {
    let thread = Thread {
      while true {
        context.semaphore.wait()
        context.drainAndForward()
        if context.stopped.isSet() { break }
      }
    }
    thread.name = "com.enviouswispr.audio.hal-consumer"
    thread.qualityOfService = .userInteractive
    thread.start()
    return thread
  }

  /// Read the device's OWN native stream format directly from the HAL device
  /// object (`kAudioDevicePropertyStreamFormat`, input scope) — the ground
  /// truth for what rate the hardware actually runs at, queried BEFORE we
  /// overwrite the AudioUnit's client-side format with our own request.
  static func queryNativeStreamFormat(deviceID: AudioDeviceID)
    -> AudioStreamBasicDescription?
  {
    readNativeStreamFormat(deviceID: deviceID).format
  }

  /// The same read, keeping the `OSStatus` the HAL returned (#1851), so a failed
  /// read can say why. `format` is nil exactly when `status` is not `noErr`.
  static func readNativeStreamFormat(deviceID: AudioDeviceID)
    -> (format: AudioStreamBasicDescription?, status: OSStatus)
  {
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamFormat,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &format)
    return (status == noErr ? format : nil, status)
  }

  /// Device-vanish listener (#1408): its block reaches `handleDeviceMayHaveVanished`
  /// on the main actor through the sink.
  static func registerDeviceIsAliveListener(
    deviceID: AudioDeviceID, resources: HALUnitResources, sink: ListenerSink
  ) {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsAlive,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    // The sink hops to the main actor before any source state is read (#4601).
    let generation = resources.generation
    let block: AudioObjectPropertyListenerBlock = { _, _ in
      sink.deviceMayHaveVanished(deviceID, generation)
    }
    let status = AudioObjectAddPropertyListenerBlock(deviceID, &addr, listenerQueue, block)
    if status == noErr {
      // #4601 §3.2: the exact registration tuple lives with the unit it watches;
      // `HALUnitResources.retire()` removes it with the same object, address,
      // queue and block.
      resources.addListener(
        .init(object: deviceID, address: addr, queue: listenerQueue, block: block))
    }
  }

  /// Mid-recording format/rate-change observation — Apple's documented AirPods
  /// behavior (forum 770232) is a transient wrong rate corrected via exactly
  /// these notifications. Structural sibling of `registerDeviceIsAliveListener`:
  /// one registration tuple PER selector (owned by `HALUnitResources`, #4601), the
  /// shared `listenerQueue`, and a MainActor hop before touching source state. v1 is LOG + FLAG only — a forced
  /// interruption would discard the dictation (#1408's known gap), converting
  /// degraded audio into guaranteed total loss.
  static func registerFormatChangeListeners(
    deviceID: AudioDeviceID, resources: HALUnitResources, sink: ListenerSink
  ) {
    var formatAddr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamFormat,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var rateAddr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let generation = resources.generation
    let formatBlock: AudioObjectPropertyListenerBlock = { _, _ in
      sink.formatMayHaveChanged(deviceID, "streamFormat", generation)
    }
    let rateBlock: AudioObjectPropertyListenerBlock = { _, _ in
      sink.formatMayHaveChanged(deviceID, "nominalRate", generation)
    }
    if AudioObjectAddPropertyListenerBlock(deviceID, &formatAddr, listenerQueue, formatBlock)
      == noErr
    {
      resources.addListener(
        .init(object: deviceID, address: formatAddr, queue: listenerQueue, block: formatBlock))
    }
    if AudioObjectAddPropertyListenerBlock(deviceID, &rateAddr, listenerQueue, rateBlock)
      == noErr
    {
      resources.addListener(
        .init(object: deviceID, address: rateAddr, queue: listenerQueue, block: rateBlock))
    }
  }
}

// MARK: - Native unit ownership (#4601 §3.2)

/// The native calls a unit's retirement makes. Injectable so tests can gate and
/// fail them without hardware; `.live` is the real Core Audio API.
struct HALNativeCalls: Sendable {
  var stop: @Sendable (AudioUnit) -> OSStatus
  var uninitialize: @Sendable (AudioUnit) -> OSStatus
  var dispose: @Sendable (AudioUnit) -> OSStatus
  var removeListener:
    @Sendable (
      AudioObjectID, AudioObjectPropertyAddress, DispatchQueue,
      @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus
  /// Observation only: called right after callback storage is freed. Production
  /// passes a no-op; tests use it to see WHEN storage was released.
  var storageReleased: @Sendable () -> Void
  /// The running property read (lane only). Injectable like the calls above.
  var isRunning: @Sendable (AudioUnit) -> Bool = { HALUnitNative.isRunning($0) }

  static let live = HALNativeCalls(
    stop: { AudioOutputUnitStop($0) },
    uninitialize: { AudioUnitUninitialize($0) },
    dispose: { AudioComponentInstanceDispose($0) },
    removeListener: { object, address, queue, block in
      var address = address
      return AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    },
    storageReleased: {})
}

/// #4601 §3.2: the ONE owner of a native AUHAL unit and everything its callbacks
/// can reach: the render context, the unmanaged retain the render callback
/// dereferences, the scratch buffer it renders into, the stopped flag, the
/// consumer thread and the exact listener registration tuples.
///
/// Built right after `AudioComponentInstanceNew`, so a partial open has an owner
/// too. `retire()` is the single cleanup authority for every path (normal stop,
/// abort, rebuild, device vanish, and every failed open), runs at most once, and
/// frees callback storage only after native retirement establishes safety:
/// `AudioOutputUnitStop` returned `noErr` (when the unit was started) AND
/// `AudioComponentInstanceDispose` returned `noErr`. Otherwise the storage and its
/// retain are kept until process exit and the failure is logged (Chromium keeps
/// callback storage when AUHAL teardown fails, because callbacks may survive).
/// The DEBUG #1540 counter is a tripwire, not the safety criterion.
///
/// `@unchecked Sendable` by single-owner hand-off (#4601 §3.1): exactly one party holds it at a
/// time (the native open that built it, then either the main-actor source after commit or the
/// audio-unit lane disposing a late result, then the lane that retires it). Every mutating member
/// (`attach*`, `mark*`, `addListener`, `retire`) runs on the current owner's thread only; no
/// party touches it after handing it on.
final class HALUnitResources: @unchecked Sendable {
  /// How far the open got, which decides what retirement must undo.
  enum Stage: Int, Comparable {
    case created, initialized, started
    static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  /// One successful `AudioObjectAddPropertyListenerBlock`, kept exactly as
  /// registered so removal uses the same object, address, queue and block.
  struct ListenerRegistration {
    let object: AudioObjectID
    let address: AudioObjectPropertyAddress
    let queue: DispatchQueue
    let block: AudioObjectPropertyListenerBlock
  }

  /// What `retire()` did. Statuses are nil for calls the stage did not need.
  struct RetirementReport: Equatable {
    var listenerRemovals: [OSStatus]
    var stop: OSStatus?
    var uninitialize: OSStatus?
    var dispose: OSStatus
    var storageReleased: Bool
  }

  let unit: AudioUnit
  /// #4601 §3.4: process-unique identity of this unit, assigned before any listener is
  /// registered; listener deliveries carry it so stale callbacks are ignored.
  let generation: UInt64
  private(set) var stage: Stage = .created
  fileprivate private(set) var context: HALRenderContext?
  private var unmanaged: Unmanaged<HALRenderContext>?
  private var consumerThread: Thread?
  private(set) var listeners: [ListenerRegistration] = []
  private let native: HALNativeCalls
  private(set) var report: RetirementReport?

  private static let generations = OSAllocatedUnfairLock<UInt64>(initialState: 0)

  init(unit: AudioUnit, native: HALNativeCalls) {
    self.unit = unit
    self.native = native
    self.generation = Self.generations.withLock { next -> UInt64 in
      next += 1
      return next
    }
  }

  /// #4601 §3.4: closes capture admission at hand-off: the render callback bails on the stopped
  /// flag, so no new samples reach the consumer while a retirement waits on the lane. Thread-safe
  /// (the flag has its own lock); `retire()` sets it again, harmlessly.
  func markStopping() { context?.stopped.set() }

  /// Whether `retire()` has run. Read on the audio-unit lane, where retirement runs too.
  var isRetired: Bool { report != nil }

  /// Whether the render callback's storage (scratch + unmanaged retain) is still
  /// held. True from attach until a SAFE retirement; stays true after an unsafe one.
  var holdsCallbackStorage: Bool { unmanaged != nil }

  fileprivate func attachCallbackStorage(
    context: HALRenderContext, unmanaged: Unmanaged<HALRenderContext>
  ) {
    precondition(report == nil && self.unmanaged == nil, "callback storage attached twice")
    self.context = context
    self.unmanaged = unmanaged
  }

  func markInitialized() { stage = max(stage, .initialized) }
  func markStarted() { stage = .started }
  fileprivate func attachConsumer(_ thread: Thread) { consumerThread = thread }
  func addListener(_ registration: ListenerRegistration) {
    precondition(report == nil, "listener added to a retired unit")
    listeners.append(registration)
  }

  /// Retires the unit once; a second call returns the first report and touches
  /// nothing native.
  @discardableResult
  func retire() -> RetirementReport {
    if let report { return report }
    // Set before anything blocks: the render callback and the consumer both check it.
    context?.stopped.set()
    let removals = listeners.map {
      native.removeListener($0.object, $0.address, $0.queue, $0.block)
    }
    // These are expected to be synchronous: `AudioOutputUnitStop` +
    // `AudioUnitUninitialize` + dispose should leave no `halRenderProc`
    // running, so nothing below races a live callback touching `scratch`.
    // Apple's docs do NOT explicitly promise the callback has RETURNED
    // (#1540), so the DEBUG quiescence assert below verifies it empirically
    // rather than trusting the assumption — this is the load-bearing check
    // before the in-process collapse (C1) makes a UAF here a full-app crash.
    let stopStatus = stage >= .started ? native.stop(unit) : nil
    let uninitializeStatus = stage >= .initialized ? native.uninitialize(unit) : nil
    let disposeStatus = native.dispose(unit)
    let safe = (stopStatus ?? noErr) == noErr && disposeStatus == noErr
    #if DEBUG
      // (#1540) Best-effort quiescence tripwire for the assumption above: after
      // stop/uninitialize/dispose, NO render callback should still be running,
      // so freeing `scratch` below cannot be a use-after-free. A NONZERO count
      // here is always a real fault (a callback genuinely still in flight at
      // free time) — no false positives — and under stress this catches Apple's
      // stop failing to quiesce before the in-process collapse (C1) turns it
      // into a full-app crash. A zero count is strong but not conclusive (see
      // the counter's declaration). `callbackEnteredAfterStop` is logged for
      // context but is NOT itself a fault (a callback that bails at the stop
      // guard is safe). Checked only on a safe retirement: an unsafe one frees
      // nothing, so a still-running callback is no use-after-free (#4601).
      if safe, let context {
        let inFlight = context.inFlightRenderCallbacks.withLock { $0 }
        let racedStop = context.callbackEnteredAfterStop.withLock { $0 }
        if inFlight != 0 || racedStop {
          AudioCaptureManager.btRouteLog(
            "HAL teardown quiescence (#1540): inFlightRenderCallbacks=\(inFlight) callbackEnteredAfterStop=\(racedStop)"
              + (inFlight != 0
                ? " — AudioOutputUnitStop did NOT quiesce the RT callback before free (UAF window)"
                : " — callback raced the stop flag but bailed safely (no UAF)"))
        }
        assert(
          inFlight == 0,
          "HAL teardown: \(inFlight) render callback(s) still in flight after stop/dispose — freeing scratch is a use-after-free (#1540)"
        )
      }
    #endif
    // Wake the consumer thread (blocked on the semaphore) so it observes the
    // stopped flag and exits its loop. No RT callback can signal again after
    // `AudioOutputUnitStop` returned above, so this is the FINAL signal —
    // the thread drains anything left, sees `stopped.isSet()`, and returns.
    context?.semaphore.signal()
    var released = false
    if safe {
      if let unmanaged, let context {
        unmanaged.release()
        context.scratch[0].mData?.deallocate()
        context.scratch.unsafeMutablePointer.deallocate()
        self.unmanaged = nil
        released = true
        native.storageReleased()
      }
    } else if unmanaged != nil {
      AudioCaptureManager.btRouteLog(
        "HAL retirement unsafe (#4601): stop=\(stopStatus.map(String.init) ?? "n/a") "
          + "dispose=\(disposeStatus) — keeping callback storage until process exit")
    }
    consumerThread = nil
    let finished = RetirementReport(
      listenerRemovals: removals, stop: stopStatus, uninitialize: uninitializeStatus,
      dispose: disposeStatus, storageReleased: released)
    report = finished
    return finished
  }

  deinit {
    // Every owner path retires; an unretired owner here would be a leaked open
    // unit. Release builds free nothing here, which is the safe direction.
    assert(report != nil, "HALUnitResources released without retire() (#4601)")
  }
}

extension HALDeviceInputSource {
  /// Failed-open cleanup (#4601 §3.2): retires the partial unit and returns the
  /// setup failure unchanged, whatever the retirement reported (#1851).
  nonisolated static func failedOpenError(
    retiring resources: HALUnitResources, failure: AudioError
  ) -> AudioError {
    resources.retire()
    return failure
  }
}

#if DEBUG
  extension HALUnitResources {
    /// Test seam: a resources owner at `stage` with real callback storage (scratch,
    /// render context, unmanaged retain) around a fake unit pointer that only the
    /// injected `native` calls ever receive.
    static func makeForTesting(
      stage: Stage, native: HALNativeCalls, listenerCount: Int = 0,
      forwarder: PreRollForwarder = PreRollForwarder()
    ) -> HALUnitResources {
      let unit = AudioUnit(bitPattern: 0x4601)!
      let resources = HALUnitResources(unit: unit, native: native)
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
      let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
      let capacity = 4096
      let scratch = AudioBufferList.allocate(maximumBuffers: 1)
      let storage = UnsafeMutableRawPointer.allocate(
        byteCount: capacity * MemoryLayout<Float>.size, alignment: MemoryLayout<Float>.alignment)
      scratch[0] = AudioBuffer(
        mNumberChannels: 1, mDataByteSize: UInt32(capacity * MemoryLayout<Float>.size),
        mData: storage)
      let context = HALRenderContext(
        audioUnit: unit, scratch: scratch, capacityFrames: capacity,
        ring: HALSampleRing(slotCount: 2, capacityPerSlot: capacity), stopped: HALStoppedFlag(),
        liveness: HALCaptureLivenessFlag(), forwarder: forwarder, nativeFormat: format,
        targetFormat: target, converter: AVAudioConverter(from: format, to: target)!)
      resources.attachCallbackStorage(context: context, unmanaged: .passRetained(context))
      if stage >= .initialized { resources.markInitialized() }
      if stage >= .started { resources.markStarted() }
      for index in 0..<listenerCount {
        resources.addListener(
          .init(
            object: AudioObjectID(index + 1),
            address: AudioObjectPropertyAddress(
              mSelector: kAudioDevicePropertyDeviceIsAlive,
              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain),
            queue: .main, block: { _, _ in }))
      }
      return resources
    }

    /// Whether the stopped flag the callbacks read is set.
    var stoppedFlagIsSetForTesting: Bool { context?.stopped.isSet() ?? false }

    /// Test seam: installs a hook the consumer runs right before routing a chunk.
    func setBeforeRouteForTesting(_ hook: @escaping @Sendable () -> Void) {
      context?.debugBeforeRoute = hook
    }

    /// Test seam: puts one chunk of audio in the ring as if rendered, then runs the consumer's
    /// drain once, the way the consumer thread does.
    func renderAndDrainForTesting() {
      guard let context else { return }
      let samples = [Float](repeating: 0.25, count: 480)
      samples.withUnsafeBufferPointer { _ = context.ring.push($0.baseAddress!, count: 480, level: 0.25) }
      context.drainAndForward()
    }
  }
#endif
