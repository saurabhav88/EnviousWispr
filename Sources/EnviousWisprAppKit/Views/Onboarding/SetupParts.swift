import SwiftUI

/// Shared parts of the new Setup screens (#4528 chunk D), each added with its first real
/// consumer. Measurements follow the source-of-truth mockup's design system block.

/// Setup's primary button (mockup `[data-ui="btn"]`): 44 high, at most 360 wide, 12 corners,
/// label weight, hover and disabled colors, a slight press. Native `Button` semantics: keyboard
/// activation, focus and the accessibility name come from the button itself.
struct SetupPrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.overlayReduceMotionOverride) private var reduceMotionOverride
  @State private var hovering = false
  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

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
      .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.98 : 1)
      // Mockup: color and the press scale ease over 0.12 s; none under Reduce Motion.
      .animation(reduceMotion ? nil : SettingsHover.animation, value: hovering)
      .animation(reduceMotion ? nil : SettingsHover.animation, value: configuration.isPressed)
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
  /// Downloads: the gate card's working spinner (mockup 22-point icon, an 18-point ring).
  static let gateSpinner: CGFloat = 18
  /// Downloads: the progress bar's height (mockup 6).
  static let barHeight: CGFloat = 6
  /// Downloads: a card's status row (mockup min-height 20).
  static let cardStatusRow: CGFloat = 20
  /// AI polish See all: a tab's height (mockup 38).
  static let segmentHeight: CGFloat = 38
}

/// A screen's footer (mockup `[data-ui="footer"]`): the primary action, then the 32-high links
/// row 16 below it. The screen places it at the bottom.
struct SetupFooter<Links: View>: View {
  let title: LocalizedStringKey
  var isEnabled = true
  /// Mockup: a small spinner turns inside the button while its work runs (the key check).
  var busy = false
  let action: () -> Void
  @ViewBuilder var links: Links

  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.overlayReduceMotionOverride) private var reduceMotionOverride

  var body: some View {
    VStack(spacing: DesignSpacing.xxl) {
      Button(action: action) {
        HStack(spacing: DesignSpacing.md) {
          if busy {
            SetupSpinner(reduceMotion: reduceMotionOverride ?? systemReduceMotion, onAccent: true)
          }
          Text(title)
        }
      }
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
  /// The mockup rises rows and cards over 0.4 s, panels over 0.3 or 0.25 s, on one curve.
  var duration: Double = 0.4
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
          withAnimation(SetupMotion.rise(duration).delay(delay)) { shown = true }
        }
      }
  }
}

/// The mockup's rise and pop curve at other durations than the 0.4 s token.
enum SetupMotion {
  static func rise(_ duration: Double) -> Animation {
    DesignMotion.firstRunRise.speed(0.4 / duration)
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
  /// Checks pop over 0.4 s; the Language chip and greeting over 0.35 s.
  var duration: Double = 0.4
  @State private var shown = false

  func body(content: Content) -> some View {
    content
      .opacity(shown || reduceMotion ? 1 : 0)
      .scaleEffect(shown || reduceMotion ? 1 : 0.6)
      .onAppear {
        if reduceMotion {
          shown = true
        } else {
          withAnimation(SetupMotion.rise(duration).delay(delay)) { shown = true }
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
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.overlayReduceMotionOverride) private var reduceMotionOverride
  @State private var hovering = false
  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    return configuration.label
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(shape.fill(selected ? Color.firstRunAccentSoft : Color.obCardBg))
      .overlay(shape.strokeBorder(border, lineWidth: 2))
      .contentShape(shape)
      .opacity(isEnabled ? 1 : 0.55)
      .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.99 : 1)
      // Mockup: border and fill fade over 0.15 s on selection, the press scale over 0.12 s.
      .animation(reduceMotion ? nil : SettingsHover.animation, value: hovering)
      .animation(reduceMotion ? nil : DesignMotion.quick, value: selected)
      .animation(reduceMotion ? nil : SettingsHover.animation, value: configuration.isPressed)
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

/// A progress bar (mockup `[data-ui="bar"]`): a 6-point capsule track in the hairline color
/// with an accent fill, or an error fill. With no measured fraction it shows a short segment
/// sliding across, which stops at rest under Reduce Motion. Reads to VoiceOver as a progress
/// indicator with its percent.
struct SetupProgressBar: View {
  let fraction: Double?
  var isError = false
  let label: String
  let reduceMotion: Bool
  @State private var sweep = false

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.firstRunRule)
        if let fraction {
          Capsule()
            .fill(isError ? Color.obError : Color.obAccent)
            .frame(width: proxy.size.width * min(1, max(0, fraction)))
        } else {
          Capsule()
            .fill(Color.obAccent.opacity(0.72))
            .frame(width: proxy.size.width * 0.3)
            .offset(x: sweep && !reduceMotion ? proxy.size.width * 0.7 : 0)
        }
      }
    }
    .frame(height: SetupMetrics.barHeight)
    // Mockup: the fill glides to each new fraction over 0.3 s.
    .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: fraction)
    .onAppear { startSweep() }
    .onChange(of: reduceMotion) { startSweep() }
    .accessibilityElement()
    .accessibilityLabel(Text(verbatim: label))
    .accessibilityValue(
      Text(
        fraction.map { String(localized: "\(Int(($0 * 100).rounded(.down))) percent", comment: "Setup progress bar value.") }
          ?? String(localized: "In progress", comment: "Setup progress bar value with no measured percent.")))
    .accessibilityAddTraits(.updatesFrequently)
  }

  private func startSweep() {
    guard fraction == nil, !reduceMotion else {
      sweep = false
      return
    }
    withAnimation(DesignMotion.gentle.speed(0.3).repeatForever(autoreverses: true)) { sweep = true }
  }
}

/// The mockup's small arc spinner; a still arc under Reduce Motion.
struct SetupSpinner: View {
  let reduceMotion: Bool
  var onAccent = false
  /// 12 in buttons; the gate cards use the mockup's larger 18.
  var diameter: CGFloat = DesignSpacing.xl

  var body: some View {
    TimelineView(.animation(paused: reduceMotion)) { timeline in
      let turn = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8)
      Circle()
        .trim(from: 0, to: 0.75)
        .stroke(
          onAccent ? Color.firstRunOnAccent : Color.obAccent,
          style: StrokeStyle(
            lineWidth: diameter > DesignSpacing.xl ? diameter * 0.14 : DesignSpacing.xxs,
            lineCap: .round)
        )
        .frame(width: diameter, height: diameter)
        .rotationEffect(.degrees(reduceMotion ? 0 : turn / 0.8 * 360))
    }
    .accessibilityHidden(true)
  }
}
