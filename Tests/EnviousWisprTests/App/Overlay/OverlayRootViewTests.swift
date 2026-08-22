import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #2292 chunk C4c. The one place a decision becomes a picture.
///
/// **Product Outcome, narrowly.** The kind-to-view switch is exhaustive by
/// compiler, so a MISSING case cannot ship; what can ship is a WRONG one, and
/// that is what this pins. A cold-start pill drawing the ready mark, or a
/// user-setup advisory painted with the red error mark, both look entirely
/// correct and say the opposite of the truth.
///
/// Known limit, stated rather than discovered later: SwiftUI view identity is
/// not inspectable without rendering, so `kind -> leaf view` is verified by the
/// compiler's exhaustiveness plus §11.1 Live UAT. What IS testable is the
/// severity mapping, because it crosses two enums and neither the compiler nor
/// a glance can tell you it is right.
@MainActor
@Suite(.tags(.productOutcome))
struct OverlayRootViewTests {

  /// #1891: `.advisory` must NOT paint as `.error`. The error style carries a
  /// red mark, a 3-second dwell too short to read the sentence, and an "Error"
  /// heading — every one of which tells the user our software failed when the
  /// microphone was muted.
  @Test(
    "each severity paints as the style its shipped pill used",
    arguments: [
      (NoticeModel.Severity.error, NotificationStyle.error),
      (.warning, .warning),
      (.distress, .interruption),
      (.advisory, .advisory),
    ])
  func severityMapsToItsShippedStyle(pair: (NoticeModel.Severity, NotificationStyle)) {
    #expect(OverlayRootView.style(for: pair.0) == pair.1)
  }

  /// The paired case for the one severity with no style of its own. It maps to
  /// `.warning` rather than falling through a `default:` — a default here would
  /// hide a missing case instead of failing it, and nothing currently produces
  /// `.neutral` at all.
  @Test("the styleless severity has an explicit destination")
  func neutralHasAnExplicitDestination() {
    #expect(OverlayRootView.style(for: .neutral) == .warning)
  }
}
