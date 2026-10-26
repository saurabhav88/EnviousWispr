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

  /// A readable Float32 PCM input stream as the aggregate reports it.
  static func floatStream(channels: UInt32, rate: Double = 48_000, id: UInt32 = 1)
    -> CallSoundCaptureDiagnostics.Stream
  {
    .init(
      id: id, sampleRate: rate, formatID: kAudioFormatLinearPCM,
      formatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, channels: channels,
      bitsPerChannel: 32, bytesPerFrame: 4 * channels)
  }

  // MARK: - Capture rate (#4117 R3)

  @Test("every supported rate gives the right signal at real speed with callbacks of varying length")
  func ratesWithVariableCallbacks() throws {
    let lengths = [128, 1_024, 480, 256, 512, 333]
    for rate in [16_000.0, 24_000, 44_100, 48_000, 96_000] {
      let output = Output()
      let p = try pipeline(rate: rate, output)
      let total = Int(rate)
      var at = 0
      var i = 0
      while at < total {
        let n = min(lengths[i % lengths.count], total - at)
        ingest(
          p, buffers: [sine(n, rate: rate, from: at)], channels: [1],
          host: 2_000_000 + ticks(Double(at) / rate))
        at += n
        i += 1
      }
      p.drain()
      p.finishRun()
      let got = output.samples.withLock { $0 }
      #expect(abs(got.count - 16_000) <= 48, "rate \(rate): \(got.count) samples for one second")
      #expect(errorAgainstIdeal(got) < 0.02, "rate \(rate)")
      #expect(p.health.discontinuities == 0, "rate \(rate): one continuous run")
    }
  }

  @Test("the capture rate is the aggregate's nominal rate, even when the stream and tap say 48 kHz")
  func nominalRateIsTheAuthority() throws {
    guard #available(macOS 14.2, *) else { return }
    let stream48 = Self.floatStream(channels: 2, rate: 48_000)
    // The founder's AirPods in the call profile: nominal 24 kHz, stream virtual format 48 kHz.
    #expect(
      try CoreAudioCallSoundBackend.captureFormat(nominalRate: 24_000, inputStreams: [stream48])
        == .init(sampleRate: 24_000, bufferChannels: [2]))
    #if DEBUG
      try nominalRateThroughTheBackend()
    #endif
  }

  #if DEBUG
  /// The same rule through the backend's own reads (needs the DEBUG aggregate seam).
  private func nominalRateThroughTheBackend() throws {
    guard #available(macOS 14.2, *) else { return }
    let nominal = OSAllocatedUnfairLock<Double?>(initialState: 24_000)
    let backend = CoreAudioCallSoundBackend(
      addListener: { _, _, _, _ in noErr }, removeListener: { _, _, _, _ in noErr },
      streamLister: { _ in [5] }, tapRateReader: { _ in 48_000 },
      nominalRateReader: { _ in nominal.withLock { $0 } },
      streamFormatReader: { _ in
        (
          noErr,
          AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32,
            mReserved: 0)
        )
      })
    backend.setAggregateObjectForTesting(AudioObjectID(UInt32.max - 7))
    #expect(try backend.committedCaptureFormat() == .init(sampleRate: 24_000, bufferChannels: [2]))
    nominal.withLock { $0 = nil }
    #expect(throws: SystemAudioTap.TapError.status(operation: "read_nominal_rate", value: -1)) {
      try backend.committedCaptureFormat()
    }
  }
  #endif

  @Test("no usable nominal rate or input layout means no capture, never a fallback rate")
  func unusableConfigurationsAreRefused() throws {
    guard #available(macOS 14.2, *) else { return }
    let ok = Self.floatStream(channels: 2)
    for bad in [nil, 0, -48_000, .nan, .infinity] as [Double?] {
      #expect(throws: SystemAudioTap.TapError.status(operation: "read_nominal_rate", value: -1)) {
        try CoreAudioCallSoundBackend.captureFormat(nominalRate: bad, inputStreams: [ok])
      }
    }
    var unreadable = ok
    unreadable.sampleRate = nil
    var integer = ok
    integer.formatFlags = kAudioFormatFlagIsSignedInteger
    integer.bitsPerChannel = 16
    var double = ok
    double.bitsPerChannel = 64
    var silent = ok
    silent.channels = 0
    var compressed = ok
    compressed.formatID = kAudioFormatMPEG4AAC
    var bigEndian = ok
    bigEndian.formatFlags |= kAudioFormatFlagIsBigEndian
    var padded = ok
    padded.bytesPerFrame = 12
    for streams in [
      nil, [], [unreadable], [integer], [double], [silent], [compressed], [ok, integer],
      [bigEndian], [padded],
    ] as [[CallSoundCaptureDiagnostics.Stream]?] {
      #expect(throws: SystemAudioTap.TapError.unusableFormat) {
        try CoreAudioCallSoundBackend.captureFormat(nominalRate: 24_000, inputStreams: streams)
      }
    }
  }

  @Test("the committed buffer layout follows each stream's interleaving")
  func committedLayoutFollowsInterleaving() throws {
    guard #available(macOS 14.2, *) else { return }
    var planar = Self.floatStream(channels: 2)
    planar.formatFlags |= kAudioFormatFlagIsNonInterleaved
    planar.bytesPerFrame = 4
    #expect(
      try CoreAudioCallSoundBackend.captureFormat(
        nominalRate: 16_000, inputStreams: [planar, Self.floatStream(channels: 1, id: 2)])
        == .init(sampleRate: 16_000, bufferChannels: [1, 1, 1]))
  }

  @Test("more than eight buffers are captured whole; a mismatch past the eighth is still refused")
  func manyBuffersAreCheckedInFull() throws {
    guard #available(macOS 14.2, *) else { return }
    var planar = Self.floatStream(channels: 10)
    planar.formatFlags |= kAudioFormatFlagIsNonInterleaved
    planar.bytesPerFrame = 4
    let format = try CoreAudioCallSoundBackend.captureFormat(nominalRate: 48_000, inputStreams: [planar])
    #expect(format.bufferChannels == Array(repeating: 1, count: 10))
    let output = Output()
    let p = CallSoundPipeline(onSamples: output.handler)
    try p.configure(format)
    p.setAccepting(true)
    let tone = sine(480, rate: 48_000)
    ingest(p, buffers: Array(repeating: tone, count: 10), channels: Array(repeating: 1, count: 10), host: 1_000)
    p.drain()
    #expect(p.takeRefusedLayout() == nil, "ten mono buffers match the committed ten")
    // The tenth buffer has two channels: refused before any sample is kept.
    ingest(
      p, buffers: Array(repeating: tone, count: 9) + [tone.flatMap { [$0, $0] }],
      channels: Array(repeating: 1, count: 9) + [2], host: 1_000 + ticks(0.01))
    p.drain()
    p.finishRun()
    let refused = try #require(p.takeRefusedLayout())
    #expect(refused.callbacks == 1 && refused.layout.buffers == 10)
    #expect(abs(output.samples.withLock { $0 }.count - 160) <= 32, "only the first callback's 10 ms")
  }

  @Test("a callback without the committed layout keeps none of its samples")
  func refusedCallbackKeepsNothing() throws {
    let output = Output()
    let p = CallSoundPipeline(onSamples: output.handler)
    try p.configure(.init(sampleRate: 48_000, bufferChannels: [2]))
    p.setAccepting(true)
    // A 1-channel callback of 960 frames, then a valid 2-channel one of 480 frames.
    ingest(p, buffers: [[Float](repeating: 0.4, count: 960)], channels: [1], host: 1_000)
    ingest(
      p, buffers: [sine(480, rate: 48_000).flatMap { [$0, $0] }], channels: [2],
      host: 1_000 + ticks(0.01))
    p.drain()
    p.finishRun()
    let refused = try #require(p.takeRefusedLayout())
    #expect(refused.callbacks == 1 && refused.layout == .init(buffers: 1, channels: [1]))
    let delivered = output.samples.withLock { $0 }
    #expect(abs(delivered.count - 160) <= 32, "only the valid 10 ms: \(delivered.count) samples")
    #expect(!delivered.contains { abs($0 - 0.4) < 0.001 }, "no sample of the refused callback")
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
    var onNotice: (@Sendable (CallSoundNotice) -> Void)?
    var rate: Double = 48_000
    /// The buffer layout `start` commits to (nil commits none).
    var bufferChannels: [UInt32]?
    var outputUID = "speakers"
    /// `currentCapture` cannot read the device.
    var failCurrent = false
    /// Changes the rate while listeners install: a change no notice reports.
    var rateAtInstall: Double?
    var currentReads = 0
    /// One mono Float32 input stream, the layout `deliver` hands over.
    var diagnostics = CallSoundCaptureDiagnostics(
      inputStreams: [SystemAudioTapTests.floatStream(channels: 1)])

    func start(
      ingest: @escaping @Sendable (UnsafePointer<AudioBufferList>, UInt64, Bool) -> Void
    ) throws -> CallSoundCapture {
      lock.lock()
      defer { lock.unlock() }
      starts += 1
      if failStartNumber == starts { throw FakeError.startFailed }
      running = true
      self.ingest = ingest
      return capture
    }

    /// Lock held.
    private var capture: CallSoundCapture {
      .init(
        build: starts, outputUID: outputUID,
        format: .init(sampleRate: rate, bufferChannels: bufferChannels))
    }

    func currentCapture() throws -> CallSoundCapture {
      lock.lock()
      defer { lock.unlock() }
      currentReads += 1
      if failCurrent { throw FakeError.startFailed }
      return capture
    }

    /// Fires a notice as a Core Audio listener does; `build` defaults to the current build.
    func notify(_ name: String, build: Int? = nil) {
      let (handler, current) = lock.withLock { (onNotice, starts) }
      handler?(
        CallSoundNotice(
          build: build ?? current, object: 7, selector: 0, scope: 0, name: name))
    }

    func captureDiagnostics() -> CallSoundCaptureDiagnostics {
      lock.lock()
      defer { lock.unlock() }
      return diagnostics
    }

    /// False makes a stream-list change find a stream it cannot watch.
    var watchComplete = true
    func reconcileWatch() -> Bool { lock.withLock { watchComplete } }

    func stop() -> Int {
      lock.lock()
      defer { lock.unlock() }
      stops += 1
      running = false
      return 0
    }

    func installListeners(
      queue: DispatchQueue, onNotice: @escaping @Sendable (CallSoundNotice) -> Void
    ) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      self.onNotice = onNotice
      if let rateAtInstall { rate = rateAtInstall }
      return !failListeners
    }

    var removeListenerCalls = 0
    func removeListeners() -> Bool {
      lock.withLock { removeListenerCalls += 1 }
      return true
    }

    var snapshot: (starts: Int, running: Bool) {
      lock.lock()
      defer { lock.unlock() }
      return (starts, running)
    }
  }

  private final class Events: Sendable {
    let list = OSAllocatedUnfairLock<[String]>(initialState: [])
  }

  /// A clock a test moves by hand.
  private final class Clock: Sendable {
    let seconds = OSAllocatedUnfairLock(initialState: 100.0)
    var now: @Sendable () -> TimeInterval { { self.seconds.withLock { $0 } } }
  }

  @available(macOS 14.2, *)
  private func tap(
    _ backend: FakeBackend, _ output: Output, _ events: Events, clock: Clock = Clock()
  ) -> SystemAudioTap {
    SystemAudioTap(
      backend: backend, onSamples: output.handler,
      onEvent: { event in
        switch event {
        case .rebuilt: events.list.withLock { $0.append("rebuilt") }
        case .rebuildFailed: events.list.withLock { $0.append("rebuildFailed") }
        }
      },
      drainInterval: .seconds(3_600), now: clock.now)
  }

  /// `count` buffers of 480 mono frames, `step` seconds apart from `start` seconds: 20 ms is
  /// the call-profile shape (24 kHz), 10 ms is 48 kHz.
  private func feedTiming(
    _ ingest: @Sendable (UnsafePointer<AudioBufferList>, UInt64, Bool) -> Void, count: Int,
    start: Double, step: Double
  ) throws {
    for i in 0..<count {
      try deliver(
        [Float](repeating: 0.1, count: 480), to: ingest, host: ticks(start + Double(i) * step))
    }
  }

  #if DEBUG
    @Test("stop queued ahead of a pending recovery wins: the recovery never restarts capture")
    func stopBeatsQueuedRebuild() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = FakeBackend()
      let output = Output()
      let events = Events()
      let tap = tap(backend, output, events)
      try tap.start()
      #expect(tap.settleForTesting())
      // Order on the tap queue, held shut: the notice, then stop. The notice queues its
      // comparison only when it runs, so the comparison lands behind stop.
      let release = tap.holdQueueForTesting()
      backend.lock.withLock { backend.rate = 24_000 }
      backend.notify("aggregateNominalRate")
      tap.enqueueStopForTesting()
      release()
      #expect(tap.settleForTesting())
      #expect(backend.snapshot.starts == 1)
      #expect(!backend.snapshot.running)
      #expect(events.list.withLock { $0 }.isEmpty)
      #expect(throws: SystemAudioTap.TapError.stopped) { try tap.start() }
      tap.stop()
    }

    @Test("the settle wait gives up on a blocked tap queue, then completes once it is released")
    func settleWaitIsBounded() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = FakeBackend()
      let tap = tap(backend, Output(), Events())
      try tap.start()
      let release = tap.holdQueueForTesting()
      #expect(!tap.settleForTesting(deadline: 0), "a blocked queue never reads as settled")
      release()
      #expect(tap.settleForTesting())
      tap.stop()
    }

    @Test("call-profile timing at 48 kHz configured rebuilds once; the corrected rate is then verified")
    func mismatchRebuildsThenVerifies() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = FakeBackend()
      let output = Output()
      let events = Events()
      let tap = tap(backend, output, events)
      try tap.start()
      #expect(tap.settleForTesting())
      // Six windows of 24 kHz timing in one drain: one rebuild, not two.
      try feedTiming(try #require(backend.ingest), count: 160, start: 1, step: 0.02)
      // What the rebuild will read: the aggregate now reports 24 kHz.
      backend.lock.withLock { backend.rate = 24_000 }
      tap.drainForTesting()
      #expect(tap.settleForTesting())
      #expect(backend.snapshot.starts == 2)
      #expect(tap.health.rebuildReasons == [.rateMismatch: 1])
      #expect(tap.health.pipeline.rateMismatches == 2, "both sustained mismatches counted")
      #expect(tap.health.verifiedRecoveries == 0, "a completed rebuild is not yet verified")
      try feedTiming(try #require(backend.ingest), count: 30, start: 10, step: 0.02)
      tap.drainForTesting()
      #expect(tap.health.verifiedRecoveries == 1)
      #expect(events.list.withLock { $0 } == ["rebuilt"])
      tap.stop()
    }

    @Test("in one drain after a mismatch rebuild, a remaining mismatch then agreement still stops")
    func persistentMismatchBeforeAgreementStops() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = FakeBackend()
      let events = Events()
      let tap = tap(backend, Output(), events)
      try tap.start()
      #expect(tap.settleForTesting())
      try feedTiming(try #require(backend.ingest), count: 80, start: 1, step: 0.02)
      tap.drainForTesting()
      #expect(tap.settleForTesting())
      // Still 48 kHz configured: three mismatching windows, then 48 kHz timing that agrees.
      let ingest = try #require(backend.ingest)
      try feedTiming(ingest, count: 80, start: 10, step: 0.02)
      try feedTiming(ingest, count: 110, start: 11.6, step: 0.01)
      tap.drainForTesting()
      #expect(tap.settleForTesting())
      #expect(events.list.withLock { $0 } == ["rebuilt", "rebuildFailed"])
      #expect(tap.health.persistentMismatches == 1)
      #expect(tap.health.verifiedRecoveries == 0, "the later agreement came after the failure")
      tap.stop()
    }

    @Test("in one drain after a mismatch rebuild, agreement then a new mismatch verifies, then asks again")
    func agreementBeforeNewMismatchVerifies() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = FakeBackend()
      let events = Events()
      let clock = Clock()
      let tap = tap(backend, Output(), events, clock: clock)
      try tap.start()
      #expect(tap.settleForTesting())
      try feedTiming(try #require(backend.ingest), count: 80, start: 1, step: 0.02)
      backend.lock.withLock { backend.rate = 24_000 }
      tap.drainForTesting()
      #expect(tap.settleForTesting())
      clock.seconds.withLock { $0 += 6 }
      // 24 kHz timing (one agreeing window), then 12 kHz timing (480 frames every 40 ms) for
      // three windows; 86 buffers stay inside the 2 s handoff at 24 kHz.
      let ingest = try #require(backend.ingest)
      try feedTiming(ingest, count: 26, start: 10, step: 0.02)
      try feedTiming(ingest, count: 60, start: 10.52, step: 0.04)
      tap.drainForTesting()
      #expect(tap.settleForTesting())
      #expect(tap.health.verifiedRecoveries == 1)
      #expect(tap.health.persistentMismatches == 0, "verified first, so this is a new mismatch")
      #expect(backend.snapshot.starts == 3)
      #expect(tap.health.rebuildReasons == [.rateMismatch: 2])
      tap.stop()
    }

    @Test("a mismatch that remains after its rebuild stops the call-sound track once, no loop")
    func persistentMismatchStops() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = FakeBackend()
      let output = Output()
      let events = Events()
      let tap = tap(backend, output, events)
      try tap.start()
      #expect(tap.settleForTesting())
      try feedTiming(try #require(backend.ingest), count: 80, start: 1, step: 0.02)
      tap.drainForTesting()
      #expect(tap.settleForTesting())
      #expect(backend.snapshot.starts == 2)
      // The aggregate still says 48 kHz and the buffers still arrive at 24 kHz.
      try feedTiming(try #require(backend.ingest), count: 80, start: 10, step: 0.02)
      tap.drainForTesting()
      #expect(tap.settleForTesting())
      #expect(events.list.withLock { $0 } == ["rebuilt", "rebuildFailed"])
      #expect(tap.health.persistentMismatches == 1)
      #expect(tap.health.verifiedRecoveries == 0)
      #expect(!backend.snapshot.running)
      backend.notify("defaultOutput", build: 0)
      #expect(tap.settleForTesting())
      #expect(backend.snapshot.starts == 2, "nothing rebuilds after the stop")
      tap.stop()
    }

    @Test("a second mismatch within 5 s of a mismatch rebuild waits; after 5 s it rebuilds")
    func recoveryIntervalSurvivesRebuilds() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = FakeBackend()
      let output = Output()
      let events = Events()
      let clock = Clock()
      let tap = tap(backend, output, events, clock: clock)
      try tap.start()
      #expect(tap.settleForTesting())
      try feedTiming(try #require(backend.ingest), count: 80, start: 1, step: 0.02)
      backend.lock.withLock { backend.rate = 24_000 }
      tap.drainForTesting()
      #expect(tap.settleForTesting())
      try feedTiming(try #require(backend.ingest), count: 30, start: 10, step: 0.02)
      tap.drainForTesting()
      #expect(tap.health.verifiedRecoveries == 1)

      // 2 s later the timing moves to 48 kHz while 24 kHz is configured.
      clock.seconds.withLock { $0 += 2 }
      // Three whole windows at 10 ms steps need about 160 buffers; the handoff holds 2 s at the
      // configured 24 kHz, so drain halfway.
      try feedTiming(try #require(backend.ingest), count: 80, start: 20, step: 0.01)
      tap.drainForTesting()
      try feedTiming(try #require(backend.ingest), count: 80, start: 20.8, step: 0.01)
      tap.drainForTesting()
      #expect(tap.settleForTesting())
      #expect(backend.snapshot.starts == 2, "held back by the interval kept across the rebuild")
      #expect(tap.health.suppressedMismatchRecoveries == 1)

      clock.seconds.withLock { $0 += 4 }
      try feedTiming(try #require(backend.ingest), count: 80, start: 30, step: 0.01)
      tap.drainForTesting()
      try feedTiming(try #require(backend.ingest), count: 80, start: 30.8, step: 0.01)
      backend.lock.withLock { backend.rate = 48_000 }
      tap.drainForTesting()
      #expect(tap.settleForTesting())
      #expect(backend.snapshot.starts == 3)
      #expect(tap.health.rebuildReasons == [.rateMismatch: 2])
      tap.stop()
    }

    @Test("a notice rebuild in the same turn wins; the queued mismatch rebuild is retired")
    func mismatchAndNoticeRebuildOnce() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = FakeBackend()
      let output = Output()
      let events = Events()
      let tap = tap(backend, output, events)
      try tap.start()
      #expect(tap.settleForTesting())
      try feedTiming(try #require(backend.ingest), count: 80, start: 1, step: 0.02)
      backend.lock.withLock { backend.outputUID = "airpods" }
      backend.notify("defaultOutput", build: 0)
      tap.drainForTesting()
      #expect(tap.settleForTesting())
      #expect(backend.snapshot.starts == 2)
      #expect(tap.health.rebuildReasons == [.outputDevice: 1])
      #expect(tap.health.verifiedRecoveries == 0, "the notice rebuild verifies nothing")
      tap.stop()
    }

    @Test("stop queued ahead of a mismatch rebuild wins; a failed mismatch rebuild reports once")
    func stopAndFailureBeatMismatchRecovery() throws {
      guard #available(macOS 14.2, *) else { return }
      do {
        let backend = FakeBackend()
        let events = Events()
        let tap = tap(backend, Output(), events)
        try tap.start()
        #expect(tap.settleForTesting())
        try feedTiming(try #require(backend.ingest), count: 80, start: 1, step: 0.02)
        let release = tap.holdQueueForTesting()
        tap.enqueueDrainForTesting()
        tap.enqueueStopForTesting()
        release()
        #expect(tap.settleForTesting())
        #expect(backend.snapshot.starts == 1)
        #expect(events.list.withLock { $0 }.isEmpty)
        tap.stop()
      }
      do {
        let backend = FakeBackend()
        backend.failStartNumber = 2
        let events = Events()
        let tap = tap(backend, Output(), events)
        try tap.start()
        #expect(tap.settleForTesting())
        try feedTiming(try #require(backend.ingest), count: 80, start: 1, step: 0.02)
        tap.drainForTesting()
        #expect(tap.settleForTesting())
        #expect(events.list.withLock { $0 } == ["rebuildFailed"])
        #expect(tap.health.rebuildFailures == 1)
        #expect(!backend.snapshot.running)
        tap.stop()
      }
    }

    @Test("notices after stop returns restart nothing")
    func lateNoticesAfterStop() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = FakeBackend()
      let output = Output()
      let events = Events()
      let tap = tap(backend, output, events)
      try tap.start()
      backend.lock.withLock { backend.rate = 24_000 }
      backend.notify("aggregateNominalRate")
      tap.stop()
      let startsAtStop = backend.snapshot.starts
      // Listeners firing after stop, object-bound and system, must not resurrect capture.
      backend.lock.withLock { backend.outputUID = "airpods" }
      backend.notify("aggregateNominalRate")
      backend.notify("defaultOutput", build: 0)
      #expect(tap.settleForTesting())
      tap.drainForTesting()
      #expect(backend.snapshot.starts == startsAtStop)
      #expect(backend.snapshot.running == false)
    }

    @Test("a new stream nothing can watch rebuilds the capture rather than record it unwatched")
    func unwatchableStreamRebuilds() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = FakeBackend()
      let output = Output()
      let events = Events()
      let tap = tap(backend, output, events)
      try tap.start()
      backend.lock.withLock { backend.watchComplete = false }
      backend.notify("aggregateInputStreams")
      #expect(tap.settleForTesting())
      #expect(events.list.withLock { $0 } == ["rebuilt"])
      #expect(tap.health.rebuildReasons == [.watchFailed: 1])
      tap.stop()
    }

    @Test("a rebuild at a new nominal rate drains the old audio, then records the new rate at real speed")
    func rebuildConfiguresTheNewRate() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = FakeBackend()
      let output = Output()
      let events = Events()
      let tap = tap(backend, output, events)
      try tap.start()
      let first = try #require(backend.ingest)
      // Half a second at 48 kHz in 480-frame buffers.
      for i in 0..<50 {
        try deliver(
          sine(480, rate: 48_000, from: i * 480), to: first,
          host: 1_000_000 + ticks(Double(i * 480) / 48_000))
      }
      // What AirPods did when the call opened their microphone: the nominal rate, then the
      // stream's format, reported (twice here); the stream still says 48 kHz.
      backend.lock.withLock { backend.rate = 24_000 }
      backend.notify("aggregateNominalRate")
      backend.notify("streamVirtualFormat")
      backend.notify("aggregateNominalRate")
      #expect(tap.settleForTesting())
      #expect(backend.snapshot.starts == 2, "one rebuild for the whole burst")
      backend.notify("streamVirtualFormat")
      #expect(tap.settleForTesting())
      #expect(backend.snapshot.starts == 2, "a later notice in the new state changes nothing")
      let second = try #require(backend.ingest)
      // One second at 24 kHz in 480-frame buffers (20 ms each), the call-profile shape.
      for i in 0..<50 {
        try deliver(
          sine(480, rate: 24_000, from: i * 480), to: second,
          host: 90_000_000 + ticks(Double(i * 480) / 24_000))
      }
      tap.drainForTesting()
      tap.stop()
      #expect(events.list.withLock { $0 } == ["rebuilt"])
      #expect(tap.health.rebuildReasons == [.nominalRate: 1])
      let total = output.samples.withLock { $0 }.count
      #expect(abs(total - (8_000 + 16_000)) <= 64, "0.5 s + 1 s at 16 kHz: \(total)")
      #expect(tap.health.pipeline.discontinuities == 0, "no per-buffer run breaks at 24 kHz")
      #expect(output.newRuns.withLock { $0 }.filter { $0 }.count == 1, "one new run, at the rebuild")
    }

    @Test("a callback without the committed layout stops the call-sound track and keeps nothing of it")
    func refusedLayoutStopsCallSound() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = FakeBackend()
      backend.bufferChannels = [2]
      let output = Output()
      let events = Events()
      let tap = tap(backend, output, events)
      try tap.start()
      let ingest = try #require(backend.ingest)
      try deliver([Float](repeating: 0.4, count: 960), to: ingest, host: 1_000)  // 1 channel
      tap.drainForTesting()
      #expect(events.list.withLock { $0 } == ["rebuildFailed"])
      #expect(!backend.snapshot.running)
      #expect(tap.health.rebuildFailures == 1)
      #expect(output.samples.withLock { $0 }.isEmpty, "nothing of the refused callback reaches the track")
      tap.stop()
    }

    @Test("later diagnostic readings never change the committed layout")
    func committedLayoutIgnoresLaterDiagnostics() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = FakeBackend()
      backend.bufferChannels = [1]
      let output = Output()
      let events = Events()
      let tap = tap(backend, output, events)
      try tap.start()
      backend.lock.withLock {
        backend.diagnostics = CallSoundCaptureDiagnostics(inputStreams: [Self.floatStream(channels: 2)])
      }
      let ingest = try #require(backend.ingest)
      for i in 0..<10 {
        try deliver(sine(480, rate: 48_000, from: i * 480), to: ingest, host: 5_000 + ticks(Double(i) * 0.01))
      }
      tap.drainForTesting()
      #expect(events.list.withLock { $0 }.isEmpty, "the 1-channel callbacks match what start committed")
      #expect(backend.snapshot.running)
      tap.stop()
      #expect(abs(output.samples.withLock { $0 }.count - 1_600) <= 32)
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
      backend.lock.withLock { backend.rate = 24_000 }
      backend.notify("aggregateNominalRate")
      #expect(tap.settleForTesting())
      // More notices after the failure find nothing running.
      backend.notify("aggregateNominalRate", build: 2)
      backend.notify("defaultOutput", build: 0)
      #expect(tap.settleForTesting())
      #expect(events.list.withLock { $0 } == ["rebuildFailed"])
      #expect(tap.health.rebuildFailures == 1)
      #expect(tap.health.rebuilds == 0)
      #expect(backend.snapshot.starts == 2)
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
      backend.lock.withLock { backend.outputUID = "airpods" }
      backend.notify("defaultOutput", build: 0)
      #expect(tap.settleForTesting())
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
        queue: DispatchQueue(label: "test.listeners"), onNotice: { _ in })
      #expect(!installed)
      #expect(adds.withLock { $0 } == 2)
      #expect(removes.withLock { $0 } == 1, "the system listener that installed is removed")
      #expect(backend.listenerCountForTesting == 0)
    }

    @Test("a stream format notice with the device, rate and layout unchanged never rebuilds")
    func virtualFormatNoticeAloneDoesNotRebuild() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = FakeBackend()
      let output = Output()
      let events = Events()
      let tap = tap(backend, output, events)
      try tap.start()
      let readsAtStart = backend.lock.withLock { backend.currentReads }
      backend.lock.withLock {
        backend.diagnostics = CallSoundCaptureDiagnostics(
          inputStreams: [SystemAudioTapTests.floatStream(channels: 1, rate: 24_000)])
      }
      backend.notify("streamVirtualFormat")
      #expect(tap.settleForTesting())
      #expect(backend.snapshot.starts == 1)
      #expect(
        backend.lock.withLock { backend.currentReads } == readsAtStart + 1,
        "the notice itself was compared")
      #expect(events.list.withLock { $0 }.isEmpty)
      tap.stop()
    }

    @Test("a new output device rebuilds at the same rate; the system watch keeps working after it")
    func outputChangeRebuildsAndRetiredNoticesAreIgnored() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = FakeBackend()
      let output = Output()
      let events = Events()
      let tap = tap(backend, output, events)
      try tap.start()
      backend.lock.withLock { backend.outputUID = "airpods" }
      backend.notify("defaultOutput", build: 0)
      #expect(tap.settleForTesting())
      #expect(backend.snapshot.starts == 2)

      // A notice from the torn-down first build, even with a real change pending, is ignored.
      backend.lock.withLock { backend.rate = 24_000 }
      backend.notify("aggregateNominalRate", build: 1)
      #expect(tap.settleForTesting())
      #expect(backend.snapshot.starts == 2, "a retired build's notice never rebuilds")

      // The system watch, installed once, still reports after the rebuild.
      backend.lock.withLock { backend.outputUID = "speakers" }
      backend.notify("defaultOutput", build: 0)
      #expect(tap.settleForTesting())
      #expect(backend.snapshot.starts == 3)
      #expect(events.list.withLock { $0 } == ["rebuilt", "rebuilt"])
      #expect(tap.health.rebuildReasons == [.outputDevice: 2])
      tap.stop()
    }

    @Test("a change between the first commitment and the listeners is still found")
    func changeBeforeListenersIsFound() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = FakeBackend()
      backend.rateAtInstall = 24_000
      let output = Output()
      let events = Events()
      let tap = tap(backend, output, events)
      try tap.start()
      // Found inside start: start returns on the rebuilt capture, and sends no event.
      #expect(backend.snapshot.starts == 2)
      #expect(backend.snapshot.running)
      #expect(events.list.withLock { $0 }.isEmpty)
      tap.stop()
    }

    @Test("a change before the listeners that cannot be followed makes start throw, leaving nothing running")
    func changeBeforeListenersThatFailsThrows() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = FakeBackend()
      backend.rateAtInstall = 24_000
      backend.failStartNumber = 2
      let events = Events()
      let tap = tap(backend, Output(), events)
      #expect(throws: FakeError.self) { try tap.start() }
      #expect(!backend.snapshot.running)
      #expect(backend.lock.withLock { backend.removeListenerCalls } == 1)
      #expect(events.list.withLock { $0 }.isEmpty, "start reports it; no late failure event")
    }

    @Test("a reading that fails is never taken as unchanged: it rebuilds, and a failed rebuild is final")
    func unreadableReadingRebuilds() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = FakeBackend()
      let output = Output()
      let events = Events()
      let tap = tap(backend, output, events)
      try tap.start()
      backend.lock.withLock { backend.failCurrent = true }
      backend.notify("aggregateInputStreams")
      #expect(tap.settleForTesting())
      #expect(events.list.withLock { $0 } == ["rebuilt"])
      #expect(tap.health.rebuildReasons == [.unreadable: 1])

      backend.lock.withLock { backend.failStartNumber = 3 }
      backend.notify("aggregateInputStreams")
      #expect(tap.settleForTesting())
      #expect(events.list.withLock { $0 } == ["rebuilt", "rebuildFailed"])
      #expect(!backend.snapshot.running)
      tap.stop()
    }

    @Test("a layout the device now reports rebuilds; the refused callback's samples never arrive")
    func supportedLayoutChangeRebuilds() throws {
      guard #available(macOS 14.2, *) else { return }
      let backend = FakeBackend()
      backend.bufferChannels = [1]
      let output = Output()
      let events = Events()
      let tap = tap(backend, output, events)
      try tap.start()
      let first = try #require(backend.ingest)
      // 0.1 s of valid mono audio, then the device turns stereo.
      try deliver([Float](repeating: 0.25, count: 4_800), to: first, host: 1_000_000)
      backend.lock.withLock { backend.bufferChannels = [2] }
      try deliver(
        [Float](repeating: 0.9, count: 1_920), to: first, host: 2_000_000, channels: 2)
      try deliver(
        [Float](repeating: 0.9, count: 1_920), to: first, host: 3_000_000, channels: 2)
      tap.drainForTesting()
      #expect(tap.settleForTesting())
      #expect(events.list.withLock { $0 } == ["rebuilt"], "one rebuild for both refusals")
      #expect(tap.health.rebuildReasons == [.layout: 1])
      let second = try #require(backend.ingest)
      for i in 0..<10 {
        try deliver(
          sine(960, rate: 48_000, from: i * 480), to: second,
          host: 90_000_000 + ticks(Double(i) * 0.01), channels: 2)
      }
      tap.drainForTesting()
      tap.stop()
      let samples = output.samples.withLock { $0 }
      #expect(abs(samples.count - (1_600 + 1_600)) <= 64, "the mono audio and 0.1 s of stereo: \(samples.count)")
      #expect(samples.allSatisfy { abs($0) < 0.6 }, "nothing of the 0.9 refused callbacks")
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

  /// One callback of one interleaved buffer; `samples` holds `channels` values per frame.
  private func deliver(
    _ samples: [Float], to ingest: @Sendable (UnsafePointer<AudioBufferList>, UInt64, Bool) -> Void,
    host: UInt64, channels: UInt32 = 1
  ) throws {
    let list = AudioBufferList.allocate(maximumBuffers: 1)
    defer { free(list.unsafeMutablePointer) }
    var copy = samples
    copy.withUnsafeMutableBufferPointer { memory in
      list[0] = AudioBuffer(
        mNumberChannels: channels, mDataByteSize: UInt32(memory.count * 4),
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
      var diagnostics = CallSoundCaptureDiagnostics(
        inputStreams: [SystemAudioTapTests.floatStream(channels: 1)])
      var ingest: (@Sendable (UnsafePointer<AudioBufferList>, UInt64, Bool) -> Void)?
      var onNotice: (@Sendable (CallSoundNotice) -> Void)?
      var refreshes = 0
      /// Simulates a passive registration failing during install.
      var failPassive = false
      func start(
        ingest: @escaping @Sendable (UnsafePointer<AudioBufferList>, UInt64, Bool) -> Void
      ) throws -> CallSoundCapture {
        lock.withLock {
          starts += 1
          self.ingest = ingest
          return capture
        }
      }
      /// Lock held.
      private var capture: CallSoundCapture {
        .init(build: starts, outputUID: outputUID, format: .init(sampleRate: rate))
      }
      var outputUID = "speakers"
      /// Moves the output to another device and reports it, as the system object does.
      func switchOutput(to uid: String) {
        let handler = lock.withLock {
          outputUID = uid
          return onNotice
        }
        handler?(
          CallSoundNotice(
            build: 0, object: 1, selector: kAudioHardwarePropertyDefaultOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal, name: "defaultOutput"))
      }
      func currentCapture() throws -> CallSoundCapture { lock.withLock { capture } }
      func stop() -> Int { 0 }
      func installListeners(
        queue: DispatchQueue, onNotice: @escaping @Sendable (CallSoundNotice) -> Void
      ) -> Bool {
        lock.withLock {
          self.onNotice = onNotice
          if failPassive {
            diagnostics.watchProblems = [
              .init(text: "register streamVirtualFormat object=9 failed", count: 1, current: true)
            ]
          }
        }
        return true
      }
      func removeListeners() -> Bool { true }
      func captureDiagnostics() -> CallSoundCaptureDiagnostics { lock.withLock { diagnostics } }
      func reconcileWatch() -> Bool {
        lock.withLock { refreshes += 1 }
        return true
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
      #expect(tap.settleForTesting())
      #expect(
        backend.lock.withLock { backend.starts } == 1,
        "a notice whose reading matches the commitment never rebuilds")

      backend.switchOutput(to: "airpods")
      #expect(tap.settleForTesting())
      #expect(
        sink.matching("CALL_SOUND build").last?.contains("gen=2 trigger=rebuild reason=outputDevice")
          == true)
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
      backend.switchOutput(to: "airpods")
      #expect(tap.settleForTesting())
      try callbacks(count: 10, start: 90_000_000, valid: false)
      tap.drainForTesting()
      #expect(
        sink.matching("CALL_SOUND measured gen=2")
          == [
            "CALL_SOUND measured gen=2 rate=unavailable configured=48000.0 windows=0 invalid=10/0/0 discontinuitiesTotal=38 qualified=0 rejected=0"
          ])
      tap.stop()
    }

    @Test("a stream format watch that cannot register fails the install, recorded and rolled back")
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
        queue: DispatchQueue(label: "test.listeners"), onNotice: { _ in })
      #expect(!installed)
      #expect(
        backend.captureDiagnostics().watchProblems == [
          .init(text: "register streamVirtualFormat object=31 failed", count: 1, current: true)
        ])
      #expect(backend.listenerCountForTesting == 0)
    }

    @Test("a new stream that cannot be watched, or an unreadable stream list, is reported, not kept quiet")
    func newStreamWatchFailureIsReported() throws {
      guard #available(macOS 14.2, *) else { return }
      let streams = OSAllocatedUnfairLock<[AudioObjectID]?>(initialState: [21])
      let log = OSAllocatedUnfairLock<[AudioObjectID]>(initialState: [])
      let backend = CoreAudioCallSoundBackend(
        addListener: { object, address, _, _ in
          let selector = address.pointee.mSelector
          if selector == kAudioStreamPropertyVirtualFormat { log.withLock { $0.append(object) } }
          return selector == kAudioStreamPropertyVirtualFormat && object == 22
            ? OSStatus(kAudioHardwareUnspecifiedError) : noErr
        },
        removeListener: { _, _, _, _ in noErr },
        streamLister: { _ in streams.withLock { $0 } })
      backend.setTapObjectForTesting(AudioObjectID(4_242))
      backend.setAggregateObjectForTesting(AudioObjectID(UInt32.max - 7))
      let installed = backend.installListeners(
        queue: DispatchQueue(label: "test.listeners"), onNotice: { _ in })
      #expect(installed)
      streams.withLock { $0 = [21, 22] }
      #expect(!backend.reconcileWatch(), "stream 22 arrived and could not be watched")
      #expect(log.withLock { $0 } == [21, 22])
      streams.withLock { $0 = nil }
      #expect(!backend.reconcileWatch(), "an unreadable list is not an unchanged one")
      #expect(backend.removeListeners())
    }

    @Test("a repeated failure is one counted entry, and shows resolved once the read succeeds")
    func repeatedProblemsAreBounded() throws {
      guard #available(macOS 14.2, *) else { return }
      let failing = OSAllocatedUnfairLock(initialState: false)
      let backend = CoreAudioCallSoundBackend(
        addListener: { _, _, _, _ in noErr }, removeListener: { _, _, _, _ in noErr },
        streamLister: { _ in failing.withLock { $0 } ? nil : [5] },
        tapRateReader: { _ in 48_000 })
      backend.setTapObjectForTesting(AudioObjectID(4_242))
      backend.setAggregateObjectForTesting(AudioObjectID(UInt32.max - 7))
      let installed = backend.installListeners(
        queue: DispatchQueue(label: "test.listeners"), onNotice: { _ in })
      #expect(installed)
      failing.withLock { $0 = true }
      for _ in 0..<3 { #expect(!backend.reconcileWatch()) }
      #expect(
        backend.captureDiagnostics().watchProblems == [
          .init(text: "inputStreams unreadable", count: 3, current: true)
        ])
      failing.withLock { $0 = false }
      #expect(backend.reconcileWatch())
      #expect(
        backend.captureDiagnostics().watchProblems == [
          .init(text: "inputStreams unreadable", count: 3, current: false)
        ])
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
      #expect(backend.captureDiagnostics().tapRate == 24_000)
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
      #expect(installed.hasSuffix("watch=[register streamVirtualFormat object=9 failed x1 current]"))
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
        queue: DispatchQueue(label: "test.listeners"), onNotice: { _ in })
      #expect(installed)
      #expect(added.withLock { $0 } == [21, 22])
      streams.withLock { $0 = [22, 23] }
      #expect(backend.reconcileWatch())
      #expect(removed.withLock { $0 } == [21])
      #expect(added.withLock { $0 } == [21, 22, 23])
      #expect(backend.listenerCountForTesting == 6, "output, tap format, rate, stream list, 22, 23")
      #expect(backend.removeListeners())
      #expect(backend.listenerCountForTesting == 0)
    }

    /// Every add and remove a backend makes, as (object, selector, scope).
    private final class Registrations: Sendable {
      let adds = OSAllocatedUnfairLock<[String]>(initialState: [])
      let removes = OSAllocatedUnfairLock<[String]>(initialState: [])
      /// Registrations of this selector fail.
      let failing = OSAllocatedUnfairLock<AudioObjectPropertySelector?>(initialState: nil)
      static func text(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String {
        "\(object):\(CallSoundCaptureDiagnostics.fourCC(address.mSelector)):"
          + CallSoundCaptureDiagnostics.fourCC(address.mScope)
      }
      @available(macOS 14.2, *)
      func backend(streams: [AudioObjectID]) -> CoreAudioCallSoundBackend {
        CoreAudioCallSoundBackend(
          addListener: { [self] object, address, _, _ in
            let entry = Self.text(object, address.pointee)
            let selector = address.pointee.mSelector
            adds.withLock { $0.append(entry) }
            return failing.withLock { $0 } == selector
              ? OSStatus(kAudioHardwareUnspecifiedError) : noErr
          },
          removeListener: { [self] object, address, _, _ in
            let entry = Self.text(object, address.pointee)
            removes.withLock { $0.append(entry) }
            return noErr
          },
          streamLister: { _ in streams })
      }
    }

    @Test("each watch names its object, property and scope; a build's watches go before the system's")
    func listenerBookkeeping() throws {
      guard #available(macOS 14.2, *) else { return }
      let log = Registrations()
      let backend = log.backend(streams: [21, 22])
      let aggregate = AudioObjectID(UInt32.max - 7)
      backend.setTapObjectForTesting(AudioObjectID(4_242))
      backend.setAggregateObjectForTesting(aggregate)
      let installed = backend.installListeners(queue: DispatchQueue(label: "test.listeners"), onNotice: { _ in })
      #expect(installed)
      let expectedAdds = [
        "1:dOut:glob", "4242:tfmt:glob", "\(aggregate):nsrt:glob", "\(aggregate):stm#:inpt",
        "21:sfmt:glob", "22:sfmt:glob",
      ]
      #expect(log.adds.withLock { $0 } == expectedAdds)
      // What stop runs before destroying any object: streams, aggregate, tap; never the system.
      #expect(backend.removeBuildListeners() == 0)
      #expect(
        log.removes.withLock { $0 } == [
          "21:sfmt:glob", "22:sfmt:glob", "\(aggregate):nsrt:glob", "\(aggregate):stm#:inpt",
          "4242:tfmt:glob",
        ])
      #expect(backend.listenerCountForTesting == 1, "the default-output watch outlives the build")
      #expect(backend.removeListeners())
      #expect(log.removes.withLock { $0 }.last == "1:dOut:glob")
      #expect(backend.listenerCountForTesting == 0)
    }

    @Test("a required watch that cannot register fails the install and removes every watch that did")
    func requiredWatchFailureRollsBack() throws {
      guard #available(macOS 14.2, *) else { return }
      for selector in [
        kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyStreams,
        kAudioStreamPropertyVirtualFormat,
      ] {
        let log = Registrations()
        log.failing.withLock { $0 = selector }
        let backend = log.backend(streams: [21])
        backend.setTapObjectForTesting(AudioObjectID(4_242))
        backend.setAggregateObjectForTesting(AudioObjectID(UInt32.max - 7))
        let installed = backend.installListeners(
          queue: DispatchQueue(label: "test.listeners"), onNotice: { _ in })
        #expect(!installed)
        let added = log.adds.withLock { $0 }
        // Everything that registered before the failure, in order, and nothing after it.
        #expect(log.removes.withLock { $0 } == Array(added.dropLast()))
        #expect(backend.listenerCountForTesting == 0)
      }
    }

    @Test("the comparison names the output device first, then the rate, then the layout")
    func changeComparison() {
      guard #available(macOS 14.2, *) else { return }
      let base = CallSoundCapture(
        build: 1, outputUID: "a", format: .init(sampleRate: 48_000, bufferChannels: [2]))
      var other = base
      other.build = 2
      #expect(base.change(to: other) == nil, "the build alone is not a change")
      other.format = .init(sampleRate: 48_000, bufferChannels: [1, 1])
      #expect(base.change(to: other) == .layout)
      other.format = .init(sampleRate: 24_000, bufferChannels: [1, 1])
      #expect(base.change(to: other) == .nominalRate)
      other.outputUID = "b"
      #expect(base.change(to: other) == .outputDevice)
    }
  #endif
}

/// #4117: when these fail, the call-sound track either keeps recording at the wrong speed
/// (a real mismatch never found) or is rebuilt or stopped for a timing glitch that was not a
/// rate change.
@Suite("Call-sound rate check (#4117)", .tags(.productOutcome))
struct CallSoundRateCheckTests {
  typealias Meter = CallSoundPipeline.InputRateMeter
  typealias Streak = CallSoundPipeline.MismatchStreak

  private func ticks(_ seconds: Double) -> UInt64 { CallSoundPipeline.ticks(seconds: seconds) }

  /// Buffers of `lengths` frames whose starts follow `rate` (plus `extra[i]` seconds before
  /// buffer i), from 1 s; returns every event in order.
  private func run(
    _ meter: inout Meter, lengths: [Int], rate: Double, extra: [Int: Double] = [:],
    start: Double = 1
  ) -> [Meter.Event] {
    var time = start
    var events: [Meter.Event] = []
    for (i, frames) in lengths.enumerated() {
      time += extra[i] ?? 0
      events.append(
        meter.observe(
          frames: frames, hostTime: ticks(time), valid: true, afterLoss: false, truncated: false))
      time += Double(frames) / rate
    }
    return events
  }

  private func windows(_ events: [Meter.Event]) -> [Meter.Window] { events.compactMap(\.window) }

  @Test("the call-profile shape (480 frames every 20 ms) qualifies as 24 kHz, window after window")
  func callProfileQualifies() {
    var meter = Meter()
    let found = windows(run(&meter, lengths: Array(repeating: 480, count: 80), rate: 24_000))
    #expect(found.count == 3)
    for window in found {
      #expect(window.qualified)
      #expect(abs(window.rate - 24_000) < 24)
    }
  }

  @Test("seven 128-frame buffers then one of 1,024 qualify at the true rate, healthy or not")
  func variableBuffersQualify() {
    let pattern = Array(repeating: 128, count: 7) + [1_024]
    for rate in [48_000.0, 24_000] {
      var meter = Meter()
      let found = windows(
        run(&meter, lengths: Array(repeating: pattern, count: 60).flatMap { $0 }, rate: rate))
      #expect(found.count >= 3)
      #expect(found.allSatisfy { $0.qualified && abs($0.rate - rate) / rate < 0.01 })
    }
  }

  @Test("a startup gap makes its window an outlier; later windows qualify")
  func startupGapIsRejected() {
    var meter = Meter()
    // 0.15 s of silence before the second buffer: a step 15 times the 10 ms cadence.
    let found = windows(
      run(&meter, lengths: Array(repeating: 480, count: 160), rate: 48_000, extra: [1: 0.15]))
    #expect(found.first?.rejection == .timingOutlier)
    #expect(found.dropFirst().allSatisfy { $0.qualified })
  }

  @Test("recurring small gaps bias the rate without being outliers, and are rejected")
  func recurringGapsAreRejected() {
    var meter = Meter()
    // Every fourth buffer starts 10 ms late: a 2x step, under the 4x bound, but the window rate
    // falls about 20% below the cadence.
    let extra = Dictionary(uniqueKeysWithValues: stride(from: 4, to: 160, by: 4).map { ($0, 0.01) })
    let found = windows(
      run(&meter, lengths: Array(repeating: 480, count: 160), rate: 48_000, extra: extra))
    #expect(!found.isEmpty)
    #expect(found.allSatisfy { $0.rejection == .cadenceDisagrees })
  }

  @Test("healthy jitter of a few percent per buffer still qualifies")
  func jitterQualifies() {
    var meter = Meter()
    // Alternating 2% early and late, never accumulating.
    let extra = Dictionary(
      uniqueKeysWithValues: (1..<160).map { ($0, $0 % 2 == 0 ? -0.0002 : 0.0002) })
    let found = windows(
      run(&meter, lengths: Array(repeating: 480, count: 160), rate: 48_000, extra: extra))
    #expect(found.count >= 3)
    #expect(found.allSatisfy { $0.qualified })
  }

  @Test("too few intervals in a window is not a rate")
  func tooFewIntervals() {
    var meter = Meter()
    // 0.25 s buffers: the window closes after two intervals.
    let found = windows(run(&meter, lengths: Array(repeating: 12_000, count: 6), rate: 48_000))
    #expect(!found.isEmpty)
    #expect(found.allSatisfy { $0.rejection == .tooFewIntervals })
  }

  @Test("the window rule's bounds, at and just past each edge")
  func qualificationBoundaries() {
    // Steps in seconds per frame; a cadence of 1 frame per second makes the arithmetic exact.
    #expect(Meter.qualify(frames: 4, span: 4, steps: [1, 1, 1, 4]).rejection != .timingOutlier)
    #expect(Meter.qualify(frames: 4, span: 4, steps: [1, 1, 1, 4.01]).rejection == .timingOutlier)
    #expect(Meter.qualify(frames: 1_049, span: 1_000, steps: [1, 1, 1]).qualified)
    #expect(
      Meter.qualify(frames: 1_051, span: 1_000, steps: [1, 1, 1]).rejection == .cadenceDisagrees)
    #expect(Meter.qualify(frames: 3, span: 3, steps: [1, 1]).rejection == .tooFewIntervals)
    #expect(Meter.median([3, 1, 2]) == 2)
    #expect(Meter.median([4, 1, 3, 2]) == 2.5)
  }

  @Test("disagreement is more than 5% from the configured rate; three must agree with their median")
  func streakBoundaries() {
    var streak = Streak()
    #expect(streak.add(50_390, configured: 48_000) == .agrees, "4.98% is healthy")
    #expect(streak.add(50_410, configured: 48_000) == .mismatch(count: 1), "5.02% disagrees")
    streak.clear()
    // Spread 9.6% end to end, but each within 5% of the shared median: one streak.
    #expect(streak.add(24_000, configured: 48_000) == .mismatch(count: 1))
    #expect(streak.add(25_150, configured: 48_000) == .mismatch(count: 2))
    #expect(streak.add(26_300, configured: 48_000) == .sustained(25_150))
    // 26,600 is 5.6% from the median 25,200: the streak starts over at it.
    #expect(streak.add(24_000, configured: 48_000) == .mismatch(count: 1))
    #expect(streak.add(25_200, configured: 48_000) == .mismatch(count: 2))
    #expect(streak.add(26_600, configured: 48_000) == .mismatch(count: 1))
    #expect(streak.rates == [26_600])
  }

  @Test("an incompatible estimate restarts the streak; a healthy one clears it")
  func streakRestartsAndClears() {
    var streak = Streak()
    #expect(streak.add(24_000, configured: 48_000) == .mismatch(count: 1))
    #expect(streak.add(24_000, configured: 48_000) == .mismatch(count: 2))
    #expect(streak.add(16_000, configured: 48_000) == .mismatch(count: 1))
    #expect(streak.add(16_000, configured: 48_000) == .mismatch(count: 2))
    #expect(streak.add(48_000, configured: 48_000) == .agrees)
    #expect(streak.rates.isEmpty)
    #expect(streak.add(16_000, configured: 48_000) == .mismatch(count: 1))
    #expect(streak.add(16_000, configured: 48_000) == .mismatch(count: 2))
    #expect(streak.add(16_000, configured: 48_000) == .sustained(16_000))
  }

  // MARK: - Through the pipeline

  private func pipeline(rate: Double) throws -> CallSoundPipeline {
    let p = CallSoundPipeline(onSamples: { _, _, _ in })
    try p.configure(.init(sampleRate: rate, bufferChannels: [1]))
    p.setAccepting(true)
    return p
  }

  private func ingest(
    _ p: CallSoundPipeline, frames: Int, host: UInt64, valid: Bool = true, channels: UInt32 = 1
  ) {
    let list = AudioBufferList.allocate(maximumBuffers: 1)
    defer { free(list.unsafeMutablePointer) }
    let memory = UnsafeMutableBufferPointer<Float>.allocate(capacity: frames * Int(channels))
    memory.initialize(repeating: 0.1)
    defer { memory.deallocate() }
    list[0] = AudioBuffer(
      mNumberChannels: channels, mDataByteSize: UInt32(frames * Int(channels) * 4),
      mData: UnsafeMutableRawPointer(memory.baseAddress))
    p.ingest(UnsafePointer(list.unsafeMutablePointer), hostTime: host, hostTimeValid: valid)
  }

  /// `count` call-profile buffers (480 frames, 20 ms apart) from `start` seconds.
  private func callProfile(_ p: CallSoundPipeline, count: Int, start: Double) {
    for i in 0..<count {
      ingest(p, frames: 480, host: ticks(start + Double(i) * 0.02))
    }
  }

  private func sustained(_ outcomes: [CallSoundPipeline.RateOutcome]) -> Bool {
    outcomes.contains { if case .sustainedMismatch = $0 { true } else { false } }
  }

  /// The outcomes with each sustained rate rounded to the nearest kHz, so tests can compare
  /// order exactly.
  private func shape(_ outcomes: [CallSoundPipeline.RateOutcome]) -> [String] {
    outcomes.map {
      switch $0 {
      case .agreement: "agree"
      case .sustainedMismatch(let rate): "mismatch \(Int((rate / 1_000).rounded()))k"
      }
    }
  }

  @Test("sustained mismatches and agreements are reported in the order the buffers came")
  func outcomesKeepAcquisitionOrder() throws {
    // Mismatch, an invalid time, mismatch again: two sustained outcomes.
    let p = try pipeline(rate: 48_000)
    callProfile(p, count: 80, start: 1)
    ingest(p, frames: 480, host: ticks(2.6), valid: false)
    callProfile(p, count: 80, start: 2.62)
    p.drain()
    #expect(shape(p.takeRateOutcomes()) == ["mismatch 24k", "mismatch 24k"])
    // Mismatch, then 1.2 s at 48 kHz (agreement), then mismatch again.
    let q = try pipeline(rate: 48_000)
    callProfile(q, count: 80, start: 1)
    q.drain()
    for i in 0..<120 { ingest(q, frames: 480, host: ticks(2.6 + Double(i) * 0.01)) }
    q.drain()
    callProfile(q, count: 120, start: 3.8)
    q.drain()
    let order = shape(q.takeRateOutcomes())
    #expect(order.first == "mismatch 24k")
    #expect(order.last == "mismatch 24k")
    #expect(order.dropFirst().dropLast().allSatisfy { $0 == "agree" } && order.count >= 3)
  }

  @Test("a truncated buffer after a time that went backward anchors nothing")
  func truncatedAfterBackwardTimeAnchorsNothing() {
    var meter = Meter()
    _ = meter.observe(frames: 480, hostTime: ticks(1), valid: true, afterLoss: false, truncated: false)
    _ = meter.observe(
      frames: 480, hostTime: ticks(1.01), valid: true, afterLoss: false, truncated: false)
    // Backward and cut short, with many frames: anchored, it would skew the next window.
    let bad = meter.observe(
      frames: 48_000, hostTime: ticks(1.005), valid: true, afterLoss: false, truncated: true)
    #expect(bad.invalidatedBefore && bad.invalidatedAfter)
    let found = windows(run(&meter, lengths: Array(repeating: 480, count: 60), rate: 48_000, start: 1.02))
    let first = try? #require(found.first)
    #expect(first?.qualified == true)
    #expect(abs((first?.rate ?? 0) - 48_000) < 48)
  }

  @Test("three windows in one drain, at 48 kHz configured: one sustained mismatch at 24 kHz")
  func sustainedMismatchInOneDrain() throws {
    let p = try pipeline(rate: 48_000)
    callProfile(p, count: 80, start: 1)
    p.drain()
    let observation = p.inputRateObservation
    #expect(observation.windowsQualified == 3)
    #expect(p.health.discontinuities > 70, "every buffer breaks the converter's run")
    let outcomes = p.takeRateOutcomes()
    #expect(outcomes.count == 1)
    guard case .sustainedMismatch(let found)? = outcomes.first else {
      Issue.record("expected one sustained mismatch: \(outcomes)")
      return
    }
    #expect(abs(found - 24_000) < 24)
    #expect(p.takeRateOutcomes().isEmpty, "taking it reports it once")
    #expect(p.health.rateMismatches == 1)
    _ = p.inputRateObservation
    #expect(p.takeRateOutcomes().isEmpty, "reading the observation never advances the streak")
  }

  @Test("a healthy, an invalid or a refused observation between mismatching windows clears the streak")
  func interruptionsClearTheStreak() throws {
    // Two mismatching windows, then the interruption, then two more: never three in a row.
    let interruptions: [(String, (CallSoundPipeline, Double) -> Void)] = [
      ("invalid time", { p, t in self.ingest(p, frames: 480, host: self.ticks(t), valid: false) }),
      ("refused layout", { p, t in self.ingest(p, frames: 480, host: self.ticks(t), channels: 2) }),
      ("backward time", { p, _ in self.ingest(p, frames: 480, host: self.ticks(0.5)) }),
    ]
    for (name, interrupt) in interruptions {
      let p = try pipeline(rate: 48_000)
      callProfile(p, count: 52, start: 1)
      interrupt(p, 2.04)
      callProfile(p, count: 52, start: 2.06)
      p.drain()
      #expect(!sustained(p.takeRateOutcomes()), "\(name)")
      #expect(p.inputRateObservation.windowsQualified >= 3, "\(name): the windows still measured")
    }
    // A healthy window between: 48 kHz timing at 48 kHz configured.
    let p = try pipeline(rate: 48_000)
    callProfile(p, count: 52, start: 1)
    p.drain()  // the handoff holds 2 s at 48 kHz; drain so nothing is dropped
    // 1.2 s at 48 kHz: at least one whole window inside it agrees.
    for i in 0..<120 { ingest(p, frames: 480, host: ticks(2.04 + Double(i) * 0.01)) }
    callProfile(p, count: 52, start: 3.24)
    p.drain()
    #expect(!sustained(p.takeRateOutcomes()))
    #expect(p.inputRateObservation.windowsAgreeing >= 1)
  }

  @Test("a new configuration starts the streak over")
  func configureResetsTheStreak() throws {
    let p = try pipeline(rate: 48_000)
    callProfile(p, count: 52, start: 1)
    p.drain()
    try p.configure(.init(sampleRate: 48_000, bufferChannels: [1]))
    callProfile(p, count: 30, start: 3)
    p.drain()
    #expect(!sustained(p.takeRateOutcomes()), "two windows before and one after are not three")
  }
}
