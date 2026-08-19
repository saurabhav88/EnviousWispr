import AppKit
import SwiftUI

// MARK: - EscapeRecoveryPillView

/// The Escape Recovery pill (#2087): one sentence, one action, and a countdown
/// that shows the offer running out.
///
/// Deliberately NOT a question. The founder chose this over a "Want to paste?"
/// prompt, and the persona work agreed independently: a prompt demands attention
/// from someone who by definition is not looking, and the whole feature exists
/// for the case where the user has already moved on. It never steals focus (the
/// panel is `.nonactivatingPanel`), never blocks, and never requires dismissal.
///
/// History is the real path for most people; this is an accelerator for whoever
/// happens to be watching. That is why letting it expire costs nothing, and why
/// the spoken announcement names History rather than only the button.
///
/// **The view owns its own dwell**, exactly as `LanguageChipView` does, because
/// a panel-level timer cannot be paused by a hover only the view can see. Hover
/// cancels; hover-exit restarts the FULL three seconds rather than resuming the
/// remainder — matching the shipped chip deliberately, so two overlay pills do
/// not behave differently under the same gesture. The rail is driven from the
/// SAME two events, so what the user sees and what the timer is doing cannot
/// drift apart.
///
/// **The countdown is the brand line doing a job (founder design 2026-08-18).**
/// Every other overlay pill carries a static rainbow hairline along its bottom
/// edge. Here it traces the rim as the offer expires, so the deadline is visible
/// instead of arriving as a surprise.
struct EscapeRecoveryPillView: View {
  let onPaste: () -> Void
  let onExpire: () -> Void

  /// Founder-specified.
  static let dwellSeconds: Double = 3.0

  @Environment(\.colorScheme) private var colorScheme

  @State private var dismissTask: Task<Void, Never>?
  /// One-shot. Without it a fast double-click restores twice — and the second
  /// restore lands after the first has already moved the user's cursor.
  @State private var acted = false
  /// How far the rail has travelled, 0 to 1. Driven by the same hover events as
  /// `dismissTask`, never by its own clock.
  @State private var progress: Double = 0
  @State private var isActionHovered = false

  private var palette: PillPalette { PillPalette.forScheme(colorScheme) }

  var body: some View {
    HStack(spacing: PillMetrics.midGap) {
      Text(DictationNarrator.escapeRecoveryPillTitle)
        .font(.system(size: PillMetrics.titleSize, weight: .medium))
        .foregroundStyle(palette.text)
        .lineLimit(1)

      Button(action: {
        guard !acted else { return }
        acted = true
        dismissTask?.cancel()
        onPaste()
      }) {
        Text(DictationNarrator.escapeRecoveryPillAction)
          .font(.system(size: PillMetrics.actionSize, weight: .semibold))
          .foregroundStyle(palette.actionText)
          .lineLimit(1)
          .frame(width: PillMetrics.actionWidth, height: PillMetrics.actionHeight)
          .background(
            RoundedRectangle(cornerRadius: PillMetrics.actionRadius, style: .continuous)
              .fill(isActionHovered ? palette.actionFillHover : palette.actionFill)
          )
          .overlay(
            RoundedRectangle(cornerRadius: PillMetrics.actionRadius, style: .continuous)
              .strokeBorder(palette.actionRim, lineWidth: 1)
          )
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(DictationNarrator.escapeRecoveryPillAction)
      .onHover { isActionHovered = $0 }
    }
    .padding(.leading, PillMetrics.leadInset)
    .padding(.trailing, PillMetrics.trailInset)
    // The sentence centres in the WHOLE pill, because the rail is an overlay on
    // the rim rather than a row in a stack. Putting the bar in the layout steals
    // height from the bottom and lifts the text above the pill's true middle,
    // which reads as cramped at the top.
    .frame(width: PillMetrics.pillWidth, height: PillMetrics.pillHeight)
    .background(Capsule().fill(palette.fill))
    .overlay(Capsule().strokeBorder(palette.rim, lineWidth: 1))
    .overlay(
      SpectralRail(progress: progress, palette: palette)
        .padding(PillMetrics.railInset)
    )
    .shadow(color: palette.shadow, radius: palette.shadowRadius, y: 5)
    .onHover { isHovering in
      if isHovering {
        dismissTask?.cancel()
        // The offer is being HELD, and hover-exit restarts the full three
        // seconds rather than resuming — so the rail returns to empty rather
        // than freezing part-way, which would promise a resume that never comes.
        //
        // INSTANT, not animated, and that is load-bearing. An animated retreat
        // is interruptible: a hover shorter than the retreat leaves the rail
        // part-way, and the next `withAnimation` interpolates from there rather
        // than from empty. The timer would still give a full three seconds
        // while the rail claimed less — a countdown wrong in the only direction
        // that matters.
        resetRail()
      } else {
        scheduleExpiry()
      }
    }
    .onAppear { scheduleExpiry() }
    .onDisappear { dismissTask?.cancel() }
  }

  /// Empty the rail with no animation of its own, so whatever runs next starts
  /// from a known presentation value rather than from wherever an interrupted
  /// animation happened to be.
  private func resetRail() {
    var instant = Transaction()
    instant.disablesAnimations = true
    withTransaction(instant) { progress = 0 }
  }

  private func scheduleExpiry() {
    guard !acted else { return }
    dismissTask?.cancel()
    resetRail()
    withAnimation(.linear(duration: Self.dwellSeconds)) { progress = 1 }
    dismissTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(Self.dwellSeconds))
      guard !Task.isCancelled, !acted else { return }
      onExpire()
    }
  }
}

// MARK: - Metrics

/// The pill's geometry, in one place because the PANEL has to be sized to it and
/// a panel that disagrees with its content clips or floats.
enum PillMetrics {
  static let titleSize: CGFloat = 17
  static let actionSize: CGFloat = 15
  static let actionWidth: CGFloat = 78
  static let actionHeight: CGFloat = 34
  static let actionRadius: CGFloat = 12
  static let leadInset: CGFloat = 22
  static let midGap: CGFloat = 16
  static let trailInset: CGFloat = 10
  static let railInset: CGFloat = 1.5
  static let pillHeight: CGFloat = 58

  /// Room for the drop shadow, so the panel never clips it.
  static let panelMargin: CGFloat = 12

  /// The pill sizes itself to the SENTENCE it renders.
  ///
  /// A hand-tuned constant here is a latent truncation bug: the copy is
  /// founder-owned and has already been revised once (#2087, 2026-08-18), and a
  /// pill too narrow by two points silently renders "Transcript cance…". The
  /// two points of slack absorb rounding between this measurement and the
  /// renderer's own layout.
  static let pillWidth: CGFloat = {
    let font = NSFont.systemFont(ofSize: titleSize, weight: .medium)
    let title = DictationNarrator.escapeRecoveryPillTitle as NSString
    let measured = ceil(title.size(withAttributes: [.font: font]).width)
    return leadInset + measured + midGap + actionWidth + trailInset + 2
  }()

  static var panelWidth: CGFloat { pillWidth + panelMargin * 2 }
  static var panelHeight: CGFloat { pillHeight + panelMargin * 2 }
}

// MARK: - Palette

/// Every colour the pill uses, for both appearances.
///
/// A struct rather than scattered `colorScheme == .dark ? a : b` expressions so
/// neither theme can be half-defined: adding a colour means filling it in twice
/// or the build fails.
///
/// **This is the first floating panel in the app with a light appearance.** The
/// recording, polishing and language pills are dark in every environment
/// (`OverlayCapsuleBackground`), so a light Mac shows this one pill differently
/// from its neighbours until they follow.
struct PillPalette {
  var fill: Color
  var rim: Color
  var text: Color
  var actionFill: Color
  var actionFillHover: Color
  var actionRim: Color
  var actionText: Color
  var shadow: Color
  var shadowRadius: CGFloat
  var spectrum: [Color]

  static func forScheme(_ scheme: ColorScheme) -> PillPalette {
    scheme == .dark ? .dark : .light
  }

  static let dark = PillPalette(
    fill: Color(red: 0.078, green: 0.078, blue: 0.11).opacity(0.90),
    rim: .white.opacity(0.14),
    text: .white,
    actionFill: .white.opacity(0.16),
    actionFillHover: .white.opacity(0.26),
    actionRim: .clear,
    actionText: .white,
    shadow: .black.opacity(0.55),
    shadowRadius: 14,
    spectrum: PillSpectrum.dark
  )

  static let light = PillPalette(
    fill: Color(red: 0.98, green: 0.98, blue: 0.99).opacity(0.94),
    rim: .black.opacity(0.10),
    text: Color(red: 0.10, green: 0.10, blue: 0.13),
    actionFill: .black.opacity(0.075),
    actionFillHover: .black.opacity(0.13),
    actionRim: .black.opacity(0.09),
    actionText: Color(red: 0.10, green: 0.10, blue: 0.13),
    shadow: .black.opacity(0.22),
    shadowRadius: 16,
    spectrum: PillSpectrum.light
  )
}

/// The brand sequence the rail reveals.
///
/// **The HEAD is theme-dependent and that is the whole point.** A hot white head
/// reads as a moving light on a dark pill and is invisible on a white one, so
/// the light sequence leads with deep amber instead. The two themes cannot share
/// one sequence, which is why this is not a single constant.
enum PillSpectrum {
  /// The pill fill each spectrum is drawn ON. Held here because the contrast
  /// floor below is a claim about the PAIR, and a fill that moves without its
  /// spectrum moving is exactly the change that would break it silently.
  static let darkGround = (red: 0.078, green: 0.078, blue: 0.11)
  static let lightGround = (red: 0.98, green: 0.98, blue: 0.99)

  /// The shipped brand line, which lives on dark pills and is bright by design.
  static let dark: [Color] = [
    .white,
    Color(red: 1.0, green: 0.843, blue: 0.0),
    Color(red: 1.0, green: 0.549, blue: 0.0),
    Color(red: 1.0, green: 0.165, blue: 0.251),
    Color(red: 0.914, green: 0.118, blue: 0.706),
    Color(red: 0.541, green: 0.169, blue: 0.886),
    Color(red: 0.255, green: 0.412, blue: 0.882),
    Color(red: 0.118, green: 0.565, blue: 1.0),
    Color(red: 0.0, green: 0.78, blue: 0.85),
    Color(red: 0.0, green: 0.72, blue: 0.45),
    Color(red: 0.42, green: 0.75, blue: 0.12),
  ]

  /// **Not the dark sequence re-used.** Measured against the white pill, six of
  /// the eleven brand colours fall under a 3:1 contrast floor — the yellow head
  /// worst at 1.55:1, which is a countdown that appears never to start. These
  /// hold the same hues and deepen the value until each clears the floor.
  ///
  /// The HEAD inverts deliberately: on a dark pill the leading spark is the
  /// brightest colour, on a light one it is the darkest. Both read as the hot
  /// end of the rail.
  static let light: [Color] = [
    Color(red: 0.62, green: 0.40, blue: 0.0),
    Color(red: 0.84, green: 0.46, blue: 0.0),
    Color(red: 1.0, green: 0.115, blue: 0.206),
    Color(red: 0.914, green: 0.072, blue: 0.694),
    Color(red: 0.52, green: 0.125, blue: 0.886),
    Color(red: 0.211, green: 0.379, blue: 0.882),
    Color(red: 0.068, green: 0.54, blue: 1.0),
    Color(red: 0.0, green: 0.608, blue: 0.663),
    Color(red: 0.0, green: 0.626, blue: 0.391),
    Color(red: 0.328, green: 0.615, blue: 0.068),
  ]
}

// MARK: - The rail

/// The bottom edge of the capsule, as a path that can be drawn along.
///
/// Deliberately NOT a straight line inset from the bottom. The countdown rides
/// the rim and curls up into both end caps, which is what makes it read as part
/// of the pill rather than a progress bar parked inside it.
struct BottomRail: Shape {
  /// How far up each cap the rail climbs, in degrees past the bottom.
  var climb: Double = 28

  func path(in rect: CGRect) -> Path {
    let radius = rect.height / 2
    let leftCentre = CGPoint(x: rect.minX + radius, y: rect.midY)
    let rightCentre = CGPoint(x: rect.maxX - radius, y: rect.midY)
    var path = Path()
    path.addArc(
      center: leftCentre, radius: radius,
      startAngle: .degrees(90 + climb), endAngle: .degrees(90),
      clockwise: true)
    path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
    path.addArc(
      center: rightCentre, radius: radius,
      startAngle: .degrees(90), endAngle: .degrees(90 - climb),
      clockwise: true)
    return path
  }
}

/// The three seconds, drawn along the rim.
///
/// The gradient is painted across the FULL width and then MASKED by the drawn
/// portion of the rail, so a colour never moves once it has appeared — the rail
/// REVEALS the spectrum rather than squeezing it into whatever length it has
/// reached so far. Painting the gradient into the trimmed path instead would
/// make every colour slide leftward as the rail grew.
struct SpectralRail: View {
  var progress: Double
  var palette: PillPalette
  var lineWidth: CGFloat = 3

  var body: some View {
    ZStack {
      spectrum
        .mask { rail }
        .blur(radius: 4)
        .opacity(0.8)
      spectrum
        .mask { rail }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var spectrum: some View {
    LinearGradient(colors: palette.spectrum, startPoint: .leading, endPoint: .trailing)
  }

  /// How much of the rail is drawn for a given elapsed fraction.
  ///
  /// The floor keeps a visible spark at t=0, so the pill never appears with a
  /// rim that looks broken; the ceiling stops a late or over-shooting animation
  /// value from asking `trim` for more path than exists.
  static func drawnFraction(for progress: Double) -> Double {
    guard progress.isFinite else { return minimumSpark }
    return max(minimumSpark, min(1, progress))
  }

  static let minimumSpark: Double = 0.015

  private var rail: some View {
    BottomRail()
      .trim(from: 0, to: Self.drawnFraction(for: progress))
      .stroke(
        Color.white,
        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
  }
}
