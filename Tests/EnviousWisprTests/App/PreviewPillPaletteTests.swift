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

  /// **Read from the palette, never re-listed here.** Three review rounds ran on
  /// hand-written copies of these lists in this file; each fix pinned one array and
  /// left a sibling, and the last round found that comparing NAMES cannot catch a
  /// tuple whose colour reference is wrong. Two files that must agree is the defect,
  /// so there is now one file and this one reads it.
  nonisolated static var allPillColours: [(name: String, colour: Color)] {
    PreviewPillPalette.allColours
  }

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

  /// Read from the palette. See `allPillColours`.
  nonisolated static var textColours: [(name: String, colour: Color)] {
    PreviewPillPalette.textColours
  }

  @Test(
    "every text colour clears 4.5:1 on the pill surface, in both appearances",
    arguments: PreviewPillPaletteTests.textColours)
  func everyTextColourIsLegible(entry: (name: String, colour: Color)) throws {
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      let surface = try #require(
        PreviewPillPalette.resolved(PreviewPillPalette.surface, in: appearance))
      let fg = try #require(PreviewPillPalette.resolved(entry.colour, in: appearance))
      let ratio = Self.contrastRatio(fg, on: surface)
      #expect(
        ratio >= 4.5,
        """
        \(entry.name) is \(String(format: "%.2f", ratio)):1 against the pill surface in \
        \(appearance.rawValue), below the 4.5:1 floor. The pill floats over arbitrary \
        windows, so it cannot borrow contrast from what is behind it.
        """)
    }
  }

  /// **Every colour the palette declares is either checked for contrast or named
  /// as a non-text colour. Nothing can be silently omitted.**
  ///
  /// Cloud review caught the previous version claiming set-wide protection while
  /// using a hand-maintained array: a token added to `PreviewPillPalette` and
  /// forgotten here would leave every contrast test passing, repeating the exact
  /// omission that missed `modeQuiet` and `textDimmed` in the first place. A list
  /// I maintain by hand cannot protect against me forgetting to maintain it.
  ///
  /// Swift cannot enumerate static members at runtime, so the palette's own source
  /// is the only authority available — the same mechanism
  /// `LivePreviewSettingsCopyTests.everyCopyPropertyIsCovered` uses, and for the
  /// same reason.
  @Test("every colour in the palette reaches BOTH hand-written arrays")
  func everyPaletteColourIsAccountedFor() throws {
    let url = RepoRoot.url.appending(
      path: "Sources/EnviousWisprAppKit/App/PreviewPillPalette.swift")
    let source = try String(contentsOf: url, encoding: .utf8)

    // **Whole-source match, not line-by-line.** Review round 5: a declaration
    // formatted as `static let futureLabel =` with `Color.stDynamic(...)` on the
    // NEXT line was silently skipped by a per-line regex, and the ten existing
    // declarations still cleared the count floor — so a colour could be absent
    // from every collection while this check passed. That is the same shape as
    // every other finding on this file: a comparison narrower than the language.
    let pattern = #"static\s+let\s+(\w+)\s*(?::\s*Color\s*)?=\s*Color\s*\.\s*stDynamic"#
    let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    let ns = source as NSString
    let declared = regex
      .matches(in: source, range: NSRange(location: 0, length: ns.length))
      .map { ns.substring(with: $0.range(at: 1)) }

    // Fail closed: a parse that finds nothing would make every check below vacuous.
    #expect(
      declared.count >= 10,
      "parsed only \(declared.count) colours out of PreviewPillPalette.swift — the reader is wrong, not the palette")

    // The palette's own collections must account for every declaration. This is
    // now the ONLY hand-written mapping in the system, it lives beside the
    // declarations it lists, and nothing in the test target duplicates it.
    let paired = Set(Self.allPillColours.map(\.name))
    let missingFromPairing = Set(declared).subtracting(paired).sorted()
    #expect(
      missingFromPairing.isEmpty,
      """
      \(missingFromPairing.joined(separator: ", ")) are declared in PreviewPillPalette \
      but absent from `allColours`, so they are never checked for a light/dark pair \
      or for contrast. A colour resolving the same in both themes would ship one \
      theme's paint into the other and nothing would notice.
      """)

    let stalePairing = paired.subtracting(Set(declared)).sorted()
    #expect(
      stalePairing.isEmpty,
      "\(stalePairing.joined(separator: ", ")) are in `allColours` but no longer declared")

    // The palette's two collections must PARTITION the declarations: every colour
    // is text or surface, never both, never neither. `allColours` is their sum, so
    // the check above already covers "neither" — this covers "both", which would
    // make a surface colour carry a contrast obligation it cannot meet.
    let textNames = Set(PreviewPillPalette.textColours.map(\.name))
    let surfaceNames = Set(PreviewPillPalette.surfaceColours.map(\.name))
    let inBoth = textNames.intersection(surfaceNames).sorted()
    #expect(
      inBoth.isEmpty,
      "\(inBoth.joined(separator: ", ")) appear in BOTH textColours and surfaceColours")

    #expect(
      textNames.count + surfaceNames.count == Self.allPillColours.count,
      """
      the two collections hold \(textNames.count) + \(surfaceNames.count) names but \
      allColours has \(Self.allPillColours.count) entries — a duplicate inside one of \
      them would silently drop a colour from these set comparisons.
      """)
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
