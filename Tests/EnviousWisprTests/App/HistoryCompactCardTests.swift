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
      rootView: HistoryClampedText(text: text, query: "", expanded: expanded, onToggle: {})
        .frame(width: 420))
    return view.fittingSize.height
  }

  private static let long = String(
    repeating: "This sentence keeps going so the card has to wrap many lines. ", count: 20)
  private static let list =
    "Groceries for the week:\n\n- milk\n- eggs and a long item that wraps onto another line in a narrow card\n- bread\n- apples\n- coffee\n\nThanks!"
  private static let german =
    "Die Größenänderung der Straßenbahnhaltestelle verzögert sich wegen Bauarbeiten im Frühjahr, außerdem müssen wir die Übergabe der Schlüssel neu planen und die Gäste rechtzeitig informieren. Bitte schicken Sie mir die Unterlagen bis Freitag."

  private static let medium =
    "Please send the quarterly report to the whole team before Friday, and remind them about the offsite."

  private func clampedView(_ text: String, width: CGFloat) -> some View {
    HistoryClampedText(text: text, query: "", expanded: false, onToggle: {}).frame(width: width)
  }

  private func png(_ view: NSView) -> Data? {
    view.frame = NSRect(origin: .zero, size: view.fittingSize)
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep.representation(using: .png, properties: [:])
  }

  /// #4586: the clamp keeps its measurements per width. A card that is narrowed and widened
  /// again must measure exactly as a card drawn fresh at each width, or its row would change
  /// height after the list cached it.
  @Test(
    "A card narrowed and widened again keeps the height a fresh card has at each width",
    arguments: ["long", "list", "german", "medium"])
  func reusedCardMeasuresLikeAFreshOne(_ name: String) {
    let text =
      switch name {
      case "long": Self.long
      case "list": Self.list
      case "german": Self.german
      default: Self.medium
      }
    let host = NSHostingView(rootView: AnyView(clampedView(text, width: 420)))
    var reused: [CGFloat] = []
    var fresh: [CGFloat] = []
    for width: CGFloat in [420, 160, 420, 160] {
      host.rootView = AnyView(clampedView(text, width: width))
      reused.append(host.fittingSize.height)
      fresh.append(NSHostingView(rootView: clampedView(text, width: width)).fittingSize.height)
    }
    #expect(reused == fresh, "\(name): reused \(reused) vs fresh \(fresh)")
    if name == "medium" {
      // Control: whole at 420, cut with Show more at 160, so a cache that ignored the width
      // would give the wrong answer at one of them.
      #expect(fresh[1] > fresh[0], "medium: \(fresh)")
    }
  }

  /// #4586: the card hands `HistoryListText` the blocks it parsed; text with no list line must
  /// still draw from the original string, blank edge lines included.
  @Test("Text parsed once by the card draws exactly as the text itself, blank edge lines kept")
  func parsedOnceDrawsTheSame() throws {
    for text in ["\nHello there\n", Self.list] {
      let own = try #require(
        png(NSHostingView(rootView: HistoryListText(text: text).frame(width: 300))))
      let handed = try #require(
        png(
          NSHostingView(
            rootView: HistoryListText(text: text, blocks: HistoryListText.blocks(text))
              .frame(width: 300))))
      #expect(own == handed, "\(text.debugDescription) draws differently when parsed once")
    }
    // Control: the blank edge lines are visible, so the comparison above can see them.
    let trimmed = NSHostingView(rootView: HistoryListText(text: "Hello there").frame(width: 300))
    let padded = NSHostingView(
      rootView: HistoryListText(text: "\nHello there\n").frame(width: 300))
    #expect(padded.fittingSize.height > trimmed.fittingSize.height)
  }

  /// #4586: the card skips redrawing its text when nothing it draws changed. Expanding, new
  /// words (compared by bytes) or a new search must still redraw.
  @Test("The card text redraws for Show more, new words or a new search, and only then")
  func clampedTextComparison() {
    func make(_ text: String, _ query: String = "", expanded: Bool = false) -> HistoryClampedText {
      HistoryClampedText(text: text, query: query, expanded: expanded, onToggle: {})
    }
    #expect(make("Café") == make("Café"))
    #expect(make("Café") != make("Café", expanded: true))
    #expect(make("Café") != make("Café", "caf"))
    #expect(make("Caf\u{00E9}") != make("Cafe\u{0301}"), "same words, different bytes")
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
