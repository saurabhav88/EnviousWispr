import AppKit
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #2216: the meter shows a RECORD of volume over time, not one level drawn nine
/// times.
///
/// **What the first version got wrong, and why no test caught it.** Every bar was
/// computed from the same instant's `audioLevel` scaled by a fixed per-bar weight,
/// so the bars could only rise and fall together in a static symmetric shape. The
/// old suite asserted the properties that design HAD — louder is taller, nothing
/// overflows, the centre outreacts the edges — and every one passed. None of them
/// asked the question that mattered: **can two bars ever differ for a reason other
/// than their index?** Under the old design the answer was no, and the tests could
/// not see it because they never showed the meter two different moments.
///
/// So the cases here are about the history, which is the whole difference between
/// a record and a level.
@MainActor
@Suite(.tags(.productOutcome))
struct RainbowLevelMeterTests {

  private final class MeterDriver: ObservableObject {
    @Published var tick = 0
    @Published var audioLevel: Float = 0
  }

  private struct MeterHarness: View {
    @ObservedObject var driver: MeterDriver
    let onHistoryChange: ([CGFloat]) -> Void

    var body: some View {
      RainbowLevelMeter(
        audioLevel: driver.audioLevel,
        tick: driver.tick,
        onHistoryChange: onHistoryChange)
    }
  }

  init() { _ = NSApplication.shared }

  // MARK: - The history is a record

  @Test("a sample lands at the newest end and the buffer keeps its order")
  func samplesArriveInOrder() {
    var h: [CGFloat] = []
    for level in [0.1, 0.5, 0.9] as [CGFloat] {
      h = RainbowLevelMeter.pushed(h, level: level, capacity: 5)
    }
    #expect(h == [0.1, 0.5, 0.9], "got \(h) — the buffer is not preserving arrival order")
  }

  @Test("the oldest sample falls off once the buffer is full")
  func oldestFallsOff() {
    var h: [CGFloat] = []
    for level in [0.1, 0.2, 0.3, 0.4] as [CGFloat] {
      h = RainbowLevelMeter.pushed(h, level: level, capacity: 3)
    }
    #expect(h == [0.2, 0.3, 0.4], "got \(h) — expected the first sample to be dropped")
  }

  @Test("the buffer never exceeds its capacity")
  func capacityIsRespected() {
    var h: [CGFloat] = []
    for i in 0..<200 {
      h = RainbowLevelMeter.pushed(h, level: CGFloat(i % 10) / 10, capacity: 24)
    }
    #expect(h.count == 24, "buffer grew to \(h.count)")
  }

  /// **The case the old design could not pass.** Two different moments must be
  /// able to produce two different bars. Under a single-level meter every bar is
  /// the same number times a constant, so this is impossible by construction.
  @Test("bars differ because the audio differed, not because of their position")
  func barsRecordDistinctMoments() {
    var h: [CGFloat] = []
    for level in [0.0, 1.0, 0.0, 1.0, 0.0] as [CGFloat] {
      h = RainbowLevelMeter.pushed(h, level: level, capacity: 5)
    }
    let fills = h.map { RainbowLevelMeter.fill(level: $0) }
    #expect(
      Set(fills).count == 2,
      """
      an alternating loud/quiet passage produced \(Set(fills).count) distinct bar \
      heights: \(fills). A record of volume must show the alternation; a meter \
      driven by one instant cannot.
      """)
  }

  /// The inverse, and it is what makes the case above meaningful: a steady tone
  /// must produce a FLAT line. The old design produced its fixed centre-weighted
  /// shape for any input at all, so it could not tell these two passages apart.
  @Test("a steady tone reads flat")
  func steadyToneIsFlat() {
    var h: [CGFloat] = []
    for _ in 0..<10 { h = RainbowLevelMeter.pushed(h, level: 0.6, capacity: 6) }
    let fills = Set(h.map { RainbowLevelMeter.fill(level: $0) })
    #expect(fills.count == 1, "a constant level produced \(fills.count) heights: \(fills)")
  }

  /// **A pause must DRAIN the waveform, not freeze it**, and this is the case that
  /// sent the history to a poll counter rather than to `audioLevel`.
  ///
  /// `onChange` fires on a CHANGE. Silence is the one passage where consecutive
  /// samples are bit-identical, so a level-driven history stops taking samples
  /// exactly when the user stops talking — leaving the shape of their last words
  /// frozen on screen until they speak again, which reads as the app having hung.
  @Test("a pause scrolls the last words out and settles on the silence floor")
  func silenceDrainsTheWaveform() {
    var h: [CGFloat] = []
    for level in [0.9, 0.8, 1.0, 0.7] as [CGFloat] {
      h = RainbowLevelMeter.pushed(h, level: level)
    }
    for _ in 0..<RainbowLevelMeter.barCount {
      h = RainbowLevelMeter.pushed(h, level: 0)
    }
    let heights = Set(RainbowLevelMeter.bars(history: h).map { RainbowLevelMeter.fill(level: $0) })
    #expect(
      heights == [RainbowLevelMeter.silenceFraction],
      """
      after a full buffer of silence the meter still shows \(heights.count) heights: \
      \(heights). The loud passage never scrolled off, so the waveform is frozen \
      rather than draining.
      """)
  }

  @Test("identical silence samples enter history on every poll tick")
  func identicalSilenceSamplesFollowTheTick() async {
    let driver = MeterDriver()
    var observed: [[CGFloat]] = []
    let host = NSHostingView(
      rootView: MeterHarness(driver: driver) { observed.append($0) }
        .frame(width: 100, height: 20))
    let frame = NSRect(x: 0, y: 0, width: 100, height: 20)
    let window = NSWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.frame = frame
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    #expect(observed.isEmpty, "mounting the meter must not invent a sample")

    driver.tick = 1
    await Task.yield()
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    driver.tick = 2
    await Task.yield()
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    #expect(observed.count == 2, "two poll ticks delivered \(observed.count) samples")
    #expect(observed.last == [0, 0], "identical silence did not advance the rendered history")
  }

  // MARK: - Turning the buffer into bars

  @Test("a partial buffer is right-aligned, so the newest sample never moves")
  func partialBufferIsRightAligned() {
    let h: [CGFloat] = [0.4, 0.9]
    let bars = RainbowLevelMeter.bars(history: h, count: 5)
    #expect(
      bars == [0, 0, 0, 0.4, 0.9], "got \(bars) — the newest sample is not at the right edge")
  }

  @Test("the newest sample sits at the same edge whether the buffer is partial or full")
  func newestSampleHoldsItsEdge() {
    let partial = RainbowLevelMeter.bars(history: [0.4, 0.9], count: 5)
    let full = RainbowLevelMeter.bars(history: [0.1, 0.2, 0.3, 0.4, 0.9], count: 5)
    #expect(
      partial.last == full.last,
      "newest sample moved from \(String(describing: full.last)) to \(String(describing: partial.last)) as the buffer filled"
    )
  }

  /// The heart path draws this every frame, so an index slip is a crash in the
  /// recording overlay rather than a wrong pixel.
  @Test("an over-long buffer keeps its newest samples and cannot read out of bounds")
  func overLongBufferIsSafe() {
    let h: [CGFloat] = (0..<100).map { CGFloat($0) / 100 }
    let bars = RainbowLevelMeter.bars(history: h, count: 4)
    #expect(bars == [0.96, 0.97, 0.98, 0.99], "got \(bars) — expected the four newest samples")
  }

  @Test("an empty buffer draws the silence floor rather than crashing")
  func emptyBufferIsSafe() {
    let bars = RainbowLevelMeter.bars(history: [], count: 3)
    #expect(bars == [0, 0, 0])
  }

  @Test("a zero bar count produces no bars")
  func zeroBarCountIsSafe() {
    #expect(RainbowLevelMeter.bars(history: [0.5], count: 0).isEmpty)
  }

  @Test("the drawing always has exactly one level per bar")
  func barsMatchTheBarCount() {
    #expect(RainbowLevelMeter.bars(history: [0.5]).count == RainbowLevelMeter.barCount)
  }

  // MARK: - Hostile input

  /// The level arrives from a live capture path. A bad sample must not sit in the
  /// buffer for a second and a bit, poisoning every frame it appears in — so the
  /// clamp is on the way IN, not at draw time.
  @Test(
    "out-of-range samples are clamped before entering the buffer",
    arguments: [-99.0, -0.5, 1.5, 99.0] as [CGFloat])
  func hostileSamplesAreClampedOnEntry(level: CGFloat) {
    let h = RainbowLevelMeter.pushed([], level: level, capacity: 4)
    let v = h.first ?? -1
    #expect(v >= 0 && v <= 1, "level \(level) entered the buffer as \(v)")
  }

  @Test("a zero capacity cannot produce a negative removeFirst")
  func zeroCapacityIsSafe() {
    #expect(RainbowLevelMeter.pushed([0.5], level: 0.5, capacity: 0).isEmpty)
  }

  // MARK: - Drawing

  @Test("silence still shows a bar, because an empty meter reads as not hearing you")
  func silenceIsNotEmpty() {
    #expect(RainbowLevelMeter.fill(level: 0) == RainbowLevelMeter.silenceFraction)
    #expect(RainbowLevelMeter.fill(level: 0) > 0)
  }

  @Test("louder is taller, and full level does not overflow the strip")
  func fillIsMonotonicAndBounded() {
    var previous = RainbowLevelMeter.fill(level: 0)
    for step in 1...10 {
      let current = RainbowLevelMeter.fill(level: CGFloat(step) / 10)
      #expect(current > previous, "level \(CGFloat(step) / 10) was not taller than the step before")
      previous = current
    }
    #expect(RainbowLevelMeter.fill(level: 1) <= 1, "full level overflows the strip")
  }

  /// The gradient is positional, so it must span the spectrum regardless of how
  /// many bars there are — the bar count changed in this issue and would have
  /// silently truncated a hardcoded mapping.
  @Test("the positional gradient spans the spectrum at the shipped bar count")
  func gradientSpansTheSpectrum() {
    let first = RainbowLevelMeter.colour(at: 0, of: RainbowLevelMeter.barCount)
    let last = RainbowLevelMeter.colour(
      at: RainbowLevelMeter.barCount - 1, of: RainbowLevelMeter.barCount)
    #expect(first == RainbowLevelMeter.spectrum.first)
    #expect(last == RainbowLevelMeter.spectrum.last)
  }

  @Test("a single-bar meter does not divide by zero")
  func singleBarGradientIsSafe() {
    #expect(RainbowLevelMeter.colour(at: 0, of: 1) == RainbowLevelMeter.spectrum[0])
  }

  /// The frame and the drawing derive from one expression, so the Canvas cannot
  /// draw outside the frame it was given.
  @Test("declared width matches what the bars and gaps actually need")
  func widthMatchesTheDrawing() {
    let barWidth: CGFloat = 2
    let spacing: CGFloat = 1.5
    let declared = RainbowLevelMeter.width(barWidth: barWidth, spacing: spacing)
    let lastEdge =
      CGFloat(RainbowLevelMeter.barCount - 1) * (barWidth + spacing) + barWidth
    #expect(declared == lastEdge, "frame is \(declared)pt but the last bar ends at \(lastEdge)pt")
  }
}
