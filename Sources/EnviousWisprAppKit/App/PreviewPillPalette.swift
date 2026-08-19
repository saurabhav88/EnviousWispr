import AppKit
import SwiftUI

/// #2204: every colour the live preview pill draws, as a light/dark pair.
///
/// The pill was permanently dark. The founder's decision (2026-08-19) is that it
/// follows the app's Appearance setting — System, Light or Dark — like the rest of
/// the app.
///
/// ## Why these live here and not inline
///
/// Two reasons, and the second is the load-bearing one.
///
/// First, `RecordingOverlayPanel.swift` is ~3,000 lines and the pill's colours
/// were scattered through it as literals. Collecting them makes "what does the
/// preview pill look like" a question with one answer.
///
/// Second, and this is the isolation the whole epic turns on: **every modifier on
/// `RecordingOverlayView`'s root is rendered by BOTH the preview pill and the
/// protected 185pt capsule**, and `OverlayCapsuleBackground` has EIGHT call sites
/// of which only one is the preview. A colour that becomes dynamic in the wrong
/// place restyles the polishing pill, the cold-start notice, the distress variant
/// and four others — surfaces that ship to everyone, while the preview ships OFF
/// by default and is macOS 26+. **The leak direction is the dangerous one.**
/// Naming these `preview*` and reading them only from preview-gated branches makes
/// a leak visible at the call site rather than in a diff of colour literals.
///
/// ## The mechanism is the app's existing one
///
/// `Color.stDynamic` builds an `NSColor(name:)` whose resolver picks per
/// appearance at draw time; `AppearanceController` sets `NSApplication.shared
/// .appearance` from the user's preference. `BluetoothAwarenessCardView` is the
/// precedent INSIDE this same panel. A borderless `NSPanel` inherits
/// `NSApp.appearance` because `NSWindow.appearanceSource` defaults to `NSApp`, and
/// `showPanel` sets no override — **do not add one**, it would pin the pill to a
/// single theme.
///
/// ## Light is not an inversion
///
/// The pill floats over whatever the user is looking at, so light-on-light and
/// dark-on-dark both happen. Both variants are near-opaque and carry their own
/// border and shadow rather than borrowing contrast from what is behind them. The
/// light surface is warm rather than pure white, matching the app's own
/// lavender-tinted page colour.
enum PreviewPillPalette {

  // MARK: - Surface

  /// The pill's own background. Deliberately more opaque than the capsule's 0.82:
  /// a translucent light panel over a white document disappears, and the preview
  /// pill is the one that carries text you have to read.
  static let surface = Color.stDynamic(
    lightRGB: (0.988, 0.980, 1.0, 0.94),
    darkRGB: (0.067, 0.059, 0.094, 0.90))

  /// The hairline around the pill. Light needs a real border because the surface
  /// alone does not separate it from a pale document.
  static let border = Color.stDynamic(
    lightRGB: (0.059, 0.039, 0.102, 0.14),
    darkRGB: (1.0, 1.0, 1.0, 0.13))

  /// The rule between the header and the reading well.
  static let divider = Color.stDynamic(
    lightRGB: (0.059, 0.039, 0.102, 0.10),
    darkRGB: (1.0, 1.0, 1.0, 0.09))

  // MARK: - Header

  /// Elapsed time. The one number in the pill, so it stays high-contrast.
  static let timer = Color.stDynamic(
    lightRGB: (0.133, 0.106, 0.200, 1.0),
    darkRGB: (1.0, 1.0, 1.0, 0.94))

  /// The quiet hold-to-talk state word.
  ///
  /// **0.60 in light, not the 0.45 that mirrors dark.** Cloud review measured the
  /// mirrored value at 3.10:1 against the light surface, below the 4.5:1 floor.
  /// Dark ink losing contrast as it fades toward a near-white ground is not
  /// symmetric with white text fading toward a near-black one, so a light palette
  /// built by mirroring dark's alphas is wrong wherever a colour is deliberately
  /// quiet. 0.60 measures 5.09:1.
  static let modeQuiet = Color.stDynamic(
    lightRGB: (0.059, 0.039, 0.102, 0.60),
    darkRGB: (1.0, 1.0, 1.0, 0.50))

  /// The hands-free badge's fill and its text.
  static let badgeFill = Color.stDynamic(
    lightRGB: (0.059, 0.039, 0.102, 0.09),
    darkRGB: (1.0, 1.0, 1.0, 0.13))
  static let badgeText = Color.stDynamic(
    lightRGB: (0.059, 0.039, 0.102, 0.72),
    darkRGB: (1.0, 1.0, 1.0, 0.88))

  // MARK: - Reading well

  /// Live words.
  static let text = Color.stDynamic(
    lightRGB: (0.059, 0.039, 0.102, 1.0),
    darkRGB: (1.0, 1.0, 1.0, 0.97))

  /// The dimmed states — "Listening", and the reasons the preview cannot run.
  ///
  /// **Dimmed does not mean optional here.** This renders `.unavailable`, which is
  /// a full sentence explaining WHY the preview is not running — read at exactly
  /// the moment the user is confused. Cloud review measured the mirrored 0.45 at
  /// 3.10:1 in light; 0.60 measures 5.09:1.
  static let textDimmed = Color.stDynamic(
    lightRGB: (0.059, 0.039, 0.102, 0.60),
    darkRGB: (1.0, 1.0, 1.0, 0.50))

  /// The #1060 notice banner.
  ///
  /// **This one is why the palette exists.** The notice is rendered by BOTH
  /// layouts from one `Text`, and its colour was a hardcoded white — invisible on
  /// a light pill. It has to be selected on `usesPreviewLayout` at the call site,
  /// with the capsule keeping `.white.opacity(0.95)` exactly.
  static let notice = Color.stDynamic(
    lightRGB: (0.059, 0.039, 0.102, 0.88),
    darkRGB: (1.0, 1.0, 1.0, 0.95))

  // MARK: - Test seam

  /// Resolve a pill colour against a named appearance, so a test can assert the
  /// pair actually differs rather than trusting that two literals were typed.
  ///
  /// A `Color` built from a dynamic `NSColor` reports nothing useful until it is
  /// resolved against an appearance, which is why this exists rather than a
  /// comparison of the `Color` values.
  static func resolved(_ color: Color, in appearance: NSAppearance.Name) -> NSColor? {
    let ns = NSColor(color)
    var out: NSColor?
    NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
      out = ns.usingColorSpace(.sRGB)
    }
    return out
  }
}
