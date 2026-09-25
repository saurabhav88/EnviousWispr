import EnviousWisprCore
import Foundation
import SQLite3

// Snippet import "From another app" (#2997 PR-B).
//
// Two adapters read the snippets a user built up in a rival dictation app, through the SAME
// acquisition policies the Dictionary import already measured and shipped for those apps'
// databases (`WisprFlowDatabase`, `TypeWhisperStoreSnapshot`). What is snippet-shaped here is
// the SQL, the row mapping, the exclusion rules, and the sentences. Nothing runs against
// another app's files until the user is on the app picker and chooses one.

/// Why reading another app's snippets didn't work (#2997). A snippet-shaped twin of
/// `SmartImportError`: the same three conditions, with sentences that say "snippets" where
/// that enum says "words" and "dictionary entries".
package enum SnippetImportAppError: LocalizedError, Sendable, Equatable {
  case appNotFound(String)
  case unreadable(String)
  /// More source rows than the shared candidate ceiling, counted BEFORE the adapter's own
  /// exclusions, so a store above the ceiling is refused rather than silently importing
  /// whichever survivors happened to fit.
  case tooManySourceEntries(appName: String, limit: Int)

  package var errorDescription: String? {
    switch self {
    case .appNotFound(let app):
      return String(
        localized:
          "Couldn't find any \(app) snippets on this Mac.",
        comment:
          "Snippets, import from another app: error. %@ is the other app's name.")
    case .unreadable(let app):
      // Same shape and reason as `SmartImportError.unreadable` (#3032): the remedy is offered,
      // not asserted as the cause, because the founder hit this sentence with Wispr Flow quit.
      return String(
        localized:
          "Couldn't read your \(app) snippets, so nothing was imported. If \(app) is running, quitting it and trying again can help.",
        comment:
          "Snippets, import from another app: error. Both %@ are the other app's name.")
    case .tooManySourceEntries(let app, let limit):
      // "entries", not "snippets": the count is of every row scanned where the app keeps
      // its snippets, and in Wispr Flow that table holds the words too.
      return String(
        localized:
          "\(app) has more than \(String(limit)) entries where it keeps snippets, counting ones that can't be snippets here. EnviousWispr stopped without importing anything.",
        comment:
          "Snippets, import from another app: error. The first %@ is the other app's name, the second a large limit (never 1)."
      )
    }
  }
}

/// What an adapter read, and how much of the source it deliberately refused. A COUNT only,
/// never the content: a competitor's excluded text never reaches our UI or our telemetry.
package struct SnippetImportRows: Sendable, Equatable {
  package let candidates: [SnippetImportCandidate]
  package let excludedCount: Int

  package init(candidates: [SnippetImportCandidate], excludedCount: Int = 0) {
    self.candidates = candidates
    self.excludedCount = excludedCount
  }
}

/// One competitor app EnviousWispr can read snippets out of.
///
/// A registry, like the file parsers: adding an app is a new conformer and one list entry.
/// `isInstalled` is consulted only once the user is looking at the app picker, and
/// `loadSnippets` only after they choose one (the same discipline as `SmartImportAdapter`).
package protocol SnippetImportAppAdapter: ImportedAppLocator {
  /// Stable identifier carried as the batch's `sourceID`; one of telemetry's closed
  /// `source` raw values (`wispr_flow`, `typewhisper`), never a display name.
  var identifier: String { get }
  /// What the user sees.
  var displayName: String { get }
  /// Read every snippet row, refusing and COUNTING the ones that cannot become a literal
  /// snippet here.
  func loadSnippets(at url: URL) throws -> SnippetImportRows
}

// MARK: - Wispr Flow

/// Wispr Flow keeps snippets in the same `Dictionary` table as its words, flagged
/// `isSnippet`; the word adapter excludes those rows and this one keeps only them.
package struct WisprFlowSnippetAdapter: SnippetImportAppAdapter {
  package let identifier = "wispr_flow"
  package let displayName = "Wispr Flow"

  package var candidatePaths: [URL] { WisprFlowDatabase.candidatePaths }

  package init() {}

  package func loadSnippets(at url: URL) throws -> SnippetImportRows {
    // `phrase` is the trigger and `replacement` the text (measured on the three real rows,
    // plan §2.5 premise 3). `replacementHtml` is ignored: a snippet here is plain text, and
    // it was empty on every real row. `isDeleted` rows are soft-deletes and importing them
    // would resurrect a snippet the user removed; `isSnippet = 0` rows are words, which the
    // Dictionary import owns. Both are COUNTED, never hidden by a WHERE clause, so a store
    // that held only words and deleted snippets reads as "found N, none compatible" and not
    // as empty. `ORDER BY id` gives the review a stable order; `LIMIT` is one past the
    // ceiling so "too many" is knowable (`AppSnippetImportSource`).
    let sql = """
      SELECT phrase, replacement, isDeleted, isSnippet
      FROM Dictionary
      ORDER BY id COLLATE BINARY ASC
      LIMIT \(SnippetImportLimits.maximumCandidates + 1)
      """
    let read: (rows: [SnippetImportCandidate], excludedCount: Int)
    do {
      read = try WisprFlowDatabase.read(at: url, appName: displayName, sql: sql) {
        statement -> SnippetImportCandidate? in
        let phrase = try SmartImportSQLiteReader.requiredText(statement, 0, displayName)
        let replacement = try SmartImportSQLiteReader.optionalText(statement, 1, displayName)
        let isDeleted = try SmartImportSQLiteReader.requiredBoolean(statement, 2, displayName)
        let isSnippet = try SmartImportSQLiteReader.requiredBoolean(statement, 3, displayName)
        guard !isDeleted, isSnippet else { return nil }
        return SnippetImportCandidate.literal(trigger: phrase, expansion: replacement)
      }
    } catch is SmartImportError {
      // The shared readers speak the word vocabulary; the sentence a user sees here must say
      // snippets. Every reader failure is one condition: the store could not be read safely.
      throw SnippetImportAppError.unreadable(displayName)
    }
    return SnippetImportRows(candidates: read.rows, excludedCount: read.excludedCount)
  }
}

extension SnippetImportCandidate {
  /// A rival-app row survives only as a LITERAL snippet: a trigger with some text and a
  /// non-blank expansion. A blank trigger or an empty text is valid-but-incompatible
  /// CONTENT, an exclusion the user sees as a count, never a refusal of the whole import
  /// (which `validated()` would make of it) and never a guess. The expansion is kept as the
  /// source held it.
  static func literal(trigger: String, expansion: String?) -> SnippetImportCandidate? {
    guard let expansion, !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    let trimmedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTrigger.isEmpty else { return nil }
    return SnippetImportCandidate(trigger: trimmedTrigger, expansion: expansion)
  }
}

// MARK: - TypeWhisper

/// TypeWhisper keeps snippets in their own Core Data store beside the dictionary one,
/// `snippets.store`, with the same `-wal`/`-shm` sidecars and the same never-checkpoint
/// behaviour, so the stable-copy acquisition serves it unchanged.
package struct TypeWhisperSnippetAdapter: SnippetImportAppAdapter {
  package let identifier = "typewhisper"
  package let displayName = "TypeWhisper"

  private let readPart: TypeWhisperAdapter.PartReader

  package var candidatePaths: [URL] {
    TypeWhisperStoreSnapshot.candidatePaths(store: "snippets.store")
  }

  package init(
    readPart: @escaping TypeWhisperAdapter.PartReader = TypeWhisperAdapter.readPartFromDisk
  ) {
    self.readPart = readPart
  }

  package func loadSnippets(at url: URL) throws -> SnippetImportRows {
    // No filtering WHERE clause: the mapper must SEE disabled rows in order to count them.
    // `ZCASESENSITIVE` and `ZUSAGECOUNT` are not read: a snippet here has neither concept.
    let sql = """
      SELECT ZTRIGGER, ZREPLACEMENT, ZISENABLED
      FROM ZSNIPPET
      ORDER BY Z_PK ASC
      LIMIT \(SnippetImportLimits.maximumCandidates + 1)
      """
    let read: (rows: [SnippetImportCandidate], excludedCount: Int)
    do {
      read = try TypeWhisperStoreSnapshot.read(
        at: url, readPart: readPart, appName: displayName, sql: sql
      ) { statement -> SnippetImportCandidate? in
        let trigger = try SmartImportSQLiteReader.requiredText(statement, 0, displayName)
        let replacement = try SmartImportSQLiteReader.optionalText(statement, 1, displayName)
        let isEnabled = try SmartImportSQLiteReader.requiredBoolean(statement, 2, displayName)
        guard isEnabled else { return nil }
        // TypeWhisper's three built-ins — `{{DATE}}`, `{{TIME}}`, `{{CLIPBOARD}}` — are fill-ins
        // EnviousWispr now has too, so they import verbatim and resolve at paste time (#3018).
        // Anything ELSE inside `{{...}}` is still refused and still counted, because pasting it
        // would paste the letters. `SnippetPlaceholder` answers both questions, so the import's
        // idea of a fill-in and the matcher's cannot drift apart.
        guard let replacement,
          !SnippetPlaceholder.carriesUnsupportedPlaceholder(replacement)
        else { return nil }
        return SnippetImportCandidate.literal(trigger: trigger, expansion: replacement)
      }
    } catch is SmartImportError {
      throw SnippetImportAppError.unreadable(displayName)
    }
    return SnippetImportRows(candidates: read.rows, excludedCount: read.excludedCount)
  }

}

// MARK: - Registry and source

package struct SnippetImportAppRegistry: Sendable {
  package let adapters: [any SnippetImportAppAdapter]

  package static let v1 = SnippetImportAppRegistry(
    adapters: [WisprFlowSnippetAdapter(), TypeWhisperSnippetAdapter()])

  /// The display names, in registry order, for whoever writes the picker copy. The registry
  /// owns the NAMES; AppKit owns the SENTENCE (as `SmartImportRegistry.displayNames`).
  package var displayNames: [String] { adapters.map(\.displayName) }

  package init(adapters: [any SnippetImportAppAdapter]) {
    self.adapters = adapters
  }

  package func adapter(withID id: String) -> (any SnippetImportAppAdapter)? {
    adapters.first { $0.identifier == id }
  }
}

/// Reads one competitor app's snippets into the shared import pipeline.
package struct AppSnippetImportSource: SnippetImportSource {
  private let adapter: any SnippetImportAppAdapter

  package init(adapter: any SnippetImportAppAdapter) {
    self.adapter = adapter
  }

  package var sourceID: String { adapter.identifier }

  /// `@concurrent` so a SQLite read of another app's database never runs on the main actor.
  ///
  /// Returns RAW candidates: `loadCandidates()` validates what this produces, so a
  /// competitor's snippets go through exactly the same character and length rules as a
  /// pasted list or a chosen file.
  @concurrent package func loadRawCandidates() async throws -> SnippetImportBatch {
    guard let path = adapter.installedPath else {
      throw SnippetImportAppError.appNotFound(adapter.displayName)
    }
    try Task.checkCancellation()

    let rows = try adapter.loadSnippets(at: path)
    try Task.checkCancellation()

    // The SCANNED row count, survivors plus exclusions, against the ceiling: the adapters
    // read one past it so "too many" is knowable, and an adapter that excluded 5,001 rows
    // down to one must not look like a one-row source (the same shape as
    // `SmartImportSource`).
    let scannedCount = rows.candidates.count + rows.excludedCount
    guard scannedCount <= SnippetImportLimits.maximumCandidates else {
      throw SnippetImportAppError.tooManySourceEntries(
        appName: adapter.displayName, limit: SnippetImportLimits.maximumCandidates)
    }

    // One notice whenever anything was left out, not only when nothing survived: a mixed
    // batch tells the user "3 left out" beside the rows that did come across
    // (`SnippetImportNotice`).
    let notices: [SnippetImportNotice] =
      rows.excludedCount > 0
      ? [.incompatibleSourceEntriesExcluded(count: rows.excludedCount)]
      : []

    return SnippetImportBatch(
      sourceID: adapter.identifier, sourceDisplayName: adapter.displayName,
      candidates: rows.candidates, notices: notices)
  }
}
