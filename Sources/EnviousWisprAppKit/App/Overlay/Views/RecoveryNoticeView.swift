import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import SwiftUI

// MARK: - RecoveryNoticeView (#1063 PR2)

/// The "recovering your last recording" pill shown when a record-press lands
/// while the crash-recovery limb holds the shared engine. Mirrors the cold-start
/// notice shape (spinner + plain-English copy) and adds a Discard affordance for
/// "I don't want to wait." Icon + text (never color-only); the Discard button is
/// keyboard-activatable for VoiceOver.
struct RecoveryNoticeView: View {
  let onDiscard: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(DictationNarrator.recoveryTitle)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.white)
        Text(DictationNarrator.recoverySubtitle)
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(0.7))
      }
      Spacer(minLength: 8)
      Button(action: onDiscard) {
        Text("Discard")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 12)
          .padding(.vertical, 4)
          .contentShape(Rectangle())
          .background(Capsule().fill(Color.white.opacity(0.18)))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Discard recovering recording")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(OverlayCapsuleBackground())
    .accessibilityElement(children: .contain)
    .accessibilityLabel(DictationNarrator.recoveryAccessibilityLabel)
  }
}
