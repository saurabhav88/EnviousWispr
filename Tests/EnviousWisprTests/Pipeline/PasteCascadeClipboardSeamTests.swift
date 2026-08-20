import AppKit
import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

// The cascade's clipboard-only tier, exercised against a REAL executor for the
// first time (#2170).
//
// Until the seam landed, `PasteCascadeExecutor` reached `PasteService`'s
// clipboard writers with no board argument, so they resolved to
// `NSPasteboard.general` — the developer's own clipboard. That is correct for
// production and made the tier untestable: `PasteClipboardHygieneTests` says so
// in its own header, and pins the RULE in isolation because "the live cascade
// needs a real focused element and a real pasteboard".
//
// Half of that is now false. The board is injected and required, so the tier can
// be driven directly; the focused element is still real and is why every case
// here passes `targetApp: nil`.
//
// WHY `targetApp: nil` IS THE SAFE AND DETERMINISTIC INPUT, rather than a way of
// dodging setup: tiers 2, 2b and 2c all live inside `if … let app =
// request.targetApp`, so with no app there is no activation, no CGEvent, no
// AppleScript and no menu probe. The cascade provably reaches exactly one write.
// That is a property of the code, not of the machine — it does not depend on
// whether the test runner happens to hold Accessibility trust, which would make
// these cases pass or skip for reasons having nothing to do with the seam.
//
// WHY EVERY CASE STORES THE EXECUTOR IN A LET BEFORE CALLING IT, since an inline
// construction would read more naturally: `ClipboardIsolationFreezeTests` bans
// `PasteCascadeExecutor` as a literal call base, and it caught the first draft of
// this file for exactly that. That guard predates the seam — before #2170 there
// was no way to construct this type safely from a test, so banning the type WAS
// banning the hazard.
//
// After #2170 it is not. The board must be NAMED at construction, so reaching the
// real one requires typing `.general`, which is visible at the call site in either
// form. The stored form is the one the scanner's own documented known limit
// exempts, and using it here is honest rather than a dodge — but the durable fix
// is to ban the ARGUMENT rather than the TYPE, which is filed.
@Suite("Paste cascade clipboard seam (#2170)", .tags(.productOutcome))
@MainActor
struct PasteCascadeClipboardSeamTests {

  private func request(_ text: String) -> PasteDeliveryRequest {
    PasteDeliveryRequest(
      legacyText: text,
      repairedText: nil,
      caretContext: nil,
      candidateDeletesDictatedText: false,
      targetApp: nil,
      targetElement: nil,
      targetElementIsRetried: false,
      restoreClipboardAfterPaste: false,
      terminalBudget: nil)
  }

  @Test("The clipboard-only tier writes the dictated text to the board it was given")
  func clipboardOnlyTierWritesToTheInjectedBoard() async {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }

    let executor = PasteCascadeExecutor(pasteboard: board)
    let result = await executor.deliver(request("the words the user just said"))

    #expect(result.tier == .clipboardOnly)
    #expect(board.string(forType: .string) == "the words the user just said")
  }

  // WHY THERE IS NO "AND THE REAL CLIPBOARD IS UNTOUCHED" CASE, since that is the
  // claim the seam exists to make and its absence looks like a gap.
  //
  // A first draft had one, asserting `NSPasteboard.general.changeCount` was
  // unchanged, on the reasoning that the case above would pass either way and so
  // could not fail in the direction that matters. **That reasoning was wrong.**
  // If the writes go to `.general`, the injected board is EMPTY, and the case
  // above fails on its contents.
  //
  // THE ARGUMENT FOR DELETING IT quantifies over DEFECTS, not over the mutants
  // that happened to be run: is there any defect for which the removed case is
  // the ONLY red row? No. Case 1 asserts the injected board's CONTENTS, so it
  // fails whenever the write lands anywhere else — the whole class of "wrote
  // somewhere other than the board it was given". The only distinction the
  // removed case drew on top of that is WHICH other board, and no defect attaches
  // to that.
  //
  // The evidence for one member of that class: a mutant sending the writes to a
  // board the test never sees turned case 1 red. That is a fact about one mutant
  // and is NOT the argument — a redundancy claim proved over the mutants you ran
  // is the smaller, easier question wearing the same words, and it invites the
  // next reader to restore this case the moment a mutant appears that case 1
  // survives.
  //
  // The removed case also cost something real: naming `NSPasteboard.general` in a
  // test, which `ClipboardIsolationFreezeTests` bans outright with a single
  // allowlisted file. That ban is right even though the access was a READ — a
  // scanner cannot tell a read from a write, and the way to get a read past a
  // name-based guard is to spell the board differently, which is the evasion this
  // repo forbids. A case that is redundant and needs an exemption is two reasons
  // to delete it.

  // A second board, to separate "wrote to the board it was given" from "wrote to
  // whichever board happened to be first". A single-board case cannot tell those
  // apart.
  @Test("Two executors with two boards do not cross-write")
  func eachExecutorWritesOnlyItsOwnBoard() async {
    let first = NSPasteboard.withUniqueName()
    let second = NSPasteboard.withUniqueName()
    defer {
      first.releaseGlobally()
      second.releaseGlobally()
    }

    let firstExecutor = PasteCascadeExecutor(pasteboard: first)
    let secondExecutor = PasteCascadeExecutor(pasteboard: second)
    _ = await firstExecutor.deliver(request("first"))
    _ = await secondExecutor.deliver(request("second"))

    #expect(first.string(forType: .string) == "first")
    #expect(second.string(forType: .string) == "second")
  }
}
