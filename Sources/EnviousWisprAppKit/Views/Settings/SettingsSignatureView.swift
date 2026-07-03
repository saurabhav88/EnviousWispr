import SwiftUI

// MARK: - Settings signature

/// The brand signature on the AI Polish page: the rainbow waveform (reused from
/// the recording HUD, UNMODIFIED) held at a pleasing open frame over a soft
/// static luminous aurora. #1299.
///
/// Battery discipline (a speed-and-battery product): this signature is STATIC —
/// zero animation, zero ongoing CPU. A *breathing* animated variant was built
/// and measured behind a council-hardened AppKit occlusion gate (it correctly
/// dropped to 0% CPU when the window was hidden/occluded/minimized), but its
/// visible-state cost was ~30% CPU in a debug build — far too high for a
/// decorative element on a product that sells speed. Per the plan's battery-
/// safety-wins fallback, the animation is NOT shipped; the founder decides
/// whether to invest in optimizing it, with those numbers in hand. The full
/// gate design lives in docs/feature-requests/issue-1299-*.
struct SettingsSignatureView: View {
  @Environment(\.colorSchemeContrast) private var contrast

  /// Fixed, pleasing level for the waveform (lips gently open).
  private let restingLevel: Float = 0.34

  var body: some View {
    ZStack {
      aurora
      RainbowLipsIcon(size: 92, audioLevel: restingLevel)
    }
    .frame(maxWidth: .infinity)
    .frame(height: 132)
    .accessibilityHidden(true)
  }

  // MARK: Aurora (static luminous)

  private var aurora: some View {
    // A soft brand-hued glow behind the waveform. Static: renders once, no
    // per-frame cost. Simplified (dropped) under Increase Contrast, where a
    // low-opacity multi-hue gradient reads as banding/glitch (#1299).
    Group {
      if contrast == .increased {
        Color.clear
      } else {
        ZStack {
          Circle()
            .fill(Color(red: 0.541, green: 0.169, blue: 0.886))
            .frame(width: 210, height: 210)
            .blur(radius: 70)
            .opacity(0.16)
            .offset(x: -70)
          Circle()
            .fill(Color(red: 0.0, green: 0.9, blue: 1.0))
            .frame(width: 180, height: 180)
            .blur(radius: 70)
            .opacity(0.12)
            .offset(x: 80, y: 10)
          Circle()
            .fill(Color(red: 1.0, green: 0.4, blue: 0.55))
            .frame(width: 150, height: 150)
            .blur(radius: 70)
            .opacity(0.10)
            .offset(x: 10, y: -30)
        }
        .allowsHitTesting(false)
      }
    }
  }
}
