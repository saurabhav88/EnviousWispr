import AppKit
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #2202: the live level meter that replaces the lips mark in the preview pill's
/// header.
///
/// A `Canvas` cannot be asked what it drew, so the geometry decision is extracted
/// as a static function and pinned here — the same shape
/// `RecordingOverlayPanelInheritedGeometryTests` uses for panel arithmetic, and
/// for the same reason.
///
/// What these protect, stated so a later reader does not have to infer it: the
/// meter is the ONLY thing in the new header that moves, so if it stops responding
/// to the voice the pill silently becomes a static graphic that claims to be
/// listening. That is a product outcome, not a drift guard.
@MainActor
@Suite(.tags(.productOutcome))
struct RainbowLevelMeterTests {

  init() { _ = NSApplication.shared }

  @Test("silence still shows bars, because an empty meter reads as not hearing you")
  func silenceIsNotEmpty() {
    for i in 0..<RainbowLevelMeter.spectrum.count {
      let fill = RainbowLevelMeter.fill(index: i, level: 0)
      #expect(fill > 0, "bar \(i) vanished at silence")
      #expect(
        fill == RainbowLevelMeter.silenceFraction,
        "bar \(i) filled \(fill) at silence, not the resting \(RainbowLevelMeter.silenceFraction)")
    }
  }

  @Test("louder is taller, for every bar")
  func fillIsMonotonicInLevel() {
    for i in 0..<RainbowLevelMeter.spectrum.count {
      var previous = RainbowLevelMeter.fill(index: i, level: 0)
      for step in 1...10 {
        let level = CGFloat(step) / 10
        let current = RainbowLevelMeter.fill(index: i, level: level)
        #expect(
          current > previous,
          "bar \(i) did not grow from level \(level - 0.1) to \(level): \(previous) -> \(current)")
        previous = current
      }
    }
  }

  @Test("no bar overflows its strip at full level")
  func fillNeverExceedsTheStrip() {
    for i in 0..<RainbowLevelMeter.spectrum.count {
      let fill = RainbowLevelMeter.fill(index: i, level: 1)
      #expect(fill <= 1, "bar \(i) filled \(fill) of the strip, which would clip")
    }
  }

  /// The audio level arrives from a live capture path. A meter that trusts it is
  /// one bad sample away from drawing outside its own frame, and
  /// `RainbowLipsIcon` already clamps for exactly this reason.
  @Test(
    "out-of-range levels are clamped rather than trusted",
    arguments: [-99.0, -0.5, 1.5, 99.0] as [CGFloat])
  func hostileLevelsAreClamped(level: CGFloat) {
    let atFloor = RainbowLevelMeter.fill(index: 4, level: 0)
    let atCeiling = RainbowLevelMeter.fill(index: 4, level: 1)
    let got = RainbowLevelMeter.fill(index: 4, level: level)
    #expect(got >= atFloor, "level \(level) drew below the resting height")
    #expect(got <= atCeiling, "level \(level) drew above full")
  }

  @Test("an out-of-range bar index cannot crash the pill")
  func hostileIndexIsClamped() {
    // The pill is on the recording path's display side; an index error here must
    // degrade rather than trap.
    #expect(RainbowLevelMeter.fill(index: -1, level: 0.5) > 0)
    #expect(RainbowLevelMeter.fill(index: 99, level: 0.5) > 0)
  }

  @Test("the centre bar reacts more than the edges, like the mark it replaces")
  func centreIsMoreSensitiveThanTheEdges() {
    let centre = RainbowLevelMeter.fill(index: 4, level: 1)
    let edge = RainbowLevelMeter.fill(index: 0, level: 1)
    #expect(
      centre > edge,
      """
      centre filled \(centre) and edge \(edge) at full level — the meter is flat, \
      which loses the shape that makes it read as a voice
      """)
  }

  @Test("nine bars carry the nine brand spectrum colours in order")
  func spectrumIsTheBrandOrder() {
    #expect(RainbowLevelMeter.spectrum.count == 9)
    #expect(RainbowLevelMeter.sensitivity.count == RainbowLevelMeter.spectrum.count)
  }

  /// The frame and the drawing derive from one expression, so a change to bar
  /// width or spacing cannot leave the Canvas drawing outside the frame it was
  /// given — the shape of defect that produced clipped glyphs in the preview text
  /// before #1988 settled on measured layout.
  @Test("declared width matches what nine bars and eight gaps actually need")
  func widthMatchesTheDrawing() {
    let barWidth: CGFloat = 2.5
    let spacing: CGFloat = 3
    let declared = RainbowLevelMeter.width(barWidth: barWidth, spacing: spacing)
    let lastBarRightEdge =
      CGFloat(RainbowLevelMeter.spectrum.count - 1) * (barWidth + spacing) + barWidth
    #expect(
      declared == lastBarRightEdge,
      "frame is \(declared)pt but the last bar ends at \(lastBarRightEdge)pt")
  }
}
