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
/// **It renders the model it is handed and reads no copy of its own** (#2376
/// Phase 4, C3). It used to take only a closure and reach for
/// `DictationNarrator.recoveryTitle`, `.recoverySubtitle` and
/// `.recoveryAccessibilityLabel` itself, and to hardcode both button strings —
/// while `PillCatalog` was already carrying every one of those values on the
/// model. Two sources for one sentence, and the leaf's copy was the one on
/// screen.
struct RecoveryNoticeView: View {
  let title: String
  let subtitle: String?
  /// What VoiceOver reads for the pill as a whole. Distinct from `title` by
  /// design: the title carries an ellipsis and the spoken label does not.
  let accessibilityLabel: String
  let action: NoticeAction?
  let onAction: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.white)
        if let subtitle {
          Text(subtitle)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.7))
        }
      }
      Spacer(minLength: 8)
      if let action {
        Button(action: onAction) {
          Text(action.label)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(Capsule().fill(Color.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.spokenLabel)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(OverlayCapsuleBackground())
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityLabel)
  }
}
