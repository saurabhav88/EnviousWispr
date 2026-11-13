import AudioToolbox
import CoreAudio
import Darwin
import EnviousWisprCore
import Foundation
import os

/// Writes one EnviousMeet track to disk as rolling 60-second CAF segment files (#3972 §3.2, R2,
/// R3). Peer design (#3972 teardown): FluidVoice writes meeting audio in 60-second chunks so a
/// crash costs at most the chunk being written.
///
/// **Threading.** `append` may be called from any thread, including the HAL consumer thread, a
/// Core Audio IOProc and the MainActor. It only copies into storage reserved at init, under a
/// lock, and schedules a drain; it never waits for disk work and never calls the owner. File work
/// and the owner callbacks run on the writer's own serial queue. The writer never hops to the
/// MainActor, so `close(until:)` from `applicationWillTerminate` cannot deadlock.
///
/// **Handoff storage.** Two sample buffers and two chunk lists, each reserved to capacity at
/// init. A drain SWAPS the filled pair with the empty pair under the lock, writes the swapped
/// pair outside it and empties it in place, so no drain allocates or copies the audio.
///
/// **Timeline.** Positions are 16 kHz samples from the meeting's anchor host time. A new segment
/// starts on a 16-sample boundary (1 ms), so its file-name start time is exact. A segment that
/// rolls over at 60 s continues exactly where the last one ended. Arrival times are approximate
/// (R27): only a jump forward past `gapThresholdMs`, or audio this writer had to drop, starts a
/// new segment at the arrival time; small jitter is ignored. Audio from before the anchor is
/// trimmed and counted.
///
/// **Durability order per segment (R3).** Reserve `<stem>-<n>-s<ms>.caf.partial` with an
/// exclusive create (an existing file is never erased or overwritten) → write → on 60 s, a gap,
/// a drop or close: `ExtAudioFileDispose` (finalizes the header) → `F_FULLFSYNC` → exclusive
/// rename to `.caf` → directory sync → `onSegmentFinalized`. The owner records the segment after
/// that callback, so a file can exist without its record (recovery adds it) but a record never
/// names a file that is not complete. Any failed step is reported once through `onFailure`,
/// stops the writer and leaves the file for recovery.
///
/// **Microphone silence hold (#4248).** A writer configured with `silenceHoldSeconds` passes every
/// drained chunk through `MeetingMicrophoneSilence` on its queue before writing it: audio waits
/// for the hold, samples inside `setSilencedIntervals` are zeroed, and the chunk is written and
/// handed to `onReleased` with its original metadata. Release is scheduled queue work, never a
/// wait. `finish`, `close(until:)` and `waitUntilWritten` release everything held first. Other
/// writers (call sound) write each chunk at once, as before.
///
/// **Cleaned copy (#4355 PR B).** A microphone writer configured with `cleanedCopy` also takes an
/// echo-cleaned copy of every chunk (`append(_:cleaned:...)`). Both copies go through the same
/// hold, masking, pre-anchor trim and placement, decided once for the raw audio, and the cleaned
/// copy is written to a twin file per segment (`micclean-<n>-s<ms>.caf`, same index and start)
/// with the same durability order. The cleaned copy is derivative: a failure creating, writing or
/// finalizing it never touches the raw audio, never trips `onFailure` and never stops the writer.
/// It is counted (`Health.cleanedFailed`), its unfinished twin is removed where it can be, and no
/// further cleaned segment is written. Eligibility never depends on that cleanup: only a close
/// that finished every twin without any cleaned-copy failure writes the durable proof
/// (`MeetingSegmentNaming.cleanedProofName`), and the final pass uses only twins a proof lists.
public final class MeetingTrackWriter: @unchecked Sendable {
  public typealias SegmentHandler = @Sendable (MeetingSegmentInfo) -> Void
  public typealias FailureHandler = @Sendable (Error) -> Void
  /// Receives each slice once it is written (after the hold, silence, pre-anchor trimming and
  /// placement), with its written span, on the writer's queue. Audio that was trimmed or that a
  /// failed write lost is never handed over. The buffer is valid only during the call.
  public typealias ReleasedHandler = @Sendable (UnsafeBufferPointer<Float>, MeetingReleasedChunk)
    -> Void

  public struct Configuration: Sendable {
    public let meetingID: UUID
    public let track: MeetingTrackKind
    /// The meeting's folder (`MeetingStore.folder(for:)`).
    public let folder: URL
    /// Host time (mach ticks) the meeting's timeline is measured from.
    public let anchorHostTime: UInt64
    public let segmentSeconds: Double
    /// A chunk arriving this much later than the samples already written predict starts a new
    /// segment at its real time (device change, stall, sleep).
    public let gapThresholdMs: Int
    /// Samples the handoff buffer can hold before new audio is counted as dropped.
    public let bufferCapacity: Int
    /// Appends the handoff can hold between drains before new audio is counted as dropped.
    public let maxPendingChunks: Int
    /// The microphone silence hold in seconds (#4248); nil writes each chunk at once. Ignored
    /// for any track but the microphone.
    public let silenceHoldSeconds: Double?
    /// #4355 PR B: the microphone also writes an echo-cleaned twin of every segment. Ignored for
    /// any track but the microphone.
    public let cleanedCopy: Bool

    public init(
      meetingID: UUID, track: MeetingTrackKind, folder: URL, anchorHostTime: UInt64,
      segmentSeconds: Double = MeetingAudioFormat.segmentSeconds, gapThresholdMs: Int = 1_500,
      bufferCapacity: Int = Int(MeetingAudioFormat.sampleRate * 20),
      maxPendingChunks: Int = 8_192, silenceHoldSeconds: Double? = nil, cleanedCopy: Bool = false
    ) {
      self.silenceHoldSeconds = silenceHoldSeconds
      self.cleanedCopy = cleanedCopy && track == .microphone
      self.meetingID = meetingID
      self.track = track
      self.folder = folder
      self.anchorHostTime = anchorHostTime
      self.segmentSeconds = segmentSeconds
      self.gapThresholdMs = gapThresholdMs
      self.bufferCapacity = bufferCapacity
      self.maxPendingChunks = maxPendingChunks
    }
  }

  public enum WriterError: Error, Equatable {
    /// The meeting folder could not be listed, so the indexes already in use are unknown.
    case inventoryFailed(errno: Int32)
    /// Reserving the segment file failed (errno), or no free index was found.
    case reserveFailed(Int32)
    case createFailed(OSStatus)
    case clientFormatFailed(OSStatus)
    case permissionsFailed
    case writeFailed(OSStatus)
    case disposeFailed(OSStatus)
    case syncFailed(Int32)
    case renameFailed(Int32)
    case directorySyncFailed(Int32)
  }

  /// How a close ended. `timedOut` means only that the deadline passed: the close is still
  /// queued or running and still owns the files (#3972 R18).
  public enum CloseOutcome: Sendable, Equatable {
    case finalized
    case failed
    case timedOut
  }

  /// Counters the recorder reads for status and telemetry. Content-free.
  public struct Health: Sendable, Equatable {
    public var segmentsFinalized = 0
    public var framesWritten = 0
    /// Audio refused because the handoff was full (the disk stalled).
    public var droppedFrames = 0
    /// New segments started because arrival time jumped forward past the gap threshold.
    public var gaps = 0
    /// New segments started because audio was dropped before them.
    public var discontinuities = 0
    /// Audio stamped before the meeting's anchor, trimmed.
    public var preAnchorFrames = 0
    /// Audio handed over after a close or a failure.
    public var rejectedFrames = 0
    /// Microphone frames written as silence (#4248).
    public var silencedFrames = 0
    /// Silence intervals left out because the hold's interval storage was full; their audio was
    /// written as recorded.
    public var silenceIntervalOverflows = 0
    /// Microphone frames that arrived stamped more than the hold's late-arrival bound before
    /// released audio; judged as live (#4248 arrival contract).
    public var silenceLateFrames = 0
    public var failed = false
    /// #4355 PR B: cleaned twins finalized, and whether the cleaned copy stopped (a failed twin,
    /// or a chunk handed over without its copy). Raw writing is never affected by either.
    public var cleanedSegmentsFinalized = 0
    public var cleanedFailed = false
  }

  #if DEBUG
    /// Points in a segment's finalization a test can stop at (#3972 C2a process-death proof).
    package enum Phase: String, Sendable {
      /// The file is closed and its header written; it still has its `.partial` name.
      case disposed
      /// The final file exists; the owner has not been told yet.
      case published
    }
  #endif

  private struct Chunk {
    var offset: Int
    var hostTime: UInt64
    /// Audio was dropped between the previous accepted chunk and this one.
    var afterDrop: Bool
    /// The producer says this chunk does not continue the previous one.
    var sourceBreak: Bool
    /// A cleaned-copy writer only: the producer gave this chunk's cleaned copy.
    var hasCleaned: Bool
  }

  private struct Pending {
    var samples: [Float]
    /// The cleaned copy beside `samples`, sample for sample; empty without `cleanedCopy`.
    var cleaned: [Float]
    var chunks: [Chunk]
    var droppedFrames = 0
    var rejectedFrames = 0
    var dropOpen = false
    var drainScheduled = false
    var accepting = true
  }

  private let config: Configuration
  private let queue: DispatchQueue
  private let pending: OSAllocatedUnfairLock<Pending>
  private let health = OSAllocatedUnfairLock(initialState: Health())
  private let onSegmentFinalized: SegmentHandler
  private let onFailure: FailureHandler
  private let framesPerSegment: Int
  private let gapThresholdSamples: Int
  private let onReleased: ReleasedHandler?
  private let now: @Sendable () -> UInt64
  private let scheduler: ReleaseScheduler
  /// C for the follower: the end of microphone audio released for good; nil before the first.
  private let releasedWatermark = OSAllocatedUnfairLock<MeetingAcquisitionTime?>(initialState: nil)

  // Queue-confined state.
  private var scratchSamples: [Float] = []
  private var scratchCleaned: [Float] = []
  private var scratchChunks: [Chunk] = []
  private var file: ExtAudioFileRef?
  /// #4355 PR B: the open cleaned twin of `file`, and whether the cleaned copy stopped for good.
  private var cleanedFile: ExtAudioFileRef?
  private var cleanedStopped = false
  /// Twins this writer finalized, for the proof written at a clean close.
  private var cleanedFinalized: [MeetingSegmentInfo] = []
  /// Set once the proof is published: a repeated close (`finish` after `finish`, or
  /// `close(until:)` after it) has nothing more to prove.
  private var cleanedProofWritten = false
  private var segmentIndex = 0
  private var indexScanned = false
  private var listingErrno: Int32 = 0
  private var segmentFrames = 0
  private var segmentStartSample = 0
  /// The timeline sample after the last frame written; nil before the first write.
  private var cursorSample: Int?
  /// The current run of contiguous written audio: a new one starts wherever placement does not
  /// continue the cursor (first write, gap, drop, producer break). Segment rollover keeps it.
  private var runIndex = -1
  private var failed = false
  private let silence: MeetingMicrophoneSilence?
  /// The host time the one pending scheduled release is for; nil when none is pending.
  private var releaseScheduledAt: UInt64?
  /// Set by the close: a scheduled release that fires later does nothing.
  private var silenceClosed = false
  /// Run before every release decision (`setSilenceClock`).
  private var silenceClock: MeetingSilenceStep?
  #if DEBUG
    private var phaseHook: (@Sendable (Phase) -> Void)?
  #endif

  public convenience init(
    configuration: Configuration, onSegmentFinalized: @escaping SegmentHandler,
    onFailure: @escaping FailureHandler, onReleased: ReleasedHandler? = nil
  ) {
    self.init(
      configuration: configuration, onSegmentFinalized: onSegmentFinalized, onFailure: onFailure,
      onReleased: onReleased, now: { mach_absolute_time() }, scheduler: .live)
  }

  /// When a held chunk's release runs. `live` is the writer queue at the due host time;
  /// `manual` hands the due time and the release to a test, which runs it when its clock says.
  package enum ReleaseScheduler: Sendable {
    case live
    case manual(@Sendable (UInt64, @escaping @Sendable () -> Void) -> Void)
  }

  /// `now` and `scheduler`: the host clock the hold releases by, and how a release is timed;
  /// tests pass their own.
  package init(
    configuration: Configuration, onSegmentFinalized: @escaping SegmentHandler,
    onFailure: @escaping FailureHandler, onReleased: ReleasedHandler?,
    now: @escaping @Sendable () -> UInt64, scheduler: ReleaseScheduler
  ) {
    self.config = configuration
    self.onReleased = onReleased
    self.now = now
    self.scheduler = scheduler
    // Only the microphone is ever silenced; call sound is written as captured.
    self.silence = (configuration.track == .microphone ? configuration.silenceHoldSeconds : nil)
      .map { hold in
      MeetingMicrophoneSilence(
        recording: configuration.meetingID, holdSeconds: hold,
        sampleCapacity: Int((hold + 2) * MeetingAudioFormat.sampleRate),
        chunkCapacity: configuration.maxPendingChunks, paired: configuration.cleanedCopy)
    }
    self.queue = DispatchQueue(
      label: "com.enviouswispr.meeting.writer.\(configuration.track.fileStem)", qos: .utility)
    var initial = Pending(samples: [], cleaned: [], chunks: [])
    initial.samples.reserveCapacity(configuration.bufferCapacity)
    initial.chunks.reserveCapacity(configuration.maxPendingChunks)
    if configuration.cleanedCopy {
      initial.cleaned.reserveCapacity(configuration.bufferCapacity)
      scratchCleaned.reserveCapacity(configuration.bufferCapacity)
    }
    self.pending = OSAllocatedUnfairLock(initialState: initial)
    scratchSamples.reserveCapacity(configuration.bufferCapacity)
    scratchChunks.reserveCapacity(configuration.maxPendingChunks)
    self.onSegmentFinalized = onSegmentFinalized
    self.onFailure = onFailure
    self.framesPerSegment = max(
      16, Int(configuration.segmentSeconds * MeetingAudioFormat.sampleRate))
    self.gapThresholdSamples = configuration.gapThresholdMs * Self.samplesPerMs
    // Weak: the hold belongs to this writer.
    silence?.beforeRelease = { [weak self] in
      guard let self, let clock = self.silenceClock else { return }
      self.runSilenceStep(clock)
    }
  }

  public var currentHealth: Health { health.withLock { $0 } }

  /// The end of microphone audio the silence hold has released for good (the plan's C): an
  /// interval update can no longer change audio before it. Nil before the first release.
  public var released: MeetingAcquisitionTime? { releasedWatermark.withLock { $0 } }

  /// Runs `step` on the writer's queue, in call order with appends, drains and the close. The
  /// queue's clock is read first (the plan's D), then C, and the intervals `step` returns apply
  /// in the same queue operation, before any later release. A writer without a hold, or one
  /// already closed, ignores it.
  public func applySilenceStep(_ step: @escaping MeetingSilenceStep) {
    guard silence != nil else { return }
    queue.async { [self] in runSilenceStep(step) }
  }

  /// Sets the step run before every release decision, forced releases included (nil removes
  /// it), so expiry is judged at the queue's own time. The writer keeps `step`; it must not keep
  /// the writer.
  public func setSilenceClock(_ step: MeetingSilenceStep?) {
    guard silence != nil else { return }
    queue.async { [self] in silenceClock = step }
  }

  /// Fixed intervals for audio not yet released (tests).
  func setSilencedIntervals(_ intervals: [MeetingSilenceInterval]) {
    applySilenceStep { _, _ in intervals }
  }

  /// The clock adapter: the queue's clock read now, observed rather than acquired.
  private func queueNow() -> MeetingAcquisitionTime {
    MeetingAcquisitionTime(recording: config.meetingID, hostTicks: now(), provenance: .observed)
  }

  private func runSilenceStep(_ step: MeetingSilenceStep) {
    let delivered = queueNow()
    guard let silence, !silenceClosed else { return }
    guard let intervals = step(delivered, silence.released) else { return }
    silence.setIntervals(intervals)
    recordSilenceHealth()
  }

  // MARK: - Producer side (any thread)

  /// Hands 16 kHz mono samples to the writer. `hostTime` is the capture clock's time of the
  /// chunk's FIRST sample. Never blocks on file work. Audio that does not fit the handoff is
  /// counted as dropped, and the next accepted audio starts a new segment at its own time.
  ///
  /// `startsNewRun`: the producer knows this audio does not continue what it handed over before
  /// (the call-sound pipeline's run boundary). It starts a new segment at `hostTime` whatever
  /// the gap, so a break the producer detected is never closed up here.
  ///
  /// `cleaned` (#4355 PR B, `cleanedCopy` writers only): the echo-cleaned copy of exactly these
  /// samples. Nil, or another count, writes the raw audio as always and stops the cleaned copy
  /// for the rest of the recording.
  public func append(
    _ samples: UnsafeBufferPointer<Float>, cleaned: UnsafeBufferPointer<Float>? = nil,
    hostTime: UInt64, startsNewRun: Bool = false
  ) {
    guard !samples.isEmpty else { return }
    let pair = config.cleanedCopy ? cleaned.flatMap { $0.count == samples.count ? $0 : nil } : nil
    // `withLockUnchecked`: the body copies from a caller-owned pointer that never escapes the
    // lock. The append stays inside the capacity reserved at init, so it does not allocate.
    let schedule = pending.withLockUnchecked { state -> Bool in
      guard state.accepting else {
        state.rejectedFrames += samples.count
        return false
      }
      let room = config.bufferCapacity - state.samples.count
      guard room > 0, state.chunks.count < config.maxPendingChunks else {
        state.droppedFrames += samples.count
        state.dropOpen = true
        return false
      }
      let take = min(room, samples.count)
      state.chunks.append(
        Chunk(
          offset: state.samples.count, hostTime: hostTime, afterDrop: state.dropOpen,
          sourceBreak: startsNewRun, hasCleaned: pair != nil))
      state.dropOpen = false
      state.samples.append(contentsOf: UnsafeBufferPointer(rebasing: samples[0..<take]))
      if config.cleanedCopy {
        // Kept the same length as `samples`; a chunk without its copy holds raw here and says so.
        let source = pair ?? samples
        state.cleaned.append(contentsOf: UnsafeBufferPointer(rebasing: source[0..<take]))
      }
      if take < samples.count {
        state.droppedFrames += samples.count - take
        state.dropOpen = true
      }
      if state.drainScheduled { return false }
      state.drainScheduled = true
      return true
    }
    if schedule { queue.async { [self] in drain() } }
  }

  public func append(_ samples: [Float], hostTime: UInt64) {
    samples.withUnsafeBufferPointer { append($0, cleaned: nil, hostTime: hostTime) }
  }

  // MARK: - Owner side

  /// Stops accepting audio, writes what is buffered, and finalizes the open segment. Calling it
  /// again (or after `close`) finalizes nothing twice.
  @discardableResult
  public func finish() async -> CloseOutcome {
    pending.withLock { $0.accepting = false }
    return await withCheckedContinuation {
      (continuation: CheckedContinuation<CloseOutcome, Never>) in
      queue.async { [self] in continuation.resume(returning: closeOnQueue()) }
    }
  }

  /// Returns once every sample appended so far has been written to the open segment, WITHOUT
  /// finalizing it: the on-disk state a crash at this moment would leave. Queue order is the
  /// signal (this block runs after every drain scheduled before it). Held microphone audio is
  /// released first, with the silence intervals known now.
  package func waitUntilWritten() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      queue.async { [self] in
        drain()
        releaseAllHeld()
        continuation.resume()
      }
    }
  }

  /// Quit path (#3972 R18): `finish`, waited for until `deadline`. On `.timedOut` the close is
  /// still queued or running and keeps ownership of the files: nothing else may touch them
  /// until it ends, and a crash leaves its `.caf.partial` for launch recovery. A later close
  /// queues behind it. Must not be called on the writer's own queue.
  public func close(until deadline: DispatchTime) -> CloseOutcome {
    dispatchPrecondition(condition: .notOnQueue(queue))
    pending.withLock { $0.accepting = false }
    let box = OSAllocatedUnfairLock<CloseOutcome?>(initialState: nil)
    let done = DispatchSemaphore(value: 0)
    queue.async { [self] in
      let outcome = closeOnQueue()
      box.withLock { $0 = outcome }
      done.signal()
    }
    guard done.wait(timeout: deadline) == .success else { return .timedOut }
    return box.withLock { $0 } ?? .failed
  }

  /// Whether `close(until:)` ended before `deadline`, whatever its result.
  @discardableResult
  public func closeSynchronously(until deadline: DispatchTime) -> Bool {
    close(until: deadline) != .timedOut
  }

  /// Continues numbering after `highestIndex` (a resumed meeting). The writer also scans its
  /// folder before its first segment and never reuses an index it finds there. Call before the
  /// first `append`; must not be called on the writer's own queue.
  public func resumeNumbering(after highestIndex: Int) {
    queue.sync { segmentIndex = max(segmentIndex, highestIndex) }
  }

  // MARK: - Queue work

  private func closeOnQueue() -> CloseOutcome {
    drain()
    releaseAllHeld()
    silenceClosed = true
    guard !failed else {
      // A failed writer still closes its open file, so the header is as complete as the
      // failure allows; the file keeps its `.partial` name for recovery.
      if let ref = file {
        file = nil
        ExtAudioFileDispose(ref)
      }
      return .failed
    }
    guard finalizeSegment() else { return .failed }
    writeCleanedProof()
    return .finalized
  }

  private func drain() {
    let (dropped, rejected) = pending.withLockUnchecked { state -> (Int, Int) in
      swap(&state.samples, &scratchSamples)
      swap(&state.cleaned, &scratchCleaned)
      swap(&state.chunks, &scratchChunks)
      let counts = (state.droppedFrames, state.rejectedFrames)
      state.droppedFrames = 0
      state.rejectedFrames = 0
      state.drainScheduled = false
      return counts
    }
    if dropped > 0 || rejected > 0 {
      health.withLock {
        $0.droppedFrames += dropped
        $0.rejectedFrames += rejected
      }
    }
    defer {
      scratchSamples.removeAll(keepingCapacity: true)
      scratchCleaned.removeAll(keepingCapacity: true)
      scratchChunks.removeAll(keepingCapacity: true)
    }
    guard !failed, !scratchSamples.isEmpty else { return }
    scratchSamples.withUnsafeBufferPointer { all in
      scratchCleaned.withUnsafeBufferPointer { twins in
      for (i, chunk) in scratchChunks.enumerated() {
        let end = i + 1 < scratchChunks.count ? scratchChunks[i + 1].offset : all.count
        guard end > chunk.offset else { continue }
        let frames = UnsafeBufferPointer(rebasing: all[chunk.offset..<end])
        let twin =
          config.cleanedCopy && chunk.hasCleaned
          ? UnsafeBufferPointer(rebasing: twins[chunk.offset..<end]) : nil
        if config.cleanedCopy, !chunk.hasCleaned { stopCleaned(reason: "copy missing") }
        // The append adapter: the producers hand scalar host ticks without saying how they got
        // them (the microphone estimates from arrival, `MeetingRecorder`; the call-sound tap's
        // validity is not passed through yet), so nothing here may claim hardware acquisition.
        let info = MeetingHeldChunk(
          acquired: MeetingAcquisitionTime(
            recording: config.meetingID, hostTicks: chunk.hostTime, provenance: .estimated),
          afterDrop: chunk.afterDrop, sourceBreak: chunk.sourceBreak)
        if let silence {
          // The hold copies the chunk; nothing keeps a pointer into the handoff buffer.
          silence.accept(
            frames, cleaned: twin, acquired: info.acquired, afterDrop: info.afterDrop,
            sourceBreak: info.sourceBreak, emit: emitHeld)
        } else {
          writeReleased(frames, twin, info)
        }
        if failed { return }
      }
      }
    }
    releaseDueHeld()
  }

  // MARK: - Silence hold (#4248)

  /// One released chunk. C is published first, so anything that sees this chunk downstream
  /// also sees a watermark that covers it.
  private func emitHeld(
    _ frames: UnsafeBufferPointer<Float>, _ cleaned: UnsafeBufferPointer<Float>?,
    _ info: MeetingHeldChunk
  ) {
    if let end = silence?.released { publishReleased(end) }
    guard !failed else { return }
    writeReleased(frames, cleaned, info)
  }

  /// Releases what is due now and schedules the next release; a no-op without a hold.
  private func releaseDueHeld() {
    guard let silence, !silenceClosed else { return }
    silence.releaseDue(now: queueNow(), emit: emitHeld)
    recordSilenceHealth()
    scheduleRelease()
  }

  /// Releases everything held (Stop, close, `waitUntilWritten`).
  private func releaseAllHeld() {
    guard let silence, !silenceClosed else { return }
    silence.releaseAll(emit: emitHeld)
    recordSilenceHealth()
  }

  /// One pending release at a time, for the oldest held chunk's due time. The block holds the
  /// writer weakly and does nothing once the writer closed.
  private func scheduleRelease() {
    // The scheduler adapter: Dispatch and the test scheduler take raw host ticks.
    guard let silence, !silenceClosed, let due = silence.nextDue?.hostTicks else { return }
    if let pending = releaseScheduledAt, pending <= due { return }
    releaseScheduledAt = due
    let fire: @Sendable () -> Void = { [weak self] in
      guard let self, self.releaseScheduledAt == due else { return }
      self.releaseScheduledAt = nil
      self.releaseDueHeld()
    }
    switch scheduler {
    case .live:
      let deadline = DispatchTime(uptimeNanoseconds: AudioConvertHostTimeToNanos(due))
      queue.asyncAfter(deadline: deadline, execute: fire)
    case .manual(let hand):
      hand(due) { [weak self] in self?.queue.async(execute: fire) }
    }
  }

  private func recordSilenceHealth() {
    guard let silence else { return }
    let (end, silenced, overflows, late) = (
      silence.released, silence.silencedFrames, silence.intervalOverflows, silence.lateFrames
    )
    if let end { publishReleased(end) }
    health.withLock {
      $0.silencedFrames = silenced
      $0.silenceIntervalOverflows = overflows
      $0.silenceLateFrames = late
    }
  }

  /// C never moves back: a later end replaces it, an earlier one is ignored.
  private func publishReleased(_ end: MeetingAcquisitionTime) {
    releasedWatermark.withLock { current in
      if current.map({ end.hostTicks > $0.hostTicks }) ?? true { current = end }
    }
  }

  /// Trims audio from before the anchor, writes the rest, and hands what was written to
  /// `onReleased` with its span. The acquisition time moves with the trim; it is never derived
  /// from the written position. A cleaned copy is trimmed and placed with the raw audio; live
  /// words get the cleaned samples while the cleaned copy is being written, raw otherwise.
  private func writeReleased(
    _ chunk: UnsafeBufferPointer<Float>, _ cleanedChunk: UnsafeBufferPointer<Float>?,
    _ info: MeetingHeldChunk
  ) {
    var frames = chunk
    var twin = cleanedChunk
    var acquired = info.acquired
    var arrival = Self.samples(from: config.anchorHostTime, to: info.acquired.hostTicks)
    if arrival < 0 {
      let trim = min(frames.count, -arrival)
      frames = UnsafeBufferPointer(rebasing: frames[trim...])
      twin = twin.map { UnsafeBufferPointer(rebasing: $0[trim...]) }
      arrival += trim
      acquired = MeetingAcquisitionTime(
        recording: acquired.recording,
        hostTicks: acquired.hostTicks &+ MeetingMicrophoneSilence.ticks(forSamples: trim),
        provenance: acquired.provenance)
      health.withLock { $0.preAnchorFrames += trim }
    }
    guard !frames.isEmpty else { return }
    if config.cleanedCopy, twin == nil { stopCleaned(reason: "copy missing") }
    let written = write(
      frames, cleaned: twin, arrival: arrival, afterDrop: info.afterDrop,
      sourceBreak: info.sourceBreak)
    guard let onReleased, let written, written.count > 0,
      let span = MeetingAudioSpan(
        recording: config.meetingID, track: config.track, run: runIndex,
        startSample: written.start, sampleCount: written.count)
    else { return }
    // The cleaned samples only while the cleaned copy is still written: once it stopped, what
    // live words get is what the files hold, raw.
    let published = (!cleanedStopped ? twin : nil) ?? frames
    onReleased(
      UnsafeBufferPointer(rebasing: published[0..<written.count]),
      MeetingReleasedChunk(
        span: span, acquired: acquired, afterDrop: info.afterDrop, sourceBreak: info.sourceBreak))
  }

  /// Writes `frames` and returns the contiguous prefix actually written (its first timeline
  /// sample and count; zero count when nothing was), or nil when placement itself failed.
  @discardableResult
  private func write(
    _ frames: UnsafeBufferPointer<Float>, cleaned twin: UnsafeBufferPointer<Float>?,
    arrival: Int, afterDrop: Bool, sourceBreak: Bool
  ) -> (start: Int, count: Int)? {
    var position: Int
    if let cursor = cursorSample, !afterDrop, !sourceBreak,
      arrival - cursor <= gapThresholdSamples
    {
      position = cursor
    } else {
      if cursorSample != nil {
        health.withLock {
          if afterDrop { $0.discontinuities += 1 } else { $0.gaps += 1 }
        }
      }
      guard finalizeSegment() else { return nil }
      // Never before audio already written, and on a 1 ms boundary.
      let earliest = cursorSample.map { Self.alignUp($0) } ?? 0
      position = max(Self.alignDown(arrival), earliest)
      runIndex += 1
    }
    let start = position
    var offset = 0
    while offset < frames.count {
      if file == nil {
        guard openSegment(at: position) else { return (start, offset) }
      }
      let take = min(framesPerSegment - segmentFrames, frames.count - offset)
      guard writeFrames(UnsafeBufferPointer(rebasing: frames[offset..<(offset + take)])) else {
        return (start, offset)
      }
      // The raw frames are written: the twin follows them, and nothing about it can undo that.
      if let twin { writeCleaned(UnsafeBufferPointer(rebasing: twin[offset..<(offset + take)])) }
      offset += take
      segmentFrames += take
      position += take
      cursorSample = position
      if segmentFrames >= framesPerSegment {
        guard finalizeSegment() else { return (start, offset) }
      }
    }
    return (start, offset)
  }

  private func openSegment(at startSample: Int) -> Bool {
    if !indexScanned {
      // Exclusive creation protects one exact name, not every file sharing an index, so a
      // folder this writer cannot list is a failure, never "nothing there".
      guard let highest = highestOccupiedIndex() else {
        fail(WriterError.inventoryFailed(errno: listingErrno))
        return false
      }
      indexScanned = true
      segmentIndex = max(segmentIndex, highest)
    }
    segmentStartSample = startSample
    // Exclusive reservation: an existing name (final or partial) is skipped, never erased.
    var reserved: URL?
    for _ in 0..<1_000 {
      segmentIndex += 1
      let url = segmentURL(index: segmentIndex, partial: true)
      let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
      if fd >= 0 {
        Darwin.close(fd)
        reserved = url
        break
      }
      let code = errno
      guard code == EEXIST else {
        fail(WriterError.reserveFailed(code))
        return false
      }
    }
    guard let url = reserved else {
      fail(WriterError.reserveFailed(EEXIST))
      return false
    }
    // The erase flag only empties the file this writer just reserved.
    var fileFormat = Self.fileFormat
    var ref: ExtAudioFileRef?
    var status = ExtAudioFileCreateWithURL(
      url as CFURL, kAudioFileCAFType, &fileFormat, nil, AudioFileFlags.eraseFile.rawValue, &ref)
    guard status == noErr, let ref else {
      fail(WriterError.createFailed(status))
      return false
    }
    var clientFormat = Self.clientFormat
    status = ExtAudioFileSetProperty(
      ref, kExtAudioFileProperty_ClientDataFormat,
      UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat)
    guard status == noErr else {
      ExtAudioFileDispose(ref)
      fail(WriterError.clientFormatFailed(status))
      return false
    }
    guard chmod(url.path, 0o600) == 0 else {
      ExtAudioFileDispose(ref)
      fail(WriterError.permissionsFailed)
      return false
    }
    file = ref
    segmentFrames = 0
    openCleaned()
    return true
  }

  private func writeFrames(_ frames: UnsafeBufferPointer<Float>) -> Bool {
    guard let file, let base = frames.baseAddress else { return true }
    var list = AudioBufferList(
      mNumberBuffers: 1,
      mBuffers: AudioBuffer(
        mNumberChannels: 1, mDataByteSize: UInt32(frames.count * MemoryLayout<Float>.size),
        mData: UnsafeMutableRawPointer(mutating: base)))
    let status = ExtAudioFileWrite(file, UInt32(frames.count), &list)
    guard status == noErr else {
      fail(WriterError.writeFailed(status))
      return false
    }
    let written = frames.count
    health.withLock { $0.framesWritten += written }
    return true
  }

  /// Closes, syncs and publishes the open segment. True when there was nothing open or every
  /// step succeeded; false after reporting the failure (the file stays for recovery).
  private func finalizeSegment() -> Bool {
    guard let ref = file else { return !failed }
    file = nil
    let frames = segmentFrames
    segmentFrames = 0
    let partialURL = segmentURL(index: segmentIndex, partial: true)
    let finalURL = segmentURL(index: segmentIndex, partial: false)
    let status = ExtAudioFileDispose(ref)
    guard status == noErr else {
      fail(WriterError.disposeFailed(status))
      return false
    }
    #if DEBUG
      phaseHook?(.disposed)
    #endif
    if let code = Self.fullSync(partialURL) {
      fail(WriterError.syncFailed(code))
      return false
    }
    if renamex_np(partialURL.path, finalURL.path, UInt32(RENAME_EXCL)) != 0 {
      fail(WriterError.renameFailed(errno))
      return false
    }
    if let code = Self.syncDirectory(config.folder) {
      fail(WriterError.directorySyncFailed(code))
      return false
    }
    #if DEBUG
      phaseHook?(.published)
    #endif
    health.withLock { $0.segmentsFinalized += 1 }
    onSegmentFinalized(
      MeetingSegmentInfo(
        index: segmentIndex, fileName: finalURL.lastPathComponent,
        startMs: segmentStartSample / Self.samplesPerMs, frameCount: frames))
    finalizeCleaned(frames: frames)
    return true
  }

  // MARK: - Cleaned copy (#4355 PR B)

  /// Opens the cleaned twin of the segment just opened, at the same index and start. Any failure
  /// stops the cleaned copy; the raw segment is already open and unaffected.
  private func openCleaned() {
    guard config.cleanedCopy, !cleanedStopped else { return }
    let url = segmentURL(index: segmentIndex, partial: true, variant: .cleaned)
    let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else {
      // An existing twin name is not ours to reuse or erase.
      stopCleaned(reason: "reserve errno=\(errno)", removePartial: false)
      return
    }
    Darwin.close(fd)
    var fileFormat = Self.fileFormat
    var ref: ExtAudioFileRef?
    var status = ExtAudioFileCreateWithURL(
      url as CFURL, kAudioFileCAFType, &fileFormat, nil, AudioFileFlags.eraseFile.rawValue, &ref)
    guard status == noErr, let ref else {
      stopCleaned(reason: "create status=\(status)")
      return
    }
    var clientFormat = Self.clientFormat
    status = ExtAudioFileSetProperty(
      ref, kExtAudioFileProperty_ClientDataFormat,
      UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat)
    guard status == noErr, chmod(url.path, 0o600) == 0 else {
      ExtAudioFileDispose(ref)
      stopCleaned(reason: "format status=\(status)")
      return
    }
    cleanedFile = ref
  }

  private func writeCleaned(_ frames: UnsafeBufferPointer<Float>) {
    guard let ref = cleanedFile, let base = frames.baseAddress, !cleanedStopped else { return }
    #if DEBUG
      if cleanedFaultForTesting == .write {
        stopCleaned(reason: "write (test fault)")
        return
      }
    #endif
    var list = AudioBufferList(
      mNumberBuffers: 1,
      mBuffers: AudioBuffer(
        mNumberChannels: 1, mDataByteSize: UInt32(frames.count * MemoryLayout<Float>.size),
        mData: UnsafeMutableRawPointer(mutating: base)))
    let status = ExtAudioFileWrite(ref, UInt32(frames.count), &list)
    if status != noErr { stopCleaned(reason: "write status=\(status)") }
  }

  /// Finalizes the cleaned twin of the raw segment just published, in the same durability order.
  private func finalizeCleaned(frames: Int) {
    guard let ref = cleanedFile, !cleanedStopped else { return }
    cleanedFile = nil
    let partialURL = segmentURL(index: segmentIndex, partial: true, variant: .cleaned)
    let finalURL = segmentURL(index: segmentIndex, partial: false, variant: .cleaned)
    let status = ExtAudioFileDispose(ref)
    #if DEBUG
      if cleanedFaultForTesting == .finalize {
        stopCleaned(reason: "finalize (test fault)")
        return
      }
    #endif
    guard status == noErr else { return stopCleaned(reason: "dispose status=\(status)") }
    if let code = Self.fullSync(partialURL) { return stopCleaned(reason: "sync errno=\(code)") }
    if renamex_np(partialURL.path, finalURL.path, UInt32(RENAME_EXCL)) != 0 {
      return stopCleaned(reason: "rename errno=\(errno)")
    }
    #if DEBUG
      let syncFailure =
        (cleanedFaultForTesting == .afterRename || cleanedFaultForTesting == .afterRenameKeepingTwin)
        ? EIO : Self.syncDirectory(config.folder)
    #else
      let syncFailure = Self.syncDirectory(config.folder)
    #endif
    if let code = syncFailure {
      // The rename happened but is not durable. Removed where possible (it is ours: we just
      // renamed it); whether or not that works, the stop means no proof lists it.
      #if DEBUG
        if cleanedFaultForTesting != .afterRenameKeepingTwin { unlink(finalURL.path) }
      #else
        unlink(finalURL.path)
      #endif
      return stopCleaned(reason: "directory sync errno=\(code)", removePartial: false)
    }
    cleanedFinalized.append(
      MeetingSegmentInfo(
        index: segmentIndex, fileName: finalURL.lastPathComponent,
        startMs: segmentStartSample / Self.samplesPerMs, frameCount: frames))
    health.withLock { $0.cleanedSegmentsFinalized += 1 }
  }

  /// Writes the proof that this writer's cleaned copy finished whole: only at a clean close, only
  /// when no cleaned-copy step failed, in the segment durability order (exclusive create of a
  /// temporary name, write, F_FULLFSYNC, exclusive rename, directory sync). Any failure leaves no
  /// proof, which the final pass reads as "use raw".
  private func writeCleanedProof() {
    guard config.cleanedCopy, !cleanedStopped, !failed, !cleanedProofWritten,
      let first = cleanedFinalized.first, let last = cleanedFinalized.last
    else { return }
    let finalURL = config.folder.appendingPathComponent(
      MeetingSegmentNaming.cleanedProofName(first: first.index, last: last.index))
    let temporary = config.folder.appendingPathComponent(".proof-\(UUID().uuidString).tmp")
    func give(up reason: String) {
      unlink(temporary.path)
      stopCleaned(reason: reason, removePartial: false)
    }
    #if DEBUG
      if cleanedFaultForTesting == .proof { return give(up: "proof (test fault)") }
    #endif
    guard let data = try? JSONEncoder().encode(MeetingCleanedProof(segments: cleanedFinalized))
    else { return give(up: "proof encode") }
    let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else { return give(up: "proof create errno=\(errno)") }
    let wrote = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    Darwin.close(fd)
    guard wrote == data.count else { return give(up: "proof write") }
    if let code = Self.fullSync(temporary) { return give(up: "proof sync errno=\(code)") }
    guard renamex_np(temporary.path, finalURL.path, UInt32(RENAME_EXCL)) == 0 else {
      return give(up: "proof rename errno=\(errno)")
    }
    if let code = Self.syncDirectory(config.folder) {
      unlink(finalURL.path)
      return give(up: "proof directory sync errno=\(code)")
    }
    cleanedProofWritten = true
  }

  /// Stops the cleaned copy for the rest of the recording. Its open twin is closed and, unless it
  /// is not ours (`removePartial` false), its unfinished `.partial` removed, so no incomplete
  /// twin is left to look like a finished one. Raw writing goes on as before.
  private func stopCleaned(reason: String, removePartial: Bool = true) {
    guard config.cleanedCopy, !cleanedStopped else { return }
    cleanedStopped = true
    if let ref = cleanedFile {
      cleanedFile = nil
      ExtAudioFileDispose(ref)
    }
    if removePartial, segmentIndex > 0 {
      unlink(segmentURL(index: segmentIndex, partial: true, variant: .cleaned).path)
    }
    health.withLock { $0.cleanedFailed = true }
  }

  /// The highest index any recognized file of this track already uses, final or partial,
  /// readable or not; 0 for none. Nil when the folder cannot be listed (`listingErrno` set).
  private func highestOccupiedIndex() -> Int? {
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: config.folder.path)
    } catch {
      listingErrno = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)
        .map { Int32($0.code) } ?? EIO
      return nil
    }
    // #3147 PR4B: a compacted file occupies its source's index, so a new segment never reuses it.
    return names.compactMap { MeetingSegmentNaming.parseAny($0) }
      .filter { $0.track == config.track }
      .map(\.index)
      .max() ?? 0
  }

  /// A segment's file, with its start time in the name (#3972 R15).
  private func segmentURL(index: Int, partial: Bool, variant: MeetingSegmentVariant = .raw) -> URL {
    config.folder.appendingPathComponent(
      MeetingSegmentNaming.fileName(
        track: config.track, variant: variant, index: index,
        startMs: segmentStartSample / Self.samplesPerMs, partial: partial))
  }

  private func fail(_ error: Error) {
    guard !failed else { return }
    // The raw audio stopped: no twin may outlive it as if it were complete.
    stopCleaned(reason: "raw writer failed")
    failed = true
    health.withLock { $0.failed = true }
    pending.withLock { $0.accepting = false }
    onFailure(error)
  }

  // MARK: - Test seams

  #if DEBUG
    /// #4355 PR B: a failure injected at the cleaned copy's own boundary (its write, or its
    /// finalization), so a test can prove raw writing does not depend on it.
    package enum CleanedFault: Sendable {
      case write, finalize, afterRename
      /// After the rename, and the cleanup that would remove the twin fails too.
      case afterRenameKeepingTwin
      /// Writing the proof at close fails.
      case proof
    }
    private var cleanedFaultForTesting: CleanedFault?
    package func setCleanedFaultForTesting(_ fault: CleanedFault?) {
      queue.sync { cleanedFaultForTesting = fault }
    }

    /// Runs `hook` on the writer's queue at each finalization phase. Set before the first append.
    package func setPhaseHookForTesting(_ hook: (@Sendable (Phase) -> Void)?) {
      queue.sync { phaseHook = hook }
    }

    /// Returns once every block queued before it ran, without draining or releasing anything.
    package func queueBarrierForTesting() async {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        queue.async { continuation.resume() }
      }
    }

    /// Holds every queued drain and close until `resumeQueueForTesting`.
    package func suspendQueueForTesting() { queue.suspend() }
    package func resumeQueueForTesting() { queue.resume() }

    /// The base address of the buffer `append` currently copies into.
    package func handoffStorageForTesting() -> UInt {
      pending.withLockUnchecked { state in
        state.samples.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
      }
    }
  #endif

  // MARK: - Formats and clocks

  static let samplesPerMs = Int(MeetingAudioFormat.sampleRate) / 1_000

  /// 16 kHz mono signed 16-bit little-endian PCM in the file.
  static let fileFormat = AudioStreamBasicDescription(
    mSampleRate: MeetingAudioFormat.sampleRate, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
    mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
    mBitsPerChannel: 16, mReserved: 0)

  /// 16 kHz mono Float32, what every capture source hands over.
  static let clientFormat = AudioStreamBasicDescription(
    mSampleRate: MeetingAudioFormat.sampleRate, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
    mBitsPerChannel: 32, mReserved: 0)

  /// Timeline samples from `anchor` to `hostTime`; negative before the anchor.
  static func samples(from anchor: UInt64, to hostTime: UInt64) -> Int {
    // 1 s / 16,000 = 62,500 ns exactly; dividing (not multiplying) cannot overflow.
    let nanosPerSample = UInt64(1_000_000_000 / Int(MeetingAudioFormat.sampleRate))
    if hostTime >= anchor {
      return Int(AudioConvertHostTimeToNanos(hostTime - anchor) / nanosPerSample)
    }
    return -Int(AudioConvertHostTimeToNanos(anchor - hostTime) / nanosPerSample)
  }

  static func alignDown(_ sample: Int) -> Int { sample - sample % samplesPerMs }
  static func alignUp(_ sample: Int) -> Int { alignDown(sample + samplesPerMs - 1) }

  /// `F_FULLFSYNC`, or `fsync` where the volume does not support it. Nil on success, else errno.
  static func fullSync(_ url: URL) -> Int32? {
    let fd = Darwin.open(url.path, O_RDONLY)
    guard fd >= 0 else { return errno }
    var result = fcntl(fd, F_FULLFSYNC)
    if result != 0 { result = fsync(fd) }
    let code = result == 0 ? 0 : errno
    let closed = Darwin.close(fd)
    if code != 0 { return code }
    return closed == 0 ? nil : errno
  }

  /// Makes a rename in `folder` durable. Nil on success, else errno.
  static func syncDirectory(_ folder: URL) -> Int32? {
    let fd = Darwin.open(folder.path, O_RDONLY)
    guard fd >= 0 else { return errno }
    let code = fsync(fd) == 0 ? 0 : errno
    let closed = Darwin.close(fd)
    if code != 0 { return code }
    return closed == 0 ? nil : errno
  }
}
