import EnviousWisprServices
import SwiftUI

struct SetupShortcutKeycap: View {
  let display: String
  let isCapturing: Bool
  let isDown: Bool

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: DesignRadius.xxl, style: .continuous)
  }

  var body: some View {
    legend
      .foregroundStyle(Color.obAccent)
      .padding(.horizontal, DesignSpacing.xl)
      .frame(width: ShortcutLayout.mainWidth, height: ShortcutLayout.mainHeight)
      .background { face }
      .overlay {
        shape.strokeBorder(
          isCapturing || isDown ? Color.obAccent : Color.firstRunAccentSoft,
          lineWidth: DesignSpacing.xxs
        ).allowsHitTesting(false)
      }
      .shadow(
        color: Color.obAccent.opacity(isCapturing || isDown ? 0 : 0.12),
        radius: DesignRadius.lg, y: 3
      )
      .contentShape(shape)
      .overlay(alignment: .topTrailing) {
        if !isCapturing { changeBadge }
      }
  }

  @ViewBuilder
  private var legend: some View {
    if isCapturing {
      HStack(spacing: DesignSpacing.sm) {
        Text("Press a key").font(.firstRunLabel)
        Capsule().fill(Color.obAccent)
          .frame(width: DesignSpacing.xxs, height: ShortcutLayout.caretHeight)
      }
    } else {
      Text(verbatim: display)
        .font(.firstRunDisplay)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }
  }

  @ViewBuilder
  private var face: some View {
    if isCapturing {
      shape.fill(Color.firstRunAccentSoft)
    } else {
      shape.fill(ShortcutLayout.keyFace)
    }
  }

  private var changeBadge: some View {
    let badge = Text("CHANGE")
      .font(.firstRunEyebrow)
      .tracking(CGFloat(0.8))
      .foregroundStyle(Color.firstRunOnAccent)
      .padding(.horizontal, DesignSpacing.md)
      .frame(height: SetupMetrics.tagHeight)
      .background { Capsule().fill(Color.obAccent) }
    return
      badge
      .offset(x: DesignSpacing.xl, y: -DesignSpacing.xs)
      .accessibilityHidden(true)
      .allowsHitTesting(false)
  }
}

enum ShortcutLayout {
  static let cardWidth: CGFloat = 380
  static let cardInset: CGFloat = 20
  static let mainWidth: CGFloat = 168
  static let mainHeight: CGFloat = 68
  static let caretHeight: CGFloat = 18
  static let keyboardKeySize: CGFloat = 40
  static let keyFace = LinearGradient(
    colors: [.obKeycapTop, .obSurface], startPoint: .top, endPoint: .bottom)
}

/// The mockup's seven-key row. The spacebar is scenery. Every selectable key goes through
/// the same owner acceptance as a captured key.
enum SetupShortcutKey: CaseIterable {
  case function, control, leftOption, leftCommand, space, rightCommand, rightOption

  var code: UInt16? {
    switch self {
    case .function: ModifierKeyCodes.globe
    case .control: ModifierKeyCodes.leftControl
    case .leftOption: ModifierKeyCodes.leftOption
    case .leftCommand: ModifierKeyCodes.leftCommand
    case .space: nil
    case .rightCommand: ModifierKeyCodes.rightCommand
    case .rightOption: ModifierKeyCodes.rightOption
    }
  }

  var name: LocalizedStringKey {
    switch self {
    case .function: "fn"
    case .control: "Control"
    case .leftOption: "Left Option"
    case .leftCommand: "Left Command"
    case .space: "Space"
    case .rightCommand: "Right Command"
    case .rightOption: "Right Option"
    }
  }

  var glyph: String {
    switch self {
    case .function: "fn"
    case .control: "⌃"
    case .leftOption, .rightOption: "⌥"
    case .leftCommand, .rightCommand: "⌘"
    case .space: "␣"
    }
  }

  func face(selected: Bool) -> some View {
    let shape = RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
    return Text(verbatim: glyph)
      .font(self == .function ? .firstRunCaption.weight(.semibold) : .firstRunSay)
      .foregroundStyle(
        selected ? Color.obAccent : (code == nil ? Color.obTextSecondary : Color.obTextPrimary)
      )
      .frame(
        width: code == nil ? nil : ShortcutLayout.keyboardKeySize,
        height: ShortcutLayout.keyboardKeySize
      )
      .frame(maxWidth: code == nil ? .infinity : nil)
      .background {
        if selected {
          shape.fill(Color.firstRunAccentSoft)
        } else {
          shape.fill(ShortcutLayout.keyFace)
        }
      }
      .overlay {
        shape.strokeBorder(
          selected ? Color.obAccent : Color.firstRunRule, lineWidth: DesignSpacing.xxs
        )
        .allowsHitTesting(false)
      }
      .contentShape(shape)
  }
}
