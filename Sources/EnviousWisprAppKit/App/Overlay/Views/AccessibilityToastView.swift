import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import SwiftUI

// MARK: - AccessibilityToastView

struct AccessibilityToastView: View {
  let onGrant: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "lock.shield.fill")
        .foregroundStyle(.orange)
        .font(.system(size: 16))
      Text(DictationNarrator.accessibilityToastText)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
      Spacer(minLength: 8)
      Button(action: onGrant) {
        Text("Grant")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 12)
          .padding(.vertical, 4)
          .background(Capsule().fill(Color.orange.opacity(0.85)))
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(OverlayCapsuleBackground())
  }
}
