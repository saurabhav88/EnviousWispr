import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprLLM

/// #3147 PR4A (D5): when these fail, a summary shows source tags as text, a tag points at the
/// wrong line, a reworded or partly supported line is offered a source link, or a summary
/// written in parts loses the lines its points came from.
@Suite("Meeting summary references", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingSummaryReferencesTests {
  static let noteID = UUID(uuidString: "6F0C1E9A-7A55-4E54-9C1A-2B5B0D3E4F11")!

  static let sources = MeetingSummaryReferenceSources(
    turns: [
      .init(id: "t-a", speaker: "Priya", text: "I will send the deck by Monday."),
      .init(id: "t-b", speaker: nil, text: "We  decided to   ship on Friday."),
      .init(id: "t-c", speaker: "You", text: "The budget is shipping late"),
    ],
    notes: [.init(blockID: noteID, text: "Call the vendor about pricing")])

  static let inputs = SummaryInputs(
    transcriptSHA256: "transcript", notesRevision: 3, speakerNamesSHA256: "names",
    promptVersion: MeetingSummaryReferences.promptVersion, providerID: "ollama",
    configurationSHA256: "configuration")

  // MARK: - Tagged inputs

  @Test("the model reads each turn and note behind its tag; the plain form is History's")
  func taggedTexts() {
    #expect(
      Self.sources.taggedTranscript
        == "[T1] Priya: I will send the deck by Monday.\n\n[T2] We  decided to   ship on Friday."
        + "\n\n[T3] You: The budget is shipping late")
    #expect(
      Self.sources.plainTranscript
        == "Priya: I will send the deck by Monday.\n\nWe  decided to   ship on Friday.\n\n"
        + "You: The budget is shipping late")
    #expect(Self.sources.taggedNotes == "[N1] Call the vendor about pricing")
  }

  /// #3147 PR4A (Codex integration r1 #3): a ticked and an open action item with the same text
  /// stay different for the model, while a citation still points into the block's own text.
  @Test("the model reads a task's tick; citations stay on the block's own text")
  func taskTickReachesTheModel() throws {
    let done = UUID()
    let open = UUID()
    let sources = MeetingSummaryReferenceSources(
      turns: [],
      notes: [
        .init(blockID: done, text: "Send the deck", promptText: "- [x] Send the deck"),
        .init(blockID: open, text: "Send the deck", promptText: "- [ ] Send the deck"),
      ])
    #expect(sources.taggedNotes == "[N1] - [x] Send the deck\n[N2] - [ ] Send the deck")
    let tagged = "## Action items\n- Send the deck [N2]"
    let document = try #require(
      MeetingSummaryReferences.document(
        taggedSummary: tagged, summary: MeetingSummaryReferences.strippingTags(tagged),
        sources: sources, inputs: Self.inputs))
    #expect(
      document.sections.first?.items.first?.citations == [
        .init(
          source: .note(
            blockID: open, textSHA256: MeetingDocumentHash.sha256("Send the deck")),
          quote: "Send the deck", rangeUTF16: 0..<13)
      ])
  }

  @Test("sources from a meeting row make exactly the transcript History hashes")
  func turnSourcesMatchTheProjection() {
    let text = "  hello there  \nsecond line\n   \nechoed words"
    let ns = text as NSString
    func range(_ s: String) -> Range<Int> {
      let r = ns.range(of: s)
      return r.location..<(r.location + r.length)
    }
    let turns = [
      Turn(
        id: "a", speakerId: "mic:you", startMs: 0, endMs: 1,
        originalTextRange: range("  hello there  ")),
      Turn(
        id: "b", speakerId: "call:1", startMs: 1, endMs: 2, originalTextRange: range("second line")),
      Turn(id: "c", speakerId: "call:1", startMs: 2, endMs: 3, originalTextRange: range("   \n")),
      Turn(
        id: "d", speakerId: "call:2", startMs: 3, endMs: 4, originalTextRange: range("echoed words")
      ),
    ]
    let names = ["mic:you": "You", "call:1": ""]
    let line: (String) -> String = { $0.uppercased() }
    let built = MeetingSummaryReferences.turnSources(
      text: text, turns: turns, speakerNames: names, echoTurnIDs: ["d"], showEcho: false,
      line: line)
    #expect(
      built == [
        .init(id: "a", speaker: "You", text: "HELLO THERE"),
        .init(id: "b", speaker: nil, text: "SECOND LINE"),
      ])
    let plain = MeetingTranscriptProjection.plainText(
      text: text, turns: turns, speakerNames: names, echoTurnIDs: ["d"], showEcho: false,
      line: line)
    #expect(MeetingSummaryReferenceSources(turns: built, notes: []).plainTranscript == plain)
  }

  // MARK: - Tags never reach the reader

  @Test(
    "tag groups are removed and anything else in brackets stays",
    arguments: [
      ("- Ship Friday [T2]", "- Ship Friday"),
      ("- Ship Friday [T1, T3]", "- Ship Friday"),
      ("- Ship Friday [T1][N1]", "- Ship Friday"),
      ("- Ship Friday [T2-T4]", "- Ship Friday"),
      ("- Ship [T2] Friday", "- Ship Friday"),
      ("- See [notes] and array[1]", "- See [notes] and array[1]"),
      ("- Odd [T] [T0] [X1] [T123456]", "- Odd [T] [T0] [X1] [T123456]"),
      ("## Overview\n[T1][T2]\n- Ship", "## Overview\n- Ship"),
      ("- One [T1]\r\n- Two [N1]", "- One\n- Two"),
      ("- Ship Friday [T1 [N1]]", "- Ship Friday"),
    ])
  func stripping(input: String, expected: String) {
    #expect(MeetingSummaryReferences.strippingTags(input) == expected)
  }

  // MARK: - Candidate citations

  static let tagged = """
    ## Action items
    - I will send the deck by Monday. [T1]
    - Priya sends the deck on Monday [T1]
    - We decided to ship on Friday. [T2]
    - ship [T3]
    - I will send the deck by Monday and fix the budget [T1]
    - Call the vendor about pricing [N1][T9]
    """

  static func build(_ tagged: String = tagged) throws -> MeetingSummaryDocument {
    let summary = MeetingSummaryReferences.strippingTags(tagged)
    return try #require(
      MeetingSummaryReferences.document(
        taggedSummary: tagged, summary: summary, sources: sources, inputs: inputs))
  }

  @Test("an item's citation quotes the whole item from its source, or nothing")
  func candidateCitations() throws {
    let document = try Self.build()
    #expect(document.version == MeetingSummaryDocument.currentVersion)
    #expect(document.inputs == Self.inputs)
    #expect(
      document.renderedMarkdownSHA256
        == MeetingDocumentHash.sha256(MeetingSummaryReferences.strippingTags(Self.tagged)))
    #expect(document.sections.map(\.title) == ["Action items"])
    let items = document.sections[0].items
    #expect(
      items.map(\.text) == [
        "I will send the deck by Monday.", "Priya sends the deck on Monday",
        "We decided to ship on Friday.", "ship",
        "I will send the deck by Monday and fix the budget", "Call the vendor about pricing",
      ])
    let turnA = MeetingSummarySource.turn(
      id: "t-a", textSHA256: MeetingDocumentHash.sha256("I will send the deck by Monday."))
    // Whole item, exact: the passage and its range.
    #expect(
      items[0].citations == [
        .init(source: turnA, quote: "I will send the deck by Monday.", rangeUTF16: 0..<31)
      ])
    // Reworded: the candidate is kept, with no passage.
    #expect(items[1].citations == [.init(source: turnA, quote: "", rangeUTF16: 0..<0)])
    // Only whitespace differs: the passage is the source's own spacing.
    #expect(items[2].citations.map(\.quote) == ["We  decided to   ship on Friday."])
    #expect(items[2].citations.map(\.rangeUTF16) == [0..<32])
    // "ship" inside "shipping" is not a passage.
    #expect(items[3].citations.map(\.quote) == [""])
    // A claim with more than the source said.
    #expect(items[4].citations.map(\.quote) == [""])
    // A tag naming no source is dropped; the note is cited.
    #expect(
      items[5].citations == [
        .init(
          source: .note(
            blockID: Self.noteID,
            textSHA256: MeetingDocumentHash.sha256("Call the vendor about pricing")),
          quote: "Call the vendor about pricing", rangeUTF16: 0..<29)
      ])
  }

  @Test("a passage inside a longer source keeps its own range")
  func passageInside() throws {
    let document = try Self.build("- the deck by Monday. [T1]")
    let citation = try #require(document.sections.first?.items.first?.citations.first)
    #expect(citation.quote == "the deck by Monday.")
    #expect(citation.rangeUTF16 == 12..<31)
  }

  @Test("a range that cuts a surrogate pair slices to nothing")
  func surrogateRanges() {
    #expect(MeetingSummaryReferences.slice("a😀b", 1..<3) == "😀")
    #expect(MeetingSummaryReferences.slice("a😀b", 1..<2) == "")
    #expect(MeetingSummaryReferences.slice("a😀b", 2..<4) == "")
    #expect(MeetingSummaryReferences.slice("a😀b", 0..<5) == "")
  }

  @Test("a summary whose text does not match its tagged answer gets no document")
  func mismatch() {
    #expect(
      MeetingSummaryReferences.document(
        taggedSummary: "- Ship [T1]", summary: "- Ship it", sources: Self.sources,
        inputs: Self.inputs) == nil)
  }

  @Test("the saved file round-trips, and an unknown version or damaged file reads as none")
  func savedFile() throws {
    let document = try Self.build()
    let data = try MeetingSummaryReferences.encode(document)
    #expect(MeetingSummaryReferences.decode(data) == document)
    let newer = MeetingSummaryDocument(
      version: 2, inputs: Self.inputs, renderedMarkdownSHA256: "x", sections: [])
    #expect(MeetingSummaryReferences.decode(try MeetingSummaryReferences.encode(newer)) == nil)
    #expect(MeetingSummaryReferences.decode(Data("{".utf8)) == nil)
    #expect(MeetingSummaryReferences.decode(data.prefix(data.count / 2)) == nil)
  }

  // MARK: - Writing with references

  final class Calls: @unchecked Sendable {
    // Test-only recorder touched from the summary's sequential calls; never concurrently.
    var instructions: [String] = []
    var prompts: [String] = []
    var answer: @Sendable (String) -> String = { _ in "## Overview\nShip." }

    func complete(_ instructions: String, _ prompt: String) async throws -> String {
      self.instructions.append(instructions)
      prompts.append(prompt)
      return answer(prompt)
    }
  }

  @Test("without references every call is exactly the plain summary's")
  func plainRouteUnchanged() async throws {
    let calls = Calls()
    let written = try await MeetingSummary.write(
      transcript: "You: ship Friday", notes: "", facts: "",
      window: .init(contextTokens: 128_000, outputReserveTokens: 1_500), callTimeoutSeconds: 60,
      admit: {}, complete: calls.complete)
    #expect(calls.instructions == [MeetingSummary.instructions])
    #expect(calls.prompts[0].contains("tag") == false)
    #expect(written.document == nil)
    #expect(written.text == "## Overview\nShip.")
  }

  @Test("with references the model is told to keep tags; the reader gets none")
  func singleCall() async throws {
    let calls = Calls()
    calls.answer = { _ in
      "Title: Launch plan\n## Action items\n- I will send the deck by Monday. [T1]"
    }
    let written = try await MeetingSummary.write(
      transcript: Self.sources.taggedTranscript, notes: Self.sources.taggedNotes, facts: "",
      window: .init(contextTokens: 128_000, outputReserveTokens: 1_500), callTimeoutSeconds: 60,
      references: .init(sources: Self.sources, inputs: Self.inputs), admit: {},
      complete: calls.complete)
    #expect(calls.instructions == [MeetingSummary.systemInstructions(referencing: true)])
    #expect(calls.instructions[0].hasPrefix(MeetingSummary.instructions))
    #expect(calls.prompts[0].contains("[T1] Priya: I will send the deck by Monday."))
    #expect(calls.prompts[0].contains("[N1] Call the vendor about pricing"))
    #expect(
      written.text == "Title: Launch plan\n## Action items\n- I will send the deck by Monday.")
    let summary = MeetingSummary.splitTitle(written.text).summary
    let document = try #require(written.document)
    #expect(document.renderedMarkdownSHA256 == MeetingDocumentHash.sha256(summary))
    #expect(
      document.sections.first?.items.first?.citations.first?.quote
        == "I will send the deck by Monday.")
  }

  @Test("a tag before the title line still leaves the summary its document")
  func tagBeforeTitle() async throws {
    let calls = Calls()
    calls.answer = { _ in "[T1] Title: Launch\n\n## Overview\nI will send the deck by Monday. [T1]" }
    let written = try await MeetingSummary.write(
      transcript: Self.sources.taggedTranscript, notes: "", facts: "",
      window: .init(contextTokens: 128_000, outputReserveTokens: 1_500), callTimeoutSeconds: 60,
      references: .init(sources: Self.sources, inputs: Self.inputs), admit: {},
      complete: calls.complete)
    #expect(written.text == "Title: Launch\n\n## Overview\nI will send the deck by Monday.")
    #expect(MeetingSummary.splitTitle(written.text).title == "Launch")
    let document = try #require(written.document)
    #expect(document.sections.map(\.title) == ["Overview"])
    #expect(
      document.sections.first?.items.first?.citations.first?.quote
        == "I will send the deck by Monday.")
  }

  @Test("a meeting written in parts keeps each line's tag through parts, combining and the end")
  func chunkedProvenance() async throws {
    // Many tagged turns and long part answers, so the small window needs parts and at least
    // one combine round.
    let turns = (1...400).map {
      MeetingSummaryTurnSource(
        id: "t\($0)", speaker: "Speaker \($0 % 3)",
        text: "Line \($0) talks about the quarterly plan and its many open questions in detail.")
    }
    let many = MeetingSummaryReferenceSources(turns: turns, notes: [])
    let calls = Calls()
    let claim = "Line 7 talks about the quarterly plan and its many open questions in detail."
    let filler = Array(repeating: "- Filler point about scheduling and staffing. [T1]", count: 20)
      .joined(separator: "\n")
    calls.answer = { prompt in
      if prompt.contains("This is part") || prompt.contains("Combine them") {
        return "- \(claim) [T7]\n\(filler)"
      }
      return "## Key points\n- \(claim) [T7]"
    }
    let written = try await MeetingSummary.write(
      transcript: many.taggedTranscript, notes: "", facts: "",
      window: .init(contextTokens: 4_096, outputReserveTokens: MeetingSummary.outputTokens),
      callTimeoutSeconds: 60, references: .init(sources: many, inputs: Self.inputs), admit: {},
      complete: calls.complete)
    #expect(written.inParts)
    let parts = calls.prompts.filter { $0.contains("This is part") }
    #expect(parts.count > 1)
    #expect(parts.allSatisfy { $0.contains(MeetingSummaryReferences.partClause) })
    #expect(parts.allSatisfy { $0.contains("[T") })
    let combines = calls.prompts.filter { $0.contains("Combine them") }
    #expect(combines.isEmpty == false)
    #expect(combines.allSatisfy { $0.contains(MeetingSummaryReferences.keepClause) })
    #expect(combines.allSatisfy { $0.contains("[T7]") })
    let final = try #require(calls.prompts.last)
    #expect(final.contains("[T7]"))
    #expect(written.text == "## Key points\n- \(claim)")
    let citation = try #require(written.document?.sections.first?.items.first?.citations.first)
    #expect(citation.source == .turn(id: "t7", textSHA256: MeetingDocumentHash.sha256(claim)))
    #expect(citation.quote == claim)
  }
}
