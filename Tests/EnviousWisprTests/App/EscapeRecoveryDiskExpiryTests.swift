import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// #2186: a cancelled dictation is deleted at its moment, whatever the UI is doing.
///
/// ## The requirement
///
/// Founder, 2026-08-20: *"the software shouldn't be based on whether the
/// window's open or not. As long as the application is running, the timer should
/// be ticking… And then it just deletes. And if they close the application and
/// then they reopen the application, it should know how long it's been since the
/// last time that message was and run any cleanups at that time."*
///
/// ## What was actually wrong, measured rather than read
///
/// Not what the issue said. `sweepExpiredPending()` DOES run at launch today —
/// a probe inside it fired on a build whose launch path never calls it — because
/// SwiftUI materialises the `Window(id: "main")` scene, `SettingsView`'s
/// `@State selectedSection` defaults to `.history`, and `HistoryContentView`'s
/// `.task` calls `load()`. That window is never on screen: `CGWindowList`
/// reports it under `ALL` and not under `ON-SCREEN`.
///
/// So the promise is kept by an invisible view mounting, which is the fragility
/// worth removing rather than a defect a user can see.
///
/// **The genuine gap is the middle case, and no issue named it.** A row carried
/// over from a PREVIOUS session is not in `transcripts` unless History loaded it,
/// and the countdown arms from `livePendingCount`, which reads `transcripts`. So
/// while the app runs, nothing is watching that row's deadline: it survives its
/// moment and waits for a relaunch.
///
/// These are Product Outcome tests. When they fail, the plaintext of a dictation
/// the user CANCELLED outlives the window three shipped surfaces promise —
/// `help/escape-recovery.md`, `help/what-data-is-collected.md`, and the in-app
/// countdown that renders "Deleted in 23h".
@MainActor
@Suite("Escape Recovery disk expiry (#2186)", .tags(.productOutcome))
struct EscapeRecoveryDiskExpiryTests {

  /// `spools` defaults to EMPTY — never the real disk reader. A test store must
  /// not read the user's own crash-recovery directory, and "no spools" is the
  /// state the sibling pending suites already assume.
  private func makeStore(spools: @escaping @Sendable () -> Set<String>? = { [] })
    -> TranscriptStore
  {
    makeStoreWithDirectory(spools: spools).store
  }

  private func makeStoreWithDirectory(
    spools: @escaping @Sendable () -> Set<String>? = { [] }
  ) -> (store: TranscriptStore, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-2186-\(UUID().uuidString)", isDirectory: true)
    return (
      TranscriptStore(directory: directory, liveSpoolIDs: spools),
      directory)
  }

  /// Written from the detached walk and read on the main actor, so it carries
  /// its own lock rather than relying on the two never overlapping.
  private final class MainThreadFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    func record(_ isMain: Bool) {
      lock.lock()
      defer { lock.unlock() }
      value = isMain
    }
    var wasCalled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return value != nil
    }
    var onMain: Bool? {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }

  private final class EventLog {
    var expired: [(ageMs: Int, takeID: String)] = []
  }

  private func makeCoordinator(_ log: EventLog, store: TranscriptStore) -> TranscriptCoordinator {
    TranscriptCoordinator(
      store: store,
      emitEscapeRecoveryKept: { _, _ in },
      emitEscapeRecoveryExpired: { log.expired.append((ageMs: $0, takeID: $1)) })
  }

  #if DEBUG
    /// `@MainActor` explicitly: a nested type does NOT inherit the suite's
    /// isolation, and the pulse's sleep seam is `@Sendable`. Global-actor
    /// isolation is what makes this capturable there.
    @MainActor
    private final class PulseGate {
      var iterations = 0
      var onWait: ((Int) -> Void)?
      func advance() {
        iterations += 1
        onWait?(iterations)
      }
    }

    @Test(
      "a dictation held from a previous session starts the countdown, with History never loaded")
    func carriedOverRowArmsTheCountdown() async throws {
      let store = makeStore()
      let log = EventLog()
      let coordinator = makeCoordinator(log, store: store)

      // On disk and STILL COUNTING DOWN — the state after a relaunch. Nothing
      // puts it in `transcripts`, because that is what `load()` does and History
      // is never opened here.
      try store.savePending(
        Transcript(
          text: "cancelled yesterday, still offered",
          escapeRecoveredAt: Date().addingTimeInterval(-60),
          escapeRecoveryTakeID: "take-carried-over"))

      #expect(
        !coordinator.hasPendingPulseForTesting,
        "control: nothing is watching before a sweep — the row is not in memory")

      await coordinator.sweepExpiredPending()

      #expect(
        log.expired.isEmpty, "control: a live row must not be swept or reported")
      #expect(
        coordinator.liveOnDiskPendingCountForTesting == 1,
        "the sweep must report what is still counting down ON DISK")
      #expect(
        coordinator.hasPendingPulseForTesting,
        """
        #2186: a dictation held from a previous session left the countdown unarmed, so nothing \
        was watching its deadline for the whole session. It would survive its moment and wait \
        for a relaunch — while three shipped surfaces say it is deleted.
        """)
    }

    @Test("a Keep or Delete stops the countdown instead of walking the directory forever")
    func removalRefreshesTheDiskCache() async throws {
      let store = makeStore()
      let log = EventLog()
      let coordinator = makeCoordinator(log, store: store)

      let id = UUID()
      let row = Transcript(
        id: id, text: "held, then deleted by the user",
        escapeRecoveredAt: Date().addingTimeInterval(-60),
        escapeRecoveryTakeID: "take-then-deleted")
      try store.savePending(row)
      coordinator.setTranscriptsForTesting([row])
      await coordinator.sweepExpiredPending()
      #expect(coordinator.hasPendingPulseForTesting, "control: the countdown is running")
      #expect(coordinator.liveOnDiskPendingCountForTesting == 1, "control: disk truth cached")

      // The user removes it. `liveOnDiskPendingCount` is a CACHE of the last
      // sweep and this changes the directory it describes, so stopping on the
      // stale value leaves the pulse alive with nothing to do — a directory walk
      // every minute for the life of the app, which is the stranded retry this
      // file's own comments warn about. Cloud review, P2.
      coordinator.delete(row)
      await coordinator.waitForRefreshForTesting()

      #expect(
        coordinator.liveOnDiskPendingCountForTesting == 0,
        "the cache must be re-read from disk after a removal, not trusted")
      #expect(
        !coordinator.hasPendingPulseForTesting,
        """
        #2186: nothing is pending after the user removed the only held row, yet the countdown is \
        still running. It will walk the pending directory every minute for the life of the app.
        """)
    }

    @Test("a kept live dictation's leftover copy is deleted before it can re-arm the pulse")
    func keptLiveShadowIsDeletedDespiteSurvivingSpool() async throws {
      let store = makeStore(spools: { ["session-kept"] })

      // The state a half-failed Keep leaves behind: the permanent row written,
      // the pending copy NOT removed. `promotePending` does exactly this pair
      // in this order, and its removal is best-effort.
      let id = UUID()
      let row = Transcript(
        id: id, text: "the user pressed Keep on this", recoverySessionID: "session-kept",
        escapeRecoveredAt: Date().addingTimeInterval(-60),
        escapeRecoveryTakeID: "take-kept")
      try store.savePending(row)
      try store.save(row.promotedFromPending())

      let swept = try await store.deleteExpiredPending()

      // Local review, P2. The spool guard exists to stop a row being deleted
      // while it is the only proof its audio was already recovered — but the
      // PERMANENT row carries that same proof, so this copy proves nothing and
      // protects nothing. Retaining it kept the pulse walking the directory
      // every minute for the life of the app, for a dictation the user KEPT.
      #expect(
        swept.retainedForSpool == 0,
        """
        #2186: a leftover copy of a KEPT dictation was retained because its audio survives. The \
        kept row already carries that proof, so this one is litter that is never collected — and \
        the countdown keeps running against it forever.
        """)
      #expect(swept.deletedIDs.contains(id), "it must be swept as the litter it is")
      #expect(
        swept.remainingLive == 0 && swept.nextLiveDeadline == nil,
        "a kept live shadow must not be re-offered or keep the expiry pulse armed")
      #expect(
        swept.expired.isEmpty,
        "and NOT reported as expired — the user kept this dictation, nothing lapsed")
    }

    @Test("the recovery folder is never read on the main thread")
    func spoolReadHappensOffTheMainActor() async throws {
      // The production reader does far more than read: it creates the recovery
      // directory, chmods it, writes metadata, then enumerates and sorts every
      // spool. On the main actor that is a filesystem stall in front of app
      // launch and of every retry pulse. Local review, P2.
      let sawMainThread = MainThreadFlag()
      let store = makeStore(spools: {
        sawMainThread.record(Thread.isMainThread)
        return []
      })
      try store.savePending(
        Transcript(
          text: "anything, so the walk has a row to consider",
          escapeRecoveredAt: Date().addingTimeInterval(-48 * 3600),
          escapeRecoveryTakeID: "take-offmain"))

      _ = try await store.deleteExpiredPending()

      #expect(sawMainThread.wasCalled, "control: the reader ran at all")
      #expect(
        sawMainThread.onMain == false,
        """
        #2186: the recovery folder was scanned on the main thread. That scan creates a directory, \
        changes its permissions, writes a file and sorts every recording in it — in front of the \
        app appearing, and again on every retry.
        """)
    }

    @Test("a removal re-reads the directory instead of assuming it is now empty")
    func removalRearmsAnotherRowStillOnDisk() async throws {
      let store = makeStore()
      let log = EventLog()
      let coordinator = makeCoordinator(log, store: store)

      // The row the user is about to remove: in memory AND on disk.
      let removed = Transcript(
        id: UUID(), text: "the one the user deletes",
        escapeRecoveredAt: Date().addingTimeInterval(-60),
        escapeRecoveryTakeID: "take-removed")
      // The row this test exists for: on disk ONLY, still counting down. That is
      // a dictation held from a previous session with History never opened, so
      // nothing in `transcripts` knows it exists.
      try store.savePending(removed)
      try store.savePending(
        Transcript(
          text: "carried over, nobody has looked at it",
          escapeRecoveredAt: Date().addingTimeInterval(-120),
          escapeRecoveryTakeID: "take-carried-over"))
      coordinator.setTranscriptsForTesting([removed])
      await coordinator.sweepExpiredPending()
      #expect(coordinator.liveOnDiskPendingCountForTesting == 2, "control: both rows counted")

      coordinator.delete(removed)
      await coordinator.waitForRefreshForTesting()

      // Zeroing the cache is what lets the pulse stop, and it is only ever
      // provisional — the directory decides. A removal that zeroed and never
      // looked again would be indistinguishable from this on the single-row
      // case, which is why that case cannot bind the re-read.
      #expect(
        coordinator.liveOnDiskPendingCountForTesting == 1,
        """
        #2186: after removing one held row the app assumed the directory was empty. A dictation \
        cancelled in an earlier session is still on disk and still counting down, and nothing is \
        watching its deadline any more.
        """)
      #expect(
        coordinator.hasPendingPulseForTesting,
        "and the countdown that row needs has stopped, so it survives to the next launch")
    }

    @Test("a walk overtaken by a removal does not write its stale count back")
    func supersededWalkDoesNotWriteItsResult() async throws {
      let store = makeStore()
      let log = EventLog()
      let coordinator = makeCoordinator(log, store: store)

      let id = UUID()
      let row = Transcript(
        id: id, text: "still counting down while a walk is in flight",
        escapeRecoveredAt: Date().addingTimeInterval(-60),
        escapeRecoveryTakeID: "take-superseded")
      try store.savePending(row)
      coordinator.setTranscriptsForTesting([row])

      // The removal lands in the ONE window that matters: the walk has finished
      // and counted this row, and has not yet written that count back. In the
      // app the two arrive as separate tasks whose main-actor resumptions are
      // unordered, so this is staged through the subject's own seam rather than
      // raced — a race would pass on the runs where it happened to win, which is
      // indistinguishable from a guard that works.
      //
      // One-shot: cleared before it acts, or the walk it arms re-enters here.
      coordinator.onSweepWalkFinishedForTesting = { [weak coordinator] in
        coordinator?.onSweepWalkFinishedForTesting = nil
        coordinator?.simulateRemovalDuringWalkForTesting()
      }
      await coordinator.sweepExpiredPending()

      #expect(
        coordinator.liveOnDiskPendingCountForTesting == 0,
        """
        #2186 cloud review P2: a walk that finished BEFORE the user's removal wrote its count back \
        anyway. That count describes a directory that no longer exists, so the countdown stays \
        armed until a row that is already deleted reaches its former deadline.
        """)

      // Deliberately NOT asserting the pulse is stopped here, and the reason is
      // the finding rather than a caveat: this scenario supersedes a walk, it
      // does not remove the row, so the row is still live in memory and the
      // pulse is correctly armed for it. Asserting a stop would pass only
      // because a DIFFERENT input was broken. The removal-and-stop outcome is
      // owned by `removalRefreshesTheDiskCache` above, which drives the real
      // `delete` path end to end.
    }

    @Test("and it is deleted at its moment, still with History never loaded")
    func carriedOverRowIsDeletedAtItsMoment() async throws {
      let store = makeStore()
      let log = EventLog()
      let gate = PulseGate()
      // Constructed inline rather than through the helper: routing the
      // `@Sendable` sleep seam through an extra parameter loses the isolation
      // that makes capturing `gate` legal. Matches `pulseSweepsOnDetection`.
      let coordinator = TranscriptCoordinator(
        store: store,
        pendingPulseSleep: { _ in await gate.advance() },
        emitEscapeRecoveryKept: { _, _ in },
        emitEscapeRecoveryExpired: { log.expired.append((ageMs: $0, takeID: $1)) })

      // The id is pinned and REUSED below, and that is not tidiness. `Transcript`
      // mints a fresh id when none is given, so writing a second row without it
      // leaves the LIVE one on disk beside the expired one — `remainingLive`
      // never reaches zero, `pendingPulseHasWork` never goes false, and the loop
      // spins forever against a gate that no longer sleeps. Caught as a hung
      // xctest process at 5m31s with no compiler running: a livelock, not a slow build.
      let id = UUID()
      try store.savePending(
        Transcript(
          id: id, text: "cancelled yesterday, still offered",
          escapeRecoveredAt: Date().addingTimeInterval(-60),
          escapeRecoveryTakeID: "take-carried-over"))
      await coordinator.sweepExpiredPending()
      #expect(coordinator.hasPendingPulseForTesting, "control: the countdown is running")

      // The row crosses its deadline while the app runs. Driven by SIGNAL, not by
      // a wall clock: the SAME row is rewritten already past its window and the
      // deadline seam is brought forward, so the next tick is where expiry
      // happens. Racing a real 0.4s deadline is the flake this file's sibling
      // suite already had to remove once.
      // LIVELOCK NET, and it is required rather than defensive. This loop's exit
      // condition is the very thing under test: the pulse stops when nothing is
      // counting down, which only happens if the sweep deletes the row. Break
      // the sweep — which is exactly what the mutation battery does — and the
      // gate returns instantly forever, so the test SPINS instead of failing.
      // Measured: a hung xctest process at 5m48s on a suite that passes in 0.005s.
      //
      // So the cap fires LOUDLY and names itself, per this repo's rule that an
      // exhausted budget must never be mistaken for a settle.
      var capFired = false
      gate.onWait = { [weak coordinator] iteration in
        guard let coordinator else { return }
        if iteration == 1 {
          try? store.savePending(
            Transcript(
              id: id, text: "cancelled yesterday, still offered",
              escapeRecoveredAt: Date().addingTimeInterval(
                -(AppConstants.pendingTranscriptRetention + 1)),
              escapeRecoveryTakeID: "take-carried-over"))
          coordinator.setDiskExpiryDeadlineForTesting(.distantPast)
          return
        }
        if iteration >= 20 {
          capFired = true
          coordinator.cancelPulseForTesting()
        }
      }
      await coordinator.waitForPulseForTesting()

      #expect(
        !capFired,
        """
        #2186 livelock net: the countdown ran 20 iterations without the row being swept, so the \
        loop never ran out of work. That is the pulse spinning, NOT a settle — read this as the \
        sweep failing to delete the disk row, not as a slow test.
        """)

      #expect(
        log.expired.map(\.takeID) == ["take-carried-over"],
        """
        #2186: the row crossed its deadline with the app running and nothing deleted it. \
        "As long as the application is running, the timer should be ticking… and then it just \
        deletes." Events seen: \(log.expired.map(\.takeID))
        """)
      #expect(
        try await store.loadPending().isEmpty,
        "and the plaintext must actually be gone from disk, not merely hidden")
    }
  #endif

  // MARK: - The spool guard
  //
  // A pending row is the PROOF its spool was already recovered —
  // `allRecoveredSessionIDs()` reads exactly these rows. Delete an expired one
  // while its spool survives and the next scan replays that spool as a fresh
  // dictation, handing back the take the user CANCELLED. These three are the
  // only tests that exercise it: the 19 in `EscapeRecoveryTelemetryTests` set no
  // `recoverySessionID`, so they pass whatever this rule does.

  @Test("an expired dictation whose audio is still on disk is KEPT, not deleted")
  func expiredRowWithSurvivingSpoolIsRetained() async throws {
    let session = UUID().uuidString
    let store = makeStore(spools: { [session] })
    let log = EventLog()
    let coordinator = makeCoordinator(log, store: store)

    try store.savePending(
      Transcript(
        text: "cancelled, and its audio has not been cleared yet",
        recoverySessionID: session,
        escapeRecoveredAt: Date().addingTimeInterval(
          -(AppConstants.pendingTranscriptRetention + 3600)),
        escapeRecoveryTakeID: "take-spool-alive"))

    await coordinator.sweepExpiredPending()

    #expect(
      log.expired.isEmpty,
      """
      #2186: an expired row whose spool SURVIVES must not be swept. Deleting it removes the only \
      proof that spool was already recovered, so the next crash-recovery scan replays it and \
      hands the user back a dictation they cancelled.
      """)
    // DEBUG-only seam, so the assertion is wrapped rather than the test: the
    // KEEP behaviour above must be proven in BOTH configurations, and only the
    // retry check needs a hook that does not exist in a Release build. An
    // unwrapped seam here breaks the Release COMPILE, which a Debug-only run
    // cannot see.
    #if DEBUG
      #expect(
        coordinator.hasPendingPulseForTesting,
        "and the retry must stay armed, or the row waits for a relaunch after recovery clears it")
    #endif
  }

  @Test("once the audio is gone the same dictation is deleted")
  func expiredRowIsSweptOnceSpoolIsCleared() async throws {
    let session = UUID().uuidString
    // The paired ACCEPTED case: identical row, identical clock, spool absent.
    // Without it, a guard that simply never sweeps anything would pass above.
    let store = makeStore(spools: { [] })
    let log = EventLog()
    let coordinator = makeCoordinator(log, store: store)

    try store.savePending(
      Transcript(
        text: "cancelled, audio already cleared",
        recoverySessionID: session,
        escapeRecoveredAt: Date().addingTimeInterval(
          -(AppConstants.pendingTranscriptRetention + 3600)),
        escapeRecoveryTakeID: "take-spool-gone"))

    await coordinator.sweepExpiredPending()

    #expect(log.expired.map(\.takeID) == ["take-spool-gone"])
    #expect(try await store.loadPending().isEmpty, "and the plaintext is gone from disk")
  }

  @Test("an INVALID row whose audio survives is kept too — its id still de-dupes")
  func invalidRowWithSurvivingSpoolIsRetained() async throws {
    let session = UUID().uuidString
    let store = makeStore(spools: { [session] })
    let log = EventLog()
    let coordinator = makeCoordinator(log, store: store)

    // A FUTURE-skewed stamp makes this `.invalid` — it carries no transcript in
    // the sweep's enum, so the enum cannot report its recovery id. But
    // `decodeAnyPendingIdentities` counts an invalid row's id anyway, on the
    // stated grounds that "a row we refuse to count here becomes a spool we
    // replay again". Deleting it therefore strips a live de-dup key.
    // Cloud review found this; the first version of the guard swept it.
    try store.savePending(
      Transcript(
        text: "clock-skewed, but its audio was already transcribed",
        recoverySessionID: session,
        escapeRecoveredAt: Date().addingTimeInterval(86_400 * 30),
        escapeRecoveryTakeID: "take-invalid-spool-alive"))

    await coordinator.sweepExpiredPending()

    #expect(
      try await !store.pendingRecoverySessionIDs().isEmpty,
      """
      #2186: the sweep deleted an INVALID pending row whose spool is still on disk. Its \
      recoverySessionID is de-dup proof that `allRecoveredSessionIDs()` honours, so removing \
      the file makes the next scan replay that spool and hand back a cancelled dictation.
      """)
  }

  @Test("a filename collision with an unrelated permanent row keeps the invalid row's spool proof")
  func invalidFilenameCollisionDoesNotBypassSpoolGuard() async throws {
    let session = UUID().uuidString
    let fixture = makeStoreWithDirectory(spools: { [session] })
    let store = fixture.store
    let pendingID = UUID()
    let unrelatedPermanentID = UUID()
    let pending = Transcript(
      id: pendingID,
      text: "cancelled audio still needs its de-dup proof",
      recoverySessionID: session,
      escapeRecoveredAt: Date().addingTimeInterval(
        -(AppConstants.pendingTranscriptRetention + 3600)),
      escapeRecoveryTakeID: "take-filename-collision")
    try store.savePending(pending)
    try store.save(
      Transcript(
        id: unrelatedPermanentID,
        text: "a different dictation that happened to take this filename",
        recoverySessionID: UUID().uuidString))

    // Pending file A decodes as transcript B. A permanent A exists, but it is
    // unrelated: treating filename equality as a permanent twin would skip the
    // spool guard and delete B's recovery-session de-dup proof.
    let pendingDir = fixture.directory.appendingPathComponent(AppConstants.pendingTranscriptsDir)
    let original = pendingDir.appendingPathComponent("\(pendingID.uuidString).json")
    let collidingName = pendingDir.appendingPathComponent("\(unrelatedPermanentID.uuidString).json")
    try FileManager.default.moveItem(at: original, to: collidingName)

    let swept = try await store.deleteExpiredPending()

    #expect(swept.retainedForSpool == 1)
    #expect(
      try await store.pendingRecoverySessionIDs().contains(session),
      """
      #2256: a filename collision must not erase the invalid row's recovery-session key. The next \
      scan would otherwise replay the surviving cancelled-audio spool as a duplicate dictation.
      """)
  }

  @Test("an unreadable audio folder keeps the dictation rather than guessing")
  func unreadableSpoolDirectoryRetains() async throws {
    // `nil` is the THIRD answer — could not determine — and it must not collapse
    // into "no spools". Collapsing it deletes the dedup proof at exactly the
    // moment we cannot see what it protects, which is the fail-OPEN direction.
    let store = makeStore(spools: { nil })
    let log = EventLog()
    let coordinator = makeCoordinator(log, store: store)

    try store.savePending(
      Transcript(
        text: "cancelled, and we cannot see the audio folder",
        recoverySessionID: UUID().uuidString,
        escapeRecoveredAt: Date().addingTimeInterval(
          -(AppConstants.pendingTranscriptRetention + 3600)),
        escapeRecoveryTakeID: "take-spools-unknown"))

    await coordinator.sweepExpiredPending()

    #expect(
      log.expired.isEmpty,
      "#2186: cannot-determine must fail CLOSED — retain, never delete on a guess")
  }

  @Test("an install with no held dictations leaves the countdown off")
  func emptyStoreLeavesTheCountdownOff() async throws {
    let store = makeStore()
    let log = EventLog()
    let coordinator = makeCoordinator(log, store: store)

    // No pending directory at all — the ordinary case, since Escape Recovery is
    // off by default. The sweep short-circuits and reports a COMPLETE walk of
    // nothing, so the countdown must stay off rather than run for the life of
    // the app over an empty directory.
    await coordinator.sweepExpiredPending()

    #if DEBUG
      #expect(coordinator.liveOnDiskPendingCountForTesting == 0)
      #expect(
        !coordinator.hasPendingPulseForTesting,
        "nothing is counting down, so nothing should be watching")
    #endif
  }

  // NOT COVERED HERE, and named rather than left to be discovered: the
  // UNREADABLE-directory case. A walk that could not enumerate reports
  // `walkComplete == false`, and the coordinator must then leave
  // `liveOnDiskPendingCount` ALONE — storing that walk's zero would read as
  // "nothing is counting down" and stop the countdown on the one occasion it
  // must keep running. An earlier version of the test above claimed that
  // property in its NAME while asserting only the absent-directory path, which
  // short-circuits to a COMPLETE walk. Reaching the real case needs a directory
  // that exists and cannot be read; the guard is in `sweepExpiredPending` and is
  // currently held by `lastSweepIncomplete` alone.
}
