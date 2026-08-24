import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import SwiftUI

// MARK: - PolishingOverlayView

/// Compact polishing indicator overlay shown during LLM processing.
struct PolishingOverlayView: View {
  var label: String

  var body: some View {
    HStack(spacing: 10) {
      // Spinning spectrum wheel icon — polishing/processing state
      SpectrumWheelIcon(size: 24)

      // #1064: single line that hugs its content. The panel is sized to this
      // view's fittingSize (showPanel `fitToContent`), so short labels
      // ("Polishing...", "Transcribing...") stay compact and the long 60-minute
      // cap-end message gets exactly the width it needs — never clipped, never
      // stranded in empty space (the #1060 fixed-frame regression).
      Text(label)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(OverlayCapsuleBackground())
  }
}
