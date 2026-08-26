import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import SwiftUI

// MARK: - RainbowLevelMeter

/// #2202: the live level meter in the preview pill's header.
///
/// **Replaces the lips mark in THIS box only.** The mark stays everywhere else —
/// the menu bar, the polishing pill, settings. Founder direction, 2026-08-19: it
/// is a logo doing a meter's job, a square block of nine bars that has to be read
/// as a picture before it reads as movement, and it occupies the left edge the
/// timer should own. Bars on a baseline say "I can hear you" in a shape everyone
/// knows from every recorder ever made.
///
/// `barCount` history bars — 24 today — interpolate across the NINE brand spectrum
/// colours in order, red through violet, the same palette and the same order as
/// `RainbowLipsIcon`, so the two read as one family while the pill transitions
/// between layouts. An earlier version of this paragraph said "nine bars", which
/// confused the palette's size with the strip's; `colour(at:of:)` blends between
/// adjacent spectrum entries precisely so the two need not match.
///
/// **Symmetric about a centre line rather than growing off a floor.** That echoes
/// the mark it replaces, and it means the meter's visual weight does not shift
/// down the header as the level drops.
///
/// Fixed height in every state. This KEEPS a property rather than adding one: the
/// capsule is already height-neutral across modes, because `scaleEffect` does not
/// participate in layout (measured — `fittingSize` 95x44 at both 1.0 and 2.0).
/// The 2x mark overflows its own slot visually and nothing resizes. A meter
/// occupying one strip avoids reintroducing a real size change where the old
/// design only ever had an apparent one.
struct RainbowLevelMeter: View {
  /// Normalised audio level 0.0-1.0, polled every ~50 ms by the parent view. The
  /// same value `RainbowLipsIcon` reads, so this adds no timer and no new source.
  let audioLevel: Float

  /// The parent's poll counter, incremented once per sample whether or not the
  /// level changed.
  ///
  /// **The history cannot be driven by a change in `audioLevel`, and that is not a
  /// style preference — it is the difference between a waveform that drains and one
  /// that freezes.** `onChange` fires on a CHANGE, and silence is the one passage
  /// where consecutive samples are bit-identical, so a level-driven history stops
  /// scrolling exactly when the user stops talking: the shape of their last words
  /// sits frozen on screen until they speak again. Reading a strictly-increasing
  /// tick makes every poll a sample, so a pause scrolls out to the silence floor
  /// the way a record of volume should.
  let tick: Int

  var height: CGFloat = 16
  var barWidth: CGFloat = 2
  var spacing: CGFloat = 1.5

  /// Outcome observer for the rendered history update. Production uses the
  /// no-op default; host-view tests use it to prove the SwiftUI trigger feeds
  /// identical samples on successive poll ticks.
  var onHistoryChange: ([CGFloat]) -> Void = { _ in }

  /// #2216: the last `barCount` levels, oldest first. Bar `i` is a MOMENT, not a
  /// position on a shape.
  ///
  /// **The first version drew every bar from the same instant's level**, scaled by
  /// a fixed per-bar weight, so all nine could only rise and fall together — a
  /// level meter in a waveform's clothes. The founder caught it against the
  /// approved mockup, where each bar ran on its own CSS timer at its own phase and
  /// therefore only LOOKED like a record of anything. Real audio hands us one
  /// scalar per tick, so the only honest way to get that picture is to keep the
  /// scalars.
  @State private var history: [CGFloat]

  /// **A SEEDED METER IS A PICTURE AND STOPS ACCUMULATING (#2435).** Non-empty
  /// `initialHistory` is the caller declaring that it owns what this meter shows,
  /// so tick changes are ignored and the rendered bars are exactly what was
  /// handed in, on the first frame and every frame after it.
  ///
  /// **Two review rounds were spent trying to make an accumulating meter hold
  /// still, and both fixes only moved the artifact.** A FULL seed hit capacity on
  /// the first poll, dropped its oldest sample and shifted every bar. Seeding one
  /// SHORT moved it: `bars` right-aligns a short history and pads the old end,
  /// so the first frame carried a leading silence bar that the poll then pushed
  /// out — the same one-bar shift, arriving from the other side. The root was
  /// never the seed's length; it was that the meter kept accumulating into a
  /// picture somebody else had already decided.
  ///
  /// Production passes nothing, gets `[]`, and accumulates exactly as it always
  /// has — the branch cannot reach a live pill.
  private var isSeeded: Bool { !initialHistory.isEmpty }

  /// The history this meter was handed, if any. Held as well as seeded into
  /// `@State` because the seeded-ness is what decides whether ticks are read.
  private let initialHistory: [CGFloat]

  /// Seeds `history` so a meter that will never poll still shows a real shape
  /// (#2435).
  ///
  /// **Without it a still pill draws ONE sample and twenty-three bars at the
  /// silence floor**, because `history` starts empty and only `onChange(of: tick)`
  /// ever appends. The Appearance picker draws exactly that pill, and the Level
  /// Rail's entire identity is this meter, so the picker would misrepresent the
  /// design it is asking the user to choose.
  ///
  /// Seeded through an initializer rather than `onAppear`, which runs after the
  /// first layout and would show the flat meter for a frame before filling it —
  /// the same defect `initialPreview:` exists to avoid one view up.
  ///
  /// Production passes nothing and gets `[]`, which is exactly today's behaviour.
  init(
    audioLevel: Float,
    tick: Int,
    height: CGFloat = 16,
    barWidth: CGFloat = 2,
    spacing: CGFloat = 1.5,
    onHistoryChange: @escaping ([CGFloat]) -> Void = { _ in },
    initialHistory: [CGFloat] = []
  ) {
    self.audioLevel = audioLevel
    self.tick = tick
    self.height = height
    self.barWidth = barWidth
    self.spacing = spacing
    self.onHistoryChange = onHistoryChange
    self.initialHistory = initialHistory
    _history = State(initialValue: initialHistory)
  }

  /// About 1.2 seconds of history at the parent's 50 ms poll — long enough to read
  /// as a shape, short enough that it is recognisably what you just said.
  static let barCount = 24

  /// A bar's minimum share of the strip. Non-zero on purpose: a meter that
  /// collapses to nothing between words reads as "it stopped hearing me", which is
  /// the exact anxiety the preview exists to remove.
  static let silenceFraction: CGFloat = 0.14

  /// Additional share available at full level.
  static let peakFraction: CGFloat = 0.86

  /// The brand spectrum, sampled across the strip.
  ///
  /// **Positional, not per-sample.** The gradient stays still while heights scroll
  /// through it, which keeps the mark recognisable — colours crawling sideways
  /// would read as a progress bar rather than as our spectrum.
  static let spectrum: [Color] = [
    Color(red: 1.0, green: 0.165, blue: 0.251),  // #ff2a40 red
    Color(red: 1.0, green: 0.549, blue: 0.0),  // #ff8c00 orange
    Color(red: 1.0, green: 0.843, blue: 0.0),  // #ffd700 gold
    Color(red: 0.678, green: 1.0, blue: 0.184),  // #adff2f lime
    Color(red: 0.0, green: 0.98, blue: 0.604),  // #00fa9a spring
    Color(red: 0.0, green: 1.0, blue: 1.0),  // #00ffff cyan
    Color(red: 0.118, green: 0.565, blue: 1.0),  // #1e90ff blue
    Color(red: 0.255, green: 0.412, blue: 0.882),  // #4169e1 royal
    Color(red: 0.541, green: 0.169, blue: 0.886),  // #8a2be2 violet
  ]

  /// The colour at position `index` of `count`, interpolated across the spectrum so
  /// the gradient is smooth at any bar count.
  static func colour(at index: Int, of count: Int) -> Color {
    guard count > 1 else { return spectrum[0] }
    let t = CGFloat(min(max(index, 0), count - 1)) / CGFloat(count - 1)
    let scaled = t * CGFloat(spectrum.count - 1)
    let lower = Int(scaled)
    let upper = min(lower + 1, spectrum.count - 1)
    let frac = scaled - CGFloat(lower)
    return frac < 0.001
      ? spectrum[lower] : spectrum[lower].blended(with: spectrum[upper], amount: frac)
  }

  /// Fraction of the strip a sample occupies.
  ///
  /// Extracted so a test can assert it without rendering — a `Canvas` cannot be
  /// asked what it drew.
  static func fill(level: CGFloat) -> CGFloat {
    silenceFraction + peakFraction * min(max(level, 0), 1)
  }

  /// Push a sample onto the history, dropping the oldest once full.
  ///
  /// Pure and static so the scrolling behaviour is testable directly: this is the
  /// whole difference between a record and a level, and it is the part that was
  /// missing.
  static func pushed(_ history: [CGFloat], level: CGFloat, capacity: Int = barCount) -> [CGFloat] {
    guard capacity > 0 else { return [] }
    // Clamp on the way IN, so a bad sample cannot sit in the buffer for a second
    // and a bit poisoning every frame it appears in.
    var next = history + [min(max(level, 0), 1)]
    if next.count > capacity { next.removeFirst(next.count - capacity) }
    return next
  }

  /// The level to draw in each of `count` bars, right-aligned so the newest sample
  /// is always at the same edge — without this the whole waveform slides sideways
  /// for the first second of every recording.
  ///
  /// Extracted from the `Canvas` so it can be asserted directly: a `Canvas` cannot
  /// be asked what it drew, and this is the step that turns a buffer into bars.
  /// Every read is bounds-checked rather than trusting `history` to be the right
  /// length, because this runs on the heart path and an index slip here is a crash
  /// in the recording overlay.
  static func bars(history: [CGFloat], count: Int = barCount) -> [CGFloat] {
    guard count > 0 else { return [] }
    let pad = max(0, count - history.count)
    // A longer-than-expected buffer keeps its NEWEST samples, never its oldest.
    let offset = max(0, history.count - count)
    return (0..<count).map { i in
      let index = i - pad + offset
      return index >= 0 && index < history.count ? history[index] : 0
    }
  }

  var body: some View {
    Canvas { context, size in
      let levels = Self.bars(history: history)
      for i in 0..<Self.barCount {
        let barHeight = size.height * Self.fill(level: levels[i])
        let x = CGFloat(i) * (barWidth + spacing)
        let rect = CGRect(
          x: x, y: (size.height - barHeight) / 2,
          width: barWidth, height: barHeight)
        context.fill(
          Path(roundedRect: rect, cornerRadius: barWidth / 2),
          with: .color(Self.colour(at: i, of: Self.barCount)))
      }
    }
    .frame(width: Self.width(barWidth: barWidth, spacing: spacing), height: height)
    .onChange(of: tick) { _, _ in
      // A seeded meter is a PICTURE: the caller owns what it shows, so a poll
      // that exists only to synchronise scalars must not shift the bars.
      guard !isSeeded else { return }
      let next = Self.pushed(history, level: CGFloat(audioLevel))
      history = next
      onHistoryChange(next)
    }
    .accessibilityHidden(true)
  }

  /// Total width for `barCount` bars and their gaps. Derived rather than a
  /// literal, so the frame cannot drift from what the Canvas draws.
  static func width(barWidth: CGFloat, spacing: CGFloat) -> CGFloat {
    CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
  }
}

extension Color {
  /// Linear blend towards another colour, for the meter's positional gradient.
  fileprivate func blended(with other: Color, amount: CGFloat) -> Color {
    let a = NSColor(self).usingColorSpace(.sRGB) ?? .white
    let b = NSColor(other).usingColorSpace(.sRGB) ?? .white
    let t = min(max(amount, 0), 1)
    return Color(
      red: a.redComponent + (b.redComponent - a.redComponent) * t,
      green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
      blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t)
  }
}
