import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices
@testable import EnviousWisprStorage

/// Escape Recovery telemetry (#2087, chunk 11).
///
/// The funnel is the instrument that decides whether this feature earns its
/// blast radius — the ratio of expired-unused to restored is the honest verdict
/// — so the events have to be right before anything can be concluded from them.
///
/// Two properties matter most and are easy to get quietly wrong: the join key
/// must be the PERSISTED take id (these events fire hours later, possibly after
/// a relaunch), and the payloads must carry no content.
@MainActor
/// Class: `.observabilityContract` — same: the events are how we judge the feature, not how it works.
@Suite("Escape Recovery telemetry (#2087)", .tags(.observabilityContract))
struct EscapeRecoveryTelemetryTests {

  private func makeStore() -> TranscriptStore {
    TranscriptStore(
      directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("ew-2087-tel-\(UUID().uuidString)", isDirectory: true))
  }

  private final class EventLog {
    var kept: [(ageMs: Int, takeID: String)] = []
    var expired: [(ageMs: Int, takeID: String)] = []
  }

  private func makeCoordinator(_ log: EventLog, store: TranscriptStore) -> TranscriptCoordinator {
    TranscriptCoordinator(
      store: store,
      emitEscapeRecoveryKept: { log.kept.append((ageMs: $0, takeID: $1)) },
      emitEscapeRecoveryExpired: { log.expired.append((ageMs: $0, takeID: $1)) })
  }

  // MARK: Keep

  @Test("Keep reports the persisted take id and the row's age")
  func keepEmitsWithPersistedTakeID() async throws {
    let store = makeStore()
    let log = EventLog()
    let coordinator = makeCoordinator(log, store: store)
    let stamped = Transcript(
      text: "kept", escapeRecoveredAt: Date().addingTimeInterval(-7200),
      escapeRecoveryTakeID: "take-abc")
    try store.savePending(stamped)
    coordinator.load()
    await coordinator.waitForLoadForTesting()
    let loaded = try #require(coordinator.visibleTranscripts.first)

    coordinator.keep(loaded)

    #expect(log.kept.count == 1)
    let event = try #require(log.kept.first)
    #expect(
      event.takeID == "take-abc",
      "the PERSISTED id, because this can fire hours later and after a relaunch")
    #expect(
      abs(event.ageMs - 7_200_000) < 60_000,
      "and the age since the offer began, not since the app launched")
  }

  #if DEBUG
    /// The event must not overstate the one ratio it exists to measure.
    @Test("a refused Keep reports nothing")
    func keepOnALapsedRowEmitsNothing() async throws {
      let store = makeStore()
      let log = EventLog()
      let coordinator = makeCoordinator(log, store: store)
      let stale = Transcript(
        text: "too late",
        escapeRecoveredAt: Date().addingTimeInterval(
          -(AppConstants.pendingTranscriptRetention + 5)),
        escapeRecoveryTakeID: "take-stale")
      try store.savePending(stale)
      coordinator.setTranscriptsForTesting([stale])

      coordinator.keep(stale)

      #expect(log.kept.isEmpty, "nothing was promoted, so nothing may be reported as kept")
    }
  #endif

  @Test("Keep on an ordinary dictation reports nothing")
  func keepOnOrdinaryRowEmitsNothing() async throws {
    let store = makeStore()
    let log = EventLog()
    let coordinator = makeCoordinator(log, store: store)
    try store.save(Transcript(text: "ordinary"))
    coordinator.load()
    await coordinator.waitForLoadForTesting()
    let ordinary = try #require(coordinator.visibleTranscripts.first)

    coordinator.keep(ordinary)

    #expect(log.kept.isEmpty)
  }

  // MARK: Expiry sweep

  /// The age is the row's REAL age, which is the whole reason the receipt
  /// carries a timestamp. Deriving it from the retention constant would emit a
  /// fixed 24h for every row and be wrong exactly when it matters — a Mac left
  /// off for days sweeps rows far older than the deadline, and that gap is the
  /// signal.
  @Test("the sweep reports each expired row's real age, not the retention window")
  func sweepReportsRealAge() async throws {
    let store = makeStore()
    let log = EventLog()
    let coordinator = makeCoordinator(log, store: store)

    let now = Date()
    let threeDays: TimeInterval = 3 * 24 * 60 * 60
    try store.savePending(
      Transcript(
        text: "long forgotten", escapeRecoveredAt: now.addingTimeInterval(-threeDays),
        escapeRecoveryTakeID: "take-old"))

    await coordinator.sweepExpiredPending(now: now)

    #expect(log.expired.count == 1)
    let event = try #require(log.expired.first)
    #expect(event.takeID == "take-old")
    #expect(
      abs(event.ageMs - Int(threeDays * 1000)) < 60_000,
      "72 hours, not the 24-hour deadline it passed three days ago")
  }

  /// The sweep needs a CALLER, or expired files accumulate forever and the
  /// `expired` half of the ratio never fires. It had none when this chunk was
  /// first submitted — the method existed and nothing invoked it.
  @Test("loading History sweeps, so the sweep is not a dead method")
  func loadTriggersTheSweep() async throws {
    let store = makeStore()
    let log = EventLog()
    let coordinator = makeCoordinator(log, store: store)
    try store.savePending(
      Transcript(
        text: "aged out",
        escapeRecoveredAt: Date().addingTimeInterval(
          -(AppConstants.pendingTranscriptRetention + 60)),
        escapeRecoveryTakeID: "take-swept"))

    coordinator.load()
    await coordinator.waitForLoadForTesting()

    #expect(
      log.expired.map(\.takeID) == ["take-swept"],
      "the load path must sweep, or nothing ever does")
    #expect(try await store.loadPending().isEmpty, "and the file is gone")
  }

  #if DEBUG
    /// The pulse is where an expiry is DETECTED, so it must be where the file
    /// goes and the event fires.
    ///
    /// Sweeping only on `load()` left both waiting for the user to reopen
    /// History — for a row that aged out while they were looking at it, that is
    /// days away or never. Driven through the injected wait, so no wall clock is
    /// involved.
    @Test("a row that ages out under the pulse is swept there and then")
    func pulseSweepsOnDetection() async throws {
      let store = makeStore()
      let log = EventLog()
      let gate = PulseGate()
      let coordinator = TranscriptCoordinator(
        store: store,
        pendingPulseSleep: { _ in await gate.advance() },
        emitEscapeRecoveryKept: { log.kept.append((ageMs: $0, takeID: $1)) },
        emitEscapeRecoveryExpired: { log.expired.append((ageMs: $0, takeID: $1)) })

      // The disk row is already past its window; the IN-MEMORY copy still looks
      // live, which is the real situation — a row loaded while offered, ageing
      // out under the user's eyes.
      //
      // Driven by a signal, not a clock: the first injected wait is where the
      // in-memory copy ages out. An earlier version made the row expire 0.4s in
      // the future and let the loop spin against the wall clock until it did,
      // which is flaky by construction and showed up as the suite jumping from
      // 0.010s to 0.415s.
      let id = UUID()
      let takeID = "take-live-expiry"
      try store.savePending(
        Transcript(
          id: id, text: "ages out while you watch",
          escapeRecoveredAt: Date().addingTimeInterval(
            -(AppConstants.pendingTranscriptRetention + 1)),
          escapeRecoveryTakeID: takeID))
      coordinator.setTranscriptsForTesting([
        Transcript(
          id: id, text: "ages out while you watch",
          escapeRecoveredAt: Date().addingTimeInterval(-60), escapeRecoveryTakeID: takeID)
      ])

      #expect(log.expired.isEmpty, "control: nothing swept before a pulse runs")
      #expect(coordinator.hasPendingPulseForTesting, "control: the pulse is running")

      gate.onWait = { [weak coordinator] iteration in
        guard iteration == 1 else { return }
        coordinator?.setTranscriptsForTesting([
          Transcript(
            id: id, text: "ages out while you watch",
            escapeRecoveredAt: Date().addingTimeInterval(
              -(AppConstants.pendingTranscriptRetention + 1)),
            escapeRecoveryTakeID: takeID)
        ])
      }
      await coordinator.waitForPulseForTesting()

      #expect(
        log.expired.map(\.takeID) == ["take-live-expiry"],
        "the pulse detected the expiry, so the pulse must have swept it")
      #expect(
        try await store.loadPending().isEmpty, "and the file is gone without reopening History")
    }

    /// A removal that FAILS must leave the pulse armed, so the next one retries.
    ///
    /// The store promises a failed removal is retried on the next sweep. The
    /// pulse used to stop as soon as nothing was LIVE, so for a lapsed row whose
    /// file would not go there was no next sweep — the file and its expiry event
    /// waited for History to reload. Arming carried the same defect one step
    /// earlier: a lapsed row on its own never started the pulse at all, which is
    /// why this test asserts the arm BEFORE it drives anything.
    ///
    /// The failure is real rather than injected. Removing a file needs write
    /// permission on the CONTAINING directory, so `0500` on `pending/` makes
    /// `removeItem` fail while leaving the walk able to list and decode — no
    /// production seam, and the sweep still runs exactly as it does in the
    /// field.
    ///
    /// The retry is armed by DISK truth (`PendingSweepResult.retryable`), never
    /// by a lapsed row in memory. Memory can outlive the file it describes —
    /// `load()` preserves rows absent from both namespaces — so retrying on it
    /// would mean walking the directory every minute for the life of the app.
    @Test("a failed removal keeps the pulse armed and is retried on the next one")
    func failedRemovalStaysArmedAndRetries() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ew-2087-retry-\(UUID().uuidString)", isDirectory: true)
      let store = TranscriptStore(directory: directory)
      let log = EventLog()
      let gate = PulseGate()

      let id = UUID()
      let takeID = "take-retry"
      let row = Transcript(
        id: id, text: "its file will not go the first time",
        escapeRecoveredAt: Date().addingTimeInterval(
          -(AppConstants.pendingTranscriptRetention + 1)),
        escapeRecoveryTakeID: takeID)
      try store.savePending(row)

      let pending = directory.appendingPathComponent(
        AppConstants.pendingTranscriptsDir, isDirectory: true)
      let file = pending.appendingPathComponent("\(id.uuidString).json")
      let sealed: [FileAttributeKey: Any] = [.posixPermissions: 0o500]
      let unsealed: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
      try FileManager.default.setAttributes(sealed, ofItemAtPath: pending.path)
      defer { try? FileManager.default.setAttributes(unsealed, ofItemAtPath: pending.path) }

      let coordinator = TranscriptCoordinator(
        store: store,
        pendingPulseSleep: { _ in await gate.advance() },
        emitEscapeRecoveryKept: { log.kept.append((ageMs: $0, takeID: $1)) },
        emitEscapeRecoveryExpired: { log.expired.append((ageMs: $0, takeID: $1)) })

      // The hook is installed BEFORE anything can start the pulse, and this
      // ordering is load bearing. The sweep itself arms the retry, so `load()`
      // starts the pulse; the injected wait is instant, so the pulse spins; and
      // an `== 2` hook installed afterwards is simply missed, leaving a loop
      // whose exit condition can never be met. That hung a clean tree on 1 run
      // in 4 — it passed three times first.
      let seen = FailedRemovalObservation()
      gate.onWait = { [weak coordinator] iteration in
        // Recorded once, at the first wait AFTER a sweep has failed: that is
        // the claim. Later iterations would overwrite it with the state after
        // the permissions are restored, which is a different fact.
        if iteration >= 2, !seen.recorded, let coordinator {
          seen.recorded = true
          seen.stillArmed = coordinator.hasPendingPulseForTesting
          seen.fileSurvived = FileManager.default.fileExists(atPath: file.path)
          try? FileManager.default.setAttributes(unsealed, ofItemAtPath: pending.path)
        }
        // CANCELS the loop. A backstop that instead tries to satisfy the stop
        // condition cannot help when the loop is held open by state the defect
        // itself controls — that version hung for 30 minutes rather than
        // failing. A hang costs a CI run and reads as a slow build; a failure
        // names the defect. The healthy path never reaches this.
        if iteration > 20 {
          seen.overran = true
          coordinator?.cancelPulseForTesting()
        }
      }

      // Through `load()`, not an injected list: arming is DISK-driven, and the
      // signal is load's own sweep failing to remove the file. The row is never
      // in memory at all — `loadPending` refuses a lapsed row — which is
      // precisely why the pulse cannot decide this from its own list.
      coordinator.load()
      await coordinator.waitForLoadForTesting()

      #expect(
        coordinator.rawTranscriptsForTesting.isEmpty,
        "control: nothing in memory, so this cannot be a memory-driven arm")

      await coordinator.waitForPulseForTesting()

      #expect(seen.overran == false, "the pulse must reach its own exit, not the test's backstop")
      #expect(seen.recorded, "control: the pulse ran far enough to observe the failed removal")
      #expect(seen.fileSurvived, "control: the first removal genuinely failed")
      #expect(seen.stillArmed, "and the pulse stayed armed rather than stranding it")
      #expect(
        log.expired.map(\.takeID) == [takeID],
        "reported exactly once, by the pass that actually removed the file")
      #expect(try await store.loadPending().isEmpty, "the retry cleared it")
      #expect(
        coordinator.hasPendingPulseForTesting == false,
        "and only then does the pulse stop, with nothing left to do")
    }

    /// A stale lapsed row must not keep the directory walk alive.
    ///
    /// `load()` preserves in-memory rows absent from BOTH namespaces, so a
    /// lapsed row whose file is already gone is reachable, not theoretical. It
    /// was invisible while it was the only row — the pulse stopped for want of
    /// a live one — but ONE unrelated live row beside it kept the pulse running,
    /// and then the trigger never settled: a walk every minute for the life of
    /// the app.
    ///
    /// Two pulses, because one proves nothing. The first walk is legitimate; the
    /// second is the defect. What ends it is the sweep dropping a lapsed row it
    /// did not find, so the trigger returns to zero on its own.
    @Test("a stale lapsed row beside a live one costs one walk, not one per pulse")
    func staleLapsedRowDoesNotWalkForever() async throws {
      let store = makeStore()
      let log = EventLog()
      let gate = PulseGate()
      let coordinator = TranscriptCoordinator(
        store: store,
        pendingPulseSleep: { _ in await gate.advance() },
        emitEscapeRecoveryKept: { log.kept.append((ageMs: $0, takeID: $1)) },
        emitEscapeRecoveryExpired: { log.expired.append((ageMs: $0, takeID: $1)) })

      // Neither row has a file. The lapsed one is the stale remnant; the live
      // one exists only to keep the pulse running, which is what exposed this.
      coordinator.setTranscriptsForTesting([
        Transcript(
          text: "live, and only here to keep the pulse alive",
          escapeRecoveredAt: Date().addingTimeInterval(-60),
          escapeRecoveryTakeID: "take-live"),
        Transcript(
          text: "lapsed, and its file went long ago",
          escapeRecoveredAt: Date().addingTimeInterval(
            -(AppConstants.pendingTranscriptRetention + 1)),
          escapeRecoveryTakeID: "take-stale"),
      ])

      #expect(coordinator.hasPendingPulseForTesting, "control: the live row arms the pulse")
      #expect(
        coordinator.lapsedPendingCountForTesting == 1,
        "control: the stale row is genuinely lapsed before any sweep")

      let seen = FailedRemovalObservation()
      gate.onWait = { [weak coordinator] iteration in
        guard let coordinator else { return }
        // Read at the top of the SECOND wait, i.e. after exactly one sweep.
        if iteration == 2 { seen.lapsedAfterOneSweep = coordinator.lapsedPendingCountForTesting }
        // Emptied from the third onward so the loop has a REASON to exit and the
        // test ends on the production stop condition rather than a cancellation.
        // `>=`, never `==`: an exact-iteration hook is missed outright if the
        // loop advances before it is installed, and what is left behind is a
        // loop whose exit condition can never be met.
        if iteration >= 3 { coordinator.setTranscriptsForTesting([]) }
      }
      await coordinator.waitForPulseForTesting()

      #expect(
        seen.lapsedAfterOneSweep == 0,
        "one sweep must drop the stale row, or the trigger never settles")
      #expect(
        log.expired.isEmpty,
        "and a row with no file is not an expiry anyone can report")
    }

    /// A sweep that could not LOOK must not be treated as one that found nothing.
    ///
    /// The eviction above is licensed by "every not-live file this pass could see
    /// is gone". An unreadable directory reports the same zero while having seen
    /// nothing at all, so acting on it would drop the only remaining record of
    /// rows whose files are still there — and stop retrying at the same moment.
    ///
    /// `0300` is write-plus-execute with no READ: enumeration fails while the
    /// directory is otherwise intact.
    ///
    /// **The PULSE performs the retry. The test never sweeps by hand.** An
    /// earlier version asserted the pulse was armed and then called the second
    /// sweep itself, which proves the arming and nothing else: with the retry
    /// condition removed the task stays armed forever, never sweeps, and that
    /// version still passed because the test was doing the work the code was
    /// supposed to do. Cleanup and telemetry here are produced by the loop or
    /// not at all.
    @Test("the pulse itself retries a blind sweep once the directory is readable")
    func incompleteWalkKeepsRowsAndPulseRetries() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ew-2087-blind-\(UUID().uuidString)", isDirectory: true)
      let store = TranscriptStore(directory: directory)
      let log = EventLog()
      let gate = PulseGate()
      let lapsed = Transcript(
        text: "its file is still there, we just cannot see it",
        escapeRecoveredAt: Date().addingTimeInterval(
          -(AppConstants.pendingTranscriptRetention + 1)),
        escapeRecoveryTakeID: "take-blind")
      try store.savePending(lapsed)

      let pending = directory.appendingPathComponent(
        AppConstants.pendingTranscriptsDir, isDirectory: true)
      let sealed: [FileAttributeKey: Any] = [.posixPermissions: 0o300]
      let unsealed: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
      try FileManager.default.setAttributes(sealed, ofItemAtPath: pending.path)
      defer { try? FileManager.default.setAttributes(unsealed, ofItemAtPath: pending.path) }

      let coordinator = TranscriptCoordinator(
        store: store,
        pendingPulseSleep: { _ in await gate.advance() },
        emitEscapeRecoveryKept: { log.kept.append((ageMs: $0, takeID: $1)) },
        emitEscapeRecoveryExpired: { log.expired.append((ageMs: $0, takeID: $1)) })
      // In memory before the load, so `load()` carries it through as an
      // in-flight row — the real path by which a lapsed row outlives the
      // namespaces, rather than a state only a seam can produce.
      coordinator.setTranscriptsForTesting([lapsed])

      let seen = FailedRemovalObservation()
      // Installed BEFORE anything can start the pulse: the sweep arms it, so
      // `load()` starts it, and a hook installed afterwards is simply missed.
      gate.onWait = { [weak coordinator] iteration in
        guard let coordinator else { return }
        if iteration == 1 {
          // After the BLIND sweep and before the directory is readable.
          seen.lapsedAfterBlindSweep = coordinator.lapsedPendingCountForTesting
          seen.reportedAfterBlindSweep = log.expired.count
        }
        if iteration >= 2 {
          try? FileManager.default.setAttributes(unsealed, ofItemAtPath: pending.path)
        }
        // Cancels rather than trying to satisfy the stop condition — see the
        // sibling above; the alternative hangs instead of failing.
        if iteration > 20 {
          seen.overran = true
          coordinator.cancelPulseForTesting()
        }
      }

      coordinator.load()
      await coordinator.waitForLoadForTesting()
      await coordinator.waitForPulseForTesting()

      #expect(seen.overran == false, "the pulse must reach its own exit, not the test's backstop")
      #expect(
        seen.lapsedAfterBlindSweep == 1,
        "a sweep that never saw the file must not drop the row that records it")
      #expect(
        seen.reportedAfterBlindSweep == 0, "and a sweep that saw nothing reports nothing")
      #expect(
        log.expired.map(\.takeID) == ["take-blind"],
        "the PULSE retried and reported it once — nothing in this test swept by hand")
      #expect(try await store.loadPending().isEmpty, "and the retry cleared the file")
      #expect(
        coordinator.lapsedPendingCountForTesting == 0, "the row leaves memory with its file")
      #expect(
        coordinator.hasPendingPulseForTesting == false, "then the pulse stops, with nothing left")
    }

    /// The incomplete-walk flag ALONE must keep the sweep coming back.
    ///
    /// Its sibling above keeps the lapsed row in memory, and that row is an
    /// independent reason to sweep — so removing the flag from the sweep-due
    /// predicate left that test passing while the retry it names had stopped
    /// existing. Verified, not assumed: the mutant came back GREEN.
    ///
    /// Here memory is EMPTY, so `lastSweepIncomplete` is the only thing that can
    /// bring the pulse back to the directory. Nothing sweeps by hand.
    @Test("a blind sweep retries even with nothing in memory to remind it")
    func blindSweepWithEmptyMemoryStillRetries() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ew-2087-blind-empty-\(UUID().uuidString)", isDirectory: true)
      let store = TranscriptStore(directory: directory)
      let log = EventLog()
      let gate = PulseGate()
      try store.savePending(
        Transcript(
          text: "nothing in memory points at this file",
          escapeRecoveredAt: Date().addingTimeInterval(
            -(AppConstants.pendingTranscriptRetention + 1)),
          escapeRecoveryTakeID: "take-blind-empty"))

      let pending = directory.appendingPathComponent(
        AppConstants.pendingTranscriptsDir, isDirectory: true)
      let sealed: [FileAttributeKey: Any] = [.posixPermissions: 0o300]
      let unsealed: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
      try FileManager.default.setAttributes(sealed, ofItemAtPath: pending.path)
      defer { try? FileManager.default.setAttributes(unsealed, ofItemAtPath: pending.path) }

      let coordinator = TranscriptCoordinator(
        store: store,
        pendingPulseSleep: { _ in await gate.advance() },
        emitEscapeRecoveryKept: { log.kept.append((ageMs: $0, takeID: $1)) },
        emitEscapeRecoveryExpired: { log.expired.append((ageMs: $0, takeID: $1)) })

      let seen = FailedRemovalObservation()
      gate.onWait = { [weak coordinator] iteration in
        guard let coordinator else { return }
        if iteration == 1 { seen.lapsedAfterBlindSweep = coordinator.lapsedPendingCountForTesting }
        if iteration >= 2 {
          try? FileManager.default.setAttributes(unsealed, ofItemAtPath: pending.path)
        }
        // CANCELS, rather than trying to satisfy the stop condition. An earlier
        // backstop emptied memory instead, which cannot help when the loop is
        // held open by a flag only a successful sweep clears — so a mutant that
        // arms the pulse and never sweeps HUNG the suite for 30 minutes rather
        // than failing it. A hang costs a CI run and reads as a slow build; a
        // failure names the defect. The healthy path never reaches this.
        if iteration > 20 {
          seen.overran = true
          coordinator.cancelPulseForTesting()
        }
      }

      coordinator.load()
      await coordinator.waitForLoadForTesting()
      await coordinator.waitForPulseForTesting()

      #expect(seen.overran == false, "the pulse must reach its own exit, not the test's backstop")
      #expect(
        seen.lapsedAfterBlindSweep == 0,
        "control: memory is empty, so a lapsed row cannot be what brings the sweep back")
      #expect(
        log.expired.map(\.takeID) == ["take-blind-empty"],
        "the flag alone brought the pulse back, and it reported the row once")
      #expect(try await store.loadPending().isEmpty, "and cleared the file")
      #expect(
        coordinator.hasPendingPulseForTesting == false, "then stopped, with nothing left")
    }

    /// What the second wait observed. A reference so the gate's closure can
    /// record into it without capturing a mutable local.
    @MainActor
    private final class FailedRemovalObservation {
      var recorded = false
      var stillArmed = false
      var fileSurvived = false
      var lapsedAfterOneSweep = -1
      var lapsedAfterBlindSweep = -1
      var reportedAfterBlindSweep = -1
      /// The test's own backstop fired. Turns a hang into a failure, which is
      /// the difference between a named defect and a lost CI run.
      var overran = false
    }

    @MainActor
    private final class PulseGate {
      var iterations = 0
      var onWait: ((Int) -> Void)?
      func advance() {
        iterations += 1
        onWait?(iterations)
      }
    }
  #endif

  @Test("a live row is neither swept nor reported")
  func sweepLeavesLiveRowsAlone() async throws {
    let store = makeStore()
    let log = EventLog()
    let coordinator = makeCoordinator(log, store: store)
    try store.savePending(
      Transcript(
        text: "still offered", escapeRecoveredAt: Date().addingTimeInterval(-60),
        escapeRecoveryTakeID: "take-live"))

    await coordinator.sweepExpiredPending()

    #expect(log.expired.isEmpty)
    #expect(try await store.loadPending().count == 1, "and the row is still on disk")
  }

  @Test("a row with no persisted take id is swept silently")
  func sweepSkipsRowsWithoutAJoinKey() async throws {
    let store = makeStore()
    let log = EventLog()
    let coordinator = makeCoordinator(log, store: store)
    try store.savePending(
      Transcript(
        text: "predates take-id persistence",
        escapeRecoveredAt: Date().addingTimeInterval(
          -(AppConstants.pendingTranscriptRetention + 1)),
        escapeRecoveryTakeID: nil))

    await coordinator.sweepExpiredPending()

    #expect(
      log.expired.isEmpty,
      "an event with no join key cannot enter the funnel, so it is not emitted")
  }

  /// Diagnostic control: does a SINGLE sweep already over-report?
  ///
  /// Written because two attempted fixes to the concurrent case both left
  /// duplicates, which is evidence the model was wrong rather than the fix. If
  /// one sweep over five files yields more than five receipts, concurrency is
  /// not the mechanism at all.
  @Test("one sweep over five expired rows yields exactly five receipts")
  func singleSweepDoesNotOverReport() async throws {
    let store = makeStore()
    for index in 0..<5 {
      try store.savePending(
        Transcript(
          text: "aged out \(index)",
          escapeRecoveredAt: Date().addingTimeInterval(
            -(AppConstants.pendingTranscriptRetention + 60)),
          escapeRecoveryTakeID: "take-\(index)"))
    }

    let result = try await store.deleteExpiredPending()
    let byTake = Dictionary(grouping: result.expired, by: { $0.takeID ?? "nil" }).mapValues(\.count)
    #expect(result.expired.count == 5, "single sweep counts: \(byTake)")
    #expect(result.deletedIDs.count == 5, "and every file it removed is reported for eviction")
  }

  /// Two sweeps racing must produce ONE receipt.
  ///
  /// `load()` and the pulse can both reach the sweep, and the store used to
  /// report on "the file is now absent" — which cannot tell "I removed it" from
  /// "the other sweep removed it first", so both reported and one expiry was
  /// counted twice in the funnel this feature is judged by.
  @Test("concurrent sweeps report an expiry exactly once")
  func concurrentSweepsReportOnce() async throws {
    let store = makeStore()
    let log = EventLog()
    let coordinator = makeCoordinator(log, store: store)
    for index in 0..<5 {
      try store.savePending(
        Transcript(
          text: "aged out \(index)",
          escapeRecoveredAt: Date().addingTimeInterval(
            -(AppConstants.pendingTranscriptRetention + 60)),
          escapeRecoveryTakeID: "take-\(index)"))
    }

    // The coordinator serialises, so drive the STORE directly — that is the
    // layer whose reporting rule the finding was about, and the layer that must
    // hold even if a future caller forgets to serialise.
    async let first = store.deleteExpiredPending()
    async let second = store.deleteExpiredPending()
    let receipts = try await first.expired + second.expired

    let byTake = Dictionary(grouping: receipts, by: { $0.takeID ?? "nil" })
      .mapValues(\.count)
    #expect(
      receipts.count == 5,
      "five rows, five receipts — not ten, and not five plus duplicates. counts: \(byTake)")
    #expect(Set(receipts.map(\.takeID)).count == 5, "each take id reported once")
  }

  #if DEBUG
    /// One expired row plus one still-live row.
    ///
    /// The expired row must leave memory when it is swept. Leaving it there kept
    /// the pulse's trigger above zero, so it re-walked the whole directory every
    /// minute until the LIVE row expired — work for rows already deleted.
    @Test("a swept row leaves memory, so the pulse stops re-sweeping")
    func sweptRowsLeaveMemory() async throws {
      let store = makeStore()
      let log = EventLog()
      let coordinator = makeCoordinator(log, store: store)
      try store.savePending(
        Transcript(
          text: "gone",
          escapeRecoveredAt: Date().addingTimeInterval(
            -(AppConstants.pendingTranscriptRetention + 60)),
          escapeRecoveryTakeID: "take-gone"))
      try store.savePending(
        Transcript(
          text: "still offered", escapeRecoveredAt: Date().addingTimeInterval(-60),
          escapeRecoveryTakeID: "take-live"))

      coordinator.load()
      await coordinator.waitForLoadForTesting()

      #expect(log.expired.map(\.takeID) == ["take-gone"], "control: the expired one was swept")
      #expect(
        coordinator.visibleTranscripts.count == 1,
        "and the live one is still offered, so the pulse has a reason to run")
      #expect(
        coordinator.lapsedPendingCountForTesting == 0,
        "but nothing lapsed remains, so the pulse will not re-walk the directory")
    }
  #endif

  #if DEBUG
    /// An INVALID row plus a live one.
    ///
    /// The store deletes invalid rows without a receipt — correctly, since a
    /// corrupt file is not a user letting a recovery lapse. Evicting memory on
    /// receipts alone therefore left such a row in `transcripts` after its file
    /// was gone, so the sweep trigger never returned to zero and the directory
    /// was re-walked every minute while an unrelated live row counted down.
    @Test("a row deleted WITHOUT a receipt still leaves memory")
    func invalidRowIsEvictedDespiteNoReceipt() async throws {
      let store = makeStore()
      let log = EventLog()
      let coordinator = makeCoordinator(log, store: store)

      // Future-stamped beyond tolerance: `PendingAdmission` calls it corrupt, so
      // the store sweeps it and issues NO receipt.
      let skewedID = UUID()
      try store.savePending(
        Transcript(
          id: skewedID, text: "from the future",
          escapeRecoveredAt: Date().addingTimeInterval(
            AppConstants.pendingClockSkewTolerance + 3600),
          escapeRecoveryTakeID: "take-skew"))
      let live = Transcript(
        text: "still offered", escapeRecoveredAt: Date().addingTimeInterval(-60),
        escapeRecoveryTakeID: "take-live")
      try store.savePending(live)

      // Both in memory, which is the situation after a load that preceded the
      // skew.
      coordinator.setTranscriptsForTesting([
        Transcript(
          id: skewedID, text: "from the future",
          escapeRecoveredAt: Date().addingTimeInterval(
            AppConstants.pendingClockSkewTolerance + 3600),
          escapeRecoveryTakeID: "take-skew"),
        live,
      ])
      #expect(
        coordinator.lapsedPendingCountForTesting == 1, "control: the skewed row counts as lapsed")

      await coordinator.sweepExpiredPending()

      #expect(log.expired.isEmpty, "a corrupt file is not a user letting a recovery lapse")
      #expect(
        coordinator.lapsedPendingCountForTesting == 0,
        "but it must still leave memory, or the pulse re-walks the directory every minute")
      #expect(
        coordinator.visibleTranscripts.count == 1, "and the live row is untouched")
    }
  #endif

  #if DEBUG
    /// A latecomer must not resume before the sweep it coalesced onto finishes.
    ///
    /// Returning early made `await deleteExpiredPending()` a lie: `load()` could
    /// resume while the walk was still running and read rows about to be
    /// deleted.
    ///
    /// The gate is what makes this observable. An earlier version awaited BOTH
    /// callers and asserted the directory was empty — which the winner
    /// guarantees on its own, so an early-returning latecomer passed. Holding
    /// the sweep open is the only way to see who resumed when.
    @Test("a second concurrent caller cannot resume before the sweep finishes")
    func latecomerAwaitsTheWinner() async throws {
      let store = makeStore()
      for index in 0..<5 {
        try store.savePending(
          Transcript(
            text: "aged out \(index)",
            escapeRecoveredAt: Date().addingTimeInterval(
              -(AppConstants.pendingTranscriptRetention + 60)),
            escapeRecoveryTakeID: "take-\(index)"))
      }

      let release = GateBox()
      TranscriptStore.sweepGateForTesting = { await release.wait() }
      defer { TranscriptStore.sweepGateForTesting = nil }

      async let winner = store.deleteExpiredPending()
      await Task.yield()  // let the winner claim the in-flight slot

      let latecomerDone = GateBox()
      let latecomer = Task { @MainActor in
        let result = try? await store.deleteExpiredPending()
        latecomerDone.open()
        return result
      }

      // The sweep is held open, so nothing may have finished.
      await Task.yield()
      #expect(
        latecomerDone.isOpen == false,
        "the latecomer resumed while the sweep was still running")

      release.open()
      _ = try await winner
      _ = await latecomer.value
      #expect(latecomerDone.isOpen, "control: it does finish once the sweep completes")
      #expect(try await store.loadPending().isEmpty)
    }

    /// A row that lapses WHILE the first sweep is walking must still be swept.
    ///
    /// The latecomer carries a later clock. When it merely awaited the winner
    /// and returned the winner's emptiness, a row that crossed its deadline
    /// mid-walk was classified live by that walk and then never re-examined:
    /// the file and its expiry receipt were stranded until History reloaded,
    /// and the pulse that would have retried stops once nothing looks lapsed.
    ///
    /// The gate is what makes the boundary reachable at all. Without holding
    /// the sweep open there is no interval for the deadline to fall inside.
    @Test("a row lapsing mid-sweep is swept once by the latecomer's own clock")
    func latecomerRunsItsOwnPassWithItsOwnClock() async throws {
      let store = makeStore()
      let stampedAt = Date()
      let deadline = stampedAt.addingTimeInterval(AppConstants.pendingTranscriptRetention)
      try store.savePending(
        Transcript(
          text: "lapsed while the first sweep was walking",
          escapeRecoveredAt: stampedAt,
          escapeRecoveryTakeID: "take-boundary"))

      let release = GateBox()
      TranscriptStore.sweepGateForTesting = { await release.wait() }
      defer { TranscriptStore.sweepGateForTesting = nil }

      // The owner's clock stops one second SHORT of the deadline, so its walk
      // correctly leaves the row alone.
      async let owner = store.deleteExpiredPending(now: deadline.addingTimeInterval(-1))
      await Task.yield()  // let the owner claim the in-flight slot

      let latecomerDone = GateBox()
      let latecomer = Task { @MainActor in
        let result = try? await store.deleteExpiredPending(now: deadline.addingTimeInterval(1))
        latecomerDone.open()
        return result
      }

      await Task.yield()
      #expect(
        latecomerDone.isOpen == false,
        "control: the latecomer must still be waiting, or the boundary was never crossed mid-sweep")

      release.open()
      let ownerResult = try await owner
      let latecomerResult = try #require(await latecomer.value)

      #expect(
        ownerResult.expired.isEmpty,
        "the owner's clock says the row is still live, and it must not report it")
      #expect(
        ownerResult.deletedIDs.isEmpty, "nor delete it")

      let receipts = ownerResult.expired + latecomerResult.expired
      #expect(receipts.count == 1, "reported exactly once, by whichever pass saw it lapse")
      #expect(receipts.first?.takeID == "take-boundary")
      #expect(
        ownerResult.deletedIDs.union(latecomerResult.deletedIDs).count == 1,
        "and deleted exactly once")
      #expect(
        try await store.loadPending().isEmpty,
        "the file is gone — not stranded until History reloads")
    }

    /// A one-shot gate. Not a clock: the test opens it explicitly.
    ///
    /// LOCKED, and the lock is load bearing. This is waited on from the sweep's
    /// DETACHED walk and opened from the main actor, so the unsynchronised
    /// version had two races. The lethal one was a torn check-then-append:
    /// `wait()` read `opened` as false, `open()` then ran and drained the list,
    /// and only afterwards did the continuation get appended — to a list nobody
    /// would ever resume. That is an unresumed `CheckedContinuation`, i.e. a
    /// permanent hang, and it took a suite from 0.03s to killed-at-84-minutes.
    ///
    /// It became reachable only when a latecomer began running its OWN pass, so
    /// the gate went from one waiter to two. The lesson is not about locks: a
    /// change to how many times a seam is ENTERED can turn a benign test helper
    /// into a deadlock, and the seam is where to look when a passing suite
    /// starts hanging intermittently. It passed three runs before it hung.
    private final class GateBox: @unchecked Sendable {
      private let lock = NSLock()
      private var opened = false
      private var waiters: [CheckedContinuation<Void, Never>] = []

      var isOpen: Bool { lock.withLock { opened } }

      func open() {
        var pending: [CheckedContinuation<Void, Never>] = []
        lock.withLock {
          guard !opened else { return }
          opened = true
          pending = waiters
          waiters = []
        }
        // Resumed OUTSIDE the lock: a continuation can run arbitrary code.
        for continuation in pending { continuation.resume() }
      }

      func wait() async {
        await withCheckedContinuation { continuation in
          let alreadyOpen: Bool = lock.withLock {
            guard !opened else { return true }
            waiters.append(continuation)
            return false
          }
          // The re-check and the append are ONE atomic step. Checking before
          // entering the continuation is what allowed the gap.
          if alreadyOpen { continuation.resume() }
        }
      }
    }
  #endif

  // MARK: Payload shape

  /// The privacy boundary is the network. Envious Labs receives metadata only —
  /// never dictated content, and never anything naming where it was going.
  @Test("no event carries content or a paste target")
  func payloadsAreContentFree() async throws {
    let store = makeStore()
    let log = EventLog()
    let coordinator = makeCoordinator(log, store: store)
    let secret = "the quarterly revenue figure is forty two"
    let stamped = Transcript(
      text: secret, escapeRecoveredAt: Date().addingTimeInterval(-120),
      escapeRecoveryTakeID: "take-priv")
    try store.savePending(stamped)
    coordinator.load()
    await coordinator.waitForLoadForTesting()

    coordinator.keep(try #require(coordinator.visibleTranscripts.first))
    await coordinator.sweepExpiredPending()

    // Everything that left the coordinator, rendered.
    let emitted =
      log.kept.map { "\($0.ageMs) \($0.takeID)" } + log.expired.map { "\($0.ageMs) \($0.takeID)" }
    #expect(emitted.isEmpty == false, "control: something was actually emitted to inspect")
    for payload in emitted {
      #expect(payload.contains(secret) == false, "transcript text must never leave the machine")
      #expect(
        payload.contains(stamped.id.uuidString) == false,
        "the row id is not the join key; take_id is")
    }
  }
}
