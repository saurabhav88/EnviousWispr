import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprAudio
@testable import EnviousWisprPipeline

// MARK: - VADMonitorLoopTests (#1060)
//
// Unit coverage for the one-shot approaching-cap warning added to the shared
// VAD monitor loop. Drives the XPC branch (detector == nil) with an injected
// `now` clock so threshold crossings are exercised without real-time waits in
// the assertions (the loop's inter-poll sleep still runs, kept to ≤2 iterations).

@MainActor
@Suite struct VADMonitorLoopTests {

  /// Records the loop's callbacks. `@MainActor` so the loop's `@MainActor`
  /// closures mutate it without data races; `keepRecording` flips it off.
  @MainActor final class Recorder {
    var warningRemaining: [TimeInterval] = []
    var stops: [VADStopReason] = []
    var keepRecording = true
    var ticks = 0
  }

  private static let start = Date(timeIntervalSince1970: 1_000_000)

  @Test("warning fires exactly once when elapsed crosses maxDuration - lead")
  func warningFiresOnceAtThreshold() async {
    let rec = Recorder()
    // elapsed 250s: past the 240s threshold (300 - 60), before the 300s cap.
    await VADMonitorLoop.run(
      detector: nil, vadAutoStop: true,
      maxDuration: 300, warningLead: 60,
      recordingStartTime: Self.start,
      sampleProvider: { [] },
      isRecording: { rec.keepRecording },
      now: { Self.start.addingTimeInterval(250) },
      onApproachingMaxDuration: { remaining in
        rec.warningRemaining.append(remaining)
        rec.keepRecording = false  // exit the loop after the warning
      },
      onStop: { rec.stops.append($0) }
    )
    #expect(rec.warningRemaining.count == 1)
    #expect(abs((rec.warningRemaining.first ?? 0) - 50) < 0.001)  // 300 - 250
    #expect(rec.stops.isEmpty)
  }

  @Test("no warning when recording stops before the threshold")
  func noWarningIfStoppedEarly() async {
    let rec = Recorder()
    rec.keepRecording = false  // loop body never runs
    await VADMonitorLoop.run(
      detector: nil, vadAutoStop: true,
      maxDuration: 300, warningLead: 60,
      recordingStartTime: Self.start,
      sampleProvider: { [] },
      isRecording: { rec.keepRecording },
      now: { Self.start.addingTimeInterval(100) },
      onApproachingMaxDuration: { rec.warningRemaining.append($0) },
      onStop: { rec.stops.append($0) }
    )
    #expect(rec.warningRemaining.isEmpty)
    #expect(rec.stops.isEmpty)
  }

  @Test("no warning when maxDuration is not greater than the lead")
  func noWarningWhenCapTooShort() async {
    let rec = Recorder()
    // maxDuration 30 <= lead 60 → warning disarmed. Run ≤2 body iterations.
    await VADMonitorLoop.run(
      detector: nil, vadAutoStop: true,
      maxDuration: 30, warningLead: 60,
      recordingStartTime: Self.start,
      sampleProvider: { [] },
      isRecording: {
        rec.ticks += 1
        return rec.ticks <= 2
      },
      now: { Self.start.addingTimeInterval(25) },  // past any threshold, below cap
      onApproachingMaxDuration: { rec.warningRemaining.append($0) },
      onStop: { rec.stops.append($0) }
    )
    #expect(rec.warningRemaining.isEmpty)
    #expect(rec.stops.isEmpty)
  }

  @Test("max-duration stop fires at the cap and pre-empts the warning")
  func stopFiresAtCapBeforeWarning() async {
    let rec = Recorder()
    await VADMonitorLoop.run(
      detector: nil, vadAutoStop: true,
      maxDuration: 300, warningLead: 60,
      recordingStartTime: Self.start,
      sampleProvider: { [] },
      isRecording: { rec.keepRecording },
      now: { Self.start.addingTimeInterval(300) },  // == cap
      onApproachingMaxDuration: {
        rec.warningRemaining.append($0)
        rec.keepRecording = false
      },
      onStop: {
        rec.stops.append($0)
        rec.keepRecording = false
      }
    )
    #expect(rec.stops == [.maxDuration])
    // The cap check precedes the warning check, so no warning fires at exactly the cap.
    #expect(rec.warningRemaining.isEmpty)
  }

  // MARK: - First-chunk observation (#1780)
  //
  // The started/completed pair is the diagnostic added for #1780: a crash with
  // `started` present and `completed` absent localises a fatal failure to
  // first-chunk processing, which contains the CoreML path seen in the
  // production crash.
  // These tests freeze the ordering the pair depends on, the once-per-run
  // latch, and the caught-error path.

  /// Lock-backed because the fake `StreamingVad` is an actor while the loop's
  /// callbacks are `@MainActor` — both write this trace, so it is genuinely
  /// cross-actor and needs real synchronisation, not an unlocked box.
  final class Trace: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private var chunks = 0

    func record(_ event: String) { lock.withLock { entries.append(event) } }
    func countChunk() { lock.withLock { chunks += 1 } }
    var events: [String] { lock.withLock { entries } }
    var chunkCount: Int { lock.withLock { chunks } }
  }

  /// Records entry and exit around the real `SilenceDetector.processChunk`, so
  /// the callbacks can be proven to bracket the actual VAD work.
  actor TracingVad: StreamingVad {
    private let trace: Trace
    private let shouldThrow: Bool

    init(trace: Trace, shouldThrow: Bool = false) {
      self.trace = trace
      self.shouldThrow = shouldThrow
    }

    struct Boom: Error {}

    func processStreamingChunk(
      _ audioChunk: [Float],
      state: VadStreamState,
      config: VadSegmentationConfig,
      returnSeconds: Bool,
      timeResolution: Int
    ) async throws -> VadStreamResult {
      trace.record("vad_enter")
      trace.countChunk()
      if shouldThrow {
        trace.record("vad_throw")
        throw Boom()
      }
      trace.record("vad_exit")
      var next = state
      next.processedSamples += audioChunk.count
      return VadStreamResult(state: next, event: nil, probability: 0.0)
    }
  }

  /// Deterministic monotonic clock: returns the scripted values in order, then
  /// repeats the last one. No real time enters any assertion.
  @MainActor final class ScriptedClock {
    private var values: [TimeInterval]
    private var index = 0
    init(_ values: [TimeInterval]) { self.values = values }
    func next() -> TimeInterval {
      let v = values[min(index, values.count - 1)]
      index += 1
      return v
    }
  }

  @MainActor final class ChunkRecorder {
    var started: [Double] = []
    var completed: [(Double, Bool)] = []
    var stops: [VADStopReason] = []
  }

  private static func samples(chunks: Int) -> [Float] {
    [Float](repeating: 0.0, count: SilenceDetector.chunkSize * chunks)
  }

  /// Drives the real `SilenceDetector` over `chunkCount` chunks, stopping the
  /// loop on a SIGNAL (chunks actually processed), never a wall-clock wait.
  private static func runLoop(
    trace: Trace,
    rec: ChunkRecorder,
    clock: ScriptedClock,
    chunkCount: Int,
    shouldThrow: Bool = false
  ) async throws {
    let vad = TracingVad(trace: trace, shouldThrow: shouldThrow)
    let detector = SilenceDetector(makeStreamingVad: { vad })
    try await detector.prepare()

    await VADMonitorLoop.run(
      detector: detector, vadAutoStop: true,
      maxDuration: 3600, warningLead: 0,
      recordingStartTime: Self.start,
      sampleProvider: { samples(chunks: chunkCount) },
      isRecording: { trace.chunkCount < chunkCount },
      now: { Self.start },
      onApproachingMaxDuration: { _ in },
      onStop: { rec.stops.append($0) },
      monotonicNow: { clock.next() },
      onFirstChunkStarted: { ms in
        rec.started.append(ms)
        trace.record("started")
      },
      onFirstChunkCompleted: { ms, stop in
        rec.completed.append((ms, stop))
        trace.record("completed")
      }
    )
  }

  @Test("first-chunk callbacks bracket the VAD call and carry injected timings")
  func firstChunkOrderingAndMeasurement() async throws {
    let trace = Trace()
    let rec = ChunkRecorder()
    // run entry 100.0 -> marker emitted 100.5 -> chunk start 100.75 -> end 100.875.
    // The 0.25s gap between marker and chunk start is the synchronous cost of the
    // `started` telemetry write. `chunk_processing_latency_ms` must EXCLUDE it:
    // 125ms, not 375ms. Timing the chunk from before the callback would report
    // 375 and silently fold telemetry cost into a metric named for chunk work.
    //
    // Every value is an exact binary fraction (x.5 / x.75 / x.875) so the
    // subtractions are exact and the assertions can compare with ==. 100.6 is
    // not representable and leaves residue (150.00000000000568), which is the
    // classic FP-boundary trap in scripted-clock tests.
    let clock = ScriptedClock([100.0, 100.5, 100.75, 100.875])

    try await Self.runLoop(trace: trace, rec: rec, clock: clock, chunkCount: 1)

    #expect(trace.events == ["started", "vad_enter", "vad_exit", "completed"])
    #expect(rec.started == [500.0])
    #expect(rec.completed.count == 1)
    #expect(
      rec.completed.first?.0 == 125.0,
      "chunk latency must exclude the started-marker write")
    #expect(rec.completed.first?.1 == false)
  }

  @Test("first-chunk pair fires once per run even though later chunks process")
  func firstChunkLatchIsOncePerRun() async throws {
    let trace = Trace()
    let rec = ChunkRecorder()
    let clock = ScriptedClock([10.0, 10.1, 10.1, 10.2])

    try await Self.runLoop(trace: trace, rec: rec, clock: clock, chunkCount: 3)

    #expect(trace.chunkCount == 3)
    #expect(rec.started.count == 1)
    #expect(rec.completed.count == 1)
    #expect(trace.events.filter { $0 == "started" }.count == 1)
    #expect(trace.events.filter { $0 == "completed" }.count == 1)
  }

  @Test("a second run emits its own fresh first-chunk pair")
  func firstChunkPairIsFreshPerRun() async throws {
    let rec = ChunkRecorder()

    let trace1 = Trace()
    try await Self.runLoop(
      trace: trace1, rec: rec, clock: ScriptedClock([0.0, 0.25, 0.25, 0.5]), chunkCount: 1)
    let trace2 = Trace()
    try await Self.runLoop(
      trace: trace2, rec: rec, clock: ScriptedClock([0.0, 0.75, 0.75, 1.0]), chunkCount: 1)

    #expect(rec.started == [250.0, 750.0])
    #expect(rec.completed.count == 2)
    #expect(rec.completed.map(\.1) == [false, false])
  }

  @Test("a thrown StreamingVad error still emits both callbacks with shouldStop false")
  func firstChunkPairSurvivesCaughtVadError() async throws {
    let trace = Trace()
    let rec = ChunkRecorder()
    let clock = ScriptedClock([5.0, 5.1, 5.1, 5.3])

    // `SilenceDetector.processChunk` is non-throwing: it catches the underlying
    // StreamingVad error and returns false. There is no throwing path out of it,
    // so the pair must still complete.
    try await Self.runLoop(
      trace: trace, rec: rec, clock: clock, chunkCount: 1, shouldThrow: true)

    #expect(trace.events == ["started", "vad_enter", "vad_throw", "completed"])
    #expect(rec.started.count == 1)
    #expect(rec.completed.count == 1)
    #expect(rec.completed.first?.1 == false)
    #expect(rec.stops.isEmpty)
  }
}
