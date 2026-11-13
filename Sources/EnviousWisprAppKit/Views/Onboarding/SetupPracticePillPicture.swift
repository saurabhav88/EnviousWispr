import EnviousWisprCore
import SwiftUI

/// The approved pill views in standalone pictures. In the app the real overlay displays the take.
struct SetupPracticePillPicture: View {
  let state: SetupPracticeState

  var body: some View {
    Group {
      switch state {
      case .listening(let handsFree):
        RecordingOverlayView(
          audioLevelProvider: { 0 },
          livePreviewProvider: { .off },
          onContentHeightChange: { _ in },
          chrome: RecordingPillDesign.classic.chrome,
          isLocked: handsFree, noticeText: nil, cadence: .still, animatesGlow: false)
      case .transcribing:
        PolishingOverlayView(label: String(localized: "Transcribing…"))
      case .polishing:
        PolishingOverlayView(label: String(localized: "Polishing…"))
      default:
        EmptyView()
      }
    }
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}
