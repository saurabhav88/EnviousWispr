import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2817 item 8: Copy everything says "Copied" for a moment after a press.
///
/// The founder, 2026-09-13: pressing Copy everything "doesn't give any feedback that it
/// worked. We need a copied pill so folks know it is actually copied." The button's title
/// and symbol come from one pure rule, `copyButtonPresentation`, so the hold and the
/// revert-to-the-right-label behaviour are pinned here; the two-second timer and the
/// VoiceOver announcement are SwiftUI and AppKit calls the Live UAT row verifies.
@Suite("Transcribe a File Copied feedback (#2817 item 8)", .tags(.productOutcome))
struct TranscribeFileCopiedTests {
  let now = Date(timeIntervalSinceReferenceDate: 1_000)

  @Test("never pressed: the label and the copy symbol")
  func neverPressed() {
    let p = TranscribeFileExport.copyButtonPresentation(
      label: "Copy everything", copiedAt: nil, now: now)
    #expect(p.title == "Copy everything")
    #expect(p.systemImage == "doc.on.doc")
  }

  @Test("within the hold: Copied with a checkmark")
  func withinTheHold() {
    let p = TranscribeFileExport.copyButtonPresentation(
      label: "Copy everything", copiedAt: now.addingTimeInterval(-1), now: now)
    #expect(p.title == "Copied")
    #expect(p.systemImage == "checkmark")
  }

  @Test("after the hold: back to the label")
  func afterTheHold() {
    let p = TranscribeFileExport.copyButtonPresentation(
      label: "Copy everything", copiedAt: now.addingTimeInterval(-3), now: now)
    #expect(p.title == "Copy everything")
    #expect(p.systemImage == "doc.on.doc")
  }

  /// The hold is a NUMBER, not only a relationship: exactly at the boundary it has ended.
  @Test("the hold is two seconds, ending at the boundary")
  func theHoldIsTwoSeconds() {
    #expect(TranscribeFileExport.copiedHoldSeconds == 2)
    let justInside = TranscribeFileExport.copyButtonPresentation(
      label: "Copy everything", copiedAt: now.addingTimeInterval(-1.99), now: now)
    let atBoundary = TranscribeFileExport.copyButtonPresentation(
      label: "Copy everything", copiedAt: now.addingTimeInterval(-2), now: now)
    #expect(justInside.title == "Copied")
    #expect(atBoundary.title == "Copy everything")
  }

  /// Marked up relabels the button "Copy cleaned" (it exports the cleaned text); the
  /// revert must return THAT label, not "Copy everything".
  @Test("the revert returns the label the view is using")
  func revertReturnsTheCurrentLabel() {
    let p = TranscribeFileExport.copyButtonPresentation(
      label: "Copy cleaned", copiedAt: now.addingTimeInterval(-3), now: now)
    #expect(p.title == "Copy cleaned")
  }

  /// A press stamped in the future (a clock change) is not "within the hold".
  @Test("a press in the future does not read as Copied")
  func futurePressIsNotCopied() {
    let p = TranscribeFileExport.copyButtonPresentation(
      label: "Copy everything", copiedAt: now.addingTimeInterval(10), now: now)
    #expect(p.title == "Copy everything")
  }
}

