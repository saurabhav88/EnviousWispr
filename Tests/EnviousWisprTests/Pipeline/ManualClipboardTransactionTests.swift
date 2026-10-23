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
  .serialized, .clipboardCleanupExclusive)
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
      users, changeCountAfterPaste: pb.changeCount, markTransient: false, tier: .cgEvent, on: pb)
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
        text: "send the draft to Maya", restore: true, markTransient: false, on: pb
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
        text: "send the draft to Maya", restore: false, markTransient: false, on: pb
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
        text: "send the draft to Maya", restore: true, markTransient: false, on: pb
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
        ClipboardCleanup.manualPaste(text: "send the draft to Maya", restore: true, markTransient: false, on: pb) { true }
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

  // MARK: A write that does not take

  /// `setString` refusing after `clearContents`: the board is empty, not holding the dictation.
  private static func refusedWrite(
    _ text: String, _ pb: NSPasteboard, _ kind: PasteService.WriteKind
  ) -> Int {
    pb.clearContents()
    return pb.changeCount
  }

  @Test(
    "A paste whose write does not take posts no Cmd+V and puts the clipboard back, restore on or off",
    arguments: [true, false])
  func pasteWriteFailed(restore: Bool) async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      var dispatches = 0
      let result = ClipboardCleanup.manualPaste(
        text: "send the draft to Maya", restore: restore, markTransient: false, on: pb, write: Self.refusedWrite
      ) {
        dispatches += 1
        return true
      }

      #expect(result == .writeFailed)
      #expect(dispatches == 0)
      #expect(!ClipboardCleanup.hasPending)
      #expect(pb.string(forType: .string) == "the user's own clipboard")
    }
  }

  // MARK: Transient marker (#3528)
  // The literal type string is the oracle: it is the nspasteboard.org convention managers read.

  private static let transientMarker = "org.nspasteboard.TransientType"

  private func carriesMarker(_ pb: NSPasteboard) -> Bool {
    pb.pasteboardItems?.contains { $0.types.map(\.rawValue).contains(Self.transientMarker) } ?? false
  }

  @Test("#3528: Paste Last with restore and the history setting on writes the text marked, on one item")
  func pasteWithRestoreWritesMarked() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      var markedAtDispatch = false
      var itemCountAtDispatch = 0
      let result = ClipboardCleanup.manualPaste(text: "send the draft to Maya", restore: true, markTransient: true, on: pb) {
        markedAtDispatch = self.carriesMarker(pb)
        itemCountAtDispatch = pb.pasteboardItems?.count ?? 0
        return true
      }

      #expect(result == .dispatched)
      #expect(markedAtDispatch)
      #expect(itemCountAtDispatch == 1)
      await ClipboardCleanup.awaitPendingCleanup()
      #expect(pb.string(forType: .string) == "the user's own clipboard")
    }
  }

  @Test("#3528: Paste Last with restore off writes the text unmarked even with the history setting on, because it stays")
  func pasteWithoutRestoreWritesUnmarked() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      var markedAtDispatch = true
      let result = ClipboardCleanup.manualPaste(
        text: "send the draft to Maya", restore: false, markTransient: true, on: pb
      ) {
        markedAtDispatch = self.carriesMarker(pb)
        return true
      }

      #expect(result == .dispatched)
      #expect(!markedAtDispatch)
      #expect(pb.string(forType: .string) == "send the draft to Maya")
      #expect(!carriesMarker(pb))
    }
  }

  @Test("#3528: Copy Last Dictation leaves the text unmarked")
  func copyLeavesTextUnmarked() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      #expect(ClipboardCleanup.manualCopy(text: "send the draft to Maya", on: pb) == .copied)
      #expect(pb.string(forType: .string) == "send the draft to Maya")
      #expect(!carriesMarker(pb))
    }
  }

  @Test("#3528: a paste whose Cmd+V cannot be posted leaves the text on the board unmarked")
  func dispatchFailureRewritesUnmarked() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      let result = ClipboardCleanup.manualPaste(
        text: "send the draft to Maya", restore: true, markTransient: true, on: pb
      ) { false }

      #expect(result == .dispatchFailed)
      #expect(pb.string(forType: .string) == "send the draft to Maya")
      #expect(!carriesMarker(pb))
      #expect(!ClipboardCleanup.hasPending)
    }
  }

  @Test("#3528: if the unmarked rewrite after a failed Cmd+V does not take, the user's clipboard comes back")
  func dispatchFailureRewriteRefusedRestoresClipboard() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      let result = ClipboardCleanup.manualPaste(
        text: "send the draft to Maya", restore: true, markTransient: true, on: pb,
        write: { text, board, kind in
          switch kind {
          case .temporary:
            return ClipboardCleanup.defaultManualWrite(text, board, kind)
          case .kept:
            board.clearContents()
            return board.changeCount
          }
        }
      ) { false }

      #expect(result == .writeFailed)
      #expect(pb.string(forType: .string) == "the user's own clipboard")
    }
  }

  // MARK: History setting OFF (#3672): the released write sequence

  @Test("#3672: Paste Last with the history setting off writes the text unmarked and restores unmarked")
  func settingOffWritesUnmarked() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      var markedAtDispatch = true
      let result = ClipboardCleanup.manualPaste(
        text: "send the draft to Maya", restore: true, markTransient: false, on: pb
      ) {
        markedAtDispatch = self.carriesMarker(pb)
        return true
      }

      #expect(result == .dispatched)
      #expect(!markedAtDispatch)
      await ClipboardCleanup.awaitPendingCleanup()
      #expect(pb.string(forType: .string) == "the user's own clipboard")
      #expect(!carriesMarker(pb))
    }
  }

  @Test("#3672: with the setting off a failed Cmd+V leaves the text where it was, with no extra write")
  func settingOffDispatchFailureWritesNothingMore() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      var writes = 0
      let result = ClipboardCleanup.manualPaste(
        text: "send the draft to Maya", restore: true, markTransient: false, on: pb,
        write: { text, board, kind in
          writes += 1
          return ClipboardCleanup.defaultManualWrite(text, board, kind)
        }
      ) { false }

      #expect(result == .dispatchFailed)
      #expect(writes == 1, "the released sequence is one write; the unmarked rewrite is only for a marked paste")
      #expect(pb.string(forType: .string) == "send the draft to Maya")
      #expect(!carriesMarker(pb))
    }
  }

  @Test("#3672: the restore keeps a marker the user's own clipboard already carried, in both states")
  func restoreKeepsAnExistingMarkerWhateverTheSetting() async {
    for setting in [false, true] {
      await withFastCleanup {
        let pb = NSPasteboard.withUniqueName()
        let item = NSPasteboardItem()
        item.setString("copied from a password manager", forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType(Self.transientMarker))
        pb.clearContents()
        pb.writeObjects([item])

        let result = ClipboardCleanup.manualPaste(
          text: "send the draft to Maya", restore: true, markTransient: setting, on: pb
        ) { true }

        #expect(result == .dispatched)
        await ClipboardCleanup.awaitPendingCleanup()
        #expect(pb.string(forType: .string) == "copied from a password manager")
        #expect(carriesMarker(pb), "an existing marker is part of the user's clipboard bytes")
      }
    }
  }

  @Test("A copy whose write does not take says so and puts the clipboard back")
  func copyWriteFailed() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      let result = ClipboardCleanup.manualCopy(
        text: "send the draft to Maya", on: pb, write: Self.refusedWrite)

      #expect(result == .writeFailed)
      #expect(!ClipboardCleanup.hasPending)
      #expect(pb.string(forType: .string) == "the user's own clipboard")
    }
  }

  @Test("A write that lands different text counts as not taken: exact match, not a prefix")
  func pasteWriteLandsOtherText() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      var dispatches = 0
      let result = ClipboardCleanup.manualPaste(
        text: "send the draft to Maya", restore: false, markTransient: false, on: pb,
        write: { text, board, _ in
          board.clearContents()
          board.setString(String(text.dropLast()), forType: .string)
          return board.changeCount
        }
      ) {
        dispatches += 1
        return true
      }

      #expect(result == .writeFailed)
      #expect(dispatches == 0)
      #expect(pb.string(forType: .string) == "the user's own clipboard")
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
        // #3135: the predicate Paste/Copy Last waits on says held exactly where the write refuses.
        #expect(ClipboardCleanup.isBoardHeldForManualWrite(pb), "legacyRewrite=\(legacyRewrite)")

        let paste = ClipboardCleanup.manualPaste(text: "reused", restore: true, markTransient: false, on: pb) {
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

  @Test("An idle board is not held (#3135)")
  func idleBoardIsNotHeld() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      #expect(!ClipboardCleanup.isBoardHeldForManualWrite(pb))
    }
  }

  @Test("A stale pending restore is dropped, so it cannot fire over the new text")
  func stalePendingIsCancelled() async {
    await withFastCleanup {
      let pb = board(holding: "the user's own clipboard")
      dictationJustPasted(on: pb)
      put("the board moved on", on: pb)  // the pending restore is now stale
      #expect(!ClipboardCleanup.isBoardHeldForManualWrite(pb), "a stale pending is not a hold")
      #expect(ClipboardCleanup.hasPending, "the probe cancels nothing; only the claim does")

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
      #expect(ClipboardCleanup.isBoardHeldForManualWrite(pb), "a takeover is a hold")

      let paste = ClipboardCleanup.manualPaste(text: "reused", restore: false, markTransient: false, on: pb) {
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
