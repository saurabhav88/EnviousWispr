import EnviousWisprCore
import Foundation

/// Turns pasted text into import candidates (#1681, PR-P1).
///
/// Deterministic and total: no model call, no network, no availability check.
/// Whatever the user pasted either becomes a word or is honestly reported as
/// nothing to import.
///
/// **v1 ships no on-device variant suggestions.** The adopted plan pairs Paste
/// with `WordSuggestionService`, and that stage remains the right design — a
/// pipeline step between compare and review, filling the candidate's
/// never-authoritative `suggestedAliases` channel. It is deliberately deferred
/// so the plain path can be proven first; nothing here forecloses it.
package enum PasteWordsParser {
  /// Separators, and only these.
  ///
  /// Semicolon, slash, hyphen, and plain space are deliberately NOT separators:
  /// "Envious Labs" is one word, "C++"/"C#"/".NET" must survive intact, and a
  /// hyphenated surname is not two people. Being conservative here is why the
  /// user can paste a messy list and still get what they meant — a wrong split
  /// silently invents words nobody typed.
  private static let separators = CharacterSet(charactersIn: ",\n\r")

  package static func parse(_ text: String) -> [String] {
    var seen = Set<String>()
    var results: [String] = []

    for piece in text.components(separatedBy: separators) {
      let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      // Deduplicate on the compare engine's own key, so "GitHub" and "github"
      // in one paste collapse the same way they would against the library —
      // and the FIRST spelling wins, because that is the one the user typed
      // first and has no reason to see replaced by a later casing.
      let key = CustomWordsImportCompareEngine.normalize(trimmed)
      guard !key.isEmpty, seen.insert(key).inserted else { continue }
      results.append(trimmed)
    }
    return results
  }
}

/// Pasting more than the shared ceiling allows (#1683).
package enum PasteWordsImportError: LocalizedError, Sendable, Equatable {
  case tooManyWords(found: Int, limit: Int)

  package var errorDescription: String? {
    switch self {
    case .tooManyWords(let found, let limit):
      return
        "That's \(found) words, which is more than EnviousWispr can import at once "
        + "(\(limit)). Try pasting a smaller batch."
    }
  }
}

/// The pasted-text import source.
package struct PasteWordsImportSource: CustomWordsImportSource {
  package static let sourceID = "paste"

  private let text: String

  package init(text: String) {
    self.text = text
  }

  /// `@concurrent` so a very large paste is parsed off the caller's actor
  /// rather than on the main one (code review r2).
  @concurrent package func loadCandidates() async throws -> CustomWordsImportBatch {
    let canonicals = PasteWordsParser.parse(text)
    // The same ceiling file import enforces. A limit that applied to one door
    // and not the other would just be a bug with a longer fuse.
    guard canonicals.count <= CustomWordsImportLimits.maximumCandidates else {
      throw PasteWordsImportError.tooManyWords(
        found: canonicals.count, limit: CustomWordsImportLimits.maximumCandidates)
    }
    return CustomWordsImportBatch(
      sourceID: Self.sourceID,
      sourceDisplayName: "Pasted words",
      // Every authority field stays `.unspecified`: pasted text carries no
      // alias data and no opinion about category, priority, strictness, or
      // case sensitivity, so a Replace built from it must never claim to.
      candidates: canonicals.map { CustomWordsImportCandidate(canonical: $0) }
    )
  }
}
