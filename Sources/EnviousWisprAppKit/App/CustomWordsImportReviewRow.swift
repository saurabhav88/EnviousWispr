import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation

/// A review decision (#1669, epic #1619 PR-F2c).
///
/// v1 offers exactly two (founder scope revision, 2026-07-18). Replace and
/// Keep Both are deliberately absent: no import source ships yet, so a v1
/// candidate carries only its main word, and a Replace would rewrite a
/// hand-tuned entry's spelling on the authority of nothing. Importing *with
/// your own aliases* is a later version, and arrives as an alias **merge**
/// offer built on PR-F2b's replacement machinery — not as a revived Replace.
enum CustomWordsImportDecision: Sendable, Equatable, CaseIterable {
  case add
  case skip
}

/// Result-screen copy, kept out of the view so it can be asserted directly
/// (#1669). The view renders these strings and adds nothing of its own.
enum CustomWordsImportResultCopy {
  static func message(for result: CustomWordsImportFlowModel.Result) -> String {
    switch result {
    case .completed(let added, let replaced):
      // v1 can only add, so the replaced count is mentioned only if a later
      // flow (backup restore) actually produced one — a v1 user must never
      // read "replaced 0".
      // Whole sentences chosen by the counts, never "word" or "words" spliced in (#3142).
      switch (added == 1, replaced > 0) {
      case (true, false):
        return String(
          localized: "Added 1 word. Your words are ready to use.",
          comment: "Your Words, import result: one word added.")
      case (false, false):
        return String(
          localized: "Added \(added) words. Your words are ready to use.",
          comment: "Your Words, import result: %lld is the number of words added, never 1.")
      case (true, true):
        return String(
          localized: "Added 1 word. Replaced \(replaced). Your words are ready to use.",
          comment:
            "Your Words, import result: one word added. %lld is the number of words replaced.")
      case (false, true):
        return String(
          localized: "Added \(added) words. Replaced \(replaced). Your words are ready to use.",
          comment:
            "Your Words, import result: the first %lld is the number of words added (never 1), the second the number replaced."
        )
      }
    case .nothingFound:
      return String(
        localized: "No words were found, and nothing was changed.",
        comment: "Your Words, import result: the source had no words.")
    case .nothingCompatible(let found):
      // Names what was there and why it did not come across, instead of
      // claiming the source was empty when it plainly was not.
      return found == 1
        ? String(
          localized: "Found 1 entry, but none were compatible. Nothing was changed.",
          comment: "Your Words, import result: one entry found, and it could not be imported.")
        : String(
          localized: "Found \(found) entries, but none were compatible. Nothing was changed.",
          comment:
            "Your Words, import result: %lld is the number of entries found, never 1; none could be imported."
        )
    case .nothingApproved:
      return String(
        localized: "You skipped everything, so nothing was changed.",
        comment: "Your Words, import result: the user added nothing.")
    case .failed(let message):
      return message
    }
  }

  static func droppedCollisionMessage(count: Int) -> String {
    count == 1
      ? String(
        localized: "1 alternate spelling was skipped, because other words already use them.",
        comment: "Your Words, import result: one misheard form was not added.")
      : String(
        localized:
          "\(count) alternate spellings were skipped, because other words already use them.",
        comment:
          "Your Words, import result: %lld is the number of misheard forms not added, never 1.")
  }
}

/// One row on the Review & Merge screen: a comparison, the decision the user
/// has selected for it, and the pre-resolved copy the screen renders.
///
/// Identity is the comparison's own UUID, never an array index, so re-ordering
/// or a stale-triggered rebuild can never move a decision onto another word.
///
/// The two note strings are resolved at build time rather than computed on
/// demand because naming a collision's owner requires the existing library,
/// which this row deliberately does not retain.
struct CustomWordsImportReviewRow: Identifiable, Sendable, Equatable {
  let comparison: CustomWordsImportComparison
  /// Non-nil only when the word already exists in some form; this is the
  /// "you already have this one" line.
  let matchSummary: String?
  /// Non-nil when this candidate's aliases would land on a trigger another
  /// word already owns. Informational only — it never changes which decisions
  /// are available, and PR-F2b is the guarantee that a colliding alias is
  /// never persisted.
  let collisionNote: String?
  var decision: CustomWordsImportDecision

  var id: UUID { comparison.id }
  var canonical: String { comparison.candidate.canonical }
  var allowedDecisions: [CustomWordsImportDecision] {
    Self.allowedDecisions(for: comparison.classification)
  }
  var isAddable: Bool { allowedDecisions.contains(.add) }

  /// Classification-gated, never universal: the screen must not offer an
  /// action persistence would refuse. Only a genuinely new word can be added;
  /// every match classification is Skip-only.
  ///
  /// `.fuzzy` is unreachable in v1 — the flow passes
  /// `CustomWordsImportFuzzyPolicy.disabled` — but it is handled here rather
  /// than trapped, so a future caller that arms the policy cannot produce an
  /// unhandled row.
  static func allowedDecisions(
    for classification: CustomWordsImportClassification
  ) -> [CustomWordsImportDecision] {
    switch classification {
    case .new: return [.add, .skip]
    case .exact, .variant, .fuzzy, .ambiguous: return [.skip]
    }
  }

  static func defaultDecision(
    for classification: CustomWordsImportClassification
  ) -> CustomWordsImportDecision {
    switch classification {
    case .new: return .add
    case .exact, .variant, .fuzzy, .ambiguous: return .skip
    }
  }

  /// Build the review rows for a completed comparison run.
  ///
  /// `existingWords` is needed only to name collision owners; no reference to
  /// it is retained past this call.
  static func rows(
    from comparisons: [CustomWordsImportComparison],
    existingWords: [CustomWord]
  ) -> [CustomWordsImportReviewRow] {
    var namesByID: [UUID: String] = [:]
    for word in existingWords { namesByID[word.id] = word.canonical }

    return comparisons.map { comparison in
      CustomWordsImportReviewRow(
        comparison: comparison,
        matchSummary: matchSummary(for: comparison.classification),
        collisionNote: collisionNote(
          for: comparison.collidingAliases, namesByID: namesByID),
        decision: defaultDecision(for: comparison.classification)
      )
    }
  }

  private static func matchSummary(
    for classification: CustomWordsImportClassification
  ) -> String? {
    switch classification {
    case .new:
      return nil
    case .exact(let existing):
      return String(
        localized: "You already have \(existing.canonical).",
        comment: "Your Words, import review: a row's note. %@ is the word.")
    case .variant(let existing, _):
      return String(
        localized: "You already have this, as another spelling of \(existing.canonical).",
        comment: "Your Words, import review: a row's note. %@ is the existing word.")
    case .fuzzy(let existing, _):
      return String(
        localized: "This looks like \(existing.canonical), which you already have.",
        comment: "Your Words, import review: a row's note. %@ is the existing word.")
    case .ambiguous:
      return String(
        localized: "This matches more than one word you already have.",
        comment: "Your Words, import review: a row's note.")
    }
  }

  /// Unreachable in v1, deliberately kept: the compare engine only records a
  /// collision for a candidate whose aliases are `.supplied`
  /// (`CustomWordsImportCompareEngine.detectAliasCollisions`), and no v1
  /// source supplies any — every candidate's alias field is `.unspecified`.
  /// The first real producer is backup restore (PR-E1/U1), which is also when
  /// this copy first reaches a user. It is written here rather than deferred
  /// because F2a already ships the detection and the display is a plain
  /// rendering of it, not new machinery for a hypothetical state.
  ///
  /// The wording is deliberately conditional ("may not be"). Whether a given
  /// alias actually lands depends on which rows the user approves — a
  /// candidate that lost an alias to another *incoming* candidate wins it back
  /// if that other row is skipped. Recomputing this per decision change would
  /// be decision-aware display logic for a case v1 cannot produce; honest
  /// conditional copy is correct in every future instead. PR-F2b's receipt
  /// reports what was actually dropped, and the result screen shows that count.
  static func collisionNote(
    for collisions: [CustomWordsImportAliasCollision],
    namesByID: [UUID: String]
  ) -> String? {
    guard !collisions.isEmpty else { return nil }
    // Name the owner when we can. A collision can be held by another incoming
    // candidate rather than an existing word, in which case there is no name
    // to look up and the honest line just states the outcome.
    if collisions.count == 1, let owner = namesByID[collisions[0].heldBy] {
      return String(
        localized:
          "The spelling \"\(collisions[0].alias)\" may not be added, because \(owner) already uses it.",
        comment:
          "Your Words, import review: a row's note. The first %@ is a misheard form, the second the word that has it; use this language's quotation marks."
      )
    }
    let count = collisions.count
    return count == 1
      ? String(
        localized: "1 alternate spelling may not be added, because other words already use them.",
        comment: "Your Words, import review: a row's note: one misheard form.")
      : String(
        localized:
          "\(count) alternate spellings may not be added, because other words already use them.",
        comment:
          "Your Words, import review: a row's note. %lld is the number of misheard forms, never 1.")
  }
}
