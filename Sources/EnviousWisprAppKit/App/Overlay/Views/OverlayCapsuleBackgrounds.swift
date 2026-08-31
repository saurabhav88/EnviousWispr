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
        .opacity(
          animatesGlow && cornerStyle == .capsule ? glowOpacity : Self.steadyGlowOpacity
        )
        .padding(.horizontal, 20)
        .offset(y: -1)
      }
      .onAppear {
        // #2201: only the capsule breathes. Arming a `repeatForever` for the
        // preview would keep it re-rendering whether or not anything read
        // `glowOpacity`, and the point of this chunk is that the preview pill
        // stops moving on its own.
        guard animatesGlow, cornerStyle == .capsule else { return }
        withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
          glowOpacity = 0.65
        }
      }
      .accessibilityHidden(true)
  }
}

// MARK: - DistressCapsuleBackground

/// Capsule background for interruption warnings: red glow instead of rainbow.
struct DistressCapsuleBackground: View {
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
