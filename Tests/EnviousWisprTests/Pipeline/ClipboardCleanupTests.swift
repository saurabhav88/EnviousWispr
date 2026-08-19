import AppKit
import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

// MARK: - ClipboardCleanupTests (#2197)
//
// Every case drives an ISOLATED pasteboard (`pasteboardWithUniqueName`), never
// `NSPasteboard.general` — the developer's real clipboard is not a fixture
// (`ClipboardIsolationFreezeTests`, #2146).
//
// No case sleeps to decide the subject is finished. `awaitPendingCleanup()` and
// `cancelPendingAndAwait()` both await the subject's own task, including the
// case that proves cleanup was ABANDONED — a cancelled task still runs to
// completion, so its completion is a real signal
// (testing-philosophy.md RULE: never-guess-when-the-subject-is-finished).

/// Product Outcome: when these fail, the user's clipboard is not returned, or is
/// replaced with the wrong thing.
@Suite("Clipboard cleanup scheduling (#2197)", .tags(.productOutcome), .serialized)
@MainActor
struct ClipboardCleanupTests {

  private static let fast = 5  // ms

  // Board access here is deliberately plain AppKit, NOT `PasteService`.
  //
  // `ClipboardIsolationFreezeTests` allows exactly one suite to touch
  // clipboard-capable `PasteService` entry points, and widening that allowlist
  // to admit this file would weaken the guard for every future test in it. These
  // helpers need none of that capability: they set up and read an isolated
  // board, which AppKit does directly.
  private func put(_ text: String, on pb: NSPasteboard) {
    pb.clearContents()
    pb.setString(text, forType: .string)
  }

  private func snapshot(of pb: NSPasteboard) -> ClipboardSnapshot {
    ClipboardSnapshot(
      items: pb.string(forType: .string).map { [[.string: Data($0.utf8)]] } ?? [],
      changeCount: pb.changeCount)
  }

  private func string(_ snapshot: ClipboardSnapshot) -> String? {
    snapshot.items.first?[.string].map { String(decoding: $0, as: UTF8.self) }
  }

  private func board(holding text: String) -> NSPasteboard {
    let pb = NSPasteboard.withUniqueName()
    put(text, on: pb)
    return pb
  }

  private func withFastCleanup(_ body: () async -> Void) async {
    ClipboardCleanup.resetPendingForTests()
    ClipboardCleanup.testDelayOverrideMs = Self.fast
    await body()
    ClipboardCleanup.resetPendingForTests()
    ClipboardCleanup.testDelayOverrideMs = nil
  }

  // MARK: The change itself

  @Test("The user's clipboard is still restored, with the same content")
  func restoresAfterTheDelay() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      let snapshot = snapshot(of: pb)

      put("our dictated payload", on: pb)
      let afterOurWrite = pb.changeCount

      ClipboardCleanup.scheduleRestore(
        snapshot, changeCountAfterPaste: afterOurWrite, tier: .cgEvent, on: pb)

      // The point of the change: the caller is NOT blocked, so our payload is
      // still on the board the instant after scheduling.
      #expect(pb.string(forType: .string) == "our dictated payload")

      await ClipboardCleanup.awaitPendingCleanup()
      #expect(pb.string(forType: .string) == "the user's own clipboard")
    }
  }

  @Test("A board the user changed during the window is left alone")
  func declinesWhenTheBoardMoved() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      let snapshot = snapshot(of: pb)
      put("our dictated payload", on: pb)
      let afterOurWrite = pb.changeCount

      ClipboardCleanup.scheduleRestore(
        snapshot, changeCountAfterPaste: afterOurWrite, tier: .cgEvent, on: pb)
      // The user copies something while we wait.
      put("something the user just copied", on: pb)

      await ClipboardCleanup.awaitPendingCleanup()
      #expect(pb.string(forType: .string) == "something the user just copied")
    }
  }

  // MARK: Pending-cleanup states — the class this design had to close

  @Test(
    "A delivery starting while cleanup is pending inherits, never photographing our own payload")
  func inheritsRatherThanPhotographingOurPayload() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      let snapshot = snapshot(of: pb)
      put("dictation one", on: pb)

      ClipboardCleanup.scheduleRestore(
        snapshot, changeCountAfterPaste: pb.changeCount, tier: .cgEvent, on: pb)

      // A second delivery begins before the first cleanup ran. The board still
      // holds OUR text; photographing it would save dictation one as "the user's
      // clipboard" and hand it back to them later.
      #expect(string(ClipboardCleanup.snapshotForDelivery(from: pb)) == "the user's own clipboard")
    }
  }

  @Test("A delivery starting after the board MOVED photographs it, never a stale snapshot")
  func photographsWhenTheBoardMoved() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      let snapshot = snapshot(of: pb)
      put("dictation one", on: pb)
      ClipboardCleanup.scheduleRestore(
        snapshot, changeCountAfterPaste: pb.changeCount, tier: .cgEvent, on: pb)

      // The user copies something. The pending snapshot is now stale, and
      // inheriting it would destroy what they just copied — the inverse of the
      // bug above, and the worse one.
      put("something the user just copied", on: pb)

      #expect(
        string(ClipboardCleanup.snapshotForDelivery(from: pb)) == "something the user just copied")
      #expect(ClipboardCleanup.hasPending == false)
    }
  }

  @Test(
    "A pending LEGACY REWRITE is inherited as its legacy text, not the repaired payload on the board"
  )
  func inheritsLegacyTextNotTheRepairedPayload() async {
    await withFastCleanup {
      let pb = NSPasteboard.withUniqueName()
      // Restore is OFF on this path, so the board holds our REPAIRED payload and
      // a rewrite to the legacy one is pending.
      put("repaired payload", on: pb)
      ClipboardCleanup.scheduleLegacyRewrite(
        legacyText: "legacy payload", submittedChangeCount: pb.changeCount,
        tier: .cgEvent, on: pb)

      #expect(string(ClipboardCleanup.snapshotForDelivery(from: pb)) == "legacy payload")
    }
  }

  @Test("A cancelled cleanup ABANDONS its work rather than performing it early")
  func cancellationAbandons() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      let snapshot = snapshot(of: pb)
      put("our dictated payload", on: pb)
      ClipboardCleanup.scheduleRestore(
        snapshot, changeCountAfterPaste: pb.changeCount, tier: .cgEvent, on: pb)

      // Cancelling must not be read as "do it now". If it were, the restore would
      // fire before the target app had read our payload — the wrong-text failure.
      // Awaiting the cancelled task is what makes this a real assertion: the task
      // has demonstrably finished, and it did not touch the board.
      await ClipboardCleanup.cancelPendingAndAwait()

      #expect(pb.string(forType: .string) == "our dictated payload")
    }
  }

  @Test("A superseded cleanup does not clear the slot that replaced it")
  func supersedeKeepsTheNewerSlot() async {
    await withFastCleanup {
      let pbA = NSPasteboard.withUniqueName()
      put("first payload", on: pbA)
      ClipboardCleanup.scheduleRestore(
        snapshot(of: pbA), changeCountAfterPaste: pbA.changeCount,
        tier: .cgEvent, on: pbA)

      let pbB = NSPasteboard.withUniqueName()
      put("the user's own clipboard", on: pbB)
      let snapshotB = snapshot(of: pbB)
      put("second payload", on: pbB)
      ClipboardCleanup.scheduleRestore(
        snapshotB, changeCountAfterPaste: pbB.changeCount, tier: .cgEvent, on: pbB)

      await ClipboardCleanup.awaitPendingCleanup()
      #expect(pbB.string(forType: .string) == "the user's own clipboard")
      // And the superseded one must NOT have fired. Asserting only on pbB left
      // this test blind: a mutation run showed that removing the identity guard
      // entirely still passed, because nothing observed the older board.
      #expect(pbA.string(forType: .string) == "first payload")
      #expect(ClipboardCleanup.hasPending == false)
    }
  }

  @Test("The slot is cleared even when the restore guard DECLINES")
  func slotClearsOnDecline() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      let snapshot = snapshot(of: pb)
      put("our dictated payload", on: pb)
      ClipboardCleanup.scheduleRestore(
        snapshot, changeCountAfterPaste: pb.changeCount, tier: .cgEvent, on: pb)
      // Force the guard to decline.
      put("user copied this", on: pb)

      await ClipboardCleanup.awaitPendingCleanup()
      // A slot left populated would be inherited by the next delivery AND would
      // block update installs forever, because `hasPending` gates them.
      #expect(ClipboardCleanup.hasPending == false)
    }
  }

  @Test("hasPending is true only while cleanup is outstanding")
  func hasPendingTracksTheWindow() async {
    await withFastCleanup {
      #expect(ClipboardCleanup.hasPending == false)
      let pb = board(holding: "the user's own clipboard")
      let snapshot = snapshot(of: pb)
      put("our dictated payload", on: pb)
      ClipboardCleanup.scheduleRestore(
        snapshot, changeCountAfterPaste: pb.changeCount, tier: .cgEvent, on: pb)
      #expect(ClipboardCleanup.hasPending == true)
      await ClipboardCleanup.awaitPendingCleanup()
      #expect(ClipboardCleanup.hasPending == false)
    }
  }

  @Test("A legacy rewrite keeps its own body: it applies, and it declines on a moved board")
  func legacyRewriteKeepsItsOwnBody() async {
    await withFastCleanup {
      let pb = NSPasteboard.withUniqueName()
      put("repaired payload", on: pb)
      ClipboardCleanup.scheduleLegacyRewrite(
        legacyText: "legacy payload", submittedChangeCount: pb.changeCount,
        tier: .cgEvent, on: pb)
      await ClipboardCleanup.awaitPendingCleanup()
      #expect(pb.string(forType: .string) == "legacy payload")

      let pb2 = NSPasteboard.withUniqueName()
      put("repaired payload", on: pb2)
      ClipboardCleanup.scheduleLegacyRewrite(
        legacyText: "legacy payload", submittedChangeCount: pb2.changeCount,
        tier: .cgEvent, on: pb2)
      put("user copied this", on: pb2)
      await ClipboardCleanup.awaitPendingCleanup()
      #expect(pb2.string(forType: .string) == "user copied this")
    }
  }
}
