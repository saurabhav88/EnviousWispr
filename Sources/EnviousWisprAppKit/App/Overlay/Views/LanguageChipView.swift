import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import SwiftUI

// MARK: - LanguageChipView

/// Passive language-detection chip surfaced post-dictation. Two visual states:
/// - `.askToLock`: "Detected <Lang>. Lock it?" with Lock + Dismiss buttons.
/// - `.educateAboutSettings`: "Detected <Lang>. This can be changed in Settings." with Dismiss only.
///
/// Auto-dismiss timer: 6 seconds. Paused while the cursor hovers over the chip.
/// Auto-dismiss callback is gated on a generation token (race protection).
struct LanguageChipView: View {
  let payload: LanguageChipPayload
  let onLock: () -> Void
  let onDismiss: () -> Void
  let onAutoDismiss: () -> Void

  @State private var hovering: Bool = false
  @State private var dismissTask: Task<Void, Never>?

  private static let autoDismissSeconds: Double = 6.0

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
        Button(action: {
          dismissTask?.cancel()
          onLock()
        }) {
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

      Button(action: {
        dismissTask?.cancel()
        onDismiss()
      }) {
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
    .onHover { isHovering in
      hovering = isHovering
      if isHovering {
        dismissTask?.cancel()
      } else {
        scheduleAutoDismiss()
      }
    }
    .onAppear {
      scheduleAutoDismiss()
    }
    .onDisappear {
      dismissTask?.cancel()
    }
  }

  private var promptText: String {
    switch payload.state {
    case .askToLock:
      return "Detected \(payload.displayName). Lock it?"
    case .educateAboutSettings:
      return "Detected \(payload.displayName). This can be changed in Settings."
    }
  }

  private func scheduleAutoDismiss() {
    dismissTask?.cancel()
    dismissTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(Self.autoDismissSeconds))
      guard !Task.isCancelled else { return }
      onAutoDismiss()
    }
  }
}
