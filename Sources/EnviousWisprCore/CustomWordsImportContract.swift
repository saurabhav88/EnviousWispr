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
  /// cannot import is not an export. Far above any real library (over a
  /// million terms), while still refusing a mistakenly chosen disk image.
  package static let maximumExportedFileBytes = 256 * 1024 * 1024
}

package protocol CustomWordsImportSource: Sendable {
  func loadCandidates() async throws -> CustomWordsImportBatch
}
