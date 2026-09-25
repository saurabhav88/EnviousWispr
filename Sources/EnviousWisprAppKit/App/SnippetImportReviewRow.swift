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
    case .existing(let trigger):
      return String(
        localized: "You have this, as \u{201C}\(trigger)\u{201D}.",
        comment:
          "Snippets, import review: a row's note. %@ is the user's existing trigger; use this language's quotation marks."
      )
    case .duplicateInBatch:
      return String(
        localized: "Already listed above.",
        comment: "Snippets, import review: a row's note when the same trigger appears twice.")
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
      return added == 1
        ? String(
          localized: "Added 1 snippet. Say your keyword, then the trigger, and it's pasted.",
          comment: "Snippets, import result: one snippet added.")
        : String(
          localized:
            "Added \(String(added)) snippets. Say your keyword, then the trigger, and it's pasted.",
          comment: "Snippets, import result. %@ is the number of snippets added, never 1.")
    case .nothingFound:
      return String(
        localized: "No snippets were found, and nothing was changed.",
        comment: "Snippets, import result: the source had no snippets.")
    case .nothingCompatible(let found):
      return found == 1
        ? String(
          localized: "Found 1 entry, but none could be imported. Nothing was changed.",
          comment: "Snippets, import result: one entry found, and it could not be imported.")
        : String(
          localized:
            "Found \(String(found)) entries, but none could be imported. Nothing was changed.",
          comment:
            "Snippets, import result: %@ is the number of entries found, never 1; none could be imported."
        )
    case .nothingApproved:
      return String(
        localized: "You skipped everything, so nothing was changed.",
        comment: "Snippets, import result: the user skipped every row.")
    case .failed(let message):
      return message
    }
  }

  /// The confirm button, whole, by count (#3142).
  static func confirmTitle(approvedCount count: Int) -> String {
    switch count {
    case 0:
      return String(
        localized: "Add nothing",
        comment: "Snippets, import snippets: confirm button when no snippet is chosen.")
    case 1:
      return String(
        localized: "Add 1 snippet",
        comment: "Snippets, import snippets: confirm button for one snippet.")
    default:
      return String(
        localized: "Add \(String(count)) snippets",
        comment:
          "Snippets, import snippets: confirm button. %@ is the number of snippets, never 1.")
    }
  }

  /// The paste box's count line, whole, by the two counts (#3142). `found` is never 0 here: the
  /// sheet says "No snippets found" first.
  static func pasteSummary(found: Int, skipped: Int) -> String {
    switch (found == 1, skipped) {
    case (true, 0):
      return String(
        localized: "1 snippet found.",
        comment: "Snippets, paste count: one snippet, nothing skipped.")
    case (false, 0):
      return String(
        localized: "\(String(found)) snippets found.",
        comment: "Snippets, paste count. %@ is the number of snippets, never 1.")
    case (true, 1):
      return String(
        localized: "1 snippet found, 1 line skipped.",
        comment: "Snippets, paste count: one snippet, one unreadable line.")
    case (false, 1):
      return String(
        localized: "\(String(found)) snippets found, 1 line skipped.",
        comment:
          "Snippets, paste count. %@ is the number of snippets, never 1; one unreadable line.")
    case (true, _):
      return String(
        localized: "1 snippet found, \(String(skipped)) lines skipped.",
        comment:
          "Snippets, paste count: one snippet. %@ is the number of unreadable lines, never 1.")
    case (false, _):
      return String(
        localized: "\(String(found)) snippets found, \(String(skipped)) lines skipped.",
        comment:
          "Snippets, paste count. The first %@ is snippets, the second unreadable lines; neither is 1."
      )
    }
  }

  /// The one-line summary above the review list: each count that is not zero, as its own whole
  /// phrase, then a localized list pattern for one, two or three phrases (#3142).
  static func reviewSummary(new: Int, existing: Int, duplicates: Int) -> String {
    var parts: [String] = []
    if new == 1 {
      parts.append(
        String(
          localized: "1 new snippet",
          comment: "Snippets, import review summary: one phrase of a list, one new snippet."))
    } else if new > 0 {
      parts.append(
        String(
          localized: "\(String(new)) new snippets",
          comment:
            "Snippets, import review summary: one phrase of a list. %@ is the number of new snippets, never 1."
        ))
    }
    if existing > 0 {
      parts.append(
        String(
          localized: "\(String(existing)) you already have",
          comment:
            "Snippets, import review summary: one phrase of a list. %@ is how many the user already has (1 or more)."
        ))
    }
    if duplicates > 0 {
      parts.append(
        String(
          localized: "\(String(duplicates)) listed twice",
          comment:
            "Snippets, import review summary: one phrase of a list. %@ is how many appear twice (1 or more)."
        ))
    }
    switch parts.count {
    case 0:
      return String(
        localized: "Nothing to review.",
        comment: "Snippets, import review summary: nothing in the source.")
    case 1:
      return String(
        localized: "snippetImport.summary.one", defaultValue: "\(parts[0]).",
        comment: "Snippets, import review summary: a sentence of one phrase. %@ is the phrase.")
    case 2:
      return String(
        localized: "snippetImport.summary.two", defaultValue: "\(parts[0]), \(parts[1]).",
        comment: "Snippets, import review summary: a sentence listing two phrases.")
    default:
      return String(
        localized: "snippetImport.summary.three",
        defaultValue: "\(parts[0]), \(parts[1]), \(parts[2]).",
        comment: "Snippets, import review summary: a sentence listing three phrases.")
    }
  }

  /// The notice for lines a source could not read, shown beside the rows that did come
  /// across. COUNTS only, never the text.
  static func noticeMessage(for notice: SnippetImportNotice) -> String {
    switch notice {
    case .incompatibleSourceEntriesExcluded(let count):
      return count == 1
        ? String(
          localized: "1 entry was left out because EnviousWispr can't use it.",
          comment: "Snippets, import review: notice, one entry could not be used.")
        : String(
          localized: "\(String(count)) entries were left out because EnviousWispr can't use them.",
          comment:
            "Snippets, import review: notice. %@ is the number of entries that could not be used, never 1."
        )
    case .linesSkipped(let count):
      return count == 1
        ? String(
          localized: "1 line skipped because it has no trigger and text.",
          comment: "Snippets, import review: notice, one unreadable line.")
        : String(
          localized: "\(String(count)) lines skipped because they have no trigger and text.",
          comment:
            "Snippets, import review: notice. %@ is the number of unreadable lines, never 1.")
    }
  }
}
