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

  var body: some View {
    HStack(spacing: 8) {
      if style.usesDistressLips {
        RainbowLipsIcon(size: 24, audioLevel: 0, isDistress: true)
      } else {
        Image(systemName: style.iconName)
          .foregroundStyle(style.iconColor)
          .font(.system(size: 16))
      }

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
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(
      style.usesDistressLips
        ? AnyView(DistressCapsuleBackground()) : AnyView(OverlayCapsuleBackground()))
  }
}
