import CWebRTCAEC
import EnviousWisprCore
import Foundation
import os

// #4355 PR B: the meeting echo cleaner. One recording-scoped WebRTC AEC3 instance on a serial
// worker. The microphone and the render reference (the call sound the Mac plays) arrive as
// 16 kHz mono float audio with their acquisition times; every admitted microphone interval comes
// back exactly once, in admission order, with its raw samples untouched and either AEC3's
// cleaned samples or an explicit raw substitution.
//
// Ownership and threading:
// - Admission (`admitMicrophone`, `admitRender`, `requestReset`, `close`, `settle`,
//   `takeResults`) is non-blocking except `settle`, which waits at most until the caller's
//   deadline. All shared state sits behind one lock; no native call runs under it.
// - Native work runs only on the injected serial executor (one scheduled drain at a time). The
//   native backend is owned by the worker: it is created at init, released on the worker after
//   the final drain, and destroyed by its `deinit` only once no native call holds it. A drain
//   stuck inside a native call keeps the backend alive until that call returns (or the process
//   exits); `settle` never waits for it.
// - Substitution (backlog, deadline, close timeout) is decided under the lock by the admitting
//   or settling caller, so it never waits for a blocked native call. It bumps `generation`; a
//   native result produced under an older generation is discarded, so a late result cannot
//   replace a substitution.
//
// Alignment: the render reference is fed in acquisition-time order up to the end of each
// microphone frame; AEC3's own delay estimator does the fine alignment (stream delay seed 0,
// Phase 0a: 36-40 ms, steady). Written file positions (`MeetingAudioSpan`) play no part.

/// The native operations the worker drives, for one recording. The default is the shipped
/// CWebRTCAEC library; tests may substitute a fake at this boundary only.
package protocol MeetingEchoBackend: AnyObject {
  /// Feeds one 160-sample render frame. False when the library refused it.
  func render(_ frame: UnsafePointer<Float>) -> Bool
  /// Cleans one 160-sample microphone frame into `out`. False when the library refused it.
  func capture(_ frame: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>) -> Bool
  /// Returns the library to its just-created state. False when that failed.
  func reset() -> Bool
  /// Whether the library reports a delay estimate now; nil when metrics could not be read.
  func hasDelayEstimate() -> Bool?
}

/// The shipped WebRTC AEC3 library behind `MeetingEchoBackend`.
package final class WebRTCEchoBackend: MeetingEchoBackend {
  private let handle: OpaquePointer

  /// Nil when the library could not create an instance.
  package init?() {
    guard let created = ew_aec_create() else { return nil }
    handle = created
  }

  deinit { ew_aec_destroy(handle) }

  package func render(_ frame: UnsafePointer<Float>) -> Bool {
    ew_aec_process_render(handle, frame, EW_AEC_FRAME_SAMPLES) == EW_AEC_OK
  }

  package func capture(_ frame: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>) -> Bool
  {
    ew_aec_process_capture(handle, frame, out, EW_AEC_FRAME_SAMPLES) == EW_AEC_OK
  }

  package func reset() -> Bool { ew_aec_reset(handle) == EW_AEC_OK }

  package func hasDelayEstimate() -> Bool? {
    var metrics = EWAECMetrics()
    guard ew_aec_get_metrics(handle, &metrics) == EW_AEC_OK else { return nil }
    return metrics.has_delay != 0
  }
}

/// Why a microphone interval came back raw instead of cleaned.
public enum MeetingEchoSubstitution: Sendable, Hashable {
  /// AEC3 has not yet shown it is tracking since its last start or reset.
  case reacquiring
  /// No render reference had reached AEC3 since its last start or reset.
  case noReference
  /// Admitted microphone audio waiting for the worker exceeded 500 ms.
  case backlog
  /// The oldest waiting interval was admitted more than 500 ms ago.
  case deadline
  /// The library refused a frame, or a reset failed.
  case nativeFailure
  /// The library could not be created; nothing is cleaned for this recording.
  case nativeUnavailable
  /// `settle` reached its deadline before this interval was processed.
  case closed
}

/// One admitted microphone interval, settled.
public struct MeetingEchoResult: Sendable {
  public let acquired: MeetingAcquisitionTime
  /// The producer run the interval was admitted with.
  public let run: Int
  /// The samples exactly as admitted.
  public let raw: [Float]
  /// AEC3's output, or `raw` again when `substitution` is set. Always `raw.count` samples.
  public let cleaned: [Float]
  /// Nil when `cleaned` is AEC3's output for every sample.
  public let substitution: MeetingEchoSubstitution?
}

/// Whether the worker took a microphone interval. A refused interval stays the caller's: it
/// delivers the raw samples itself.
public enum MeetingEchoAdmission: Sendable, Hashable {
  case accepted
  case refusedClosed
  case refusedOtherRecording
  case refusedEmpty
  /// More than `readyCapacitySamples` of settled audio is waiting for `takeResults`.
  case refusedResultsNotTaken
  /// One interval longer than `backlogSamples`: it could never be cleaned within the bound.
  case refusedTooLong
}

/// Why the caller asks AEC3 to start over (the next frame resets and reacquires).
public enum MeetingEchoResetReason: Sendable, Hashable {
  case microphoneReopened
  case callSoundRebuilt
  case sampleRateChanged
  case wake
  case divergence
}

public final class MeetingEchoCanceller: @unchecked Sendable {
  // @unchecked Sendable: every stored property is either immutable, the lock-protected
  // `shared`, or `worker`, which only the serial executor touches (see `Worker`).

  /// Counters for the recording's end report (read with `counters`).
  public struct Counters: Sendable, Equatable {
    public var cleanedIntervals = 0
    public var substitutedIntervals: [MeetingEchoSubstitution: Int] = [:]
    public var capturedFrames = 0
    public var renderFrames = 0
    public var renderSamplesDropped = 0
    public var foreignRenderChunks = 0
    public var resets = 0
    public var resetRequests: [MeetingEchoResetReason: Int] = [:]
  }

  public static let frameSamples = Int(EW_AEC_FRAME_SAMPLES)
  /// The plan's raw-substitution bound (§3.2): 500 ms of waiting microphone audio, or an
  /// oldest waiting interval admitted 500 ms ago.
  public static let backlogSamples = Int(MeetingAudioFormat.sampleRate) / 2
  public static let backlogNanos: UInt64 = 500_000_000
  /// Render reference kept ahead of the microphone (1 s); older reference is dropped and
  /// AEC3 restarts, because a hole in the reference breaks its echo path.
  public static let renderCapacitySamples = Int(MeetingAudioFormat.sampleRate)
  /// Settled audio kept for `takeResults` (2 s); past it new microphone audio is refused and
  /// stays the caller's.
  public static let readyCapacitySamples = Int(MeetingAudioFormat.sampleRate) * 2
  /// Metrics are read once per this many captured frames (1 s of audio).
  static let metricsEveryFrames = 100
  /// Consecutive metric reads with a delay estimate before cleaned output is trusted. The
  /// library's metrics can lag one read (CWebRTCAEC.h), so one read is not proof.
  static let trustReads = 2

  private struct Interval {
    let id: UInt64
    let acquired: MeetingAcquisitionTime
    let run: Int
    let raw: [Float]
    let admittedAt: UInt64
    /// Microphone audio before this interval was refused: the stream is not contiguous.
    let afterGap: Bool
  }

  private struct RenderChunk {
    let acquired: MeetingAcquisitionTime
    let run: Int
    let samples: [Float]
  }

  private struct Shared {
    var pending: [Interval] = []
    var pendingSamples = 0
    var renderInbox: [RenderChunk] = []
    var renderInboxSamples = 0
    var ready: [MeetingEchoResult] = []
    var readySamples = 0
    var deadlineArmed = false
    var nextID: UInt64 = 0
    var generation: UInt64 = 0
    var resetRequested = false
    /// Queued reference no longer continues into new reference (a drop or a call-sound rebuild).
    var referenceInvalid = false
    /// Microphone audio was refused since the last accepted interval.
    var micGap = false
    var closed = false
    var drainScheduled = false
    var workerReleased = false
    var counters = Counters()
  }

  private let recording: UUID
  private let now: @Sendable () -> UInt64
  private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void
  private let after: @Sendable (UInt64, @escaping @Sendable () -> Void) -> Void
  private let shared = OSAllocatedUnfairLock(initialState: Shared())
  private let settled = NSCondition()
  private let worker: Worker

  /// - Parameters:
  ///   - recording: the meeting; audio of any other meeting is refused.
  ///   - makeBackend: creates the native instance, called once on the worker executor (nil
  ///     means the library could not be created).
  ///   - now: monotonic nanoseconds (deadline and backlog age).
  ///   - schedule: a SERIAL executor for native work, never the main actor or a capture callback.
  ///   - after: runs work after a delay in nanoseconds, NOT on `schedule` (the 500 ms deadline
  ///     must fire while a native call blocks the worker).
  package init(
    recording: UUID,
    makeBackend: @escaping @Sendable () -> MeetingEchoBackend?,
    now: @escaping @Sendable () -> UInt64,
    schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
    after: @escaping @Sendable (UInt64, @escaping @Sendable () -> Void) -> Void
  ) {
    self.recording = recording
    self.now = now
    self.schedule = schedule
    self.after = after
    self.worker = Worker(makeBackend: makeBackend)
  }

  /// The production worker: the shipped library on its own serial queue.
  public convenience init(recording: UUID) {
    let queue = DispatchQueue(label: "com.enviouswispr.meeting.echo", qos: .userInitiated)
    let timers = DispatchQueue(label: "com.enviouswispr.meeting.echo.deadline")
    self.init(
      recording: recording, makeBackend: { WebRTCEchoBackend() },
      now: { DispatchTime.now().uptimeNanoseconds },
      schedule: { work in queue.async(execute: work) },
      after: { nanos, work in
        timers.asyncAfter(deadline: .now() + .nanoseconds(Int(min(nanos, UInt64(Int.max)))), execute: work)
      })
  }

  // MARK: Admission

  /// Admits one microphone interval (16 kHz mono, any length). Never waits for native work.
  @discardableResult
  public func admitMicrophone(
    _ samples: UnsafeBufferPointer<Float>, acquired: MeetingAcquisitionTime, run: Int
  ) -> MeetingEchoAdmission {
    guard acquired.recording == recording else { return .refusedOtherRecording }
    guard !samples.isEmpty else { return .refusedEmpty }
    guard samples.count <= Self.backlogSamples else {
      shared.withLock { s in if !s.closed { s.micGap = true } }
      return .refusedTooLong
    }
    let raw = Array(samples)
    let admittedAt = now()
    let (outcome, arm): (MeetingEchoAdmission, Bool) = shared.withLock { s in
      guard !s.closed else { return (.refusedClosed, false) }
      guard s.readySamples <= Self.readyCapacitySamples else {
        s.micGap = true
        return (.refusedResultsNotTaken, false)
      }
      if let oldest = s.pending.first {
        if s.pendingSamples + raw.count > Self.backlogSamples {
          Self.substituteAll(&s, .backlog)
        } else if admittedAt &- oldest.admittedAt > Self.backlogNanos {
          Self.substituteAll(&s, .deadline)
        }
      }
      s.pending.append(
        Interval(
          id: s.nextID, acquired: acquired, run: run, raw: raw, admittedAt: admittedAt,
          afterGap: s.micGap))
      s.micGap = false
      s.nextID += 1
      s.pendingSamples += raw.count
      let arm = !s.deadlineArmed
      s.deadlineArmed = true
      return (.accepted, arm)
    }
    if outcome == .accepted { scheduleDrain() }
    if arm { armDeadline(in: Self.backlogNanos + 1) }
    return outcome
  }

  /// Admits render reference (16 kHz mono). Reference of another meeting is ignored and
  /// counted. Keeps at most `renderCapacitySamples` waiting; older reference is dropped and
  /// AEC3 restarts.
  public func admitRender(
    _ samples: UnsafeBufferPointer<Float>, acquired: MeetingAcquisitionTime, run: Int
  ) {
    guard !samples.isEmpty else { return }
    guard acquired.recording == recording else {
      shared.withLock { $0.counters.foreignRenderChunks += 1 }
      return
    }
    let excess = max(0, samples.count - Self.renderCapacitySamples)
    let chunk = RenderChunk(
      acquired: MeetingAcquisitionTime(
        recording: acquired.recording,
        hostTicks: acquired.hostTicks &+ MeetingMicrophoneSilence.ticks(forSamples: excess),
        provenance: acquired.provenance),
      run: run, samples: Array(samples[excess...]))
    let admitted: Bool = shared.withLock { s in
      guard !s.closed else { return false }
      if excess > 0 {
        s.counters.renderSamplesDropped += excess
        s.resetRequested = true
        s.referenceInvalid = true
      }
      s.renderInbox.append(chunk)
      s.renderInboxSamples += chunk.samples.count
      while s.renderInboxSamples > Self.renderCapacitySamples, s.renderInbox.count > 1 {
        let dropped = s.renderInbox.removeFirst()
        s.renderInboxSamples -= dropped.samples.count
        s.counters.renderSamplesDropped += dropped.samples.count
        s.resetRequested = true
        s.referenceInvalid = true
      }
      return true
    }
    if admitted { scheduleDrain() }
  }

  /// Asks AEC3 to start over before the next frame; output is raw until it reacquires.
  public func requestReset(_ reason: MeetingEchoResetReason) {
    shared.withLock {
      $0.resetRequested = true
      $0.counters.resetRequests[reason, default: 0] += 1
      switch reason {
      case .callSoundRebuilt, .sampleRateChanged, .wake:
        // Reference admitted before this point does not continue into what follows: drop it
        // here, so only reference admitted after the request reaches AEC3.
        $0.counters.renderSamplesDropped += $0.renderInboxSamples
        $0.renderInbox.removeAll()
        $0.renderInboxSamples = 0
        $0.referenceInvalid = true
      case .microphoneReopened, .divergence: break
      }
    }
    scheduleDrain()
  }

  /// Settled intervals since the last call, in admission order. Results wait here until taken.
  /// Admission is refused once more than `readyCapacitySamples` waits; everything admitted
  /// before that is waiting audio (at most `backlogSamples`, moved here by a substitution) plus
  /// at most one more `backlogSamples` admitted with it, so this store holds at most
  /// `readyCapacitySamples + 2 × backlogSamples` samples.
  public func takeResults() -> [MeetingEchoResult] {
    shared.withLock { s in
      defer {
        s.ready.removeAll(keepingCapacity: true)
        s.readySamples = 0
      }
      return s.ready
    }
  }

  public var counters: Counters { shared.withLock { $0.counters } }

  // MARK: Stop

  /// Closes admission. Already admitted audio is still processed; the final drain cleans the
  /// last partial frame and then releases the native instance. Idempotent.
  public func close() {
    let first: Bool = shared.withLock { s in
      defer { s.closed = true }
      return !s.closed
    }
    if first { scheduleDrain() }
  }

  /// Waits until every admitted interval is settled or `deadline` (monotonic nanoseconds, the
  /// caller's shared Stop deadline) passes; then substitutes raw for anything unsettled and
  /// returns all results not yet taken. Never waits for a native call to return.
  public func settle(deadline: UInt64) -> [MeetingEchoResult] {
    close()
    settled.lock()
    while shared.withLock({ !$0.pending.isEmpty }) {
      let t = now()
      let remaining = deadline > t ? deadline - t : 0
      if remaining == 0 { break }
      _ = settled.wait(until: Date(timeIntervalSinceNow: Double(remaining) / 1e9))
    }
    settled.unlock()
    shared.withLock { s in
      if !s.pending.isEmpty { Self.substituteAll(&s, .closed) }
    }
    return takeResults()
  }

  /// True once the worker has released the native instance (it is destroyed when the last
  /// in-flight call returns).
  public var nativeReleased: Bool { shared.withLock { $0.workerReleased } }

  // MARK: Worker

  private func scheduleDrain() {
    let go: Bool = shared.withLock { s in
      guard !s.drainScheduled, !s.workerReleased else { return false }
      s.drainScheduled = true
      return true
    }
    guard go else { return }
    schedule { [self] in drain() }
  }

  private static func substituteAll(_ s: inout Shared, _ reason: MeetingEchoSubstitution) {
    for interval in s.pending {
      appendReady(
        &s,
        MeetingEchoResult(
          acquired: interval.acquired, run: interval.run, raw: interval.raw,
          cleaned: interval.raw, substitution: reason))
    }
    s.pending.removeAll()
    s.pendingSamples = 0
    s.generation &+= 1
  }

  private static func appendReady(_ s: inout Shared, _ result: MeetingEchoResult) {
    s.ready.append(result)
    s.readySamples += result.raw.count
    if let substitution = result.substitution {
      s.counters.substitutedIntervals[substitution, default: 0] += 1
    } else {
      s.counters.cleanedIntervals += 1
    }
  }

  /// The 500 ms deadline, independent of admission and of the worker: one timer at a time,
  /// re-armed for the next waiting interval.
  private func armDeadline(in nanos: UInt64) {
    after(nanos) { [self] in
      let next: UInt64? = shared.withLock { s in
        guard let oldest = s.pending.first else {
          s.deadlineArmed = false
          return nil
        }
        let age = now() &- oldest.admittedAt
        if age > Self.backlogNanos {
          Self.substituteAll(&s, .deadline)
          s.deadlineArmed = false
          return nil
        }
        return Self.backlogNanos - age + 1
      }
      if let next { armDeadline(in: next) } else { wakeSettle() }
    }
  }

  private func wakeSettle() {
    settled.lock()
    settled.broadcast()
    settled.unlock()
  }

  /// One drain: processes everything admitted, then returns. Runs only on the serial executor.
  private func drain() {
    shared.withLock { $0.drainScheduled = false }
    worker.createIfNeeded()
    while step() {}
    let release: Bool = shared.withLock { s in
      s.closed && s.pending.isEmpty && !s.workerReleased
    }
    if release {
      worker.backend = nil
      shared.withLock { $0.workerReleased = true }
    }
    wakeSettle()
  }

  /// Processes one microphone frame (or one closing tail). False when there is nothing to do.
  private func step() -> Bool {
    let w = worker
    let snapshot = shared.withLock {
      s -> (gen: UInt64, reset: Bool, dropReference: Bool, render: [RenderChunk], next: Interval?, closed: Bool) in
      let reset = s.resetRequested
      s.resetRequested = false
      let dropReference = s.referenceInvalid
      s.referenceInvalid = false
      let render = s.renderInbox
      s.renderInbox.removeAll()
      s.renderInboxSamples = 0
      let next = s.pending.first { $0.id >= w.feedID }
      return (s.generation, reset, dropReference, render, next, s.closed)
    }
    if snapshot.gen != w.generation {
      w.restartEpoch(generation: snapshot.gen)
      w.nativeResetNeeded = true
    }
    if snapshot.reset { w.nativeResetNeeded = true }
    // Reference queued before a drop or a call-sound rebuild does not continue into what follows.
    if snapshot.dropReference { w.dropReference() }
    for chunk in snapshot.render {
      w.enqueueRender(chunk.samples, ticks: chunk.acquired.hostTicks, run: chunk.run)
    }
    guard let interval = snapshot.next else {
      // Nothing left to feed: a closing drain cleans the last partial frame.
      if snapshot.closed, w.micFill > 0 { processFrame() }
      return false
    }
    let startsInterval = w.feedID != interval.id || w.feedOffset == 0
    if let run = w.micRun, run != interval.run || (startsInterval && interval.afterGap) {
      // The microphone stream breaks here (a new producer run, or refused audio): finish the
      // frame so far on its own, then start AEC3 over.
      if w.micFill > 0 { processFrame() }
      w.nativeResetNeeded = true
    }
    w.micRun = interval.run
    if w.feedID != interval.id {
      w.feedID = interval.id
      w.feedOffset = 0
    }
    let take = min(Self.frameSamples - w.micFill, interval.raw.count - w.feedOffset)
    if w.micFill == 0 {
      w.frameStartTicks =
        interval.acquired.hostTicks &+ MeetingMicrophoneSilence.ticks(forSamples: w.feedOffset)
    }
    interval.raw.withUnsafeBufferPointer { raw in
      for i in 0..<take { w.micFrame[w.micFill + i] = raw[w.feedOffset + i] }
    }
    w.micFill += take
    w.feedOffset += take
    w.frameSpans.append((interval.id, take))
    if w.feedOffset == interval.raw.count {
      w.feedID = interval.id + 1
      w.feedOffset = 0
    }
    if w.micFill == Self.frameSamples { processFrame() }
    return true
  }

  /// Runs AEC3 on the assembled microphone frame and settles the intervals it completes.
  private func processFrame() {
    let w = worker
    let real = w.micFill
    for i in real..<Self.frameSamples { w.micFrame[i] = 0 }
    var verdict: MeetingEchoSubstitution? = nil
    var out = [Float](repeating: 0, count: Self.frameSamples)
    var renderFed = 0
    var resetCount = 0
    var captured = false
    if let backend = w.backend {
      if w.nativeResetNeeded {
        w.nativeResetNeeded = false
        w.resetTrust()
        // A partial render frame from before the reset never joins reference after it.
        w.renderFill = 0
        resetCount = 1
        if !backend.reset() {
          w.backend = nil
          verdict = .nativeFailure
        }
      }
      if let backend = w.backend {
        let render = w.feedRender(
          upTo: w.frameStartTicks &+ MeetingMicrophoneSilence.ticks(forSamples: Self.frameSamples),
          backend)
        renderFed = render.fed
        if render.failed { verdict = .nativeFailure }
        let ok = w.micFrame.withUnsafeBufferPointer { m in
          out.withUnsafeMutableBufferPointer { o in
            backend.capture(m.baseAddress!, into: o.baseAddress!)
          }
        }
        captured = ok
        if !ok {
          verdict = .nativeFailure
          w.nativeResetNeeded = true
        } else {
          w.framesSinceMetrics += 1
          if w.framesSinceMetrics >= Self.metricsEveryFrames {
            w.framesSinceMetrics = 0
            w.delayReads = backend.hasDelayEstimate() == true ? w.delayReads + 1 : 0
          }
          if !w.renderSeen {
            verdict = verdict ?? .noReference
          } else if w.delayReads < Self.trustReads {
            verdict = verdict ?? .reacquiring
          }
        }
      }
    } else {
      verdict = .nativeUnavailable
    }
    let spans = w.frameSpans
    w.frameSpans.removeAll(keepingCapacity: true)
    w.micFill = 0
    let generation = w.generation
    let (frameVerdict, cleaned, fed, resets, didCapture) = (verdict, out, renderFed, resetCount, captured)
    let dropped = w.renderDropped
    w.renderDropped = 0
    shared.withLock { s in
      s.counters.resets += resets
      s.counters.renderSamplesDropped += dropped
      s.counters.renderFrames += fed
      if didCapture { s.counters.capturedFrames += 1 }
      // A substitution after this frame was taken owns those intervals: drop this result.
      guard s.generation == generation else { return }
      var offset = 0
      for (id, count) in spans {
        w.accumulate(id: id, samples: cleaned[offset..<(offset + count)], verdict: frameVerdict)
        offset += count
      }
      while let head = s.pending.first, let done = w.completed(head.id, count: head.raw.count) {
        s.pending.removeFirst()
        s.pendingSamples -= head.raw.count
        let substitution = done.verdict
        Self.appendReady(
          &s,
          MeetingEchoResult(
            acquired: head.acquired, run: head.run, raw: head.raw,
            cleaned: substitution == nil ? done.cleaned : head.raw, substitution: substitution))
      }
    }
  }

  /// State only the serial executor touches.
  // @unchecked Sendable: confined to the serial executor; the lock-held closures that touch
  // it run only inside `drain()` on that executor.
  private final class Worker: @unchecked Sendable {
    var backend: MeetingEchoBackend?
    private let makeBackend: @Sendable () -> MeetingEchoBackend?
    private var created = false
    var generation: UInt64 = 0
    var nativeResetNeeded = false
    // Microphone framing.
    var micFrame = [Float](repeating: 0, count: MeetingEchoCanceller.frameSamples)
    var micFill = 0
    var micRun: Int?
    var frameStartTicks: UInt64 = 0
    var frameSpans: [(UInt64, Int)] = []
    var feedID: UInt64 = 0
    var feedOffset = 0
    // Cleaned output per interval, until the interval is complete.
    var outputs: [UInt64: (cleaned: [Float], verdict: MeetingEchoSubstitution?)] = [:]
    // Render reference.
    var renderQueue: [(ticks: UInt64, samples: [Float], offset: Int)] = []
    var renderQueueSamples = 0
    var renderDropped = 0
    var renderRun: Int?
    var renderFrame = [Float](repeating: 0, count: MeetingEchoCanceller.frameSamples)
    var renderFill = 0
    var renderSeen = false
    // Trust.
    var framesSinceMetrics = 0
    var delayReads = 0

    init(makeBackend: @escaping @Sendable () -> MeetingEchoBackend?) { self.makeBackend = makeBackend }

    /// Creates the native instance on the worker executor, once.
    func createIfNeeded() {
      guard !created else { return }
      created = true
      backend = makeBackend()
    }

    func resetTrust() {
      renderSeen = false
      framesSinceMetrics = 0
      delayReads = 0
    }

    /// A substitution ended the epoch: nothing partial carries over.
    func restartEpoch(generation: UInt64) {
      self.generation = generation
      micFill = 0
      frameSpans.removeAll()
      outputs.removeAll()
      feedOffset = 0
      renderQueue.removeAll()
      renderQueueSamples = 0
      renderFill = 0
    }

    func dropReference() {
      renderDropped += renderQueueSamples + renderFill
      renderQueue.removeAll()
      renderQueueSamples = 0
      renderFill = 0
    }

    func enqueueRender(_ samples: [Float], ticks: UInt64, run: Int) {
      if let current = renderRun, current != run {
        renderQueue.removeAll()
        renderQueueSamples = 0
        renderFill = 0
        nativeResetNeeded = true
      }
      renderRun = run
      renderQueue.append((ticks, samples, 0))
      renderQueueSamples += samples.count
      // Reference the microphone never caught up with: keep the newest second, restart AEC3.
      while renderQueueSamples > MeetingEchoCanceller.renderCapacitySamples, renderQueue.count > 1 {
        let head = renderQueue.removeFirst()
        renderQueueSamples -= head.samples.count - head.offset
        renderDropped += head.samples.count - head.offset
        renderFill = 0
        nativeResetNeeded = true
      }
    }

    /// Feeds the render samples acquired before `limit` (exactly up to that time, across
    /// chunk boundaries) in whole frames. A refused render frame ends trust at once.
    func feedRender(upTo limit: UInt64, _ backend: MeetingEchoBackend) -> (fed: Int, failed: Bool) {
      var fed = 0
      var failed = false
      let ticksPerSecond = Double(MeetingMicrophoneSilence.ticks(forSamples: Int(MeetingAudioFormat.sampleRate)))
      while !renderQueue.isEmpty {
        let head = renderQueue[0]
        let start = head.ticks &+ MeetingMicrophoneSilence.ticks(forSamples: head.offset)
        guard start < limit else { break }
        let before = Int((Double(limit - start) / ticksPerSecond * MeetingAudioFormat.sampleRate).rounded(.up))
        let take = min(head.samples.count - head.offset, max(1, before))
        var index = head.offset
        let end = head.offset + take
        while index < end {
          let n = min(MeetingEchoCanceller.frameSamples - renderFill, end - index)
          for i in 0..<n { renderFrame[renderFill + i] = head.samples[index + i] }
          renderFill += n
          index += n
          if renderFill == MeetingEchoCanceller.frameSamples {
            let ok = renderFrame.withUnsafeBufferPointer { backend.render($0.baseAddress!) }
            renderFill = 0
            if ok {
              fed += 1
              renderSeen = true
            } else {
              failed = true
              resetTrust()
              nativeResetNeeded = true
            }
          }
        }
        renderQueueSamples -= take
        if end == head.samples.count {
          renderQueue.removeFirst()
        } else {
          renderQueue[0].offset = end
        }
      }
      return (fed, failed)
    }

    func accumulate(id: UInt64, samples: ArraySlice<Float>, verdict: MeetingEchoSubstitution?) {
      var entry = outputs[id] ?? ([], nil)
      entry.cleaned.append(contentsOf: samples)
      entry.verdict = entry.verdict ?? verdict
      outputs[id] = entry
    }

    func completed(_ id: UInt64, count: Int) -> (
      cleaned: [Float], verdict: MeetingEchoSubstitution?
    )? {
      guard let entry = outputs[id], entry.cleaned.count >= count else { return nil }
      outputs[id] = nil
      return (Array(entry.cleaned.prefix(count)), entry.verdict)
    }
  }
}
