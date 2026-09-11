import AppKit
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #2772: the polish grid steps down at narrow widths instead of squeezing six cards until
/// their words clip. The count was a constant six while its comment promised a fallback;
/// at the 750-point minimum window every title and subtitle clipped. Found by the cloud
/// review of PR #2786.
///
/// **What fails when this fails is a person who cannot read the engine names.**
@MainActor
@Suite("Transcribe a File polish grid (#2772)", .tags(.productOutcome))
struct TranscribeFilePolishGridTests {

  init() { _ = NSApplication.shared }

  /// The design's steps and nothing between them.
  @Test("six across at the design width, three when six would squeeze, two below that")
  func theGridStepsSixThreeTwo() {
    let min = TranscribeFileView.polishCardMinimumWidth
    let gap = TranscribeFileView.polishGridSpacing
    // Before the first layout the width is zero; six, so the first frame is the design.
    #expect(TranscribeFileView.polishColumns(fitting: 0) == 6)
    // The exact boundary, both sides: six cards at the minimum plus five gaps.
    let sixFit = min * 6 + gap * 5
    #expect(TranscribeFileView.polishColumns(fitting: sixFit) == 6)
    #expect(TranscribeFileView.polishColumns(fitting: sixFit - 1) == 3)
    let threeFit = min * 3 + gap * 2
    #expect(TranscribeFileView.polishColumns(fitting: threeFit) == 3)
    #expect(TranscribeFileView.polishColumns(fitting: threeFit - 1) == 2)
    // The pane at the 750-point minimum window is a few hundred points narrower than the
    // window; it must land on three, never six.
    #expect(TranscribeFileView.polishColumns(fitting: 520) == 3)
  }

  /// The constant against the real badge, measured in this process. Title and subtitle
  /// wrap, so the badge is the one thing in a card that sets its floor.
  @Test("the minimum card width holds the Recommended badge inside the card's padding")
  func theMinimumHoldsTheBadge() {
    let host = NSHostingView(rootView: TranscribeFileView.wizardBadge("Recommended"))
    let badge = host.fittingSize.width
    #expect(badge > 0, "the harness returned nothing, which is not a pass")
    let padding: CGFloat = 12 * 2
    #expect(
      badge + padding <= TranscribeFileView.polishCardMinimumWidth,
      "the badge measures \(badge); the card minimum leaves \(TranscribeFileView.polishCardMinimumWidth - padding) for it")
  }
}
