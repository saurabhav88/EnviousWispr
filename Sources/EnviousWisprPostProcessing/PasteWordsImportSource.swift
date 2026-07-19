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
  /// Tab IS a separator, by the same reasoning that excludes the others: it
  /// never appears inside a word. Treating it as ordinary whitespace instead
  /// stored it INSIDE a canonical term, where it is invisible — and comparison
  /// normalises it to a space, so the saved word could never match a
  /// transcript (Codex review, #1683).
  ///
  /// Semicolon, slash, hyphen, and plain space are deliberately NOT separators:
  /// "Envious Labs" is one word, "C++"/"C#"/".NET" must survive intact, and a
  /// hyphenated surname is not two people. Being conservative here is why the
  /// user can paste a messy list and still get what they meant — a wrong split
  /// silently invents words nobody typed.
  private static let separators = CharacterSet(charactersIn: ",\n\r\t")

  /// Scans the text ONCE, emitting words as it goes, and stops at `limit` + 1.
  ///
  /// The previous shape built every component first and checked the ceiling
  /// afterwards, so a 16 MB list of separators materialised millions of
  /// entries to then reject the file — spending exactly the memory the ceiling
  /// exists to save, with cancellation unobserved until it finished (Codex
  /// review, #1683).
  ///
  /// `split`/`components(separatedBy:)` cannot fix that: both build the whole
  /// array before any early exit can run. Only a character-by-character scan
  /// with its own buffer is genuinely incremental.
  ///
  /// One entry past the limit is enough for the caller to tell "at the limit"
  /// from "over" it.
  package static func parse(_ text: String, limit: Int? = nil) throws -> [String] {
    var seen = Set<String>()
    var results: [String] = []
    var buffer = ""
    // Whitespace seen since the last real character, held rather than buffered
    // so padding never counts toward a length. See the scan loop below.
    var pendingWhitespace: [Unicode.Scalar] = []
    var pendingWhitespaceOverflowed = false
    // One bound for both the buffer and the held whitespace: neither may grow
    // toward the size of the file.
    let memoryBound = CustomWordsImportLimits.maximumStoredValueScalars * 4
    let ceiling = limit.map { $0 + 1 }
    var scanned = 0
    // flush() reports "stop" for both success-with-ceiling-reached and a real
    // failure, so the failure is carried out rather than inferred.
    var lengthFailure: CustomWordsImportValidationError?

    func flush() -> Bool {
      // Whatever whitespace was being held is trailing padding at a boundary,
      // and trailing padding is not part of the entry.
      defer {
        buffer.removeAll(keepingCapacity: true)
        pendingWhitespace.removeAll(keepingCapacity: true)
        pendingWhitespaceOverflowed = false
      }
      let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
      // Skipped like any other blank line. A piece made only of invisible
      // joiners is noise in a pasted list, not a word the user meant — and
      // refusing the whole paste over one would be a strange way to treat
      // what is effectively an empty line (cloud review, #1683). A structured
      // file is different: there a blank word is a defect, and the validator
      // refuses it.
      // Skips only what is BLANK — an empty line, or a piece made of nothing
      // but joiners — the way this has always skipped whitespace. Deliberately
      // NOT the full acceptability check: a visible entry carrying a
      // disallowed character must reach the validator and be REPORTED, not
      // vanish from a list the user pasted (cloud review, #1683).
      guard !trimmed.isEmpty,
        CustomWordsImportTextPolicy.hasVisibleContent(trimmed)
      else { return true }
      // Length is judged on the TRIMMED value, matching the validator. Judging
      // the raw buffer counted padding as part of the word, so 513 spaces or a
      // heavily padded short entry failed as "too long" (cloud review, #1683).
      guard
        trimmed.unicodeScalars.count
          <= CustomWordsImportLimits.maximumStoredValueScalars
      else {
        lengthFailure = CustomWordsImportValidationError.wordTooLong(
          limit: CustomWordsImportLimits.maximumStoredValueScalars)
        return false
      }
      // Deduplicate on the compare engine's own key, so "GitHub" and "github"
      // in one paste collapse the same way they would against the library —
      // and the FIRST spelling wins, because that is the one the user typed
      // first and has no reason to see replaced by a later casing.
      let key = CustomWordsImportCompareEngine.normalize(trimmed)
      guard !key.isEmpty, seen.insert(key).inserted else { return true }
      results.append(trimmed)
      return ceiling.map { results.count < $0 } ?? true
    }

    for scalar in text.unicodeScalars {
      scanned += 1
      if scanned.isMultiple(of: 100_000) { try Task.checkCancellation() }
      if separators.contains(scalar) {
        guard flush() else {
          if let lengthFailure { throw lengthFailure }
          return results
        }
        continue
      }
      // Padding never reaches the buffer, so it can never count toward a
      // length. Whitespace is HELD until a real character follows it: leading
      // padding is then dropped, trailing padding is discarded at flush, and
      // interior spacing survives because a term may legitimately contain it
      // ("Claude Code"). Without this, a file of 3000 spaces — which should
      // import nothing — tripped the buffer bound below and failed the whole
      // paste as "too long" (cloud review, #1683).
      //
      // The hold is BOUNDED, or excluding padding from the length would just
      // move the unbounded growth somewhere the limit no longer watches: `x`
      // followed by millions of spaces would retain every one of them (Codex
      // review, #1683). Past the bound the run stops being kept and is only
      // remembered as overflowed — enough, because interior spacing that long
      // can only produce an entry the ceiling refuses anyway, and if no real
      // character follows, it was trailing padding and is discarded.
      if scalar.properties.isWhitespace {
        guard !buffer.isEmpty else { continue }
        if pendingWhitespace.count < memoryBound {
          pendingWhitespace.append(scalar)
        } else {
          pendingWhitespaceOverflowed = true
        }
        continue
      }
      // A real character after an overflowed run: the entry now contains that
      // whole run, so it is over-length by construction. Refuse it here rather
      // than materialising it to measure it.
      if pendingWhitespaceOverflowed {
        throw CustomWordsImportValidationError.wordTooLong(
          limit: CustomWordsImportLimits.maximumStoredValueScalars)
      }
      buffer.unicodeScalars.append(contentsOf: pendingWhitespace)
      pendingWhitespace.removeAll(keepingCapacity: true)
      // A MEMORY bound so one enormous line cannot grow the buffer to the
      // whole file. Now that padding is excluded, anything reaching it really
      // is an over-length entry, so wordTooLong is the honest error. The rule
      // itself still lives in flush(), applied to the trimmed value.
      guard
        buffer.unicodeScalars.count
          < CustomWordsImportLimits.maximumStoredValueScalars * 4
      else {
        throw CustomWordsImportValidationError.wordTooLong(
          limit: CustomWordsImportLimits.maximumStoredValueScalars)
      }
      buffer.unicodeScalars.append(scalar)
    }
    _ = flush()
    if let lengthFailure { throw lengthFailure }
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
        // See ImportFileError.tooManyWords: `found` is a stop-sentinel, not a
        // total.
        "That's more than \(limit) words, which is more than EnviousWispr can "
        + "import at once. Try pasting a smaller batch."
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
  @concurrent package func loadRawCandidates() async throws -> CustomWordsImportBatch {
    let canonicals = try PasteWordsParser.parse(
      text, limit: CustomWordsImportLimits.maximumCandidates)
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
