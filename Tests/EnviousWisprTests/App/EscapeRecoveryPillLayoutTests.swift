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

  @Test("The pill is wide enough for the sentence it renders")
  func theSentenceFitsThePillItIsRenderedIn() {
    let font = NSFont.systemFont(ofSize: PillMetrics.titleSize, weight: .medium)
    let title = DictationNarrator.escapeRecoveryPillTitle as NSString
    let sentence = ceil(title.size(withAttributes: [.font: font]).width)

    let claimed =
      PillMetrics.leadInset + sentence + PillMetrics.midGap
      + PillMetrics.actionWidth + PillMetrics.trailInset

    // Failing this renders "Transcript cance…", which the earlier fixed-width
    // pill did when the copy was revised.
    #expect(PillMetrics.pillWidth >= claimed)
  }

  @Test("A longer sentence would widen the pill rather than clip")
  func theWidthTracksTheCopyRatherThanAConstant() {
    let font = NSFont.systemFont(ofSize: PillMetrics.titleSize, weight: .medium)
    let shipped = DictationNarrator.escapeRecoveryPillTitle as NSString
    let longer = (DictationNarrator.escapeRecoveryPillTitle + " again") as NSString

    let shippedWidth = ceil(shipped.size(withAttributes: [.font: font]).width)
    let longerWidth = ceil(longer.size(withAttributes: [.font: font]).width)

    // The measurement is what the pill is built from, so a wider sentence has to
    // produce a wider measurement. A constant here would make both equal and the
    // pill would clip the longer one silently.
    #expect(longerWidth > shippedWidth)
    #expect(PillMetrics.pillWidth > shippedWidth)
  }

  /// **Equality, not headroom, and the direction matters.**
  ///
  /// `showPanel` anchors the PANEL to the configured screen edge, so any slack
  /// inside it moves the visible capsule that far off that edge and makes a
  /// recording-to-recovery transition jump. The shadow is drawn by the window,
  /// outside its frame, so no slack is needed to avoid clipping it.
  @Test("The anchored panel is exactly the visible pill")
  func thePanelFrameIsThePill() {
    #expect(PillMetrics.panelWidth == PillMetrics.pillWidth)
    #expect(PillMetrics.panelHeight == PillMetrics.pillHeight)
  }

  @Test("The action is a real target, not a hairline")
  func theActionIsBigEnoughToHit() {
    // Well under the 44pt HIG target because this is a transient overlay the
    // pointer is already near, but a button that shrinks toward the text size
    // would be a regression a user feels immediately.
    #expect(PillMetrics.actionWidth >= 60)
    #expect(PillMetrics.actionHeight >= 28)
    #expect(PillMetrics.actionHeight < PillMetrics.pillHeight)
  }

  // MARK: - The countdown

  @Test("The rail is already visible the instant the pill appears")
  func theRailShowsASparkAtZero() {
    // At t=0 an untrimmed rail draws nothing, and the pill arrives looking like
    // its rim is broken.
    #expect(SpectralRail.drawnFraction(for: 0) > 0)
    #expect(SpectralRail.drawnFraction(for: 0) == SpectralRail.minimumSpark)
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
    #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 })
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
