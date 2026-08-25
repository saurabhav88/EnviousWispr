import AppKit
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// What each recording design tells the leaf to draw (#2376 Phase 4, C2).
///
/// **The first assertion in this repo that can fail when two designs are painted
/// the same.** Before `RecordingPillChrome` the pill's appearance was a boolean
/// read eighteen times inside one view body, so "these two designs look
/// different" was not a question any test could ask — it was a property of
/// scattered ternaries. As a value it is comparable, and comparing it is what
/// this suite does.
///
/// **A Drift Guard.** When a row here fails the user sees nothing yet: it says we
/// changed our own appearance table. Whether the table reached the pixels is a
/// Live UAT row, because `fittingSize` is blind to icon, colour and corner shape.
@MainActor
@Suite(.tags(.driftGuard))
struct RecordingPillChromeTests {

  /// **Generated over the cross-product rather than hand-picked**, so a design
  /// added later is swept with no edit here. Hand-written pairs cover the cells
  /// the author thought of, which is the same blind spot the check exists to
  /// cover for.
  @Test("no two designs are painted the same")
  func chromeIsInjectiveOverDesigns() {
    let designs = RecordingPillDesign.allCases
    for a in designs {
      for b in designs where a != b {
        #expect(
          a.chrome != b.chrome,
          """
          \(a) and \(b) carry identical chrome, so one of them renders as the \
          other. That is this phase's named regression — correct model data with \
          the wrong visual treatment — and it is the one thing this value exists \
          to make observable.
          """)
      }
    }
  }

  /// The paired case that stops the sweep above passing vacuously: a design must
  /// equal ITSELF, or `Equatable` is comparing nothing and every pair differs.
  @Test("chrome is stable and self-equal", arguments: RecordingPillDesign.allCases)
  func chromeIsSelfEqual(design: RecordingPillDesign) {
    #expect(
      design.chrome == design.chrome,
      "\(design)'s chrome does not equal itself, so the injectivity sweep proves nothing")
  }

  /// **Pinned per design, read off the base revision's own branches.**
  ///
  /// `.classic` was the `false` side of every `usesPreviewLayout` read and
  /// `.readingWell` the `true` side. A wrong value here is a wrong pill, and the
  /// C1 frozen rows are what say these values reached the render — this suite
  /// says WHICH values, that one says they draw the same as before.
  @Test("the classic capsule's chrome is what the boolean's false side said")
  func classicChromeIsPinned() {
    let chrome = RecordingPillDesign.classic.chrome
    #expect(chrome.header == .mark)
    #expect(chrome.stackSpacing == 6)
    #expect(chrome.rootInsets == EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
    #expect(chrome.cornerStyle == .capsule)
    #expect(chrome.levelAnimation == .capsuleEaseOut)
    #expect(chrome.showsListeningSentence)
    #expect(chrome.noticeInk == .capsuleWhite)
    #expect(chrome.noticeMaxWidth == 170)
    #expect(chrome.noticeInsets == EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    #expect(chrome.wellInsets == EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    #expect(chrome.wellInk == .capsuleWhite)
    #expect(chrome.fadesWhenWellIsFull == false)
    #expect(chrome.isContentSizedVertically == false)
  }

  @Test("the reading well's chrome is what the boolean's true side said")
  func readingWellChromeIsPinned() {
    let chrome = RecordingPillDesign.readingWell.chrome
    #expect(chrome.header == .meterStrip)
    #expect(chrome.stackSpacing == 0)
    #expect(chrome.rootInsets == EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    #expect(chrome.cornerStyle == .rounded)
    #expect(chrome.levelAnimation == .none)
    #expect(chrome.showsListeningSentence == false)
    #expect(chrome.noticeInk == .previewPalette)
    #expect(chrome.noticeMaxWidth == nil)
    #expect(chrome.noticeInsets == EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
    #expect(chrome.wellInsets == EdgeInsets(top: 12, leading: 16, bottom: 15, trailing: 16))
    #expect(chrome.wellInk == .previewPalette)
    #expect(chrome.fadesWhenWellIsFull)
    #expect(chrome.isContentSizedVertically)
  }

  /// **The one field that must never be typed, only derived.** A design that
  /// reserves a fixed box is not content-sized, by definition; two independent
  /// answers to that is how a pill comes to be measured inside the panel being
  /// sized from that measurement, which is the loop #2201 settled.
  @Test(
    "content sizing follows the design's reserved height",
    arguments: RecordingPillDesign.allCases)
  func contentSizingIsDerivedFromTheReservedHeight(design: RecordingPillDesign) {
    #expect(
      design.chrome.isContentSizedVertically == (design.reservedHeight == nil),
      """
      \(design) reserves \(String(describing: design.reservedHeight)) and reports \
      isContentSizedVertically = \(design.chrome.isContentSizedVertically). These are \
      one fact; if they can disagree, one of them is typed rather than derived.
      """)
  }

  /// The two inks must resolve to different colours, or the enum is a label with
  /// no consequence and every notice paints the same whatever a design asks for.
  @Test("the two inks are actually different paint")
  func inksResolveDifferently() {
    #expect(PillInk.capsuleWhite.notice != PillInk.previewPalette.notice)
    for dimmed in [true, false] {
      #expect(
        PillInk.capsuleWhite.well(dimmed: dimmed) != PillInk.previewPalette.well(dimmed: dimmed),
        "the two inks resolve to one colour at dimmed=\(dimmed)")
    }
  }

  /// And the dimmed variant must differ from the normal one within an ink, or
  /// "listening" and real words are painted identically.
  @Test("each ink dims", arguments: [PillInk.capsuleWhite, .previewPalette])
  func eachInkDims(ink: PillInk) {
    #expect(ink.well(dimmed: true) != ink.well(dimmed: false), "\(ink) does not dim")
  }

  /// The animation case must resolve to an actual absence and an actual
  /// animation, or #2201's whole fix is a renamed constant.
  @Test("the level animation cases resolve to what they promise")
  func levelAnimationResolves() {
    #expect(PillLevelAnimation.none.resolved == nil)
    #expect(PillLevelAnimation.capsuleEaseOut.resolved != nil)
  }

  /// **The RESOLVED values, not just the cases.** Every assertion above compares
  /// one case to another, which stays green if a case is quietly repointed at a
  /// different colour or duration — the enum would still be injective and the
  /// chrome table would still read correctly while the pill changed. These pin
  /// what the cases actually produce, at the shipped values.
  ///
  /// `Color.white.opacity(0.95)` is also counted by
  /// `CapsuleBackgroundFreezeTests.frozenCapsuleLiterals`, which is a tripwire on
  /// the FILE. This is the same fact asserted on the VALUE, and the two fail for
  /// different reasons: that one catches the literal being edited, this one
  /// catches the ink being pointed somewhere else.
  @Test("the shipped ink and animation values are what they have always been")
  func resolvedValuesAreShipped() {
    #expect(PillInk.capsuleWhite.notice == Color.white.opacity(0.95))
    #expect(PillInk.capsuleWhite.well(dimmed: false) == .white.opacity(0.92))
    #expect(PillInk.capsuleWhite.well(dimmed: true) == .white.opacity(0.5))
    #expect(PillInk.previewPalette.notice == PreviewPillPalette.notice)
    #expect(PillInk.previewPalette.well(dimmed: false) == PreviewPillPalette.text)
    #expect(PillInk.previewPalette.well(dimmed: true) == PreviewPillPalette.textDimmed)
    #expect(PillLevelAnimation.capsuleEaseOut.resolved == .easeOut(duration: 0.08))
  }
}
