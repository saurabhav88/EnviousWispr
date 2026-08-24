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
/// First, the overlay's view layer was one large file and the pill's colours were
/// scattered through it as literals. That file is gone — #2374 Phase 2 split it into
/// focused files under `App/Overlay/Views/` — but the reason survives the split:
/// the preview pill's own colours would otherwise be spread across
/// `RecordingOverlayView.swift` and `OverlayCapsuleBackgrounds.swift`. Collecting
/// them makes "what does the preview pill look like" a question with one answer.
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

  // MARK: - The canonical collections
  //
  // **These live in the PALETTE, not in the test, and that is the structural half
  // of the fix.** Three review rounds ran on hand-written arrays in the test file
  // that had to be kept in step with the declarations here; each round pinned one
  // array and left a sibling. Two files that must agree is the defect. One file
  // that lists its own members can still be wrong, but it is wrong where the
  // declaration is, in the reader's eye, rather than three hundred lines away in
  // another target.
  //
  // A colour belongs to exactly one of these. `allColours` is their sum and is
  // what a test iterates.

  /// Colours that draw TEXT and therefore carry a contrast obligation.
  static let textColours: [(name: String, colour: Color)] = [
    ("timer", timer),
    ("modeQuiet", modeQuiet),
    ("badgeText", badgeText),
    ("text", text),
    ("textDimmed", textDimmed),
    ("notice", notice),
  ]

  /// Colours that do not draw text: surfaces, borders, fills.
  static let surfaceColours: [(name: String, colour: Color)] = [
    ("surface", surface),
    ("border", border),
    ("divider", divider),
    ("badgeFill", badgeFill),
  ]

  /// Every colour the pill draws.
  static let allColours: [(name: String, colour: Color)] = textColours + surfaceColours

  // KNOWN LIMIT, accepted at review round 6 rather than left to be rediscovered.
  //
  // **The name in each tuple is a string literal, not a binding to the declaration
  // it names.** Written as `("textDimmed", text)` by copy-paste, the parsed
  // declaration `textDimmed` still looks accounted for while the pair and contrast
  // tests exercise `text` twice and `textDimmed` never.
  //
  // It is not closable without reflection, a macro, or code generation. Swift
  // cannot enumerate static members at runtime, and a lookup-by-name accessor
  // (`static let surface = entries.first { $0.name == "surface" }!.colour`) trades a
  // compile-time-visible typo for a force-unwrap that crashes the app, or a silent
  // fallback colour — both worse than the hole.
  //
  // A distinctness check over resolved values would catch it, EXCEPT that
  // `modeQuiet` and `textDimmed` legitimately hold identical values today, so it
  // would false-positive on correct code. Changing one of them purely to enable a
  // test would be the tail wagging the dog.
  //
  // What bounds the risk: all ten entries sit in one screenful directly beneath the
  // declarations they name, so a mismatch is visible where it is written rather
  // than three hundred lines away in another target — which is what the round-5
  // restructure bought. The residual failure needs a copy-paste inside that
  // screenful, and costs one colour going unchecked.
  //
  // **Reopen this if a colour is ever added whose values duplicate another's for a
  // reason other than being the same colour** — at that point the distinctness
  // check becomes viable and should be preferred to this comment.

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
