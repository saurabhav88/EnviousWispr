import Foundation
import Testing

@testable import EnviousWisprCore

/// Issue #445: signal-based wedge detector tests.
///
/// The watcher is `@MainActor`-isolated; tests must run on `@MainActor`.
/// Synthetic signal streams are injected directly (no real ProgressFile);
/// silence is produced by `Task.sleep` between observations. Sleep durations
/// are deliberately short (50–250ms) and the floor is 800ms / ratio is 5x,
/// so the deterministic-yet-real-time tests still complete in single-digit
/// seconds.
@MainActor
@Suite("LoadProgressWatcher — signal-based wedge detection")
struct LoadProgressWatcherTests {

  /// Helper: sleep for `ms` milliseconds in the host clock.
  private func sleep(ms: Int) async {
    try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
  }

  /// Helper: synthetic mtime. Distinct values trigger "real signal" detection
  /// inside the watcher; identical values are treated as no-op ticks.
  private func mtime(_ index: Int) -> Date {
    Date(timeIntervalSince1970: 1_000_000 + Double(index))
  }

  /// Helper: race `wedged()` against a short bound. Returns true if the watcher
  /// fired within `ms` milliseconds, false otherwise.
  private func didFireWithin(_ ms: Int, watcher: LoadProgressWatcher) async -> Bool {
    let fireTask = Task { @MainActor in
      await watcher.wedged()
      return true
    }
    let timeoutTask = Task { @MainActor () -> Bool in
      try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
      return false
    }
    let result: Bool
    if await fireTask.value == true && !timeoutTask.isCancelled {
      result = true
    } else {
      result = false
    }
    fireTask.cancel()
    timeoutTask.cancel()
    return result
  }

  @Test("Pre-first-signal silence does NOT fire (uncovered case per plan §2.2)")
  func preFirstSignalDoesNotFire() async {
    let watcher = LoadProgressWatcher()
    watcher.start()
    for _ in 0..<20 {
      watcher.observeTick(observedMtime: nil, observedPhase: "")
      await sleep(ms: 50)
    }
    let snap = watcher.snapshot
    #expect(snap.signalCountTotal == 0)
    #expect(snap.firstSignalLatencyMs == nil)
    // No signal ever observed → wedged() must remain pending forever, but
    // stop() must release any awaiter cleanly.
    let waiter = Task { @MainActor in
      await watcher.wedged()
      return true
    }
    await sleep(ms: 100)
    watcher.stop()
    let releasedByStop = await waiter.value
    #expect(releasedByStop, "stop() must release the pending consumer")
  }

  @Test("Steady-cadence ticks do NOT fire — silence stays below floor")
  func steadyCadenceNoFire() async {
    let watcher = LoadProgressWatcher()
    watcher.start()
    for i in 0..<10 {
      watcher.observeTick(observedMtime: mtime(i), observedPhase: "downloading")
      await sleep(ms: 100)
    }
    let snap = watcher.snapshot
    #expect(snap.signalCountTotal == 10)
    #expect(snap.maxGapMs > 50, "max gap observed; precise value depends on CI scheduler")
    #expect(!watcher.hasFired, "steady cadence stays below floor — watcher must not fire")
    watcher.stop()
  }

  @Test("Single signal then long silence does NOT fire (no ratio data)")
  func singleSignalLongSilenceDoesNotFire() async {
    let watcher = LoadProgressWatcher()
    watcher.start()
    // Only ONE real signal — `maxGapSeconds == 0`. Silence then accumulates
    // past the 800ms floor. Without an observed inter-signal gap the watcher
    // must NOT fire (Codex finding 2026-05-07).
    watcher.observeTick(observedMtime: mtime(0), observedPhase: "listing")
    let waiter = Task { @MainActor in
      await watcher.wedged()
      return true
    }
    for _ in 0..<20 {
      watcher.observeTick(observedMtime: mtime(0), observedPhase: "listing")
      await sleep(ms: 60)
    }
    // Silence well over 1 second now; without ratio data, must not fire.
    let snap = watcher.snapshot
    #expect(snap.signalCountTotal == 1)
    #expect(snap.maxGapMs == 0)
    watcher.stop()
    let released = await waiter.value
    #expect(released, "stop() releases the consumer; watcher itself never fired")
  }

  @Test("Below 800ms floor — does NOT fire even if ratio is met")
  func ratioOnlyDoesNotFire() async {
    let watcher = LoadProgressWatcher()
    watcher.start()
    // Two signals 50ms apart → max gap 50ms. Ratio threshold = 250ms.
    watcher.observeTick(observedMtime: mtime(0), observedPhase: "downloading")
    await sleep(ms: 50)
    watcher.observeTick(observedMtime: mtime(1), observedPhase: "downloading")
    // Silence at 300ms exceeds ratio (250ms) but is below floor (800ms).
    for _ in 0..<5 {
      watcher.observeTick(observedMtime: mtime(1), observedPhase: "downloading")
      await sleep(ms: 60)
    }
    // Spawn a wedged() waiter. With stop() called shortly after, it must
    // resolve without ever having fired.
    let waiter = Task { @MainActor in
      await watcher.wedged()
      return true
    }
    await sleep(ms: 100)
    let firedBeforeStop = watcher.hasFired
    watcher.stop()
    _ = await waiter.value
    #expect(!firedBeforeStop, "silence below 800ms floor must not fire even when ratio is met")
  }

  @Test("Both gates met (silence > floor AND silence > 5x max gap) — fires")
  func bothGatesFire() async {
    let watcher = LoadProgressWatcher()
    watcher.start()
    // Establish two inter-signal gaps. The actual gap duration varies with CI
    // scheduler load and determines the ratio threshold (5 * maxGap).
    watcher.observeTick(observedMtime: mtime(0), observedPhase: "compiling")
    await sleep(ms: 150)
    watcher.observeTick(observedMtime: mtime(1), observedPhase: "compiling")
    await sleep(ms: 150)
    watcher.observeTick(observedMtime: mtime(2), observedPhase: "compiling")
    // Feed silence ticks until the watcher fires (both gates met) or a 5-second
    // deadline expires. 5s comfortably exceeds any realistic threshold even when
    // CI load inflates the gap measurement. The watcher fires synchronously inside
    // observeTick(), so hasFired is readable immediately after the loop exits.
    let deadline = ProcessInfo.processInfo.systemUptime + 5.0
    repeat {
      watcher.observeTick(observedMtime: mtime(2), observedPhase: "compiling")
      if watcher.hasFired { break }
      await sleep(ms: 100)
    } while ProcessInfo.processInfo.systemUptime < deadline
    // Assert via the deterministic `hasFired` accessor. Avoids awaiting
    // `wedged()` unconditionally — under heavy CI load the resumed
    // continuation can lag behind the assertion, causing the test to hang
    // until the job-level timeout. The state read is synchronous and safe.
    let snap = watcher.snapshot
    #expect(watcher.hasFired, "Both gates met → watcher must fire")
    #expect(snap.lastObservedPhase == "compiling")
    #expect(snap.signalCountTotal == 3)
    watcher.stop()
  }

  @Test("stop() resumes pending wedged() consumer without firing")
  func stopReleasesWaiterCleanly() async {
    let watcher = LoadProgressWatcher()
    watcher.start()
    let task = Task { @MainActor in
      await watcher.wedged()
      return true
    }
    await sleep(ms: 50)
    watcher.stop()
    let released = await task.value
    #expect(released, "stop() must resume the pending wedged() awaiter")
  }

  @Test("Identical-mtime ticks do NOT count as signals (mtime is the key)")
  func identicalMtimeDoesNotIncrementSignalCount() async {
    let watcher = LoadProgressWatcher()
    watcher.start()
    let m = mtime(0)
    for _ in 0..<10 {
      watcher.observeTick(observedMtime: m, observedPhase: "compiling")
      await sleep(ms: 30)
    }
    let snap = watcher.snapshot
    #expect(snap.signalCountTotal == 1, "Identical mtime must not multiply signal count")
    watcher.stop()
  }

  @Test("raceWithSignalWatcher returns .completed when work wins")
  func raceCompletedPath() async {
    let watcher = LoadProgressWatcher()
    watcher.start()
    let outcome = await raceWithSignalWatcher(watcher: watcher) {
      try await Task.sleep(nanoseconds: 50_000_000)
      return 42
    }
    watcher.stop()
    if case .completed(let value) = outcome {
      #expect(value == 42)
    } else {
      Issue.record("Expected .completed(42), got \(outcome)")
    }
  }

  @Test("raceWithSignalWatcher returns .threw when work throws")
  func raceThrewPath() async {
    struct TestError: Error {}
    let watcher = LoadProgressWatcher()
    watcher.start()
    let outcome: WatcherOutcome<Int> = await raceWithSignalWatcher(watcher: watcher) {
      throw TestError()
    }
    watcher.stop()
    if case .threw = outcome {
      // ok
    } else {
      Issue.record("Expected .threw, got \(outcome)")
    }
  }

  @Test("Snapshot fields are accurate after a successful attempt")
  func snapshotFieldsAccurate() async {
    let watcher = LoadProgressWatcher()
    watcher.start()
    watcher.observeTick(observedMtime: mtime(0), observedPhase: "listing")
    await sleep(ms: 100)
    watcher.observeTick(observedMtime: mtime(1), observedPhase: "downloading")
    await sleep(ms: 200)
    watcher.observeTick(observedMtime: mtime(2), observedPhase: "compiling")
    let snap = watcher.snapshot
    #expect(snap.signalCountTotal == 3)
    #expect(snap.lastObservedPhase == "compiling")
    #expect(snap.firstSignalLatencyMs != nil)
    #expect(snap.maxGapMs > 100, "max gap captured")
    watcher.stop()
  }
}
