import AppKit
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #2204: the preview pill follows the app's Appearance setting.
///
/// **The risk in this chunk is not that the pill looks wrong — it is that the
/// SEVEN other pills change.** `OverlayCapsuleBackground` has eight call sites and
/// only one is the preview; the others are the polishing pill, the cold-start
/// notice, the distress variant and four more, and they ship to everyone. The
/// preview ships OFF by default and is macOS 26+, so a leak reaches vastly more
/// users than the feature does. That asymmetry is why the capsule guard here is
/// stricter than the preview one.
@MainActor
@Suite(.tags(.productOutcome))
struct PreviewPillPaletteTests {

  init() { _ = NSApplication.shared }

  /// Every colour the pill draws. A new one added to the palette and forgotten
  /// here is the failure this list exists to make loud.
  nonisolated static let allPillColours: [(name: String, colour: Color)] = [
    ("surface", PreviewPillPalette.surface),
    ("border", PreviewPillPalette.border),
    ("divider", PreviewPillPalette.divider),
    ("timer", PreviewPillPalette.timer),
    ("modeQuiet", PreviewPillPalette.modeQuiet),
    ("badgeFill", PreviewPillPalette.badgeFill),
    ("badgeText", PreviewPillPalette.badgeText),
    ("text", PreviewPillPalette.text),
    ("textDimmed", PreviewPillPalette.textDimmed),
    ("notice", PreviewPillPalette.notice),
  ]

  // MARK: - The pair is real

  /// A colour that resolves the SAME in both appearances is one somebody forgot to
  /// pair — it compiles, it looks right in whichever theme they were testing, and
  /// it ships one theme's paint into the other.
  @Test("every pill colour actually differs between light and dark")
  func everyColourIsAPair() throws {
    for (name, colour) in Self.allPillColours {
      let light = try #require(
        PreviewPillPalette.resolved(colour, in: .aqua), "\(name) did not resolve in light")
      let dark = try #require(
        PreviewPillPalette.resolved(colour, in: .darkAqua), "\(name) did not resolve in dark")

      let same =
        abs(light.redComponent - dark.redComponent) < 0.001
        && abs(light.greenComponent - dark.greenComponent) < 0.001
        && abs(light.blueComponent - dark.blueComponent) < 0.001
        && abs(light.alphaComponent - dark.alphaComponent) < 0.001

      #expect(
        !same,
        """
        \(name) resolves identically in both appearances, so it was never paired. \
        It will ship one theme's paint into the other and look correct only in \
        whichever theme it was written in.
        """)
    }
  }

  // MARK: - Light is legible

  /// The pill floats over arbitrary windows, so it cannot borrow contrast from
  /// what is behind it. Text on surface has to carry itself.
  @Test("light text on the light surface clears a readable contrast ratio")
  func lightTextIsLegible() throws {
    let surface = try #require(PreviewPillPalette.resolved(PreviewPillPalette.surface, in: .aqua))
    let text = try #require(PreviewPillPalette.resolved(PreviewPillPalette.text, in: .aqua))
    let ratio = Self.contrastRatio(text, on: surface)
    #expect(
      ratio >= 4.5,
      "light text on the light surface is \(String(format: "%.1f", ratio)):1, below 4.5:1")
  }

  @Test("dark text on the dark surface clears a readable contrast ratio")
  func darkTextIsLegible() throws {
    let surface = try #require(
      PreviewPillPalette.resolved(PreviewPillPalette.surface, in: .darkAqua))
    let text = try #require(PreviewPillPalette.resolved(PreviewPillPalette.text, in: .darkAqua))
    let ratio = Self.contrastRatio(text, on: surface)
    #expect(
      ratio >= 4.5,
      "dark text on the dark surface is \(String(format: "%.1f", ratio)):1, below 4.5:1")
  }

  /// The notice is the colour that was hardcoded white and would have been
  /// invisible on a light pill. It carries a cap warning, so it is the one piece
  /// of copy in the box the user must not miss.
  @Test("the notice is legible in both appearances")
  func noticeIsLegibleInBoth() throws {
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      let surface = try #require(
        PreviewPillPalette.resolved(PreviewPillPalette.surface, in: appearance))
      let notice = try #require(
        PreviewPillPalette.resolved(PreviewPillPalette.notice, in: appearance))
      let ratio = Self.contrastRatio(notice, on: surface)
      #expect(
        ratio >= 4.5,
        "the notice is \(String(format: "%.1f", ratio)):1 in \(appearance.rawValue)")
    }
  }

  /// The pill is near-opaque on purpose: it sits over arbitrary windows and must
  /// not borrow its legibility from whatever happens to be behind it.
  @Test("the surface is opaque enough to carry its own contrast")
  func surfaceIsNearlyOpaque() throws {
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      let surface = try #require(
        PreviewPillPalette.resolved(PreviewPillPalette.surface, in: appearance))
      #expect(
        surface.alphaComponent >= 0.88,
        """
        the surface is \(surface.alphaComponent) alpha in \(appearance.rawValue). Below \
        about 0.88 the window behind it starts showing through the text.
        """)
    }
  }

  // MARK: - Contrast maths (WCAG relative luminance)

  private static func contrastRatio(_ a: NSColor, on b: NSColor) -> CGFloat {
    // The pill's colours carry alpha, so composite the foreground over the
    // background before measuring — a ratio taken on the raw values would flatter
    // every translucent colour in the palette.
    let composited = NSColor(
      srgbRed: a.redComponent * a.alphaComponent + b.redComponent * (1 - a.alphaComponent),
      green: a.greenComponent * a.alphaComponent + b.greenComponent * (1 - a.alphaComponent),
      blue: a.blueComponent * a.alphaComponent + b.blueComponent * (1 - a.alphaComponent),
      alpha: 1)
    let l1 = relativeLuminance(composited)
    let l2 = relativeLuminance(b)
    return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
  }

  private static func relativeLuminance(_ c: NSColor) -> CGFloat {
    func channel(_ v: CGFloat) -> CGFloat {
      v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent)
      + 0.0722 * channel(c.blueComponent)
  }
}
