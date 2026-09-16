import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation

/// A review decision for one imported snippet (#2997). Add or skip; there is no Replace,
/// because an import never edits a snippet the user already has.
enum SnippetImportDecision: Sendable, Equatable, CaseIterable {
  case add
  case skip
}

/// One row on the Review screen: the candidate, how it relates to what the user already has,
/// and the decision selected for it.
///
/// Identity is the candidate's own review id, never an array index, so a stale-triggered
/// rebuild can never move a decision onto another snippet.
struct SnippetImportReviewRow: Identifiable, Sendable, Equatable {
  enum Status: Sendable, Equatable {
    case new
    /// The user already has a snippet on these spoken words; `trigger` is theirs, as typed.
    case existing(trigger: String)
    /// An earlier row in this same batch already claims these spoken words.
    case duplicateInBatch
  }

  let candidate: SnippetImportCandidate
  let status: Status
  var decision: SnippetImportDecision

  var id: UUID { candidate.id }
  var trigger: String { candidate.trigger }
  var expansion: String { candidate.expansion }

  /// Status-gated, never universal: the screen must not offer an action the store would
  /// refuse. Only a genuinely new snippet can be added; every other status is Skip-only.
  var allowedDecisions: [SnippetImportDecision] { Self.allowedDecisions(for: status) }
  var isAddable: Bool { allowedDecisions.contains(.add) }

  static func allowedDecisions(for status: Status) -> [SnippetImportDecision] {
    switch status {
    case .new: return [.add, .skip]
    case .existing, .duplicateInBatch: return [.skip]
    }
  }

  static func defaultDecision(for status: Status) -> SnippetImportDecision {
    switch status {
    case .new: return .add
    case .existing, .duplicateInBatch: return .skip
    }
  }

  /// The "you already have this" line, resolved at build time from the existing trigger.
  var statusNote: String? {
    switch status {
    case .new: return nil
    case .existing(let trigger): return "You have this, as \u{201C}\(trigger)\u{201D}."
    case .duplicateInBatch: return "Already listed above."
    }
  }
}

/// Builds review rows from a validated batch against the user's current list (#2997).
///
/// `@concurrent`, pure, and O(n + m): one `collisionKey` per existing snippet into a
/// key-to-trigger dictionary (so a hit can name the trigger the user typed), then one
/// lookup per candidate against that dictionary and a separate set of keys seen so far in
/// the batch. The existing list is uncapped, which is why the dictionary is built from IT
/// rather than probing it per candidate. A candidate with no key cannot reach here:
/// `SnippetImportBatch.validated()` refused it.
enum SnippetImportRowBuilder {
  @concurrent static func rows(
    candidates: [SnippetImportCandidate], existing: [Snippet]
  ) async throws -> [SnippetImportReviewRow] {
    var existingByKey: [String: String] = [:]
    for (index, snippet) in existing.enumerated() {
      if index.isMultiple(of: 1_000) { try Task.checkCancellation() }
      // The FIRST owner is kept, as the store's collision check names it.
      if let key = snippet.collisionKey, existingByKey[key] == nil {
        existingByKey[key] = snippet.trigger
      }
    }
    var seenInBatch = Set<String>()
    var rows: [SnippetImportReviewRow] = []
    rows.reserveCapacity(candidates.count)
    for (index, candidate) in candidates.enumerated() {
      if index.isMultiple(of: 1_000) { try Task.checkCancellation() }
      let key =
        Snippet(trigger: candidate.trigger, expansion: candidate.expansion).collisionKey ?? ""
      let status: SnippetImportReviewRow.Status
      if let owner = existingByKey[key] {
        status = .existing(trigger: owner)
      } else if !seenInBatch.insert(key).inserted {
        status = .duplicateInBatch
      } else {
        status = .new
      }
      rows.append(
        SnippetImportReviewRow(
          candidate: candidate, status: status,
          decision: SnippetImportReviewRow.defaultDecision(for: status)))
    }
    return rows
  }
}

/// Result-screen copy, kept out of the view so it can be asserted directly (#2997). The view
/// renders these strings and adds nothing of its own.
enum SnippetImportResultCopy {
  static func message(for result: SnippetImportFlowModel.Result) -> String {
    switch result {
    case .completed(let added):
      return "Added \(added) \(added == 1 ? "snippet" : "snippets"). Say your keyword, then the trigger, and it's pasted."
    case .nothingFound:
      return "No snippets were found, and nothing was changed."
    case .nothingCompatible(let found):
      let entries = found == 1 ? "entry" : "entries"
      return "Found \(found) \(entries), but none could be imported. Nothing was changed."
    case .nothingApproved:
      return "You skipped everything, so nothing was changed."
    case .failed(let message):
      return message
    }
  }

  /// The one-line summary above the review list.
  static func reviewSummary(new: Int, existing: Int, duplicates: Int) -> String {
    var parts: [String] = []
    if new > 0 { parts.append("\(new) new \(new == 1 ? "snippet" : "snippets")") }
    if existing > 0 { parts.append("\(existing) you already have") }
    if duplicates > 0 { parts.append("\(duplicates) listed twice") }
    guard !parts.isEmpty else { return "Nothing to review." }
    return parts.joined(separator: ", ") + "."
  }

  /// The notice for lines a source could not read, shown beside the rows that did come
  /// across. COUNTS only, never the text.
  static func noticeMessage(for notice: SnippetImportNotice) -> String {
    switch notice {
    case .incompatibleSourceEntriesExcluded(let count):
      return "\(count) \(count == 1 ? "entry was" : "entries were") left out because EnviousWispr can't use \(count == 1 ? "it" : "them")."
    case .linesSkipped(let count):
      return "\(count) \(count == 1 ? "line" : "lines") skipped because \(count == 1 ? "it has" : "they have") no trigger and text."
    }
  }
}
