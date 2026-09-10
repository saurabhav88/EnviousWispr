import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import SwiftUI

// MARK: - OverlayCapsuleBackground

/// Shared capsule background with warmer dark fill, subtle border, and a
/// rainbow gradient line pulsing along the bottom edge.
struct OverlayCapsuleBackground: View {
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

  /// Whether the hairline breathes at all (#2435).
  ///
  /// **A still pill is a REQUIREMENT where this background is a picture rather
  /// than a live overlay**, and the Appearance picker draws three of them at
  /// once. Defaults to `true`, so all eight existing call sites are unchanged.
  var animatesGlow: Bool = true
  @State private var glowOpacity: Double = 0.3

  /// Outcome observer for the hairline's target opacity, called every time the loop is armed or
  /// parked. Production uses the no-op default; tests use it because an off-screen
  /// `NSHostingView` does not advance a `repeatForever`, so a re-arm cannot be seen in pixels.
  /// Same shape and same reason as `RainbowLevelMeter.onHistoryChange`.
  var onGlowTarget: (Double) -> Void = { _ in }

  /// #2303: the person's own answer, alongside #2201's and #2435's.
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.overlayReduceMotionOverride) private var reduceMotionOverride
  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

  /// Every condition for the hairline to breathe, in one place. `OverlayMotion` owns the
  /// Reduce Motion half and states why the still value costs nothing here.
  private var breathes: Bool {
    animatesGlow && cornerStyle == .capsule
      && OverlayMotion.showsAmbientLoop(reduceMotion: reduceMotion)
  }

  /// The loop's own two endpoints, named so the stop branch parks on the value the loop starts
  /// from rather than on a second opinion about what "dim" means.
  private static let dimGlowOpacity: Double = 0.3
  private static let brightGlowOpacity: Double = 0.65

  /// Bring the loop into line with `breathes`, in BOTH directions.
  ///
  /// The stop branch is not decoration. Nothing reads `glowOpacity` once `breathes` is false,
  /// so a loop left running would be invisible and would still re-render forever, which is the
  /// cost #2201 exists to avoid. Parking it also leaves a known value for the next arm.
  private func syncGlow() {
    guard breathes else {
      var stop = Transaction()
      stop.animation = nil
      withTransaction(stop) { glowOpacity = Self.dimGlowOpacity }
      onGlowTarget(Self.dimGlowOpacity)
      return
    }
    withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
      glowOpacity = Self.brightGlowOpacity
    }
    onGlowTarget(Self.brightGlowOpacity)
  }

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
  ///
  /// **#2435 widened it to every hairline that is not breathing, which is why it
  /// is no longer named for the preview.** A capsule drawn as a still picture in
  /// Settings would otherwise sit at `glowOpacity`'s initial 0.3 — the DIM
  /// ENDPOINT of a loop that is not running, which nobody chose and which shows
  /// the user a duller pill than the one they will get.
  private static let steadyGlowOpacity: Double = 0.5

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

  /// The nine brand spectrum colors, shared with anything else that draws the
  /// rainbow gradient (#2549: the mic-permission notice's left accent bar) so
  /// there is one list to keep in sync with `brand-guide`'s `--rainbow-full`,
  /// not a second hand-copied one.
  static let rainbowColors: [Color] = [
    Color(red: 1.0, green: 0.165, blue: 0.251),  // #ff2a40 red
    Color(red: 1.0, green: 0.549, blue: 0.0),  // #ff8c00 orange
    Color(red: 1.0, green: 0.843, blue: 0.0),  // #ffd700 yellow
    Color(red: 0.678, green: 1.0, blue: 0.184),  // #adff2f yellow-green
    Color(red: 0.0, green: 0.98, blue: 0.604),  // #00fa9a mint
    Color(red: 0.0, green: 1.0, blue: 1.0),  // #00ffff cyan
    Color(red: 0.118, green: 0.565, blue: 1.0),  // #1e90ff dodger blue
    Color(red: 0.255, green: 0.412, blue: 0.882),  // #4169e1 royal blue
    Color(red: 0.541, green: 0.169, blue: 0.886),  // #8a2be2 purple
  ]

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
          colors: [.clear] + Self.rainbowColors + [.clear],
          startPoint: .leading,
          endPoint: .trailing
        )
        .frame(height: 1)
        // Breathing is the ONLY case that reads the animated value. Everything
        // else — the reading well, and any capsule asked to hold still — takes
        // the chosen steady one.
        .opacity(breathes ? glowOpacity : Self.steadyGlowOpacity)
        .padding(.horizontal, 20)
        .offset(y: -1)
      }
      // #2201: only the capsule breathes. Arming a `repeatForever` for the
      // preview would keep it re-rendering whether or not anything read
      // `glowOpacity`, and the point of this chunk is that the preview pill
      // stops moving on its own.
      //
      // **Keyed to `breathes` rather than to `onAppear` (#2303, cloud review r1).** Reduce
      // Motion can be switched off while this pill is still mounted, and an `onAppear` guard
      // runs once: the loop would never arm, `glowOpacity` would sit at its dim starting
      // value, and the hairline would be DIMMER than in either state it is meant to have.
      // `initial: true` keeps the appear case, so this stays one mechanism rather than two.
      .onChange(of: breathes, initial: true) { _, _ in syncGlow() }
      .accessibilityHidden(true)
  }
}

// MARK: - DistressCapsuleBackground

/// Capsule background for interruption warnings: red glow instead of rainbow.
struct DistressCapsuleBackground: View {
  @State private var glowOpacity: Double = 0.3

  /// Outcome observer for the target opacity, armed or parked. Production uses the no-op
  /// default; the reason it exists is recorded on `OverlayCapsuleBackground.onGlowTarget`.
  var onGlowTarget: (Double) -> Void = { _ in }

  /// #2303. The red hairline pulses to draw the eye; the RED is what says something is wrong,
  /// and it survives holding still.
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.overlayReduceMotionOverride) private var reduceMotionOverride
  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

  /// Mid-point of this pulse's own 0.3-to-0.6 endpoints, for the same reason
  /// `OverlayCapsuleBackground.steadyGlowOpacity` is the mid-point of its loop: a still line is
  /// no dimmer on average than the moving one it replaces.
  private static let steadyGlowOpacity: Double = 0.45

  /// Whether the red hairline pulses at all.
  private var pulses: Bool { OverlayMotion.showsAmbientLoop(reduceMotion: reduceMotion) }

  /// The pulse's own two endpoints. Same reason as the rainbow hairline's pair above.
  private static let dimGlowOpacity: Double = 0.3
  private static let brightGlowOpacity: Double = 0.6

  /// Bring the pulse into line with `pulses`, in BOTH directions (#2303, cloud review r1).
  private func syncGlow() {
    guard pulses else {
      var stop = Transaction()
      stop.animation = nil
      withTransaction(stop) { glowOpacity = Self.dimGlowOpacity }
      onGlowTarget(Self.dimGlowOpacity)
      return
    }
    withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
      glowOpacity = Self.brightGlowOpacity
    }
    onGlowTarget(Self.brightGlowOpacity)
  }

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
        // The still value is chosen HERE rather than in the arming closure, so a person with
        // Reduce Motion on gets it on the FIRST frame — the same shape the rainbow hairline
        // above already uses.
        .opacity(pulses ? glowOpacity : Self.steadyGlowOpacity)
        .padding(.horizontal, 20)
        .offset(y: -1)
      }
      .onChange(of: pulses, initial: true) { _, _ in syncGlow() }
      .accessibilityHidden(true)
  }
}
