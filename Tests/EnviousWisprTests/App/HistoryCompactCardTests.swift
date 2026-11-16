import AppKit
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #4611: the compact History card. A long dictation stops at four lines until Show more (so
/// cards stay light and close to one height while History scrolls), a short one draws whole,
/// and the playback waveform shows the voice's shape: speech rises, pauses stay flat.
@MainActor
@Suite(
  "Compact History cards: four lines until Show more, a waveform that shows the voice",
  .tags(.productOutcome))
struct HistoryCompactCardTests {
  init() { _ = NSApplication.shared }

  private func height(_ text: String, expanded: Bool) -> CGFloat {
    let view = NSHostingView(
      rootView: HistoryClampedText(text: text, query: "", expanded: .constant(expanded))
        .frame(width: 420))
    return view.fittingSize.height
  }

  @Test("A long dictation stops at four lines with Show more; a short one draws whole")
  func longTextIsClampedShortTextIsWhole() {
    let short = "Please send the report before Friday."
    let long = String(
      repeating: "This sentence keeps going so the card has to wrap many lines. ", count: 20)
    let oneLine = height(short, expanded: false)
    #expect(height(short, expanded: true) > oneLine, "expanded adds only the Show less button")
    let clamped = height(long, expanded: false)
    let whole = height(long, expanded: true)
    #expect(
      clamped > oneLine * 3, "four lines of text plus Show more: \(clamped) vs one line \(oneLine)")
    #expect(clamped < oneLine * 7, "the clamped card stays near four lines: \(clamped)")
    #expect(whole > clamped * 2, "Show more opens the whole text: \(whole) vs \(clamped)")
  }

  @Test("The waveform shows loudness the way ears hear it: loudest is full, a pause is flat")
  func loudnessScale() {
    let bars = MeetingPlaybackController.loudness([0, 0.001, 0.5, 1])
    #expect(bars[0] == 0)
    #expect(bars[1] == 0, "60 dB below the loudest is a pause")
    #expect(abs(bars[2] - (1 - 6.02 / 35)) < 0.01, "half the loudness is 6 dB down")
    #expect(bars[3] == 1)
    #expect(MeetingPlaybackController.loudness([]).isEmpty)
    #expect(MeetingPlaybackController.loudness([0, 0]) == [0, 0])
  }
}
