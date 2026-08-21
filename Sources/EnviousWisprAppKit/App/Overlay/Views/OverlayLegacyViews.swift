import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import SwiftUI

// MARK: - The two legacy observable channels

/// Observable state holder for hands-free lock mode.
///
/// **Kept, not removed, and this file is why.** With one retained window every
/// change is a morph, so a channel that exists so a lock can update "without
/// tearing down and recreating the panel" has nothing left to work around. But
/// removing it means editing the leaf views below, which C4c deliberately does
/// not do; `OverlayRootView` drives it FROM the presentation instead, so the
/// presentation is the single source and the views are untouched.
///
/// It moved here from `RecordingOverlayPanel` when that class was deleted. Its
/// removal belongs with the leaf-view cleanup this migration explicitly defers.
@MainActor
@Observable
final class OverlayLockState {
  var isLocked: Bool = false
}

/// Observable holder for the transient in-panel notice banner (#1060).
///
/// Its original doc comment stated the reason it exists: so a notice can morph
/// the live recording pill "WITHOUT tearing the panel down", because every other
/// notice path rebuilt the single panel and lost the `.recording` state. That
/// rebuild is what #2292 removed, so the workaround outlived its problem — see
/// `OverlayLockState` for why it is still here.
@MainActor
@Observable
final class OverlayNoticeState {
  var message: String? = nil
}


// The overlay's SwiftUI view layer, moved verbatim out of
// `05411427:Sources/EnviousWisprAppKit/App/RecordingOverlayPanel.swift` (#2292, chunk C1). Nothing here changed: same
// declarations, same order, same file-private relationships between the view
// types, which is why they moved as ONE unit rather than one file per feature.
//
// These views DO still participate in the current presentation transaction —
// through provider closures, `OverlayNoticeState`, and view-owned expiry tasks.
// The move changes their LOCATION, not their ownership or behaviour. Ownership
// moves in the C4 cutover, which is where the per-feature split belongs.

// MARK: - SpectrumWheelIcon

/// 12 rainbow-colored bars arranged radially, spinning slowly.
struct SpectrumWheelIcon: View {
  @State private var rotation: Double = 0
  let size: CGFloat

  private let bars: [(deg: Double, yOffset: CGFloat, height: CGFloat, color: Color)] = [
    (0, 4, 14, Color(red: 1.0, green: 0.176, blue: 0.333)),
    (30, 7, 10, Color(red: 1.0, green: 0.624, blue: 0.039)),
    (60, 5, 12, Color(red: 1.0, green: 0.839, blue: 0.039)),
    (90, 8, 9, Color(red: 0.188, green: 0.82, blue: 0.345)),
    (120, 4, 14, Color(red: 0.204, green: 0.78, blue: 0.349)),
    (150, 6, 11, Color(red: 0.196, green: 0.847, blue: 0.745)),
    (180, 5, 13, Color(red: 0.392, green: 0.824, blue: 1.0)),
    (210, 8, 9, Color(red: 0.039, green: 0.518, blue: 1.0)),
    (240, 4, 14, Color(red: 0.369, green: 0.361, blue: 0.902)),
    (270, 6, 12, Color(red: 0.749, green: 0.353, blue: 0.949)),
    (300, 7, 10, Color(red: 1.0, green: 0.176, blue: 0.333)),
    (330, 5, 13, Color(red: 1.0, green: 0.624, blue: 0.039)),
  ]

  var body: some View {
    // Scale factor: SVG viewBox is 64x64, we map to `size`
    let scale = size / 64.0
    Canvas { context, size in
      let cx = size.width / 2
      let cy = size.height / 2
      for bar in bars {
        let barW = 4.0 * scale
        let barH = bar.height * scale
        // Bar rect centered on the canvas, offset upward by yOffset so
        // its visual center sits at the correct radial distance.
        let distFromCenter = 32.0 * scale - bar.yOffset * scale - barH / 2
        let rect = CGRect(
          x: -barW / 2,
          y: -distFromCenter - barH / 2,
          width: barW,
          height: barH
        )
        let cornerRadius = 2.0 * scale
        let barPath = Path(roundedRect: rect, cornerRadius: cornerRadius)
        // Rotate around canvas center by bar's degree offset (converted to radians).
        let angle = bar.deg * .pi / 180.0
        let transform = CGAffineTransform(translationX: cx, y: cy)
          .rotated(by: angle)
        let rotatedPath = barPath.applying(transform)
        context.fill(rotatedPath, with: .color(bar.color))
      }
    }
    .frame(width: size, height: size)
    .rotationEffect(.degrees(rotation))
    .onAppear {
      withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
        rotation = 360
      }
    }
    .accessibilityHidden(true)
  }
}

// MARK: - RainbowLipsIcon

/// Lip/spectrum bar brand icon driven by real-time audio level during recording.
/// Each of the 18 bars (9 upper + 9 lower) scales vertically in response to
/// `audioLevel` (0.0–1.0). Per-bar variation factors make the motion organic
/// rather than all bars moving in lockstep.
///
/// Scale formula (matches MenuBarIconAnimator.renderRecordingLips):
///   scaleY = silenceScale + (peakScale - silenceScale) * level * perBarFactor
///
/// At silence (level ≈ 0) bars sit at their minimum compressed state (lips closed).
/// At peak (level = 1.0) center bars reach maximum expansion (lips open/talking).
/// #2202: the live level meter in the preview pill's header.
///
/// **Replaces the lips mark in THIS box only.** The mark stays everywhere else —
/// the menu bar, the polishing pill, settings. Founder direction, 2026-08-19: it
/// is a logo doing a meter's job, a square block of nine bars that has to be read
/// as a picture before it reads as movement, and it occupies the left edge the
/// timer should own. Nine bars on a baseline say "I can hear you" in a shape
/// everyone knows from every recorder ever made.
///
/// Nine bars, nine brand spectrum colours in order, red through violet — the same
/// palette and the same order as `RainbowLipsIcon`, so the two read as one family
/// while the pill transitions between layouts.
///
/// **Symmetric about a centre line rather than growing off a floor.** That echoes
/// the mark it replaces, and it means the meter's visual weight does not shift
/// down the header as the level drops.
///
/// Fixed height in every state. This KEEPS a property rather than adding one: the
/// capsule is already height-neutral across modes, because `scaleEffect` does not
/// participate in layout (measured — `fittingSize` 95x44 at both 1.0 and 2.0).
/// The 2x mark overflows its own slot visually and nothing resizes. A meter
/// occupying one strip avoids reintroducing a real size change where the old
/// design only ever had an apparent one.
struct RainbowLevelMeter: View {
  /// Normalised audio level 0.0-1.0, polled every ~50 ms by the parent view. The
  /// same value `RainbowLipsIcon` reads, so this adds no timer and no new source.
  let audioLevel: Float

  /// The parent's poll counter, incremented once per sample whether or not the
  /// level changed.
  ///
  /// **The history cannot be driven by a change in `audioLevel`, and that is not a
  /// style preference — it is the difference between a waveform that drains and one
  /// that freezes.** `onChange` fires on a CHANGE, and silence is the one passage
  /// where consecutive samples are bit-identical, so a level-driven history stops
  /// scrolling exactly when the user stops talking: the shape of their last words
  /// sits frozen on screen until they speak again. Reading a strictly-increasing
  /// tick makes every poll a sample, so a pause scrolls out to the silence floor
  /// the way a record of volume should.
  let tick: Int

  var height: CGFloat = 16
  var barWidth: CGFloat = 2
  var spacing: CGFloat = 1.5

  /// Outcome observer for the rendered history update. Production uses the
  /// no-op default; host-view tests use it to prove the SwiftUI trigger feeds
  /// identical samples on successive poll ticks.
  var onHistoryChange: ([CGFloat]) -> Void = { _ in }

  /// #2216: the last `barCount` levels, oldest first. Bar `i` is a MOMENT, not a
  /// position on a shape.
  ///
  /// **The first version drew every bar from the same instant's level**, scaled by
  /// a fixed per-bar weight, so all nine could only rise and fall together — a
  /// level meter in a waveform's clothes. The founder caught it against the
  /// approved mockup, where each bar ran on its own CSS timer at its own phase and
  /// therefore only LOOKED like a record of anything. Real audio hands us one
  /// scalar per tick, so the only honest way to get that picture is to keep the
  /// scalars.
  @State private var history: [CGFloat] = []

  /// About 1.2 seconds of history at the parent's 50 ms poll — long enough to read
  /// as a shape, short enough that it is recognisably what you just said.
  static let barCount = 24

  /// A bar's minimum share of the strip. Non-zero on purpose: a meter that
  /// collapses to nothing between words reads as "it stopped hearing me", which is
  /// the exact anxiety the preview exists to remove.
  static let silenceFraction: CGFloat = 0.14

  /// Additional share available at full level.
  static let peakFraction: CGFloat = 0.86

  /// The brand spectrum, sampled across the strip.
  ///
  /// **Positional, not per-sample.** The gradient stays still while heights scroll
  /// through it, which keeps the mark recognisable — colours crawling sideways
  /// would read as a progress bar rather than as our spectrum.
  static let spectrum: [Color] = [
    Color(red: 1.0, green: 0.165, blue: 0.251),  // #ff2a40 red
    Color(red: 1.0, green: 0.549, blue: 0.0),  // #ff8c00 orange
    Color(red: 1.0, green: 0.843, blue: 0.0),  // #ffd700 gold
    Color(red: 0.678, green: 1.0, blue: 0.184),  // #adff2f lime
    Color(red: 0.0, green: 0.98, blue: 0.604),  // #00fa9a spring
    Color(red: 0.0, green: 1.0, blue: 1.0),  // #00ffff cyan
    Color(red: 0.118, green: 0.565, blue: 1.0),  // #1e90ff blue
    Color(red: 0.255, green: 0.412, blue: 0.882),  // #4169e1 royal
    Color(red: 0.541, green: 0.169, blue: 0.886),  // #8a2be2 violet
  ]

  /// The colour at position `index` of `count`, interpolated across the spectrum so
  /// the gradient is smooth at any bar count.
  static func colour(at index: Int, of count: Int) -> Color {
    guard count > 1 else { return spectrum[0] }
    let t = CGFloat(min(max(index, 0), count - 1)) / CGFloat(count - 1)
    let scaled = t * CGFloat(spectrum.count - 1)
    let lower = Int(scaled)
    let upper = min(lower + 1, spectrum.count - 1)
    let frac = scaled - CGFloat(lower)
    return frac < 0.001
      ? spectrum[lower] : spectrum[lower].blended(with: spectrum[upper], amount: frac)
  }

  /// Fraction of the strip a sample occupies.
  ///
  /// Extracted so a test can assert it without rendering — a `Canvas` cannot be
  /// asked what it drew.
  static func fill(level: CGFloat) -> CGFloat {
    silenceFraction + peakFraction * min(max(level, 0), 1)
  }

  /// Push a sample onto the history, dropping the oldest once full.
  ///
  /// Pure and static so the scrolling behaviour is testable directly: this is the
  /// whole difference between a record and a level, and it is the part that was
  /// missing.
  static func pushed(_ history: [CGFloat], level: CGFloat, capacity: Int = barCount) -> [CGFloat] {
    guard capacity > 0 else { return [] }
    // Clamp on the way IN, so a bad sample cannot sit in the buffer for a second
    // and a bit poisoning every frame it appears in.
    var next = history + [min(max(level, 0), 1)]
    if next.count > capacity { next.removeFirst(next.count - capacity) }
    return next
  }

  /// The level to draw in each of `count` bars, right-aligned so the newest sample
  /// is always at the same edge — without this the whole waveform slides sideways
  /// for the first second of every recording.
  ///
  /// Extracted from the `Canvas` so it can be asserted directly: a `Canvas` cannot
  /// be asked what it drew, and this is the step that turns a buffer into bars.
  /// Every read is bounds-checked rather than trusting `history` to be the right
  /// length, because this runs on the heart path and an index slip here is a crash
  /// in the recording overlay.
  static func bars(history: [CGFloat], count: Int = barCount) -> [CGFloat] {
    guard count > 0 else { return [] }
    let pad = max(0, count - history.count)
    // A longer-than-expected buffer keeps its NEWEST samples, never its oldest.
    let offset = max(0, history.count - count)
    return (0..<count).map { i in
      let index = i - pad + offset
      return index >= 0 && index < history.count ? history[index] : 0
    }
  }

  var body: some View {
    Canvas { context, size in
      let levels = Self.bars(history: history)
      for i in 0..<Self.barCount {
        let barHeight = size.height * Self.fill(level: levels[i])
        let x = CGFloat(i) * (barWidth + spacing)
        let rect = CGRect(
          x: x, y: (size.height - barHeight) / 2,
          width: barWidth, height: barHeight)
        context.fill(
          Path(roundedRect: rect, cornerRadius: barWidth / 2),
          with: .color(Self.colour(at: i, of: Self.barCount)))
      }
    }
    .frame(width: Self.width(barWidth: barWidth, spacing: spacing), height: height)
    .onChange(of: tick) { _, _ in
      let next = Self.pushed(history, level: CGFloat(audioLevel))
      history = next
      onHistoryChange(next)
    }
    .accessibilityHidden(true)
  }

  /// Total width for `barCount` bars and their gaps. Derived rather than a
  /// literal, so the frame cannot drift from what the Canvas draws.
  static func width(barWidth: CGFloat, spacing: CGFloat) -> CGFloat {
    CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
  }
}

extension Color {
  /// Linear blend towards another colour, for the meter's positional gradient.
  fileprivate func blended(with other: Color, amount: CGFloat) -> Color {
    let a = NSColor(self).usingColorSpace(.sRGB) ?? .white
    let b = NSColor(other).usingColorSpace(.sRGB) ?? .white
    let t = min(max(amount, 0), 1)
    return Color(
      red: a.redComponent + (b.redComponent - a.redComponent) * t,
      green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
      blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t)
  }
}

struct RainbowLipsIcon: View {
  let size: CGFloat
  /// Normalised audio level 0.0-1.0, updated every ~50 ms by the parent view.
  let audioLevel: Float
  /// When true, all bars turn red and pulse opacity (distress/interruption state).
  var isDistress: Bool = false

  private let upperBars: [(x: CGFloat, y: CGFloat, h: CGFloat, color: Color)] = [
    (4, 22.25, 5, Color(red: 1.0, green: 0.165, blue: 0.251)),
    (10, 17.6375, 8, Color(red: 1.0, green: 0.549, blue: 0.0)),
    (16, 12.04, 12, Color(red: 1.0, green: 0.843, blue: 0.0)),
    (22, 16.96, 9, Color(red: 0.678, green: 1.0, blue: 0.184)),
    (28, 21.5575, 6, Color(red: 0.0, green: 0.98, blue: 0.604)),
    (34, 16.96, 9, Color(red: 0.0, green: 1.0, blue: 1.0)),
    (40, 12.04, 12, Color(red: 0.118, green: 0.565, blue: 1.0)),
    (46, 17.6375, 8, Color(red: 0.255, green: 0.412, blue: 0.882)),
    (52, 22.25, 5, Color(red: 0.541, green: 0.169, blue: 0.886)),
  ]

  private let lowerBars: [(x: CGFloat, y: CGFloat, h: CGFloat, color: Color)] = [
    (4, 30.25, 5, Color(red: 0.255, green: 0.412, blue: 0.882)),
    (10, 28.6375, 9, Color(red: 0.118, green: 0.565, blue: 1.0)),
    (16, 27.04, 12, Color(red: 0.0, green: 1.0, blue: 1.0)),
    (22, 28.96, 15, Color(red: 0.0, green: 0.98, blue: 0.604)),
    (28, 30.5575, 17, Color(red: 0.678, green: 1.0, blue: 0.184)),
    (34, 28.96, 15, Color(red: 1.0, green: 0.843, blue: 0.0)),
    (40, 27.04, 12, Color(red: 1.0, green: 0.549, blue: 0.0)),
    (46, 28.6375, 9, Color(red: 1.0, green: 0.165, blue: 0.251)),
    (52, 30.25, 5, Color(red: 0.541, green: 0.169, blue: 0.886)),
  ]

  // Per-bar sensitivity multipliers (index 0-8).
  // Center bars (index 4) react most; edge bars react least — mirrors the
  // centerDistance weighting used in MenuBarIconAnimator.renderRecordingLips.
  private let sensitivity: [CGFloat] = [0.70, 0.80, 0.90, 0.95, 1.00, 0.95, 0.90, 0.80, 0.70]

  // Baseline scaleY when audio level is zero (lips lightly closed).
  private let silenceScale: CGFloat = 0.55

  // Maximum additional scaleY headroom above silence (reached at level = 1.0
  // for the most-sensitive bar). Chosen so peak scaleY ≈ 1.45 for center bars.
  private let peakRange: CGFloat = 0.90

  /// Compute the Y scale for a given bar index and the current audio level.
  /// Upper and lower bars share the same formula; the caller may pass a
  /// mirrored index to create counterpoint movement between the two lip halves.
  private func yScale(for barIndex: Int, level: CGFloat) -> CGFloat {
    silenceScale + peakRange * level * sensitivity[barIndex]
  }

  private static let distressRed = Color(red: 1.0, green: 0.165, blue: 0.251)

  var body: some View {
    if isDistress {
      // Distress mode: lips in normal shape, all bars red, pulsing opacity.
      // TimelineView drives continuous redraw; Canvas does not respond to @State animation.
      TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
        let phase = timeline.date.timeIntervalSinceReferenceDate
        let pulseOpacity = 0.4 + 0.6 * (0.5 + 0.5 * sin(phase * .pi / 0.35))
        lipsCanvas(level: 0.3, barColorOverride: Self.distressRed)
          .opacity(pulseOpacity)
      }
      .frame(width: size, height: size)
      .accessibilityHidden(true)
    } else {
      lipsCanvas(level: CGFloat(min(max(audioLevel, 0), 1)), barColorOverride: nil)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
  }

  /// Shared Canvas renderer for both normal and distress modes.
  /// When `barColorOverride` is non-nil, all bars use that color instead of their rainbow colors.
  private func lipsCanvas(level: CGFloat, barColorOverride: Color?) -> some View {
    let scale = size / 64.0
    return Canvas { context, canvasSize in
      let maxSeparation = 3.5 * scale
      let barW = 4.5 * scale
      let cornerRadius = 1.5 * scale

      for i in 0..<upperBars.count {
        let bar = upperBars[i]
        let s = yScale(for: i, level: level)
        let scaledH = bar.h * scale * s
        let separation = -maxSeparation * level * sensitivity[i]
        let barBottom = (bar.y + bar.h) * scale + separation
        let rect = CGRect(
          x: bar.x * scale,
          y: barBottom - scaledH,
          width: barW,
          height: scaledH
        )
        let barPath = Path(roundedRect: rect, cornerRadius: cornerRadius)
        context.fill(barPath, with: .color(barColorOverride ?? bar.color))
      }

      for i in 0..<lowerBars.count {
        let bar = lowerBars[i]
        let s = yScale(for: 8 - i, level: level)
        let scaledH = bar.h * scale * s
        let separation = maxSeparation * level * sensitivity[8 - i]
        let barTop = bar.y * scale + separation
        let rect = CGRect(
          x: bar.x * scale,
          y: barTop,
          width: barW,
          height: scaledH
        )
        let barPath = Path(roundedRect: rect, cornerRadius: cornerRadius)
        context.fill(barPath, with: .color(barColorOverride ?? bar.color))
      }
    }
  }
}

// MARK: - OverlayCapsuleBackground

/// Shared capsule background with warmer dark fill, subtle border, and a
/// rainbow gradient line pulsing along the bottom edge.
private struct OverlayCapsuleBackground: View {
  /// #1988: the live-preview pill is tall and full of text, and a capsule's
  /// semicircular ends eat exactly the width the text needs while crowding the
  /// first and last characters of every line. A rounded rectangle reads as a panel
  /// rather than a lozenge at that size, which is what the shape should say.
  /// Everything else keeps the capsule.
  enum CornerStyle {
    case capsule
    case rounded
  }

  var cornerStyle: CornerStyle = .capsule
  @State private var glowOpacity: Double = 0.3

  /// #2201: the preview pill's rainbow hairline holds still instead of breathing
  /// on a permanent two-second loop.
  ///
  /// The loop is a nice touch on the small capsule, which shows for a moment and
  /// carries no text. On the preview pill it sits under a box that is already
  /// growing a line at a time while words arrive, and the two movements read as
  /// one restless object — the founder reported the pill "pulsing", and this is
  /// the part of that which is not the sizing defect.
  ///
  /// Mid-way between the loop's own 0.3 and 0.65 endpoints, so the line is no
  /// dimmer on average than the one it replaces.
  private static let steadyPreviewGlow: Double = 0.5

  private var shape: AnyShape {
    switch cornerStyle {
    case .capsule: return AnyShape(Capsule())
    case .rounded: return AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
  }

  /// #2204: the preview branch follows the appearance setting; the capsule does
  /// not. This type has EIGHT call sites and only `.rounded` is the preview, so
  /// every colour here is selected on `cornerStyle` and the `.capsule` values stay
  /// byte-identical for the polishing pill, the cold-start notice, the distress
  /// variant and four others — surfaces that ship to everyone, while the preview
  /// ships OFF by default and is macOS 26+.
  private var isPreview: Bool { cornerStyle == .rounded }

  var body: some View {
    shape
      .fill(
        isPreview
          ? PreviewPillPalette.surface
          : Color(red: 0.078, green: 0.078, blue: 0.11).opacity(0.82)
      )
      // `strokeBorder` needs an insettable shape, which the type-erased `AnyShape`
      // is not, so the two concrete shapes are named here. Kept as `strokeBorder`
      // rather than switching both to `stroke`: the capsule is shipped UI and its
      // border should stay exactly where it already sits.
      .overlay(
        Group {
          switch cornerStyle {
          case .capsule:
            Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
          case .rounded:
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .strokeBorder(PreviewPillPalette.border, lineWidth: 0.5)
          }
        }
      )
      .overlay(alignment: .bottom) {
        LinearGradient(
          colors: [
            .clear,
            Color(red: 1.0, green: 0.165, blue: 0.251),  // #ff2a40 red
            Color(red: 1.0, green: 0.549, blue: 0.0),  // #ff8c00 orange
            Color(red: 1.0, green: 0.843, blue: 0.0),  // #ffd700 yellow
            Color(red: 0.678, green: 1.0, blue: 0.184),  // #adff2f yellow-green
            Color(red: 0.0, green: 0.98, blue: 0.604),  // #00fa9a mint
            Color(red: 0.0, green: 1.0, blue: 1.0),  // #00ffff cyan
            Color(red: 0.118, green: 0.565, blue: 1.0),  // #1e90ff dodger blue
            Color(red: 0.255, green: 0.412, blue: 0.882),  // #4169e1 royal blue
            Color(red: 0.541, green: 0.169, blue: 0.886),  // #8a2be2 purple
            .clear,
          ],
          startPoint: .leading,
          endPoint: .trailing
        )
        .frame(height: 1)
        .opacity(cornerStyle == .rounded ? Self.steadyPreviewGlow : glowOpacity)
        .padding(.horizontal, 20)
        .offset(y: -1)
      }
      .onAppear {
        // #2201: only the capsule breathes. Arming a `repeatForever` for the
        // preview would keep it re-rendering whether or not anything read
        // `glowOpacity`, and the point of this chunk is that the preview pill
        // stops moving on its own.
        guard cornerStyle == .capsule else { return }
        withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
          glowOpacity = 0.65
        }
      }
      .accessibilityHidden(true)
  }
}

// MARK: - DistressCapsuleBackground

/// Capsule background for interruption warnings: red glow instead of rainbow.
private struct DistressCapsuleBackground: View {
  @State private var glowOpacity: Double = 0.3

  var body: some View {
    Capsule()
      .fill(Color(red: 0.078, green: 0.078, blue: 0.11).opacity(0.82))
      .overlay(
        Capsule()
          .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
      )
      .overlay(alignment: .bottom) {
        LinearGradient(
          colors: [
            .clear,
            Color(red: 1.0, green: 0.165, blue: 0.251),
            Color(red: 1.0, green: 0.27, blue: 0.27),
            Color(red: 1.0, green: 0.165, blue: 0.251),
            .clear,
          ],
          startPoint: .leading,
          endPoint: .trailing
        )
        .frame(height: 1)
        .opacity(glowOpacity)
        .padding(.horizontal, 20)
        .offset(y: -1)
      }
      .onAppear {
        withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
          glowOpacity = 0.6
        }
      }
      .accessibilityHidden(true)
  }
}

// MARK: - RecordingOverlayView

/// Compact recording indicator overlay.
struct RecordingOverlayView: View {
  let audioLevelProvider: () -> Float
  /// #1393: monotonic elapsed recording time, read from the shared kernel
  /// source of truth instead of a per-view-instance stamp — a panel-recreate
  /// (e.g. transitionToRecording) must not reset the displayed timer.
  let recordingElapsedProvider: () -> TimeInterval?
  /// #1988: what the live preview should show. Polled on the same 50 ms loop as
  /// audio level and elapsed time rather than on a publisher, because that loop
  /// already exists and coalesces naturally: Apple emits updates every ~210-290 ms,
  /// so a push-based feed would redraw more often than the eye can read without
  /// showing anything more.
  let livePreviewProvider: () -> LivePreviewDisplay
  /// #1988: reports the capsule's measured height so the panel can follow it as the
  /// preview grows. No-op when the preview is off.
  var onContentHeightChange: (CGFloat) -> Void = { _ in }
  /// #1988: whether this pill is the tall preview layout. Passed in rather than
  /// derived from the display state, which remains `.off` until the polling task
  /// first runs and would flash the capsule shape before that first read.
  ///
  /// #2201: the previous wording said "for one 50 ms poll", which names a duration
  /// the code does not have — the task reads its providers BEFORE its first sleep,
  /// so the window is until it is first scheduled, not a fixed 50 ms.
  var usesPreviewLayout: Bool = false
  var lockState: OverlayLockState
  /// #1060: transient notice banner shown inside the recording capsule.
  var noticeState: OverlayNoticeState
  @State private var audioLevel: Float = 0

  /// Counts polls, not level changes. #2216: the meter's history needs a sample
  /// every tick INCLUDING the silent ones, and consecutive silent samples are
  /// bit-identical, so `audioLevel` alone cannot drive it.
  @State private var audioTick: Int = 0
  @State private var elapsed: TimeInterval = 0
  @State private var preview: LivePreviewDisplay

  /// Seeds `preview` so a size test can measure a KNOWN display state on the
  /// first layout pass instead of waiting for the 50 ms poll to publish one.
  ///
  /// **The seam exists because the alternative is a timed wait, and this view's
  /// whole defect is about what its height does over time.** `preview` is
  /// `@State`, so nothing outside can set it; without this a test would have to
  /// pump a run loop until the polling task happened to run, which is the
  /// guess-when-the-subject-is-finished shape testing-philosophy.md forbids.
  ///
  /// Production never passes it. The poll is the only writer it needs, and it
  /// overwrites this on the first tick regardless — so a wrong value here cannot
  /// survive into a real recording, which is what makes the seam cheap.
  init(
    audioLevelProvider: @escaping () -> Float,
    recordingElapsedProvider: @escaping () -> TimeInterval? = { nil },
    livePreviewProvider: @escaping () -> LivePreviewDisplay,
    onContentHeightChange: @escaping (CGFloat) -> Void = { _ in },
    usesPreviewLayout: Bool = false,
    lockState: OverlayLockState,
    noticeState: OverlayNoticeState,
    initialPreview: LivePreviewDisplay = .off
  ) {
    self.audioLevelProvider = audioLevelProvider
    self.recordingElapsedProvider = recordingElapsedProvider
    self.livePreviewProvider = livePreviewProvider
    self.onContentHeightChange = onContentHeightChange
    self.usesPreviewLayout = usesPreviewLayout
    self.lockState = lockState
    self.noticeState = noticeState
    _preview = State(initialValue: initialPreview)
  }

  /// #2202: the preview pill's header — timer hard left, live meter beside it,
  /// recording mode on the right.
  ///
  /// **The badge buys CLARITY, not height stability — the first version of this
  /// comment claimed the wrong thing.** It said the capsule's 2x mark was "the
  /// single biggest height jump anywhere in the pill". It is not a height jump at
  /// all: `scaleEffect` is a rendering transform and does not participate in
  /// layout. Measured — an `HStack` holding a 24pt box reports `fittingSize`
  /// 95x44 at `scaleEffect(1.0)` and 95x44 at `scaleEffect(2.0)`. The capsule is
  /// already height-neutral across modes; the 2x mark overflows its own slot
  /// visually and nothing resizes.
  ///
  /// What the badge actually fixes: a size change is a signal you can only read
  /// by COMPARISON — you notice it only if you saw the other size a moment
  /// earlier — while a badge naming the mode works the first time you see it.
  /// This header is height-neutral across modes too, which is a property to KEEP
  /// rather than one this chunk introduces.
  ///
  /// **The timer renders in both modes.** The capsule hides it when locked, which
  /// is backwards: hands-free is the mode that runs for minutes, so it is the one
  /// that needs a clock. Founder decision, 2026-08-19.
  @ViewBuilder
  private var previewHeader: some View {
    HStack(spacing: 12) {
      Text(FormattingConstants.formatDuration(elapsed))
        .font(.system(size: 13, weight: .semibold, design: .monospaced))
        .foregroundStyle(PreviewPillPalette.timer)

      RainbowLevelMeter(audioLevel: audioLevel, tick: audioTick)

      Spacer(minLength: 8)

      if lockState.isLocked {
        // A filled badge, because the mode it announces persists until the user
        // presses again. A size change is a weak signal — you only notice it if
        // you saw the other size a second earlier.
        HStack(spacing: 6) {
          Circle()
            .fill(PreviewPillPalette.badgeText)
            .frame(width: 5, height: 5)
          Text(LivePreviewCopy.handsFreeMode)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(PreviewPillPalette.badgeText)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(PreviewPillPalette.badgeFill))
        .transition(.opacity)
      } else {
        Text(LivePreviewCopy.listeningMode)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(PreviewPillPalette.modeQuiet)
          .transition(.opacity)
      }
    }
    .textCase(.uppercase)
    .padding(.horizontal, 16)
    .padding(.top, 9)
    .padding(.bottom, 8)
    .frame(height: Self.previewHeaderHeight)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(PreviewPillPalette.divider)
        .frame(height: 0.5)
    }
  }

  /// Fixed, so the header cannot change height between modes. Read by a test.
  static let previewHeaderHeight: CGFloat = 34

  var body: some View {
    // #2202 row 1 of the shared-root table: the capsule wants 6pt between its
    // stacked pieces; the preview puts a ruled header directly against its
    // reading well and supplies its own spacing inside each section.
    VStack(spacing: usesPreviewLayout ? 0 : 6) {
      if usesPreviewLayout {
        previewHeader
      } else {
        HStack(spacing: 10) {
          // Rainbow lips icon — audio-reactive during recording.
          // Scales to 2x in hands-free (locked) mode.
          RainbowLipsIcon(size: 24, audioLevel: audioLevel)
            .scaleEffect(lockState.isLocked ? 2.0 : 1.0)

          if !lockState.isLocked {
            Text(FormattingConstants.formatDuration(elapsed))
              .font(.system(size: 13, weight: .medium, design: .monospaced))
              .foregroundStyle(.white)
              .transition(.opacity)
          }
        }
      }

      // #1988: the live preview. Display only — the pasted text comes from the
      // normal transcription path after the key is released.
      livePreviewBody

      // #1060: approaching-cap warning banner. Appears inside the same capsule
      // (no panel rebuild), wraps within the pill width, auto-clears.
      if let notice = noticeState.message {
        Text(notice)
          .font(.system(size: 11, weight: .medium))
          // #2204: the notice is rendered by BOTH layouts from this one `Text`,
          // and white is invisible on a light pill. Gated rather than made
          // dynamic, so the capsule's paint is unchanged to the byte.
          .foregroundStyle(
            usesPreviewLayout ? PreviewPillPalette.notice : Color.white.opacity(0.95)
          )
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          // 170pt suits the 185pt capsule. The preview pill is 400pt wide, so the
          // same cap would wrap a one-line warning into three inside a box with
          // room to spare.
          .frame(maxWidth: usesPreviewLayout ? .infinity : 170)
          // #2202 row 4 of the shared-root table. The notice is rendered by BOTH
          // layouts and its ONLY inset came from the shared root padding, which
          // the preview now zeroes — so without this it sits flush against the
          // pill's bottom edge. The header and the reading well each received
          // replacement padding; this is the third section and it was missed.
          .padding(.horizontal, usesPreviewLayout ? 16 : 0)
          .padding(.bottom, usesPreviewLayout ? 12 : 0)
          .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.3), value: lockState.isLocked)
    // Single container animation prevents animation stacking: N per-element
    // modifiers × update rate creates exponential state transitions (gotchas.md).
    //
    // #2201: the PREVIEW layout selects no animation here. `audioLevel` is
    // repolled every 50 ms, so this fires ~20 times a second, and a container
    // animation animates whatever else changed in the same update — including the
    // preview text, and therefore the capsule's HEIGHT. That turned each genuine
    // resize into a smoothly animated one and drove `setFrame` once per frame.
    //
    // The trigger VALUE is kept rather than deleted, so the non-preview capsule's
    // animation is visibly untouched in the diff and the two branches sit side by
    // side. Audio-reactive PAINT is unaffected in both: `RainbowLipsIcon` reads
    // `audioLevel` directly and redraws without needing this.
    //
    // Not a violation of swift-patterns.md RULE: animate-the-container-not-children
    // — that forbids per-child `.animation(value:)`, and this adds none. The
    // container keeps its `lockState` and `noticeState` triggers in both layouts.
    .animation(
      usesPreviewLayout ? nil : .easeOut(duration: 0.08),
      value: audioLevel
    )
    .animation(.easeInOut(duration: 0.25), value: noticeState.message)
    // #2202 row 8 of the shared-root table. The capsule keeps its uniform inset;
    // the preview zeroes it and each section supplies its own, because a header
    // strip over a reading well does not want one rectangle of padding wrapped
    // around both. Migrated ATOMICALLY with the section padding above and below:
    // split across two commits, whatever shipped in between would have had no
    // insets at all.
    .padding(.horizontal, usesPreviewLayout ? 0 : 14)
    .padding(.vertical, usesPreviewLayout ? 0 : 10)
    // #2201: the preview pill's height must be a function of what it is SHOWING,
    // never of how tall it happens to be already.
    //
    // Without this the capsule is free to stretch into whatever room the panel
    // offers, because `previewText`'s `.frame(maxHeight:)` grows to its cap under
    // a large proposal. The panel is then sized FROM that measurement
    // (`onContentHeightChange` -> resizeRecordingPanel) while the measurement is
    // taken INSIDE the panel, so the pair has no single solution: measured on the
    // real view, one line of text reported 65pt in a 65pt panel and 125pt in a
    // 125pt one. Nothing in the loop pulls the height back down either, so a box
    // that grew for a long sentence stayed at the cap when the recognizer revised
    // the sentence shorter.
    //
    // `fixedSize` makes the stack report its IDEAL height whatever it is offered,
    // which is the same question `showPanel(fitToContent:)` asks at creation — so
    // the two sizing paths finally agree. Growth is unaffected: the ideal height
    // still tracks the text (65 -> 80 -> 125 across one, three and six-plus lines).
    //
    // **Gated, because every modifier on this root is rendered by BOTH layouts.**
    // The 185pt capsule sits inside a fixed 92pt frame and is out of scope for
    // #2198; `vertical: false` leaves it exactly as it was.
    //
    // **Order is load-bearing:** after both paddings, before both backgrounds. The
    // measurement is taken on the padded stack, so moving this either side of it
    // measures a different view than the one that was proven.
    .fixedSize(horizontal: false, vertical: usesPreviewLayout)
    .background(OverlayCapsuleBackground(cornerStyle: usesPreviewLayout ? .rounded : .capsule))
    // #1988: report the capsule's real height so the panel can follow it. Measured
    // on the capsule rather than computed from a line count, because only the text
    // engine knows how many lines a sentence wraps to at this width in this script.
    .background(
      GeometryReader { geo in
        Color.clear
          .onAppear { onContentHeightChange(geo.size.height) }
          .onChange(of: geo.size.height) { _, height in onContentHeightChange(height) }
      }
    )
    .task {
      while !Task.isCancelled {
        audioLevel = audioLevelProvider()
        audioTick &+= 1
        elapsed = recordingElapsedProvider() ?? 0
        preview = livePreviewProvider()
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }

  /// The preview area.
  ///
  /// **The tail is produced by `.truncationMode(.head)`, not by counting characters
  /// and not by clipping an oversized box.** A character budget is a guess about how
  /// many glyphs fit, and that guess is wrong by a factor of two for CJK and wrong
  /// again for any proportional font. Clipping was tried first and shipped two
  /// visible defects that a screenshot caught immediately: `fixedSize` makes a Text
  /// render at its ideal height regardless of the frame around it, so three lines of
  /// text spilled out of the capsule background entirely and the top line was sliced
  /// through the middle of its glyphs. Letting the text engine drop the head gives
  /// the same "newest words win" result, correct in every script, with a leading
  /// ellipsis that reads as continuation rather than as a rendering fault.
  @ViewBuilder
  private var livePreviewBody: some View {
    switch preview {
    case .off:
      EmptyView()
    case .waiting:
      // One line, so the pill starts compact and the growth the user sees is their
      // own words arriving rather than space that was always reserved.
      //
      // #2202: in the PREVIEW layout the header already says `Listening`, so
      // repeating it here would greet a first-time user with the same word twice
      // in one small box — worse than either alone. The well shows nothing and
      // the pill stays one header tall until real words arrive. The capsule has
      // no header, so it keeps the sentence.
      //
      // #2222: `EmptyView()`, NOT `previewText("")`. An empty string still built a
      // `PreviewWellText`, which applies the well's own 12/15pt inset and an empty
      // `Text`'s line box unconditionally — so the state documented above as "one
      // header tall" measured 75pt against the header's 34pt, three points short of
      // a pill with words in it. Every dictation passes through here before the
      // first word, so every user saw the pill resize before saying anything.
      //
      // The inset lives on `PreviewWellText` and is correct for every state that
      // HAS a well; the defect was asking for a well to hold nothing. Fixed at the
      // call site rather than by making the shared padding conditional, which would
      // put an emptiness test inside a view that should not care.
      if usesPreviewLayout {
        EmptyView()
      } else {
        previewText(LivePreviewCopy.listening, dimmed: true, lines: 1)
      }
    case .unavailable(let reason):
      // Say why rather than sitting blank. A blank preview reads as "it did not
      // hear me", which is the exact anxiety this feature exists to remove. Two
      // lines because some of these sentences wrap.
      previewText(reason, dimmed: true, lines: 2)
    case .text(let text):
      previewText(text, dimmed: false, lines: Self.previewMaxLines)
    }
  }

  /// One builder for all three states, so the pill cannot change alignment as it
  /// moves between "Listening...", real words, and a reason it cannot run.
  ///
  /// **No fixed height.** The text takes exactly the lines it needs, the capsule
  /// grows with it, and the panel follows via `onContentHeightChange`. At the cap
  /// the text keeps laying out in full but the box stops growing and pins the text
  /// to its BOTTOM, so the overflow leaves at the top and the newest words stay
  /// where the eye already is.
  ///
  /// **`.lineLimit(n)` + `.truncationMode(.head)` does NOT do this, despite
  /// reading as though it should.** Measured by rendering this exact modifier
  /// stack over 60 numbered words: it keeps the OLDEST four lines and truncates
  /// only the LAST one, so a long dictation showed `word1...word32`, then a jump
  /// to `...word53 word60` — the middle silently gone and four fifths of the pill
  /// frozen on the opening words. Review caught it; the screenshot that had
  /// "verified" the behaviour showed a transcript at exactly five lines, which
  /// never exercises overflow at all.
  ///
  /// Bottom-pinned clipping is the literal reading of "scrolls off the top", and
  /// needs no ScrollView (which brings scrollers, elasticity and its own
  /// scroll-to-bottom timing into a borderless overlay) and no manual text
  /// measurement.
  private func previewText(_ message: String, dimmed: Bool, lines: Int) -> some View {
    PreviewWellText(
      message: message, dimmed: dimmed, lines: lines, usesPreviewLayout: usesPreviewLayout)
  }

  /// #2203: ONE authority for preview typography. The `Text` and the cap both read
  /// these, so a change to the type size cannot leave the two disagreeing.
  ///
  /// **The previous version's doc comment claimed the cap "tracks the type size"
  /// and it did not.** It built `NSFont.systemFont(ofSize: 12)` from its own
  /// hardcoded 12, independent of the `Text`'s own `.font(.system(size: 12))`
  /// twenty lines away. Two literals that had to agree, with a comment asserting
  /// they could not drift — which is worse than no comment, because it stops the
  /// next reader checking.
  static let previewFontSize: CGFloat = 14
  static let previewLineSpacing: CGFloat = 4

  /// #2203: how much of the reading well's height the top fade occupies.
  ///
  /// Deliberately small. The fade exists to say "there is more above this", not to
  /// hide a line — at the cap the oldest visible line is still readable, just
  /// clearly on its way out. A larger value starts costing the user words they
  /// have not finished reading.
  static let previewFadeFraction: CGFloat = 0.22

  /// Height of `lines` lines of the preview font, INCLUDING the gaps between them.
  ///
  /// **Counting the gaps is not a refinement, it is the difference between five
  /// lines and four.** SwiftUI adds `lineSpacing` BETWEEN lines, so five lines
  /// occupy five glyph heights plus four gaps. A cap that counts only the glyphs
  /// under-measures by 4 x `previewLineSpacing` and clips the fifth line partway.
  ///
  /// An exact multiple still matters: the clip lands on a line boundary, so no row
  /// is cut through the middle of its glyphs.
  static func previewHeight(lines: Int) -> CGFloat {
    let font = NSFont.systemFont(ofSize: previewFontSize)
    let glyphHeight = ceil(font.ascender - font.descender + font.leading)
    let gaps = max(lines - 1, 0)
    return glyphHeight * CGFloat(lines) + previewLineSpacing * CGFloat(gaps)
  }

  /// Five lines, matching the shape the founder tested against Spokenly: the pill
  /// grows a line at a time up to this, then holds its size and scrolls.
  static let previewMaxLines = 5
}

/// #2203: the reading well's text, and the one part of the pill that has to know
/// whether it is FULL.
///
/// Split out of `RecordingOverlayView` only because the fade decision needs
/// `@State`, and a function returning a view cannot hold one.
struct PreviewWellText: View {
  let message: String
  let dimmed: Bool
  let lines: Int
  let usesPreviewLayout: Bool

  /// Whether the well is at its cap, and so whether anything is scrolling off the
  /// top. Written from a `GeometryReader` in the BACKGROUND of the capped frame,
  /// which does not participate in layout, and it feeds only the mask, which does
  /// not either — so it cannot reach the panel-resize loop #2201 settled.
  /// `RecordingOverlayPreviewSizingTests` is the check on that claim rather than
  /// this sentence.
  @State private var wellIsFull = false

  private var cap: CGFloat { RecordingOverlayView.previewHeight(lines: lines) }

  var body: some View {
    Text(message)
      .font(.system(size: RecordingOverlayView.previewFontSize))
      .lineSpacing(RecordingOverlayView.previewLineSpacing)
      .foregroundStyle(
        usesPreviewLayout
          ? (dimmed ? PreviewPillPalette.textDimmed : PreviewPillPalette.text)
          : .white.opacity(dimmed ? 0.5 : 0.92)
      )
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      // `maxHeight` CAPS without fixing: below the cap the box is the text's own
      // height, which is what lets the pill still grow a line at a time.
      .frame(maxHeight: cap, alignment: .bottom)
      .background(
        GeometryReader { geo in
          Color.clear
            .onAppear { updateFullness(geo.size.height) }
            .onChange(of: geo.size.height) { _, height in updateFullness(height) }
        }
      )
      .clipped()
      // #2203: fade the top edge ONLY when something is actually above it.
      //
      // **Cloud review caught this applying unconditionally.** The capped frame
      // takes the TEXT's height while the text is short, so the gradient mapped
      // onto the first line of a one-line transcript and dimmed words the user
      // still had to read. A fade means "there is more above this"; saying that
      // when there is not is worse than not saying it at all.
      //
      // Doing it with a mask rather than per-line opacity remains the point:
      // dimming older LINES needs to know where the text engine broke them, which
      // is the knowledge this file records as unavailable — a character budget is
      // wrong by 2x for CJK and wrong again for any proportional font. A gradient
      // needs no line information and behaves identically in every script, because
      // older words are higher up by construction.
      //
      // KNOWN LIMIT, recorded rather than hidden: a transcript landing at EXACTLY
      // the cap fades slightly with nothing yet above it. Separating that from a
      // genuine overflow needs the text's unclipped intrinsic height, which costs a
      // second layout of the same string for a one-frame cosmetic difference at the
      // moment the well is about to overflow anyway.
      .mask(fadeMask)
      // #2202: the well's own inset, replacing what the shared root padding used
      // to give it. **Outside the cap, deliberately.** Padding inserted before
      // `.frame(maxHeight:)` is subtracted from the five-line viewport, so the
      // box would clip at four-and-a-bit lines and the founder's five-line rule
      // would quietly stop holding — a number that looks like it means lines
      // while meaning something else.
      .padding(.horizontal, usesPreviewLayout ? 16 : 0)
      .padding(.top, usesPreviewLayout ? 12 : 0)
      .padding(.bottom, usesPreviewLayout ? 15 : 0)
  }

  @ViewBuilder
  private var fadeMask: some View {
    if usesPreviewLayout && wellIsFull {
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0),
          .init(color: .white, location: RecordingOverlayView.previewFadeFraction),
          .init(color: .white, location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom)
    } else {
      Rectangle()
    }
  }

  /// The capped frame reports the TEXT's height below the cap and the CAP once the
  /// text exceeds it, so "is it at the cap" is the overflow signal without
  /// measuring the string ourselves.
  private func updateFullness(_ height: CGFloat) {
    let full = Self.wellIsFull(measuredHeight: height, cap: cap)
    if full != wellIsFull { wellIsFull = full }
  }

  /// The fade decision, extracted so it can be asserted directly.
  ///
  /// A mask does not participate in layout, so no height test can see whether the
  /// fade is applied — the same reason `RecordingOverlayPanel`'s inherited-geometry
  /// arithmetic is pinned as a pure function rather than driven through a panel.
  /// Cloud review found this applying unconditionally; a decision worth fixing is
  /// worth pinning.
  ///
  /// The half-point tolerance absorbs the rounding between a laid-out frame and a
  /// computed cap. Without it a well that is full to the pixel reports empty and
  /// the fade flickers off at exactly the moment it is needed.
  static func wellIsFull(measuredHeight: CGFloat, cap: CGFloat) -> Bool {
    measuredHeight >= cap - 0.5
  }

}

// MARK: - PolishingOverlayView

/// Compact polishing indicator overlay shown during LLM processing.
struct PolishingOverlayView: View {
  var label: String

  var body: some View {
    HStack(spacing: 10) {
      // Spinning spectrum wheel icon — polishing/processing state
      SpectrumWheelIcon(size: 24)

      // #1064: single line that hugs its content. The panel is sized to this
      // view's fittingSize (showPanel `fitToContent`), so short labels
      // ("Polishing...", "Transcribing...") stay compact and the long 60-minute
      // cap-end message gets exactly the width it needs — never clipped, never
      // stranded in empty space (the #1060 fixed-frame regression).
      Text(label)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(OverlayCapsuleBackground())
  }
}

// MARK: - ColdStartNoticeView

/// Cold-boot warm-up pill (#879). Two uses, driven by `icon`:
/// - `.spinner` — "getting ready" while the engine warms after a cold boot.
/// - `.ready` — the "ready, press to dictate" announcement.
///
/// Both convey state with a shape (spinning wheel / checkmark) plus text, never
/// color alone (accessibility-noncolor). An optional `subtitle` renders a
/// dimmer secondary line (e.g. which engine is warming).
struct ColdStartNoticeView: View {
  enum Icon {
    case spinner
    case ready
  }

  let title: String
  var subtitle: String?
  let icon: Icon

  var body: some View {
    HStack(spacing: 10) {
      switch icon {
      case .spinner:
        SpectrumWheelIcon(size: 24)
      case .ready:
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(Color(red: 0.2, green: 0.82, blue: 0.45))
          .font(.system(size: 18))
          .accessibilityHidden(true)
      }

      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.white)
          .lineLimit(1)
        if let subtitle {
          Text(subtitle)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.white.opacity(0.65))
            .lineLimit(1)
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(OverlayCapsuleBackground())
  }
}

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

/// Bulk-import-enrichment start/finish pill (#1701 Chunk 2). Mirrors
/// `NotificationOverlayView`'s shell with a neutral status icon — this is
/// neither an error nor a warning, so it does not borrow `NotificationStyle`.
struct ImportStatusOverlayView: View {
  let message: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "arrow.triangle.2.circlepath")
        .foregroundStyle(.white)
        .font(.system(size: 16))
      Text(message)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 280, alignment: .leading)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(OverlayCapsuleBackground())
  }
}

// MARK: - AccessibilityToastView

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

// MARK: - AccessibilityToastView

struct AccessibilityToastView: View {
  let onGrant: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "lock.shield.fill")
        .foregroundStyle(.orange)
        .font(.system(size: 16))
      Text(DictationNarrator.accessibilityToastText)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
      Spacer(minLength: 8)
      Button(action: onGrant) {
        Text("Grant")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 12)
          .padding(.vertical, 4)
          .background(Capsule().fill(Color.orange.opacity(0.85)))
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(OverlayCapsuleBackground())
  }
}

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
