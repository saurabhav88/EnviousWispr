import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import SwiftUI

// MARK: - NotificationStyle

/// Visual style for transient overlay notifications (errors and warnings).
enum NotificationStyle {
  case error
  case warning
  case interruption
  /// #1891: a user-setup advisory. Not a failure of ours, so it does not
  /// borrow the red failure treatment.
  case advisory

  var iconName: String {
    switch self {
    case .error: "xmark.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .interruption: ""  // uses distress lips, not SF Symbol
    case .advisory: "mic.slash.fill"
    }
  }

  var iconColor: Color {
    switch self {
    case .error: .red
    case .warning: .orange
    case .interruption: .red
    // #1891: deliberately not red. The glyph carries the meaning, so the state
    // is never signalled by colour alone (accessibility-macos.md
    // RULE: accessibility-macos-baseline, accessibility-noncolor-motion).
    case .advisory: .secondary
    }
  }

  var usesDistressLips: Bool {
    self == .interruption
  }
}

// MARK: - NotificationOverlayView

/// Compact notification overlay for errors (red), warnings (orange), and interruptions (distress lips).
struct NotificationOverlayView: View {
  let message: String
  let style: NotificationStyle
  /// #1891: only the advisory wraps and sizes to its content; every other notice
  /// is a short single line in a fixed 280x44 box.
  ///
  /// **Taken from the MODEL rather than re-derived from the style** (#2376 Phase
  /// 4, C3). `NotificationStyle` carried its own `isMultiline` computed from
  /// `self == .advisory` while `PillCatalog` set the same fact on every notice
  /// row, so one pill's wrapping was stated twice and the model's copy was
  /// ignored. The style's copy is deleted; this is the survivor.
  let isMultiline: Bool
  /// #2549: a second line under `message`, shown only in the "carries a
  /// button" shape below. `nil` for every existing single-string notice.
  var secondaryText: String?
  /// #2549: the one button a notification may carry (mirrors
  /// `AccessibilityToastView`'s "Grant"). `nil` for every notice that carries
  /// none today, so everything below is additive to the existing single-line
  /// and advisory shapes.
  var action: NoticeAction?
  var onAction: (() -> Void)?

  /// #2549: only a notice with a button gets the richer badge/stripe
  /// treatment. Every other `.notification` row (the compact 280x44 single
  /// line, the borderless advisory) renders exactly as it did before this
  /// case existed.
  private var isRich: Bool { action != nil }

  var body: some View {
    HStack(spacing: isRich ? 10 : 8) {
      if style.usesDistressLips {
        RainbowLipsIcon(size: 24, audioLevel: 0, isDistress: true)
      } else if isRich {
        Image(systemName: style.iconName)
          .foregroundStyle(.white)
          .font(.system(size: 18, weight: .semibold))
          .frame(width: 40, height: 40)
          .background(Circle().fill(style.iconColor.opacity(0.22)))
          .overlay(Circle().strokeBorder(style.iconColor.opacity(0.45), lineWidth: 1.5))
      } else {
        Image(systemName: style.iconName)
          .foregroundStyle(style.iconColor)
          .font(.system(size: 16))
      }

      if isRich {
        VStack(alignment: .leading, spacing: 2) {
          Text(message)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
          if let secondaryText {
            Text(secondaryText)
              .font(.system(size: 12))
              .foregroundStyle(.white.opacity(0.65))
          }
        }
      } else {
        Text(message)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(style.usesDistressLips ? Color.orange : .white)
          // #1891: `.lineLimit(1)` in a 280pt box truncates the advisory sentence
          // to a fragment. Only the advisory wraps; every other notice keeps its
          // single-line shape exactly as before.
          .lineLimit(isMultiline ? nil : 1)
          .fixedSize(horizontal: false, vertical: isMultiline)
          .multilineTextAlignment(.leading)
      }

      if let action, let onAction {
        Spacer(minLength: 8)
        Button(action: onAction) {
          HStack(spacing: 4) {
            Text(action.label)
            Image(systemName: "arrow.up.right")
              .font(.system(size: 10, weight: .bold))
          }
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .contentShape(Rectangle())
          .background(Capsule().fill(Color.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.spokenLabel)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .padding(.leading, isRich ? 6 : 0)
    .background(
      style.usesDistressLips
        ? AnyView(DistressCapsuleBackground()) : AnyView(OverlayCapsuleBackground())
    )
    .overlay(alignment: .leading) {
      if isRich {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(
            LinearGradient(
              colors: OverlayCapsuleBackground.rainbowColors, startPoint: .top,
              endPoint: .bottom)
          )
          .frame(width: 4)
          .padding(.vertical, 8)
          .padding(.leading, 8)
          .accessibilityHidden(true)
      }
    }
  }
}
