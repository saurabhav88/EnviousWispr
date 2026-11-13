import SwiftUI

/// Shared parts of the new Setup screens (#4528 chunk D), each added with its first real
/// consumer. Measurements follow the source-of-truth mockup's design system block.

/// Setup's primary button (mockup `[data-ui="btn"]`): 44 high, at most 360 wide, 12 corners,
/// label weight, hover and disabled colors, a slight press. Native `Button` semantics: keyboard
/// activation, focus and the accessibility name come from the button itself.
struct SetupPrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.firstRunLabel)
      .foregroundStyle(isEnabled ? Color.white : Color.firstRunButtonDisabledText)
      .frame(maxWidth: SetupMetrics.buttonMaxWidth)
      .frame(height: SetupMetrics.buttonHeight)
      .background(
        RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous)
          .fill(fill(pressed: configuration.isPressed))
      )
      .contentShape(RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous))
      .scaleEffect(configuration.isPressed && isEnabled ? 0.98 : 1)
      .animation(SettingsHover.animation, value: hovering)
      .onHover { hovering = $0 }
  }

  private func fill(pressed: Bool) -> Color {
    guard isEnabled else { return .firstRunButtonDisabled }
    return hovering || pressed ? .firstRunButtonHover : .obButtonFill
  }
}

/// Mockup measurements the Setup screens share.
enum SetupMetrics {
  static let buttonHeight: CGFloat = 44
  static let buttonMaxWidth: CGFloat = 360
  static let fieldHeight: CGFloat = 52
  static let tileSize: CGFloat = 36
  static let heroLips: CGFloat = 144
  static let screenLips: CGFloat = 112
  static let linksHeight: CGFloat = 32
  /// Language screen: the match/hint row, the match chip, the greeting bubble's top offset and
  /// the field's focus ring (mockup 48, 32, 14 and 3).
  static let statusRowHeight: CGFloat = 48
  static let chipHeight: CGFloat = 32
  static let bubbleTop: CGFloat = 14
  static let focusRing: CGFloat = 3
  /// Speech Compare: the tag height and the tile icon well (mockup 20, 52; the well's 14-point
  /// mockup corner uses the approved 12, DESIGN.md allows no new radius), and the tag's overlap
  /// above the tile (10).
  static let tagHeight: CGFloat = 20
  static let iconWell: CGFloat = 52
  static let tagOverlap: CGFloat = 10
  /// AI polish: the choice radio and its dot (mockup 20, 8) and the check badge (22).
  static let radio: CGFloat = 20
  static let radioDot: CGFloat = 8
  static let check: CGFloat = 22
}

/// A screen's footer (mockup `[data-ui="footer"]`): the primary action, then the 32-high links
/// row 16 below it. The screen places it at the bottom.
struct SetupFooter<Links: View>: View {
  let title: LocalizedStringKey
  var isEnabled = true
  let action: () -> Void
  @ViewBuilder var links: Links

  var body: some View {
    VStack(spacing: DesignSpacing.xxl) {
      Button(title, action: action)
        .buttonStyle(SetupPrimaryButtonStyle())
        .disabled(!isEnabled)
        .keyboardShortcut(.defaultAction)
      HStack(spacing: DesignSpacing.xs) { links }
        .frame(height: SetupMetrics.linksHeight)
    }
    .padding(.top, DesignSpacing.xl)
  }
}

/// A feature row (mockup `[data-ui="row"]` with a `tile` icon): surface background, 12 corners.
struct SetupRow: View {
  let symbol: String
  let title: LocalizedStringKey
  let detail: LocalizedStringKey

  var body: some View {
    HStack(spacing: DesignSpacing.xl) {
      Image(systemName: symbol)
        .font(.firstRunLabel)
        .foregroundStyle(Color.obAccent)
        .frame(width: SetupMetrics.tileSize, height: SetupMetrics.tileSize)
        .background(
          RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
            .fill(Color.firstRunAccentSoft)
        )
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
        Text(title).font(.firstRunLabel).foregroundStyle(Color.obTextPrimary)
        Text(detail).font(.firstRunCaption).foregroundStyle(Color.obTextSecondary)
          .fixedSize(horizontal: false, vertical: true)  // wraps if it must, never truncates
      }
      // The text takes the row's whole width (a Spacer beside it would split the width and wrap
      // captions the mockup shows on one line).
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, DesignSpacing.xl)
    .padding(.horizontal, DesignSpacing.xxl)
    .background(
      RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous).fill(Color.obSurface)
    )
    .accessibilityElement(children: .combine)
  }
}

/// The mockup's card rise (`obRise` 0.4 s), staggered by `delay`; none under Reduce Motion.
struct SetupRise: ViewModifier {
  let delay: Double
  let reduceMotion: Bool
  @State private var shown = false

  func body(content: Content) -> some View {
    content
      .opacity(shown || reduceMotion ? 1 : 0)
      .offset(y: shown || reduceMotion ? 0 : 8)
      .onAppear {
        // Shown either way, so turning Reduce Motion off later never hides an appeared row.
        if reduceMotion {
          shown = true
        } else {
          withAnimation(DesignMotion.firstRunRise.delay(delay)) { shown = true }
        }
      }
  }
}

/// A footer link (mockup `[data-ui="link"]`): accent, underlined, 32 high; `quiet` is the
/// secondary-text variant ("Recommended options").
struct SetupLinkButton: View {
  let title: LocalizedStringKey
  var quiet = false
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.firstRunLabel)
        .underline()
        .foregroundStyle(quiet ? Color.obTextSecondary : Color.obAccent)
        .padding(.horizontal, DesignSpacing.xl)
        .frame(height: SetupMetrics.linksHeight)
        .background(
          RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
            .fill(hovering ? (quiet ? Color.obSurface : Color.firstRunAccentSoft) : .clear))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(SettingsHover.animation, value: hovering)
  }
}

/// A surface card (mockup `[data-ui="card"]`): 16 padding, 16 corners.
struct SetupCard<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    content
      .padding(DesignSpacing.xxl)
      .frame(maxWidth: .infinity)
      .background(
        RoundedRectangle(cornerRadius: DesignRadius.xxl, style: .continuous).fill(Color.obSurface))
  }
}

/// A small uppercase tag (mockup `[data-ui="tag"]`); `recommended` is the success tone.
struct SetupTag: View {
  let text: String
  var recommended = false

  var body: some View {
    Text(verbatim: text.uppercased())
      .font(.firstRunEyebrow)
      .tracking(0.4)
      .lineLimit(1)
      .foregroundStyle(recommended ? Color.firstRunSuccessText : Color.obAccent)
      .padding(.horizontal, DesignSpacing.md)
      .frame(height: SetupMetrics.tagHeight)
      .background(
        Capsule().fill(recommended ? Color.obSuccessSoft : Color.firstRunAccentSoft)
          .background(Capsule().fill(Color.obCardBg)))
  }
}

/// The mockup's check pop (`obPop` 0.4 s: from 60% scale and clear), staggered by `delay`; none
/// under Reduce Motion. The mockup's pop curve equals its rise curve, so it shares that token.
struct SetupPop: ViewModifier {
  let delay: Double
  let reduceMotion: Bool
  @State private var shown = false

  func body(content: Content) -> some View {
    content
      .opacity(shown || reduceMotion ? 1 : 0)
      .scaleEffect(shown || reduceMotion ? 1 : 0.6)
      .onAppear {
        if reduceMotion {
          shown = true
        } else {
          withAnimation(DesignMotion.firstRunRise.delay(delay)) { shown = true }
        }
      }
  }
}

/// A selectable card (mockup `[data-ui="choice"]`): card fill, 2-point hairline border, 16
/// corners; selected is the accent wash and border; hover tints the border; disabled fades to
/// 55%. Native `Button` semantics, so keyboard and VoiceOver activation come from the button.
struct SetupChoiceStyle: ButtonStyle {
  let selected: Bool
  var cornerRadius: CGFloat = DesignRadius.xxl
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    return configuration.label
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(shape.fill(selected ? Color.firstRunAccentSoft : Color.obCardBg))
      .overlay(shape.strokeBorder(border, lineWidth: 2))
      .contentShape(shape)
      .opacity(isEnabled ? 1 : 0.55)
      .scaleEffect(configuration.isPressed && isEnabled ? 0.99 : 1)
      .animation(SettingsHover.animation, value: hovering)
      .onHover { hovering = $0 }
  }

  private var border: Color {
    if selected { return .obAccent }
    return hovering && isEnabled ? Color.obAccent.opacity(0.72) : .firstRunRule
  }
}

/// The choice card's radio (mockup `[data-ui="radio"]`): a 20-point ring, filled accent with an
/// 8-point dot when selected.
struct SetupRadio: View {
  let selected: Bool

  var body: some View {
    ZStack {
      Circle()
        .strokeBorder(selected ? Color.obAccent : Color.firstRunTextTertiary, lineWidth: 2)
        .background(Circle().fill(selected ? Color.obAccent : .clear))
      Circle()
        .fill(selected ? Color.firstRunOnAccent : .clear)
        .frame(width: SetupMetrics.radioDot, height: SetupMetrics.radioDot)
    }
    .frame(width: SetupMetrics.radio, height: SetupMetrics.radio)
    .accessibilityHidden(true)
  }
}
