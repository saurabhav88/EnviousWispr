import EnviousWisprCore
import Foundation
import Observation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// History policy for held Escape Recovery rows (#2087, chunk 9).
///
/// Every rule here is READ-TIME: a held row is visible until its retention
/// window elapses, is never searched while held, and never counts as a
/// dictation. Nothing produces a held row in production yet — the producer
/// arrives at activation — so these drive the policy directly.
///
/// The expiry sweep is deliberately NOT the authority. Visibility is decided
/// against the clock on every read, so a sweep that fails, throws, or has not
/// run cannot leave an expired row on screen.
///
/// Split deliberately: everything reachable through `load()` runs in BOTH
/// configurations, because the launch merge and the delete paths are where a
/// regression would cost a user their text. Only the cases that must place a
/// row the store would refuse to return — an already-expired one, above all —
/// need the DEBUG seam, and those are grouped at the end.
@MainActor
@Suite("Escape Recovery history policy (#2087)")
struct EscapeRecoveryHistoryPolicyTests {

  // MARK: Fixtures

  private func makeStore() -> (TranscriptStore, URL) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-2087-history-\(UUID().uuidString)", isDirectory: true)
    return (TranscriptStore(directory: dir), dir)
  }

  /// A held row whose retention window began `age` seconds ago.
  private func held(_ text: String, age: TimeInterval, createdAt: Date = Date()) -> Transcript {
    Transcript(
      text: text, createdAt: createdAt,
      escapeRecoveredAt: Date().addingTimeInterval(-age),
      escapeRecoveryTakeID: "take-\(text)")
  }

  private func permanent(_ text: String, createdAt: Date = Date()) -> Transcript {
    Transcript(text: text, createdAt: createdAt)
  }

  private var window: TimeInterval { AppConstants.pendingTranscriptRetention }

  // MARK: Launch merge — runs in both configurations

  @Test("root wins when Keep crashed between writing the copy and deleting the pending file")
  func rootPrecedenceOnLaunchMerge() async throws {
    let (store, _) = makeStore()
    let coordinator = TranscriptCoordinator(store: store)

    // Exactly the crash window: the promoted copy is in root and the pending
    // file was never removed, so the same id lives in both namespaces.
    let stamped = held("kept just before the crash", age: 120)
    try store.savePending(stamped)
    try store.save(stamped.promotedFromPending())

    coordinator.load()
    await coordinator.waitForLoadForTesting()

    let matching = coordinator.visibleTranscripts.filter { $0.id == stamped.id }
    #expect(matching.count == 1, "the user sees the row they kept exactly once")
    #expect(
      matching.first?.escapeRecoveredAt == nil,
      "and it is the permanent copy, not a duplicate still counting down")
  }

  @Test("with nothing held, the loaded list is exactly what the permanent store returned")
  func mergeIsIdentityWhenNothingIsHeld() async throws {
    let (store, _) = makeStore()
    let coordinator = TranscriptCoordinator(store: store)

    // Deliberately sharing a createdAt: re-sorting the combined list would be
    // free to reorder these, which is a visible change to shipped History
    // ordering caused by a feature that is supposed to be inert.
    let base = Date()
    for row in [
      permanent("first", createdAt: base),
      permanent("second", createdAt: base),
      permanent("third", createdAt: base.addingTimeInterval(-30)),
    ] { try store.save(row) }
    let expected = try await store.loadAll().map(\.id)

    coordinator.load()
    await coordinator.waitForLoadForTesting()

    #expect(
      coordinator.visibleTranscripts.map(\.id) == expected,
      "identical ORDER, not merely the same set")
  }

  @Test("a held row loads alongside permanent ones, newest first")
  func heldRowsMergeByRecency() async throws {
    let (store, _) = makeStore()
    let coordinator = TranscriptCoordinator(store: store)
    let now = Date()

    try store.save(permanent("oldest", createdAt: now.addingTimeInterval(-300)))
    try store.save(permanent("newest", createdAt: now))
    try store.savePending(held("middle", age: 60, createdAt: now.addingTimeInterval(-150)))

    coordinator.load()
    await coordinator.waitForLoadForTesting()

    #expect(coordinator.visibleTranscripts.map(\.displayText) == ["newest", "middle", "oldest"])
  }

  /// The tie is where the merge and a plain re-sort actually diverge.
  ///
  /// `Array.sorted` is not documented as stable; the current implementation
  /// preserves input order, which would put the HELD row first because it is
  /// concatenated first. The merge specifies the opposite — an unresolved offer
  /// does not displace a dictation the user completed at the same instant — so
  /// this test is what distinguishes the two, and what stops the merge being
  /// replaced by a one-liner that behaves differently on a toolchain where the
  /// sort is not stable.
  @Test("a held row loses a tie with a permanent row")
  func heldRowLosesATieWithAPermanentRow() async throws {
    let (store, _) = makeStore()
    let coordinator = TranscriptCoordinator(store: store)
    let instant = Date()

    try store.save(permanent("completed", createdAt: instant))
    try store.savePending(held("offered", age: 60, createdAt: instant))

    coordinator.load()
    await coordinator.waitForLoadForTesting()

    #expect(coordinator.visibleTranscripts.map(\.displayText) == ["completed", "offered"])
  }

  /// The signal `keep` depends on. Without it, "ignored because it expired" and
  /// "promoted" are the same return value, and the caller cannot tell whether
  /// it is safe to clear the row's held marker.
  @Test("promotePending reports whether it actually promoted anything")
  func promoteReportsWhetherItActed() throws {
    let (store, _) = makeStore()
    let live = held("live", age: 60)
    let stale = held("stale", age: window + 5)
    try store.savePending(live)
    try store.savePending(stale)

    #expect(try store.promotePending(id: live.id), "a live row promotes")
    #expect(try store.promotePending(id: live.id) == false, "and does not promote twice")
    #expect(try store.promotePending(id: stale.id) == false, "an expired row is refused")
    #expect(try store.promotePending(id: UUID()) == false, "so is one that never existed")
  }

  @Test("an expired row on disk never reaches memory through a load")
  func expiredRowsAreNotLoaded() async throws {
    let (store, _) = makeStore()
    let coordinator = TranscriptCoordinator(store: store)
    try store.savePending(held("aged out", age: window + 60))

    coordinator.load()
    await coordinator.waitForLoadForTesting()

    #expect(
      coordinator.visibleTranscripts.isEmpty, "the store refuses to offer it in the first place")
  }

  @Test("deleteAll takes held rows with it")
  func deleteAllRemovesPendingToo() async throws {
    let (store, _) = makeStore()
    let coordinator = TranscriptCoordinator(store: store)
    try store.savePending(held("held", age: 60))
    try store.save(permanent("ordinary"))
    coordinator.load()
    await coordinator.waitForLoadForTesting()
    #expect(coordinator.visibleTranscripts.count == 2, "control: both loaded")

    coordinator.deleteAll()
    coordinator.load()
    await coordinator.waitForLoadForTesting()

    #expect(
      coordinator.visibleTranscripts.isEmpty,
      "pending/ is a child of the directory deleteAll removes wholesale")
  }

  @Test("deleting a held row removes its pending file, so a relaunch cannot resurrect it")
  func deleteRemovesThePendingFile() async throws {
    let (store, _) = makeStore()
    let coordinator = TranscriptCoordinator(store: store)
    let stamped = held("deleted on purpose", age: 60)
    try store.savePending(stamped)
    coordinator.load()
    await coordinator.waitForLoadForTesting()
    let loaded = try #require(coordinator.visibleTranscripts.first, "control: the held row loaded")

    coordinator.delete(loaded)

    #expect(coordinator.visibleTranscripts.isEmpty)
    #expect(
      try await store.loadPending().isEmpty,
      "a root-only delete would leave the file and reload it at next launch")

    coordinator.load()
    await coordinator.waitForLoadForTesting()
    #expect(coordinator.visibleTranscripts.isEmpty, "and the reload confirms it stayed deleted")
  }

  /// The sweep can be best-effort; a DELETE cannot.
  ///
  /// An expired row that survives its sweep is still invisible, because expiry
  /// is decided at read time. A deleted row is unexpired by definition, so a
  /// pending file left behind is loaded again at next launch and the recording
  /// the user deleted returns with its countdown running. Reporting success
  /// there is worse than failing: the caller drops it from memory and nothing
  /// is left to notice.
  /// Both halves, and the ROOT TWIN is what makes it a real test.
  ///
  /// With only a pending file present, an implementation that throws the
  /// instant the pending removal fails passes just as well as one that attempts
  /// both — the two are indistinguishable. Giving the id a copy in each
  /// namespace (the Keep crash window) separates them: the root file must be
  /// GONE even though the pending removal failed, which only holds if both
  /// removals are attempted before either failure is raised.
  @Test("a failed pending removal is reported, and does not abort the root removal")
  func deleteSurfacesAFailedPendingRemoval() throws {
    let (store, dir) = makeStore()
    let stamped = held("undeletable", age: 60)
    try store.savePending(stamped)
    try store.save(stamped.promotedFromPending())

    let rootFile = dir.appendingPathComponent("\(stamped.id.uuidString).json")
    #expect(
      FileManager.default.fileExists(atPath: rootFile.path), "control: the root twin exists")

    let pendingDir = dir.appendingPathComponent(
      AppConstants.pendingTranscriptsDir, isDirectory: true)
    // Removing a directory entry needs write permission on the DIRECTORY.
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: pendingDir.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: pendingDir.path)
    }

    #expect(throws: (any Error).self) {
      try store.delete(id: stamped.id)
    }
    #expect(
      FileManager.default.fileExists(atPath: rootFile.path) == false,
      "the root copy is removed even though the pending removal failed")
  }

  /// A destructive confirmation must count what it will destroy.
  ///
  /// `transcriptCount` is the DICTATION statistic and excludes held recoveries,
  /// which is right for a sidebar and wrong for a Delete All dialog: a history
  /// showing only held rows would offer to delete "all 0 transcripts" and then
  /// delete them. The two counts are different questions, so they are different
  /// properties.
  @Test("the delete confirmation counts held rows; the dictation stat does not")
  func deletableCountIncludesHeldRows() async throws {
    let (store, _) = makeStore()
    let coordinator = TranscriptCoordinator(store: store)
    try store.savePending(held("held", age: 60))
    coordinator.load()
    await coordinator.waitForLoadForTesting()

    #expect(coordinator.transcriptCount == 0, "a held row is not a dictation")
    #expect(
      coordinator.deletableCount == 1,
      "but Delete All would take it, so the confirmation must say so")
    // The SENTENCE, not just the count. While the view interpolated a count of
    // its own choosing, swapping it for the dictation statistic survived the
    // entire suite — nothing testable observed which one the dialog used.
    #expect(
      coordinator.deleteAllConfirmationMessage.contains("delete 1 transcript."),
      "the dialog must not offer to delete 'all 0 transcripts' and then delete one")
    #expect(
      coordinator.deleteAllConfirmationMessage.contains("transcripts") == false,
      "one row is not a plural — an earlier version of this test PINNED 'all 1 transcripts'")
  }

  @Test("the delete confirmation is plural for more than one row")
  func deleteConfirmationIsPluralForMany() async throws {
    let (store, _) = makeStore()
    let coordinator = TranscriptCoordinator(store: store)
    try store.save(permanent("one"))
    try store.savePending(held("two", age: 60))
    coordinator.load()
    await coordinator.waitForLoadForTesting()

    #expect(coordinator.deleteAllConfirmationMessage.contains("all 2 transcripts"))
  }

  @Test("the delete confirmation counts nothing when there is nothing")
  func deleteConfirmationIsPluralForZero() {
    let (store, _) = makeStore()
    let coordinator = TranscriptCoordinator(store: store)

    #expect(
      coordinator.deleteAllConfirmationMessage.contains("all 0 transcripts"),
      "zero is plural, and the button is hidden at zero anyway")
  }

  /// The mirror of the case above, and it is not symmetric for free.
  ///
  /// Production removes the ROOT copy first, so an implementation that aborts
  /// the moment root removal fails would never reach the pending file — and the
  /// pending-side test cannot see that, because there the root removal
  /// succeeds. Only failing the FIRST removal proves both are attempted.
  @Test("a failed root removal does not abort the pending removal")
  func deleteAttemptsPendingEvenWhenRootFails() throws {
    let (store, dir) = makeStore()
    let stamped = held("undeletable root", age: 60)
    try store.savePending(stamped)
    try store.save(stamped.promotedFromPending())

    let pendingFile = dir.appendingPathComponent(
      AppConstants.pendingTranscriptsDir, isDirectory: true
    ).appendingPathComponent("\(stamped.id.uuidString).json")
    #expect(
      FileManager.default.fileExists(atPath: pendingFile.path), "control: the pending twin exists")

    // Write permission on the ROOT directory is what removing the root entry
    // needs; `pending/` is a child with its own permissions, so its entry stays
    // removable.
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    #expect(throws: (any Error).self) {
      try store.delete(id: stamped.id)
    }
    #expect(
      FileManager.default.fileExists(atPath: pendingFile.path) == false,
      "the pending copy is removed even though the root removal failed")
  }

  @Test("Keep makes the row permanent and stops its clock")
  func keepPromotesTheRow() async throws {
    let (store, _) = makeStore()
    let coordinator = TranscriptCoordinator(store: store)
    let stamped = held("worth keeping", age: 300)
    try store.savePending(stamped)
    coordinator.load()
    await coordinator.waitForLoadForTesting()
    let loaded = try #require(coordinator.visibleTranscripts.first)

    coordinator.keep(loaded)

    #expect(
      coordinator.visibleTranscripts.first?.escapeRecoveredAt == nil,
      "the in-memory row stops being pending")
    #expect(coordinator.transcriptCount == 1, "and starts counting as a dictation")
    #expect(
      try await store.loadPending().isEmpty,
      "the pending file is gone, so a relaunch cannot resume the countdown")
    #expect(try await store.loadAll().map(\.id) == [stamped.id], "and the permanent copy exists")
  }

  @Test("Keep is idempotent")
  func keepTwiceChangesNothing() async throws {
    let (store, _) = makeStore()
    let coordinator = TranscriptCoordinator(store: store)
    try store.savePending(held("twice", age: 60))
    coordinator.load()
    await coordinator.waitForLoadForTesting()
    let loaded = try #require(coordinator.visibleTranscripts.first)

    coordinator.keep(loaded)
    coordinator.keep(coordinator.visibleTranscripts[0])

    #expect(try await store.loadAll().count == 1)
    #expect(coordinator.visibleTranscripts.count == 1)
  }

  @Test("a held row is never a search result, and never counts as a dictation")
  func heldRowsAreExcludedFromSearchAndCount() async throws {
    let (store, _) = makeStore()
    let coordinator = TranscriptCoordinator(store: store)
    try store.savePending(held("quarterly numbers", age: 60))
    try store.save(permanent("quarterly report"))
    coordinator.load()
    await coordinator.waitForLoadForTesting()

    #expect(coordinator.transcriptCount == 1, "a held row is an offer, not a dictation")

    coordinator.searchQuery = "quarterly"
    #expect(
      coordinator.filteredTranscripts.map(\.displayText) == ["quarterly report"],
      "an accidental Escape must not pollute results for 24 hours")

    coordinator.searchQuery = ""
    #expect(
      coordinator.filteredTranscripts.count == 2,
      "but it stays reachable by scrolling History, which is where the user left it")
  }

  // MARK: Cases that need a row the store would refuse to hand back

  #if DEBUG

    /// The read-time filter, driven directly. This CANNOT be reached through
    /// `load()`: `loadPending` already refuses expired rows, so a row that ages
    /// out while the app is open — the actual scenario — is only reproducible by
    /// placing it in memory.
    @Test("a held row inside its window is visible; past it, it is not")
    func expiryIsDecidedAtReadTime() {
      let (store, _) = makeStore()
      let coordinator = TranscriptCoordinator(store: store)

      coordinator.setTranscriptsForTesting([
        held("fresh", age: 60),
        held("nearly out", age: window - 60),
        held("just past", age: window + 1),
        permanent("ordinary"),
      ])

      let visible = coordinator.visibleTranscripts.map(\.displayText)
      #expect(visible.contains("fresh"))
      #expect(visible.contains("nearly out"), "the boundary is not reached until the full window")
      #expect(visible.contains("ordinary"), "permanent rows carry no stamp and never expire")
      #expect(
        visible.contains("just past") == false,
        "past the window the row is gone from the read, with no sweep involved")
    }

    @Test("an expired row is hidden even though nothing swept its file")
    func visibilityDoesNotDependOnTheSweep() throws {
      let (store, dir) = makeStore()
      let coordinator = TranscriptCoordinator(store: store)
      let expired = held("aged out", age: window + 3600)
      try store.savePending(expired)

      coordinator.setTranscriptsForTesting([expired])

      // The file is still on disk. That is the whole point of the test.
      let pendingDir = dir.appendingPathComponent(
        AppConstants.pendingTranscriptsDir, isDirectory: true)
      let files = try FileManager.default.contentsOfDirectory(atPath: pendingDir.path)
      #expect(
        files.contains("\(expired.id.uuidString).json"), "control: the file was never swept")

      #expect(coordinator.visibleTranscripts.isEmpty, "and it is invisible regardless")
    }

    /// The divergence that motivated `PendingAdmission` in the first place.
    ///
    /// A stamp in the future is CORRUPT, not "very fresh". Comparing elapsed
    /// time alone — which this method used to do — makes such a row visible in
    /// History indefinitely while the store refuses to return it, so the two
    /// sides disagree about the same file. Asking the shared authority is what
    /// keeps them the same answer.
    @Test("a future-dated stamp is not visible, it is corrupt")
    func futureStampsAreNotVisible() {
      let (store, _) = makeStore()
      let coordinator = TranscriptCoordinator(store: store)
      let skewed = Transcript(
        text: "from the future",
        escapeRecoveredAt: Date().addingTimeInterval(
          AppConstants.pendingClockSkewTolerance + 3600),
        escapeRecoveryTakeID: "skewed")

      coordinator.setTranscriptsForTesting([skewed])

      #expect(coordinator.visibleTranscripts.isEmpty, "beyond tolerance is corrupt, not fresh")
      #expect(coordinator.transcriptCount == 0)
      #expect(
        coordinator.hasPendingPulseForTesting == false,
        "and nothing counts down toward a deadline that has not begun")
    }

    @Test("a stamp inside the skew tolerance is still offered")
    func smallForwardSkewIsTolerated() {
      let (store, _) = makeStore()
      let coordinator = TranscriptCoordinator(store: store)
      let slightlyAhead = Transcript(
        text: "clock drift",
        escapeRecoveredAt: Date().addingTimeInterval(
          AppConstants.pendingClockSkewTolerance / 2),
        escapeRecoveryTakeID: "drift")

      coordinator.setTranscriptsForTesting([slightlyAhead])

      #expect(
        coordinator.visibleTranscripts.count == 1,
        "ordinary clock drift must not destroy a real recovery")
    }

    @Test("an expired held row is not counted either")
    func expiredRowsDoNotCount() {
      let (store, _) = makeStore()
      let coordinator = TranscriptCoordinator(store: store)

      coordinator.setTranscriptsForTesting([
        held("gone", age: window + 1),
        permanent("kept"),
      ])

      #expect(coordinator.transcriptCount == 1)
    }

    /// Inert on BOTH sides. An earlier version of this test checked only the
    /// store and passed while the in-memory row had its stamp cleared anyway —
    /// which would have put the expired recovery on screen as permanent
    /// History, resurrecting in the UI exactly the text the store refused to
    /// write. Storage refusing is only half the guarantee.
    @Test(
      "Keep on a row that expired between render and click changes nothing, on disk or on screen")
    func keepIsInertOnAnExpiredRow() async throws {
      let (store, _) = makeStore()
      let coordinator = TranscriptCoordinator(store: store)
      let stale = held("too late", age: window + 5)
      try store.savePending(stale)
      coordinator.setTranscriptsForTesting([stale])

      coordinator.keep(stale)

      #expect(
        try await store.loadAll().isEmpty,
        "nothing is written: text the user was told had gone is not resurrected")
      // The RAW view, deliberately: this asserts about a row the filter is
      // supposed to hide, so reading the visible list would assert nothing and
      // contradict the next expectation.
      #expect(
        coordinator.rawTranscriptsForTesting.first?.escapeRecoveredAt != nil,
        "and the in-memory row keeps its stamp rather than being promoted on screen")
      #expect(
        coordinator.visibleTranscripts.isEmpty,
        "so it stays invisible, which is what the user was promised")
      #expect(coordinator.transcriptCount == 0, "and is still not a dictation")
    }

    @Test("a held row appended mid-session starts its countdown")
    func appendingAHeldRowStartsThePulse() {
      let (store, _) = makeStore()
      let coordinator = TranscriptCoordinator(store: store)
      #expect(coordinator.hasPendingPulseForTesting == false, "control: nothing running")

      coordinator.append(held("held mid-session", age: 5))

      #expect(
        coordinator.hasPendingPulseForTesting,
        "the production route appends at runtime; without this the countdown would never advance")
    }

    @Test("appending an ordinary dictation starts no pulse")
    func appendingAPermanentRowStartsNoPulse() {
      let (store, _) = makeStore()
      let coordinator = TranscriptCoordinator(store: store)

      coordinator.append(permanent("ordinary"))

      #expect(coordinator.hasPendingPulseForTesting == false)
    }

    /// The pulse only matters if reading the list SUBSCRIBES to it. Observation
    /// tracks the properties actually read during evaluation, so this asserts
    /// the dependency exists rather than trusting that some future view will
    /// remember to read a counter.
    @Test("reading the visible list registers a dependency on the pulse")
    func visibleTranscriptsDependOnThePulse() {
      let (store, _) = makeStore()
      let coordinator = TranscriptCoordinator(store: store)
      coordinator.setTranscriptsForTesting([held("held", age: 60)])

      // A reference box, because `onChange` is `@Sendable` and cannot mutate a
      // captured local. It fires synchronously on the mutating actor, so no
      // further synchronisation is involved.
      let invalidated = InvalidationFlag()
      withObservationTracking {
        _ = coordinator.visibleTranscripts
      } onChange: {
        invalidated.fired = true
      }

      coordinator.bumpExpiryPulseForTesting()

      #expect(
        invalidated.fired,
        "bumping the pulse must invalidate a read of the visible list, or no redraw happens")
    }

    @Test("Keep on an ordinary row does nothing")
    func keepOnAPermanentRowIsANoOp() async throws {
      let (store, _) = makeStore()
      let coordinator = TranscriptCoordinator(store: store)
      let ordinary = permanent("never held")
      coordinator.setTranscriptsForTesting([ordinary])

      coordinator.keep(ordinary)

      #expect(try await store.loadAll().isEmpty, "no write for a row that was never pending")
    }

    // MARK: Pulse lifecycle

    @Test("the pulse runs only while a row is actually being held")
    func pulseIsAbsentWithoutHeldRows() {
      let (store, _) = makeStore()
      let coordinator = TranscriptCoordinator(store: store)

      coordinator.setTranscriptsForTesting([permanent("ordinary")])
      #expect(
        coordinator.hasPendingPulseForTesting == false,
        "the ordinary case — feature off, or nothing held — pays for no timer")

      coordinator.setTranscriptsForTesting([held("held", age: 60)])
      #expect(coordinator.hasPendingPulseForTesting)
    }

    @Test("an already-expired row does not start a pulse")
    func expiredRowStartsNoPulse() {
      let (store, _) = makeStore()
      let coordinator = TranscriptCoordinator(store: store)

      coordinator.setTranscriptsForTesting([held("aged out", age: window + 1)])

      #expect(
        coordinator.hasPendingPulseForTesting == false, "there is nothing left to count down")
    }

    @Test("Keep stops the pulse once the last held row is gone")
    func keepStopsThePulse() throws {
      let (store, _) = makeStore()
      let coordinator = TranscriptCoordinator(store: store)
      let stamped = held("last one", age: 60)
      try store.savePending(stamped)
      coordinator.setTranscriptsForTesting([stamped])
      #expect(coordinator.hasPendingPulseForTesting, "control: it was running")

      coordinator.keep(stamped)

      #expect(coordinator.hasPendingPulseForTesting == false)
    }

    /// Driven entirely by a signal: the injected wait is where the test decides
    /// what the world looks like on the next iteration, so no wall clock is
    /// involved and the loop cannot be raced.
    @Test("the pulse delivers a redraw and then stops itself once nothing is held")
    func pulseFiresThenSelfTerminates() async {
      let (store, _) = makeStore()
      let box = PulseBox()
      let coordinator = TranscriptCoordinator(
        store: store,
        pendingPulseSleep: { _ in await box.advance() })
      box.onWait = { [weak coordinator] iteration in
        guard let coordinator else { return }
        if iteration == 1 {
          // The held row ages out between one pulse and the next.
          coordinator.setTranscriptsForTesting([])
        } else if iteration >= PulseBox.limit {
          // Deadline. Reached only if the loop stopped honouring its own exit
          // condition; without this the suite would HANG instead of failing,
          // which is worse than having no test.
          coordinator.cancelPulseForTesting()
        }
      }

      coordinator.setTranscriptsForTesting([held("brief", age: 60)])
      #expect(coordinator.hasPendingPulseForTesting, "control: the pulse started")

      await coordinator.waitForPulseForTesting()

      #expect(
        box.iterations < PulseBox.limit,
        "the loop stopped on its own condition rather than being cut off at the deadline")
      #expect(
        coordinator.expiryPulse >= 1, "the redraw that carries the row past its deadline fires")
      #expect(
        coordinator.hasPendingPulseForTesting == false,
        "and nothing keeps waking for a row nobody can see")
    }

    /// Records that Observation invalidated a tracked read. `onChange` runs
    /// synchronously on the mutating thread, before the change lands, so this
    /// box is only ever touched from the same isolation that bumped the pulse —
    /// which is why unchecked is accurate here rather than a shortcut. The
    /// mutation control is what proves the callback actually ran.
    private final class InvalidationFlag: @unchecked Sendable {
      var fired = false
    }

    /// Stands in for the clock without being one: each `advance()` is exactly
    /// one loop iteration, and the test decides what the world looks like on
    /// each of them.
    @MainActor
    private final class PulseBox {
      static let limit = 50
      var iterations = 0
      var onWait: ((Int) -> Void)?

      func advance() {
        iterations += 1
        onWait?(iterations)
      }
    }

  #endif
}
