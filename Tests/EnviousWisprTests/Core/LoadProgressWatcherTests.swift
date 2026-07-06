import Foundation
import Testing

@testable import EnviousWisprCore

/// Issue #445: signal-based wedge detector tests.
///
/// Issue #782: timing-coupled tests migrated to a `ManualClock` seam so the
/// suite no longer depends on real `Task.sleep` for the SUT's measured cadence.
/// Each test that drives an asserted threshold passes a manual clock to the
/// watcher and advances it deterministically with `tick(seconds:)` — including
/// pre-first-signal, which crosses the fire floor in logical time and asserts
/// `hasFired == false` (#881 TO-1). Tests whose sleeps are non-load-bearing
/// (identical-mtime, stop() release, raceWithSignalWatcher orchestration) keep
/// real `Task.sleep` because the sleep duration does not feed any asserted
/// measurement. The one real `Task.sleep` that survives in pre-first-signal is
/// the 100ms continuation-park before `stop()`, which is scheduling, not a
/// measured cadence.
///
/// The watcher is `@MainActor`-isolated; tests must run on `@MainActor`.
/// Synthetic signal streams are injected directly (no real ProgressFile).
@MainActor
@Suite("LoadProgressWatcher — signal-based wedge detection")
struct LoadProgressWatcherTests {

  /// Deterministic monotonic-clock stand-in for tests that drive watcher
  /// thresholds. `@MainActor`-implicit (the suite is `@MainActor`); safe because
  /// `LoadProgressWatcher` is also `@MainActor`-isolated, so every `currentTime()`
  /// read happens on the same actor that mutates `now`.
  @MainActor
  private final class ManualClock {
    private(set) var now: TimeInterval = 0
    func tick(seconds: TimeInterval) { now += seconds }
  }

  /// Helper: sleep for `ms` milliseconds in the host clock. Only used by tests
  /// whose sleeps are NOT load-bearing for the watcher's measured cadence.
  private func sleep(ms: Int) async {
    try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
  }

  /// Helper: synthetic mtime. Distinct values trigger "real signal" detection
  /// inside the watcher; identical values are treated as no-op ticks.
  private func mtime(_ index: Int) -> Date {
    Date(timeIntervalSince1970: 1_000_000 + Double(index))
  }

  @Test("Pre-first-signal silence does NOT fire (uncovered case per plan §2.2)")
  func preFirstSignalDoesNotFire() async {
    // Deterministic clock so the 20 nil ticks cross the 800ms fire floor in
    // logical time (~2.0s) without burning ~1000ms of real wall-clock per run.
    // The point of the test is that even past the floor, a watcher that never
    // observed a real signal must NOT fire (the pre-first-signal guard returns
    // before any silence/floor evaluation). The old real-clock sleep made this
    // slow AND under-asserted — it never checked `hasFired`, so a regression
    // firing past the floor would have stayed green (#881 TO-1).
    let clock = ManualClock()
    let watcher = LoadProgressWatcher(currentTime: { clock.now })
    watcher.start()
    for _ in 0..<20 {
      watcher.observeTick(observedMtime: nil, observedPhase: "")
      clock.tick(seconds: 0.1)  // 20 * 0.1s = 2.0s, well past the 0.8s floor
    }
    let snap = watcher.snapshot
    #expect(snap.signalCountTotal == 0)
    #expect(snap.firstSignalLatencyMs == nil)
    #expect(
      watcher.hasFired == false,
      "pre-first-signal silence must never fire, even after the 800ms floor elapses")
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
    let clock = ManualClock()
    let watcher = LoadProgressWatcher(currentTime: { clock.now })
    watcher.start()
    for i in 0..<10 {
      watcher.observeTick(observedMtime: mtime(i), observedPhase: "downloading")
      clock.tick(seconds: 0.100)
    }
    let snap = watcher.snapshot
    #expect(snap.signalCountTotal == 10)
    #expect(snap.maxGapMs == 100, "max gap is the steady 100ms cadence")
    #expect(!watcher.hasFired, "steady cadence stays below floor — watcher must not fire")
    watcher.stop()
  }

  @Test("Single signal then long silence does NOT fire (observed-gap gate protects XPC)")
  func singleSignalLongSilenceDoesNotFire() async {
    let clock = ManualClock()
    let watcher = LoadProgressWatcher(currentTime: { clock.now })
    watcher.start()
    // Only ONE real signal — `maxGapSeconds == 0`. Silence then accumulates
    // past the 800ms floor. Without an observed inter-signal gap the watcher
    // must NOT fire (Codex finding 2026-05-07).
    watcher.observeTick(observedMtime: mtime(0), observedPhase: "listing")
    for _ in 0..<20 {
      watcher.observeTick(observedMtime: mtime(0), observedPhase: "listing")
      clock.tick(seconds: 0.060)
    }
    // Silence well over 1 second now; without ratio data, must not fire.
    let snap = watcher.snapshot
    #expect(snap.signalCountTotal == 1)
    #expect(snap.maxGapMs == 0)
    #expect(
      !watcher.hasFired,
      "single XPC lifecycle tick with no observed gap must not become an 800ms timeout"
    )
    watcher.stop()
  }

  @Test("Below 800ms floor — does NOT fire even if ratio is met")
  func ratioOnlyDoesNotFire() async {
    let clock = ManualClock()
    let watcher = LoadProgressWatcher(currentTime: { clock.now })
    watcher.start()
    // Two signals 50ms apart → max gap 50ms. Ratio threshold = 250ms.
    watcher.observeTick(observedMtime: mtime(0), observedPhase: "downloading")
    clock.tick(seconds: 0.050)
    watcher.observeTick(observedMtime: mtime(1), observedPhase: "downloading")
    // Silence at 300ms exceeds ratio (250ms) but is below floor (800ms).
    for _ in 0..<5 {
      clock.tick(seconds: 0.060)
      watcher.observeTick(observedMtime: mtime(1), observedPhase: "downloading")
    }
    #expect(!watcher.hasFired, "silence below 800ms floor must not fire even when ratio is met")
    watcher.stop()
  }

  @Test("Both gates met (silence > floor AND silence > 5x max gap) — fires")
  func bothGatesFire() async {
    let clock = ManualClock()
    let watcher = LoadProgressWatcher(currentTime: { clock.now })
    watcher.start()
    // Establish two inter-signal gaps of 150ms each → maxGap = 0.150.
    // Ratio threshold = 5 * 0.150 = 0.750; floor wins at 0.800.
    watcher.observeTick(observedMtime: mtime(0), observedPhase: "compiling")
    clock.tick(seconds: 0.150)
    watcher.observeTick(observedMtime: mtime(1), observedPhase: "compiling")
    clock.tick(seconds: 0.150)
    watcher.observeTick(observedMtime: mtime(2), observedPhase: "compiling")
    // Advance silence past the 0.800 floor and re-tick with the same mtime so
    // observeTick takes the silence-evaluation branch (no new signal).
    clock.tick(seconds: 0.810)
    watcher.observeTick(observedMtime: mtime(2), observedPhase: "compiling")
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

  @Test("raceWithSignalWatcher can wait through parent cancellation for cleanup awaits")
  func raceWaitsThroughParentCancellationWhenRequested() async {
    let watcher = LoadProgressWatcher()
    watcher.start()
    let task = Task { @MainActor in
      await raceWithSignalWatcher(
        watcher: watcher,
        parentCancellationBehavior: .waitForResolution
      ) {
        try await Task.sleep(nanoseconds: 50_000_000)
        return 42
      }
    }
    await sleep(ms: 10)
    task.cancel()
    let outcome = await task.value
    watcher.stop()
    if case .completed(let value) = outcome {
      #expect(value == 42)
    } else {
      Issue.record("Expected cleanup wait to complete after cancellation, got \(outcome)")
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
    let clock = ManualClock()
    let watcher = LoadProgressWatcher(currentTime: { clock.now })
    watcher.start()
    // Advance before the first signal so firstSignalLatencyMs is non-zero —
    // the field is measured from start() to firstSignal.
    clock.tick(seconds: 0.100)
    watcher.observeTick(observedMtime: mtime(0), observedPhase: "listing")
    clock.tick(seconds: 0.100)
    watcher.observeTick(observedMtime: mtime(1), observedPhase: "downloading")
    clock.tick(seconds: 0.200)
    watcher.observeTick(observedMtime: mtime(2), observedPhase: "compiling")
    let snap = watcher.snapshot
    #expect(snap.signalCountTotal == 3)
    #expect(snap.lastObservedPhase == "compiling")
    #expect(snap.firstSignalLatencyMs == 100, "first signal observed 100ms after start()")
    #expect(snap.maxGapMs == 200, "max gap is the 200ms second-to-third interval")
    watcher.stop()
  }

  // MARK: - Boundary tests (issue #782)
  //
  // `observeTick` fires only when `silence > threshold` (strict comparator,
  // LoadProgressWatcher.swift:140). These three tests pin the boundary so a
  // future refactor of the threshold formula cannot quietly flip the comparator.

  @Test("Fires just above threshold (silence = threshold + epsilon)")
  func firesJustAboveThreshold() async {
    let clock = ManualClock()
    let watcher = LoadProgressWatcher(currentTime: { clock.now })
    watcher.start()
    // Two signals 200ms apart → maxGap = 0.200. Ratio = 5 * 0.200 = 1.000.
    // Floor = 0.800. Effective threshold = max(0.800, 1.000) = 1.000.
    watcher.observeTick(observedMtime: mtime(0), observedPhase: "compiling")
    clock.tick(seconds: 0.200)
    watcher.observeTick(observedMtime: mtime(1), observedPhase: "compiling")
    // Advance silence to 1.001 (1ms past threshold).
    clock.tick(seconds: 1.001)
    watcher.observeTick(observedMtime: mtime(1), observedPhase: "compiling")
    #expect(watcher.hasFired, "silence 1ms past threshold must fire")
    watcher.stop()
  }

  @Test("Does NOT fire at exact threshold (strict > comparator)")
  func doesNotFireAtExactThreshold() async {
    let clock = ManualClock()
    let watcher = LoadProgressWatcher(currentTime: { clock.now })
    watcher.start()
    // Same setup as firesJustAboveThreshold — threshold = 1.000.
    watcher.observeTick(observedMtime: mtime(0), observedPhase: "compiling")
    clock.tick(seconds: 0.200)
    watcher.observeTick(observedMtime: mtime(1), observedPhase: "compiling")
    // Advance silence to exactly 1.000 (equality is below `>` threshold).
    clock.tick(seconds: 1.000)
    watcher.observeTick(observedMtime: mtime(1), observedPhase: "compiling")
    #expect(!watcher.hasFired, "silence == threshold is below the strict > comparator")
    watcher.stop()
  }

  @Test("maxGap stays sticky when subsequent gaps shrink")
  func maxGapStaysStickyWhenGapsShrink() async {
    let clock = ManualClock()
    let watcher = LoadProgressWatcher(currentTime: { clock.now })
    watcher.start()
    // First gap is the largest (500ms). Threshold should be derived from it
    // even after smaller gaps follow.
    watcher.observeTick(observedMtime: mtime(0), observedPhase: "compiling")
    clock.tick(seconds: 0.500)
    watcher.observeTick(observedMtime: mtime(1), observedPhase: "compiling")
    clock.tick(seconds: 0.100)
    watcher.observeTick(observedMtime: mtime(2), observedPhase: "compiling")
    clock.tick(seconds: 0.100)
    watcher.observeTick(observedMtime: mtime(3), observedPhase: "compiling")
    let snap = watcher.snapshot
    #expect(
      snap.maxGapMs == 500, "maxGap must remain at 500ms — guarded by `if gap > maxGapSeconds`")
    // Ratio threshold = 5 * 0.500 = 2.500. Silence of 2.499 must NOT fire.
    clock.tick(seconds: 2.499)
    watcher.observeTick(observedMtime: mtime(3), observedPhase: "compiling")
    #expect(!watcher.hasFired, "silence below sticky-maxGap ratio must not fire")
    // One more ms past the ratio threshold — must fire.
    clock.tick(seconds: 0.002)
    watcher.observeTick(observedMtime: mtime(3), observedPhase: "compiling")
    #expect(watcher.hasFired, "silence past sticky-maxGap ratio must fire")
    watcher.stop()
  }

  // MARK: - #1339 phase-aware listing-stall gate

  /// Watcher configured like the sessionless warm-up guard: listing phase
  /// token + a deterministic deadline the ManualClock can cross.
  private func listingAwareWatcher(_ clock: ManualClock, deadline: TimeInterval = 120)
    -> LoadProgressWatcher
  {
    LoadProgressWatcher(
      currentTime: { clock.now },
      listingPhase: ModelLoadStallPolicy.listingPhase,
      listingStallDeadlineSeconds: deadline)
  }

  @Test("#1339: single listing signal then silence past the deadline FIRES")
  func listingStallFiresAtDeadline() async {
    let clock = ManualClock()
    let watcher = listingAwareWatcher(clock)
    watcher.start()
    // The P0 shape: exactly one "Preparing download..." signal, then silence.
    watcher.observeTick(observedMtime: mtime(0), observedPhase: ModelLoadStallPolicy.listingPhase)
    clock.tick(seconds: 119.9)
    watcher.observeTick(observedMtime: mtime(0), observedPhase: ModelLoadStallPolicy.listingPhase)
    #expect(!watcher.hasFired, "just below the listing deadline must not fire")
    clock.tick(seconds: 0.2)
    watcher.observeTick(observedMtime: mtime(0), observedPhase: ModelLoadStallPolicy.listingPhase)
    #expect(watcher.hasFired, "listing silence past the deadline is the P0 stall — must fire")
    let snap = watcher.snapshot
    #expect(snap.signalCountTotal == 1)
    #expect(snap.lastObservedPhase == ModelLoadStallPolicy.listingPhase)
    watcher.stop()
  }

  @Test("#1339: single NON-listing signal then long silence does NOT fire (adversarial class)")
  func nonListingSingleSignalStaysCovered() async {
    let clock = ManualClock()
    let watcher = listingAwareWatcher(clock)
    watcher.start()
    // Same silence shape, different phase — the deadline is scoped to the
    // listing window only; other single-signal quiets keep the #445 deferral.
    watcher.observeTick(observedMtime: mtime(0), observedPhase: "Installing model...")
    clock.tick(seconds: 500)
    watcher.observeTick(observedMtime: mtime(0), observedPhase: "Installing model...")
    #expect(
      !watcher.hasFired,
      "the listing deadline must not become a generic single-signal timeout")
    watcher.stop()
  }

  @Test("#1339: NO signal at all fires past the deadline (dead service)")
  func preFirstSignalFiresWithDeadline() async {
    let clock = ManualClock()
    let watcher = listingAwareWatcher(clock)
    watcher.start()
    for _ in 0..<10 {
      clock.tick(seconds: 13)  // evaluations at 13s..130s, crossing the 120s deadline
      watcher.observeTick(observedMtime: nil, observedPhase: "")
    }
    #expect(
      watcher.hasFired,
      "a service that never writes a single progress signal must fire the deadline")
    let snap = watcher.snapshot
    #expect(snap.signalCountTotal == 0)
    watcher.stop()
  }

  @Test("#1339: progressing download runs past the deadline WITHOUT firing")
  func progressingTransferNeverDeadlined() async {
    let clock = ManualClock()
    let watcher = listingAwareWatcher(clock)
    watcher.start()
    // Listing completes quickly, then bytes flow: signals every 2s for 200s
    // (well past the 120s deadline). A progressing transfer must never be
    // wall-clock-killed (plan E1) — only the ratio gate governs it.
    watcher.observeTick(observedMtime: mtime(0), observedPhase: ModelLoadStallPolicy.listingPhase)
    clock.tick(seconds: 2)
    for i in 1..<100 {
      watcher.observeTick(observedMtime: mtime(i), observedPhase: "Downloading model files...")
      clock.tick(seconds: 2)
    }
    #expect(
      !watcher.hasFired,
      "a slow but progressing transfer must never hit a wall-clock deadline")
    #expect(watcher.snapshot.totalAttemptDurationMs >= 200_000)
    watcher.stop()
  }

  @Test("#1339: listing that resolves before the deadline hands off to the ratio gate")
  func listingHandsOffToRatioGate() async {
    let clock = ManualClock()
    let watcher = listingAwareWatcher(clock)
    watcher.start()
    // Healthy listing: 5s to first byte (below deadline), then download
    // signals. Once 2+ signals exist, the ratio gate owns detection — a
    // silence past 5x the worst gap fires, exactly as before #1339.
    watcher.observeTick(observedMtime: mtime(0), observedPhase: ModelLoadStallPolicy.listingPhase)
    clock.tick(seconds: 5)
    watcher.observeTick(observedMtime: mtime(1), observedPhase: "Downloading model files...")
    #expect(!watcher.hasFired, "healthy listing handoff must not fire")
    // maxGap = 5s → ratio threshold 25s. 24.9s of silence: no fire.
    clock.tick(seconds: 24.9)
    watcher.observeTick(observedMtime: mtime(1), observedPhase: "Downloading model files...")
    #expect(!watcher.hasFired)
    // Past the ratio threshold: fire (mid-download wedge).
    clock.tick(seconds: 0.2)
    watcher.observeTick(observedMtime: mtime(1), observedPhase: "Downloading model files...")
    #expect(watcher.hasFired, "mid-download wedge past the ratio gate must still fire")
    watcher.stop()
  }

  @Test("#1339: default init (no deadline) preserves the pre-#1339 listing-stall behavior")
  func defaultsPreserveLegacyBehavior() async {
    let clock = ManualClock()
    let watcher = LoadProgressWatcher(currentTime: { clock.now })
    watcher.start()
    watcher.observeTick(observedMtime: mtime(0), observedPhase: ModelLoadStallPolicy.listingPhase)
    clock.tick(seconds: 10_000)
    watcher.observeTick(observedMtime: mtime(0), observedPhase: ModelLoadStallPolicy.listingPhase)
    #expect(
      !watcher.hasFired,
      "without an injected deadline the watcher keeps the deliberate #445 deferral")
    watcher.stop()
  }
}
