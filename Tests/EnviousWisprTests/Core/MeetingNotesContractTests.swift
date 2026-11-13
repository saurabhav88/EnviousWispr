import EnviousWisprCore
import Foundation
import Testing

/// #3147 PR4 contract: meeting notes v2 and the structured summary survive a save and a reload
/// exactly, so a note's kind, tick, time and quote source, and a summary's candidate sources,
/// are never lost or changed by storage.
/// Class: `.productOutcome`: when these fail, saved notes or summary links come back different.
@Suite("Meeting notes v2 and summary document storage (#3147 PR4)", .tags(.productOutcome))
struct MeetingNotesContractTests {
  private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
  }

  @Test("every note block kind and field comes back exactly")
  func notesRoundTrip() throws {
    let document = MeetingNotesDocument(blocks: [
      MeetingNoteBlock(startedAtMs: 1_200, text: "Budget is fixed"),
      MeetingNoteBlock(kind: .task, done: true, text: "Send the deck"),
      MeetingNoteBlock(startedAtMs: 61_000, kind: .mark, text: ""),
      MeetingNoteBlock(
        kind: .quote, text: "We ship Friday", sourceSpeaker: "Ana", sourceMs: 90_500),
    ])
    #expect(document.version == 2)
    #expect(try roundTrip(document) == document)
    #expect(
      document.blocks[0].done == false && document.blocks[0].kind == .text,
      "a plain block is untick text by default")
  }

  @Test("a structured summary keeps its sections, items and candidate sources")
  func summaryRoundTrip() throws {
    let inputs = SummaryInputs(
      transcriptSHA256: "t", notesRevision: 3, speakerNamesSHA256: "s", promptVersion: 2,
      providerID: "egOne", configurationSHA256: "c")
    let noteID = UUID()
    let summary = MeetingSummaryDocument(
      inputs: inputs, renderedMarkdownSHA256: "m",
      sections: [
        MeetingSummarySection(
          id: UUID(), title: "Decisions",
          items: [
            MeetingSummaryItem(
              id: UUID(), text: "Ship Friday",
              citations: [
                MeetingSummaryCitation(
                  source: .turn(id: "mic-4", textSHA256: "a"), quote: "ship Friday",
                  rangeUTF16: 3..<14),
                MeetingSummaryCitation(
                  source: .note(blockID: noteID, textSHA256: "b"), quote: "Friday",
                  rangeUTF16: 0..<6),
              ])
          ])
      ])
    #expect(summary.version == 1)
    #expect(try roundTrip(summary) == summary)
  }

  @Test("edits are values: the same edit compares equal, a different range does not")
  func editsAreValues() {
    let id = UUID()
    #expect(
      MeetingNotesEdit.replaceText(blockID: id, rangeUTF16: 0..<2, text: "Hi")
        == .replaceText(blockID: id, rangeUTF16: 0..<2, text: "Hi"))
    #expect(
      MeetingNotesEdit.replaceText(blockID: id, rangeUTF16: 0..<2, text: "Hi")
        != .replaceText(blockID: id, rangeUTF16: 0..<3, text: "Hi"))
  }
}
