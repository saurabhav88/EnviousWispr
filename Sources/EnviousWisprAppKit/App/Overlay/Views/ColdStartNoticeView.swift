import AppKit
import SwiftUI

// MARK: - ColdStartNoticeView

/// Cold-boot warm-up pill (#879). Uses, driven by `icon`:
/// - `.spinner` — "getting ready" while the engine warms after a cold boot.
/// - `.ready` — the "ready, press to dictate" announcement.
/// - `.download` — #3546 A3: the Parakeet Ultra download, with an optional `progress` line.
///
/// Both convey state with a shape (spinning wheel / checkmark) plus text, never
/// color alone (accessibility-noncolor). An optional `subtitle` renders a
/// dimmer secondary line (e.g. which engine is warming).
struct ColdStartNoticeView: View {
  enum Icon {
    case spinner
    case ready
    case download
  }

  let title: String
  var subtitle: String?
  let icon: Icon
  /// 0...1; when set, a thin progress line along the pill's bottom edge (#3546 A3 mock).
  var progress: Double? = nil

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
      case .download:
        Image(systemName: "arrow.down.circle.fill")
          .foregroundStyle(Color(red: 0.118, green: 0.565, blue: 1.0))
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
    // The progress line sits in the bottom padding and adds no height: any line laid out
    // under the subtitle made the pill taller than its reserved 56 pt, and it rendered cut
    // off at the screen's bottom edge (#3546 live UAT, 2026-10-12).
    .overlay(alignment: .bottom) {
      if let progress {
        Capsule()
          .fill(.white.opacity(0.15))
          .frame(height: 2)
          .overlay(alignment: .leading) {
            Capsule()
              .fill(Color(red: 0.118, green: 0.565, blue: 1.0))
              .scaleEffect(x: min(max(progress, 0), 1), y: 1, anchor: .leading)
          }
          .padding(.horizontal, 18)
          .padding(.bottom, 4)
          .accessibilityHidden(true)
      }
    }
    .background(OverlayCapsuleBackground())
  }
}
