import Foundation

// Canonical shared contract for Custom Words import (#1661, epic #1619 PR-F2a).
//
// Every import source — Paste, Upload, each Smart Import competitor adapter,
// and the EnviousWispr backup format — implements `CustomWordsImportSource`
// and returns `CustomWordsImportBatch`. Nothing downstream (compare engine,
// Review screen, commit) knows which source produced a candidate. Lives in
// Core because the file-import and smart-import leaf modules depend only on
// Core, and LLM / PostProcessing / AppKit all need these types too.

/// Core-level Apple Intelligence availability value for the import flow.
/// PR-P1's connector check returns this; the import UI says so honestly when
/// it is unavailable (unlike AI Polish, whose silent skip is deliberate —
/// nobody asked polish for suggestions, but an importing user did).
package enum AppleIntelligenceAvailability: Sendable, Equatable {
  case available
  case unavailable(reason: AIFailureReason, message: String)
}

/// Authority carrier for the six conditional fields on an import candidate.
///
/// `.unspecified` means the source has NO OPINION — on Replace, the existing
/// word's hand-tuned value is preserved untouched. `.supplied` means the
/// source is authoritative — on Replace its value is applied, INCLUDING
/// authoritative clears: `.supplied([])` empties aliases and
/// `.supplied(nil)` clears `minSimilarityOverride`. Only the EnviousWispr
/// backup format ever emits either clear; every other source maps "no data
/// in this row" to `.unspecified`, never to an instruction to clear.
/// A plain Optional cannot represent "supplied: nil", which is what forced
/// this enum (plan round 9).
package enum CustomWordsImportField<Value: Sendable & Hashable>: Sendable, Hashable {
  case unspecified
  case supplied(Value)
}

/// Transient import candidate. Deliberately CANNOT carry `source`,
/// `frequencyUsed`, or `lastUsed`, so no adapter can import another Mac's
/// usage history. `id` is review-row identity only — a committed Replace
/// keeps the existing word's UUID, and a committed Add mints a fresh one.
package struct CustomWordsImportCandidate: Identifiable, Sendable, Hashable {
  package let id: UUID
  package var canonical: String
  package var aliases: CustomWordsImportField<[String]>
  /// AI-enrichment output (PR-P1). NEVER authoritative: applied only on Add,
  /// never on Replace, so a machine guess cannot overwrite hand-tuned aliases.
  package var suggestedAliases: [String]
  package var category: CustomWordsImportField<WordCategory>
  package var priority: CustomWordsImportField<Int>
  package var forceReplace: CustomWordsImportField<Bool>
  package var caseSensitive: CustomWordsImportField<Bool>
  /// `.supplied(nil)` = authoritative "no per-term override" (backup
  /// round-trip); `.unspecified` = the source knows nothing about strictness.
  package var minSimilarityOverride: CustomWordsImportField<Double?>

  /// Every string this candidate could put into the library.
  ///
  /// Enumerated in ONE place so validation cannot check some of them: it
  /// covered canonical and aliases while `suggestedAliases` — which the commit
  /// path also persists — went unchecked (cloud review, #1683). A field added
  /// here is validated automatically; a field added anywhere else is not, so
  /// this is the list to extend.
  package var storedValues: [String] {
    var values = [canonical]
    if case .supplied(let aliases) = aliases { values.append(contentsOf: aliases) }
    values.append(contentsOf: suggestedAliases)
    return values
  }

  package init(
    id: UUID = UUID(),
    canonical: String,
    aliases: CustomWordsImportField<[String]> = .unspecified,
    suggestedAliases: [String] = [],
    category: CustomWordsImportField<WordCategory> = .unspecified,
    priority: CustomWordsImportField<Int> = .unspecified,
    forceReplace: CustomWordsImportField<Bool> = .unspecified,
    caseSensitive: CustomWordsImportField<Bool> = .unspecified,
    minSimilarityOverride: CustomWordsImportField<Double?> = .unspecified
  ) {
    self.id = id
    self.canonical = canonical
    self.aliases = aliases
    self.suggestedAliases = suggestedAliases
    self.category = category
    self.priority = priority
    self.forceReplace = forceReplace
    self.caseSensitive = caseSensitive
    self.minSimilarityOverride = minSimilarityOverride
  }
}

/// One notices side-channel for a batch — never a second `warnings` field.
package enum CustomWordsImportNotice: Sendable, Equatable {
  /// Produced by the shared enrichment stage (PR-P1) in the Paste and Upload flows.
  case appleIntelligenceUnavailable(AppleIntelligenceAvailability)
  /// Produced by the shared enrichment stage (PR-P1).
  case suggestionsPartiallyUnavailable(count: Int)
  /// Produced by the shared enrichment stage when the per-import
  /// suggestion-call budget is exhausted; `remainingCount` = candidates that
  /// proceeded without suggestions.
  case suggestionBudgetReached(remainingCount: Int)
  /// Upload-only row-level parse warning.
  case fileParseWarning(rowNumber: Int, reason: String)
}

package struct CustomWordsImportBatch: Sendable, Equatable {
  /// Stable adapter identifier (`ImportFileParser.identifier` /
  /// `SmartImportSourceDescriptor.id` / "paste" / "backup") — the value
  /// telemetry emits; never a filename or display string.
  package let sourceID: String
  /// What the UI shows ("Wispr Flow", "CSV file", …); never emitted to telemetry.
  package let sourceDisplayName: String
  package let candidates: [CustomWordsImportCandidate]
  package let notices: [CustomWordsImportNotice]

  package init(
    sourceID: String,
    sourceDisplayName: String,
    candidates: [CustomWordsImportCandidate],
    notices: [CustomWordsImportNotice] = []
  ) {
    self.sourceID = sourceID
    self.sourceDisplayName = sourceDisplayName
    self.candidates = candidates
    self.notices = notices
  }

  /// Refuses the WHOLE batch if any candidate is unstorable.
  ///
  /// All-or-nothing on purpose: silently dropping bad rows would show the user
  /// a review screen that quietly disagrees with their file, and importing
  /// them would put invisible characters inside stored words. A refusal names
  /// the offending entry so the file can be fixed.
  ///
  /// Checks the values that actually get STORED — canonical and aliases — for
  /// every source, which is the gap that let exported JSON skip the character
  /// rules the text path enforced.
  package func validated() throws -> CustomWordsImportBatch {
    // Walks `storedValues` rather than naming fields here, so a field added to
    // the candidate is validated by existing. Naming them individually is what
    // let `suggestedAliases` — which the commit path persists — go unchecked
    // while canonical and aliases were covered (cloud review, #1683).
    //
    // Counted across the whole walk, because the work is proportional to total
    // stored values: one candidate may carry hundreds of thousands of aliases,
    // so a per-candidate check leaves that uninterruptible.
    var scanned = 0
    for candidate in candidates {
      for value in candidate.storedValues {
        scanned += 1
        if scanned.isMultiple(of: 1_000) { try Task.checkCancellation() }

        // Judged on the TRIMMED value, because trimmed is what gets stored —
        // the same rule the paste scanner and the manager's write boundary
        // apply. Counting padding here refused a short word in a structured
        // file for whitespace that would never have been saved (cloud review,
        // #1683).
        guard
          value.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
            <= CustomWordsImportLimits.maximumStoredValueScalars
        else {
          throw CustomWordsImportValidationError.wordTooLong(
            limit: CustomWordsImportLimits.maximumStoredValueScalars)
        }
        guard CustomWordsImportTextPolicy.isAcceptableStoredValue(value) else {
          throw value == candidate.canonical
            ? CustomWordsImportValidationError.unusableWord(canonical: candidate.canonical)
            : CustomWordsImportValidationError.unusableAlias(
              alias: value, canonical: candidate.canonical)
        }
      }
    }
    return self
  }
}

/// Shared ceilings every import source honours (#1683).
///
/// One home so paste and file import cannot drift apart: the compare engine,
/// the review list, and the commit all pay the same cost per candidate no
/// matter which door the words came through, so a limit that applies to one
/// source and not another is an accident waiting to be found by a user.
package enum CustomWordsImportLimits {
  /// The compare engine's documented upload ceiling. Beyond this the review
  /// screen is not something a person can meaningfully read anyway.
  package static let maximumCandidates = 25_000

  /// Untrusted files: a word list is small, so anything larger is a mistaken
  /// selection (a video, a database, a disk image) and reading it into memory
  /// to find that out is the expensive way to learn it.
  package static let maximumImportFileBytes = 16 * 1024 * 1024

  /// Our OWN exported file, which must always be readable back — an export you
  /// cannot import is not an export.
  ///
  /// Higher than the untrusted cap, but still FINITE, because the
  /// "this is an EnviousWispr export" marker is self-declared and unsigned:
  /// any JSON claiming it would otherwise get an unbounded budget (Codex
  /// review, #1683). Bounded means a crafted or damaged file has a known worst
  /// case instead of hanging the review screen.
  package static let maximumExportedFileBytes = 64 * 1024 * 1024

  /// Words an exported file may carry. Comfortably past any real library —
  /// larger than most complete English dictionaries — while keeping the
  /// compare engine and review list inside a worst case we have reasoned about.
  package static let maximumExportedCandidates = 100_000

  /// Total stored strings — every canonical PLUS every alias — an exported
  /// file may carry.
  ///
  /// Bounding words alone bounded one dimension of the wrong thing: 100,000
  /// words each carrying hundreds of aliases fits inside both the word and
  /// byte ceilings while producing millions of strings to validate, compare,
  /// and index (Codex review, #1683). The cost of an import tracks the stored
  /// SURFACE, so that is what has a ceiling.
  package static let maximumExportedStoredValues = 400_000

  /// Longest a single canonical or alias may be, in Unicode scalars.
  ///
  /// A custom word is a word or short phrase. Without this, one enormous line
  /// — a minified file or a log picked by mistake — passes the candidate
  /// ceiling as a SINGLE entry and becomes a multi-megabyte "word" that is
  /// copied through normalisation and comparison, rendered in Review, and
  /// persisted (Codex review, #1683). Generous enough for any real term,
  /// including long compounds in scripts that do not space-separate.
  package static let maximumStoredValueScalars = 512
}

package protocol CustomWordsImportSource: Sendable {
  /// Produce candidates. Callers do NOT call this — they call
  /// `loadCandidates()`, which validates what this returns.
  func loadRawCandidates() async throws -> CustomWordsImportBatch
}

extension CustomWordsImportSource {
  /// The only entry point callers use, so domain validation cannot be
  /// forgotten by a new source (#1683).
  ///
  /// Validation used to live inside one parser, which meant it protected the
  /// door it was written for and no other: words from an exported file
  /// bypassed every character rule the pasted-text path enforced. Putting it
  /// HERE makes it a property of importing rather than of one importer — a new
  /// source gets it by existing, and cannot opt out by forgetting.
  package func loadCandidates() async throws -> CustomWordsImportBatch {
    try await loadRawCandidates().validated()
  }
}

/// A candidate that cannot be stored, and why (#1683).
package enum CustomWordsImportValidationError: LocalizedError, Sendable, Equatable {
  case unusableWord(canonical: String)
  case unusableAlias(alias: String, canonical: String)
  case wordTooLong(limit: Int)

  /// Replaces anything the policy refuses with a visible `U+XXXX` label, so a
  /// deceptive scalar cannot act on the UI that reports it.
  static func displayable(_ value: String) -> String {
    String(
      value.unicodeScalars.map { scalar -> String in
        CustomWordsImportTextPolicy.isAcceptableInStoredValue(scalar)
          ? String(scalar)
          : "<U+" + String(format: "%04X", scalar.value) + ">"
      }.joined())
  }

  package var errorDescription: String? {
    switch self {
    case .wordTooLong(let limit):
      return
        "That contains an entry longer than \(limit) characters, which is too "
        + "long to be a word. Nothing was imported."
    case .unusableAlias(let alias, let canonical):
      // Names the ALIAS, not the word that owns it. Reporting the canonical
      // quoted an innocent value and hid the one that has to be fixed (Codex
      // review, #1683).
      return
        "That contains an alternate spelling EnviousWispr can't store "
        + "(\"\(Self.displayable(alias))\", for \"\(Self.displayable(canonical))\"). "
        + "Nothing was imported."
    case .unusableWord(let canonical):
      // Source-neutral: this validator now runs for pasted text and files
      // alike, so naming a file was wrong half the time (Codex review, #1683).
      //
      // The value is SANITISED before display. Echoing it raw meant the very
      // character rejected for rendering deceptively — a bidi override, a line
      // separator — got rendered into the message explaining its rejection,
      // where it can reorder or break the error text itself. Naming the
      // offending scalar is more useful to the user than showing it.
      let shown =
        canonical.isEmpty ? "a blank entry" : "\"\(Self.displayable(canonical))\""
      return
        "That contains a word EnviousWispr can't store (\(shown)). "
        + "Nothing was imported."
    }
  }
}
