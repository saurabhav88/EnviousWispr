import EnviousWisprCore
import Foundation
import SQLite3

/// Why reading another app's vocabulary didn't work (#1686).
package enum SmartImportError: LocalizedError, Sendable, Equatable {
  case appNotFound(String)
  case unreadable(String)

  package var errorDescription: String? {
    switch self {
    case .appNotFound(let app):
      return "Couldn't find any \(app) words on this Mac."
    case .unreadable(let app):
      return
        "Couldn't read your \(app) words. If \(app) is open, try quitting it and importing again."
    }
  }
}

/// One competitor app EnviousWispr can read vocabulary out of.
///
/// A registry, like the file parsers: adding an app is a new conformer and one
/// list entry, with nothing existing rewritten.
///
/// **Nothing here runs until the user asks for it.** No adapter touches disk at
/// launch or when the sheet opens — an installed competitor is never quietly
/// inspected in the background. `isInstalled` is only consulted once the user
/// is looking at the app picker, and `loadWords` only after they choose one.
package protocol SmartImportAdapter: Sendable {
  /// Stable identifier emitted as the batch's `sourceID` for telemetry.
  var identifier: String { get }
  /// What the user sees.
  var displayName: String { get }
  /// Where this app keeps vocabulary, in probe order.
  var candidatePaths: [URL] { get }
  /// Read the canonical words. Aliases are deliberately NOT returned: v1
  /// import carries the main word only (founder rule), so an adapter that
  /// harvested synonyms would be supplying data the pipeline must discard.
  func loadWords(at url: URL) throws -> [String]
}

extension SmartImportAdapter {
  /// Refuse an implausibly large vocabulary file before decoding it.
  ///
  /// A word list is small. Reading an arbitrarily large or corrupted file into
  /// memory to discover it is too big is the expensive way to find out, and
  /// can end the app before the intended error is ever shown (code review r9).
  static var maximumVocabularyBytes: Int { 8 * 1024 * 1024 }

  /// Read a vocabulary file with that ceiling applied to the READ itself.
  func boundedData(at url: URL, appName: String) throws -> Data {
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      throw SmartImportError.unreadable(appName)
    }
    defer { try? handle.close() }
    let ceiling = Self.maximumVocabularyBytes + 1
    var data = Data()
    while data.count < ceiling {
      let chunk: Data?
      do { chunk = try handle.read(upToCount: ceiling - data.count) } catch {
        throw SmartImportError.unreadable(appName)
      }
      guard let chunk, !chunk.isEmpty else { break }
      data.append(chunk)
    }
    guard data.count <= Self.maximumVocabularyBytes else {
      throw SmartImportError.unreadable(appName)
    }
    return data
  }

  /// The first location that actually exists, or nil.
  package var installedPath: URL? {
    candidatePaths.first { FileManager.default.fileExists(atPath: $0.path) }
  }
  package var isInstalled: Bool { installedPath != nil }
}

// MARK: - FluidVoice

/// Single JSON file. The keys beside `terms` are FluidVoice's own ASR tuning
/// parameters, not vocabulary, and are ignored.
package struct FluidVoiceAdapter: SmartImportAdapter {
  package let identifier = "fluidvoice"
  package let displayName = "FluidVoice"

  private struct Vocabulary: Decodable {
    struct Term: Decodable { let text: String }
    let terms: [Term]?
  }

  package var candidatePaths: [URL] {
    [
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(
          "Library/Application Support/FluidVoice/parakeet_custom_vocabulary.json")
    ]
  }

  package init() {}

  package func loadWords(at url: URL) throws -> [String] {
    let data = try boundedData(at: url, appName: displayName)
    guard let vocabulary = try? JSONDecoder().decode(Vocabulary.self, from: data) else {
      throw SmartImportError.unreadable(displayName)
    }
    // `terms` absent entirely is a legitimate fresh install, not a failure.
    return (vocabulary.terms ?? []).map(\.text)
  }
}

// MARK: - Superwhisper

/// JSON settings file in one of two locations. Both keys may be absent
/// entirely on a fresh install rather than present-but-empty.
package struct SuperwhisperAdapter: SmartImportAdapter {
  package let identifier = "superwhisper"
  package let displayName = "Superwhisper"

  private struct Settings: Decodable {
    struct Replacement: Decodable { let with: String? }
    let vocabulary: [String]?
    let replacements: [Replacement]?
  }

  package var candidatePaths: [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    // Probe BOTH, CURRENT FIRST. The app's current default is directly under
    // home; older installs keep it under Documents. Checking only one silently
    // reports "not found" for half the installed base — but order matters just
    // as much: an upgraded install can retain BOTH files, and probing the
    // legacy path first would read vocabulary the user stopped editing months
    // ago while ignoring the file the app is actually using (code review).
    return [
      home.appendingPathComponent("superwhisper/settings/settings.json"),
      home.appendingPathComponent("Documents/superwhisper/settings/settings.json"),
    ]
  }

  package init() {}

  package func loadWords(at url: URL) throws -> [String] {
    let data = try boundedData(at: url, appName: displayName)
    guard let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
      throw SmartImportError.unreadable(displayName)
    }
    // A replacement is a find/replace pair; its `with` side is the spelling
    // the user actually wants, which is the word worth bringing across. The
    // `original` side is the alias, and v1 does not import aliases.
    let corrected = (settings.replacements ?? []).compactMap(\.with)
    return (settings.vocabulary ?? []) + corrected
  }
}

// MARK: - Wispr Flow

/// SQLite, read strictly read-only against another app's live database.
package struct WisprFlowAdapter: SmartImportAdapter {
  package let identifier = "wispr-flow"
  package let displayName = "Wispr Flow"

  package var candidatePaths: [URL] {
    [
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Wispr Flow/flow.sqlite")
    ]
  }

  package init() {}

  package func loadWords(at url: URL) throws -> [String] {
    // isDeleted: a soft-delete flag. Importing unfiltered would resurrect
    // words the user deliberately removed — the single worst thing this
    // adapter could do.
    // isSnippet: text expansions are a different feature, not vocabulary.
    // `replacement` is the corrected spelling when present; `phrase` is the
    // alias in that case, and v1 does not import aliases.
    let sql = """
      SELECT COALESCE(NULLIF(TRIM(replacement), ''), phrase)
      FROM Dictionary
      WHERE isDeleted = 0 AND isSnippet = 0
      LIMIT \(CustomWordsImportLimits.maximumCandidates + 1)
      """

    // Choose the connection mode from the WAL sidecar, rather than trying one
    // and falling back (code reviews r1 + r2, both measured).
    //
    // r1 asked for plain read-only, because `immutable=1` lets SQLite skip WAL
    // handling and can return stale or torn rows while Wispr Flow writes. Real
    // concern. But measured on a real install with the app NOT running, plain
    // read-only opens and then fails to prepare with SQLITE_CANTOPEN: the
    // database is WAL and a read-only connection needs the `-shm` sidecar,
    // which a cleanly closed app does not leave behind.
    //
    // r2 then caught what try-and-fallback risks: `SQLITE_OPEN_READONLY`
    // protects the main database only. A read-only connection CAN create
    // `-wal`/`-shm` in a writable directory, so merely attempting it can
    // leave files inside another app's data folder — which is not read-only
    // in any sense the user would recognise. It did not happen here (the
    // attempt failed first), but "it happens to fail safely" is not a
    // guarantee worth shipping.
    //
    // So decide up front, from a fact already on disk:
    //   WAL present  → the other app has uncommitted content, so read it
    //                  WAL-aware. Its sidecars already exist; we create nothing.
    //   WAL absent   → nothing uncommitted, the committed file IS the whole
    //                  truth, and immutable reads it without ever creating a
    //                  sidecar.
    // BOTH sidecars, not just the WAL (code review r3). If `-wal` exists but
    // `-shm` does not — a crashed or mid-recovery Wispr Flow — a plain
    // read-only connection will CREATE the missing `-shm` in a writable
    // directory, which is the exact thing the previous round removed. And
    // immutable is not a safe substitute here either: with real uncommitted
    // WAL content, skipping it would import a stale view and call it complete.
    //
    // Neither option is honest, so refuse and say what would fix it. Quitting
    // the other app flushes its WAL and makes the next attempt both safe and
    // complete — which is exactly what the error message already tells the
    // user to do.
    let fm = FileManager.default
    let hasWAL = fm.fileExists(atPath: url.path + "-wal")
    let hasSHM = fm.fileExists(atPath: url.path + "-shm")
    if hasWAL && !hasSHM {
      throw SmartImportError.unreadable(displayName)
    }
    let uri = hasWAL ? "file:\(url.path)" : "file:\(url.path)?immutable=1"

    // The check above and the open below are two moments, and Wispr Flow can
    // start or stop writing in between (code review r4). Two ways that hurts:
    // a WAL created after an immutable decision is ignored, silently importing
    // stale words; a WAL that disappears makes the read-only path recreate
    // sidecars in the competitor's directory.
    //
    // A snapshot copy would close the window completely, but the real database
    // here is 151 MB — copying it to read a handful of words is a poor trade.
    // Instead the state is re-checked after the read (see below): if it moved,
    // the import is refused rather than reported. That turns an invisible
    // wrong answer into a visible "try again", which is the honest failure.
    let sidecarStateAtStart = hasWAL

    var db: OpaquePointer?
    guard
      sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
      let db
    else {
      sqlite3_close(db)
      throw SmartImportError.unreadable(displayName)
    }
    defer { sqlite3_close(db) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      sqlite3_finalize(statement)
      throw SmartImportError.unreadable(displayName)
    }
    defer { sqlite3_finalize(statement) }

    let words = try readWords(from: statement)

    // Re-check the sidecar state the mode was chosen from. If Wispr Flow began
    // or finished writing while this read was in flight, the connection mode no
    // longer matches the database and these words may be a stale view. Refuse
    // rather than hand back something that looks complete — the error already
    // tells the user to quit the other app and try again.
    guard fm.fileExists(atPath: url.path + "-wal") == sidecarStateAtStart else {
      throw SmartImportError.unreadable(displayName)
    }
    return words
  }

  private func readWords(from statement: OpaquePointer?) throws -> [String] {

    var words: [String] = []
    var result = sqlite3_step(statement)
    while result == SQLITE_ROW {
      if let text = sqlite3_column_text(statement, 0) {
        words.append(String(cString: text))
      }
      result = sqlite3_step(statement)
    }
    // Only SQLITE_DONE means "that was all of them" (code review). The first
    // version treated every non-ROW result as the end, so SQLITE_BUSY on a
    // database Wispr Flow was writing — or IOERR, or CORRUPT — returned
    // whatever prefix had been read so far, possibly nothing at all, and the
    // import reported success. A partial read presented as a complete one is
    // the same false-pass shape as a test that never runs.
    guard result == SQLITE_DONE else {
      throw SmartImportError.unreadable(displayName)
    }
    return words
  }
}

// MARK: - Registry and source

package struct SmartImportRegistry: Sendable {
  package let adapters: [any SmartImportAdapter]

  /// TypeWhisper is deliberately absent: its schema is confirmed but its table
  /// is empty on the only machine available, so an adapter would be written
  /// against a shape nobody has seen populated, and its WAL sidecar files add
  /// a correctness question that cannot be tested without real content.
  package static let v1 = SmartImportRegistry(
    adapters: [WisprFlowAdapter(), FluidVoiceAdapter(), SuperwhisperAdapter()])

  package init(adapters: [any SmartImportAdapter]) {
    self.adapters = adapters
  }

  package func adapter(withID id: String) -> (any SmartImportAdapter)? {
    adapters.first { $0.identifier == id }
  }
}

/// Reads one competitor app's vocabulary into the shared pipeline.
package struct SmartImportSource: CustomWordsImportSource {
  private let adapter: any SmartImportAdapter

  package init(adapter: any SmartImportAdapter) {
    self.adapter = adapter
  }

  /// `@concurrent` so a SQLite read of another app's database never runs on
  /// the main actor.
  ///
  /// Returns RAW candidates: the protocol's `loadCandidates()` validates what
  /// this produces, so a competitor's vocabulary goes through exactly the same
  /// character and length rules as a pasted list or an uploaded file. A source
  /// cannot opt out of that by forgetting to call it (#1683).
  @concurrent package func loadRawCandidates() async throws -> CustomWordsImportBatch {
    guard let path = adapter.installedPath else {
      throw SmartImportError.appNotFound(adapter.displayName)
    }
    try Task.checkCancellation()

    let words = try adapter.loadWords(at: path)
    try Task.checkCancellation()

    // Check the RAW row count, before deduplication (code review r10).
    //
    // The adapters read one past the ceiling so that "too many" is knowable.
    // But dedup shrinks the list, so a source whose first 25,001 rows contain
    // duplicates would fall back under the limit and report a successful
    // import that had silently dropped everything beyond it. Every ceiling
    // needs a signal for having been reached; counting after the shrink loses
    // that signal — the same mistake the pasted-text parser made.
    guard words.count <= CustomWordsImportLimits.maximumCandidates else {
      // `found` is a real count here, not a stop-sentinel: the adapters read
      // exactly one past the ceiling, so this is what was actually seen. The
      // message says "more than" either way, so it never states a figure it
      // cannot stand behind.
      throw ImportFileError.tooManyWords(
        found: words.count, limit: CustomWordsImportLimits.maximumCandidates)
    }

    // Reuse the shared splitter's normalization so a competitor's list dedups
    // exactly the way a pasted one does, and trim/blank handling is identical.
    var seen = Set<String>()
    var canonicals: [String] = []
    for word in words {
      let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let key = CustomWordsImportCompareEngine.normalize(trimmed)
      guard !key.isEmpty, seen.insert(key).inserted else { continue }
      canonicals.append(trimmed)
    }

    return CustomWordsImportBatch(
      sourceID: adapter.identifier,
      sourceDisplayName: adapter.displayName,
      // Main word only, every authority field unspecified — the same contract
      // paste and plain text honour. A competitor's synonyms are not imported
      // in v1, so an existing word is skipped rather than modified.
      candidates: canonicals.map { CustomWordsImportCandidate(canonical: $0) }
    )
  }
}
