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

  var autoDismissSeconds: Double {
    switch self {
    case .error: 3.0
    case .warning: 2.5
    case .interruption: 2.0
    // #1891: the advisory sentence is ~23 words. At roughly 200 wpm that needs
    // about 7 seconds to read, so the 3.0s error dwell would show a message
    // the user physically cannot finish. 8s, confirmed by reading UAT.
    case .advisory: 8.0
    }
  }

  /// #1891: only the advisory wraps and sizes to its content. Every other
  /// notice is a short single line in a fixed 280x44 box and stays that way.
  var isMultiline: Bool {
    self == .advisory
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
        .lineLimit(style.isMultiline ? nil : 1)
        .fixedSize(horizontal: false, vertical: style.isMultiline)
        .multilineTextAlignment(.leading)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(
      style.usesDistressLips
        ? AnyView(DistressCapsuleBackground()) : AnyView(OverlayCapsuleBackground()))
  }
}
