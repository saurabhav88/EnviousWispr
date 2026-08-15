import AppKit
import Testing

@testable import EnviousWisprAppKit

/// Pins the Top-position inherited-transition arithmetic (#1988 cloud review).
///
/// `RecordingOverlayPanel` is real-NSPanel/window-server UI code under the
/// established runtime-only exemption, so the geometry decision is extracted as
/// a pure function and pinned here rather than driven through a live panel.
///
/// The defect: the recording pill used to be a fixed 92pt frame, so preserving
/// its CENTER across the hand-off to the shorter polishing pill kept the visible
/// pill still (#1650). The #1988 preview made the recording frame content-sized
/// and anchored to its TOP edge while it grows, and center-preservation then
/// dropped the polishing pill by half the height it lost.
///
/// **Keep both sides of every `#expect` comparison the same type.** An `#expect`
/// whose two sides are `CGFloat` and `Double` (or an untyped integer expression)
/// reports a FAILURE on values that are genuinely equal: the macro re-evaluates
/// the expression without the implicit CGFloat/Double conversion the type
/// checker inserted. Measured while writing these tests — the same comparison
/// assigned to a local first was `true`, with identical bit patterns, while the
/// macro printed `(top → 0.0) == (originY → 0.0)` and recorded an issue. The
/// signature is a failure message whose two printed values look equal.
@Suite("RecordingOverlayPanel — inherited Top geometry (#1988)")
struct RecordingOverlayPanelInheritedGeometryTests {

  /// 44pt polishing pill inheriting from a five-line 150pt preview frame whose
  /// top edge sits at y = 950.
  private static let tallPreview = NSRect(x: 0, y: 800, width: 400, height: 150)

  @Test("a content-sized outgoing frame keeps its TOP edge, not its center")
  func contentSizedPreservesTopEdge() {
    let y = RecordingOverlayPanel.inheritedTopOriginY(
      inheritedFrame: Self.tallPreview, resolvedHeight: 44, outgoingWasContentSized: true)

    // Top edge 950 preserved: the incoming pill's own top edge lands there too.
    #expect(y + 44 == Self.tallPreview.maxY)
    #expect(y == 906)
  }

  @Test("center-preservation would drop the incoming pill by half the height lost")
  func centerRuleDropsATallPreview() {
    // Not a second assertion of the same thing: this pins the SIZE of the bug,
    // so a future change that silently reverts to the center rule fails with a
    // number that names the symptom rather than an opaque mismatch.
    let top = RecordingOverlayPanel.inheritedTopOriginY(
      inheritedFrame: Self.tallPreview, resolvedHeight: 44, outgoingWasContentSized: true)
    let center = RecordingOverlayPanel.inheritedTopOriginY(
      inheritedFrame: Self.tallPreview, resolvedHeight: 44, outgoingWasContentSized: false)

    // Both sides CGFloat deliberately — see the type note on the suite.
    let expectedDrop: CGFloat = (Self.tallPreview.height - 44) / 2
    #expect(top - center == expectedDrop)
    #expect(expectedDrop == 53)
  }

  @Test("a fixed outgoing frame still preserves its center (#1650 unchanged)")
  func fixedFramePreservesCenter() {
    // The shipped case #1650 fixed: the 92pt recording frame handing off to the
    // ~44pt polishing pill.
    let fixedRecording = NSRect(x: 0, y: 800, width: 185, height: 92)

    let y = RecordingOverlayPanel.inheritedTopOriginY(
      inheritedFrame: fixedRecording, resolvedHeight: 44, outgoingWasContentSized: false)

    #expect(y + 22 == fixedRecording.midY)
    #expect(y == 824)
  }

  @Test("the two rules agree exactly when the height does not change")
  func rulesAgreeAtEqualHeights() {
    // The claim that licenses leaving every other content-sized transition
    // alone: this branch can only change behaviour when a transition changes
    // height. Swept across heights and origins rather than asserted once,
    // because a single example would hold for the wrong reason.
    for height in stride(from: CGFloat(20), through: 200, by: 20) {
      for originY in stride(from: CGFloat(0), through: 900, by: 300) {
        let frame = NSRect(x: 0, y: originY, width: 300, height: height)
        let top = RecordingOverlayPanel.inheritedTopOriginY(
          inheritedFrame: frame, resolvedHeight: height, outgoingWasContentSized: true)
        let center = RecordingOverlayPanel.inheritedTopOriginY(
          inheritedFrame: frame, resolvedHeight: height, outgoingWasContentSized: false)

        #expect(top == center)
        #expect(top == originY, "an unchanged height must not move the pill at all")
      }
    }
  }

  @Test("a GROWING transition moves the pill up under the content-sized rule")
  func growingTransitionUnderContentSizedRule() {
    // The reverse direction, which the preview also produces: a one-line pill
    // inheriting into something taller must keep its top edge, so it grows
    // downward rather than straddling the old center.
    let shortPill = NSRect(x: 0, y: 900, width: 400, height: 44)

    let y = RecordingOverlayPanel.inheritedTopOriginY(
      inheritedFrame: shortPill, resolvedHeight: 150, outgoingWasContentSized: true)

    #expect(y + 150 == shortPill.maxY)
    #expect(y == 794)
  }
}
