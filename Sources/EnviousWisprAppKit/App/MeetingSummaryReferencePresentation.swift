import EnviousWisprCore
import EnviousWisprLLM
import Foundation

/// #3147 PR4A (D5): sources a summary item may link to. Only the validator in this file can make
/// one (the initializer is file-private), so no view can show a link the validator did not
/// accept.
struct ValidatedMeetingSummarySource: Equatable, Sendable {
  let itemID: UUID
  let sources: [MeetingSummarySource]

  fileprivate init(itemID: UUID, sources: [MeetingSummarySource]) {
    self.itemID = itemID
    self.sources = sources
  }
}

/// #3147 PR4A (D5): decides, every time it is asked, whether a summary item may show View
/// source. The saved reference document is only a set of candidates; an item links only when
/// all of this holds now:
/// - the document has a schema this build knows and the summary prompt version that writes
///   references;
/// - the meeting's summary is the generated one (never the user's own text), is not out of date
///   (transcript, its attempt, notes revision, speaker names, prompt, provider and facts are
///   all current), records exactly the document's inputs, and its text, as saved and as shown,
///   hashes to the document's Markdown hash;
/// - a cited source still exists with the recorded text hash, the recorded range lies inside
///   it and slices to exactly the recorded quote, and that quote is the WHOLE item with only
///   whitespace normalized.
/// Only the citations meeting the last point are returned; an item with none gets no link.
/// Paraphrase, partial support, a claim mixing supported and unsupported words, an edited,
/// legacy or stale summary, and a changed or renamed source all fail closed. No model is asked.
@MainActor
final class MeetingSummaryReferenceValidator: MeetingSummaryReferencing {
  struct Dependencies {
    /// The saved reference document (`MeetingSummaryReferences.sidecarFileName`), decoded with
    /// `MeetingSummaryReferences.decode`; nil when there is none or it cannot be read.
    var storedDocument: @MainActor (UUID) -> MeetingSummaryDocument?
    /// The saved summary's manifest entry (`documents.json` `summary`).
    var savedSummary: @MainActor (UUID) -> MeetingDocumentsManifest.Summary?
    /// The summary text shown now, unsaved typing included.
    var shownSummary: @MainActor (UUID) -> String?
    /// `MeetingSummaryOwner.isOutOfDate`.
    var isOutOfDate: @MainActor (UUID) -> Bool
    /// The current sources, from the same projection the summary owner reads.
    var sources: @MainActor (UUID) -> MeetingSummaryReferenceSources?
  }

  private let deps: Dependencies

  init(dependencies: Dependencies) {
    deps = dependencies
  }

  func document(for meetingID: UUID) -> MeetingSummaryDocument? {
    guard let document = deps.storedDocument(meetingID),
      document.version == MeetingSummaryDocument.currentVersion,
      document.inputs.promptVersion == MeetingSummaryReferences.promptVersion,
      let saved = deps.savedSummary(meetingID), saved.origin == .generated,
      saved.inputs == document.inputs,
      MeetingDocumentHash.sameBytes(saved.sha256, document.renderedMarkdownSHA256),
      let shown = deps.shownSummary(meetingID),
      MeetingDocumentHash.sameBytes(
        MeetingDocumentHash.sha256(shown), document.renderedMarkdownSHA256),
      !deps.isOutOfDate(meetingID)
    else { return nil }
    return document
  }

  func validatedSource(for itemID: UUID, meetingID: UUID) -> ValidatedMeetingSummarySource? {
    guard let document = document(for: meetingID),
      let item = document.sections.lazy.flatMap(\.items).first(where: { $0.id == itemID }),
      !item.citations.isEmpty, let sources = deps.sources(meetingID)
    else { return nil }
    let supported = Self.supportingSources(of: item, in: sources)
    guard !supported.isEmpty else { return nil }
    return ValidatedMeetingSummarySource(itemID: itemID, sources: supported)
  }

  /// The citations of `item` that hold the whole item in a current source, in order.
  static func supportingSources(
    of item: MeetingSummaryItem, in sources: MeetingSummaryReferenceSources
  ) -> [MeetingSummarySource] {
    var turns: [String: String] = [:]
    for turn in sources.turns where turns[turn.id] == nil { turns[turn.id] = turn.text }
    var notes: [UUID: String] = [:]
    for note in sources.notes where notes[note.blockID] == nil { notes[note.blockID] = note.text }
    var result: [MeetingSummarySource] = []
    for citation in item.citations {
      let current: String?
      let recordedSHA: String
      switch citation.source {
      case .turn(let id, let sha):
        current = turns[id]
        recordedSHA = sha
      case .note(let blockID, let sha):
        current = notes[blockID]
        recordedSHA = sha
      }
      guard let current,
        MeetingDocumentHash.sameBytes(MeetingDocumentHash.sha256(current), recordedSHA),
        !citation.quote.isEmpty, !citation.rangeUTF16.isEmpty,
        MeetingDocumentHash.sameBytes(
          MeetingSummaryReferences.slice(current, citation.rangeUTF16), citation.quote),
        MeetingSummaryReferences.sameClaim(citation.quote, item.text),
        !result.contains(citation.source)
      else { continue }
      result.append(citation.source)
    }
    return result
  }
}
