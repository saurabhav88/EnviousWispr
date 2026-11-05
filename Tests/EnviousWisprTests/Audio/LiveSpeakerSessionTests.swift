import Foundation
import Testing
import os

@testable import EnviousWisprAudio
@testable import EnviousWisprCore

/// #4355 PR C: the live speaker session's own contract, on a fake model.
///
/// When these fail, live speaker labels land on the wrong audio (a frame mapped to the wrong
/// written position, dropped audio shifting later positions), an old epoch's slot numbers
/// survive a reset, the model runs two steps at once or on the main thread, a refused step
/// still runs during dictation, or a closed session keeps publishing or never releases.
@Suite(.tags(.productOutcome)) struct LiveSpeakerSessionTests {
  static let recording = UUID()

  // MARK: Fixtures

  /// Emits one frame per 160 fed samples on each `process()`, with slot probabilities from
  /// `pattern(globalFrame)`. Records overlap and main-thread use.
  final class FakeRuntime: LiveSpeakerRuntime {
    let stepSamples: Int
    let slotCount = 3
    private var buffered = 0
    private var emitted = 0
    let pattern: @Sendable (Int) -> [Float]
    let probe: Probe
    let gate: DispatchSemaphore?

    init(
      stepSamples: Int = 800, probe: Probe, gate: DispatchSemaphore? = nil,
      pattern: @escaping @Sendable (Int) -> [Float] = { _ in [0.9, 0.1, 0.1] }
    ) {
      self.stepSamples = stepSamples
      self.probe = probe
      self.gate = gate
      self.pattern = pattern
    }

    func append(_ samples: [Float]) { buffered += samples.count }

    func process() throws -> LiveSpeakerFrames {
      probe.enter()
      defer { probe.leave() }
      gate?.wait()
      let frames = buffered / 160
      buffered -= frames * 160
      var probabilities: [Float] = []
      for frame in 0..<frames { probabilities += pattern(emitted + frame) }
      emitted += frames
      if probe.failNext { throw CancellationError() }
      return LiveSpeakerFrames(probabilities: probabilities, frameCount: frames)
    }

    func reset() {
      probe.resets.withLock { $0 += 1 }
      buffered = 0
      emitted = 0
    }

    deinit { probe.deinits.withLock { $0 += 1 } }
  }

  final class Probe: Sendable {
    let active = OSAllocatedUnfairLock(initialState: 0)
    let peak = OSAllocatedUnfairLock(initialState: 0)
    let steps = OSAllocatedUnfairLock(initialState: 0)
    let onMain = OSAllocatedUnfairLock(initialState: false)
    let resets = OSAllocatedUnfairLock(initialState: 0)
    let deinits = OSAllocatedUnfairLock(initialState: 0)
    let fail = OSAllocatedUnfairLock(initialState: false)
    let stepStarted = BoundedWait.Signal()
    var failNext: Bool { fail.withLock { $0 } }

    func enter() {
      if Thread.isMainThread { onMain.withLock { $0 = true } }
      let now = active.withLock {
        $0 += 1
        return $0
      }
      peak.withLock { $0 = max($0, now) }
      steps.withLock { $0 += 1 }
      stepStarted.fire()
    }

    func leave() { active.withLock { $0 -= 1 } }
  }

  /// Every published update, with a signal per awaited condition (fired by the session's own
  /// publication, never by elapsed time).
  final class Recorder: Sendable {
    typealias Wait = (@Sendable ([LiveSpeakerUpdate]) -> Bool, BoundedWait.Signal)
    private struct State: Sendable {
      var updates: [LiveSpeakerUpdate] = []
      var waits: [Wait] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var updates: [LiveSpeakerUpdate] { state.withLock { $0.updates } }

    /// Conditions run OUTSIDE the lock: they may read this recorder's derived counts.
    func record(_ update: LiveSpeakerUpdate) {
      let (updates, waits) = state.withLock { s -> ([LiveSpeakerUpdate], [Wait]) in
        s.updates.append(update)
        return (s.updates, s.waits)
      }
      for wait in waits where wait.0(updates) { wait.1.fire() }
    }

    /// Registers first, then checks the current updates, so no publication is missed.
    func when(_ condition: @escaping @Sendable ([LiveSpeakerUpdate]) -> Bool) -> BoundedWait.Signal {
      let signal = BoundedWait.Signal()
      let updates = state.withLock { s -> [LiveSpeakerUpdate] in
        s.waits.append((condition, signal))
        return s.updates
      }
      if condition(updates) { signal.fire() }
      return signal
    }

    var activities: [LiveSpeakerActivity] {
      updates.flatMap { update -> [LiveSpeakerActivity] in
        if case .activity(let list, _) = update { return list } else { return [] }
      }
    }

    var unpositioned: Int {
      updates.reduce(0) { total, update in
        if case .activity(_, let count) = update { return total + count } else { return total }
      }
    }

    var activityFrames: Int { activities.reduce(0) { $0 + $1.span.sampleCount } / 160 }
  }

  static func span(run: Int = 0, start: Int, count: Int) -> MeetingAudioSpan {
    MeetingAudioSpan(
      recording: recording, track: .callSound, run: run, startSample: start, sampleCount: count)!
  }

  /// `count` samples positioned contiguously from written sample `start`.
  static func chunk(start: Int, count: Int, run: Int = 0) -> MeetingLiveAudioChunk {
    MeetingLiveAudioChunk(
      samples: Array(repeating: 0.1, count: count),
      slices: [MeetingLiveAudioSlice(offset: 0, span: span(run: run, start: start, count: count))])
  }

  struct Harness {
    let session: LiveSpeakerSession
    let recorder: Recorder
    let probe: Probe
    let released: BoundedWait.Signal
    let loadedFrom: OSAllocatedUnfairLock<URL?>
    /// Fired by the loader stub when the load starts (the subject's own signal).
    let loaderEntered: BoundedWait.Signal
  }

  static func make(
    admit: @escaping @Sendable () -> Bool = { true }, backlog: Int = 48_000,
    gate: DispatchSemaphore? = nil, loadGate: BoundedWait.Signal? = nil,
    failLoad: Bool = false, pattern: (@Sendable (Int) -> [Float])? = nil,
    beforeRecord: (@Sendable (LiveSpeakerUpdate) -> Void)? = nil
  ) -> Harness {
    let recorder = Recorder()
    let probe = Probe()
    let released = BoundedWait.Signal()
    let loadedFrom = OSAllocatedUnfairLock<URL?>(initialState: nil)
    let loaderEntered = BoundedWait.Signal()
    let session = LiveSpeakerSession(
      directory: URL(fileURLWithPath: "/admitted/speaker-live"),
      admit: admit, backlogLimitSamples: backlog,
      loader: { url in
        loadedFrom.withLock { $0 = url }
        loaderEntered.fire()
        if let loadGate { try await BoundedWait.until(loadGate) }
        if failLoad { throw CancellationError() }
        if let pattern { return FakeRuntime(probe: probe, gate: gate, pattern: pattern) }
        return FakeRuntime(probe: probe, gate: gate)
      },
      publish: { update in
        beforeRecord?(update)
        recorder.record(update)
      },
      onReleased: { released.fire() })
    return Harness(
      session: session, recorder: recorder, probe: probe, released: released, loadedFrom: loadedFrom,
      loaderEntered: loaderEntered)
  }

  static func isReady(_ updates: [LiveSpeakerUpdate]) -> Bool {
    updates.contains { if case .ready = $0 { return true } else { return false } }
  }

  // MARK: Loading

  @Test func loadsOnlyTheGivenDirectoryAndAFailureIsUnavailableNotReady() async throws {
    let h = Self.make(failLoad: true)
    h.session.start()
    try await BoundedWait.until(h.recorder.when { !$0.isEmpty })
    #expect(h.loadedFrom.withLock { $0 } == URL(fileURLWithPath: "/admitted/speaker-live"))
    #expect(h.recorder.updates == [.unavailable(.loadFailed)])
    h.session.submit(Self.chunk(start: 0, count: 1600))
    h.session.close()
    try await BoundedWait.until(h.released)
    #expect(h.probe.steps.withLock { $0 } == 0)
  }

  // MARK: Steps, order and coverage

  /// Concurrent submitters, one step at a time, never on the main thread, and every written
  /// sample reported once, in order.
  @Test func stepsRunOneAtATimeOffMainAndCoverEveryFedSampleInOrder() async throws {
    let h = Self.make()
    h.session.start()
    try await BoundedWait.until(h.recorder.when(Self.isReady))
    // 20 chunks of 1,600 samples, submitted in order from a detached producer.
    await Task.detached {
      for index in 0..<20 { h.session.submit(Self.chunk(start: index * 1600, count: 1600)) }
    }.value
    try await BoundedWait.until(h.recorder.when { _ in h.recorder.activityFrames == 200 })
    #expect(h.probe.peak.withLock { $0 } == 1)
    #expect(h.probe.onMain.withLock { $0 } == false)
    // 32,000 samples at 800 per step is 40 steps: admission is asked per step, not per chunk.
    #expect(h.probe.steps.withLock { $0 } == 40)
    // One slot talks throughout: merged runs tile 0..<32,000 contiguously, in order.
    var next = 0
    for activity in h.recorder.activities {
      #expect(activity.span.startSample == next)
      #expect(activity.activeSlots == [0])
      next = activity.span.endSample
    }
    #expect(next == 32_000)
    h.session.close()
    try await BoundedWait.until(h.released)
  }

  /// A written gap and an unpositioned stretch inside one chunk: frames over the gap split the
  /// run, frames over unpositioned audio are counted and carry no activity, and overlap keeps
  /// both slots.
  @Test func writtenGapsSplitAndUnpositionedAudioStaysUnresolved() async throws {
    let h = Self.make(pattern: { frame in frame < 5 ? [0.9, 0.8, 0.1] : [0.1, 0.1, 0.9] })
    h.session.start()
    try await BoundedWait.until(h.recorder.when(Self.isReady))
    // 2,400 samples: 0..<800 at written 0, 800..<1,600 at written 10,000, 1,600..<2,400 unknown.
    let chunk = MeetingLiveAudioChunk(
      samples: Array(repeating: 0.1, count: 2400),
      slices: [
        MeetingLiveAudioSlice(offset: 0, span: Self.span(start: 0, count: 800)),
        MeetingLiveAudioSlice(offset: 800, span: Self.span(start: 10_000, count: 800)),
      ])
    h.session.submit(chunk)
    try await BoundedWait.until(
      h.recorder.when { _ in h.recorder.activityFrames + h.recorder.unpositioned == 15 })
    #expect(
      h.recorder.activities == [
        LiveSpeakerActivity(epoch: 0, span: Self.span(start: 0, count: 800), activeSlots: [0, 1]),
        LiveSpeakerActivity(epoch: 0, span: Self.span(start: 10_000, count: 800), activeSlots: [2]),
      ])
    #expect(h.recorder.unpositioned == 5)
    h.session.close()
    try await BoundedWait.until(h.released)
  }

  // MARK: Admission and backlog

  /// While admission refuses, no step runs and the queue stays bounded; once admitted, the
  /// surviving audio is analyzed at ITS written positions (dropped audio never shifts it).
  @Test func refusalRunsNoStepAndTheBoundedBacklogNeverShiftsPositions() async throws {
    let open = OSAllocatedUnfairLock(initialState: false)
    let h = Self.make(admit: { open.withLock { $0 } }, backlog: 4800)
    h.session.start()
    try await BoundedWait.until(h.recorder.when(Self.isReady))
    // While refused, nothing leaves the queue, so its content is decided by the bound alone:
    // 8,000 samples against 4,800 keep the newest 4,800 (3,200..<8,000).
    for index in 0..<5 { h.session.submit(Self.chunk(start: index * 1600, count: 1600)) }
    #expect(h.session.droppedSamples == 3200)
    #expect(h.probe.steps.withLock { $0 } == 0)
    // Admitted. A reset marker (queued AFTER the audio) triggers a drain without adding audio.
    open.withLock { $0 = true }
    h.session.reset()
    try await BoundedWait.until(h.recorder.when { $0.contains(.reset(epoch: 1)) })
    #expect(h.recorder.activityFrames == 30)
    #expect(h.recorder.activities.allSatisfy { $0.epoch == 0 })
    #expect(h.recorder.activities.first?.span.startSample == 3200)
    #expect(h.recorder.activities.last?.span.endSample == 8000)
    h.session.close()
    try await BoundedWait.until(h.released)
  }

  // MARK: Reset

  @Test func resetStartsANewEpochAndRestartsTheModel() async throws {
    let h = Self.make()
    h.session.start()
    try await BoundedWait.until(h.recorder.when(Self.isReady))
    h.session.submit(Self.chunk(start: 0, count: 1600))
    h.session.reset()
    h.session.submit(Self.chunk(start: 1600, count: 1600, run: 1))
    try await BoundedWait.until(h.recorder.when { _ in h.recorder.activityFrames == 20 })
    #expect(h.probe.resets.withLock { $0 } == 1)
    let epochs = h.recorder.activities.map(\.epoch)
    #expect(epochs.first == 0)
    #expect(epochs.last == 1)
    #expect(h.recorder.updates.contains(.reset(epoch: 1)))
    #expect(h.recorder.activities.last?.span.run == 1)
    h.session.close()
    try await BoundedWait.until(h.released)
  }

  // MARK: Teardown

  /// Holds the session for closures created before it exists.
  final class SessionBox: Sendable {
    let session = OSAllocatedUnfairLock<LiveSpeakerSession?>(initialState: nil)
    func close() { session.withLock { $0 }?.close() }
  }

  /// close() from inside the admission predicate, at both admission points: at the claim (the
  /// queue is then empty, so nothing is taken) and mid-chunk (the rest must not be requeued
  /// after close discarded the queue). Nothing is published after the close, and release fires.
  @Test func closeAtEitherAdmissionPointTakesNothingMoreAndPublishesNothingAfter() async throws {
    for closeOnCall in [1, 2] {
      let box = SessionBox()
      let calls = OSAllocatedUnfairLock(initialState: 0)
      let h = Self.make(admit: {
        let call = calls.withLock { $0 += 1; return $0 }
        guard call == closeOnCall else { return true }
        box.close()
        return closeOnCall == 1  // the claim says yes after closing; mid-chunk says no
      })
      box.session.withLock { $0 = h.session }
      h.session.start()
      try await BoundedWait.until(h.recorder.when(Self.isReady))
      // 1,600 samples at 800 per step: call 1 admits the claim, call 2 the second step.
      h.session.submit(Self.chunk(start: 0, count: 1600))
      try await BoundedWait.until(h.released)
      #expect(h.probe.steps.withLock { $0 } == closeOnCall - 1, "close on call \(closeOnCall)")
      let activityCount = h.recorder.updates.filter {
        if case .activity = $0 { true } else { false }
      }.count
      #expect(activityCount == closeOnCall - 1, "close on call \(closeOnCall)")
    }
  }

  /// A publication in progress when close() is called finishes; none starts after close()
  /// returns, including when the callback itself calls close() (no deadlock).
  @Test func noPublicationStartsAfterCloseReturns() async throws {
    let box = SessionBox()
    let closeReturned = OSAllocatedUnfairLock(initialState: false)
    let late = OSAllocatedUnfairLock(initialState: 0)
    let h = Self.make(beforeRecord: { update in
      if closeReturned.withLock({ $0 }) { late.withLock { $0 += 1 } }
      guard case .activity = update else { return }
      box.close()  // from inside the callback, on the session's own thread
      closeReturned.withLock { $0 = true }
    })
    box.session.withLock { $0 = h.session }
    h.session.start()
    try await BoundedWait.until(h.recorder.when(Self.isReady))
    for index in 0..<4 { h.session.submit(Self.chunk(start: index * 1600, count: 1600)) }
    try await BoundedWait.until(h.released)
    #expect(late.withLock { $0 } == 0)
    #expect(h.recorder.activities.count == 1)
    #expect(h.probe.steps.withLock { $0 } == 1)
  }

  /// Close while the load is suspended: nothing is published, the model loaded late is dropped
  /// unused, and release fires once, after the load returned.
  @Test func closeDuringLoadPublishesNothingAndReleasesAfterTheLoadReturns() async throws {
    let loadGate = BoundedWait.Signal()
    let h = Self.make(loadGate: loadGate)
    h.session.start()
    h.session.submit(Self.chunk(start: 0, count: 1600))
    try await BoundedWait.until(h.loaderEntered)
    h.session.close()
    #expect(h.released.hasFired == false)
    loadGate.fire()
    try await BoundedWait.until(h.released)
    #expect(h.recorder.updates.isEmpty)
    #expect(h.probe.steps.withLock { $0 } == 0)
    #expect(h.probe.deinits.withLock { $0 } == 1)
  }

  /// Close while a step runs: close returns at once, the step finishes, nothing of it is
  /// published, release follows the step, and a repeated close does nothing.
  @Test func closeDuringAStepWaitsForItAndPublishesNothingAfter() async throws {
    let gate = DispatchSemaphore(value: 0)
    let h = Self.make(gate: gate)
    h.session.start()
    try await BoundedWait.until(h.recorder.when(Self.isReady))
    h.session.submit(Self.chunk(start: 0, count: 800))
    try await BoundedWait.until(h.probe.stepStarted)
    h.session.close()
    h.session.close()
    #expect(h.released.hasFired == false)
    gate.signal()
    try await BoundedWait.until(h.released)
    #expect(h.recorder.updates == [.ready(epoch: 0)])
    h.session.submit(Self.chunk(start: 800, count: 800))
    #expect(h.probe.steps.withLock { $0 } == 1)
  }

  @Test func aFailingStepEndsTheSessionAsUnavailable() async throws {
    let h = Self.make()
    h.session.start()
    try await BoundedWait.until(h.recorder.when(Self.isReady))
    h.probe.fail.withLock { $0 = true }
    h.session.submit(Self.chunk(start: 0, count: 1600))
    try await BoundedWait.until(h.recorder.when { $0.last == .unavailable(.inferenceFailed) })
    h.probe.fail.withLock { $0 = false }
    h.session.submit(Self.chunk(start: 1600, count: 1600))
    h.session.close()
    try await BoundedWait.until(h.released)
    #expect(h.probe.steps.withLock { $0 } == 1)
  }
}
