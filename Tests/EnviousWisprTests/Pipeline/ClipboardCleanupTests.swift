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

  // MARK: The takeover (#2465)
  //
  // Quick Add's clipboard fallback writes to the board for a reason that is not a delivery, so it
  // needs the same preservation `snapshotForDelivery` gives a delivery plus two things a delivery
  // does not: the pending operation CONSUMED rather than read, and a baseline that is the board's
  // current count rather than the snapshot's. Both differences are defects if they are wrong, and
  // both are invisible from a happy-path run.

  @Test("A takeover hands back the user's clipboard, not our own payload on the board")
  func takeoverInheritsRatherThanPhotographingOurPayload() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      let snapshot = snapshot(of: pb)
      put("our dictated payload", on: pb)
      ClipboardCleanup.scheduleRestore(
        snapshot, changeCountAfterPaste: pb.changeCount, tier: .cgEvent, on: pb)

      guard
        case .granted(let payload, let baseline) = ClipboardCleanup.beginTakeover(
          maximumBytes: 1 << 20, from: pb)
      else {
        Issue.record("the takeover was refused on a small clipboard")
        return
      }
      #expect(string(payload) == "the user's own clipboard")

      // **The baseline is the board's CURRENT count, and this is the assertion the API exists
      // for.** The snapshot's own count is from when the DICTATION snapshot was taken, so a poll
      // comparing against it would read "something changed" on its very first look.
      #expect(baseline == pb.changeCount)
      #expect(baseline != snapshot.changeCount, "or the two numbers are indistinguishable here")

      // **KNOWN GAP, stated rather than papered over with a test that cannot see it.** The payload
      // and the baseline are also required to describe the SAME MOMENT, which `beginTakeover`
      // enforces by reading the count, building the payload, and reading the count again. No
      // single-threaded test can distinguish that from the torn version — the same reason
      // `validation-discipline.md` gives for why a contract test cannot tell an atomic primitive
      // from check-then-act. Proving it would mean racing a writer against the takeover, which is
      // the honest test to write and is filed as hardening rather than faked here.
    }
  }

  @Test("A granted takeover CONSUMES the pending restore, so nothing fires on top of it")
  func takeoverConsumesPendingCleanup() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      let snapshot = snapshot(of: pb)
      put("our dictated payload", on: pb)
      ClipboardCleanup.scheduleRestore(
        snapshot, changeCountAfterPaste: pb.changeCount, tier: .cgEvent, on: pb)
      #expect(ClipboardCleanup.hasPending)

      _ = ClipboardCleanup.beginTakeover(maximumBytes: 1 << 20, from: pb)

      // **`snapshotForDelivery` would have left this armed**, because a delivery goes on to
      // schedule its own cleanup that supersedes it. This caller schedules nothing, so a surviving
      // restore fires on top of the board it just handed back.
      #expect(!ClipboardCleanup.hasPending, "an armed restore would overwrite the fallback's work")

      // The board the caller is about to write is whatever it was; nothing else will touch it now.
      put("the copied word", on: pb)
      #expect(pb.string(forType: .string) == "the copied word")
    }
  }

  @Test("A takeover refused on budget leaves the pending restore exactly as it found it")
  func takeoverRefusedOnBudgetDoesNotDamagePendingWork() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      let snapshot = snapshot(of: pb)
      put("our dictated payload", on: pb)
      ClipboardCleanup.scheduleRestore(
        snapshot, changeCountAfterPaste: pb.changeCount, tier: .cgEvent, on: pb)

      // **The board moves, which makes the pending value stale and sends the takeover down the
      // branch that READS the board.** That is the only branch a budget can refuse: the other two
      // return a value already held in memory, where bounding saves nothing and refusing would
      // decline to hand back a clipboard we are holding anyway.
      //
      // This scenario is what the row needs after #2465's confirming round moved the budget from a
      // post-hoc measurement into the snapshot itself. Before that, ANY pending state plus a tiny
      // budget produced a refusal; now the refusal has one route and the test has to take it.
      put("something the user just copied", on: pb)

      // Refusing must not tear down state we declined to take responsibility for: a caller that
      // gets nothing back has nothing to restore, so if the pending work were cancelled here the
      // user's clipboard would be gone with no owner left.
      guard case .clipboardTooLarge = ClipboardCleanup.beginTakeover(maximumBytes: 1, from: pb)
      else {
        Issue.record("a one-byte budget must refuse on the board-reading branch")
        return
      }
      #expect(ClipboardCleanup.hasPending, "the refusal cancelled work it was not taking over")

      // And the pending cleanup, left armed, still declines on its own terms because the board
      // moved — so the user's newer copy survives, which is the outcome the arming exists to allow.
      await ClipboardCleanup.awaitPendingCleanup()
      #expect(pb.string(forType: .string) == "something the user just copied")
    }
  }

  @Test("The budget counts EVERY representation, not just the readable one")
  func takeoverBudgetCountsEveryRepresentation() async {
    await withFastCleanup {
      let pb = NSPasteboard.withUniqueName()
      pb.clearContents()
      let item = NSPasteboardItem()
      item.setData(Data("word".utf8), forType: .string)
      // A large non-text representation beside a tiny string. Measuring the string alone would let
      // this through as "small" and then hold the whole thing in memory.
      item.setData(Data(repeating: 0, count: 64 * 1024), forType: .tiff)
      pb.writeObjects([item])

      guard case .clipboardTooLarge = ClipboardCleanup.beginTakeover(maximumBytes: 8 * 1024, from: pb)
      else {
        Issue.record("a 64 KB image under an 8 KB budget must refuse")
        return
      }
      // **The budget bounds what we TOUCH, not what we keep (#2465, confirming round).** It used to
      // snapshot everything and measure afterwards, so a large image was fully materialized on the
      // main actor before the budget got a say; `boundedSaveClipboard` now stops at the
      // representation that crosses the line.
      //
      // Exercised THROUGH `beginTakeover` rather than by calling that function here, deliberately.
      // `ClipboardIsolationFreezeTests` permits exactly one suite to touch clipboard-capable
      // `PasteService` entry points, and it refused this file when the call was written directly —
      // correctly, since widening the allowlist to admit this suite would weaken the guard for
      // every future test in it. The real caller is the subject anyway.
      // The pair, or the row above passes against a budget check that refuses everything.
      guard case .granted = ClipboardCleanup.beginTakeover(maximumBytes: 1 << 20, from: pb) else {
        Issue.record("the same clipboard must be accepted under a budget that fits it")
        return
      }
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
