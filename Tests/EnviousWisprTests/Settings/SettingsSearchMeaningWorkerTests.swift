import Foundation
import Testing
import os

@testable import EnviousWisprAppKit

/// #3482 chunk 3: the worker that owns the meaning pass for one Settings window session.
/// **When this fails, typing in the Settings search either freezes, shows a result for an older
/// search, or keeps using a broken model instead of falling back to the word
/// results.** The Core ML encoder is replaced by scripted ones; the real encoder is covered by
/// `SettingsSearchMeaningEncoderTests`.
@Suite("Settings search meaning worker (#3482)", .tags(.productOutcome))
struct SettingsSearchMeaningWorkerTests {

  // MARK: - Scripted pieces

  struct ScriptedEncoder: SettingsSearchQueryEncoding {
    struct Boom: Error {}
    let log: OSAllocatedUnfairLock<[String]>
    /// What `encode` returns, per text; anything else gets `fallback`.
    var vectors: [String: [Float]] = [:]
    var fallback: [Float] = [1, 0, 0]
    var failing: Set<String> = []

    func encode(_ text: String) throws -> [Float] {
      log.withLock { $0.append(text) }
      if failing.contains(text) { throw Boom() }
      return vectors[text] ?? fallback
    }
  }

  static let selfTest = [
    SettingsSearchMeaningAssets.Manifest.SelfTest(query: "reference", vector: [1, 0, 0])
  ]

  static func places() -> SettingsSearchPlaceVectors {
    SettingsSearchPlaceVectors(
      dimension: 3, rowCount: 1, textsSHA256: "t",
      entries: ["a": .init(main: ["en": 0], languages: [:])], rows: [1, 0, 0])
  }

  static func loaded(
    _ log: OSAllocatedUnfairLock<[String]>, encoder: ScriptedEncoder? = nil,
    selfTest: [SettingsSearchMeaningAssets.Manifest.SelfTest] = SettingsSearchMeaningWorkerTests
      .selfTest
  ) -> SettingsSearchMeaningWorker.Loaded {
    .init(
      encoder: encoder ?? ScriptedEncoder(log: log), placeVectors: places(), selfTest: selfTest)
  }

  /// A clock the test moves: each call returns the next value of `readings` (nanoseconds).
  static func clock(_ readings: [UInt64]) -> @Sendable () -> UInt64 {
    let state = OSAllocatedUnfairLock(initialState: readings)
    return { state.withLock { $0.count > 1 ? $0.removeFirst() : ($0.first ?? 0) } }
  }

  // MARK: - Ready, skip and fallback

  @Test("a good load is ready, reports its time, and encodes")
  func readyAndEncodes() async {
    let log = OSAllocatedUnfairLock(initialState: [String]())
    let worker = SettingsSearchMeaningWorker(nowNanoseconds: Self.clock([0, 250_000_000])) {
      Self.loaded(log)
    }
    #expect(await worker.ensureLoaded() == .ready(loadMilliseconds: 250))
    #expect(
      await worker.encode("hello", generation: 1) == .vector(generation: 1, values: [1, 0, 0]))
    #expect(await worker.placeVectors != nil)
    // The self-test query ran once at load; the search once after.
    #expect(log.withLock { $0 } == ["reference", "hello"])
  }

  // #3545 (founder 2026-10-09) removed the one-second load budget: a slow load was discarded and
  // meaning stayed off until the app restarted. This replaces its boundary test.
  @Test("a slow load is kept and serves the searches after it")
  func slowLoadIsKept() async {
    let log = OSAllocatedUnfairLock(initialState: [String]())
    // 11.5 s, the first load measured after a restart.
    let worker = SettingsSearchMeaningWorker(nowNanoseconds: Self.clock([0, 11_500_000_000])) {
      Self.loaded(log)
    }
    #expect(await worker.ensureLoaded() == .ready(loadMilliseconds: 11_500))
    #expect(
      await worker.encode("hello", generation: 1) == .vector(generation: 1, values: [1, 0, 0]))
    #expect(await worker.placeVectors != nil)
  }

  @Test("a load that fails is skipped once and never retried in this session")
  func loadFailureFallsBack() async {
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let worker = SettingsSearchMeaningWorker {
      calls.withLock { $0 += 1 }
      throw SettingsSearchMeaningWorker.LoadFailure(reason: .assetsInvalid)
    }
    #expect(await worker.ensureLoaded() == .skipped(.assetsInvalid))
    #expect(await worker.encode("x", generation: 1) == .skipped(.assetsInvalid))
    #expect(await worker.ensureLoaded() == .skipped(.assetsInvalid))
    #expect(calls.withLock { $0 } == 1)

    let other = SettingsSearchMeaningWorker { throw ScriptedEncoder.Boom() }
    #expect(await other.ensureLoaded() == .skipped(.loadFailed))
  }

  @Test("an encoder that does not reproduce the reference vectors is never used")
  func selfTestGuardsTheModel() async {
    let log = OSAllocatedUnfairLock(initialState: [String]())
    // Orthogonal to the reference, not finite, and the wrong length: three different breakages.
    for bad: [Float] in [[0, 1, 0], [.nan, 0, 0], [1, 0]] {
      let worker = SettingsSearchMeaningWorker {
        Self.loaded(log, encoder: ScriptedEncoder(log: log, vectors: ["reference": bad]))
      }
      #expect(await worker.ensureLoaded() == .skipped(.selfTestFailed))
      #expect(await worker.placeVectors == nil)
    }
    // No reference at all is also a failure: an unchecked model is not trusted.
    let unchecked = SettingsSearchMeaningWorker { Self.loaded(log, selfTest: []) }
    #expect(await unchecked.ensureLoaded() == .skipped(.selfTestFailed))
    // A small difference passes (cosine just above 0.999), a larger one does not.
    let close = SettingsSearchMeaningWorker {
      Self.loaded(log, encoder: ScriptedEncoder(log: log, vectors: ["reference": [1, 0.04, 0]]))
    }
    let closeReadiness = await close.ensureLoaded()  // cosine 0.99920
    if case .ready = closeReadiness {} else { Issue.record("cosine 0.9992 was refused: \(closeReadiness)") }
    let far = SettingsSearchMeaningWorker {
      Self.loaded(log, encoder: ScriptedEncoder(log: log, vectors: ["reference": [1, 0.05, 0]]))
    }
    #expect(await far.ensureLoaded() == .skipped(.selfTestFailed))  // cosine 0.99875
  }

  @Test("a search the encoder cannot encode turns the pass off for the session")
  func encodeFailureSkips() async {
    let log = OSAllocatedUnfairLock(initialState: [String]())
    let worker = SettingsSearchMeaningWorker {
      Self.loaded(log, encoder: ScriptedEncoder(log: log, failing: ["bad"]))
    }
    #expect(
      await worker.encode("good", generation: 1) == .vector(generation: 1, values: [1, 0, 0]))
    #expect(await worker.encode("bad", generation: 2) == .skipped(.encodeFailed))
    log.withLock { $0.removeAll() }
    #expect(await worker.encode("good", generation: 3) == .skipped(.encodeFailed))
    #expect(log.withLock { $0.isEmpty }, "the encoder was called after it failed")
    #expect(await worker.placeVectors == nil)
  }

  @Test("missing or damaged assets skip the pass before any model work")
  func realLoaderFailsClosed() async throws {
    let missing = SettingsSearchMeaningWorker.bundled(assets: nil)
    #expect(await missing.ensureLoaded() == .skipped(.assetsMissing))

    let empty = FileManager.default.temporaryDirectory.appendingPathComponent(
      "meaning-empty-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let noManifest = SettingsSearchMeaningWorker.bundled(
      assets: SettingsSearchMeaningAssets(directory: empty))
    #expect(await noManifest.ensureLoaded() == .skipped(.assetsMissing))

    // A manifest that is not the pinned one is refused, whatever it says.
    try Data("{}".utf8).write(to: empty.appendingPathComponent("manifest.json"))
    let wrong = SettingsSearchMeaningWorker.bundled(
      assets: SettingsSearchMeaningAssets(directory: empty))
    #expect(await wrong.ensureLoaded() == .skipped(.assetsInvalid))
  }

  // MARK: - Query generations and cancellation

  /// A loader that waits for the test: `started` fires when the load begins, `release` lets it end.
  struct Gate {
    let started: AsyncStream<Void>
    let startedContinuation: AsyncStream<Void>.Continuation
    let released: AsyncStream<Void>
    let releaseContinuation: AsyncStream<Void>.Continuation

    init() {
      (started, startedContinuation) = AsyncStream<Void>.makeStream()
      (released, releaseContinuation) = AsyncStream<Void>.makeStream()
    }
  }

  @Test("a search the caller has since replaced comes back stale and is never encoded")
  func supersededSearchIsDropped() async {
    let log = OSAllocatedUnfairLock(initialState: [String]())
    let gate = Gate()
    let worker = SettingsSearchMeaningWorker {
      gate.startedContinuation.yield()
      for await _ in gate.released { break }
      return Self.loaded(log)
    }
    let first = Task { await worker.encode("one", generation: 1) }
    for await _ in gate.started { break }
    // The first search is waiting on the load. The caller has typed on.
    await worker.advance(to: 2)
    gate.releaseContinuation.yield()
    #expect(await first.value == .stale(generation: 1))
    #expect(await worker.encode("two", generation: 2) == .vector(generation: 2, values: [1, 0, 0]))
    #expect(log.withLock { $0 } == ["reference", "two"], "the replaced search was encoded")
  }

  @Test("a search whose task was cancelled is stale and is never encoded")
  func cancelledSearchIsDropped() async {
    let log = OSAllocatedUnfairLock(initialState: [String]())
    let gate = Gate()
    let worker = SettingsSearchMeaningWorker {
      gate.startedContinuation.yield()
      for await _ in gate.released { break }
      return Self.loaded(log)
    }
    let task = Task { await worker.encode("cancelled", generation: 1) }
    for await _ in gate.started { break }
    task.cancel()
    gate.releaseContinuation.yield()
    #expect(await task.value == .stale(generation: 1))
    #expect(log.withLock { $0.contains("cancelled") } == false)
  }

  @Test("an older generation arriving after a newer one is stale")
  func lateOlderGenerationIsStale() async {
    let log = OSAllocatedUnfairLock(initialState: [String]())
    let worker = SettingsSearchMeaningWorker { Self.loaded(log) }
    #expect(await worker.encode("new", generation: 5) == .vector(generation: 5, values: [1, 0, 0]))
    #expect(await worker.encode("old", generation: 4) == .stale(generation: 4))
    // Choosing the same generation again is allowed (a retry of the same search).
    #expect(await worker.encode("new", generation: 5) == .vector(generation: 5, values: [1, 0, 0]))
    #expect(log.withLock { $0.contains("old") } == false)
  }

  // MARK: - Window-session reset (#3545 T8)

  /// Every skip reason, written out: true when a window close lets the next session retry it.
  static let retried: [(SettingsSearchMeaningWorker.SkipReason, Bool)] = [
    (.loadFailed, true), (.assetsInvalid, true), (.encodeFailed, true), (.selfTestFailed, true),
    (.assetsMissing, false),
  ]

  @Test("a window close retries a failed load, self-test, bad assets or encode; never missing assets",
    arguments: retried.indices)
  func resetRetriesOnlyTransientFailures(row: Int) async {
    let (reason, retries) = Self.retried[row]
    #expect(Set(Self.retried.map(\.0.rawValue)).count == 5)
    let log = OSAllocatedUnfairLock(initialState: [String]())
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let worker = SettingsSearchMeaningWorker {
      let call = calls.withLock { $0 += 1; return $0 }
      if call == 1 { throw SettingsSearchMeaningWorker.LoadFailure(reason: reason) }
      return Self.loaded(log)
    }
    #expect(await worker.ensureLoaded() == .skipped(reason))
    await worker.resetTransientFailure()
    let after = await worker.ensureLoaded()
    if retries {
      if case .ready = after {} else { Issue.record("\(reason) stayed off: \(after)") }
      #expect(calls.withLock { $0 } == 2, "\(reason) was not loaded again")
    } else {
      #expect(after == .skipped(reason), "\(reason): \(after)")
      #expect(calls.withLock { $0 } == 1, "\(reason) was loaded again")
    }
  }

  /// A loader held at `gate` whose first load ends with `firstFails` (then loads normally).
  static func heldWorker(
    _ gate: Gate, loads: OSAllocatedUnfairLock<Int>, firstFails: Bool
  ) -> SettingsSearchMeaningWorker {
    let log = OSAllocatedUnfairLock(initialState: [String]())
    return SettingsSearchMeaningWorker {
      let call = loads.withLock { $0 += 1; return $0 }
      if call == 1 {
        gate.startedContinuation.yield()
        for await _ in gate.released { break }
        if firstFails { throw SettingsSearchMeaningWorker.LoadFailure(reason: .loadFailed) }
      }
      return Self.loaded(log)
    }
  }

  @Test("a window close while the load runs keeps that load: one load serves both sessions")
  func resetKeepsARunningLoad() async {
    let loads = OSAllocatedUnfairLock(initialState: 0)
    let gate = Gate()
    let worker = Self.heldWorker(gate, loads: loads, firstFails: false)
    let first = Task { await worker.ensureLoaded() }
    for await _ in gate.started { break }
    // The reset waits for the running load; the next session's caller shares it.
    let entered = Latch()
    let reset = Task {
      await worker.resetTransientFailure(willAwaitPreparation: { Task { await entered.open() } })
    }
    // Bounded: a reset that never waits records a failure and still lets the load go.
    #expect(await entered.wait(), "the reset did not wait for the running load")
    let second = Task { await worker.ensureLoaded() }
    gate.releaseContinuation.yield()
    await reset.value
    let readiness = [await first.value, await second.value, await worker.ensureLoaded()]
    #expect(readiness.allSatisfy { if case .ready = $0 { true } else { false } }, "\(readiness)")
    #expect(loads.withLock { $0 } == 1)
  }

  @Test("a load that fails after the window closed is retried by the next window, not inherited")
  func failureAfterCloseIsCleared() async {
    let loads = OSAllocatedUnfairLock(initialState: 0)
    let gate = Gate()
    let worker = Self.heldWorker(gate, loads: loads, firstFails: true)
    let first = Task { await worker.ensureLoaded() }
    for await _ in gate.started { break }
    // The reset is waiting on the running load before the load is allowed to fail.
    let entered = Latch()
    let reset = Task {
      await worker.resetTransientFailure(willAwaitPreparation: { Task { await entered.open() } })
    }
    // Bounded: a reset that never waits records a failure and still lets the load go.
    #expect(await entered.wait(), "the reset did not wait for the running load")
    gate.releaseContinuation.yield()
    #expect(await first.value == .skipped(.loadFailed))
    await reset.value
    let next = await worker.ensureLoaded()
    if case .ready = next {} else { Issue.record("the next window inherited the failure: \(next)") }
    #expect(loads.withLock { $0 } == 2)
  }

  @Test("several callers share one load")
  func oneLoadForConcurrentCallers() async {
    let log = OSAllocatedUnfairLock(initialState: [String]())
    let loads = OSAllocatedUnfairLock(initialState: 0)
    let worker = SettingsSearchMeaningWorker {
      loads.withLock { $0 += 1 }
      return Self.loaded(log)
    }
    async let a = worker.ensureLoaded()
    async let b = worker.ensureLoaded()
    async let c = worker.ensureLoaded()
    let readiness = await [a, b, c]
    #expect(readiness.allSatisfy { if case .ready = $0 { true } else { false } })
    #expect(loads.withLock { $0 } == 1)
  }
}
