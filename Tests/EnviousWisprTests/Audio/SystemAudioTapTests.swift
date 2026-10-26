@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Testing
import os

@testable import EnviousWisprAudio
@testable import EnviousWisprCore

/// #3972 R2: when these fail, the call side of a meeting is garbled, shifted in time, silently
/// incomplete, or capture hangs or restarts after the user pressed Stop.
@Suite("SystemAudioTap", .tags(.productOutcome))
struct SystemAudioTapTests {

  // MARK: - Fixtures

  private final class Output: Sendable {
    let samples = OSAllocatedUnfairLock<[Float]>(initialState: [])
    let hostTimes = OSAllocatedUnfairLock<[UInt64]>(initialState: [])
    let newRuns = OSAllocatedUnfairLock<[Bool]>(initialState: [])
    var handler: CallSoundPipeline.SampleHandler {
      { buffer, host, startsNewRun in
        let copy = Array(buffer)
        self.samples.withLock { $0.append(contentsOf: copy) }
        self.hostTimes.withLock { $0.append(host) }
        self.newRuns.withLock { $0.append(startsNewRun) }
      }
    }
  }

  private func pipeline(rate: Double, _ output: Output, handoffSeconds: Double = 2) throws
    -> CallSoundPipeline
  {
    let p = CallSoundPipeline(onSamples: output.handler, handoffSeconds: handoffSeconds)
    try p.configure(.init(sampleRate: rate))
    p.setAccepting(true)
    return p
  }

  /// Hands `buffers` (each one interleaved with `channels[i]` channels) to the pipeline as one
  /// IOProc callback.
  private func ingest(
    _ p: CallSoundPipeline, buffers: [[Float]], channels: [Int], host: UInt64,
    nilData: Bool = false
  ) {
    let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
    defer { free(list.unsafeMutablePointer) }
    var storage: [UnsafeMutableBufferPointer<Float>] = []
    for (i, data) in buffers.enumerated() {
      let memory = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(1, data.count))
      _ = memory.initialize(from: data)
      storage.append(memory)
      list[i] = AudioBuffer(
        mNumberChannels: UInt32(channels[i]), mDataByteSize: UInt32(data.count * 4),
        mData: nilData ? nil : UnsafeMutableRawPointer(memory.baseAddress))
    }
    defer { storage.forEach { $0.deallocate() } }
    p.ingest(UnsafePointer(list.unsafeMutablePointer), hostTime: host)
  }

  private func sine(_ n: Int, rate: Double, hz: Double = 300, amplitude: Float = 0.5, from: Int = 0)
    -> [Float]
  {
    (from..<(from + n)).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
  }

  private func ticks(_ seconds: Double) -> UInt64 { CallSoundPipeline.ticks(seconds: seconds) }

  /// Feeds one second of `mono(i)` as IOProc callbacks of 512 frames with contiguous times.
  private func feedSecond(
    _ p: CallSoundPipeline, rate: Double, build: (_ frames: Range<Int>) -> ([[Float]], [Int])
  ) {
    let total = Int(rate)
    var at = 0
    let start: UInt64 = 1_000_000
    while at < total {
      let n = min(512, total - at)
      let (buffers, channels) = build(at..<(at + n))
      ingest(p, buffers: buffers, channels: channels, host: start + ticks(Double(at) / rate))
      at += n
    }
    p.drain()
    p.finishRun()
  }

  /// The largest difference between `got` and a 16 kHz 300 Hz sine of amplitude 0.5, at the
  /// best alignment within the converter's delay, over the middle of the second.
  private func errorAgainstIdeal(_ got: [Float]) -> Float {
    let ideal = sine(16_000 + 200, rate: 16_000)
    var best = Float.infinity
    for lag in -64...64 {
      var worst: Float = 0
      for i in 2_000..<14_000 where i + lag >= 0 && i + lag < ideal.count && i < got.count {
        worst = max(worst, abs(got[i] - ideal[i + lag]))
      }
      best = min(best, worst)
    }
    return best
  }

  // MARK: - Data path

  @Test("interleaved stereo at 48 kHz becomes the right 16 kHz mono signal")
  func interleavedStereoDownmixAndResample() throws {
    let output = Output()
    let p = try pipeline(rate: 48_000, output)
    feedSecond(p, rate: 48_000) { range in
      let s = sine(range.count, rate: 48_000, from: range.lowerBound)
      return ([s.flatMap { [$0, $0] }], [2])
    }
    let got = output.samples.withLock { $0 }
    #expect(abs(got.count - 16_000) <= 32, "\(got.count) samples for one second")
    #expect(errorAgainstIdeal(got) < 0.02)
    #expect(p.health.discontinuities == 0)
  }

  @Test("two non-interleaved buffers are each read with their own channel count and mixed")
  func nonInterleavedBuffersMix() throws {
    let output = Output()
    let p = try pipeline(rate: 48_000, output)
    feedSecond(p, rate: 48_000) { range in
      let s = sine(range.count, rate: 48_000, from: range.lowerBound)
      return ([s.map { $0 * 2 }, [Float](repeating: 0, count: range.count)], [1, 1])
    }
    let got = output.samples.withLock { $0 }
    #expect(abs(got.count - 16_000) <= 32)
    #expect(errorAgainstIdeal(got) < 0.02)
  }

  @Test("44.1 kHz and 96 kHz sources both give about 16,000 samples a second of the right signal")
  func supportedRates() throws {
    for rate in [44_100.0, 96_000.0] {
      let output = Output()
      let p = try pipeline(rate: rate, output)
      feedSecond(p, rate: rate) { range in
        ([sine(range.count, rate: rate, from: range.lowerBound)], [1])
      }
      let got = output.samples.withLock { $0 }
      #expect(abs(got.count - 16_000) <= 32, "rate \(rate): \(got.count)")
      #expect(errorAgainstIdeal(got) < 0.02, "rate \(rate)")
    }
  }

  @Test("buffers of different lengths are read only up to the shortest; nothing past an end")
  func shortestBufferBoundsTheRead() throws {
    let output = Output()
    let p = try pipeline(rate: 48_000, output)
    ingest(
      p, buffers: [[Float](repeating: 0.1, count: 100), [Float](repeating: 0.1, count: 60)],
      channels: [1, 1], host: 1_000)
    #expect(p.health.framesCaptured == 60)
  }

  @Test("a buffer with no data is counted as unreadable, never read")
  func unreadableBufferIsCounted() throws {
    let output = Output()
    let p = try pipeline(rate: 48_000, output)
    ingest(p, buffers: [[0.1, 0.1]], channels: [1], host: 1_000, nilData: true)
    #expect(p.health.unreadableBuffers == 1)
    #expect(p.health.framesCaptured == 0)
  }

  @Test("a break in the buffers' times ends the run; the next run starts at its own time")
  func discontinuityKeepsEachRunsTime() throws {
    let output = Output()
    let p = try pipeline(rate: 48_000, output)
    let t0: UInt64 = 5_000_000
    ingest(p, buffers: [sine(4_800, rate: 48_000)], channels: [1], host: t0)
    let later = t0 + ticks(0.5)
    ingest(p, buffers: [sine(4_800, rate: 48_000)], channels: [1], host: later)
    p.drain()
    p.finishRun()
    #expect(p.health.discontinuities == 1)
    let hosts = output.hostTimes.withLock { $0 }
    #expect(hosts.first == t0)
    #expect(hosts.contains(later), "the second run must be stamped with its own time")
    let flags = output.newRuns.withLock { $0 }
    #expect(flags.first == false)
    #expect(zip(hosts, flags).filter(\.1).map(\.0) == [later], "only the second run is marked new")
    let total = output.samples.withLock { $0 }.count
    #expect(total == 3_200, "both runs delivered in full, each with its tail: \(total)")
  }

  @Test("a full handoff keeps what fits and counts every frame it could not keep")
  func fullHandoffCountsDrops() throws {
    let output = Output()
    // 0.01 s at 48 kHz = room for 480 frames.
    let p = try pipeline(rate: 48_000, output, handoffSeconds: 0.01)
    ingest(p, buffers: [[Float](repeating: 0.1, count: 512)], channels: [1], host: 1_000)
    ingest(p, buffers: [[Float](repeating: 0.1, count: 512)], channels: [1], host: 2_000)
    #expect(p.health.droppedFrames == 32 + 512)
    #expect(p.health.framesCaptured == 1_024)
  }

  @Test("buffers arriving while not accepting are ignored entirely")
  func notAcceptingIgnores() throws {
    let output = Output()
    let p = try pipeline(rate: 48_000, output)
    p.setAccepting(false)
    ingest(p, buffers: [[Float](repeating: 0.1, count: 512)], channels: [1], host: 1_000)
    #expect(p.health.framesCaptured == 0)
  }

  // MARK: - Lifecycle

  private enum FakeError: Error { case startFailed }

  private final class FakeBackend: CallSoundBackend, @unchecked Sendable {
    let lock = NSLock()
    var starts = 0
    var stops = 0
    var running = false
    var failStartNumber: Int?
    var failListeners = false
    var ingest: (@Sendable (UnsafePointer<AudioBufferList>, UInt64, Bool) -> Void)?
    var onChange: (@Sendable () -> Void)?
    var onNotice: (@Sendable (CallSoundNotice) -> Void)?
    var rate: Double = 48_000
    var diagnostics = CallSoundCaptureDiagnostics()

    func start(
      ingest: @escaping @Sendable (UnsafePointer<AudioBufferList>, UInt64, Bool) -> Void
    ) throws -> CallSoundPipeline.InputFormat {
      lock.lock()
      defer { lock.unlock() }
      starts += 1
      if failStartNumber == starts { throw FakeError.startFailed }
      running = true
      self.ingest = ingest
      return .init(sampleRate: rate)
    }

    func captureDiagnostics() -> CallSoundCaptureDiagnostics {
      lock.lock()
      defer { lock.unlock() }
      return diagnostics
    }

    func refreshDiagnostics() -> CallSoundCaptureDiagnostics { captureDiagnostics() }

    func stop() -> Int {
      lock.lock()
      defer { lock.unlock() }
      stops += 1
      running = false
      return 0
    }

    func installListeners(
      queue: DispatchQueue, onChange: @escaping @Sendable () -> Void,
      onNotice: @escaping @Sendable (CallSoundNotice) -> Void
    ) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      self.onChange = onChange
      self.onNotice = onNotice
      return !failListeners
    }

    func removeListeners() -> Bool { true }

    var snapshot: (starts: Int, running: Bool) {
      lock.lock()
      defer { lock.unlock() }
      return (starts, running)
    }
  }

  private final class Events: Sendable {
    let list = OSAllocatedUnfairLock<[String]>(initialState: [])
  }

  @available(macOS 14.2, *)
  private func tap(_ backend: FakeBackend, _ output: Output, _ events: Events) -> SystemAudioTap {
    SystemAudioTap(
      backend: backend, onSamples: output.handler,
      onEvent: { event in
        switch event {
        case .rebuilt: events.list.withLock { $0.append("rebuilt") }
        case .rebuildFailed: events.list.withLock { $0.append("rebuildFailed") }
        }
      },
      drainInterval: .seconds(3_600))
  }

  #if DEBUG
    @Test("stop wins over a queued rebuild and a late listener: nothing restarts, nothing hangs")
    func stopBeatsQueuedRebuild() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = FakeBackend()
      let output = Output()
      let events = Events()
      let tap = tap(backend, output, events)
      try tap.start()
      tap.requestRebuildForTesting()
      tap.stop()
      let startsAtStop = backend.snapshot.starts
      // A listener firing after stop, and another queued rebuild, must not resurrect capture.
      backend.onChange?()
      tap.requestRebuildForTesting()
      tap.drainForTesting()
      #expect(backend.snapshot.starts == startsAtStop)
      #expect(!backend.snapshot.running)
      #expect(throws: SystemAudioTap.TapError.stopped) { try tap.start() }
      tap.stop()
    }

    @Test("a failed rebuild is reported once and leaves capture stopped")
    func failedRebuildIsReported() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = FakeBackend()
      backend.failStartNumber = 2
      let output = Output()
      let events = Events()
      let tap = tap(backend, output, events)
      try tap.start()
      tap.requestRebuildForTesting()
      tap.drainForTesting()
      #expect(events.list.withLock { $0 } == ["rebuildFailed"])
      #expect(tap.health.rebuildFailures == 1)
      #expect(!backend.snapshot.running)
      tap.stop()
    }

    @Test("a rebuild drains the old audio with the old converter, then captures again")
    func rebuildKeepsAudioAndRestarts() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = FakeBackend()
      let output = Output()
      let events = Events()
      let tap = tap(backend, output, events)
      try tap.start()
      let ingest = try #require(backend.ingest)
      let samples = [Float](repeating: 0.25, count: 4_800)
      try deliver(samples, to: ingest, host: 1_000_000)
      tap.requestRebuildForTesting()
      tap.drainForTesting()
      #expect(events.list.withLock { $0 } == ["rebuilt"])
      #expect(backend.snapshot.starts == 2)
      #expect(abs(output.samples.withLock { $0 }.count - 1_600) <= 32)
      tap.stop()
    }

    @Test("a listener install that fails halfway removes the listener that did install")
    func failedListenerInstallRollsBack() throws {
      guard #available(macOS 14.2, *) else { return }
      let adds = OSAllocatedUnfairLock(initialState: 0)
      let removes = OSAllocatedUnfairLock(initialState: 0)
      let backend = CoreAudioCallSoundBackend(
        addListener: { _, _, _, _ in
          let count = adds.withLock { value -> Int in
            value += 1
            return value
          }
          return count == 1 ? noErr : OSStatus(kAudioHardwareUnspecifiedError)
        },
        removeListener: { _, _, _, _ in
          removes.withLock { $0 += 1 }
          return noErr
        })
      backend.setTapObjectForTesting(AudioObjectID(4_242))
      let installed = backend.installListeners(
        queue: DispatchQueue(label: "test.listeners"), onChange: {}, onNotice: { _ in })
      #expect(!installed)
      #expect(adds.withLock { $0 } == 2)
      #expect(removes.withLock { $0 } == 1, "the system listener that installed is removed")
      #expect(backend.listenerCountForTesting == 0)
    }
  #endif

  @Test("start twice is refused; a failed start or listener install leaves nothing running")
  func startFailuresCleanUp() throws {
    guard #available(macOS 14.2, *) else { return }
    let output = Output()
    let events = Events()
    let failing = FakeBackend()
    failing.failStartNumber = 1
    #expect(throws: FakeError.self) { try tap(failing, output, events).start() }
    #expect(!failing.snapshot.running)

    let noListeners = FakeBackend()
    noListeners.failListeners = true
    let tapWithoutListeners = tap(noListeners, output, events)
    #expect(throws: (any Error).self) { try tapWithoutListeners.start() }
    #expect(!noListeners.snapshot.running)
    #expect(tapWithoutListeners.health.listenerFailures == 1)

    let ok = FakeBackend()
    let running = tap(ok, output, events)
    try running.start()
    #expect(throws: SystemAudioTap.TapError.alreadyStarted) { try running.start() }
    running.stop()
    running.stop()
    #expect(!ok.snapshot.running)
  }

  @Test("callbacks that arrive after stop are ignored")
  func staleCallbacksAreIgnored() throws {
    guard #available(macOS 14.2, *) else { return }
    let backend = FakeBackend()
    let output = Output()
    let events = Events()
    let tap = tap(backend, output, events)
    try tap.start()
    let ingest = try #require(backend.ingest)
    tap.stop()
    try deliver([Float](repeating: 0.25, count: 512), to: ingest, host: 1_000)
    #expect(tap.health.pipeline.framesCaptured == 0)
  }

  private func deliver(
    _ samples: [Float], to ingest: @Sendable (UnsafePointer<AudioBufferList>, UInt64, Bool) -> Void,
    host: UInt64
  ) throws {
    let list = AudioBufferList.allocate(maximumBuffers: 1)
    defer { free(list.unsafeMutablePointer) }
    var copy = samples
    copy.withUnsafeMutableBufferPointer { memory in
      list[0] = AudioBuffer(
        mNumberChannels: 1, mDataByteSize: UInt32(memory.count * 4),
        mData: UnsafeMutableRawPointer(memory.baseAddress))
      ingest(UnsafePointer(list.unsafeMutablePointer), host, true)
    }
  }
}

/// #4117: when these fail, the `CALL_SOUND` diagnostics misreport what the call-sound capture
/// receives (its rate, buffer layout, or which Core Audio notifications arrive), so a headset
/// that changes the capture rate cannot be diagnosed from the log.
@Suite("SystemAudioTap diagnostics (#4117)", .tags(.observabilityContract))
struct SystemAudioTapDiagnosticsTests {

  private final class Sink: Sendable {
    let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
    var log: @Sendable (String) -> Void { { line in self.lines.withLock { $0.append(line) } } }
    func matching(_ prefix: String) -> [String] { lines.withLock { $0 }.filter { $0.hasPrefix(prefix) } }
  }

  private func pipeline(rate: Double, handoffSeconds: Double = 2) throws -> CallSoundPipeline {
    let p = CallSoundPipeline(onSamples: { _, _, _ in }, handoffSeconds: handoffSeconds)
    try p.configure(.init(sampleRate: rate))
    p.setAccepting(true)
    return p
  }

  private func ticks(_ seconds: Double) -> UInt64 { CallSoundPipeline.ticks(seconds: seconds) }

  /// One IOProc callback of `frames` mono frames.
  private func ingest(
    _ p: CallSoundPipeline, frames: Int, host: UInt64, valid: Bool = true, channels: [UInt32] = [1]
  ) {
    let list = AudioBufferList.allocate(maximumBuffers: channels.count)
    defer { free(list.unsafeMutablePointer) }
    var memories: [UnsafeMutableBufferPointer<Float>] = []
    for (i, ch) in channels.enumerated() {
      let count = max(1, frames * Int(ch))
      let memory = UnsafeMutableBufferPointer<Float>.allocate(capacity: count)
      memory.initialize(repeating: 0.1)
      memories.append(memory)
      list[i] = AudioBuffer(
        mNumberChannels: ch, mDataByteSize: UInt32(frames * Int(ch) * 4),
        mData: UnsafeMutableRawPointer(memory.baseAddress))
    }
    defer { memories.forEach { $0.deallocate() } }
    p.ingest(UnsafePointer(list.unsafeMutablePointer), hostTime: host, hostTimeValid: valid)
  }

  /// Feeds `lengths` as contiguous buffers that truly run at `actualRate`; returns the next start.
  @discardableResult
  private func feed(
    _ p: CallSoundPipeline, lengths: [Int], actualRate: Double, from start: UInt64 = 10_000_000
  ) -> UInt64 {
    var frames = 0
    for n in lengths {
      ingest(p, frames: n, host: start + ticks(Double(frames) / actualRate))
      frames += n
    }
    return start + ticks(Double(frames) / actualRate)
  }

  @Test("the meter excludes the closing buffer's frames: a large closing buffer does not bias the rate")
  func endpointArithmetic() throws {
    let p = try pipeline(rate: 48_000)
    // 25 buffers of 480 frames at 24 kHz span exactly 0.5 s; a 4,800-frame buffer closes the
    // window. Counting it would read 33,600 Hz.
    feed(p, lengths: Array(repeating: 480, count: 25) + [4_800, 960, 240], actualRate: 24_000)
    p.drain()
    let observed = p.inputRateObservation
    #expect(observed.windowsMeasured == 1)
    let rate = try #require(observed.lastRate)
    #expect(abs(rate - 24_000) < 24, "measured \(rate)")
  }

  @Test("480 frames every 20 ms configured at 48 kHz: every buffer breaks the run, the meter still reads 24 kHz")
  func callProfileShapeIsMeasuredAcrossRunBreaks() throws {
    let output = OSAllocatedUnfairLock(initialState: 0)
    let p = CallSoundPipeline(onSamples: { buffer, _, _ in
      let count = buffer.count
      output.withLock { $0 += count }
    })
    try p.configure(.init(sampleRate: 48_000))
    p.setAccepting(true)
    feed(p, lengths: Array(repeating: 480, count: 56), actualRate: 24_000)
    p.drain()
    p.finishRun()
    // The defect this issue fixes, reproduced: one run per buffer, 160 samples per 20 ms buffer.
    #expect(p.health.discontinuities == 55)
    let delivered = output.withLock { $0 }
    #expect(abs(delivered - 56 * 160) <= 56 * 8, "\(delivered) samples from 56 buffers")
    let rate = try #require(p.inputRateObservation.lastRate)
    #expect(abs(rate - 24_000) < 24, "measured \(rate) while configured at 48 kHz")
    #expect(p.inputRateObservation.windowsMeasured == 2)
  }

  @Test("a healthy 48 kHz capture measures 48 kHz with nothing invalidated")
  func healthyRate() throws {
    let p = try pipeline(rate: 48_000)
    feed(p, lengths: Array(repeating: 512, count: 110), actualRate: 48_000)
    p.drain()
    let observed = p.inputRateObservation
    let rate = try #require(observed.lastRate)
    #expect(abs(rate - 48_000) < 48)
    #expect(observed.invalidTimestamp == 0 && observed.nonIncreasing == 0 && observed.inputLoss == 0)
    #expect(p.health.discontinuities == 0)
  }

  @Test("no valid acquisition time, a time that does not advance, and lost input each abandon the window")
  func invalidObservationsAreCountedNotMeasured() throws {
    let invalid = try pipeline(rate: 24_000)
    for i in 0..<40 { ingest(invalid, frames: 480, host: 1_000 + ticks(Double(i) * 0.02), valid: false) }
    invalid.drain()
    #expect(invalid.inputRateObservation.lastRate == nil)
    #expect(invalid.inputRateObservation.invalidTimestamp == 40)

    let backwards = try pipeline(rate: 24_000)
    let t0: UInt64 = 50_000_000
    ingest(backwards, frames: 480, host: t0)
    ingest(backwards, frames: 480, host: t0)
    ingest(backwards, frames: 480, host: t0 - ticks(0.01))
    backwards.drain()
    #expect(backwards.inputRateObservation.nonIncreasing == 2)
    #expect(backwards.inputRateObservation.lastRate == nil)

    // Room for 0.03 s at 24 kHz = 720 frames: the second buffer is cut short, the third lost.
    let lossy = try pipeline(rate: 24_000, handoffSeconds: 0.03)
    ingest(lossy, frames: 480, host: t0)
    ingest(lossy, frames: 480, host: t0 + ticks(0.02))
    ingest(lossy, frames: 480, host: t0 + ticks(0.04))
    lossy.drain()
    ingest(lossy, frames: 480, host: t0 + ticks(0.06))
    lossy.drain()
    #expect(lossy.inputRateObservation.inputLoss == 2, "one truncated, then one after a lost buffer")
    #expect(lossy.inputRateObservation.lastRate == nil)
  }

  @Test("a new configuration (capture generation) starts the window over")
  func configureResetsTheWindow() throws {
    let p = try pipeline(rate: 48_000)
    feed(p, lengths: Array(repeating: 480, count: 15), actualRate: 24_000)
    p.drain()
    p.finishRun()
    try p.configure(.init(sampleRate: 48_000))
    feed(p, lengths: Array(repeating: 480, count: 15), actualRate: 24_000, from: 90_000_000)
    p.drain()
    #expect(p.inputRateObservation.windowsMeasured == 0, "0.3 s + 0.3 s never joins across generations")
  }

  @Test("the buffer layout is reported when new in a configuration and whenever it changes")
  func layoutOncePerConfiguration() throws {
    let p = try pipeline(rate: 48_000)
    #expect(p.takeNewLayout() == nil)
    ingest(p, frames: 256, host: 1_000, channels: [2, 1])
    #expect(p.takeNewLayout() == .init(buffers: 2, channels: [2, 1]))
    ingest(p, frames: 256, host: 2_000, channels: [2, 1])
    #expect(p.takeNewLayout() == nil, "an unchanged layout is not reported again")
    ingest(p, frames: 256, host: 2_500, channels: [1])
    #expect(p.takeNewLayout() == .init(buffers: 1, channels: [1]), "a changed layout is")
    p.drain()
    p.finishRun()
    try p.configure(.init(sampleRate: 48_000))
    ingest(p, frames: 256, host: 3_000, channels: [1])
    #expect(p.takeNewLayout() == .init(buffers: 1, channels: [1]))
  }

  @Test("streams map to buffers only when count and channels agree; anything else is unresolved")
  func streamToBufferMapping() {
    let stream = CallSoundCaptureDiagnostics.Stream(
      id: 7, sampleRate: 24_000, formatID: kAudioFormatLinearPCM, formatFlags: 9, channels: 2,
      bitsPerChannel: 32, bytesPerFrame: 8)
    let one = CallSoundCaptureDiagnostics(inputStreams: [stream])
    #expect(one.mapping(to: .init(buffers: 1, channels: [2])) == "layoutMatches(rate=24000.0)")
    #expect(one.mapping(to: .init(buffers: 2, channels: [2, 2])).hasPrefix("unresolved(streams=1"))
    #expect(one.mapping(to: .init(buffers: 1, channels: [1])) == "unresolved(channels-differ)")
    #expect(
      CallSoundCaptureDiagnostics().mapping(to: .init(buffers: 1, channels: [2]))
        == "unresolved(streams-unreadable)")
    #expect(
      CallSoundCaptureDiagnostics(inputStreams: []).mapping(to: .init(buffers: 0, channels: []))
        == "unresolved(no-input-streams)")
    var unreadable = stream
    unreadable.sampleRate = nil
    unreadable.readStatus = -50
    let failed = CallSoundCaptureDiagnostics(inputStreams: [unreadable])
    #expect(failed.mapping(to: .init(buffers: 1, channels: [2])) == "unresolved(format-unreadable 7)")
    #expect(failed.describe().contains("7:unreadable(-50)/2ch"))
    #expect(one.describe().contains("7:24000.0Hz/2ch/lpcm"))
    #expect(one.describe().hasSuffix("watch=ok"))
    #expect(
      CallSoundCaptureDiagnostics(
        watchProblems: [
          .init(text: "register x object=1 failed", count: 2, current: true),
          .init(text: "inputStreams unreadable", count: 1, current: false),
        ]
      ).describe()
        .hasSuffix("watch=[register x object=1 failed x2 current; inputStreams unreadable x1 resolved]"))
  }

  #if DEBUG
    private final class Backend: CallSoundBackend, @unchecked Sendable {
      let lock = NSLock()
      var starts = 0
      var rate: Double = 48_000
      var diagnostics = CallSoundCaptureDiagnostics()
      var ingest: (@Sendable (UnsafePointer<AudioBufferList>, UInt64, Bool) -> Void)?
      var onNotice: (@Sendable (CallSoundNotice) -> Void)?
      var refreshes = 0
      /// Simulates a passive registration failing during install.
      var failPassive = false
      func start(
        ingest: @escaping @Sendable (UnsafePointer<AudioBufferList>, UInt64, Bool) -> Void
      ) throws -> CallSoundPipeline.InputFormat {
        lock.withLock {
          starts += 1
          self.ingest = ingest
        }
        return .init(sampleRate: rate)
      }
      func stop() -> Int { 0 }
      func installListeners(
        queue: DispatchQueue, onChange: @escaping @Sendable () -> Void,
        onNotice: @escaping @Sendable (CallSoundNotice) -> Void
      ) -> Bool {
        lock.withLock {
          self.onNotice = onNotice
          if failPassive {
            diagnostics.watchProblems = [
              .init(text: "register aggregateNominalRate object=9 failed", count: 1, current: true)
            ]
          }
        }
        return true
      }
      func removeListeners() -> Bool { true }
      func captureDiagnostics() -> CallSoundCaptureDiagnostics { lock.withLock { diagnostics } }
      func refreshDiagnostics() -> CallSoundCaptureDiagnostics {
        lock.withLock {
          refreshes += 1
          return diagnostics
        }
      }
    }

    @Test("each build logs its generation, trigger and formats; a notification is logged and changes nothing")
    func buildAndNotificationLines() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = Backend()
      backend.diagnostics = CallSoundCaptureDiagnostics(
        tapRate: 48_000, aggregateNominalRate: 24_000,
        inputStreams: [
          .init(
            id: 11, sampleRate: 24_000, formatID: kAudioFormatLinearPCM, formatFlags: 9,
            channels: 2, bitsPerChannel: 32, bytesPerFrame: 8)
        ])
      let sink = Sink()
      let tap = SystemAudioTap(
        backend: backend, onSamples: { _, _, _ in }, onEvent: { _ in },
        drainInterval: .seconds(3_600), log: sink.log)
      try tap.start()
      let build = try #require(sink.matching("CALL_SOUND build").first)
      #expect(build.contains("gen=1 trigger=start configuredRate=48000.0"))
      #expect(build.contains("tapRate=48000.0 aggregateNominalRate=24000.0"))
      #expect(build.contains("11:24000.0Hz/2ch/lpcm"))

      // Two 2-channel buffers... one callback: the layout line names the mapping.
      let ingest = try #require(backend.lock.withLock { backend.ingest })
      let list = AudioBufferList.allocate(maximumBuffers: 1)
      defer { free(list.unsafeMutablePointer) }
      var memory = [Float](repeating: 0.1, count: 960)
      memory.withUnsafeMutableBufferPointer { buffer in
        list[0] = AudioBuffer(
          mNumberChannels: 2, mDataByteSize: UInt32(buffer.count * 4),
          mData: UnsafeMutableRawPointer(buffer.baseAddress))
        ingest(UnsafePointer(list.unsafeMutablePointer), 5_000, true)
      }
      tap.drainForTesting()
      #expect(
        sink.matching("CALL_SOUND buffers")
          == ["CALL_SOUND buffers gen=1 count=1 channels=[2] mapping=layoutMatches(rate=24000.0)"])

      let onNotice = try #require(backend.lock.withLock { backend.onNotice })
      backend.lock.withLock { backend.diagnostics.aggregateNominalRate = 16_000 }
      onNotice(
        CallSoundNotice(
          build: 1, object: 77, selector: kAudioDevicePropertyNominalSampleRate,
          scope: kAudioObjectPropertyScopeGlobal, name: "aggregateNominalRate"))
      tap.drainForTesting()
      let notify = try #require(sink.matching("CALL_SOUND notify").first)
      #expect(notify.hasPrefix("CALL_SOUND notify gen=1 build=1 object=77 selector=nsrt scope=glob"))
      #expect(notify.hasSuffix("property=aggregateNominalRate currentBuild=0 running=true"))
      #expect(
        sink.matching("CALL_SOUND observed").last?.contains("aggregateNominalRate=16000.0") == true,
        "the line after a notice shows the state it announced")
      #expect(backend.lock.withLock { backend.refreshes } == 1)
      #expect(backend.lock.withLock { backend.starts } == 1, "a diagnostic notice never rebuilds")

      tap.requestRebuildForTesting()
      tap.drainForTesting()
      #expect(sink.matching("CALL_SOUND build").last?.contains("gen=2 trigger=rebuild") == true)
      tap.stop()
    }

    @Test("the measured-rate line reports what the buffers' times say, next to the configured rate")
    func measuredLine() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = Backend()
      let sink = Sink()
      let tap = SystemAudioTap(
        backend: backend, onSamples: { _, _, _ in }, onEvent: { _ in },
        drainInterval: .seconds(3_600), log: sink.log)
      try tap.start()
      let ingest = try #require(backend.lock.withLock { backend.ingest })
      let list = AudioBufferList.allocate(maximumBuffers: 1)
      defer { free(list.unsafeMutablePointer) }
      var memory = [Float](repeating: 0.1, count: 480)
      memory.withUnsafeMutableBufferPointer { buffer in
        list[0] = AudioBuffer(
          mNumberChannels: 1, mDataByteSize: UInt32(buffer.count * 4),
          mData: UnsafeMutableRawPointer(buffer.baseAddress))
        for i in 0..<30 {
          ingest(
            UnsafePointer(list.unsafeMutablePointer),
            7_000_000 + CallSoundPipeline.ticks(seconds: Double(i) * 0.02), true)
        }
      }
      tap.drainForTesting()
      let line = try #require(sink.matching("CALL_SOUND measured").first)
      #expect(line.hasPrefix("CALL_SOUND measured gen=1 rate=24000.0 configured=48000.0 windows=1"))
      tap.stop()
    }

    @Test("after a rebuild the measured line never shows the previous capture's rate")
    func measurementIsPerGeneration() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = Backend()
      let sink = Sink()
      let tap = SystemAudioTap(
        backend: backend, onSamples: { _, _, _ in }, onEvent: { _ in },
        drainInterval: .seconds(3_600), log: sink.log)
      try tap.start()
      func callbacks(count: Int, start: UInt64, valid: Bool) throws {
        let ingest = try #require(backend.lock.withLock { backend.ingest })
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        var memory = [Float](repeating: 0.1, count: 480)
        memory.withUnsafeMutableBufferPointer { buffer in
          list[0] = AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(buffer.count * 4),
            mData: UnsafeMutableRawPointer(buffer.baseAddress))
          for i in 0..<count {
            ingest(
              UnsafePointer(list.unsafeMutablePointer),
              start + CallSoundPipeline.ticks(seconds: Double(i) * 0.02), valid)
          }
        }
      }
      try callbacks(count: 30, start: 7_000_000, valid: true)
      tap.drainForTesting()
      #expect(sink.matching("CALL_SOUND measured gen=1 rate=24000.0").count == 1)
      tap.requestRebuildForTesting()
      tap.drainForTesting()
      try callbacks(count: 10, start: 90_000_000, valid: false)
      tap.drainForTesting()
      #expect(
        sink.matching("CALL_SOUND measured gen=2")
          == [
            "CALL_SOUND measured gen=2 rate=unavailable configured=48000.0 windows=0 invalid=10/0/0 discontinuitiesTotal=38"
          ])
      tap.stop()
    }

    @Test("a diagnostic listener that fails to register is recorded, not mistaken for silence")
    func failedRegistrationIsRecorded() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = CoreAudioCallSoundBackend(
        addListener: { _, address, _, _ in
          address.pointee.mSelector == kAudioStreamPropertyVirtualFormat
            ? OSStatus(kAudioHardwareUnspecifiedError) : noErr
        },
        removeListener: { _, _, _, _ in noErr },
        streamLister: { _ in [31] })
      backend.setTapObjectForTesting(AudioObjectID(4_242))
      backend.setAggregateObjectForTesting(AudioObjectID(UInt32.max - 7))
      let installed = backend.installListeners(
        queue: DispatchQueue(label: "test.listeners"), onChange: {}, onNotice: { _ in })
      #expect(installed)
      #expect(
        backend.captureDiagnostics().watchProblems == [
          .init(text: "register streamVirtualFormat object=31 failed", count: 1, current: true)
        ])
      #expect(backend.removeListeners())
    }

    @Test("a repeated failure is one counted entry, and shows resolved once the read succeeds")
    func repeatedProblemsAreBounded() throws {
      guard #available(macOS 14.2, *) else { return }
      let failing = OSAllocatedUnfairLock(initialState: true)
      let backend = CoreAudioCallSoundBackend(
        addListener: { _, _, _, _ in noErr }, removeListener: { _, _, _, _ in noErr },
        streamLister: { _ in failing.withLock { $0 } ? nil : [5] },
        tapRateReader: { _ in 48_000 })
      backend.setTapObjectForTesting(AudioObjectID(4_242))
      backend.setAggregateObjectForTesting(AudioObjectID(UInt32.max - 7))
      let installed = backend.installListeners(
        queue: DispatchQueue(label: "test.listeners"), onChange: {}, onNotice: { _ in })
      #expect(installed)
      _ = backend.refreshDiagnostics()
      let stillFailing = backend.refreshDiagnostics()
      #expect(
        stillFailing.watchProblems == [.init(text: "inputStreams unreadable", count: 3, current: true)])
      failing.withLock { $0 = false }
      let recovered = backend.refreshDiagnostics()
      #expect(
        recovered.watchProblems == [.init(text: "inputStreams unreadable", count: 3, current: false)])
      #expect(backend.removeListeners())
    }

    @Test("the tap rate in a refreshed snapshot is read again, not the start-time value")
    func tapRateIsReadLive() throws {
      guard #available(macOS 14.2, *) else { return }
      let rate = OSAllocatedUnfairLock<Double?>(initialState: 48_000)
      let backend = CoreAudioCallSoundBackend(
        addListener: { _, _, _, _ in noErr }, removeListener: { _, _, _, _ in noErr },
        streamLister: { _ in [] }, tapRateReader: { _ in rate.withLock { $0 } })
      backend.setTapObjectForTesting(AudioObjectID(4_242))
      #expect(backend.captureDiagnostics().tapRate == 48_000)
      rate.withLock { $0 = 24_000 }
      #expect(backend.refreshDiagnostics().tapRate == 24_000)
      rate.withLock { $0 = nil }
      #expect(backend.captureDiagnostics().describe().contains("tapRate=unreadable"))
    }

    @Test("start logs which notifications are actually watched, without waiting for one to arrive")
    func startLogsInstalledWatchStatus() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = Backend()
      backend.failPassive = true
      let sink = Sink()
      let tap = SystemAudioTap(
        backend: backend, onSamples: { _, _, _ in }, onEvent: { _ in },
        drainInterval: .seconds(3_600), log: sink.log)
      try tap.start()
      #expect(sink.matching("CALL_SOUND build").first?.hasSuffix("watch=ok") == true)
      let installed = try #require(sink.matching("CALL_SOUND observed gen=1 trigger=installed").first)
      #expect(installed.hasSuffix("watch=[register aggregateNominalRate object=9 failed x1 current]"))
      tap.stop()
    }

    @Test("a changed stream list moves the stream listeners to the new streams")
    func streamListChangeIsReconciled() throws {
      guard #available(macOS 14.2, *) else { return }
      let streams = OSAllocatedUnfairLock<[AudioObjectID]>(initialState: [21, 22])
      let added = OSAllocatedUnfairLock<[AudioObjectID]>(initialState: [])
      let removed = OSAllocatedUnfairLock<[AudioObjectID]>(initialState: [])
      let backend = CoreAudioCallSoundBackend(
        addListener: { object, address, _, _ in
          if address.pointee.mSelector == kAudioStreamPropertyVirtualFormat {
            added.withLock { $0.append(object) }
          }
          return noErr
        },
        removeListener: { object, address, _, _ in
          if address.pointee.mSelector == kAudioStreamPropertyVirtualFormat {
            removed.withLock { $0.append(object) }
          }
          return noErr
        },
        streamLister: { _ in streams.withLock { $0 } })
      backend.setTapObjectForTesting(AudioObjectID(4_242))
      backend.setAggregateObjectForTesting(AudioObjectID(UInt32.max - 7))
      let installed = backend.installListeners(
        queue: DispatchQueue(label: "test.listeners"), onChange: {}, onNotice: { _ in })
      #expect(installed)
      #expect(added.withLock { $0 } == [21, 22])
      streams.withLock { $0 = [22, 23] }
      _ = backend.refreshDiagnostics()
      #expect(removed.withLock { $0 } == [21])
      #expect(added.withLock { $0 } == [21, 22, 23])
      #expect(backend.listenerCountForTesting == 6, "output, tap format, rate, stream list, 22, 23")
      #expect(backend.removeListeners())
      #expect(backend.listenerCountForTesting == 0)
    }

    @Test("diagnostic listeners on the aggregate are installed with the rebuild triggers and all removed together")
    func aggregateListenerBookkeeping() throws {
      guard #available(macOS 14.2, *) else { return }
      let adds = OSAllocatedUnfairLock<[AudioObjectPropertySelector]>(initialState: [])
      let removes = OSAllocatedUnfairLock(initialState: 0)
      let backend = CoreAudioCallSoundBackend(
        addListener: { _, address, _, _ in
          let selector = address.pointee.mSelector
          adds.withLock { $0.append(selector) }
          return noErr
        },
        removeListener: { _, _, _, _ in
          removes.withLock { $0 += 1 }
          return noErr
        })
      backend.setTapObjectForTesting(AudioObjectID(4_242))
      // An ID no device has: its stream list cannot be read, so no stream is watched.
      backend.setAggregateObjectForTesting(AudioObjectID(UInt32.max - 7))
      let installed = backend.installListeners(
        queue: DispatchQueue(label: "test.listeners"), onChange: {}, onNotice: { _ in })
      #expect(installed)
      #expect(
        adds.withLock { $0 } == [
          kAudioHardwarePropertyDefaultOutputDevice, kAudioTapPropertyFormat,
          kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyStreams,
        ])
      #expect(backend.removeListeners())
      #expect(removes.withLock { $0 } == 4)
      #expect(backend.listenerCountForTesting == 0)
    }

    @Test("a diagnostic listener that fails to register never stops capture; the rebuild triggers stay")
    func diagnosticListenerFailureIsSoft() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = CoreAudioCallSoundBackend(
        addListener: { _, address, _, _ in
          address.pointee.mSelector == kAudioDevicePropertyNominalSampleRate
            ? OSStatus(kAudioHardwareUnspecifiedError) : noErr
        },
        removeListener: { _, _, _, _ in noErr })
      backend.setTapObjectForTesting(AudioObjectID(4_242))
      backend.setAggregateObjectForTesting(AudioObjectID(UInt32.max - 7))
      let installed = backend.installListeners(
        queue: DispatchQueue(label: "test.listeners"), onChange: {}, onNotice: { _ in })
      #expect(installed, "a failed diagnostic registration is not an install failure")
      #expect(backend.listenerCountForTesting == 3, "default output, tap format, stream list")
      #expect(backend.removeListeners())
    }
  #endif
}
