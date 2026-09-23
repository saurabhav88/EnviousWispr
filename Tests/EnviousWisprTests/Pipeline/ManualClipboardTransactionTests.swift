import AppKit
import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

// MARK: - ManualClipboardTransactionTests (#3106)
//
// Every case drives an ISOLATED pasteboard, never `NSPasteboard.general`, and an injected dispatch
// closure, never a real Cmd+V (`ClipboardIsolationFreezeTests`, #2146). No case sleeps to learn the
// restore finished: `awaitPendingCleanup()` awaits the subject's own task.

/// Product Outcome: when these fail, Paste/Copy Last Dictation loses the user's clipboard, pastes
/// the wrong text into a dictation that is still landing, or pastes nothing while reporting success.
@Suite(
  "Paste and Copy Last Dictation: the clipboard transaction (#3106)", .tags(.productOutcome),
  .serialized)
@MainActor
struct ManualClipboardTransactionTests {

  private static let fast = 5  // ms

  // Plain AppKit, not `PasteService`: this file is not the freeze guard's allowlisted suite.
  private func put(_ text: String, on pb: NSPasteboard) {
    pb.clearContents()
    pb.setString(text, forType: .string)
  }

  private func board(holding text: String) -> NSPasteboard {
    let pb = NSPasteboard.withUniqueName()
    put(text, on: pb)
    return pb
  }

  private func snapshot(of pb: NSPasteboard) -> ClipboardSnapshot {
    ClipboardSnapshot(
      items: pb.string(forType: .string).map { [[.string: Data($0.utf8)]] } ?? [],
      changeCount: pb.changeCount)
  }

  private func withFastCleanup(_ body: () async -> Void) async {
    ClipboardCleanup.resetPendingForTests()
    ClipboardCleanup.testDelayOverrideMs = Self.fast
    await body()
    ClipboardCleanup.resetPendingForTests()
    ClipboardCleanup.testDelayOverrideMs = nil
  }

  /// A dictation that just pasted: our payload is on the board and its restore is armed and FRESH.
  private func dictationJustPasted(on pb: NSPasteboard) {
    let users = snapshot(of: pb)
    put("the dictation still being read", on: pb)
    ClipboardCleanup.scheduleRestore(
      users, changeCountAfterPaste: pb.changeCount, tier: .cgEvent, on: pb)
  }

  // MARK: Paste

  @Test(
    "Paste with restore on: the text is on the board when Cmd+V is posted, then the clipboard comes back"
  )
  func pasteWithRestore() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      var dispatches = 0
      var boardAtDispatch: String?

      let result = ClipboardCleanup.manualPaste(
        text: "send the draft to Maya", restore: true, on: pb
      ) {
        dispatches += 1
        boardAtDispatch = pb.string(forType: .string)
        return true
      }

      #expect(result == .dispatched)
      #expect(dispatches == 1)
      #expect(boardAtDispatch == "send the draft to Maya")
      #expect(ClipboardCleanup.hasPending, "the restore is scheduled, not run inline")

      await ClipboardCleanup.awaitPendingCleanup()
      #expect(pb.string(forType: .string) == "the user's own clipboard")
    }
  }

  @Test("Paste with restore off: the text stays on the board and nothing is scheduled")
  func pasteWithoutRestore() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      let result = ClipboardCleanup.manualPaste(
        text: "send the draft to Maya", restore: false, on: pb
      ) { true }

      #expect(result == .dispatched)
      #expect(!ClipboardCleanup.hasPending)
      #expect(pb.string(forType: .string) == "send the draft to Maya")
    }
  }

  @Test("Cmd+V that could not be posted leaves the text on the board to paste by hand")
  func failedDispatchLeavesText() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      let result = ClipboardCleanup.manualPaste(
        text: "send the draft to Maya", restore: true, on: pb
      ) { false }

      #expect(result == .dispatchFailed)
      #expect(!ClipboardCleanup.hasPending, "a restore would take away the only copy to paste")
      #expect(pb.string(forType: .string) == "send the draft to Maya")
    }
  }

  @Test("A clipboard manager writing during the restore window keeps its write")
  func clipboardManagerWriteSurvivesRestore() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      #expect(
        ClipboardCleanup.manualPaste(text: "send the draft to Maya", restore: true, on: pb) { true }
          == .dispatched)
      put("something copied during the window", on: pb)

      await ClipboardCleanup.awaitPendingCleanup()
      #expect(pb.string(forType: .string) == "something copied during the window")
    }
  }

  // MARK: Copy

  @Test("Copy puts the text on the board, posts nothing and schedules nothing")
  func copy() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      #expect(ClipboardCleanup.manualCopy(text: "send the draft to Maya", on: pb) == .copied)
      #expect(pb.string(forType: .string) == "send the draft to Maya")
      #expect(!ClipboardCleanup.hasPending)
    }
  }

  // MARK: When the board is not ours

  @Test("A dictation's paste still being read: both refuse without touching the board")
  func freshPendingRefuses() async {
    await withFastCleanup {
      for legacyRewrite in [false, true] {
        let pb = board(holding: "the user's own clipboard")
        if legacyRewrite {
          put("the dictation still being read", on: pb)
          ClipboardCleanup.scheduleLegacyRewrite(
            legacyText: "legacy text", submittedChangeCount: pb.changeCount, tier: .cgEvent, on: pb)
        } else {
          dictationJustPasted(on: pb)
        }
        let before = pb.changeCount
        var dispatches = 0

        let paste = ClipboardCleanup.manualPaste(text: "reused", restore: true, on: pb) {
          dispatches += 1
          return true
        }
        let copy = ClipboardCleanup.manualCopy(text: "reused", on: pb)

        #expect(paste == .clipboardBusy, "legacyRewrite=\(legacyRewrite)")
        #expect(copy == .clipboardBusy, "legacyRewrite=\(legacyRewrite)")
        #expect(dispatches == 0)
        #expect(pb.changeCount == before, "the board was not written")
        #expect(ClipboardCleanup.hasPending, "the dictation's own cleanup is left armed")
        ClipboardCleanup.resetPendingForTests()
      }
    }
  }

  @Test("A stale pending restore is dropped, so it cannot fire over the new text")
  func stalePendingIsCancelled() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      dictationJustPasted(on: pb)
      put("the board moved on", on: pb)  // the pending restore is now stale

      #expect(ClipboardCleanup.manualCopy(text: "send the draft to Maya", on: pb) == .copied)
      #expect(!ClipboardCleanup.hasPending)
      #expect(pb.string(forType: .string) == "send the draft to Maya")
    }
  }

  @Test("Quick Add mid-transaction: both refuse without touching the board")
  func activeTakeoverRefuses() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      guard
        case .granted(_, _, let token) = ClipboardCleanup.beginTakeover(
          maximumBytes: 1 << 20, from: pb)
      else {
        Issue.record("precondition: the takeover must be granted on an idle board")
        return
      }
      let before = pb.changeCount
      var dispatches = 0

      let paste = ClipboardCleanup.manualPaste(text: "reused", restore: false, on: pb) {
        dispatches += 1
        return true
      }
      #expect(paste == .clipboardBusy)
      #expect(ClipboardCleanup.manualCopy(text: "reused", on: pb) == .clipboardBusy)
      #expect(dispatches == 0)
      #expect(pb.changeCount == before)
      #expect(!ClipboardCleanup.wasSuperseded(token), "Quick Add keeps the board it holds")
      ClipboardCleanup.endTakeover(token)
    }
  }
}
