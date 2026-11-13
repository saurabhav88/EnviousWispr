import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprLLM
@testable import EnviousWisprStorage

/// #3147 PR4A (D5): when these fail, a meeting summary offers View source for a line the
/// transcript or notes never said, for a summary the user edited, renamed, re-transcribed or
/// that is out of date, or a summary line that came straight from the transcript loses its link.
@MainActor
@Suite("Meeting summary source links", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingSummaryReferenceValidatorTests {
  typealias Rig = MeetingSummaryOwnerTests.Rig

  static func eventually(
    _ label: String, _ condition: @escaping @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    await MeetingSummaryOwnerTests.eventually(label, condition, sourceLocation: sourceLocation)
  }

  static let turn = MeetingSummaryTurnSource(id: "turn-1", speaker: "You", text: "we ship Friday")
  static let sources = MeetingSummaryReferenceSources(turns: [turn], notes: [])

  /// The validator over the rig's real documents and owner.
  static func validator(_ rig: Rig) -> MeetingSummaryReferenceValidator {
    let world = rig.world
    let documents = rig.documents
    let owner = rig.owner
    return MeetingSummaryReferenceValidator(
      dependencies: .init(
        storedDocument: { _ in world.savedReferences.last ?? nil },
        savedSummary: { documents.manifest($0)?.summary },
        shownSummary: { documents.summary($0) },
        isOutOfDate: { owner.isOutOfDate($0) },
        sources: { _ in world.sources }))
  }

  static func referencingRig() throws -> Rig {
    let rig = try Rig()
    rig.world.referencing = true
    rig.world.transcript = "You: we ship Friday"
    rig.world.speakerNames = ["mic:you": "You"]
    rig.world.sources = sources
    rig.world.answer = "Title: Launch\n## Decisions\n- we ship Friday [T1]\n- Ship it Friday [T1]"
    return rig
  }

  @Test("a line taken word for word from the transcript links to its turn, and only while current")
  func endToEnd() async throws {
    let rig = try Self.referencingRig()
    let id = try rig.readyMeeting()
    #expect(await MeetingSummaryOwnerTests.schedule(rig, id) == .scheduled)
    await Self.eventually("written") { rig.world.finished.count == 1 }
    #expect(rig.world.finished == [MeetingSummaryOwnerTests.row(.written, .hosted)])

    // The model read the tagged turn; the reader gets no tags.
    #expect(rig.world.calls.first?.contains("[T1] You: we ship Friday") == true)
    #expect(rig.summaryOnDisk(id) == "## Decisions\n- we ship Friday\n- Ship it Friday")
    let saved = try #require(try rig.manifest(id).summary)
    #expect(saved.inputs?.promptVersion == MeetingSummaryReferences.promptVersion)
    let document = try #require(rig.world.savedReferences.last ?? nil)
    #expect(document.renderedMarkdownSHA256 == saved.sha256)
    #expect(document.inputs == saved.inputs)

    #expect(await rig.documents.load(id))
    let validator = Self.validator(rig)
    #expect(validator.document(for: id) == document)
    let items = try #require(document.sections.first?.items)
    let exact = items[0]
    let reworded = items[1]
    let link = try #require(validator.validatedSource(for: exact.id, meetingID: id))
    #expect(link.itemID == exact.id)
    #expect(
      link.sources == [
        .turn(id: "turn-1", textSHA256: MeetingDocumentHash.sha256("we ship Friday"))
      ])
    #expect(validator.validatedSource(for: reworded.id, meetingID: id) == nil)
    #expect(validator.validatedSource(for: UUID(), meetingID: id) == nil)

    // A renamed speaker makes the summary out of date: no link.
    rig.world.speakerNames = ["mic:you": "Saurabh"]
    #expect(validator.validatedSource(for: exact.id, meetingID: id) == nil)
    rig.world.speakerNames = ["mic:you": "You"]
    #expect(validator.validatedSource(for: exact.id, meetingID: id) != nil)

    // Transcribe again: a new attempt makes it out of date.
    rig.world.transcriptAttemptID = UUID()
    #expect(validator.validatedSource(for: exact.id, meetingID: id) == nil)
    rig.world.transcriptAttemptID = nil

    // The turn's words changed: its recorded hash no longer matches.
    rig.world.sources = MeetingSummaryReferenceSources(
      turns: [.init(id: "turn-1", speaker: "You", text: "we ship Saturday")], notes: [])
    #expect(validator.validatedSource(for: exact.id, meetingID: id) == nil)
    rig.world.sources = Self.sources
    #expect(validator.validatedSource(for: exact.id, meetingID: id) != nil)

    // Typing in the summary, unsaved and then saved: the user's text never links.
    rig.documents.setSummary(id, "## Decisions\n- we ship Friday, maybe")
    #expect(validator.document(for: id) == nil)
    #expect(validator.validatedSource(for: exact.id, meetingID: id) == nil)
    #expect(await rig.documents.flushSummary(id))
    #expect(try rig.manifest(id).summary?.origin == .userEdited)
    #expect(validator.validatedSource(for: exact.id, meetingID: id) == nil)
  }

  @Test("sources that do not make the hashed transcript: the plain prompt, and nothing to link")
  func mismatchedSources() async throws {
    let rig = try Self.referencingRig()
    rig.world.sources = MeetingSummaryReferenceSources(
      turns: [.init(id: "turn-1", speaker: "You", text: "we ship Thursday")], notes: [])
    let id = try rig.readyMeeting()
    _ = await MeetingSummaryOwnerTests.schedule(rig, id)
    await Self.eventually("written") { rig.world.finished.count == 1 }
    #expect(rig.world.calls.first?.contains("[T1]") == false)
    #expect(rig.world.savedReferences.count == 1)
    #expect(rig.world.savedReferences.first == .some(nil))
    #expect(await rig.documents.load(id))
    #expect(Self.validator(rig).document(for: id) == nil)
  }

  @Test("a route not qualified for references writes the plain summary exactly as before")
  func plainRoute() async throws {
    let rig = try Self.referencingRig()
    rig.world.referencing = false
    rig.world.answer = "## Overview\nShip Friday."
    let id = try rig.readyMeeting()
    _ = await MeetingSummaryOwnerTests.schedule(rig, id)
    await Self.eventually("written") { rig.world.finished.count == 1 }
    #expect(rig.world.calls.first?.contains("[T") == false)
    #expect(rig.world.calls.first?.contains("Transcript:\nYou: we ship Friday") == true)
    #expect(try rig.manifest(id).summary?.inputs?.promptVersion == MeetingSummary.promptVersion)
    #expect(rig.world.savedReferences.first == .some(nil))
    #expect(rig.summaryOnDisk(id) == "## Overview\nShip Friday.")
  }

  @Test("the production qualification table names no hosted route")
  func hostedRoutesUnqualified() {
    for provider in [LLMProvider.openAI, .gemini, .claude, .s1Mini, .none] {
      #expect(MeetingSummaryReferences.isQualified(provider: provider, model: "any") == false)
    }
  }

  // MARK: - The checks one by one, against a document the production builder made

  struct Fixture {
    var document: MeetingSummaryDocument?
    var saved: MeetingDocumentsManifest.Summary?
    var shown: String?
    var outOfDate = false
    var sources: MeetingSummaryReferenceSources?
  }

  static let noteID = UUID(uuidString: "0B3D6A61-2C1E-4F7B-8A0D-5E4C3B2A1F00")!
  static let inputs = SummaryInputs(
    transcriptSHA256: "t", notesRevision: 2, speakerNamesSHA256: "n",
    promptVersion: MeetingSummaryReferences.promptVersion, providerID: "ollama",
    configurationSHA256: "c")
  static let fixtureSources = MeetingSummaryReferenceSources(
    turns: [
      .init(id: "a", speaker: "Priya", text: "I will send the deck by Monday."),
      .init(id: "b", speaker: nil, text: "Pricing stays the same this year."),
    ],
    notes: [.init(blockID: noteID, text: "Ask legal about the contract")])
  static let tagged = """
    ## Action items
    - I will send the deck by Monday. [T1]
    - Priya will send the deck by Monday. [T1]
    - I will send the deck by Monday and pricing stays the same. [T1][T2]
    - Ask legal about the contract [N1]
    - I will send the deck by Monday. [T2][T1]
    """

  static func fixture() throws -> Fixture {
    let summary = MeetingSummaryReferences.strippingTags(tagged)
    let document = try #require(
      MeetingSummaryReferences.document(
        taggedSummary: tagged, summary: summary, sources: fixtureSources, inputs: inputs))
    return Fixture(
      document: document,
      saved: .init(sha256: MeetingDocumentHash.sha256(summary), origin: .generated, inputs: inputs),
      shown: summary, sources: fixtureSources)
  }

  static func check(_ fixture: Fixture, item index: Int) -> [MeetingSummarySource]? {
    let validator = MeetingSummaryReferenceValidator(
      dependencies: .init(
        storedDocument: { _ in fixture.document }, savedSummary: { _ in fixture.saved },
        shownSummary: { _ in fixture.shown }, isOutOfDate: { _ in fixture.outOfDate },
        sources: { _ in fixture.sources }))
    guard let item = fixture.document?.sections.first?.items[index] else { return nil }
    return validator.validatedSource(for: item.id, meetingID: UUID())?.sources
  }

  static let turnA = MeetingSummarySource.turn(
    id: "a", textSHA256: MeetingDocumentHash.sha256("I will send the deck by Monday."))

  @Test("whole-claim lines link; reworded and mixed lines do not; extra tags are dropped")
  func claims() throws {
    let fixture = try Self.fixture()
    #expect(Self.check(fixture, item: 0) == [Self.turnA])
    #expect(Self.check(fixture, item: 1) == nil)
    #expect(Self.check(fixture, item: 2) == nil)
    #expect(
      Self.check(fixture, item: 3) == [
        .note(
          blockID: Self.noteID,
          textSHA256: MeetingDocumentHash.sha256("Ask legal about the contract"))
      ])
    // The model also named a turn that does not hold the line: only the supporting one links.
    #expect(Self.check(fixture, item: 4) == [Self.turnA])
  }

  @Test("any disagreement between the document and the meeting now hides every link")
  func staleOrDamaged() throws {
    let base = try Self.fixture()
    #expect(Self.check(base, item: 0) != nil)
    let document = try #require(base.document)

    var fixture = base
    fixture.outOfDate = true
    #expect(Self.check(fixture, item: 0) == nil)

    fixture = base
    fixture.saved = .init(sha256: base.saved!.sha256, origin: .userEdited, inputs: Self.inputs)
    #expect(Self.check(fixture, item: 0) == nil)

    fixture = base
    var other = Self.inputs
    other.notesRevision += 1
    fixture.saved = .init(sha256: base.saved!.sha256, origin: .generated, inputs: other)
    #expect(Self.check(fixture, item: 0) == nil)

    fixture = base
    fixture.saved = .init(sha256: "different", origin: .generated, inputs: Self.inputs)
    #expect(Self.check(fixture, item: 0) == nil)

    fixture = base
    fixture.shown = (base.shown ?? "") + " "
    #expect(Self.check(fixture, item: 0) == nil)

    // A summary written before references (prompt 5) or a document of an unknown version.
    var legacy = Self.inputs
    legacy.promptVersion = MeetingSummary.promptVersion
    fixture = base
    fixture.document = MeetingSummaryDocument(
      inputs: legacy, renderedMarkdownSHA256: document.renderedMarkdownSHA256,
      sections: document.sections)
    fixture.saved = .init(sha256: base.saved!.sha256, origin: .generated, inputs: legacy)
    #expect(Self.check(fixture, item: 0) == nil)
    fixture = base
    fixture.document = MeetingSummaryDocument(
      version: 2, inputs: Self.inputs, renderedMarkdownSHA256: document.renderedMarkdownSHA256,
      sections: document.sections)
    #expect(Self.check(fixture, item: 0) == nil)

    // No sources known now, or the cited turn is gone.
    fixture = base
    fixture.sources = nil
    #expect(Self.check(fixture, item: 0) == nil)
    fixture.sources = MeetingSummaryReferenceSources(
      turns: [Self.fixtureSources.turns[1]], notes: Self.fixtureSources.notes)
    #expect(Self.check(fixture, item: 0) == nil)
    // The note's text changed.
    fixture.sources = MeetingSummaryReferenceSources(
      turns: Self.fixtureSources.turns,
      notes: [.init(blockID: Self.noteID, text: "Ask legal about the contract today")])
    #expect(Self.check(fixture, item: 3) == nil)
  }

  @Test("a tampered range or quote never links")
  func tampered() throws {
    let base = try Self.fixture()
    let document = try #require(base.document)
    func with(_ citation: MeetingSummaryCitation) -> Fixture {
      var items = document.sections[0].items
      items[0] = MeetingSummaryItem(id: items[0].id, text: items[0].text, citations: [citation])
      var fixture = base
      fixture.document = MeetingSummaryDocument(
        inputs: document.inputs, renderedMarkdownSHA256: document.renderedMarkdownSHA256,
        sections: [
          MeetingSummarySection(
            id: document.sections[0].id, title: document.sections[0].title, items: items)
        ])
      return fixture
    }
    let quote = "I will send the deck by Monday."
    #expect(
      Self.check(with(.init(source: Self.turnA, quote: quote, rangeUTF16: 0..<31)), item: 0) != nil)
    #expect(
      Self.check(with(.init(source: Self.turnA, quote: quote, rangeUTF16: 1..<31)), item: 0) == nil)
    #expect(
      Self.check(with(.init(source: Self.turnA, quote: quote, rangeUTF16: 0..<40)), item: 0) == nil)
    #expect(
      Self.check(with(.init(source: Self.turnA, quote: "", rangeUTF16: 0..<0)), item: 0) == nil)
    let wrongHash = MeetingSummarySource.turn(id: "a", textSHA256: "0")
    #expect(
      Self.check(with(.init(source: wrongHash, quote: quote, rangeUTF16: 0..<31)), item: 0) == nil)
    // A real passage that is not the whole line.
    #expect(
      Self.check(with(.init(source: Self.turnA, quote: "the deck", rangeUTF16: 12..<20)), item: 0)
        == nil)
  }
}
