import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import SwiftUI

// MARK: - AccessibilityToastView

/// **It renders the model it is handed and reads no copy of its own** (#2376
/// Phase 4, C3). It used to take only a closure, read
/// `DictationNarrator.accessibilityToastText` itself and hardcode its button
/// label, both of which `PillCatalog` already carried on the model.
struct AccessibilityToastView: View {
  let text: String
  let action: NoticeAction?
  let onAction: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "lock.shield.fill")
        .foregroundStyle(.orange)
        .font(.system(size: 16))
      Text(text)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
      Spacer(minLength: 8)
      if let action {
        Button(action: onAction) {
          Text(action.label)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(Capsule().fill(Color.orange.opacity(0.85)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.spokenLabel)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(OverlayCapsuleBackground())
  }
}
