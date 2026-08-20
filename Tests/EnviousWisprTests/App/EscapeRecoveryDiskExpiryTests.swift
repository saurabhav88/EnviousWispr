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

  private func makeStore() -> TranscriptStore {
    TranscriptStore(
      directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("ew-2186-\(UUID().uuidString)", isDirectory: true))
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
      // `xctest` at 5m31s with no compiler running: a livelock, not a slow build.
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
      // Measured: a hung `xctest` at 5m48s on a suite that passes in 0.005s.
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

    #expect(coordinator.liveOnDiskPendingCountForTesting == 0)
    #expect(
      !coordinator.hasPendingPulseForTesting,
      "nothing is counting down, so nothing should be watching")
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
