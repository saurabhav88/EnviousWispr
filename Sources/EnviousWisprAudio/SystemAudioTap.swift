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
    /// The output device or tap format changed and capture was rebuilt.
    case rebuilt
    /// A rebuild failed; capture has stopped. Carries the failure's description.
    case rebuildFailed(String)
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
    public var rebuildFailures = 0
    /// Core Audio calls in a teardown or listener change that returned an error.
    public var teardownFailures = 0
    public var listenerFailures = 0
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

  // Queue-confined.
  private var running = false
  private var stopped = false
  private var listening = false
  private var timer: DispatchSourceTimer?

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
    handoffSeconds: Double = 2
  ) {
    self.backend = backend
    self.pipeline = CallSoundPipeline(onSamples: onSamples, handoffSeconds: handoffSeconds)
    self.onEvent = onEvent
    self.drainInterval = drainInterval
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
      try buildOnQueue()
      let forward: @Sendable () -> Void = { [weak self] in
        self?.queue.async { self?.rebuildOnQueue() }
      }
      if backend.installListeners(queue: listenerQueue, onChange: forward) {
        listening = true
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
    queue.sync {
      guard !stopped else { return }
      stopped = true
      if listening {
        if !backend.removeListeners() { counters.withLock { $0.listenerFailures += 1 } }
        listening = false
      }
      teardownOnQueue()
    }
  }

  // MARK: - Queue work

  private func buildOnQueue() throws {
    pipeline.setAccepting(false)
    do {
      let format = try backend.start(ingest: pipeline.ingestBlock)
      try pipeline.configure(format)
      pipeline.setAccepting(true)
    } catch {
      teardownOnQueue()
      throw error
    }
    running = true
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + drainInterval, repeating: drainInterval)
    timer.setEventHandler { [weak self] in self?.pipeline.drain() }
    timer.resume()
    self.timer = timer
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

  private func rebuildOnQueue() {
    guard !stopped, running else { return }
    teardownOnQueue()
    do {
      try buildOnQueue()
      counters.withLock { $0.rebuilds += 1 }
      onEvent(.rebuilt)
    } catch {
      counters.withLock { $0.rebuildFailures += 1 }
      onEvent(.rebuildFailed(String(describing: error)))
    }
  }

  #if DEBUG
    /// Queues a rebuild exactly as a Core Audio listener does.
    func requestRebuildForTesting() { queue.async { [self] in rebuildOnQueue() } }
    /// Runs one drain on the tap queue and returns after it.
    func drainForTesting() { queue.sync { pipeline.drain() } }
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
  }

  struct InputFormat: Equatable, Sendable {
    let sampleRate: Double
  }

  private struct Chunk {
    var offset: Int
    var frames: Int
    var hostTime: UInt64
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

  init(onSamples: @escaping SampleHandler, handoffSeconds: Double = 2) {
    self.onSamples = onSamples
    self.handoffSeconds = handoffSeconds
  }

  var currentLevel: Float { handoff.withLock { $0.level } }

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
    }
    scratchSamples = []
    scratchSamples.reserveCapacity(capacity)
    scratchChunks = []
    scratchChunks.reserveCapacity(maxChunks)
    self.sampleRate = format.sampleRate
    self.converter = converter
    self.inputFormat = input
    runStartHost = nil
  }

  func setAccepting(_ accepting: Bool) { handoff.withLock { $0.accepting = accepting } }

  /// The IOProc's work, for the backend to call from the real-time thread.
  var ingestBlock: @Sendable (UnsafePointer<AudioBufferList>, UInt64) -> Void {
    { [self] list, hostTime in ingest(list, hostTime: hostTime) }
  }

  /// Real-time thread. Down-mixes every channel of every buffer (each buffer's own channel
  /// count and byte size; nothing past a buffer's end is read) into reserved storage. No
  /// allocation, logging, conversion or dispatch.
  func ingest(_ list: UnsafePointer<AudioBufferList>, hostTime: UInt64) {
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
    var frames = Int.max
    var totalChannels = 0
    var readable = buffers.count > 0
    for buffer in buffers {
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
      guard readable else {
        state.unreadableBuffers += 1
        return
      }
      guard frames > 0, frames != Int.max else { return }
      state.framesCaptured += frames
      let room = state.capacity - state.samples.count
      guard room > 0, state.chunks.count < state.maxChunks else {
        state.droppedFrames += frames
        return
      }
      let take = min(room, frames)
      state.chunks.append(Chunk(offset: state.samples.count, frames: take, hostTime: hostTime))
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
    // Two buffers continue one another when the later one starts within 4 ms of where the
    // earlier one ends.
    let tolerance = Self.ticks(seconds: 0.004)
    for chunk in scratchChunks {
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
}

enum SystemAudioTapFormatError: Error {
  case unusable
}

// MARK: - Core Audio backend

/// The Core Audio objects behind a tap. A protocol so the tap's lifecycle can be driven without
/// them in tests.
protocol CallSoundBackend: AnyObject {
  /// Creates and starts the tap, aggregate and IOProc, delivering buffers to `ingest`. On a
  /// throw, everything it created is already released.
  func start(
    ingest: @escaping @Sendable (UnsafePointer<AudioBufferList>, UInt64) -> Void
  ) throws -> CallSoundPipeline.InputFormat
  /// Stops and releases everything in Apple's order. Returns how many calls failed. Repeatable.
  func stop() -> Int
  /// Watches the default output device and the tap's format; `onChange` runs on `queue`.
  func installListeners(queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) -> Bool
  func removeListeners() -> Bool
}

@available(macOS 14.2, *)
final class CoreAudioCallSoundBackend: CallSoundBackend {
  typealias ListenerCall = (
    AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>, DispatchQueue?,
    @escaping AudioObjectPropertyListenerBlock
  ) -> OSStatus

  private let addListener: ListenerCall
  private let removeListener: ListenerCall

  /// The listener calls are parameters only so a test can make one fail.
  init(
    addListener: @escaping ListenerCall = AudioObjectAddPropertyListenerBlock,
    removeListener: @escaping ListenerCall = AudioObjectRemovePropertyListenerBlock
  ) {
    self.addListener = addListener
    self.removeListener = removeListener
  }

  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var ioProcID: AudioDeviceIOProcID?
  private var deviceStarted = false
  private var listeners:
    [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
  private var listenerQueue: DispatchQueue?
  private var onChange: (@Sendable () -> Void)?

  func start(
    ingest: @escaping @Sendable (UnsafePointer<AudioBufferList>, UInt64) -> Void
  ) throws -> CallSoundPipeline.InputFormat {
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
        let host =
          inputTime.pointee.mFlags.contains(.hostTimeValid)
          ? inputTime.pointee.mHostTime : mach_absolute_time()
        ingest(input, host)
      }
      try Self.check(
        AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil, block), "create_io_proc")
      try Self.check(AudioDeviceStart(aggregateID, ioProcID), "start_aggregate")
      deviceStarted = true
      // A rebuilt tap is a new object: watch its format too once listeners are installed.
      if onChange != nil, !add(tapID, Self.address(kAudioTapPropertyFormat)) {
        throw SystemAudioTap.TapError.status(operation: "install_format_listener", value: -1)
      }
      return CallSoundPipeline.InputFormat(sampleRate: format.mSampleRate)
    } catch {
      _ = stop()
      throw error
    }
  }

  func stop() -> Int {
    var failures = 0
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
      // The format listener names this tap; it goes with it.
      failures += removeListeners(on: tapID)
      if AudioHardwareDestroyProcessTap(tapID) != noErr { failures += 1 }
      tapID = AudioObjectID(kAudioObjectUnknown)
    }
    return failures
  }

  func installListeners(queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) -> Bool {
    listenerQueue = queue
    self.onChange = onChange
    let system = AudioObjectID(kAudioObjectSystemObject)
    var installed = add(system, Self.address(kAudioHardwarePropertyDefaultOutputDevice))
    if installed, tapID != kAudioObjectUnknown {
      installed = add(tapID, Self.address(kAudioTapPropertyFormat))
    }
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
    onChange = nil
    return failures == 0
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

  private func add(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
    guard let onChange, let listenerQueue else { return false }
    var address = address
    let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
    guard addListener(object, &address, listenerQueue, block) == noErr else { return false }
    listeners.append((object, address, block))
    return true
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

  private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress
  {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
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

  private static func readTapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
    var result = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var property = address(kAudioTapPropertyFormat)
    try check(AudioObjectGetPropertyData(tap, &property, 0, nil, &size, &result), "read_tap_format")
    return result
  }
}
