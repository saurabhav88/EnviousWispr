import Foundation
import Testing
import os

@testable import EnviousWisprAudio
@testable import EnviousWisprCore

/// The meeting echo worker (#4355 PR B): every admitted microphone interval comes back once, in
/// order, raw untouched, cleaned only when AEC3 is trusted, raw otherwise with the reason.
@Suite("Meeting echo worker", .serialized, .tags(.productOutcome))
struct MeetingEchoCancellerTests {
  static let frame = MeetingEchoCanceller.frameSamples
  static let rate = Int(MeetingAudioFormat.sampleRate)

  /// Runs scheduled work only when the test asks, on the test's own thread.
  final class ManualExecutor: @unchecked Sendable {
    private let queue = OSAllocatedUnfairLock<[@Sendable () -> Void]>(initialState: [])
    private let running = OSAllocatedUnfairLock(initialState: false)
    var schedule: @Sendable (@escaping @Sendable () -> Void) -> Void {
      { work in self.queue.withLock { $0.append(work) } }
    }
    var isRunning: Bool { running.withLock { $0 } }
    func runAll() {
      while let work = queue.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) {
        running.withLock { $0 = true }
        work()
        running.withLock { $0 = false }
      }
    }
  }

  /// Delayed work (the 500 ms deadline) runs only when the test fires it.
  final class ManualTimers: @unchecked Sendable {
    private let pending = OSAllocatedUnfairLock<[(at: UInt64, work: @Sendable () -> Void)]>(
      initialState: [])
    let clock: Clock
    init(clock: Clock) { self.clock = clock }
    var after: @Sendable (UInt64, @escaping @Sendable () -> Void) -> Void {
      { nanos, work in
        let at = self.clock.now() &+ nanos
        self.pending.withLock { $0.append((at, work)) }
      }
    }
    func fireDue() {
      while let work = pending.withLock({ list -> (@Sendable () -> Void)? in
        let now = clock.now()
        guard let index = list.firstIndex(where: { $0.at <= now }) else { return nil }
        return list.remove(at: index).work
      }) { work() }
    }
  }

  final class Clock: @unchecked Sendable {
    private let value = OSAllocatedUnfairLock<(now: UInt64, script: [UInt64])>(
      initialState: (1_000_000_000, []))
    var now: @Sendable () -> UInt64 {
      {
        self.value.withLock { v in
          if !v.script.isEmpty { v.now = v.script.removeFirst() }
          return v.now
        }
      }
    }
    func advance(nanos: UInt64) { value.withLock { $0.now += nanos } }
    /// The next reads return these values, in order.
    func script(_ values: [UInt64]) { value.withLock { $0.script = values } }
  }

  /// Cleans by halving, so cleaned output is distinguishable from raw. `onCapture` runs inside
  /// the native call (the worker is "parked" there while it runs).
  final class FakeBackend: MeetingEchoBackend, @unchecked Sendable {
    var delayEstimate = true
    var failCapture = false
    var failRender = false
    var renders = 0
    var captures = 0
    var resets = 0
    var events: [Character] = []
    /// First and last sample of every render frame AEC3 received.
    var renderEdges: [(Float, Float)] = []
    var onCapture: (() -> Void)?
    let destroyed: OSAllocatedUnfairLock<Bool>
    init(destroyed: OSAllocatedUnfairLock<Bool> = .init(initialState: false)) {
      self.destroyed = destroyed
    }
    deinit { destroyed.withLock { $0 = true } }
    func render(_ frame: UnsafePointer<Float>) -> Bool {
      renders += 1
      events.append("R")
      renderEdges.append((frame[0], frame[MeetingEchoCanceller.frameSamples - 1]))
      return !failRender
    }
    func capture(_ frame: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>) -> Bool {
      captures += 1
      events.append("C")
      if let hook = onCapture {
        onCapture = nil
        hook()
      }
      guard !failCapture else { return false }
      for i in 0..<MeetingEchoCanceller.frameSamples { out[i] = frame[i] * 0.5 }
      return true
    }
    func reset() -> Bool {
      resets += 1
      return true
    }
    func hasDelayEstimate() -> Bool? { delayEstimate }
  }

  struct Rig {
    let recording = UUID()
    let executor = ManualExecutor()
    let clock: Clock
    let timers: ManualTimers
    let canceller: MeetingEchoCanceller
    var micTicks: UInt64 = 10_000_000

    /// The worker creates the fake on its executor; the rig keeps no reference to it.
    init(
      backend: FakeBackend?, schedule: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil
    ) {
      let box = OSAllocatedUnfairLock<FakeBackend?>(initialState: backend)
      self.init(
        makeBackend: {
          let taken: FakeBackend? = box.withLock { b in
            defer { b = nil }
            return b
          }
          return taken
        }, schedule: schedule)
    }

    init(
      makeBackend: @escaping @Sendable () -> MeetingEchoBackend?,
      schedule: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil
    ) {
      let clock = Clock()
      self.clock = clock
      timers = ManualTimers(clock: clock)
      canceller = MeetingEchoCanceller(
        recording: recording, makeBackend: makeBackend, now: clock.now,
        schedule: schedule ?? executor.schedule, after: timers.after)
    }

    func time(_ ticks: UInt64, _ recording: UUID? = nil) -> MeetingAcquisitionTime {
      MeetingAcquisitionTime(
        recording: recording ?? self.recording, hostTicks: ticks, provenance: .estimated)
    }

    func ticks(_ sample: Int) -> UInt64 {
      micTicks &+ MeetingMicrophoneSilence.ticks(forSamples: sample)
    }

    func render(_ count: Int, at sample: Int, value: Float = 0.1) {
      [Float](repeating: value, count: count).withUnsafeBufferPointer {
        canceller.admitRender($0, acquired: time(ticks(sample)), run: 0)
      }
    }

    /// Admits render and microphone for the same span, starting at `sample`.
    @discardableResult
    func feed(_ mic: [Float], at sample: Int, run: Int = 0, render: Bool = true)
      -> MeetingEchoAdmission
    {
      if render { self.render(mic.count, at: sample) }
      return mic.withUnsafeBufferPointer {
        canceller.admitMicrophone($0, acquired: time(ticks(sample)), run: run)
      }
    }
  }

  static func ramp(_ count: Int, from start: Int) -> [Float] {
    (0..<count).map { Float((start + $0) % 1000) / 1000 }
  }

  @Test(
    "arbitrary chunks come back once, in order, raw exact; cleaned only after AEC3 is trusted; the tail is kept"
  )
  func framingOrderTrustAndTail() throws {
    let backend = FakeBackend()
    let rig = Rig(backend: backend)
    let sizes = [100, 250, 37, 333, 160, 1, 959]
    var admitted: [[Float]] = []
    var results: [MeetingEchoResult] = []
    var cursor = 0
    // 3.5 s of microphone in uneven chunks, ending on a partial frame; results taken as they come.
    while cursor < 3 * Self.rate + Self.rate / 2 + 77 {
      let size = sizes[admitted.count % sizes.count]
      let chunk = Self.ramp(size, from: cursor)
      #expect(rig.feed(chunk, at: cursor) == .accepted)
      admitted.append(chunk)
      cursor += size
      rig.executor.runAll()
      results += rig.canceller.takeResults()
    }
    #expect(cursor % Self.frame != 0)
    let deadline = rig.clock.now() + 1_000_000_000
    rig.canceller.close()
    rig.executor.runAll()
    results += rig.canceller.settle(deadline: deadline)

    #expect(results.count == admitted.count)
    for (result, chunk) in zip(results, admitted) {
      #expect(result.raw == chunk)
      #expect(result.cleaned.count == chunk.count)
      if result.substitution == nil {
        #expect(result.cleaned == chunk.map { $0 * 0.5 })
      } else {
        #expect(result.cleaned == chunk)
      }
    }
    #expect(
      zip(results, results.dropFirst()).allSatisfy { $0.acquired.hostTicks < $1.acquired.hostTicks }
    )
    // Trust needs two metric reads (one per 100 frames) with a delay estimate.
    let firstCleaned = try #require(results.firstIndex { $0.substitution == nil })
    #expect(results[..<firstCleaned].allSatisfy { $0.substitution == .reacquiring })
    #expect(results[firstCleaned...].allSatisfy { $0.substitution == nil })
    let rawBeforeTrust = results[..<firstCleaned].reduce(0) { $0 + $1.raw.count }
    #expect(rawBeforeTrust >= 199 * Self.frame && rawBeforeTrust <= 201 * Self.frame + 959)
    #expect(results.last?.substitution == nil)  // the padded closing frame still cleans the tail
    #expect(backend.captures == (cursor + Self.frame - 1) / Self.frame)
    #expect(rig.canceller.nativeReleased)
    #expect(rig.canceller.takeResults().isEmpty)
    #expect(rig.canceller.settle(deadline: deadline).isEmpty)
    #expect(rig.feed([1], at: cursor) == .refusedClosed)
  }

  @Test(
    "no render reference, a missing delay estimate, an unavailable library and a refused frame all stay raw"
  )
  func rawWhenNotTrusted() {
    // No render reference ever reached AEC3.
    let a = Rig(backend: FakeBackend())
    var noReference: [MeetingEchoResult] = []
    for i in 0..<30 {
      a.feed(Self.ramp(Self.frame * 10, from: i), at: i * Self.frame * 10, render: false)
      a.executor.runAll()
      noReference += a.canceller.takeResults()
    }
    #expect(noReference.map(\.substitution) == Array(repeating: .noReference, count: 30))

    // Reference present but AEC3 never reports a delay estimate.
    let noDelay = FakeBackend()
    noDelay.delayEstimate = false
    let b = Rig(backend: noDelay)
    var noDelayResults: [MeetingEchoResult] = []
    for i in 0..<30 {
      b.feed(Self.ramp(Self.frame * 10, from: i), at: i * Self.frame * 10)
      b.executor.runAll()
      noDelayResults += b.canceller.takeResults()
    }
    #expect(noDelayResults.count == 30)
    #expect(noDelayResults.allSatisfy { $0.substitution == .reacquiring && $0.cleaned == $0.raw })

    // The library could not be created.
    let c = Rig(backend: nil)
    c.feed(Self.ramp(400, from: 0), at: 0)
    c.canceller.close()
    c.executor.runAll()
    let unavailable = c.canceller.settle(deadline: c.clock.now())
    #expect(unavailable.map(\.substitution) == [.nativeUnavailable])
    #expect(unavailable.first?.raw == Self.ramp(400, from: 0))

    // The library refuses a frame: raw, and AEC3 is reset before the next frame.
    let failing = FakeBackend()
    failing.failCapture = true
    let d = Rig(backend: failing)
    d.feed(Self.ramp(Self.frame, from: 0), at: 0)
    d.executor.runAll()
    failing.failCapture = false
    d.feed(Self.ramp(Self.frame, from: 1), at: Self.frame)
    d.executor.runAll()
    #expect(d.canceller.takeResults().map(\.substitution) == [.nativeFailure, .reacquiring])
    #expect(failing.resets == 1)
  }

  @Test(
    "waiting microphone audio at 500 ms stays queued; one sample more, or 500 ms of age, comes back raw at once"
  )
  func backlogAndDeadline() {
    let backend = FakeBackend()
    let rig = Rig(backend: backend)
    let half = MeetingEchoCanceller.backlogSamples / 2
    rig.feed(Self.ramp(half, from: 0), at: 0)
    rig.feed(Self.ramp(half, from: half), at: half)
    #expect(rig.canceller.takeResults().isEmpty)  // exactly 500 ms waiting: still queued
    rig.feed([0.25], at: 2 * half)
    let backlog = rig.canceller.takeResults()
    #expect(backlog.map(\.substitution) == [.backlog, .backlog])
    #expect(backlog.map(\.raw.count) == [half, half])

    rig.clock.advance(nanos: MeetingEchoCanceller.backlogNanos + 1)
    rig.feed([0.5], at: 2 * half + 1)
    #expect(rig.canceller.takeResults().map(\.substitution) == [.deadline])
    // Native work never ran: substitution did not wait for it.
    #expect(backend.captures == 0)
    rig.executor.runAll()
    #expect(rig.canceller.takeResults().count == 0)  // the last sample waits for a full frame
    // Stop's deadline passes before the worker finishes the partial frame: raw, once.
    let tail = rig.canceller.settle(deadline: rig.clock.now())
    #expect(tail.map(\.substitution) == [.closed])
    #expect(tail.map(\.raw) == [[0.5]])
    rig.executor.runAll()
    #expect(rig.canceller.takeResults().isEmpty)
    #expect(rig.canceller.nativeReleased)
  }

  @Test(
    "while AEC3 is parked inside a call, Stop settles raw at its deadline, the late result is dropped, and the library is destroyed only after the call returns"
  )
  func parkedNativeCall() {
    let destroyed = OSAllocatedUnfairLock(initialState: false)
    var backend: FakeBackend? = FakeBackend(destroyed: destroyed)
    let rig = Rig(backend: backend)
    var settledInside: [MeetingEchoResult] = []
    var releasedInside = true
    var destroyedInside = true
    backend?.onCapture = {
      // Inside the native call: more audio arrives over the backlog, then Stop's deadline passes.
      rig.feed(Self.ramp(MeetingEchoCanceller.backlogSamples, from: 0), at: Self.frame)
      settledInside = rig.canceller.settle(deadline: rig.clock.now())
      releasedInside = rig.canceller.nativeReleased
      destroyedInside = destroyed.withLock { $0 }
    }
    backend = nil
    rig.feed(Self.ramp(Self.frame, from: 0), at: 0)
    rig.executor.runAll()
    #expect(settledInside.map(\.substitution) == [.backlog, .closed])
    #expect(settledInside.map(\.raw.count) == [Self.frame, MeetingEchoCanceller.backlogSamples])
    #expect(!releasedInside)
    #expect(!destroyedInside)
    // The parked frame returned under an old generation: nothing else comes back.
    #expect(rig.canceller.takeResults().isEmpty)
    #expect(rig.canceller.nativeReleased)
    #expect(destroyed.withLock { $0 })
    rig.canceller.close()
    rig.executor.runAll()
    #expect(rig.canceller.takeResults().isEmpty)
  }

  @Test(
    "a new microphone run or a reset request restarts AEC3 and reacquires before cleaning again")
  func runChangeAndResetRequest() {
    let backend = FakeBackend()
    let rig = Rig(backend: backend)
    var sample = 0
    /// One second of audio on `run`, results taken as they stream; returns them.
    func second(run: Int) -> [MeetingEchoResult] {
      var out: [MeetingEchoResult] = []
      for _ in 0..<10 {
        #expect(rig.feed(Self.ramp(Self.rate / 10, from: sample), at: sample, run: run) == .accepted)
        sample += Self.rate / 10
        rig.executor.runAll()
        out += rig.canceller.takeResults()
      }
      return out
    }
    _ = second(run: 0)
    _ = second(run: 0)
    #expect(second(run: 0).last?.substitution == nil)
    #expect(backend.resets == 0)
    let afterRun = second(run: 1)
    #expect(afterRun.count == 10)
    #expect(afterRun.allSatisfy { $0.substitution == .reacquiring && $0.run == 1 })
    #expect(backend.resets == 1)
    _ = second(run: 1)
    #expect(second(run: 1).last?.substitution == nil)
    rig.canceller.requestReset(.callSoundRebuilt)
    let afterReset = second(run: 1)
    #expect(afterReset.count == 10)
    #expect(afterReset.allSatisfy { $0.substitution == .reacquiring })
    #expect(backend.resets == 2)
  }

  @Test("audio of another meeting is refused or ignored and never reaches AEC3")
  func recordingIsolation() {
    let backend = FakeBackend()
    let rig = Rig(backend: backend)
    let other = UUID()
    let samples = Self.ramp(Self.frame, from: 0)
    samples.withUnsafeBufferPointer {
      rig.canceller.admitRender($0, acquired: rig.time(1, other), run: 0)
      #expect(
        rig.canceller.admitMicrophone($0, acquired: rig.time(1, other), run: 0)
          == .refusedOtherRecording)
    }
    [Float]().withUnsafeBufferPointer {
      #expect(rig.canceller.admitMicrophone($0, acquired: rig.time(1), run: 0) == .refusedEmpty)
    }
    rig.executor.runAll()
    #expect(backend.renders == 0 && backend.captures == 0)
    #expect(rig.canceller.counters.foreignRenderChunks == 1)
  }

  @Test("the production worker reaches the shipped library and removes echo once trusted")
  func shippedLibrary() throws {
    let rig = Rig(makeBackend: { WebRTCEchoBackend() })
    var state: UInt32 = 4355
    let total = 6 * Self.rate
    let render: [Float] = (0..<total).map { _ in
      state = state &* 1_664_525 &+ 1_013_904_223
      return (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.5
    }
    let delay = Self.rate / 25
    let mic = (0..<total).map { $0 >= delay ? render[$0 - delay] * 0.5 : 0 }
    let micTicks = rig.micTicks
    var streamed: [MeetingEchoResult] = []
    for start in stride(from: 0, to: total, by: 480) {
      let ticks = micTicks &+ MeetingMicrophoneSilence.ticks(forSamples: start)
      Array(render[start..<(start + 480)]).withUnsafeBufferPointer {
        rig.canceller.admitRender($0, acquired: rig.time(ticks), run: 0)
      }
      Array(mic[start..<(start + 480)]).withUnsafeBufferPointer {
        _ = rig.canceller.admitMicrophone($0, acquired: rig.time(ticks), run: 0)
      }
      rig.executor.runAll()
      streamed += rig.canceller.takeResults()
    }
    rig.canceller.close()
    rig.executor.runAll()
    let all = streamed + rig.canceller.settle(deadline: rig.clock.now())
    #expect(all.reduce(0) { $0 + $1.raw.count } == total)
    let counters = rig.canceller.counters
    #expect(counters.capturedFrames == total / Self.frame)
    #expect(counters.renderFrames == total / Self.frame)
    let lastSecond = all.suffix(Self.rate / 480)
    #expect(lastSecond.allSatisfy { $0.substitution == nil })
    let before = lastSecond.reduce(0.0) { $0 + $1.raw.reduce(0.0) { $0 + Double($1 * $1) } }
    let after = lastSecond.reduce(0.0) { $0 + $1.cleaned.reduce(0.0) { $0 + Double($1 * $1) } }
    #expect(after < before * 0.1, "echo energy kept: \(after / before)")
  }

  @Test(
    "every store is bounded: an oversized microphone chunk is raw at once, untaken results refuse new audio, render is capped"
  )
  func everyStoreIsBounded() {
    let backend = FakeBackend()
    let rig = Rig(backend: backend)
    // One chunk longer than the backlog bound: refused before it is copied; the caller keeps it.
    let big = Self.ramp(MeetingEchoCanceller.backlogSamples + 1, from: 0)
    #expect(rig.feed(big, at: 0, render: false) == .refusedTooLong)
    rig.executor.runAll()
    #expect(rig.canceller.takeResults().isEmpty)
    #expect(backend.captures == 0)

    // Results nobody takes: past 2 s settled, new microphone audio is refused (and stays the caller's).
    var sample = big.count
    var refusedAt: Int?
    for _ in 0..<40 {
      let outcome = rig.feed(Self.ramp(Self.frame * 10, from: sample), at: sample)
      sample += Self.frame * 10
      rig.executor.runAll()
      if outcome == .refusedResultsNotTaken {
        refusedAt = sample
        break
      }
    }
    #expect(refusedAt != nil)
    let taken = rig.canceller.takeResults().reduce(0) { $0 + $1.raw.count }
    #expect(taken > MeetingEchoCanceller.readyCapacitySamples)
    #expect(taken <= MeetingEchoCanceller.readyCapacitySamples + Self.frame * 10)
    #expect(rig.feed(Self.ramp(Self.frame, from: sample), at: sample) == .accepted)

    // A render chunk over 1 s keeps its newest second.
    let r = Rig(backend: FakeBackend())
    r.render(MeetingEchoCanceller.renderCapacitySamples + 4000, at: 0)
    #expect(r.canceller.counters.renderSamplesDropped == 4000)

    // Render with no microphone: the worker keeps at most 1 s of it.
    let q = Rig(backend: FakeBackend())
    for i in 0..<30 {
      q.render(1600, at: i * 1600)
      q.executor.runAll()
    }
    q.feed(Self.ramp(Self.frame, from: 0), at: 30 * 1600, render: false)
    q.executor.runAll()
    #expect(
      q.canceller.counters.renderSamplesDropped >= 30 * 1600
        - MeetingEchoCanceller.renderCapacitySamples - 1600)
  }

  @Test(
    "render reaches AEC3 only up to the end of each microphone frame, across chunk sizes and arrival order"
  )
  func renderStopsAtTheFrameBoundary() {
    let backend = FakeBackend()
    let rig = Rig(backend: backend)
    // 480 render samples and a 160-sample microphone frame starting together: one render frame first.
    rig.render(480, at: 0)
    rig.feed(Self.ramp(Self.frame, from: 0), at: 0, render: false)
    rig.executor.runAll()
    #expect(String(backend.events) == "RC")
    // The next two frames use the rest of that chunk, one render frame each.
    rig.feed(Self.ramp(Self.frame * 2, from: 160), at: Self.frame, render: false)
    rig.executor.runAll()
    #expect(String(backend.events) == "RCRCRC")
    // Microphone ahead of its render: the frame is cleaned without it; the late render is fed next time.
    rig.feed(Self.ramp(Self.frame, from: 480), at: 3 * Self.frame, render: false)
    rig.executor.runAll()
    rig.render(100, at: 3 * Self.frame)
    rig.render(220, at: 3 * Self.frame + 100)
    rig.feed(Self.ramp(Self.frame, from: 640), at: 4 * Self.frame, render: false)
    rig.executor.runAll()
    #expect(String(backend.events) == "RCRCRCCRRC")
  }

  @Test("a refused render frame ends trust at once: that frame is raw and AEC3 reacquires")
  func renderFailureEndsTrust() {
    let backend = FakeBackend()
    let rig = Rig(backend: backend)
    var sample = 0
    var trusted: [MeetingEchoResult] = []
    for _ in 0..<30 {
      #expect(rig.feed(Self.ramp(Self.rate / 10, from: sample), at: sample) == .accepted)
      sample += Self.rate / 10
      rig.executor.runAll()
      trusted += rig.canceller.takeResults()
    }
    #expect(trusted.last?.substitution == nil)
    backend.failRender = true
    rig.feed(Self.ramp(Self.frame, from: sample), at: sample)
    sample += Self.frame
    rig.executor.runAll()
    backend.failRender = false
    rig.feed(Self.ramp(Self.frame, from: sample), at: sample)
    rig.executor.runAll()
    #expect(rig.canceller.takeResults().map(\.substitution) == [.nativeFailure, .reacquiring])
    #expect(backend.resets == 1)
  }

  @Test(
    "with AEC3 parked on another thread and no further input, the 500 ms deadline settles raw, and the late result is dropped"
  )
  func deadlineFiresWhileNativeIsParked() {
    let arrived = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let drained = DispatchSemaphore(value: 0)
    let backend = FakeBackend()
    backend.onCapture = {
      arrived.signal()
      _ = release.wait(timeout: .now() + 10)  // deadline-fallback: the test releases it below
    }
    let queue = DispatchQueue(label: "test.echo.worker")
    let rig = Rig(
      backend: backend,
      schedule: { work in
        queue.async {
          work()
          drained.signal()
        }
      })
    rig.feed(Self.ramp(Self.frame, from: 0), at: 0)
    #expect(arrived.wait(timeout: .now() + 10) == .success)  // deadline-fallback: bounded signal wait
    rig.clock.advance(nanos: MeetingEchoCanceller.backlogNanos + 1)
    rig.timers.fireDue()
    let settled = rig.canceller.takeResults()
    #expect(settled.map(\.substitution) == [.deadline])
    #expect(settled.first?.cleaned == settled.first?.raw)
    release.signal()
    while drained.wait(timeout: .now() + 10) == .success {  // deadline-fallback: bounded signal wait
      if rig.canceller.counters.capturedFrames == 1 { break }
    }
    #expect(rig.canceller.counters.capturedFrames == 1)
    #expect(rig.canceller.takeResults().isEmpty)
  }

  @Test("settle never traps when the clock crosses its deadline between reads")
  func settleReadsTheClockOnce() {
    let rig = Rig(backend: FakeBackend())
    rig.feed([0.5], at: 0)
    let deadline: UInt64 = 5_000_000_000
    rig.clock.script([deadline - 1, deadline + 1, deadline + 1, deadline + 1])
    let results = rig.canceller.settle(deadline: deadline)
    #expect(results.map(\.substitution) == [.closed])
  }

  @Test(
    "the library is created on the worker executor, once, even when admission and Stop come first")
  func nativeCreatedOnTheWorker() {
    let created = OSAllocatedUnfairLock(initialState: [Bool]())
    let executor = ManualExecutor()
    let rig = Rig(
      makeBackend: {
        created.withLock { $0.append(executor.isRunning) }
        return FakeBackend()
      },
      schedule: executor.schedule)
    #expect(created.withLock { $0 }.isEmpty)
    rig.feed(Self.ramp(300, from: 0), at: 0)
    rig.canceller.close()
    #expect(created.withLock { $0 }.isEmpty)
    executor.runAll()
    #expect(created.withLock { $0 } == [true])
    let results = rig.canceller.settle(deadline: rig.clock.now())
    #expect(results.map(\.raw.count) == [300])
    #expect(results.first?.substitution == .reacquiring)
    #expect(rig.canceller.nativeReleased)
  }

  @Test(
    "refused microphone audio breaks the stream: after trust, the next accepted interval reacquires"
  )
  func refusedAudioEndsTrust() {
    let backend = FakeBackend()
    let rig = Rig(backend: backend)
    var sample = 0
    func trustedSecondsOfAudio(_ seconds: Int) {
      for _ in 0..<(seconds * 10) {
        rig.feed(Self.ramp(Self.rate / 10, from: sample), at: sample)
        sample += Self.rate / 10
        rig.executor.runAll()
        _ = rig.canceller.takeResults()
      }
    }
    trustedSecondsOfAudio(3)
    rig.feed(Self.ramp(Self.frame, from: sample), at: sample)
    sample += Self.frame
    rig.executor.runAll()
    #expect(rig.canceller.takeResults().map(\.substitution) == [nil])

    // Too long: refused, and the next interval is not contiguous with the last one cleaned.
    #expect(
      rig.feed(Self.ramp(MeetingEchoCanceller.backlogSamples + 1, from: sample), at: sample)
        == .refusedTooLong)
    sample += MeetingEchoCanceller.backlogSamples + 1
    rig.feed(Self.ramp(Self.frame, from: sample), at: sample)
    sample += Self.frame
    rig.executor.runAll()
    #expect(rig.canceller.takeResults().map(\.substitution) == [.reacquiring])
    #expect(backend.resets == 1)

    // Results not taken: refused; after they are taken, the next interval reacquires too.
    trustedSecondsOfAudio(3)
    var refused = false
    for _ in 0..<40 where !refused {
      refused =
        rig.feed(Self.ramp(Self.frame * 10, from: sample), at: sample) == .refusedResultsNotTaken
      sample += Self.frame * 10
      rig.executor.runAll()
    }
    #expect(refused)
    let backlog = rig.canceller.takeResults()
    #expect(backlog.last?.substitution == nil)
    rig.feed(Self.ramp(Self.frame, from: sample), at: sample)
    rig.executor.runAll()
    #expect(rig.canceller.takeResults().map(\.substitution) == [.reacquiring])
    #expect(backend.resets == 2)
  }

  @Test("a reset never joins reference from before it to reference after it")
  func resetDropsPartialReference() {
    let backend = FakeBackend()
    let rig = Rig(backend: backend)
    // 100 old reference samples wait as a partial render frame.
    rig.render(100, at: 0, value: 0.1)
    rig.feed(Self.ramp(Self.frame, from: 0), at: 0, render: false)
    rig.executor.runAll()
    #expect(backend.renderEdges.isEmpty)
    rig.canceller.requestReset(.callSoundRebuilt)
    rig.render(480, at: Self.frame, value: 0.9)
    rig.feed(Self.ramp(Self.frame, from: 160), at: Self.frame, render: false)
    rig.executor.runAll()
    #expect(backend.resets == 1)
    #expect(!backend.renderEdges.isEmpty)
    #expect(backend.renderEdges.allSatisfy { $0.0 == 0.9 && $0.1 == 0.9 })

    // Render inbox overflow drops the queued reference too.
    let other = FakeBackend()
    let r = Rig(backend: other)
    r.render(100, at: 0, value: 0.1)
    r.feed(Self.ramp(Self.frame, from: 0), at: 0, render: false)
    r.executor.runAll()
    // Over 1 s: the newest second is kept, so it starts 400 samples later, at sample 560.
    r.render(MeetingEchoCanceller.renderCapacitySamples + 400, at: Self.frame, value: 0.9)
    r.feed(Self.ramp(Self.frame, from: 560), at: Self.frame + 400, render: false)
    r.executor.runAll()
    #expect(other.resets == 1)
    #expect(!other.renderEdges.isEmpty)
    #expect(other.renderEdges.allSatisfy { $0.0 == 0.9 && $0.1 == 0.9 })

    // Old reference still waiting in the inbox (the worker has not run) when the reset comes.
    let inbox = FakeBackend()
    let i = Rig(backend: inbox)
    i.render(100, at: 0, value: 0.1)
    i.canceller.requestReset(.callSoundRebuilt)
    i.render(480, at: 0, value: 0.9)
    i.feed(Self.ramp(Self.frame, from: 0), at: 0, render: false)
    i.executor.runAll()
    #expect(!inbox.renderEdges.isEmpty)
    #expect(inbox.renderEdges.allSatisfy { $0.0 == 0.9 && $0.1 == 0.9 })
    #expect(i.canceller.counters.renderSamplesDropped == 100)
  }
}
