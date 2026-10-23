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
public final class MeetingTrackWriter: @unchecked Sendable {
  public typealias SegmentHandler = @Sendable (MeetingSegmentInfo) -> Void
  public typealias FailureHandler = @Sendable (Error) -> Void

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

    public init(
      meetingID: UUID, track: MeetingTrackKind, folder: URL, anchorHostTime: UInt64,
      segmentSeconds: Double = MeetingAudioFormat.segmentSeconds, gapThresholdMs: Int = 1_500,
      bufferCapacity: Int = Int(MeetingAudioFormat.sampleRate * 20),
      maxPendingChunks: Int = 8_192
    ) {
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
    public var failed = false
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
  }

  private struct Pending {
    var samples: [Float]
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

  // Queue-confined state.
  private var scratchSamples: [Float] = []
  private var scratchChunks: [Chunk] = []
  private var file: ExtAudioFileRef?
  private var segmentIndex = 0
  private var indexScanned = false
  private var listingErrno: Int32 = 0
  private var segmentFrames = 0
  private var segmentStartSample = 0
  /// The timeline sample after the last frame written; nil before the first write.
  private var cursorSample: Int?
  private var failed = false
  #if DEBUG
    private var phaseHook: (@Sendable (Phase) -> Void)?
  #endif

  public init(
    configuration: Configuration, onSegmentFinalized: @escaping SegmentHandler,
    onFailure: @escaping FailureHandler
  ) {
    self.config = configuration
    self.queue = DispatchQueue(
      label: "com.enviouswispr.meeting.writer.\(configuration.track.fileStem)", qos: .utility)
    var initial = Pending(samples: [], chunks: [])
    initial.samples.reserveCapacity(configuration.bufferCapacity)
    initial.chunks.reserveCapacity(configuration.maxPendingChunks)
    self.pending = OSAllocatedUnfairLock(initialState: initial)
    scratchSamples.reserveCapacity(configuration.bufferCapacity)
    scratchChunks.reserveCapacity(configuration.maxPendingChunks)
    self.onSegmentFinalized = onSegmentFinalized
    self.onFailure = onFailure
    self.framesPerSegment = max(
      16, Int(configuration.segmentSeconds * MeetingAudioFormat.sampleRate))
    self.gapThresholdSamples = configuration.gapThresholdMs * Self.samplesPerMs
  }

  public var currentHealth: Health { health.withLock { $0 } }

  // MARK: - Producer side (any thread)

  /// Hands 16 kHz mono samples to the writer. `hostTime` is the capture clock's time of the
  /// chunk's FIRST sample. Never blocks on file work. Audio that does not fit the handoff is
  /// counted as dropped, and the next accepted audio starts a new segment at its own time.
  ///
  /// `startsNewRun`: the producer knows this audio does not continue what it handed over before
  /// (the call-sound pipeline's run boundary). It starts a new segment at `hostTime` whatever
  /// the gap, so a break the producer detected is never closed up here.
  public func append(
    _ samples: UnsafeBufferPointer<Float>, hostTime: UInt64, startsNewRun: Bool = false
  ) {
    guard !samples.isEmpty else { return }
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
          sourceBreak: startsNewRun))
      state.dropOpen = false
      state.samples.append(contentsOf: UnsafeBufferPointer(rebasing: samples[0..<take]))
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
    samples.withUnsafeBufferPointer { append($0, hostTime: hostTime) }
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
  /// signal (this block runs after every drain scheduled before it).
  package func waitUntilWritten() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      queue.async { [self] in
        drain()
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
    guard !failed else {
      // A failed writer still closes its open file, so the header is as complete as the
      // failure allows; the file keeps its `.partial` name for recovery.
      if let ref = file {
        file = nil
        ExtAudioFileDispose(ref)
      }
      return .failed
    }
    return finalizeSegment() ? .finalized : .failed
  }

  private func drain() {
    let (dropped, rejected) = pending.withLockUnchecked { state -> (Int, Int) in
      swap(&state.samples, &scratchSamples)
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
      scratchChunks.removeAll(keepingCapacity: true)
    }
    guard !failed, !scratchSamples.isEmpty else { return }
    scratchSamples.withUnsafeBufferPointer { all in
      for (i, chunk) in scratchChunks.enumerated() {
        let end = i + 1 < scratchChunks.count ? scratchChunks[i + 1].offset : all.count
        guard end > chunk.offset else { continue }
        var frames = UnsafeBufferPointer(rebasing: all[chunk.offset..<end])
        var arrival = Self.samples(from: config.anchorHostTime, to: chunk.hostTime)
        if arrival < 0 {
          let trim = min(frames.count, -arrival)
          frames = UnsafeBufferPointer(rebasing: frames[trim...])
          arrival += trim
          health.withLock { $0.preAnchorFrames += trim }
        }
        guard !frames.isEmpty else { continue }
        write(
          frames, arrival: arrival, afterDrop: chunk.afterDrop, sourceBreak: chunk.sourceBreak)
        if failed { return }
      }
    }
  }

  private func write(
    _ frames: UnsafeBufferPointer<Float>, arrival: Int, afterDrop: Bool, sourceBreak: Bool
  ) {
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
      guard finalizeSegment() else { return }
      // Never before audio already written, and on a 1 ms boundary.
      let earliest = cursorSample.map { Self.alignUp($0) } ?? 0
      position = max(Self.alignDown(arrival), earliest)
    }
    var offset = 0
    while offset < frames.count {
      if file == nil {
        guard openSegment(at: position) else { return }
      }
      let take = min(framesPerSegment - segmentFrames, frames.count - offset)
      guard writeFrames(UnsafeBufferPointer(rebasing: frames[offset..<(offset + take)])) else {
        return
      }
      offset += take
      segmentFrames += take
      position += take
      cursorSample = position
      if segmentFrames >= framesPerSegment {
        guard finalizeSegment() else { return }
      }
    }
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
    return true
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
    return names.compactMap { MeetingSegmentNaming.parse($0) }
      .filter { $0.track == config.track }
      .map(\.index)
      .max() ?? 0
  }

  /// A segment's file, with its start time in the name (#3972 R15).
  private func segmentURL(index: Int, partial: Bool) -> URL {
    config.folder.appendingPathComponent(
      MeetingSegmentNaming.fileName(
        track: config.track, index: index, startMs: segmentStartSample / Self.samplesPerMs,
        partial: partial))
  }

  private func fail(_ error: Error) {
    guard !failed else { return }
    failed = true
    health.withLock { $0.failed = true }
    pending.withLock { $0.accepting = false }
    onFailure(error)
  }

  // MARK: - Test seams

  #if DEBUG
    /// Runs `hook` on the writer's queue at each finalization phase. Set before the first append.
    package func setPhaseHookForTesting(_ hook: (@Sendable (Phase) -> Void)?) {
      queue.sync { phaseHook = hook }
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
