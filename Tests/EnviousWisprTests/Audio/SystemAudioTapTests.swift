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
    var ingest: (@Sendable (UnsafePointer<AudioBufferList>, UInt64) -> Void)?
    var onChange: (@Sendable () -> Void)?

    func start(
      ingest: @escaping @Sendable (UnsafePointer<AudioBufferList>, UInt64) -> Void
    ) throws -> CallSoundPipeline.InputFormat {
      lock.lock()
      defer { lock.unlock() }
      starts += 1
      if failStartNumber == starts { throw FakeError.startFailed }
      running = true
      self.ingest = ingest
      return .init(sampleRate: 48_000)
    }

    func stop() -> Int {
      lock.lock()
      defer { lock.unlock() }
      stops += 1
      running = false
      return 0
    }

    func installListeners(queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      self.onChange = onChange
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
        queue: DispatchQueue(label: "test.listeners"), onChange: {})
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
    _ samples: [Float], to ingest: @Sendable (UnsafePointer<AudioBufferList>, UInt64) -> Void,
    host: UInt64
  ) throws {
    let list = AudioBufferList.allocate(maximumBuffers: 1)
    defer { free(list.unsafeMutablePointer) }
    var copy = samples
    copy.withUnsafeMutableBufferPointer { memory in
      list[0] = AudioBuffer(
        mNumberChannels: 1, mDataByteSize: UInt32(memory.count * 4),
        mData: UnsafeMutableRawPointer(memory.baseAddress))
      ingest(UnsafePointer(list.unsafeMutablePointer), host)
    }
  }
}
