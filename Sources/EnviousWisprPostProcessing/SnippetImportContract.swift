import EnviousWisprCore
import Foundation

// Shared contract for Snippet import (#2997).
//
// Every source — paste, a chosen file, and (PR-B) each rival-app adapter — implements
// `SnippetImportSource` and returns a `SnippetImportBatch`. Nothing downstream (the review
// builder, the sheet, the store's bulk insert) knows which source produced a candidate.
// A snippet-shaped twin of `CustomWordsImportContract`, kept separate on purpose: a snippet
// is a trigger plus a verbatim expansion, with none of a word's aliases, category, priority,
// fuzzy matching, enrichment or Replace, and the two have different comparison keys and
// different ceilings. Lives in PostProcessing rather than Core because only this module and
// AppKit consume it.

/// Transient import candidate. `id` is review-row identity only; a committed snippet is
/// minted with a fresh `Snippet.id`, so importing the same file twice never reuses ids.
package struct SnippetImportCandidate: Identifiable, Sendable, Hashable {
  package let id: UUID
  package var trigger: String
  package var expansion: String

  package init(id: UUID = UUID(), trigger: String, expansion: String) {
    self.id = id
    self.trigger = trigger
    self.expansion = expansion
  }

  /// The candidate as it would be STORED: trigger trimmed, expansion untouched. An expansion
  /// is delivered exactly as the source held it, so trimming it would change what a user
  /// gets pasted.
  package func trimmed() -> SnippetImportCandidate {
    var copy = self
    copy.trigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
    return copy
  }
}

/// Counts a source hands back beside its candidates. COUNTS only, never content: a
/// competitor's excluded text and a user's unparsed line never reach our UI or our telemetry.
/// Emitted whenever the count is positive, not only when nothing survived, so a mixed batch
/// tells the user "3 left out" beside the rows that did come across.
package enum SnippetImportNotice: Sendable, Equatable {
  /// Source rows deliberately refused: disabled, deleted, placeholder, or empty text.
  case incompatibleSourceEntriesExcluded(count: Int)
  /// Pasted or file lines that did not parse into a trigger and some text.
  case linesSkipped(count: Int)
}

/// Shared ceilings every snippet source honours (#2997).
///
/// One home so paste, file and app import cannot drift apart: the review builder, the review
/// list and the commit pay the same cost per candidate whichever door it came through.
package enum SnippetImportLimits {
  /// More than this is not something a person can review; a snippet list is far smaller
  /// than a vocabulary (Dictionary allows 25,000 words).
  package static let maximumCandidates = 5_000
  /// Untrusted input (a plain list, a CSV, a paste): a snippet list is small, so anything
  /// larger is a mistaken selection.
  package static let maximumImportFileBytes = 16 * 1024 * 1024
  /// Our OWN export gets a higher, still finite, ceiling (same reasoning as
  /// `CustomWordsImportLimits.maximumExportedFileBytes`): the marker is self-declared, so a
  /// crafted file must have a known worst case.
  package static let maximumExportedFileBytes = 64 * 1024 * 1024
  /// A trigger is a short spoken phrase.
  package static let maximumTriggerScalars = 512
  /// An expansion may be a paragraph, never a document.
  package static let maximumExpansionScalars = 20_000
  /// Total stored surface (every trigger plus every expansion) a batch may carry, checked
  /// after decoding. Without it a file at the candidate ceiling with every expansion at ITS
  /// ceiling would be 100M scalars to validate, index and render.
  package static let maximumStoredScalars = 4_000_000
}

package struct SnippetImportBatch: Sendable, Equatable {
  /// Stable source identifier, for telemetry's closed `source` vocabulary. Never a filename.
  package let sourceID: String
  /// What the UI shows ("Wispr Flow", "CSV file", ...).
  package let sourceDisplayName: String
  package let candidates: [SnippetImportCandidate]
  package let notices: [SnippetImportNotice]

  package init(
    sourceID: String,
    sourceDisplayName: String,
    candidates: [SnippetImportCandidate],
    notices: [SnippetImportNotice] = []
  ) {
    self.sourceID = sourceID
    self.sourceDisplayName = sourceDisplayName
    self.candidates = candidates
    self.notices = notices
  }

  /// Refuses the WHOLE batch if any candidate is unstorable, and returns the batch in
  /// stored form (triggers trimmed).
  ///
  /// All-or-nothing on purpose, as for words: silently dropping bad rows would show a review
  /// screen that quietly disagrees with the file, and importing them would put invisible
  /// characters inside a trigger nobody can then say. A refusal names the offending entry.
  ///
  /// Applies the SCALAR ceilings here, after decoding; the byte ceilings bound the read that
  /// precedes this. Finite ceilings may refuse an oversized existing export, and that is a
  /// named refusal rather than a truncation.
  package func validated() throws -> SnippetImportBatch {
    guard candidates.count <= SnippetImportLimits.maximumCandidates else {
      throw SnippetImportValidationError.tooManySnippets(limit: SnippetImportLimits.maximumCandidates)
    }
    var surface = 0
    var stored: [SnippetImportCandidate] = []
    stored.reserveCapacity(candidates.count)
    for (index, raw) in candidates.enumerated() {
      if index.isMultiple(of: 1_000) { try Task.checkCancellation() }
      let candidate = raw.trimmed()

      let triggerScalars = candidate.trigger.unicodeScalars.count
      guard triggerScalars <= SnippetImportLimits.maximumTriggerScalars else {
        throw SnippetImportValidationError.triggerTooLong(
          limit: SnippetImportLimits.maximumTriggerScalars)
      }
      // A trigger must have spoken tokens (the same rule the edit sheet applies through
      // `SnippetsManager.validate`), and it must be storable text.
      guard Snippet(trigger: candidate.trigger, expansion: "x").collisionKey != nil,
        CustomWordsImportTextPolicy.isAcceptableStoredValue(candidate.trigger)
      else {
        throw SnippetImportValidationError.unusableTrigger(trigger: candidate.trigger)
      }

      let expansionScalars = candidate.expansion.unicodeScalars.count
      guard expansionScalars <= SnippetImportLimits.maximumExpansionScalars else {
        throw SnippetImportValidationError.expansionTooLong(
          trigger: candidate.trigger, limit: SnippetImportLimits.maximumExpansionScalars)
      }
      guard CustomWordsImportTextPolicy.isAcceptableMultilineStoredValue(candidate.expansion)
      else {
        throw SnippetImportValidationError.unusableExpansion(trigger: candidate.trigger)
      }

      surface += triggerScalars + expansionScalars
      guard surface <= SnippetImportLimits.maximumStoredScalars else {
        throw SnippetImportValidationError.tooMuchText(
          limit: SnippetImportLimits.maximumStoredScalars)
      }
      stored.append(candidate)
    }
    return SnippetImportBatch(
      sourceID: sourceID, sourceDisplayName: sourceDisplayName, candidates: stored,
      notices: notices)
  }
}

package protocol SnippetImportSource: Sendable {
  /// Stable identifier for telemetry's closed `source` vocabulary.
  var sourceID: String { get }
  /// Produce candidates. Callers do NOT call this; they call `loadCandidates()`.
  func loadRawCandidates() async throws -> SnippetImportBatch
}

extension SnippetImportSource {
  /// The only entry point callers use, so validation is a property of importing rather
  /// than of one importer: a new source gets it by existing and cannot opt out.
  package func loadCandidates() async throws -> SnippetImportBatch {
    try await loadRawCandidates().validated()
  }
}

/// A candidate that cannot be stored, and why (#2997). Sentences are source-neutral: the same
/// validator runs for pasted text, files and apps.
package enum SnippetImportValidationError: LocalizedError, Sendable, Equatable {
  case tooManySnippets(limit: Int)
  case tooMuchText(limit: Int)
  case triggerTooLong(limit: Int)
  case expansionTooLong(trigger: String, limit: Int)
  case unusableTrigger(trigger: String)
  case unusableExpansion(trigger: String)

  package var errorDescription: String? {
    switch self {
    case .tooManySnippets(let limit):
      return
        "That has more than \(limit) snippets, which is more than EnviousWispr can import "
        + "at once. Nothing was imported."
    case .tooMuchText(let limit):
      return
        "That has more than \(limit) characters of snippet text in total, which is more than "
        + "EnviousWispr can import at once. Nothing was imported."
    case .triggerTooLong(let limit):
      return
        "That contains a trigger longer than \(limit) characters, which is too long to say. "
        + "Nothing was imported."
    case .expansionTooLong(let trigger, let limit):
      return
        "The text for \(CustomWordsImportValidationError.describe(trigger)) is longer than "
        + "\(limit) characters. Nothing was imported."
    case .unusableTrigger(let trigger):
      // Sanitised before display: the very character rejected for rendering deceptively
      // must not be rendered into the message explaining its rejection.
      return
        "That contains a trigger EnviousWispr can't use "
        + "(\(CustomWordsImportValidationError.describe(trigger))). Nothing was imported."
    case .unusableExpansion(let trigger):
      return
        "The text for \(CustomWordsImportValidationError.describe(trigger)) contains "
        + "characters EnviousWispr can't store. Nothing was imported."
    }
  }
}
