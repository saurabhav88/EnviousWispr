import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import SwiftUI

// MARK: - LanguageChipView

/// Passive language-detection chip surfaced post-dictation. Two visual states:
/// - `.askToLock`: "Detected <Lang>. Lock it?" with Lock + Dismiss buttons.
/// - `.educateAboutSettings`: "Detected <Lang>. This can be changed in Settings." with Dismiss only.
///
/// **It owns no clock and no hover state** (#2377 Phase 5, C3). Dismissal at six
/// seconds, and the pause while the cursor is over it, are the director's:
/// `PillCatalog` gives this chip `.after(seconds: 6, pausesOnHover: true)`,
/// `OverlayRootView` forwards hover as an event, and `PillExpiryClock` is the one
/// thing that arms, cancels and re-arms. This view renders and reports presses.
struct LanguageChipView: View {
  let payload: LanguageChipPayload
  let onLock: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "globe")
        .foregroundStyle(.white.opacity(0.85))
        .font(.system(size: 16))

      Text(promptText)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 6)

      if payload.state == .askToLock {
        Button(action: onLock) {
          Text("Lock")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(Capsule().fill(Color.blue.opacity(0.85)))
        }
        .buttonStyle(.plain)
      }

      Button(action: onDismiss) {
        Text("Dismiss")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.white.opacity(0.9))
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
          .contentShape(Rectangle())
          .background(Capsule().fill(Color.white.opacity(0.15)))
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(OverlayCapsuleBackground())
  }

  private var promptText: String {
    switch payload.state {
    case .askToLock:
      return "Detected \(payload.displayName). Lock it?"
    case .educateAboutSettings:
      return "Detected \(payload.displayName). This can be changed in Settings."
    }
  }
}
