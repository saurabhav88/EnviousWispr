import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// Founder #4611: when these fail, a transcript's polished list shows raw "- " dashes again, or
/// a dash the user typed inside a sentence turns into a dot.
@Suite("HistoryListText", .tags(.productOutcome))
struct HistoryListTextTests {

  @Test("only a marker and a space at the start of a line make a list item")
  func listItemRule() {
    #expect(HistoryListText.listItem("- Buy milk") == "Buy milk")
    #expect(HistoryListText.listItem("  * Call Sam ") == "Call Sam")
    #expect(HistoryListText.listItem("• Book flights") == "Book flights")
    for line in ["-", "- ", "-5 degrees", "--", "– en dash", "— em dash", "Plan - then go", "-item"] {
      #expect(HistoryListText.listItem(Substring(line)) == nil, "\(line)")
    }
  }

  @Test("a polished list becomes lead-in, items, then the rest, words unchanged")
  func blocks() {
    let text = "Three things:\n- Milk\n- Eggs, two dozen\n\nThat is all.\nCost -5 today.\n\n- Last\n"
    #expect(
      HistoryListText.blocks(text) == [
        .prose("Three things:"), .item("Milk"), .item("Eggs, two dozen"), .gap,
        .prose("That is all.\nCost -5 today."), .gap, .item("Last"),
      ])
    #expect(HistoryListText.blocks("\n\n- One\n\n\n") == [.item("One")])
  }

  @Test("turns show dots in Polished only; Original and Marked up keep the dash")
  func polishedOnly() throws {
    let turns = [
      Turn(
        id: "0-5", speakerId: "A", startMs: 0, endMs: 100, originalTextRange: 0..<5,
        processedText: "List:\n- one", wasPolished: true)
    ]
    for mode: TranscriptDocumentPresenter.ViewMode in [.cleaned, .original, .markedUp] {
      let rendered = try #require(
        TranscriptDocumentPresenter.render(
          turns: turns, rawText: "list one", speakerNames: [:], mode: mode, timesOn: false,
          documentFinished: true, diffLookup: { _ in nil }))
      #expect(rendered.map(\.showsListBullets) == [mode == .cleaned], "\(mode)")
    }
  }
}
