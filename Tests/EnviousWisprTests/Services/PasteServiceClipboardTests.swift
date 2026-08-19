import AppKit
import Foundation
import Testing

@testable import EnviousWisprServices

/// Real-AppKit coverage for `PasteService`'s snapshot / restore / change-count
/// guard, run against an ISOLATED pasteboard rather than the user's.
///
/// #2146: these tests used to drive the process-global board — the developer's
/// own clipboard — and put it back only when `restoreClipboard`'s guard
/// allowed it. `.serialized` orders this suite's own tests and nothing else, so a
/// sibling suite running in parallel advanced the count, the guard correctly
/// declined, and the fixture text stayed on the founder's clipboard.
///
/// The board is still a REAL `NSPasteboard` with real `changeCount` semantics, so
/// nothing is faked and no assertion is weakened; it simply is not the one the
/// user pastes from. `.serialized` is retained because these tests are cheap and
/// ordering them costs nothing, but it is no longer load-bearing.
@MainActor
@Suite("PasteService clipboard helpers", .serialized)
struct PasteServiceClipboardTests {

  /// Runs `body` against a private, system-named pasteboard.
  ///
  /// `withUniqueName()` carries a system uniqueness guarantee; a hand-rolled UUID
  /// name would only make collision unlikely. Released in a same-scope `defer`,
  /// which covers the throwing path too. Per TEST, not per suite: Swift Testing
  /// builds a fresh suite value for each instance test, so there is no suite-wide
  /// teardown to hang this on.
  ///
  /// Known limit, stated rather than hidden: an abrupt process crash bypasses
  /// `releaseGlobally()` and can leave a pasteboard-server resource behind until
  /// the server resets. Uniqueness prevents that from colliding with anything.
  private func withPrivatePasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
    let pasteboard = NSPasteboard.withUniqueName()
    defer {
      pasteboard.clearContents()
      pasteboard.releaseGlobally()
    }
    try body(pasteboard)
  }

  @Test("copyToClipboardReturningChangeCount writes string and returns the new changeCount")
  func copyToClipboardReturningChangeCountWritesString() {
    withPrivatePasteboard { pasteboard in
      let text = "dictation-\(UUID().uuidString)"
      let returnedChangeCount = PasteService.copyToClipboardReturningChangeCount(
        text, to: pasteboard)

      #expect(pasteboard.string(forType: .string) == text)
      #expect(pasteboard.changeCount == returnedChangeCount)
    }
  }

  @Test("restoreClipboard restores a saved snapshot when changeCount still matches our paste write")
  func restoreClipboardRestoresSavedSnapshot() {
    withPrivatePasteboard { pasteboard in
      let originalText = "before-\(UUID().uuidString)"
      Self.setClipboardString(originalText, on: pasteboard)
      let snapshot = PasteService.saveClipboard(from: pasteboard)

      let pastedText = "after-\(UUID().uuidString)"
      let changeCountAfterPaste = PasteService.copyToClipboardReturningChangeCount(
        pastedText, to: pasteboard)
      #expect(pasteboard.string(forType: .string) == pastedText)

      PasteService.restoreClipboard(
        snapshot, changeCountAfterPaste: changeCountAfterPaste, on: pasteboard)

      #expect(pasteboard.string(forType: .string) == originalText)
    }
  }

  @Test("#729: restoreClipboard restores an empty prior clipboard to empty (clears our paste text)")
  func restoreClipboardRestoresEmptyToEmpty() {
    withPrivatePasteboard { pasteboard in
      // Prior clipboard is empty.
      pasteboard.clearContents()
      let emptySnapshot = PasteService.saveClipboard(from: pasteboard)
      #expect(emptySnapshot.items.isEmpty)

      // Our paste writes text onto the board.
      let pastedText = "dictated-\(UUID().uuidString)"
      let changeCountAfterPaste = PasteService.copyToClipboardReturningChangeCount(
        pastedText, to: pasteboard)
      #expect(pasteboard.string(forType: .string) == pastedText)

      PasteService.restoreClipboard(
        emptySnapshot, changeCountAfterPaste: changeCountAfterPaste, on: pasteboard)

      // The board must be cleared back to empty, not left holding our paste text.
      #expect(pasteboard.string(forType: .string) == nil)
    }
  }

  @Test("restoreClipboard skips restore when clipboard changed after our paste write")
  func restoreClipboardSkipsWhenClipboardAdvanced() {
    withPrivatePasteboard { pasteboard in
      let originalText = "before-\(UUID().uuidString)"
      Self.setClipboardString(originalText, on: pasteboard)
      let snapshot = PasteService.saveClipboard(from: pasteboard)

      let pastedText = "after-\(UUID().uuidString)"
      let changeCountAfterPaste = PasteService.copyToClipboardReturningChangeCount(
        pastedText, to: pasteboard)
      #expect(pasteboard.string(forType: .string) == pastedText)

      let userClipboardText = "user-followup-\(UUID().uuidString)"
      Self.setClipboardString(userClipboardText, on: pasteboard)

      PasteService.restoreClipboard(
        snapshot, changeCountAfterPaste: changeCountAfterPaste, on: pasteboard)

      #expect(pasteboard.string(forType: .string) == userClipboardText)
    }
  }

  /// #2146 review gap: `saveClipboard`/`restoreClipboard` have always round-tripped
  /// MULTIPLE items and MULTIPLE representations per item, and nothing asserted it —
  /// every prior case used a single string or an empty board. A user copying rich
  /// text or a file and then dictating depends on this path, so a silent regression
  /// here would lose real clipboard content with no test going red.
  @Test("snapshot and restore preserve multiple items and representations")
  func restoreClipboardPreservesMultipleItemsAndTypes() throws {
    try withPrivatePasteboard { pasteboard in
      let first = NSPasteboardItem()
      first.setData(Data("plain".utf8), forType: .string)
      first.setData(Data(#"{\rtf1 rich}"#.utf8), forType: .rtf)

      let second = NSPasteboardItem()
      second.setData(Data("second".utf8), forType: .string)

      pasteboard.clearContents()
      #expect(pasteboard.writeObjects([first, second]))

      let snapshot = PasteService.saveClipboard(from: pasteboard)
      let changeCountAfterPaste = PasteService.copyToClipboardReturningChangeCount(
        "replacement", to: pasteboard)

      PasteService.restoreClipboard(
        snapshot, changeCountAfterPaste: changeCountAfterPaste, on: pasteboard)

      let restored = try #require(pasteboard.pasteboardItems)
      #expect(restored.count == 2)
      #expect(restored[0].data(forType: .string) == Data("plain".utf8))
      #expect(restored[0].data(forType: .rtf) == Data(#"{\rtf1 rich}"#.utf8))
      #expect(restored[1].data(forType: .string) == Data("second".utf8))
    }
  }

  private static func setClipboardString(_ text: String, on pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }
}

/// Observability Contract: `restoreClipboard`'s return value is what the cleanup
/// log line reports. When it lies, a diagnosis reads the wrong outcome.
@Suite("restoreClipboard reports whether it applied (#2197)", .tags(.observabilityContract))
struct RestoreClipboardResultTests {

  @Test("True when the board was ours to write")
  func trueWhenApplied() {
    let pb = NSPasteboard.withUniqueName()
    PasteService.copyToClipboard("user clipboard", to: pb)
    let snapshot = PasteService.saveClipboard(from: pb)
    PasteService.copyToClipboard("our payload", to: pb)
    #expect(
      PasteService.restoreClipboard(snapshot, changeCountAfterPaste: pb.changeCount, on: pb)
        == true)
  }

  @Test("False when the guard declined")
  func falseWhenDeclined() {
    let pb = NSPasteboard.withUniqueName()
    PasteService.copyToClipboard("user clipboard", to: pb)
    let snapshot = PasteService.saveClipboard(from: pb)
    PasteService.copyToClipboard("our payload", to: pb)
    let stale = pb.changeCount
    PasteService.copyToClipboard("someone else", to: pb)
    #expect(PasteService.restoreClipboard(snapshot, changeCountAfterPaste: stale, on: pb) == false)
  }

  @Test("True for an empty prior clipboard, which is restored by clearing")
  func trueWhenPriorWasEmpty() {
    let pb = NSPasteboard.withUniqueName()
    let snapshot = PasteService.saveClipboard(from: pb)
    PasteService.copyToClipboard("our payload", to: pb)
    #expect(
      PasteService.restoreClipboard(snapshot, changeCountAfterPaste: pb.changeCount, on: pb)
        == true)
    #expect(pb.string(forType: .string) == nil)
  }
}
