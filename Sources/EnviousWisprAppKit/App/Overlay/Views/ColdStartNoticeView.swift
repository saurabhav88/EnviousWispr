import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import SwiftUI

// MARK: - ColdStartNoticeView

/// Cold-boot warm-up pill (#879). Two uses, driven by `icon`:
/// - `.spinner` — "getting ready" while the engine warms after a cold boot.
/// - `.ready` — the "ready, press to dictate" announcement.
///
/// Both convey state with a shape (spinning wheel / checkmark) plus text, never
/// color alone (accessibility-noncolor). An optional `subtitle` renders a
/// dimmer secondary line (e.g. which engine is warming).
struct ColdStartNoticeView: View {
  enum Icon {
    case spinner
    case ready
  }

  let title: String
  var subtitle: String?
  let icon: Icon

  var body: some View {
    HStack(spacing: 10) {
      switch icon {
      case .spinner:
        SpectrumWheelIcon(size: 24)
      case .ready:
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(Color(red: 0.2, green: 0.82, blue: 0.45))
          .font(.system(size: 18))
          .accessibilityHidden(true)
      }

      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.white)
          .lineLimit(1)
        if let subtitle {
          Text(subtitle)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.white.opacity(0.65))
            .lineLimit(1)
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(OverlayCapsuleBackground())
  }
}
