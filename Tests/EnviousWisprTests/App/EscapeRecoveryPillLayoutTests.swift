import AppKit
import Foundation
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// The cancel pill's geometry and its countdown colours (#2087, redesign
/// 2026-08-19).
///
/// Product Outcome throughout — each case finishes "when this fails, the user
/// sees ___" with something a person would notice on screen: a clipped
/// sentence, a pill hanging out of its panel, or a countdown that appears never
/// to start.
///
/// Deliberately NOT pixel assertions. Nothing here pins a colour to a value or a
/// width to a literal; every case states a RELATIONSHIP that has to hold however
/// the design is retuned, which is what lets the design keep moving.
@Suite(.tags(.productOutcome))
struct EscapeRecoveryPillLayoutTests {

  // MARK: - Geometry

  /// Hosts the cancel pill the way the learned-word test hosts its pill: one
  /// off-screen `NSHostingView`, layout flushed, size read from what SwiftUI
  /// laid out.
  @MainActor private func fittingSize(of face: EscapeRecoveryPillFace) -> CGSize {
    let host = NSHostingView(rootView: face)
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
  }

  @Test("The pill is wide enough for the sentence and the button word it renders")
  @MainActor func theSentenceAndButtonFitThePillTheyAreRenderedIn() {
    // Measured here from the fonts, independently of the view's own layout.
    let title = DictationNarrator.escapeRecoveryPillTitle as NSString
    let word = DictationNarrator.escapeRecoveryPillAction as NSString
    let sentence = ceil(
      title.size(
        withAttributes: [
          .font: NSFont.systemFont(ofSize: EscapeRecoveryPillMetrics.sentenceSize, weight: .medium)
        ]
      ).width)
    let button = ceil(
      word.size(
        withAttributes: [
          .font: NSFont.systemFont(ofSize: EscapeRecoveryPillMetrics.actionSize, weight: .semibold)
        ]
      ).width) + 2 * EscapeRecoveryPillMetrics.actionPaddingAcross

    let claimed =
      EscapeRecoveryPillMetrics.sidePadding + sentence + EscapeRecoveryPillMetrics.rowGap + button
      + EscapeRecoveryPillMetrics.sidePadding

    // Failing this renders "Dictation cance…", which the earlier fixed-width
    // pill did when the copy was revised.
    #expect(fittingSize(of: EscapeRecoveryPillFace(progress: 0, palette: .dark)).width >= claimed)
  }

  /// The pill is its row plus its own padding. Since #4675 the learned-word pill has its own card
  /// and size (founder kept this pill as it was; #3747's equal-height rule was retired), so this
  /// pill's geometry is pinned against ITS OWN parts: the height is the taller of the sentence and
  /// the button, plus the vertical padding on both sides, measured from the fonts and metrics
  /// independently of the view's layout. A change to this pill's metrics or row that moves its
  /// height fails here.
  @Test("The cancelled pill is exactly its row plus its own vertical padding")
  @MainActor func theCancelledPillKeepsItsOwnGeometry() {
    let cancelled = fittingSize(of: EscapeRecoveryPillFace(progress: 0, palette: .dark))
    let sentenceFont = NSFont.systemFont(
      ofSize: EscapeRecoveryPillMetrics.sentenceSize, weight: .medium)
    let actionFont = NSFont.systemFont(
      ofSize: EscapeRecoveryPillMetrics.actionSize, weight: .semibold)
    let sentenceHeight = ceil(sentenceFont.ascender - sentenceFont.descender + sentenceFont.leading)
    let buttonHeight =
      ceil(actionFont.ascender - actionFont.descender + actionFont.leading)
      + 2 * EscapeRecoveryPillMetrics.actionPaddingDown
    let claimed = 2 * EscapeRecoveryPillMetrics.verticalPadding + max(sentenceHeight, buttonHeight)

    #expect(cancelled.height > 0, "the cancelled pill did not lay out")
    #expect(
      abs(cancelled.height - claimed) <= 1.5,
      "cancelled \(cancelled.height) vs its row plus padding \(claimed)")
  }

  @Test("The cancelled pill's metrics are the values it shipped with")
  func theCancelledPillMetricsAreUnchanged() {
    // The numbers the pill had while it shared them with the learned-word pill (#3747), moved
    // under its own name for #4675 without a visual change.
    #expect(EscapeRecoveryPillMetrics.sentenceSize == 13)
    #expect(EscapeRecoveryPillMetrics.actionSize == 12)
    #expect(EscapeRecoveryPillMetrics.actionPaddingAcross == 12)
    #expect(EscapeRecoveryPillMetrics.actionPaddingDown == 4)
    #expect(EscapeRecoveryPillMetrics.rowGap == 10)
    #expect(EscapeRecoveryPillMetrics.sidePadding == 14)
    #expect(EscapeRecoveryPillMetrics.verticalPadding == 10)
  }

  @Test("The light and dark palettes lay out to the same size")
  @MainActor func theThemesShareOneSize() {
    // The palette changes colour only. A theme that changed the size would make
    // the pill jump when the Mac switches appearance.
    #expect(
      fittingSize(of: EscapeRecoveryPillFace(progress: 0, palette: .light))
        == fittingSize(of: EscapeRecoveryPillFace(progress: 0, palette: .dark)))
  }

  // MARK: - The countdown

  @Test("The rail is already visible the instant the pill appears")
  func theRailShowsASparkAtZero() {
    // At t=0 an untrimmed rail draws nothing, and the pill arrives looking like
    // its rim is broken. The spark must also stay unmistakably near the start;
    // a large floor makes a fresh three-second offer look almost expired.
    #expect(SpectralRail.drawnFraction(for: 0) > 0)
    #expect(SpectralRail.drawnFraction(for: 0) == SpectralRail.minimumSpark)
    #expect(SpectralRail.minimumSpark < 0.1)
  }

  @Test("The rail never asks for more path than exists")
  func theRailIsClampedAtBothEnds() {
    #expect(SpectralRail.drawnFraction(for: 1) == 1)
    #expect(SpectralRail.drawnFraction(for: 1.4) == 1)
    #expect(SpectralRail.drawnFraction(for: -3) == SpectralRail.minimumSpark)
    #expect(SpectralRail.drawnFraction(for: .nan) == SpectralRail.minimumSpark)
  }

  @Test("The rail advances with the time elapsed")
  func theRailIsMonotonic() {
    let samples = stride(from: 0.0, through: 1.0, by: 0.1).map {
      SpectralRail.drawnFraction(for: $0)
    }
    // Non-strict monotonicity allowed a rail pinned at 95% for almost the whole
    // dwell. Every tenth of the timer must visibly advance the countdown.
    #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 < $1 })
  }

  // MARK: - Legibility in both themes

  /// **The case that matters most here, and the one that caught a real defect.**
  ///
  /// The first light-theme attempt re-used the dark brand sequence. Six of its
  /// eleven colours fall under 3:1 on a white pill and the yellow head measured
  /// 1.55:1 — a countdown that a user on a light Mac would see as never
  /// starting. 3:1 is the WCAG floor for non-text content.
  @Test("Every countdown colour is visible on the pill it is drawn on")
  func bothSpectraClearTheContrastFloor() {
    let floor = 3.0

    for colour in PillSpectrum.dark {
      let ratio = contrastRatio(colour, PillSpectrum.darkGround)
      #expect(ratio >= floor, "dark spectrum colour at \(ratio) against the dark pill")
    }

    for colour in PillSpectrum.light {
      let ratio = contrastRatio(colour, PillSpectrum.lightGround)
      #expect(ratio >= floor, "light spectrum colour at \(ratio) against the light pill")
    }
  }

  @Test("The two themes do not share one sequence")
  func eachThemeHasItsOwnSpectrum() {
    // Not a style preference: the dark head is white, which is invisible on the
    // light pill. Collapsing these back to one array reintroduces exactly that.
    #expect(PillSpectrum.light != PillSpectrum.dark)
    #expect(contrastRatio(PillSpectrum.dark[0], PillSpectrum.lightGround) < 3.0)
  }

  /// **The gap Codex round 1 found, closed structurally.**
  ///
  /// The contrast cases measure against `PillSpectrum.darkGround` /
  /// `lightGround`. If the pill's actual fill is translucent, or simply drifts
  /// from those constants, every one of those cases keeps passing while
  /// measuring a ground that is not the one on screen — the guarantee would be
  /// bought without the cover. This pins the two together.
  @Test("The ground the contrast cases measure is the ground that renders")
  func theFillsAreOpaqueAndMatchTheMeasuredGround() {
    for (fill, ground, name) in [
      (PillPalette.dark.fill, PillSpectrum.darkGround, "dark"),
      (PillPalette.light.fill, PillSpectrum.lightGround, "light"),
    ] {
      guard let srgb = NSColor(fill).usingColorSpace(.sRGB) else {
        Issue.record("the \(name) pill fill could not be resolved in sRGB")
        continue
      }
      // Opaque, so nothing the pill floats over can change the ground.
      #expect(srgb.alphaComponent == 1.0, "the \(name) pill fill is translucent")
      #expect(abs(Double(srgb.redComponent) - ground.red) < 0.001)
      #expect(abs(Double(srgb.greenComponent) - ground.green) < 0.001)
      #expect(abs(Double(srgb.blueComponent) - ground.blue) < 0.001)
    }
  }

  @Test("Reduce Motion drops the decoration and keeps the countdown")
  func reduceMotionRemovesTheBloomOnly() {
    #expect(RailMotion.showsBloom(reduceMotion: false))
    #expect(!RailMotion.showsBloom(reduceMotion: true))

    // The rail still ADVANCES under Reduce Motion. Suppressing it would leave
    // those users no warning at all, and snapping it to full — which a nil
    // animation does — would claim the three seconds were already spent.
    #expect(SpectralRail.drawnFraction(for: 0.5) == 0.5)
  }

  @Test("The text is readable on the pill in both themes")
  func bothPalettesKeepTheSentenceLegible() {
    // 4.5:1 is the WCAG floor for body text, and the sentence is the whole
    // point of the pill.
    #expect(contrastRatio(PillPalette.dark.text, PillSpectrum.darkGround) >= 4.5)
    #expect(contrastRatio(PillPalette.light.text, PillSpectrum.lightGround) >= 4.5)
  }

  @Test("The scheme picks the matching palette")
  func schemeSelectsThePalette() {
    #expect(PillPalette.forScheme(.dark).spectrum == PillSpectrum.dark)
    #expect(PillPalette.forScheme(.light).spectrum == PillSpectrum.light)
  }

  // MARK: - Contrast helper

  /// WCAG 2.1 relative-luminance contrast ratio.
  ///
  /// Computed here rather than asserted against stored numbers, so a colour
  /// change is measured instead of being compared to a figure someone wrote down
  /// when the colour was different.
  private func contrastRatio(_ colour: Color, _ ground: (red: Double, green: Double, blue: Double))
    -> Double
  {
    let a = relativeLuminance(of: colour)
    let b = relativeLuminance(red: ground.red, green: ground.green, blue: ground.blue)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }

  private func relativeLuminance(of colour: Color) -> Double {
    guard let srgb = NSColor(colour).usingColorSpace(.sRGB) else {
      Issue.record("a pill colour could not be resolved in sRGB")
      return 0
    }
    return relativeLuminance(
      red: Double(srgb.redComponent),
      green: Double(srgb.greenComponent),
      blue: Double(srgb.blueComponent))
  }

  private func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
    func linear(_ channel: Double) -> Double {
      channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }
}
